import Foundation

/// 下載檔案的目錄結構（放在 Documents，可由「檔案」App 存取）：
/// Downloads/<source>_<id>/{cover.jpg, detail.json, ch_<chapterId>/0001.jpg … .done}
enum DownloadStorage {
    static let root: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let exports: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]

    static func comicDir(_ summary: ComicSummary) -> URL {
        let source = summary.source.rawValue.replacingOccurrences(of: ":", with: "-")
        let id = summary.sid.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "_")
        return root.appendingPathComponent("\(source)_\(id)", isDirectory: true)
    }

    static func chapterDir(_ summary: ComicSummary, _ chapterId: String) -> URL {
        let safe = chapterId.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "_")
        return comicDir(summary).appendingPathComponent("ch_\(safe)", isDirectory: true)
    }

    static func coverFile(_ summary: ComicSummary) -> URL {
        comicDir(summary).appendingPathComponent("cover.jpg")
    }

    private static func detailFile(_ summary: ComicSummary) -> URL {
        comicDir(summary).appendingPathComponent("detail.json")
    }

    // MARK: 詳情快取（離線時使用）

    static func saveDetail(_ detail: ComicDetail) {
        let dir = comicDir(detail.summary)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var copy = detail
        copy.preloadedPages = nil // 頁面網址會過期，離線時改讀本機檔案
        if let data = try? JSONEncoder().encode(copy) {
            try? data.write(to: detailFile(detail.summary), options: .atomic)
        }
    }

    static func loadDetail(_ summary: ComicSummary) -> ComicDetail? {
        guard let data = try? Data(contentsOf: detailFile(summary)) else { return nil }
        return try? JSONDecoder().decode(ComicDetail.self, from: data)
    }

    // MARK: 章節狀態

    static func markDone(_ chapterDir: URL) {
        FileManager.default.createFile(atPath: chapterDir.appendingPathComponent(".done").path, contents: Data())
    }

    static func isDone(_ chapterDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: chapterDir.appendingPathComponent(".done").path)
    }

    static func imageFiles(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 已完整下載的章節 → 本機頁面；否則回傳 nil
    static func localPages(summary: ComicSummary, chapterId: String) -> [ReaderPage]? {
        let dir = chapterDir(summary, chapterId)
        guard isDone(dir) else { return nil }
        let files = imageFiles(in: dir)
        guard !files.isEmpty else { return nil }
        return files.enumerated().map { index, url in
            ReaderPage(index: index, image: ImageSpec(url: url, source: summary.source))
        }
    }

    // MARK: 下載

    static func fetchCover(_ summary: ComicSummary) async {
        let file = coverFile(summary)
        guard !FileManager.default.fileExists(atPath: file.path), let url = summary.coverURL else { return }
        try? FileManager.default.createDirectory(at: comicDir(summary), withIntermediateDirectories: true)
        if let data = try? await ImageLoader.rawData(ImageSpec(url: url, source: summary.source)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// 以滑動視窗併發下載；已存在的檔案會略過（支援續傳）。
    static func download(_ pages: [ReaderPage],
                         to dir: URL,
                         concurrency: Int,
                         progress: @escaping @Sendable (Int) async -> Void) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = Set(imageFiles(in: dir).map { $0.deletingPathExtension().lastPathComponent })
        let pending = pages.filter { !existing.contains(fileStem($0.index)) }
        var completed = pages.count - pending.count
        await progress(completed)
        guard !pending.isEmpty else { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<max(1, concurrency) {
                guard let page = iterator.next() else { break }
                group.addTask { try await save(page, in: dir) }
            }
            while try await group.next() != nil {
                completed += 1
                await progress(completed)
                if let page = iterator.next() {
                    group.addTask { try await save(page, in: dir) }
                }
            }
        }
    }

    private static func fileStem(_ index: Int) -> String { String(format: "%04d", index + 1) }

    private static func save(_ page: ReaderPage, in dir: URL) async throws {
        let (data, ext) = try await ImageLoader.downloadData(page.image)
        try Task.checkCancellation()
        let file = dir.appendingPathComponent("\(fileStem(page.index)).\(ext)")
        try data.write(to: file, options: .atomic)
    }

    // MARK: 刪除與容量

    static func removeComic(_ summary: ComicSummary) {
        try? FileManager.default.removeItem(at: comicDir(summary))
    }

    static func removeChapter(_ summary: ComicSummary, chapterId: String) {
        try? FileManager.default.removeItem(at: chapterDir(summary, chapterId))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
