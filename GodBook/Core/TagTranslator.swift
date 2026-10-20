import Foundation

/// 標籤翻譯（繁體中文）。資料來自 EhTagTranslation Database（經 venera 整理的 tags_tw.json）。
final class TagTranslator {
    static let shared = TagTranslator()

    private lazy var table: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "tags_tw", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return decoded
    }()

    /// nhentai 的 tag 類型 → 翻譯資料的命名空間
    private func namespaces(for group: String?) -> [String] {
        switch group {
        case "tag": ["female", "male", "mixed", "other"]
        case "category": ["reclass"]
        case let group?: [group]
        case nil: []
        }
    }

    func translate(_ name: String, group: String?) -> String {
        let key = name.lowercased()
        for namespace in namespaces(for: group) {
            if let value = table[namespace]?[key] { return value }
        }
        return name
    }

    func groupTitle(_ group: String) -> String {
        table["rows"]?[group] ?? group
    }

    struct Suggestion: Identifiable, Hashable {
        let namespace: String
        let name: String
        let translation: String
        var id: String { namespace + "|" + name }
    }

    /// 以英文名稱或中文翻譯模糊搜尋標籤，供搜尋建議使用。
    func search(_ text: String, limit: Int = 8) -> [Suggestion] {
        let needle = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard needle.count >= 1 else { return [] }
        var prefixMatches: [Suggestion] = []
        var otherMatches: [Suggestion] = []
        for namespace in ["female", "male", "mixed", "other", "artist", "parody", "character", "group"] {
            guard let table = self.table[namespace] else { continue }
            for (key, value) in table {
                let inKey = key.contains(needle), inValue = value.lowercased().contains(needle)
                guard inKey || inValue else { continue }
                let suggestion = Suggestion(namespace: namespace, name: key, translation: value)
                if key.hasPrefix(needle) || value.lowercased().hasPrefix(needle) { prefixMatches.append(suggestion) }
                else { otherMatches.append(suggestion) }
                if prefixMatches.count >= limit * 4 { break }
            }
        }
        return Array((prefixMatches + otherMatches).prefix(limit))
    }
}
