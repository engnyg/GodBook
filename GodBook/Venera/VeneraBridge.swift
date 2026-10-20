import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import Security
import SwiftSoup
import UIKit

// MARK: - 全域輔助（記錄、儲存、點陣圖）

final class VeneraLog {
    static let shared = VeneraLog()
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ level: String, _ title: String, _ content: String) {
        let line = "[\(level)] \(title): \(content)"
        lock.lock()
        lines.append(line)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        lock.unlock()
        print("[Venera]", line)
    }

    func all() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock(); lines = []; lock.unlock()
    }
}

/// 每個漫畫源各自的資料與設定（值皆以 JSON 字串存放）。
final class VeneraStorage {
    static let shared = VeneraStorage()
    private let lock = NSLock()
    private let file = "venera_storage.json"
    private var store: [String: [String: [String: String]]]

    private init() {
        store = Storage.load([String: [String: [String: String]]].self, from: "venera_storage.json") ?? [:]
    }

    private func persist() { Storage.save(store, to: file) }

    func data(_ source: String, _ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[source]?["data"]?[key]
    }

    func setData(_ source: String, _ key: String, _ json: String) {
        lock.lock(); defer { lock.unlock() }
        store[source, default: [:]]["data", default: [:]][key] = json
        persist()
    }

    func deleteData(_ source: String, _ key: String) {
        lock.lock(); defer { lock.unlock() }
        store[source]?["data"]?[key] = nil
        persist()
    }

    func setting(_ source: String, _ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[source]?["settings"]?[key]
    }

    func setSetting(_ source: String, _ key: String, _ json: String) {
        lock.lock(); defer { lock.unlock() }
        store[source, default: [:]]["settings", default: [:]][key] = json
        persist()
    }

    func isLogged(_ source: String) -> Bool {
        data(source, "account") != nil
    }

    func removeAll(_ source: String) {
        lock.lock(); defer { lock.unlock() }
        store[source] = nil
        persist()
    }
}

final class Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt32]

    init(width: Int, height: Int, fill: UInt32 = 0xFFFF_FFFF) {
        self.width = max(1, width)
        self.height = max(1, height)
        pixels = [UInt32](repeating: fill, count: self.width * self.height)
    }

    static func decode(_ data: Data) -> Bitmap? {
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        let bitmap = Bitmap(width: cg.width, height: cg.height, fill: 0)
        let w = bitmap.width, h = bitmap.height
        bitmap.pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bitmap
    }

    func encodeJPEG() -> Data? {
        let w = width, h = height
        var copy = pixels
        let image: CGImage? = copy.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }
        guard let image else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.92)
    }

    func copyRange(x: Int, y: Int, w: Int, h: Int) -> Bitmap {
        let result = Bitmap(width: w, height: h, fill: 0)
        blit(from: self, srcX: x, srcY: y, w: w, h: h, into: result, dstX: 0, dstY: 0)
        return result
    }

    func rotated90() -> Bitmap {
        let result = Bitmap(width: height, height: width, fill: 0)
        for y in 0..<height {
            for x in 0..<width {
                result.pixels[x * result.width + (height - 1 - y)] = pixels[y * width + x]
            }
        }
        return result
    }

    func fill(_ source: Bitmap, atX x: Int, y: Int, srcX: Int = 0, srcY: Int = 0, w: Int? = nil, h: Int? = nil) {
        blit(from: source, srcX: srcX, srcY: srcY, w: w ?? source.width, h: h ?? source.height, into: self, dstX: x, dstY: y)
    }

    private func blit(from src: Bitmap, srcX: Int, srcY: Int, w: Int, h: Int, into dst: Bitmap, dstX: Int, dstY: Int) {
        guard w > 0, h > 0 else { return }
        for row in 0..<h {
            let sy = srcY + row, dy = dstY + row
            guard sy >= 0, sy < src.height, dy >= 0, dy < dst.height else { continue }
            var sx0 = srcX, dx0 = dstX, count = w
            if sx0 < 0 { count += sx0; dx0 -= sx0; sx0 = 0 }
            if dx0 < 0 { count += dx0; sx0 -= dx0; dx0 = 0 }
            count = min(count, src.width - sx0, dst.width - dx0)
            guard count > 0 else { continue }
            for i in 0..<count {
                dst.pixels[dy * dst.width + dx0 + i] = src.pixels[sy * src.width + sx0 + i]
            }
        }
    }
}

final class BitmapRegistry {
    private let lock = NSLock()
    private var items: [Int: Bitmap] = [:]
    private var next = 1

    func add(_ bitmap: Bitmap) -> Int {
        lock.lock(); defer { lock.unlock() }
        let key = next
        next += 1
        items[key] = bitmap
        return key
    }

    func get(_ key: Int) -> Bitmap? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    func remove(_ keys: [Int]) {
        lock.lock(); defer { lock.unlock() }
        for key in keys { items[key] = nil }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}

final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var message: String?

    func show(_ text: String) {
        DispatchQueue.main.async {
            self.message = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if self.message == text { self.message = nil }
            }
        }
    }
}

// MARK: - JS 橋接

final class VeneraBridge {
    private let queue: DispatchQueue
    private weak var context: JSContext?
    let bitmaps = BitmapRegistry()

    private var documents: [Int: Document] = [:]
    private var nodes: [Int: [Int: Node]] = [:]
    private var nextNodeKey: [Int: Int] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func install(into context: JSContext) {
        self.context = context
        let native = JSValue(newObjectIn: context)!

        func bind(_ name: String, _ block: Any) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }

        // 轉碼與雜湊
        bind("utf8Encode", { (text: String) -> String in Data(text.utf8).base64EncodedString() } as @convention(block) (String) -> String)
        bind("utf8Decode", { (b64: String) -> String in
            String(decoding: Data(base64Encoded: b64) ?? Data(), as: UTF8.self)
        } as @convention(block) (String) -> String)
        bind("gbkEncode", { (text: String) -> String in
            (text.data(using: Self.gbk) ?? Data()).base64EncodedString()
        } as @convention(block) (String) -> String)
        bind("gbkDecode", { (b64: String) -> String in
            String(data: Data(base64Encoded: b64) ?? Data(), encoding: Self.gbk) ?? ""
        } as @convention(block) (String) -> String)
        bind("hash", { (alg: String, b64: String) -> String in
            Self.digest(alg, Data(base64Encoded: b64) ?? Data()).base64EncodedString()
        } as @convention(block) (String, String) -> String)
        bind("hmac", { (alg: String, keyB64: String, valueB64: String, asString: Bool) -> String in
            let mac = Self.hmac(alg, key: Data(base64Encoded: keyB64) ?? Data(), data: Data(base64Encoded: valueB64) ?? Data())
            return asString ? mac.map { String(format: "%02x", $0) }.joined() : mac.base64EncodedString()
        } as @convention(block) (String, String, String, Bool) -> String)
        bind("aes", { (mode: String, encrypt: Bool, valueB64: String, keyB64: String, ivB64: String, blockSize: Int) -> String? in
            Self.aes(mode: mode, encrypt: encrypt,
                     value: Data(base64Encoded: valueB64) ?? Data(),
                     key: Data(base64Encoded: keyB64) ?? Data(),
                     iv: Data(base64Encoded: ivB64) ?? Data(),
                     blockSize: blockSize)?.base64EncodedString()
        } as @convention(block) (String, Bool, String, String, String, Int) -> String?)
        bind("rsaDecrypt", { (valueB64: String, key: String) -> String? in
            Self.rsaDecrypt(Data(base64Encoded: valueB64) ?? Data(), pkcs8Base64: key)?.base64EncodedString()
        } as @convention(block) (String, String) -> String?)

        // 網路與 Cookie
        bind("http", { [weak self] (method: String, url: String, headers: String, body: String?, bytes: Bool, resolve: JSValue, reject: JSValue) in
            self?.http(method, url, headers, body, bytes, resolve, reject)
        } as @convention(block) (String, String, String, String?, Bool, JSValue, JSValue) -> Void)
        bind("cookieSet", { (url: String, json: String) in Self.setCookies(url, json) } as @convention(block) (String, String) -> Void)
        bind("cookieGet", { (url: String) -> String in Self.getCookies(url) } as @convention(block) (String) -> String)
        bind("cookieDelete", { (url: String) in Self.deleteCookies(url) } as @convention(block) (String) -> Void)

        // 計時器、記錄、剪貼簿
        bind("delay", { [weak self] (ms: Double, callback: JSValue) in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + max(0, ms) / 1000) { _ = callback.call(withArguments: []) }
        } as @convention(block) (Double, JSValue) -> Void)
        bind("log", { (level: String, title: String, content: String) in
            VeneraLog.shared.add(level, title, content)
        } as @convention(block) (String, String, String) -> Void)
        bind("setClipboard", { (text: String) in
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        } as @convention(block) (String) -> Void)
        bind("getClipboard", { () -> String in
            var text = ""
            DispatchQueue.main.sync { text = UIPasteboard.general.string ?? "" }
            return text
        } as @convention(block) () -> String)

        // 儲存
        bind("loadData", { (source: String, key: String) -> String? in VeneraStorage.shared.data(source, key) } as @convention(block) (String, String) -> String?)
        bind("saveData", { (source: String, key: String, json: String) in VeneraStorage.shared.setData(source, key, json) } as @convention(block) (String, String, String) -> Void)
        bind("deleteData", { (source: String, key: String) in VeneraStorage.shared.deleteData(source, key) } as @convention(block) (String, String) -> Void)
        bind("loadSetting", { (source: String, key: String) -> String? in VeneraStorage.shared.setting(source, key) } as @convention(block) (String, String) -> String?)
        bind("isLogged", { (source: String) -> Bool in VeneraStorage.shared.isLogged(source) } as @convention(block) (String) -> Bool)

        // HTML
        bind("html", { [weak self] (fn: String, doc: Int, node: Int, arg: String) -> String? in
            self?.html(fn, doc, node, arg)
        } as @convention(block) (String, Int, Int, String) -> String?)

        // 圖片
        bind("image", { [weak self] (fn: String, argsJSON: String) -> JSValue? in
            guard let self, let context = JSContext.current() else { return nil }
            return self.image(fn, argsJSON, context)
        } as @convention(block) (String, String) -> JSValue?)

        // UI
        bind("uiMessage", { (text: String) in ToastCenter.shared.show(text) } as @convention(block) (String) -> Void)
        bind("uiLaunch", { (url: String) in
            DispatchQueue.main.async { if let u = URL(string: url) { UIApplication.shared.open(u) } }
        } as @convention(block) (String) -> Void)
        bind("uiDialog", { [weak self] (title: String, content: String, actions: String, callback: JSValue) in
            self?.dialog(title, content, actions, callback)
        } as @convention(block) (String, String, String, JSValue) -> Void)
        bind("uiInput", { [weak self] (title: String, callback: JSValue) in
            self?.input(title, callback)
        } as @convention(block) (String, JSValue) -> Void)
        bind("uiSelect", { [weak self] (title: String, options: String, callback: JSValue) in
            self?.select(title, options, callback)
        } as @convention(block) (String, String, JSValue) -> Void)

        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    // MARK: 編碼 / 加密

    private static let gbk: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()

    private static func digest(_ alg: String, _ data: Data) -> Data {
        switch alg {
        case "md5": return Data(Insecure.MD5.hash(data: data))
        case "sha1": return Data(Insecure.SHA1.hash(data: data))
        case "sha512": return Data(SHA512.hash(data: data))
        default: return Data(SHA256.hash(data: data))
        }
    }

    private static func hmac(_ alg: String, key: Data, data: Data) -> Data {
        let k = SymmetricKey(data: key)
        switch alg {
        case "md5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: k))
        case "sha1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
        case "sha512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: k))
        default: return Data(HMAC<SHA256>.authenticationCode(for: data, using: k))
        }
    }

    /// AES 區塊加解密（不含 padding，與原生 block cipher 行為一致）
    private static func aes(mode: String, encrypt: Bool, value: Data, key: Data, iv: Data, blockSize: Int) -> Data? {
        let ccMode: Int
        switch mode {
        case "ecb": ccMode = kCCModeECB
        case "cbc": ccMode = kCCModeCBC
        case "cfb": ccMode = blockSize == 1 ? kCCModeCFB8 : kCCModeCFB
        case "ofb": ccMode = kCCModeOFB
        default: return nil
        }
        var cryptor: CCCryptorRef?
        let ivBytes = [UInt8](iv.isEmpty ? Data(count: 16) : iv)
        let status = key.withUnsafeBytes { keyPtr in
            CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(ccMode),
                                    CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                    mode == "ecb" ? nil : ivBytes, keyPtr.baseAddress, key.count,
                                    nil, 0, 0, CCModeOptions(0), &cryptor)
        }
        guard status == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: value.count + 32)
        var moved = 0
        let capacity = output.count
        let updateStatus = value.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                CCCryptorUpdate(cryptor, input.baseAddress, value.count, out.baseAddress, capacity, &moved)
            }
        }
        guard updateStatus == kCCSuccess else { return nil }
        return Data(output[0..<moved])
    }

    /// RSA(PKCS#1 v1.5) 私鑰解密。key 為 Base64 的 PKCS#8 私鑰，會依區塊大小逐段解密。
    private static func rsaDecrypt(_ value: Data, pkcs8Base64: String) -> Data? {
        let cleaned = pkcs8Base64
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: cleaned), let pkcs1 = extractPKCS1(from: der) else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else { return nil }
        let blockSize = SecKeyGetBlockSize(secKey)
        var result = Data()
        var offset = 0
        while offset < value.count {
            let chunk = value.subdata(in: offset..<min(offset + blockSize, value.count))
            guard let plain = SecKeyCreateDecryptedData(secKey, .rsaEncryptionPKCS1, chunk as CFData, &error) else { return nil }
            result.append(plain as Data)
            offset += blockSize
        }
        return result
    }

    /// PKCS#8 = SEQUENCE { INTEGER, SEQUENCE, OCTET STRING(PKCS#1 key) }，取出第三個元素的內容。
    private static func extractPKCS1(from der: Data) -> Data? {
        let bytes = [UInt8](der)
        var index = 0

        func readLength() -> Int? {
            guard index < bytes.count else { return nil }
            let first = Int(bytes[index]); index += 1
            if first < 0x80 { return first }
            let count = first & 0x7F
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            var length = 0
            for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
            return length
        }

        guard index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1
        guard readLength() != nil else { return nil }
        for position in 0..<3 {
            guard index < bytes.count else { return nil }
            index += 1 // tag
            guard let length = readLength(), index + length <= bytes.count else { return nil }
            if position == 2 { return Data(bytes[index..<(index + length)]) }
            index += length
        }
        return nil
    }

    // MARK: 網路

    private func http(_ method: String, _ urlString: String, _ headersJSON: String, _ body: String?,
                      _ bytes: Bool, _ resolve: JSValue, _ reject: JSValue, attempt startAttempt: Int? = nil) {
        guard let url = URL(string: urlString) ?? URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "%#"))) ?? "") else {
            queue.async { _ = reject.call(withArguments: ["Invalid URL: \(urlString)"]) }
            return
        }
        let attempt = startAttempt ?? HTTP.bridgeLevel(for: url.host ?? "")
        var request = URLRequest(url: url)
        request.httpMethod = method
        // 這些標頭必須交給系統處理：手動指定 Accept-Encoding 會讓 URLSession 不再自動解壓縮
        //（腳本常帶 "gzip, deflate, br, zstd"，結果收到壓縮資料或 -1103 resource exceeds maximum size）
        let managedHeaders: Set<String> = ["accept-encoding", "content-length", "host", "connection", "transfer-encoding", "http_client"]
        if let data = headersJSON.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in headers where !managedHeaders.contains(key.lowercased()) {
                request.setValue("\(value)", forHTTPHeaderField: key)
            }
        }
        request.assumesHTTP3Capable = false
        // -1103（resource exceeds maximum size）多半是系統在解壓縮時判定壓縮比過高；
        // 第一次失敗時改要求不壓縮的內容，並改用只走 TCP（不用 HTTP/3）的連線重試
        if attempt > 0 { request.setValue("identity", forHTTPHeaderField: "Accept-Encoding") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        }
        if let body, let data = Data(base64Encoded: body) { request.httpBody = data }

        let queue = self.queue
        let host = url.host ?? ""
        let logPath = url.path
        let sensitive = ["login", "sign-in", "signin", "auth", "token", "password"].contains { logPath.lowercased().contains($0) }
        let deliver: (Int, [String: String], Data) -> Void = { status, headers, payload in
            // 腳本常只丟出「Invalid status code: 400」，在執行記錄補上伺服器實際回了什麼，方便排查
            if status >= 400 {
                let snippet = sensitive ? "" : String(String(decoding: payload.prefix(300), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: " ").prefix(200))
                VeneraLog.shared.add("warn", "HTTP \(status) \(method) \(host)\(logPath)", snippet)
            }
            let result: [String: Any] = [
                "status": status,
                "headers": headers,
                "body": bytes ? payload.base64EncodedString() : String(decoding: payload, as: UTF8.self),
            ]
            let json = (try? JSONSerialization.data(withJSONObject: result)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            queue.async { _ = resolve.call(withArguments: [json]) }
        }

        // 第 1 次：一般連線；第 2 次：不壓縮 + 只走 TCP；第 3 次：再加上不經過任何代理；
        // 第 4 次：完全不用系統網路層（URLSession），自己用 Network.framework 收發（venera 也不是用系統網路層）
        if attempt >= 3 {
            let finalRequest = request
            Task.detached {
                do {
                    let reply = try await RawHTTP.fetch(finalRequest)
                    HTTP.rememberBridge(level: 3, for: host)
                    deliver(reply.status, reply.headers, reply.body)
                } catch {
                    let message = "\(host)：\(error.localizedDescription) #4"
                    queue.async { _ = reject.call(withArguments: [message]) }
                }
            }
            return
        }

        let session = attempt == 0 ? HTTP.plainSession : (attempt == 1 ? HTTP.tcpSession : HTTP.directSession)
        var taskID = 0
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                let code = (error as NSError).code
                if code == -1103, attempt < 3 {
                    self.http(method, urlString, headersJSON, body, bytes, resolve, reject, attempt: attempt + 1)
                    return
                }
                let info = TrustDelegate.metrics(for: taskID).map { " [\($0)]" } ?? ""
                let message = "\(host)：\(error.localizedDescription) (\(code))\(info) #\(attempt + 1)"
                queue.async { _ = reject.call(withArguments: [message]) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                queue.async { _ = reject.call(withArguments: ["Invalid response"]) }
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers["\(key)".lowercased()] = "\(value)" }
            if attempt > 0 { HTTP.rememberBridge(level: attempt, for: host) }
            deliver(http.statusCode, headers, data ?? Data())
        }
        taskID = task.taskIdentifier
        task.resume()
    }

    private static func setCookies(_ urlString: String, _ json: String) {
        guard let url = URL(string: urlString),
              let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for item in list {
            guard let name = item["name"] as? String, let value = item["value"] as? String else { continue }
            let domain = (item["domain"] as? String) ?? url.host ?? ""
            if let cookie = HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"]) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    private static func getCookies(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "[]" }
        let list = (HTTPCookieStorage.shared.cookies(for: url) ?? []).map {
            ["name": $0.name, "value": $0.value, "domain": $0.domain]
        }
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func deleteCookies(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    // MARK: HTML

    private func html(_ fn: String, _ docKey: Int, _ nodeKey: Int, _ arg: String) -> String? {
        func encode(_ value: Any?) -> String? {
            guard let value else { return nil }
            guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
                  var text = String(data: data, encoding: .utf8) else { return nil }
            text.removeFirst(); text.removeLast() // 去掉外層陣列的 []
            return text
        }

        func register(_ node: Node) -> Int {
            let key = nextNodeKey[docKey, default: 0]
            nextNodeKey[docKey] = key + 1
            nodes[docKey, default: [:]][key] = node
            return key
        }

        if fn == "parse" {
            documents[docKey] = try? SwiftSoup.parse(arg)
            nodes[docKey] = [:]
            nextNodeKey[docKey] = 0
            return nil
        }
        if fn == "dispose" {
            documents[docKey] = nil; nodes[docKey] = nil; nextNodeKey[docKey] = nil
            return nil
        }
        guard let document = documents[docKey] else { return nil }
        let node: Node? = nodeKey < 0 ? document : nodes[docKey]?[nodeKey]
        guard let node else { return nil }
        let element = node as? Element

        switch fn {
        case "querySelector":
            guard let element, let found = try? element.select(arg).first() else { return nil }
            return encode(register(found))
        case "querySelectorAll":
            guard let element, let list = try? element.select(arg) else { return encode([Int]()) }
            return encode(list.array().map { register($0) })
        case "getElementById":
            guard let element, let found = try? element.getElementById(arg) else { return nil }
            return encode(register(found))
        case "text":
            return encode((try? element?.text()) ?? "")
        case "attributes":
            var map: [String: String] = [:]
            if let attributes = element?.getAttributes() {
                for attribute in attributes.asList() { map[attribute.getKey()] = attribute.getValue() }
            }
            return encode(map)
        case "children":
            return encode((element?.children().array() ?? []).map { register($0) })
        case "nodes":
            return encode(node.getChildNodes().map { register($0) })
        case "parent":
            guard let parent = node.parent() else { return nil }
            return encode(register(parent))
        case "innerHtml":
            return encode((try? element?.html()) ?? "")
        case "classNames":
            return encode(Array((try? element?.classNames()) ?? []))
        case "id":
            guard let element else { return nil }
            let id = element.id()
            return id.isEmpty ? nil : encode(id)
        case "localName":
            return encode(element?.tagName().lowercased() ?? "")
        case "previousSibling":
            guard let previous = try? element?.previousElementSibling() else { return nil }
            return encode(register(previous))
        case "nextSibling":
            guard let next = try? element?.nextElementSibling() else { return nil }
            return encode(register(next))
        case "nodeType":
            if node is Document { return encode("document") }
            if node is Element { return encode("element") }
            if node is TextNode { return encode("text") }
            if node is Comment { return encode("comment") }
            return encode("unknown")
        case "nodeText":
            if let text = node as? TextNode { return encode(text.getWholeText()) }
            if let comment = node as? Comment { return encode(comment.getData()) }
            return encode((try? element?.text()) ?? "")
        case "nodeToElement":
            guard node is Element else { return nil }
            return encode(register(node))
        default:
            return nil
        }
    }

    // MARK: 圖片

    private func image(_ fn: String, _ argsJSON: String, _ context: JSContext) -> JSValue? {
        guard let data = argsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        func int(_ index: Int) -> Int { (args[safe: index] as? NSNumber)?.intValue ?? 0 }
        let registry = bitmaps

        switch fn {
        case "emptyImage":
            return JSValue(int32: Int32(registry.add(Bitmap(width: int(0), height: int(1)))), in: context)
        case "getWidth":
            return registry.get(int(0)).map { JSValue(int32: Int32($0.width), in: context) }
        case "getHeight":
            return registry.get(int(0)).map { JSValue(int32: Int32($0.height), in: context) }
        case "copyRange":
            guard let bitmap = registry.get(int(0)) else { return JSValue(nullIn: context) }
            let copy = bitmap.copyRange(x: int(1), y: int(2), w: int(3), h: int(4))
            return JSValue(int32: Int32(registry.add(copy)), in: context)
        case "copyAndRotate90":
            guard let bitmap = registry.get(int(0)) else { return JSValue(nullIn: context) }
            return JSValue(int32: Int32(registry.add(bitmap.rotated90())), in: context)
        case "fillImageAt":
            if let target = registry.get(int(0)), let source = registry.get(int(3)) {
                target.fill(source, atX: int(1), y: int(2))
            }
            return JSValue(undefinedIn: context)
        case "fillImageRangeAt":
            if let target = registry.get(int(0)), let source = registry.get(int(3)) {
                target.fill(source, atX: int(1), y: int(2), srcX: int(4), srcY: int(5), w: int(6), h: int(7))
            }
            return JSValue(undefinedIn: context)
        default:
            return JSValue(nullIn: context)
        }
    }

    // MARK: UI

    private func dialog(_ title: String, _ content: String, _ actionsJSON: String, _ callback: JSValue) {
        let actions = ((try? JSONSerialization.jsonObject(with: Data(actionsJSON.utf8))) as? [[String: Any]]) ?? []
        let queue = self.queue
        DispatchQueue.main.async {
            let alert = UIAlertController(title: title, message: content, preferredStyle: .alert)
            if actions.isEmpty {
                alert.addAction(UIAlertAction(title: L("好"), style: .default))
            }
            for (index, action) in actions.enumerated() {
                let style: UIAlertAction.Style = (action["style"] as? String) == "danger" ? .destructive : .default
                alert.addAction(UIAlertAction(title: action["text"] as? String ?? "OK", style: style) { _ in
                    queue.async { _ = callback.call(withArguments: [index]) }
                })
            }
            UIApplication.topViewController()?.present(alert, animated: true)
        }
    }

    private func input(_ title: String, _ callback: JSValue) {
        let queue = self.queue
        DispatchQueue.main.async {
            let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
            alert.addTextField()
            alert.addAction(UIAlertAction(title: L("取消"), style: .cancel) { _ in
                queue.async { _ = callback.call(withArguments: [NSNull()]) }
            })
            alert.addAction(UIAlertAction(title: L("確定"), style: .default) { _ in
                let text = alert.textFields?.first?.text ?? ""
                queue.async { _ = callback.call(withArguments: [text]) }
            })
            UIApplication.topViewController()?.present(alert, animated: true)
        }
    }

    private func select(_ title: String, _ optionsJSON: String, _ callback: JSValue) {
        let options = ((try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [Any])?.map { "\($0)" } ?? []
        let queue = self.queue
        DispatchQueue.main.async {
            let sheet = UIAlertController(title: title, message: nil, preferredStyle: .alert)
            for (index, option) in options.enumerated() {
                sheet.addAction(UIAlertAction(title: option, style: .default) { _ in
                    queue.async { _ = callback.call(withArguments: [index]) }
                })
            }
            sheet.addAction(UIAlertAction(title: L("取消"), style: .cancel) { _ in
                queue.async { _ = callback.call(withArguments: [-1]) }
            })
            UIApplication.topViewController()?.present(sheet, animated: true)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension UIApplication {
    static func topViewController() -> UIViewController? {
        let scene = shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
