import Foundation

enum ReaderMode: String, CaseIterable, Identifiable, Codable {
    case vertical              // 連續：由上到下（條漫）
    case horizontal            // 翻頁：左到右
    case horizontalRTL         // 翻頁：右到左（日漫）
    case pagedVertical         // 翻頁：上到下
    case continuousHorizontal  // 連續：左到右
    case continuousHorizontalRTL // 連續：右到左

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vertical: L("連續捲動（由上到下）")
        case .horizontal: L("翻頁（左到右）")
        case .horizontalRTL: L("翻頁（右到左，日漫）")
        case .pagedVertical: L("翻頁（上到下）")
        case .continuousHorizontal: L("連續捲動（左到右）")
        case .continuousHorizontalRTL: L("連續捲動（右到左）")
        }
    }

    var isPaged: Bool { self == .horizontal || self == .horizontalRTL || self == .pagedVertical }
    var isRTL: Bool { self == .horizontalRTL || self == .continuousHorizontalRTL }
    var isVerticalAxis: Bool { self == .vertical || self == .pagedVertical }
}

struct ReaderPrefs: Codable, Equatable {
    var mode = ReaderMode.vertical
    var tapToTurn = true
    var reverseTap = false
    var pageAnimation = true
    var volumeKeys = false
    var autoTurnSeconds = 0
    var preloadCount = 4
    var showClockBattery = true
    var showPageNumber = true
    var doubleTapZoom = true
    var longPressZoom = true
    /// 雙擊收藏目前這張圖（會停用雙擊縮放）
    var quickCollect = false
    var keepScreenOn = true
}

/// 全域閱讀設定，以及「每部漫畫獨立設定」。
final class ReaderPrefsStore: ObservableObject {
    static let shared = ReaderPrefsStore()
    private static let globalKey = "reader.prefs"
    private static let overridesFile = "reader_overrides.json"

    @Published var global: ReaderPrefs {
        didSet {
            if let data = try? JSONEncoder().encode(global) { UserDefaults.standard.set(data, forKey: Self.globalKey) }
        }
    }
    @Published private(set) var overrides: [String: ReaderPrefs]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.globalKey),
           let decoded = try? JSONDecoder().decode(ReaderPrefs.self, from: data) {
            global = decoded
        } else {
            var prefs = ReaderPrefs()
            // 沿用舊版的閱讀方式設定
            if let raw = UserDefaults.standard.string(forKey: "reader.mode"), let mode = ReaderMode(rawValue: raw) {
                prefs.mode = mode
            }
            global = prefs
        }
        overrides = Storage.load([String: ReaderPrefs].self, from: Self.overridesFile) ?? [:]
    }

    func prefs(for comicKey: String) -> ReaderPrefs { overrides[comicKey] ?? global }
    func hasOverride(_ comicKey: String) -> Bool { overrides[comicKey] != nil }

    func setOverride(_ comicKey: String, _ prefs: ReaderPrefs?) {
        overrides[comicKey] = prefs
        Storage.save(overrides, to: Self.overridesFile)
    }

    /// 寫入目前生效的那一份設定（有獨立設定就寫獨立設定，否則寫全域）
    func update(for comicKey: String, _ prefs: ReaderPrefs) {
        if hasOverride(comicKey) { setOverride(comicKey, prefs) } else { global = prefs }
    }
}
