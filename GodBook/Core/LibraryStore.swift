import Foundation

struct HistoryEntry: Identifiable, Codable, Hashable {
    var summary: ComicSummary
    var chapterId: String
    var chapterTitle: String
    var pageIndex: Int
    var date: Date

    var id: String { summary.id }
}

/// 閱讀紀錄（JSON 存放於 Application Support）。
final class LibraryStore: ObservableObject {
    @Published private(set) var history: [HistoryEntry]

    private static let historyFile = "history.json"
    /// 翻頁時頻繁更新進度：延遲合併寫檔，不在每次翻頁都寫整份紀錄
    private var pendingSave: DispatchWorkItem?

    init() {
        history = Storage.load([HistoryEntry].self, from: Self.historyFile) ?? []
    }

    func progress(for summary: ComicSummary) -> HistoryEntry? {
        history.first { $0.id == summary.id }
    }

    func record(_ summary: ComicSummary, chapter: Chapter, pageIndex: Int) {
        history.removeAll { $0.id == summary.id }
        history.insert(HistoryEntry(summary: summary, chapterId: chapter.id, chapterTitle: chapter.title,
                                    pageIndex: pageIndex, date: Date()), at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// 立即寫入（App 進入背景時呼叫，避免最後的進度遺失）
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        Storage.save(history, to: Self.historyFile)
    }

    func removeHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        flush()
    }

    func clearHistory() {
        history = []
        flush()
    }
}
