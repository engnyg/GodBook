import Foundation

/// 使用者可調整的來源與閱讀設定。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var nhMirror: String { didSet { defaults.set(nhMirror, forKey: "nh.mirror") } }
    @Published var nhApiKey: String { didSet { defaults.set(nhApiKey, forKey: "nh.apiKey") } }
    @Published var jmCustomDomain: String { didSet { defaults.set(jmCustomDomain, forKey: "jm.customDomain") } }
    @Published var jmUsername: String { didSet { defaults.set(jmUsername, forKey: "jm.username") } }
    @Published var jmAVS: String { didSet { defaults.set(jmAVS, forKey: "jm.avs") } }
    @Published var readerMode: ReaderMode { didSet { defaults.set(readerMode.rawValue, forKey: "reader.mode") } }
    @Published var downloadConcurrency: Int { didSet { defaults.set(downloadConcurrency, forKey: "dl.concurrency") } }
    @Published var translateTags: Bool { didSet { defaults.set(translateTags, forKey: "ui.translateTags") } }
    /// 被使用者停用（不顯示、不載入）的來源 rawValue
    @Published var disabledSources: Set<String> {
        didSet { defaults.set(Array(disabledSources), forKey: "ui.disabledSources") }
    }
    @Published var lastSource: SourceKind { didSet { defaults.set(lastSource.rawValue, forKey: "ui.lastSource") } }

    // MARK: 網路與進階設定（存於 UserDefaults，變動時自動通知畫面）
    @Stored("net.proxyMode", "system") var proxyMode: String      // system | direct | manual
    @Stored("net.proxyType", "http") var proxyType: String        // http | socks5
    @Stored("net.proxyHost", "") var proxyHost: String
    @Stored("net.proxyPort", "") var proxyPort: String
    @Stored("net.ignoreBadCert", false) var ignoreBadCert: Bool
    @Stored("net.cacheLimitMB", 2048) var cacheLimitMB: Int
    @Stored("lock.enabled", false) var appLockEnabled: Bool
    @Stored("webdav.url", "") var webdavURL: String
    @Stored("webdav.user", "") var webdavUser: String
    @Stored("src.listURL", "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json") var sourceListURL: String
    @Stored("src.autoUpdate", true) var autoUpdateSources: Bool
    @Stored("webdav.autoUpload", false) var webdavAutoUpload: Bool

    // MARK: 瀏覽與列表
    @Stored("list.display", "card") var listDisplay: String               // card | brief | detailed
    @Stored("list.scale", 1.0) var listScale: Double                      // 0.75 – 1.25
    @Stored("list.paging", false) var listPaging: Bool                    // true = 分頁、false = 連續捲動
    @Stored("list.autoLang", "none") var autoLanguage: String             // none | chinese | english | japanese
    @Stored("list.showStatus", true) var showTileStatus: Bool
    @Stored("list.blocked", [String]()) var blockedWords: [String]
    @Stored("list.blockedComments", [String]()) var blockedCommentWords: [String]
    @Stored("safe.enabled", false) var safeMode: Bool                      // 安全模式：隱藏 18+
    @Stored("safe.hideLibrary", false) var safeHideLibrary: Bool           // 安全模式下整個隱藏「書庫」分頁
    @Stored("safe.marked", [String]()) var adultMarked: [String]           // 使用者額外標記為 18+ 的 venera 來源 key
    @Stored("safe.unmarked", [String]()) var adultUnmarked: [String]       // 使用者取消內建 18+ 標記的來源 key
    @Stored("reader.autoNext", true) var autoNextChapter: Bool             // 翻/捲到章節盡頭時自動進入上一章或下一章
    @Stored("ui.language", "system") var language: String                  // system | zh-Hant | zh-Hans | en
    @Stored("ui.initialTab", 0) var initialTab: Int                       // 0 探索、1 書庫、2 設定
    @Stored("ui.reverseChapters", false) var reverseChapters: Bool
    @Stored("search.defaultTarget", "current") var defaultSearchTarget: String // current | aggregated
    @Stored("search.history", [String]()) var searchHistory: [String]
    @Stored("ui.sourceOrder", [String]()) var sourceOrder: [String]

    var jmLoggedIn: Bool { !jmAVS.isEmpty }

    /// 目前啟用的來源（依序：nhentai、禁漫、已安裝的 venera 漫畫源）
    var enabledSources: [SourceKind] {
        SourceKind.all.filter { isEnabled($0) }
    }

    /// 被使用者停用，或在安全模式下被隱藏的來源都視為未啟用
    func isEnabled(_ kind: SourceKind) -> Bool { !disabledSources.contains(kind.rawValue) && !SafeMode.hides(kind) }

    func setEnabled(_ kind: SourceKind, _ enabled: Bool) {
        if enabled { disabledSources.remove(kind.rawValue) } else { disabledSources.insert(kind.rawValue) }
        if !enabled, lastSource == kind, let fallback = enabledSources.first { lastSource = fallback }
    }

    private init() {
        nhMirror = defaults.string(forKey: "nh.mirror") ?? "nhentai.net"
        nhApiKey = defaults.string(forKey: "nh.apiKey") ?? ""
        jmCustomDomain = defaults.string(forKey: "jm.customDomain") ?? ""
        jmUsername = defaults.string(forKey: "jm.username") ?? ""
        jmAVS = defaults.string(forKey: "jm.avs") ?? ""
        readerMode = ReaderMode(rawValue: defaults.string(forKey: "reader.mode") ?? "") ?? .vertical
        disabledSources = Set(defaults.stringArray(forKey: "ui.disabledSources") ?? [])
        let savedConcurrency = defaults.integer(forKey: "dl.concurrency")
        downloadConcurrency = savedConcurrency == 0 ? 4 : savedConcurrency
        translateTags = defaults.object(forKey: "ui.translateTags") as? Bool ?? true
        lastSource = SourceKind(rawValue: defaults.string(forKey: "ui.lastSource") ?? "nhentai")
    }
}
