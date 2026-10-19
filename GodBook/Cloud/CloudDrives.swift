import Foundation

/// 各家雲端硬碟的共同介面。路徑以元件陣列表示，例如 ["GodBook", "Comics", "nhentai_123", "ch_1.cbz"]。
protocol CloudDrive {
    var kind: CloudKind { get }
    /// 顯示用的帳號名稱；同時驗證連線與權限
    func account() async throws -> String
    func upload(_ file: URL, to path: [String], progress: @escaping @Sendable (Double) -> Void) async throws -> CloudUploadResult
    func download(_ path: [String], remoteId: String?, to destination: URL) async throws
    /// 檔案大小；不存在時回傳 nil
    func size(of path: [String], remoteId: String?) async throws -> Int64?
    /// 刪除檔案或資料夾；本來就不存在也視為成功
    func delete(_ path: [String], remoteId: String?) async throws
}

enum CloudDrives {
    static func drive(_ kind: CloudKind) -> CloudDrive {
        switch kind {
        case .oneDrivePersonal, .oneDriveBusiness: return OneDriveDrive(kind: kind)
        case .googleDrive: return GoogleDriveDrive.shared
        case .webdav: return WebDAVDrive()
        }
    }
}

// MARK: - 共用網路工具

/// 上傳分段時，不讓 URLSession 自動跟隨轉址（Google 的分段上傳以 308 表示「尚未完成」）
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirect()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CloudHTTP {
    enum Body {
        case none
        case data(Data)
        case file(URL)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    static func formEncode(_ form: [String: String]) -> String {
        form.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func json(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// 送出請求：帶入存取權杖；401 時刷新權杖重試一次；429 / 503 依 Retry-After 等待；連線中斷最多重試兩次。
    static func send(_ request: URLRequest, auth: CloudAuth?, body: Body = .none) async throws -> (Data, HTTPURLResponse) {
        var forceRefresh = false
        var retriedAuth = false
        var throttled = 0
        var networkRetries = 0
        while true {
            var current = request
            if let auth {
                let token = try await auth.accessToken(forceRefresh: forceRefresh)
                forceRefresh = false
                current.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let session = HTTP.plainSession
            let data: Data
            let response: URLResponse
            do {
                switch body {
                case .none: (data, response) = try await session.data(for: current, delegate: NoRedirect.shared)
                case .data(let payload): (data, response) = try await session.upload(for: current, from: payload, delegate: NoRedirect.shared)
                case .file(let url): (data, response) = try await session.upload(for: current, fromFile: url, delegate: NoRedirect.shared)
                }
            } catch let error as URLError where error.code != .cancelled && networkRetries < 2 {
                networkRetries += 1
                try await Task.sleep(nanoseconds: UInt64(networkRetries) * 2_000_000_000)
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw AppError.message(L("無效的伺服器回應")) }
            if http.statusCode == 401, auth != nil, !retriedAuth {
                retriedAuth = true
                forceRefresh = true
                continue
            }
            if [429, 503].contains(http.statusCode), throttled < 3 {
                throttled += 1
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(2 << throttled)
                try await Task.sleep(nanoseconds: UInt64(min(max(wait, 1), 30) * 1_000_000_000))
                continue
            }
            return (data, http)
        }
    }

    /// 下載到指定檔案（不讀進記憶體）
    static func download(_ request: URLRequest, auth: CloudAuth?, to destination: URL) async throws {
        var current = request
        if let auth { current.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization") }
        let (temp, response) = try await HTTP.plainSession.download(for: current)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: temp)) ?? Data()
            try? FileManager.default.removeItem(at: temp)
            throw failure(data, response as? HTTPURLResponse)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    /// 把錯誤回應轉成可讀的訊息（Graph 與 Google 都把訊息放在 error.message）
    static func failure(_ data: Data, _ response: HTTPURLResponse?) -> AppError {
        let status = response?.statusCode ?? 0
        let error = json(data)["error"]
        let message = ((error as? [String: Any])?["message"] as? String) ?? (error as? String)
        if status == 401 { return AppError.message(L("雲端登入已失效，請重新連結") + (message.map { "\n\($0)" } ?? "")) }
        if status == 403 { return AppError.message(L("沒有權限存取雲端檔案 (403)") + (message.map { "\n\($0)" } ?? "")) }
        if status == 507 { return AppError.message(L("雲端空間已滿")) }
        if let message, !message.isEmpty { return AppError.message("\(message) (\(status))") }
        return AppError.http(status)
    }
}

// MARK: - OneDrive（個人版與商業版都走 Microsoft Graph）

struct OneDriveDrive: CloudDrive {
    let kind: CloudKind
    private var auth: CloudAuth { CloudAuth.shared(kind) }
    private static let graph = "https://graph.microsoft.com/v1.0"
    /// 分段大小必須是 320 KiB 的倍數（這裡是 10 MiB）
    private static let chunkSize = 320 * 1024 * 32

    private func url(_ path: [String], _ suffix: String = "") throws -> URL {
        let encoded = path.map(CloudHTTP.encode).joined(separator: "/")
        let text = suffix.isEmpty ? "\(Self.graph)/me/drive/root:/\(encoded)" : "\(Self.graph)/me/drive/root:/\(encoded):\(suffix)"
        guard let url = URL(string: text) else { throw AppError.message(L("網址無效")) }
        return url
    }

    private static func result(_ data: Data) -> CloudUploadResult {
        let json = CloudHTTP.json(data)
        return CloudUploadResult(size: (json["size"] as? NSNumber)?.int64Value, remoteId: nil)
    }

    func account() async throws -> String {
        let (data, http) = try await CloudHTTP.send(URLRequest(url: URL(string: "\(Self.graph)/me")!), auth: auth)
        guard http.statusCode == 200 else { throw CloudHTTP.failure(data, http) }
        let me = CloudHTTP.json(data)
        // 確認帳號有 OneDrive（商業版帳號若沒有授權或尚未建立 OneDrive 會失敗）
        let (driveData, driveResponse) = try await CloudHTTP.send(URLRequest(url: URL(string: "\(Self.graph)/me/drive")!), auth: auth)
        guard driveResponse.statusCode == 200 else { throw CloudHTTP.failure(driveData, driveResponse) }
        return (me["userPrincipalName"] as? String) ?? (me["mail"] as? String) ?? (me["displayName"] as? String) ?? kind.title
    }

    func upload(_ file: URL, to path: [String], progress: @escaping @Sendable (Double) -> Void) async throws -> CloudUploadResult {
        let total = CloudHTTP.fileSize(file)
        if total <= 4 << 20 {
            var request = URLRequest(url: try url(path, "/content"))
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, http) = try await CloudHTTP.send(request, auth: auth, body: .file(file))
            guard (200..<300).contains(http.statusCode) else { throw CloudHTTP.failure(data, http) }
            progress(1)
            return Self.result(data)
        }

        // 大檔：建立上傳工作階段後分段上傳（上傳網址已含授權，不需再帶權杖）
        var create = URLRequest(url: try url(path, "/createUploadSession"))
        create.httpMethod = "POST"
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = try JSONSerialization.data(withJSONObject: ["item": ["@microsoft.graph.conflictBehavior": "replace"]])
        let (sessionData, sessionResponse) = try await CloudHTTP.send(create, auth: auth, body: .data(payload))
        guard (200..<300).contains(sessionResponse.statusCode),
              let link = CloudHTTP.json(sessionData)["uploadUrl"] as? String, let uploadURL = URL(string: link) else {
            throw CloudHTTP.failure(sessionData, sessionResponse)
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < total {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            let end = offset + Int64(chunk.count) - 1
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(end)/\(total)", forHTTPHeaderField: "Content-Range")
            let (data, http) = try await CloudHTTP.send(request, auth: nil, body: .data(chunk))
            if http.statusCode == 200 || http.statusCode == 201 {
                progress(1)
                return Self.result(data)
            }
            guard http.statusCode == 202 else { throw CloudHTTP.failure(data, http) }
            offset = end + 1
            progress(Double(offset) / Double(total))
        }
        throw AppError.message(L("上傳未完成"))
    }

    func download(_ path: [String], remoteId: String?, to destination: URL) async throws {
        let (data, http) = try await CloudHTTP.send(URLRequest(url: try url(path)), auth: auth)
        guard http.statusCode == 200 else {
            throw http.statusCode == 404 ? AppError.message(L("雲端找不到這個檔案")) : CloudHTTP.failure(data, http)
        }
        // 下載網址是預先授權的短期網址，不能再帶權杖
        guard let link = CloudHTTP.json(data)["@microsoft.graph.downloadUrl"] as? String, let target = URL(string: link) else {
            throw AppError.message(L("無法取得下載網址"))
        }
        try await CloudHTTP.download(URLRequest(url: target), auth: nil, to: destination)
    }

    func size(of path: [String], remoteId: String?) async throws -> Int64? {
        let (data, http) = try await CloudHTTP.send(URLRequest(url: try url(path)), auth: auth)
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw CloudHTTP.failure(data, http) }
        return (CloudHTTP.json(data)["size"] as? NSNumber)?.int64Value
    }

    func delete(_ path: [String], remoteId: String?) async throws {
        var request = URLRequest(url: try url(path))
        request.httpMethod = "DELETE"
        let (data, http) = try await CloudHTTP.send(request, auth: auth)
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else { throw CloudHTTP.failure(data, http) }
    }
}

// MARK: - Google Drive

/// 使用 drive.file 權限：App 只看得到自己建立的檔案與資料夾，因此用名稱逐層找出資料夾 ID。
final class GoogleDriveDrive: CloudDrive {
    static let shared = GoogleDriveDrive()

    let kind = CloudKind.googleDrive
    private var auth: CloudAuth { CloudAuth.shared(.googleDrive) }
    private let lock = NSLock()
    private var folderIds: [String: String] = [:]

    private static let api = "https://www.googleapis.com/drive/v3/files"
    private static let uploadAPI = "https://www.googleapis.com/upload/drive/v3/files"
    private static let folderType = "application/vnd.google-apps.folder"
    /// 分段大小必須是 256 KiB 的倍數（這裡是 8 MiB）
    private static let chunkSize = 256 * 1024 * 32

    private init() {}

    func resetCache() {
        lock.lock(); folderIds.removeAll(); lock.unlock()
    }

    private func cachedFolder(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return folderIds[key]
    }

    private func cacheFolder(_ key: String, _ id: String?) {
        lock.lock(); defer { lock.unlock() }
        if let id { folderIds[key] = id } else { folderIds = folderIds.filter { !$0.key.hasPrefix(key) } }
    }

    private func find(_ name: String, parent: String, folder: Bool) async throws -> (id: String, size: Int64?)? {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var query = "name = '\(escaped)' and '\(parent)' in parents and trashed = false"
        query += folder ? " and mimeType = '\(Self.folderType)'" : " and mimeType != '\(Self.folderType)'"
        var components = URLComponents(string: Self.api)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,size)"),
            URLQueryItem(name: "pageSize", value: "10"),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw AppError.message(L("網址無效")) }
        let (data, http) = try await CloudHTTP.send(URLRequest(url: url), auth: auth)
        guard http.statusCode == 200 else { throw CloudHTTP.failure(data, http) }
        let files = (CloudHTTP.json(data)["files"] as? [[String: Any]]) ?? []
        guard let first = files.first, let id = first["id"] as? String else { return nil }
        return (id, Int64(first["size"] as? String ?? ""))
    }

    private func createFolder(_ name: String, parent: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.api)?fields=id")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderType, "parents": [parent]])
        let (data, http) = try await CloudHTTP.send(request, auth: auth, body: .data(body))
        guard (200..<300).contains(http.statusCode), let id = CloudHTTP.json(data)["id"] as? String else {
            throw CloudHTTP.failure(data, http)
        }
        return id
    }

    /// 逐層找出（或建立）資料夾，回傳最後一層的 ID
    private func folderId(_ path: [String], create: Bool) async throws -> String? {
        var parent = "root"
        for index in path.indices {
            let key = path[...index].joined(separator: "/")
            if let cached = cachedFolder(key) { parent = cached; continue }
            if let found = try await find(path[index], parent: parent, folder: true) {
                parent = found.id
            } else if create {
                parent = try await createFolder(path[index], parent: parent)
            } else {
                return nil
            }
            cacheFolder(key, parent)
        }
        return parent
    }

    private func fileId(_ path: [String]) async throws -> (id: String, size: Int64?)? {
        guard let name = path.last, let parent = try await folderId(Array(path.dropLast()), create: false) else { return nil }
        return try await find(name, parent: parent, folder: false)
    }

    func account() async throws -> String {
        let url = URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress,displayName)")!
        let (data, http) = try await CloudHTTP.send(URLRequest(url: url), auth: auth)
        guard http.statusCode == 200 else { throw CloudHTTP.failure(data, http) }
        let user = CloudHTTP.json(data)["user"] as? [String: Any]
        return (user?["emailAddress"] as? String) ?? (user?["displayName"] as? String) ?? "Google Drive"
    }

    func upload(_ file: URL, to path: [String], progress: @escaping @Sendable (Double) -> Void) async throws -> CloudUploadResult {
        guard let name = path.last, let parent = try await folderId(Array(path.dropLast()), create: true) else {
            throw AppError.message(L("網址無效"))
        }
        let total = CloudHTTP.fileSize(file)

        // 建立分段上傳工作階段；同名檔案已存在時改為更新內容
        var initiate: URLRequest
        let metadata: [String: Any]
        if let existing = try await find(name, parent: parent, folder: false) {
            initiate = URLRequest(url: URL(string: "\(Self.uploadAPI)/\(existing.id)?uploadType=resumable&fields=id,size")!)
            initiate.httpMethod = "PATCH"
            metadata = [:]
        } else {
            initiate = URLRequest(url: URL(string: "\(Self.uploadAPI)?uploadType=resumable&fields=id,size")!)
            initiate.httpMethod = "POST"
            metadata = ["name": name, "parents": [parent]]
        }
        initiate.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initiate.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        initiate.setValue(String(total), forHTTPHeaderField: "X-Upload-Content-Length")
        let (sessionData, sessionResponse) = try await CloudHTTP.send(initiate, auth: auth,
                                                                     body: .data(try JSONSerialization.data(withJSONObject: metadata)))
        guard sessionResponse.statusCode == 200,
              let location = sessionResponse.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location) else {
            throw CloudHTTP.failure(sessionData, sessionResponse)
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < total {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            let end = offset + Int64(chunk.count) - 1
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(end)/\(total)", forHTTPHeaderField: "Content-Range")
            let (data, http) = try await CloudHTTP.send(request, auth: nil, body: .data(chunk))
            if http.statusCode == 200 || http.statusCode == 201 {
                progress(1)
                let json = CloudHTTP.json(data)
                return CloudUploadResult(size: Int64(json["size"] as? String ?? ""), remoteId: json["id"] as? String)
            }
            guard http.statusCode == 308 else { throw CloudHTTP.failure(data, http) }
            // 308 = 尚未完成；Range 標頭是伺服器已收到的範圍（bytes=0-N）
            if let range = http.value(forHTTPHeaderField: "Range"), let last = range.split(separator: "-").last, let received = Int64(last) {
                offset = received + 1
            } else {
                offset = end + 1
            }
            progress(Double(offset) / Double(total))
        }
        throw AppError.message(L("上傳未完成"))
    }

    func download(_ path: [String], remoteId: String?, to destination: URL) async throws {
        var id = remoteId
        if id == nil { id = try await fileId(path)?.id }
        guard let id, let url = URL(string: "\(Self.api)/\(id)?alt=media") else {
            throw AppError.message(L("雲端找不到這個檔案"))
        }
        try await CloudHTTP.download(URLRequest(url: url), auth: auth, to: destination)
    }

    func size(of path: [String], remoteId: String?) async throws -> Int64? {
        guard let remoteId else { return try await fileId(path)?.size }
        let (data, http) = try await CloudHTTP.send(URLRequest(url: URL(string: "\(Self.api)/\(remoteId)?fields=size,trashed")!), auth: auth)
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw CloudHTTP.failure(data, http) }
        let json = CloudHTTP.json(data)
        if (json["trashed"] as? Bool) == true { return nil }
        return Int64(json["size"] as? String ?? "")
    }

    func delete(_ path: [String], remoteId: String?) async throws {
        var target = remoteId
        if target == nil { target = try await fileId(path)?.id }
        if target == nil { target = try await folderId(path, create: false) }
        guard let target else { return }
        var request = URLRequest(url: URL(string: "\(Self.api)/\(target)")!)
        request.httpMethod = "DELETE"
        let (data, http) = try await CloudHTTP.send(request, auth: auth)
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else { throw CloudHTTP.failure(data, http) }
        cacheFolder(path.joined(separator: "/"), nil)
    }
}

// MARK: - WebDAV（NAS、Nextcloud 等；使用「快取、備份與 WebDAV」的伺服器設定）

struct WebDAVDrive: CloudDrive {
    let kind = CloudKind.webdav

    private func url(_ path: [String]) throws -> URL {
        let base = AppSettings.shared.webdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, var url = URL(string: base) else { throw AppError.message(L("請先填寫 WebDAV 網址")) }
        for component in path { url.appendPathComponent(component) }
        return url
    }

    private func request(_ method: String, _ path: [String]) throws -> URLRequest {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        let user = AppSettings.shared.webdavUser
        if !user.isEmpty {
            let token = Data("\(user):\(WebDAV.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 逐層建立資料夾（已存在會回 405，忽略）
    private func makeCollections(_ path: [String]) async throws {
        for index in path.indices {
            let (data, http) = try await CloudHTTP.send(try request("MKCOL", Array(path[...index])), auth: nil)
            if http.statusCode == 401 { throw CloudHTTP.failure(data, http) }
        }
    }

    func account() async throws -> String {
        let root = CloudPath.root
        try await makeCollections(root)
        guard try await size(of: root, remoteId: nil) != nil else {
            throw AppError.message(L("無法在 WebDAV 伺服器上建立 %@ 資料夾", root.joined(separator: "/")))
        }
        let host = (try? url([]))?.host ?? "WebDAV"
        let user = AppSettings.shared.webdavUser
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    func upload(_ file: URL, to path: [String], progress: @escaping @Sendable (Double) -> Void) async throws -> CloudUploadResult {
        try await makeCollections(Array(path.dropLast()))
        var put = try request("PUT", path)
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, http) = try await CloudHTTP.send(put, auth: nil, body: .file(file))
        guard (200..<300).contains(http.statusCode) else { throw CloudHTTP.failure(data, http) }
        progress(1)
        return CloudUploadResult(size: nil, remoteId: nil)
    }

    func download(_ path: [String], remoteId: String?, to destination: URL) async throws {
        try await CloudHTTP.download(try request("GET", path), auth: nil, to: destination)
    }

    func size(of path: [String], remoteId: String?) async throws -> Int64? {
        var propfind = try request("PROPFIND", path)
        propfind.setValue("0", forHTTPHeaderField: "Depth")
        propfind.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let body = #"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/></d:prop></d:propfind>"#
        let (data, http) = try await CloudHTTP.send(propfind, auth: nil, body: .data(Data(body.utf8)))
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 207 || http.statusCode == 200 else { throw CloudHTTP.failure(data, http) }
        let text = String(decoding: data, as: UTF8.self)
        // 資料夾沒有 getcontentlength，回傳 0 代表存在
        guard let range = text.range(of: #"getcontentlength>\s*(\d+)\s*<"#, options: [.regularExpression, .caseInsensitive]) else { return 0 }
        return Int64(text[range].filter(\.isNumber)) ?? 0
    }

    func delete(_ path: [String], remoteId: String?) async throws {
        let (data, http) = try await CloudHTTP.send(try request("DELETE", path), auth: nil)
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else { throw CloudHTTP.failure(data, http) }
    }
}
