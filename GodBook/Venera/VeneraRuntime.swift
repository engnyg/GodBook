import Foundation
import JavaScriptCore

/// 在專屬序列佇列上執行 JavaScriptCore，並把 Promise 轉成 Swift async。
///
/// 每個漫畫源有自己的 JSContext（共用同一個 JSVirtualMachine 以節省記憶體）：
/// 腳本之間互相看不到對方的物件，原生的資料存取也綁定在該漫畫源上。
final class VeneraRuntime {
    static let shared = VeneraRuntime()

    private let queue = DispatchQueue(label: "godbook.venera.js", qos: .userInitiated)
    private let machine: JSVirtualMachine = JSVirtualMachine()
    /// 以下只能在 queue 上存取
    private var contexts: [String: JSContext] = [:]
    private var bridges: [String: VeneraBridge] = [:]

    /// 腳本沒有回應（Promise 一直沒有結果）時的上限
    private static let timeout: TimeInterval = 180

    /// 圖片還原（modifyImage）的執行佇列：最多同時 3 張，不佔用 GCD 的共用執行緒
    private static let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "godbook.venera.image"
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: 建立 context

    static func makeContext(queue: DispatchQueue, machine: JSVirtualMachine = JSVirtualMachine()) -> (JSContext, VeneraBridge) {
        let context = JSContext(virtualMachine: machine)!
        context.exceptionHandler = { ctx, exception in
            ctx?.exception = exception
            VeneraLog.shared.add("error", "JS", exception?.toString() ?? "unknown exception")
        }
        let bridge = VeneraBridge(queue: queue)
        bridge.install(into: context)
        context.evaluateScript(VeneraPrelude.source)
        context.exception = nil
        return (context, bridge)
    }

    /// 只能在 queue 上呼叫：取得（必要時建立並載入）某個漫畫源專屬的 JS 環境
    private func context(for key: String) throws -> JSContext {
        if let context = contexts[key] { return context }
        guard let js = VeneraFiles.read(key) else { throw AppError.message(L("找不到漫畫源腳本：%@", "\(key)")) }
        let (ctx, bridge) = Self.makeContext(queue: queue, machine: machine)
        bridge.bind(source: key)
        ctx.exception = nil
        let loaded = ctx.evaluateScript("__loadSource(\(jsLiteral(js)))")
        if let exception = ctx.exception {
            ctx.exception = nil
            throw AppError.message(L("載入漫畫源失敗：%@", "\(exception.toString() ?? "")"))
        }
        guard loaded?.toString() == key else {
            throw AppError.message(L("載入漫畫源失敗：%@", L("腳本的 key 與檔名不符")))
        }
        contexts[key] = ctx
        bridges[key] = bridge
        return ctx
    }

    // MARK: 執行

    /// 在指定漫畫源的環境執行一段會產生值（或 Promise）的 JS 運算式，回傳 JSON 解碼後的結果。
    func evaluate(_ expression: String, source key: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            queue.async {
                do {
                    let ctx = try self.context(for: key)
                    self.run(expression, in: ctx, continuation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 只能在 queue 上呼叫
    private func run(_ expression: String, in ctx: JSContext, _ continuation: CheckedContinuation<Any?, Error>) {
        let completion = Completion(continuation)
        let succeed: @convention(block) (String?) -> Void = { json in completion.finish(.success(Self.parse(json))) }
        let fail: @convention(block) (String?) -> Void = { message in
            completion.finish(.failure(AppError.message(message ?? L("腳本執行失敗"))))
        }

        ctx.exception = nil
        let thunk = ctx.evaluateScript("(function(){ return (\(expression)); })")
        if let exception = ctx.exception {
            ctx.exception = nil
            completion.finish(.failure(AppError.message(exception.toString() ?? L("腳本錯誤"))))
            return
        }
        let runner = ctx.objectForKeyedSubscript("__run")
        runner?.call(withArguments: [thunk as Any, succeed, fail])
        if let exception = ctx.exception {
            ctx.exception = nil
            completion.finish(.failure(AppError.message(exception.toString() ?? L("腳本錯誤"))))
            return
        }
        queue.asyncAfter(deadline: .now() + Self.timeout) {
            completion.finish(.failure(AppError.message(L("漫畫源腳本沒有回應（逾時）"))))
        }
    }

    /// 一次性的回報：成功、失敗與逾時都發生在 queue 上，只採用第一個結果
    private final class Completion {
        private var continuation: CheckedContinuation<Any?, Error>?

        init(_ continuation: CheckedContinuation<Any?, Error>) { self.continuation = continuation }

        func finish(_ result: Result<Any?, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private static func parse(_ json: String?) -> Any? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value is NSNull ? nil : value
    }

    // MARK: 高階 API

    /// 在新的環境載入腳本並取得描述；成功後取代該漫畫源原本的環境。
    func install(js: String) async throws -> VeneraInfo {
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            queue.async {
                let (ctx, bridge) = Self.makeContext(queue: self.queue, machine: self.machine)
                ctx.exception = nil
                let loaded = ctx.evaluateScript("__loadSource(\(jsLiteral(js)))")
                if let exception = ctx.exception {
                    ctx.exception = nil
                    continuation.resume(throwing: AppError.message(L("載入漫畫源失敗：%@", "\(exception.toString() ?? "")")))
                    return
                }
                // __loadSource 會把環境綁定到腳本的 key；腳本若事先綁到別的 key，代表想讀其他漫畫源的資料
                guard let key = loaded?.toString(), bridge.boundKey == key else {
                    continuation.resume(throwing: AppError.message(L("載入漫畫源失敗：%@", L("腳本試圖存取其他漫畫源的資料"))))
                    return
                }
                self.contexts[key] = ctx
                self.bridges[key] = bridge
                self.run("__describe(\(jsLiteral(key)))", in: ctx, continuation)
            }
        }
        return try Self.decodeInfo(result)
    }

    func describe(key: String) async throws -> VeneraInfo {
        let result = try await evaluate("__describe(\(jsLiteral(key)))", source: key)
        return try Self.decodeInfo(result)
    }

    func unload(key: String) {
        queue.async {
            self.contexts[key] = nil
            self.bridges[key] = nil
        }
    }

    private static func decodeInfo(_ value: Any?) throws -> VeneraInfo {
        guard let value, JSONSerialization.isValidJSONObject(value) else { throw AppError.message(L("無法解析漫畫源資訊")) }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(VeneraInfo.self, from: data)
    }

    /// 呼叫 `__fn(key, args...)`，回傳字典結果
    func call(_ key: String, _ function: String, _ args: [Any?]) async throws -> [String: Any] {
        (try await callValue(key, function, args) as? [String: Any]) ?? [:]
    }

    func callValue(_ key: String, _ function: String, _ args: [Any?]) async throws -> Any? {
        let list = ([key as Any?] + args).map { jsLiteral($0) }.joined(separator: ", ")
        return try await evaluate("\(function)(\(list))", source: key)
    }

    // MARK: 圖片

    func loadImage(sourceKey: String, imageKey: String, comicId: String?, epId: String?) async throws -> Data {
        let result = try await call(sourceKey, "__loadImage", [imageKey, comicId, epId])
        guard let b64 = result["data"] as? String, let data = Data(base64Encoded: b64) else {
            throw AppError.message(L("圖片載入失敗"))
        }
        if let script = result["modify"] as? String, !script.isEmpty {
            return try await modifyImage(data, script: script)
        }
        return data
    }

    /// 在獨立的 JS 環境執行腳本內的 `modifyImage(image)`（例如禁漫的切塊還原）。
    func modifyImage(_ data: Data, script: String) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            Self.imageQueue.addOperation {
                let isolatedQueue = DispatchQueue(label: "godbook.venera.image")
                let (ctx, bridge) = Self.makeContext(queue: isolatedQueue)
                guard let source = Bitmap.decode(data) else {
                    continuation.resume(throwing: AppError.message(L("無法解碼圖片")))
                    return
                }
                let key = bridge.bitmaps.add(source)
                ctx.exception = nil
                ctx.evaluateScript(script)
                let result = ctx.evaluateScript("(function(){ var image = new Image(\(key)); var r = modifyImage(image); return r.key; })()")
                if let exception = ctx.exception {
                    continuation.resume(throwing: AppError.message(L("modifyImage 失敗：%@", "\(exception.toString() ?? "")")))
                    return
                }
                guard let result, result.isNumber,
                      let bitmap = bridge.bitmaps.get(Int(result.toInt32())),
                      let encoded = bitmap.encodeJPEG() else {
                    continuation.resume(throwing: AppError.message(L("modifyImage 沒有回傳圖片")))
                    return
                }
                continuation.resume(returning: encoded)
            }
        }
    }
}
