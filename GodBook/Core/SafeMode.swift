import Foundation
import LocalAuthentication

/// 安全模式：開啟後隱藏 18+ 來源與帶有成人標記的作品。
enum SafeMode {
    /// 內建視為 18+ 的來源（venera 漫畫源的 key）
    static let builtinAdultKeys: Set<String> = [
        "nhentai", "wnacg", "ehentai", "jm", "hitomi", "mh18", "hcomic", "jcomic", "manwaba",
    ]

    /// 標題或標籤出現這些字眼的作品，在安全模式下一律隱藏（用於混合內容的來源）
    private static let adultWords = [
        "r18", "r-18", "r 18", "18+", "18禁", "成人", "成年向", "工口", "エロ", "色情", "情色", "里番", "裏番",
        "adult", "hentai", "porn", "nsfw", "無修正", "无修正", "限制級", "限制级", "肉番", "本子",
    ]

    static var isOn: Bool { AppSettings.shared.safeMode }

    static func isAdult(_ kind: SourceKind) -> Bool {
        if kind == .nhentai || kind == .jmcomic { return true }
        guard kind.isVenera else { return false }
        let key = kind.veneraKey
        let settings = AppSettings.shared
        if settings.adultMarked.contains(key) { return true }
        if settings.adultUnmarked.contains(key) { return false }
        return builtinAdultKeys.contains(key)
    }

    static func isAdultKey(_ key: String) -> Bool { isAdult(SourceKind(rawValue: "v:" + key)) }

    static func hides(_ kind: SourceKind) -> Bool { isOn && isAdult(kind) }

    static func hides(_ summary: ComicSummary) -> Bool {
        guard isOn else { return false }
        if isAdult(summary.source) { return true }
        let haystack = ([summary.title, summary.subtitle ?? ""] + (summary.tags ?? [])).joined(separator: "\n").lowercased()
        return adultWords.contains { haystack.contains($0) }
    }

    /// 變更安全模式。關閉時，若已啟用 App 鎖，需要先通過 Face ID / 密碼驗證。
    @MainActor
    static func set(_ on: Bool) async -> Bool {
        let settings = AppSettings.shared
        guard !on, settings.safeMode, settings.appLockEnabled else {
            settings.safeMode = on
            return true
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            settings.safeMode = false
            return true
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("關閉安全模式"))
            settings.safeMode = false
            return true
        } catch {
            return false
        }
    }
}

extension FavoriteFolder {
    /// 安全模式下可見的項目
    var visibleItems: [FavoriteItem] { items.filter { !SafeMode.hides($0.summary) } }
}
