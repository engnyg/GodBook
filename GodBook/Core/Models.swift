import Foundation

/// 內容來源。內建 nhentai / 禁漫；其餘為 venera 漫畫源（rawValue 以 "v:" 開頭）。
struct SourceKind: Hashable, Codable, Identifiable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let nhentai = SourceKind(rawValue: "nhentai")
    static let jmcomic = SourceKind(rawValue: "jmcomic")
    /// 使用者匯入的本機漫畫
    static let local = SourceKind(rawValue: "local")

    var id: String { rawValue }
    var isVenera: Bool { rawValue.hasPrefix("v:") }
    var isLocal: Bool { self == .local }
    var veneraKey: String { String(rawValue.dropFirst(2)) }

    var title: String {
        if self == .nhentai { return "nhentai" }
        if self == .jmcomic { return L("禁漫") }
        if self == .local { return L("本機") }
        return VeneraRegistry.shared.info(veneraKey)?.name ?? veneraKey
    }

    /// 所有可用來源（內建 + 已安裝的 venera 漫畫源）
    static var all: [SourceKind] {
        let natural = [.nhentai, .jmcomic] + VeneraRegistry.shared.all.map(\.kind)
        let order = UserDefaults.standard.stringArray(forKey: "ui.sourceOrder") ?? []
        guard !order.isEmpty else { return natural }
        // 依使用者自訂順序排列；沒出現在順序中的（新安裝的）排在最後
        return natural.sorted {
            (order.firstIndex(of: $0.rawValue) ?? Int.max) < (order.firstIndex(of: $1.rawValue) ?? Int.max)
        }
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct SortOption: Identifiable, Hashable {
    let id: String
    let title: String
    var order: String = ""
    var time: String = ""
    /// 選單中的分組標題（venera 漫畫源使用）
    var section: String? = nil
}

struct ComicSummary: Identifiable, Hashable, Codable {
    var source: SourceKind
    var sid: String
    var title: String
    var coverURL: URL?
    var subtitle: String?
    /// 來源提供的標籤（用於顯示與關鍵字屏蔽）；不一定有
    var tags: [String]? = nil

    var id: String { "\(source.rawValue):\(sid)" }
}

struct ComicTag: Hashable, Identifiable, Codable {
    var name: String
    var group: String?
    /// 點擊後用來搜尋的字串；nil 代表不可點擊
    var query: String?

    var id: String { "\(group ?? "")|\(name)" }
}

struct Chapter: Identifiable, Hashable, Codable {
    var id: String
    var title: String
}

struct ImageSpec: Hashable, Codable {
    var url: URL
    var source: SourceKind
    /// 禁漫圖片的切割份數，0 或 1 代表不需還原
    var scramble: Int = 0
    /// venera 漫畫源：原始圖片字串、漫畫與章節 ID（封面的 comicId 為 nil）
    var imageKey: String? = nil
    var comicId: String? = nil
    var epId: String? = nil
}

struct ReaderPage: Identifiable, Hashable, Codable {
    var index: Int
    var image: ImageSpec
    var id: Int { index }
}

struct ComicDetail: Codable {
    var summary: ComicSummary
    var description: String?
    var authors: [String] = []
    var tags: [ComicTag] = []
    var stats: [String] = []
    var chapters: [Chapter] = []
    var related: [ComicSummary] = []
    var pageCount: Int?
    /// nhentai 的詳情已含所有頁面；禁漫需再向章節 API 取得
    var preloadedPages: [ReaderPage]?
    /// 評論 API 需要的額外識別碼（venera 的 subId）
    var subId: String?
    /// 對應的網頁連結（分享用）
    var url: String?
    var isLiked: Bool?
    var stars: Double?
    /// 作品本身提供的縮圖網址；來源另有分頁縮圖 API 時為 nil
    var thumbnails: [String]?
    var isRemoteFavorite: Bool?
}

struct ComicComment: Identifiable, Hashable {
    var id: String
    var userName: String
    var avatar: URL?
    /// 原始內容：可能是純文字，也可能含 a / b / i / u / s / br / span / img 的 HTML
    var content: String
    var time: String?
    var replyCount: Int?
    var score: Int?
    var isLiked: Bool?
    /// 1 = 已按讚(推)、-1 = 已按倒讚(噓)、0 = 無
    var voteStatus: Int?
    /// 來源已一併提供的回覆（不必再向網路要）
    var replies: [ComicComment] = []
}

struct CommentPage {
    var comments: [ComicComment]
    var maxPage: Int?
}

struct CommentContext {
    var summary: ComicSummary
    var subId: String?
    /// 不為 nil 代表「章節評論」
    var chapterId: String?
}

struct SourceCapabilities {
    var comments = false
    var sendComments = false
    var chapterComments = false
    var sendChapterComments = false
    var likeComic = false
    var rating = false
    var thumbnails = false
    var likeComment = false
    var voteComment = false
    var remoteFavorites = false
}

struct RemoteFolder: Hashable, Identifiable {
    var id: String
    var name: String
}

struct RemoteFavoriteState {
    var folders: [RemoteFolder]
    var favorited: Set<String>
    var canManageFolders: Bool
}

struct ComicPageResult {
    var items: [ComicSummary]
    var total: Int?
    var totalPages: Int?
}

struct SearchRoute: Hashable {
    var source: SourceKind
    var query: String
    var title: String
}

struct FilterOption: Hashable {
    let value: String
    let title: String
}

/// 搜尋 / 分類的篩選條件群組（例如排序、語言、分類）。
struct FilterGroup: Identifiable, Hashable {
    enum Kind { case select, multi, dropdown }
    let id: String
    let title: String
    var kind = Kind.select
    let options: [FilterOption]
    var defaultValue: String?

    /// 使用者沒選時的有效值（nil 代表「不限」）
    func effective(_ values: [String: String]) -> String? {
        if let value = values[id] { return value }
        if let defaultValue { return defaultValue }
        switch kind {
        case .select: return options.first?.value
        case .multi: return "[]"
        case .dropdown: return nil
        }
    }
}

struct CategoryEntry: Identifiable, Hashable {
    let title: String
    /// 點擊後以這個字串做 browse（搜尋文字，或 venera 的分類 / 排行編碼）
    let query: String
    var id: String { title + "|" + query }
}

struct CategorySection: Identifiable, Hashable {
    let title: String
    let entries: [CategoryEntry]
    var id: String { title }
}

protocol ComicSource {
    var kind: SourceKind { get }
    var capabilities: SourceCapabilities { get }
    func loadComments(_ context: CommentContext, page: Int, replyTo: String?) async throws -> CommentPage
    func sendComment(_ context: CommentContext, content: String, replyTo: String?) async throws
    func likeComment(_ context: CommentContext, commentId: String, like: Bool) async throws
    func voteComment(_ context: CommentContext, commentId: String, up: Bool, cancel: Bool) async throws -> Int
    func setLiked(_ summary: ComicSummary, liked: Bool) async throws
    /// stars 為 0–10（App 以 5 顆星呈現，1 顆星 = 2）
    func rate(_ summary: ComicSummary, stars: Int) async throws
    func loadThumbnails(_ summary: ComicSummary, next: String?) async throws -> (urls: [String], next: String?)
    func remoteFavorites(for summary: ComicSummary) async throws -> RemoteFavoriteState
    func setRemoteFavorite(_ summary: ComicSummary, folderId: String, adding: Bool) async throws
    func addRemoteFolder(_ name: String) async throws
    func deleteRemoteFolder(_ id: String) async throws
    var sortOptions: [SortOption] { get }
    /// 分類 / 排行頁的內容；沒有則為空
    func categorySections() -> [CategorySection]
    /// 此來源是否提供標籤建議（搜尋框輸入時）
    var supportsTagSuggestions: Bool { get }
    /// 目前（依搜尋字串）可用的篩選條件；預設沒有
    func filterGroups(query: String) -> [FilterGroup]
    func browse(query: String, page: Int, sort: SortOption, filters: [String: String]) async throws -> ComicPageResult
    func detail(of summary: ComicSummary) async throws -> ComicDetail
    func pages(of detail: ComicDetail, chapter: Chapter) async throws -> [ReaderPage]
}

private let unsupported = AppError.message(L("這個來源不支援此功能"))

extension ComicSource {
    var capabilities: SourceCapabilities { SourceCapabilities() }
    func loadComments(_ context: CommentContext, page: Int, replyTo: String?) async throws -> CommentPage { throw unsupported }
    func sendComment(_ context: CommentContext, content: String, replyTo: String?) async throws { throw unsupported }
    func likeComment(_ context: CommentContext, commentId: String, like: Bool) async throws { throw unsupported }
    func voteComment(_ context: CommentContext, commentId: String, up: Bool, cancel: Bool) async throws -> Int { throw unsupported }
    func setLiked(_ summary: ComicSummary, liked: Bool) async throws { throw unsupported }
    func rate(_ summary: ComicSummary, stars: Int) async throws { throw unsupported }
    func loadThumbnails(_ summary: ComicSummary, next: String?) async throws -> (urls: [String], next: String?) { throw unsupported }
    func remoteFavorites(for summary: ComicSummary) async throws -> RemoteFavoriteState { throw unsupported }
    func setRemoteFavorite(_ summary: ComicSummary, folderId: String, adding: Bool) async throws { throw unsupported }
    func addRemoteFolder(_ name: String) async throws { throw unsupported }
    func deleteRemoteFolder(_ id: String) async throws { throw unsupported }

    func filterGroups(query: String) -> [FilterGroup] { [] }
    func categorySections() -> [CategorySection] { [] }
    var supportsTagSuggestions: Bool { false }

    func browse(query: String, page: Int, sort: SortOption) async throws -> ComicPageResult {
        try await browse(query: query, page: page, sort: sort, filters: [:])
    }
}

enum SourceRegistry {
    static func source(_ kind: SourceKind) -> ComicSource {
        if kind == .nhentai { return NHentaiSource() }
        if kind == .jmcomic { return JMComicSource() }
        if kind == .local { return LocalSource() }
        return VeneraSource(kind: kind)
    }
}

enum AppError: LocalizedError {
    case http(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            switch code {
            case 403: L("存取被拒絕 (403)：可能需要 API Key、換鏡像網域，或網路環境被封鎖")
            case 404: L("找不到內容 (404)")
            case 429: L("請求太頻繁 (429)，請稍後再試")
            default: L("伺服器回應錯誤 (%@)", "\(code)")
            }
        case .message(let text):
            text
        }
    }
}
