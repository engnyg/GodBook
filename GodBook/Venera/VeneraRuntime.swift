import Foundation
import JavaScriptCore

/// 在專屬序列佇列上執行 JavaScriptCore，並把 Promise 轉成 Swift async。
final class VeneraRuntime {
    static let shared = VeneraRuntime()

    private let queue = DispatchQueue(label: "godbook.venera.js", qos: .userInitiated)
    private var context: JSContext?
    private var bridge: VeneraBridge?
    private var loaded = Set<String>()

    private static let imageSemaphore = DispatchSemaphore(value: 3)

    // MARK: 建立 context

    static func makeContext(queue: DispatchQueue) -> (JSContext, VeneraBridge) {
        let context = JSContext(virtualMachine: JSVirtualMachine())!
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

    /// 只能在 queue 上呼叫
    private func ensureContext() -> JSContext {
        if let context { return context }
        let (ctx, bridge) = Self.makeContext(queue: queue)
        context = ctx
        self.bridge = bridge
        return ctx
    }

    private func ensureLoaded(_ key: String, in ctx: JSContext) throws {
        guard !loaded.contains(key) else { return }
        guard let js = VeneraFiles.read(key) else { throw AppError.message(L("找不到漫畫源腳本：%@", "\(key)")) }
        ctx.exception = nil
        ctx.evaluateScript("__loadSource(\(jsLiteral(js)))")
        if let exception = ctx.exception {
            ctx.exception = nil
            throw AppError.message(L("載入漫畫源失敗：%@", "\(exception.toString() ?? "")"))
        }
        loaded.insert(key)
    }

    // MARK: 執行

    /// 執行一段會產生值（或 Promise）的 JS 運算式，回傳 JSON 解碼後的結果。
    func evaluate(_ expression: String, source key: String? = nil) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            queue.async {
                let ctx = self.ensureContext()
                do {
                    if let key { try self.ensureLoaded(key, in: ctx) }
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                var finished = false
                let succeed: @convention(block) (String?) -> Void = { json in
                    guard !finished else { return }
                    finished = true
                    continuation.resume(returning: Self.parse(json))
                }
                let fail: @convention(block) (String?) -> Void = { message in
                    guard !finished else { return }
                    finished = true
                    continuation.resume(throwing: AppError.message(message ?? L("腳本執行失敗")))
                }

                ctx.exception = nil
                let thunk = ctx.evaluateScript("(function(){ return (\(expression)); })")
                if let exception = ctx.exception {
                    ctx.exception = nil
                    finished = true
                    continuation.resume(throwing: AppError.message(exception.toString() ?? L("腳本錯誤")))
                    return
                }
                let runner = ctx.objectForKeyedSubscript("__run")
                runner?.call(withArguments: [thunk as Any, succeed, fail])
                if let exception = ctx.exception {
                    ctx.exception = nil
                    if !finished {
                        finished = true
                        continuation.resume(throwing: AppError.message(exception.toString() ?? L("腳本錯誤")))
                    }
                }
            }
        }
    }

    private static func parse(_ json: String?) -> Any? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value is NSNull ? nil : value
    }

    // MARK: 高階 API

    func install(js: String) async throws -> VeneraInfo {
        let result = try await evaluate("(function(){ var k = __loadSource(\(jsLiteral(js))); return __describe(k); })()")
        let info = try Self.decodeInfo(result)
        queue.async { self.loaded.insert(info.key) }
        return info
    }

    func describe(key: String) async throws -> VeneraInfo {
        let result = try await evaluate("__describe(\(jsLiteral(key)))", source: key)
        return try Self.decodeInfo(result)
    }

    func unload(key: String) {
        queue.async {
            self.loaded.remove(key)
            self.context?.evaluateScript("delete ComicSource.sources[\(jsLiteral(key))]")
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
            DispatchQueue.global(qos: .userInitiated).async {
                Self.imageSemaphore.wait()
                defer { Self.imageSemaphore.signal() }

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
