import Foundation

enum HTTP {
    private static let lock = NSLock()
    private static var cachedSession = NetworkManager.makeSession(cached: true)
    private static var uncachedSession = NetworkManager.makeSession(cached: false)
    private static var tcpSessionStore = NetworkManager.makeSession(cached: false, tcpOnly: true)
    private static var directSessionStore = NetworkManager.makeSession(cached: false, tcpOnly: true, direct: true)

    /// 一般 API 請求（有 URL 快取）
    static var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        return cachedSession
    }

    /// 不使用快取的連線（漫畫源腳本、登入等）
    static var plainSession: URLSession {
        lock.lock(); defer { lock.unlock() }
        return uncachedSession
    }

    /// 只走 TCP（不使用 HTTP/3）的連線；某些網路環境下 QUIC 會出現 -1103 之類的怪錯誤，用來重試
    static var tcpSession: URLSession {
        lock.lock(); defer { lock.unlock() }
        return tcpSessionStore
    }

    /// 只走 TCP 且不經過任何代理的連線（最後的重試手段）
    static var directSession: URLSession {
        lock.lock(); defer { lock.unlock() }
        return directSessionStore
    }

    /// 代理或憑證設定變更後重新建立連線
    static func reload() {
        lock.lock()
        let old = [cachedSession, uncachedSession, tcpSessionStore, directSessionStore]
        cachedSession = NetworkManager.makeSession(cached: true)
        uncachedSession = NetworkManager.makeSession(cached: false)
        tcpSessionStore = NetworkManager.makeSession(cached: false, tcpOnly: true)
        directSessionStore = NetworkManager.makeSession(cached: false, tcpOnly: true, direct: true)
        lock.unlock()
        old.forEach { $0.finishTasksAndInvalidate() }
    }

    /// 各主機目前需要的連線方式：0 = 一般、1 = 只走 TCP、2 = 自己用 Network.framework 收發。
    /// 某個主機出現 -1103 後，之後的請求直接從有效的那一層開始，不用每次都先失敗再重試。
    private static var hostLevels: [String: Int] = [:]
    private static var bridgeLevels: [String: Int] = [:]

    private static func level(for host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return hostLevels[host] ?? 0
    }

    private static func remember(level: Int, for host: String) {
        lock.lock(); defer { lock.unlock() }
        if level > (hostLevels[host] ?? 0) { hostLevels[host] = level }
    }

    /// 漫畫源腳本請求的起始層級（0 一般、1 不壓縮+TCP、2 再加直連、3 自己收發）
    static func bridgeLevel(for host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return bridgeLevels[host] ?? 0
    }

    static func rememberBridge(level: Int, for host: String) {
        lock.lock(); defer { lock.unlock() }
        if level > (bridgeLevels[host] ?? 0) { bridgeLevels[host] = level }
    }

    static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? ""
        var current = level(for: host)
        while true {
            do {
                let result = try await perform(request, level: current)
                remember(level: current, for: host)
                return result
            } catch let error as URLError where error.code.rawValue == -1103 && current < 2 {
                // 某些網路環境下系統網路層會回 -1103：依序改用「只走 TCP」與「完全不用 URLSession」的連線重試
                current += 1
            }
        }
    }

    private static func perform(_ request: URLRequest, level: Int) async throws -> (Data, HTTPURLResponse) {
        if level >= 2 {
            let reply = try await RawHTTP.fetch(request)
            guard let url = request.url,
                  let http = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
                throw AppError.message(L("無效的伺服器回應"))
            }
            return (reply.body, http)
        }
        let (data, response) = try await (level == 1 ? tcpSession : session).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.message(L("無效的伺服器回應")) }
        return (data, http)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message(L("無法解析伺服器資料"))
        }
        return object
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let n = self[key] as? Int { return n }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    func dicts(_ key: String) -> [[String: Any]] {
        (self[key] as? [[String: Any]]) ?? []
    }

    func strings(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue } ?? []
    }
}
