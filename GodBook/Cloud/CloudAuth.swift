import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct OAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

/// OAuth 端點設定。行動 App 屬於公開用戶端：使用授權碼 + PKCE，不需要用戶端密鑰。
struct OAuthConfig {
    let authorizeURL: URL
    let tokenURL: URL
    let clientId: String
    let redirectURI: String
    let callbackScheme: String
    let scopes: String
    var extraParameters: [String: String] = [:]
    var scopeOnRefresh = false

    /// Microsoft：在 Azure 的「iOS / macOS」平台填入 Bundle ID com.godbook.app 即會產生這個網址
    static let microsoftRedirect = "msauth.com.godbook.app://auth"

    /// 要填到雲端服務後台的重新導向 URI（Google 的網址由用戶端 ID 推算）
    static func redirectURI(for kind: CloudKind) -> String? {
        switch kind {
        case .oneDrivePersonal, .oneDriveBusiness:
            return microsoftRedirect
        case .googleDrive:
            let id = CloudSettings.shared.clientId(for: .googleDrive)
            return id.isEmpty ? nil : googleScheme(id) + ":/oauthredirect"
        case .webdav:
            return nil
        }
    }

    /// 123-abc.apps.googleusercontent.com → com.googleusercontent.apps.123-abc
    private static func googleScheme(_ clientId: String) -> String {
        clientId.split(separator: ".").reversed().joined(separator: ".")
    }

    static func make(_ kind: CloudKind) throws -> OAuthConfig {
        let settings = CloudSettings.shared
        let clientId = settings.clientId(for: kind)
        guard !clientId.isEmpty else { throw AppError.message(L("請先填寫 %@ 的用戶端 ID", kind.title)) }
        switch kind {
        case .oneDrivePersonal, .oneDriveBusiness:
            // 個人版固定走 consumers；商業版走 organizations 或指定的租用戶
            let tenant = kind == .oneDrivePersonal ? "consumers" : settings.businessTenant
            let base = "https://login.microsoftonline.com/\(CloudHTTP.encode(tenant))/oauth2/v2.0"
            guard let authorize = URL(string: base + "/authorize"), let token = URL(string: base + "/token") else {
                throw AppError.message(L("租用戶格式不正確"))
            }
            return OAuthConfig(authorizeURL: authorize, tokenURL: token, clientId: clientId,
                               redirectURI: microsoftRedirect, callbackScheme: "msauth.com.godbook.app",
                               scopes: "offline_access User.Read Files.ReadWrite",
                               extraParameters: ["prompt": "select_account"], scopeOnRefresh: true)
        case .googleDrive:
            let scheme = googleScheme(clientId)
            return OAuthConfig(authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                               tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                               clientId: clientId, redirectURI: scheme + ":/oauthredirect", callbackScheme: scheme,
                               scopes: "https://www.googleapis.com/auth/drive.file",
                               extraParameters: ["prompt": "select_account"])
        case .webdav:
            throw AppError.message(L("WebDAV 不使用 OAuth 登入"))
        }
    }
}

/// 權杖存在 Keychain（不放進 App 備份；換裝置需重新連結）
enum OAuthStore {
    private static func key(_ kind: CloudKind) -> String { "cloud.token.\(kind.rawValue)" }

    static func load(_ kind: CloudKind) -> OAuthToken? {
        guard let text = Keychain.get(key(kind)) else { return nil }
        return try? JSONDecoder().decode(OAuthToken.self, from: Data(text.utf8))
    }

    static func save(_ token: OAuthToken, _ kind: CloudKind) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        Keychain.set(String(decoding: data, as: UTF8.self), for: key(kind))
    }

    static func delete(_ kind: CloudKind) {
        Keychain.delete(key(kind))
    }
}

private enum OAuthError: Error {
    case invalidGrant
}

enum OAuth {
    /// 開啟系統登入頁取得授權碼，換成權杖並存入 Keychain。
    @MainActor
    static func signIn(_ kind: CloudKind) async throws {
        let config = try OAuthConfig.make(kind)
        let verifier = randomString(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomString(24)

        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ] + config.extraParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw AppError.message(L("網址無效")) }

        let callback = try await OAuthPresenter.shared.run(url: url, scheme: config.callbackScheme)
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if let error = value("error") {
            throw AppError.message(L("登入失敗：%@", value("error_description") ?? error))
        }
        guard value("state") == state, let code = value("code") else {
            throw AppError.message(L("登入失敗：回應無效"))
        }
        let token = try await requestToken(config, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientId,
            "code_verifier": verifier,
        ], previous: nil)
        OAuthStore.save(token, kind)
    }

    static func refresh(_ token: OAuthToken, kind: CloudKind) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else {
            throw AppError.message(L("%@ 的登入已失效，請重新連結", kind.title))
        }
        let config = try OAuthConfig.make(kind)
        var form = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": config.clientId]
        if config.scopeOnRefresh { form["scope"] = config.scopes }
        do {
            return try await requestToken(config, form, previous: token)
        } catch OAuthError.invalidGrant {
            OAuthStore.delete(kind)
            throw AppError.message(L("%@ 的登入已失效，請重新連結", kind.title))
        }
    }

    private static func requestToken(_ config: OAuthConfig, _ form: [String: String], previous: OAuthToken?) async throws -> OAuthToken {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(CloudHTTP.formEncode(form).utf8)
        let (data, response) = try await HTTP.plainSession.data(for: request)
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let access = json["access_token"] as? String else {
            let code = json["error"] as? String ?? ""
            if code == "invalid_grant" { throw OAuthError.invalidGrant }
            let description = json["error_description"] as? String ?? code
            throw AppError.message(L("取得權杖失敗：%@", description.isEmpty ? "HTTP \(status)" : description))
        }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue ?? Double(json["expires_in"] as? String ?? "") ?? 3600
        return OAuthToken(accessToken: access,
                          refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
                          expiresAt: Date().addingTimeInterval(expires))
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in characters.randomElement()! })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// 每個服務一個，負責回傳有效的存取權杖；同時間只會有一個刷新請求。
actor CloudAuth {
    private static let all = Dictionary(uniqueKeysWithValues: CloudKind.allCases.map { ($0, CloudAuth(kind: $0)) })

    static func shared(_ kind: CloudKind) -> CloudAuth { all[kind]! }

    let kind: CloudKind
    private var refreshing: Task<OAuthToken, Error>?

    private init(kind: CloudKind) { self.kind = kind }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let token = OAuthStore.load(kind) else {
            throw AppError.message(L("尚未連結 %@", kind.title))
        }
        if !forceRefresh, token.expiresAt > Date().addingTimeInterval(60) { return token.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let kind = self.kind
        let task = Task { try await OAuth.refresh(token, kind: kind) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        OAuthStore.save(fresh, kind)
        return fresh.accessToken
    }
}

/// 以 ASWebAuthenticationSession 顯示登入頁（與 Safari 共用登入狀態）
final class OAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresenter()
    private var session: ASWebAuthenticationSession?

    @MainActor
    func run(url: URL, scheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? AppError.message(L("登入失敗：回應無效")))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AppError.message(L("無法開啟登入頁面")))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first ?? ASPresentationAnchor()
        }
    }
}
