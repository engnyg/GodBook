import Compression
import Foundation
import Network
import Security

/// 不經過 CFNetwork（URLSession）的簡易 HTTP/1.1 用戶端，直接用 Network.framework 連線。
/// venera 用 Rust 的 reqwest 而不是系統網路層；這裡的做法類似：
/// 當 URLSession 對某些網站回 -1103 時，改用這個自己收發的版本當最後手段。
/// 支援 HTTPS/HTTP、Content-Length / chunked / 連線關閉三種結尾、gzip / deflate、轉址與 Cookie。
enum RawHTTP {
    struct Reply {
        var status: Int
        var headers: [String: String]   // 名稱一律小寫；同名標頭以 ", " 合併
        var body: Data
    }

    enum RawError: LocalizedError {
        case invalid(String)
        case timeout
        var errorDescription: String? {
            switch self {
            case .invalid(let text): return text
            case .timeout: return "timeout"
            }
        }
    }

    static func fetch(_ request: URLRequest, redirects: Int = 5) async throws -> Reply {
        var current = request
        var remaining = redirects
        while true {
            let reply = try await exchange(current)
            if [301, 302, 303, 307, 308].contains(reply.status), remaining > 0,
               let location = reply.headers["location"], let base = current.url,
               let next = URL(string: location, relativeTo: base)?.absoluteURL {
                remaining -= 1
                current.url = next
                if reply.status != 307 && reply.status != 308 {
                    current.httpMethod = "GET"
                    current.httpBody = nil
                }
                continue
            }
            return reply
        }
    }

    // MARK: 收發

    private static func exchange(_ request: URLRequest) async throws -> Reply {
        guard let url = request.url, let host = url.host else { throw RawError.invalid("Invalid URL") }
        let secure = url.scheme?.lowercased() == "https"
        let portNumber = UInt16(url.port ?? (secure ? 443 : 80))
        guard let port = NWEndpoint.Port(rawValue: portNumber) else { throw RawError.invalid("Invalid port") }
        let method = (request.httpMethod ?? "GET").uppercased()
        let payload = buildRequest(request, url: url, host: host, method: method)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters(secure: secure))
        let raw = try await Exchange(connection: connection, payload: payload, method: method).run()
        guard let reply = parse(raw, method: method, eof: true) else { throw RawError.invalid("Invalid response") }
        if let setCookie = reply.headers["set-cookie"] {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookie], for: url) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
        return reply
    }

    private static func parameters(secure: Bool) -> NWParameters {
        guard secure else { return .tcp }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        if AppSettings.shared.ignoreBadCert {
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, DispatchQueue.global())
        }
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private static func buildRequest(_ request: URLRequest, url: URL, host: String, method: String) -> Data {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = comps?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let query = comps?.percentEncodedQuery { target += "?" + query }
        var hostHeader = host
        if let port = url.port { hostHeader += ":\(port)" }

        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(hostHeader)"]
        var present = Set<String>()
        let skipped: Set<String> = ["host", "connection", "accept-encoding", "content-length", "transfer-encoding"]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = key.lowercased()
            if skipped.contains(lower) { continue }
            lines.append("\(key): \(value)")
            present.insert(lower)
        }
        if !present.contains("cookie"), let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty,
           let cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            lines.append("Cookie: \(cookie)")
        }
        if !present.contains("accept") { lines.append("Accept: */*") }
        lines.append("Accept-Encoding: identity")
        lines.append("Connection: close")
        if let body = request.httpBody {
            lines.append("Content-Length: \(body.count)")
        } else if ["POST", "PUT", "PATCH"].contains(method) {
            lines.append("Content-Length: 0")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body = request.httpBody { data.append(body) }
        return data
    }

    // MARK: 解析

    private static let crlf = Data([13, 10])
    private static let headerEnd = Data([13, 10, 13, 10])

    /// 解析回應；資料還不完整時回傳 nil（`eof` 為 true 時一律盡量回傳目前收到的內容）
    fileprivate static func parse(_ data: Data, method: String, eof: Bool) -> Reply? {
        guard let split = data.range(of: headerEnd) else { return nil }
        let head = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self)
        let rest = Data(data[split.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        if status >= 100 && status < 200 && status != 101 {
            return parse(rest, method: method, eof: eof) // 略過 100 Continue 這類中間回應
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }

        var body = Data()
        if method == "HEAD" || status == 204 || status == 304 {
            // 沒有內容
        } else if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
            let (decoded, done) = dechunk(rest)
            guard done || eof else { return nil }
            body = decoded
        } else if let text = headers["content-length"], let length = Int(text) {
            guard rest.count >= length || eof else { return nil }
            body = rest.prefix(length)
        } else {
            guard eof else { return nil }
            body = rest
        }
        if headers["content-encoding"] != nil {
            body = decode(body, encoding: headers["content-encoding"])
            headers["content-encoding"] = nil
            headers["content-length"] = String(body.count)
        }
        return Reply(status: status, headers: headers, body: body)
    }

    private static func dechunk(_ data: Data) -> (Data, Bool) {
        var output = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data[index...].range(of: crlf) else { return (output, false) }
            let sizeLine = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = (sizeLine.split(separator: ";").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16) else { return (output, false) }
            let start = lineEnd.upperBound
            if size == 0 { return (output, true) }
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return (output, false) }
            let end = data.index(start, offsetBy: size)
            output.append(data[start..<end])
            index = data.index(end, offsetBy: 2)
        }
    }

    private static func decode(_ body: Data, encoding: String?) -> Data {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "gzip", "x-gzip":
            return gunzip(body) ?? body
        case "deflate":
            var bytes = body
            if bytes.count > 2, bytes[bytes.startIndex] & 0x0F == 8,
               (Int(bytes[bytes.startIndex]) * 256 + Int(bytes[bytes.startIndex + 1])) % 31 == 0 {
                bytes = Data(bytes.dropFirst(2)) // zlib 外層標頭
            }
            return inflate(bytes) ?? body
        default:
            return body
        }
    }

    private static func inflate(_ data: Data) -> Data? {
        guard let result = try? (data as NSData).decompressed(using: .zlib) else { return nil }
        return result as Data
    }

    private static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { return nil }
        let flags = bytes[3]
        var position = 10
        if flags & 4 != 0 {
            guard position + 2 <= bytes.count else { return nil }
            position += 2 + Int(bytes[position]) + Int(bytes[position + 1]) * 256
        }
        if flags & 8 != 0 { while position < bytes.count && bytes[position] != 0 { position += 1 }; position += 1 }
        if flags & 16 != 0 { while position < bytes.count && bytes[position] != 0 { position += 1 }; position += 1 }
        if flags & 2 != 0 { position += 2 }
        guard position < bytes.count - 8 else { return nil }
        return inflate(Data(bytes[position..<(bytes.count - 8)]))
    }

    // MARK: 連線

    private final class Exchange {
        private let connection: NWConnection
        private let payload: Data
        private let method: String
        private let queue = DispatchQueue(label: "godbook.rawhttp")
        private var buffer = Data()
        private var continuation: CheckedContinuation<Data, Error>?
        private var finished = false

        init(connection: NWConnection, payload: Data, method: String) {
            self.connection = connection
            self.payload = payload
            self.method = method
        }

        func run() async throws -> Data {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                queue.async {
                    self.continuation = cont
                    self.connection.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.connection.send(content: self.payload, completion: .contentProcessed { error in
                                if let error { self.finish(.failure(error)) } else { self.receive() }
                            })
                        case .failed(let error):
                            self.finish(.failure(error))
                        case .waiting(let error):
                            self.finish(.failure(error))
                        default:
                            break
                        }
                    }
                    self.connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 30) { self.finish(.failure(RawError.timeout)) }
                }
            }
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self, !self.finished else { return }
                if let data, !data.isEmpty { self.buffer.append(data) }
                if let error {
                    // 伺服器送完後直接重設連線也算收到完整回應
                    if RawHTTP.parse(self.buffer, method: self.method, eof: true) != nil {
                        self.finish(.success(self.buffer))
                    } else {
                        self.finish(.failure(error))
                    }
                    return
                }
                if isComplete || RawHTTP.parse(self.buffer, method: self.method, eof: false) != nil {
                    self.finish(.success(self.buffer))
                    return
                }
                self.receive()
            }
        }

        private func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
