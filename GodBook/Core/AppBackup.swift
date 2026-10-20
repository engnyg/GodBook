import Foundation

/// 全部 App 資料（收藏、歷史、設定、主題、漫畫源腳本與資料）打包成單一檔案，供匯出 / 匯入 / WebDAV 同步。
enum AppBackup {
    struct Payload: Codable {
        var version = 1
        var date: Date
        var files: [String: Data]
        var defaults: Data
    }

    private static let defaultsPrefixes = ["nh.", "jm.", "reader.", "ui.", "dl.", "theme.", "venera.",
                                           "net.", "lock.", "webdav.", "src.", "lib.", "search.", "list."]
    /// 不放進備份的檔案（下載清單指向本機檔案，換裝置沒有意義）
    private static let excludedFiles: Set<String> = ["downloads.json"]

    static func make() throws -> Data {
        var files: [String: Data] = [:]
        let root = Storage.directory
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = String(url.path.dropFirst(root.path.count + 1))
                guard !excludedFiles.contains(relative), let data = try? Data(contentsOf: url) else { continue }
                files[relative] = data
            }
        }
        let all = UserDefaults.standard.dictionaryRepresentation()
        let filtered = all.filter { key, _ in defaultsPrefixes.contains { key.hasPrefix($0) } }
        let plist = try PropertyListSerialization.data(fromPropertyList: filtered, format: .xml, options: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Payload(date: Date(), files: files, defaults: plist))
    }

    @discardableResult
    static func restore(_ data: Data) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            throw AppError.message(L("這不是有效的 GodBook 備份檔"))
        }
        let root = Storage.directory
        for (relative, content) in payload.files {
            let target = root.appendingPathComponent(relative)
            guard target.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else { continue } // 防止路徑跳脫
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, options: .atomic)
        }
        if let object = try? PropertyListSerialization.propertyList(from: payload.defaults, options: [], format: nil),
           let dict = object as? [String: Any] {
            for (key, value) in dict { UserDefaults.standard.set(value, forKey: key) }
        }
        return payload
    }

    static func exportFile() throws -> URL {
        let data = try make()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GodBook-\(stamp.string(from: Date())).godbook")
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// 以 WebDAV 儲存同一份備份檔。
enum WebDAV {
    private static let fileName = "GodBook-backup.godbook"
    private static let passwordKey = "webdav.password"

    static var password: String {
        get { Keychain.get(passwordKey) ?? "" }
        set { newValue.isEmpty ? Keychain.delete(passwordKey) : Keychain.set(newValue, for: passwordKey) }
    }

    private static func request(_ method: String, path: String = fileName, body: Data? = nil) throws -> URLRequest {
        let settings = AppSettings.shared
        let base = settings.webdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, var url = URL(string: base) else { throw AppError.message(L("請先填寫 WebDAV 網址")) }
        if !path.isEmpty { url.appendPathComponent(path) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if !settings.webdavUser.isEmpty {
            let token = Data("\(settings.webdavUser):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func upload() async throws {
        // 嘗試建立資料夾（已存在會回 405，忽略）
        if let mkcol = try? request("MKCOL", path: "") { _ = try? await HTTP.plainSession.data(for: mkcol) }
        let data = try AppBackup.make()
        let (_, response) = try await HTTP.plainSession.data(for: try request("PUT", body: data))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    static func download() async throws -> Data {
        let (data, response) = try await HTTP.plainSession.data(for: try request("GET"))
        guard let http = response as? HTTPURLResponse else { throw AppError.message(L("無效的回應")) }
        guard http.statusCode == 200 else {
            throw http.statusCode == 404 ? AppError.message(L("伺服器上還沒有備份檔")) : AppError.http(http.statusCode)
        }
        return data
    }
}
