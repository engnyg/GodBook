import Foundation

enum DownloadState: String, Codable {
    case queued, downloading, paused, failed, finished
}

struct DownloadItem: Identifiable, Codable {
    var summary: ComicSummary
    var chapter: Chapter
    var total = 0
    var done = 0
    var state = DownloadState.queued
    var error: String?

    var id: String { Self.makeID(summary, chapter) }
    static func makeID(_ summary: ComicSummary, _ chapter: Chapter) -> String { "\(summary.id)|\(chapter.id)" }

    var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// 下載佇列：章節依序下載，章節內的圖片併發下載；支援暫停、續傳、重試。
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem]
    private var running: [String: Task<Void, Never>] = [:]
    private static let file = "downloads.json"

    private init() {
        var loaded = Storage.load([DownloadItem].self, from: Self.file) ?? []
        for index in loaded.indices where loaded[index].state == .downloading {
            loaded[index].state = .queued // App 被關閉時中斷的任務，下次啟動繼續
        }
        items = loaded
    }

    // MARK: 查詢

    var comics: [ComicSummary] {
        var seen = Set<String>()
        return items.compactMap { seen.insert($0.summary.id).inserted ? $0.summary : nil }
    }

    func items(for summary: ComicSummary) -> [DownloadItem] {
        items.filter { $0.summary.id == summary.id }
    }

    func item(_ summary: ComicSummary, _ chapter: Chapter) -> DownloadItem? {
        let id = DownloadItem.makeID(summary, chapter)
        return items.first { $0.id == id }
    }

    // MARK: 操作

    func resumeQueued() { pump() }

    func enqueue(detail: ComicDetail, chapters: [Chapter]) {
        DownloadStorage.saveDetail(detail)
        for chapter in chapters {
            let id = DownloadItem.makeID(detail.summary, chapter)
            if let index = items.firstIndex(where: { $0.id == id }) {
                switch items[index].state {
                case .finished, .downloading, .queued: continue
                case .paused, .failed:
                    items[index].state = .queued
                    items[index].error = nil
                }
            } else {
                items.append(DownloadItem(summary: detail.summary, chapter: chapter))
            }
        }
        persist()
        pump()
    }

    func pause(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state == .downloading || items[index].state == .queued else { return }
        items[index].state = .paused
        running[id]?.cancel()
        persist()
    }

    func resume(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state == .paused || items[index].state == .failed else { return }
        items[index].state = .queued
        items[index].error = nil
        persist()
        pump()
    }

    func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        running[id]?.cancel()
        CloudSync.shared.unpin([id])
        DownloadStorage.removeChapter(item.summary, chapterId: item.chapter.id)
        // 雲端還有這部作品時保留詳情與封面，供離線顯示與從雲端閱讀
        if !items.contains(where: { $0.summary.id == item.summary.id }), !CloudSync.shared.hasRecords(item.summary.id) {
            DownloadStorage.removeComic(item.summary)
        }
        persist()
    }

    /// 刪除本機下載；已上傳到雲端的章節仍可從雲端閱讀
    func removeComic(_ summary: ComicSummary) {
        let removed = items(for: summary)
        for item in removed { running[item.id]?.cancel() }
        CloudSync.shared.unpin(removed.map(\.id))
        items.removeAll { $0.summary.id == summary.id }
        if CloudSync.shared.hasRecords(summary.id) {
            for item in removed { DownloadStorage.removeChapter(summary, chapterId: item.chapter.id) }
        } else {
            DownloadStorage.removeComic(summary)
        }
        persist()
    }

    /// 從雲端下載回本機的章節加回列表
    func adopt(_ summary: ComicSummary, _ chapter: Chapter) {
        guard item(summary, chapter) == nil else { return }
        let count = DownloadStorage.imageFiles(in: DownloadStorage.chapterDir(summary, chapter.id)).count
        items.append(DownloadItem(summary: summary, chapter: chapter, total: count, done: count, state: .finished))
        persist()
    }

    func pauseAll(of summary: ComicSummary) {
        for item in items(for: summary) { pause(item.id) }
    }

    func resumeAll(of summary: ComicSummary) {
        for item in items(for: summary) { resume(item.id) }
    }

    func removeAll() {
        for task in running.values { task.cancel() }
        let removed = items
        items = []
        let cloud = CloudSync.shared
        cloud.unpin(removed.map(\.id))
        if cloud.records.isEmpty {
            DownloadStorage.removeAll()
        } else {
            // 保留雲端作品的詳情與封面
            for item in removed { DownloadStorage.removeChapter(item.summary, chapterId: item.chapter.id) }
            for summary in Set(removed.map(\.summary)) where !cloud.hasRecords(summary.id) { DownloadStorage.removeComic(summary) }
        }
        persist()
    }

    // MARK: 排程

    private func pump() {
        guard running.isEmpty, let index = items.firstIndex(where: { $0.state == .queued }) else { return }
        start(at: index)
    }

    private func start(at index: Int) {
        items[index].state = .downloading
        items[index].error = nil
        persist()
        let item = items[index]
        let id = item.id
        let concurrency = max(1, min(8, AppSettings.shared.downloadConcurrency))

        running[id] = Task { [weak self] in
            do {
                let detail = DownloadStorage.loadDetail(item.summary)
                    ?? ComicDetail(summary: item.summary, chapters: [item.chapter])
                await DownloadStorage.fetchCover(detail.summary)
                let source = SourceRegistry.source(item.summary.source)
                let pages = try await source.pages(of: detail, chapter: item.chapter)
                try Task.checkCancellation()
                await self?.setTotal(id, pages.count)

                let dir = DownloadStorage.chapterDir(item.summary, item.chapter.id)
                try await DownloadStorage.download(pages, to: dir, concurrency: concurrency) { done in
                    await self?.setDone(id, done)
                }
                try Task.checkCancellation()
                DownloadStorage.markDone(dir)
                await self?.finish(id, error: nil)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    await self?.finishCancelled(id)
                } else {
                    await self?.finish(id, error: error.localizedDescription)
                }
            }
        }
    }

    private func setTotal(_ id: String, _ total: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].total = total
    }

    private func setDone(_ id: String, _ done: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done = done
    }

    private func finish(_ id: String, error: String?) {
        running[id] = nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = error == nil ? .finished : .failed
            items[index].error = error
            if error == nil { items[index].done = items[index].total }
        }
        persist()
        if error == nil, let item = items.first(where: { $0.id == id }) { CloudSync.shared.chapterDownloaded(item) }
        pump()
    }

    private func finishCancelled(_ id: String) {
        running[id] = nil
        persist()
        pump()
    }

    private func persist() {
        Storage.save(items, to: Self.file)
    }
}
