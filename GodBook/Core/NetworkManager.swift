import Foundation

/// 伺服器憑證驗證：使用者開啟「忽略憑證錯誤」時接受任何憑證。
final class TrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    /// 最近一次請求的連線資訊（協定、是否經過代理、收到的位元組…），失敗時附在錯誤訊息裡方便排查
    private static let lock = NSLock()
    private static var metricsByTask: [Int: String] = [:]

    static func metrics(for taskID: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return metricsByTask.removeValue(forKey: taskID)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        var parts = [last.networkProtocolName ?? "?"]
        if last.isProxyConnection { parts.append("proxy") }
        parts.append("rx\(last.countOfResponseBodyBytesReceived)")
        if let http = last.response as? HTTPURLResponse {
            parts.append("\(http.statusCode)")
            if let length = http.value(forHTTPHeaderField: "Content-Length") { parts.append("cl\(length)") }
            if let encoding = http.value(forHTTPHeaderField: "Content-Encoding") { parts.append(encoding) }
        }
        Self.lock.lock()
        Self.metricsByTask[task.taskIdentifier] = parts.joined(separator: ",")
        if Self.metricsByTask.count > 50 { Self.metricsByTask.removeAll() }
        Self.lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if AppSettings.shared.ignoreBadCert,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum NetworkManager {
    /// 依設定（系統 / 直連 / 手動代理）建立 URLSessionConfiguration
    static func makeConfiguration(cached: Bool, tcpOnly: Bool = false, direct: Bool = false) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        // QUIC（HTTP/3）需要 TLS 1.3；限制在 TLS 1.2 就只會走 TCP（HTTP/2 或 1.1）
        if tcpOnly { config.tlsMaximumSupportedProtocolVersion = .TLSv12 }
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        config.httpCookieStorage = HTTPCookieStorage.shared
        if cached {
            config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 200 << 20)
            config.requestCachePolicy = .useProtocolCachePolicy
        } else {
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
        }

        let settings = AppSettings.shared
        switch direct ? "direct" : settings.proxyMode {
        case "direct":
            config.connectionProxyDictionary = [:]
        case "manual":
            let host = settings.proxyHost.trimmingCharacters(in: .whitespaces)
            if let port = Int(settings.proxyPort.trimmingCharacters(in: .whitespaces)), !host.isEmpty {
                if settings.proxyType == "socks5" {
                    config.connectionProxyDictionary = [
                        "SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port,
                    ]
                } else {
                    config.connectionProxyDictionary = [
                        "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                        "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
                    ]
                }
            }
        default:
            break // 系統代理
        }
        return config
    }

    static func makeSession(cached: Bool, tcpOnly: Bool = false, direct: Bool = false) -> URLSession {
        URLSession(configuration: makeConfiguration(cached: cached, tcpOnly: tcpOnly, direct: direct), delegate: TrustDelegate(), delegateQueue: nil)
    }
}
