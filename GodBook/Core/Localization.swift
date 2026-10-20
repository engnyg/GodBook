import Foundation

/// App 內語言切換（繁體中文 / 简体中文 / English / 跟隨系統）。
/// 程式裡的字串以繁體中文原文當 key，查不到翻譯就直接顯示原文。
enum Language {
    static let defaultsKey = "ui.language"

    static let choices: [(code: String, title: String)] = [
        ("system", ""), ("zh-Hant", "繁體中文"), ("zh-Hans", "简体中文"), ("en", "English"),
    ]

    /// 實際使用的語言代碼：zh-Hant / zh-Hans / en
    static var current: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? "system"
        if stored != "system" { return stored }
        for id in Locale.preferredLanguages {
            let lower = id.lowercased()
            if lower.hasPrefix("zh") {
                return (lower.contains("hans") || lower.hasSuffix("-cn") || lower.hasSuffix("-sg")) ? "zh-Hans" : "zh-Hant"
            }
            if lower.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    static var locale: Locale { Locale(identifier: current) }

    private static var cache: (code: String, bundle: Bundle?)?

    private static var bundle: Bundle? {
        let code = current
        if let cache, cache.code == code { return cache.bundle }
        let resolved = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        cache = (code, resolved)
        return resolved
    }

    static func localized(_ key: String) -> String {
        guard let bundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// 取得目前語言的字串；`%@` 依序代入 `args`。
func L(_ key: String, _ args: String...) -> String {
    let text = Language.localized(key)
    return args.isEmpty ? text : String(format: text, arguments: args.map { $0 as NSString })
}
