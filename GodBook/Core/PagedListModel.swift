import Foundation

/// 清單狀態：連續捲動（無限載入）或分頁（一次一頁）；以 generation 避免舊請求覆蓋新結果。
@MainActor
final class PagedListModel: ObservableObject {
    @Published private(set) var items: [ComicSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasMore = true
    @Published private(set) var didLoadOnce = false
    /// 分頁模式：目前頁碼與總頁數（未知時為 nil）
    @Published private(set) var currentPage = 1
    @Published private(set) var totalPages: Int?
    private(set) var pagingMode = false

    private var loader: ((Int) async throws -> ComicPageResult)?
    private var nextPage = 1
    private var generation = 0
    private var seen = Set<String>()
    private var knownTotal: Int?
    /// 連續幾頁載入後完全沒有可顯示的項目（全被屏蔽）
    private var emptyStreak = 0

    func start(paging: Bool = false, _ loader: @escaping (Int) async throws -> ComicPageResult) {
        generation += 1
        self.loader = loader
        pagingMode = paging
        items = []
        seen = []
        nextPage = 1
        currentPage = 1
        totalPages = nil
        hasMore = true
        errorMessage = nil
        didLoadOnce = false
        knownTotal = nil
        emptyStreak = 0
        isLoading = false
        if paging { goTo(1) } else { loadMore() }
    }

    func loadMoreIfNeeded(current: ComicSummary) {
        guard !pagingMode, let index = items.firstIndex(where: { $0.id == current.id }) else { return }
        if index >= items.count - 6 { loadMore() }
    }

    func retry() {
        if pagingMode { goTo(currentPage) } else { loadMore() }
    }

    // MARK: 連續捲動

    func loadMore() {
        guard !isLoading, hasMore, let loader else { return }
        isLoading = true
        errorMessage = nil
        let ticket = generation
        let page = nextPage
        Task {
            do {
                let result = try await loader(page)
                guard ticket == generation else { return }
                let fresh = result.items.filter { seen.insert($0.id).inserted }
                let visible = fresh.filter { !Blocklist.blocks($0) }
                items.append(contentsOf: visible)
                nextPage = page + 1
                if let total = result.total { knownTotal = total }
                var more = !result.items.isEmpty
                if let pages = result.totalPages, page >= pages { more = false }
                if let total = knownTotal, seen.count >= total { more = false }
                if fresh.isEmpty && !result.items.isEmpty { more = false } // 伺服器重複回傳同一頁
                hasMore = more
                didLoadOnce = true
                isLoading = false
                // 整頁都被屏蔽時畫面上不會出現新項目，也就不會觸發下一頁；自動再往下載（最多連續 5 頁）
                if visible.isEmpty && more {
                    emptyStreak += 1
                    if emptyStreak < 5 { loadMore() }
                } else {
                    emptyStreak = 0
                }
            } catch {
                guard ticket == generation else { return }
                errorMessage = error.localizedDescription
                didLoadOnce = true
                isLoading = false
            }
        }
    }

    // MARK: 分頁

    func goTo(_ page: Int) {
        guard let loader, !isLoading, page >= 1 else { return }
        isLoading = true
        errorMessage = nil
        let ticket = generation
        Task {
            do {
                let result = try await loader(page)
                guard ticket == generation else { return }
                items = result.items.filter { !Blocklist.blocks($0) }
                currentPage = page
                if let pages = result.totalPages { totalPages = pages }
                else if let total = result.total, !result.items.isEmpty {
                    // 沒給總頁數時，用「總筆數 ÷ 第一頁筆數」估算
                    if page == 1 { totalPages = max(1, Int((Double(total) / Double(result.items.count)).rounded(.up))) }
                }
                var more = !result.items.isEmpty
                if let pages = totalPages, page >= pages { more = false }
                hasMore = more
                didLoadOnce = true
                isLoading = false
            } catch {
                guard ticket == generation else { return }
                errorMessage = error.localizedDescription
                didLoadOnce = true
                isLoading = false
            }
        }
    }

    func nextPageAction() { if hasMore { goTo(currentPage + 1) } }
    func previousPageAction() { goTo(currentPage - 1) }
}
