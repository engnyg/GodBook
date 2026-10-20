import Foundation

/// 腳本 `__describe()` 回傳的漫畫源能力描述。
struct VeneraInfo: Codable, Identifiable {
    struct Explore: Codable { let title: String; let type: String; let hasLoad: Bool }
    struct CategoryItem: Codable {
        let label: String; let kind: String
        let text: String?; let category: String?; let param: String?
    }
    struct CategoryPart: Codable { let name: String; let items: [CategoryItem] }
    struct Category: Codable { let title: String; let parts: [CategoryPart] }
    struct Option: Codable {
        let type: String; let label: String
        let options: [[String]]; let def: String?
    }
    struct Ranking: Codable { let options: [[String]] }
    struct Search: Codable { let options: [Option]; let hasLoad: Bool; let enableTags: Bool? }
    struct Favorites: Codable {
        let multiFolder: Bool
        let canToggle: Bool?
        let hasFolders: Bool?
        let canAddFolder: Bool?
        let canDeleteFolder: Bool?
    }
    struct ComicCaps: Codable {
        let comments: Bool
        let sendComment: Bool
        let chapterComments: Bool
        let sendChapterComment: Bool
        let like: Bool
        let rating: Bool
        let thumbnails: Bool
        let likeComment: Bool
        let voteComment: Bool
        let hasLink: Bool
        let linkDomains: [String]
    }
    struct Account: Codable {
        let hasLogin: Bool; let webviewUrl: String?
        let cookieFields: [String]?; let registerWebsite: String?
    }
    struct SettingOption: Codable { let value: String; let text: String }
    struct Setting: Codable, Identifiable {
        let name: String; let title: String; let type: String
        let options: [SettingOption]; let defJSON: String?
        let buttonText: String?; let validator: String?
        var id: String { name }
    }

    let key: String
    let name: String
    let version: String
    let url: String
    let explore: [Explore]
    let category: Category?
    let categoryOptions: [Option]
    let ranking: Ranking?
    let search: Search?
    let favorites: Favorites?
    let account: Account?
    let settings: [Setting]
    let idMatch: String?
    let comic: ComicCaps?

    var id: String { key }
    var kind: SourceKind { SourceKind(rawValue: "v:" + key) }
}

/// 使用者在「來源管理」關掉的頁面（探索頁 / 分類區塊 / 排行）
enum VeneraVisibility {
    private static func key(_ source: String) -> String { "src.hidden.\(source)" }

    static func hidden(_ source: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(source)) ?? [])
    }

    static func setHidden(_ source: String, _ item: String, _ isHidden: Bool) {
        var set = hidden(source)
        if isHidden { set.insert(item) } else { set.remove(item) }
        UserDefaults.standard.set(Array(set), forKey: key(source))
    }
}

/// 已安裝漫畫源的執行緒安全快取（供非 UI 程式碼讀取）。
final class VeneraRegistry {
    static let shared = VeneraRegistry()
    private let lock = NSLock()
    private var infos: [String: VeneraInfo] = [:]
    private var order: [String] = []

    func set(_ info: VeneraInfo) {
        lock.lock(); defer { lock.unlock() }
        if infos[info.key] == nil { order.append(info.key) }
        infos[info.key] = info
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        infos[key] = nil
        order.removeAll { $0 == key }
    }

    func info(_ key: String) -> VeneraInfo? {
        lock.lock(); defer { lock.unlock() }
        return infos[key]
    }

    var all: [VeneraInfo] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { infos[$0] }
    }
}

enum VeneraFiles {
    static let directory: URL = {
        let dir = Storage.directory.appendingPathComponent("Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for key: String) -> URL { directory.appendingPathComponent("\(key).js") }

    static func read(_ key: String) -> String? { try? String(contentsOf: url(for: key), encoding: .utf8) }

    static func write(_ js: String, key: String) throws {
        try js.write(to: url(for: key), atomically: true, encoding: .utf8)
    }

    static func delete(_ key: String) { try? FileManager.default.removeItem(at: url(for: key)) }
}

/// 把任意值轉成可安全嵌入 JS 原始碼的字面量。
func jsLiteral(_ value: Any?) -> String {
    func sanitize(_ input: Any?) -> Any {
        guard let input else { return NSNull() }
        let mirror = Mirror(reflecting: input)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return sanitize(child.value)
        }
        if let array = input as? [Any?] { return array.map { sanitize($0) } }
        if let dict = input as? [String: Any?] { return dict.mapValues { sanitize($0) } }
        return input
    }
    let wrapped: [Any] = [sanitize(value)]
    guard let data = try? JSONSerialization.data(withJSONObject: wrapped),
          var text = String(data: data, encoding: .utf8) else { return "null" }
    text.removeFirst()
    text.removeLast()
    return text
}

/// 版本比較：a > b
func isNewerVersion(_ a: String, than b: String) -> Bool {
    let lhs = a.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    let rhs = b.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    for i in 0..<max(lhs.count, rhs.count) {
        let x = i < lhs.count ? lhs[i] : 0, y = i < rhs.count ? rhs[i] : 0
        if x != y { return x > y }
    }
    return false
}
