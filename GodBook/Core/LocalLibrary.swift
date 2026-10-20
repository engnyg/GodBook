import PDFKit
import UIKit

/// 使用者匯入的本機漫畫（CBZ / ZIP / PDF / EPUB / 圖片資料夾）。
@MainActor
final class LocalLibrary: ObservableObject {
    static let shared = LocalLibrary()
    private static let file = "local_comics.json"
    nonisolated static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "bmp"]

    nonisolated static let root: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Local", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Published private(set) var comics: [ComicSummary]
    @Published private(set) var isImporting = false

    private init() {
        comics = Self.loadList()
    }

    // MARK: 路徑（非隔離，供 LocalSource 使用）

    nonisolated static func dir(_ sid: String) -> URL { root.appendingPathComponent(sid, isDirectory: true) }
    nonisolated static func coverURL(_ sid: String) -> URL { dir(sid).appendingPathComponent("cover.jpg") }

    nonisolated static func loadList() -> [ComicSummary] {
        var list = Storage.load([ComicSummary].self, from: file) ?? []
        for i in list.indices { list[i].coverURL = coverURL(list[i].sid) } // 容器路徑可能改變，每次重新計算
        return list
    }

    nonisolated static func loadDetail(_ sid: String) -> ComicDetail? {
        guard let data = try? Data(contentsOf: dir(sid).appendingPathComponent("detail.json")) else { return nil }
        return try? JSONDecoder().decode(ComicDetail.self, from: data)
    }

    nonisolated static func pageFiles(sid: String, chapterId: String) -> [URL] {
        let chapterDir = dir(sid).appendingPathComponent(chapterId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: chapterDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func persist() { Storage.save(comics, to: Self.file) }

    // MARK: 匯入

    func importItem(at url: URL) async throws {
        isImporting = true
        defer { isImporting = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let sid = UUID().uuidString
        let target = Self.dir(sid)
        let title = url.deletingPathExtension().lastPathComponent
        do {
            let chapters = try await Task.detached(priority: .userInitiated) {
                try Self.performImport(from: url, to: target)
            }.value
            guard !chapters.isEmpty else { throw AppError.message(L("找不到任何圖片")) }

            let summary = ComicSummary(source: .local, sid: sid, title: title, coverURL: Self.coverURL(sid),
                                       subtitle: L("%@ 頁", "\(chapters.reduce(0) { $0 + $1.count })"))
            let detail = ComicDetail(summary: summary, chapters: chapters.map(\.chapter),
                                     pageCount: chapters.reduce(0) { $0 + $1.count })
            try JSONEncoder().encode(detail).write(to: target.appendingPathComponent("detail.json"), options: .atomic)
            comics.insert(summary, at: 0)
            persist()
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func remove(_ summary: ComicSummary) {
        try? FileManager.default.removeItem(at: Self.dir(summary.sid))
        comics.removeAll { $0.sid == summary.sid }
        persist()
    }

    func rename(_ summary: ComicSummary, to title: String) {
        guard let index = comics.firstIndex(where: { $0.sid == summary.sid }),
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        comics[index].title = title
        persist()
        if var detail = Self.loadDetail(summary.sid) {
            detail.summary.title = title
            try? JSONEncoder().encode(detail).write(to: Self.dir(summary.sid).appendingPathComponent("detail.json"), options: .atomic)
        }
    }

    // MARK: 實際匯入（背景執行緒）

    private struct ImportedChapter {
        let chapter: Chapter
        let count: Int
    }

    private nonisolated static func performImport(from url: URL, to target: URL) throws -> [(chapter: Chapter, count: Int)] {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDirectory)

        var groups: [(title: String, write: (URL) throws -> Int)] = []
        let ext = url.pathExtension.lowercased()

        if isDirectory.boolValue {
            groups = folderGroups(url)
        } else if ext == "pdf" {
            groups = [(url.deletingPathExtension().lastPathComponent, { dir in try writePDF(url, to: dir) })]
        } else if ext == "cbz" || ext == "zip" || ext == "epub" {
            groups = try zipGroups(url, single: ext == "epub")
        } else {
            throw AppError.message(L("不支援的檔案類型：.%@", "\(ext)"))
        }

        var result: [(chapter: Chapter, count: Int)] = []
        for (index, group) in groups.enumerated() {
            let id = "ch_\(index + 1)"
            let dir = target.appendingPathComponent(id, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let count = try group.write(dir)
            if count > 0 { result.append((Chapter(id: id, title: group.title), count)) }
        }
        // 封面：第一章第一張
        if let first = result.first,
           let file = pageFiles(sid: target.lastPathComponent, chapterId: first.chapter.id).first,
           let image = UIImage(contentsOfFile: file.path)?.downscaled(maxSide: 640),
           let jpeg = image.jpegData(compressionQuality: 0.85) {
            try jpeg.write(to: target.appendingPathComponent("cover.jpg"))
        }
        return result
    }

    private nonisolated static func naturalSorted<T>(_ items: [T], key: (T) -> String) -> [T] {
        items.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
    }

    private nonisolated static func isImage(_ name: String) -> Bool {
        let lower = name.lowercased()
        let last = (lower as NSString).lastPathComponent
        return imageExtensions.contains((lower as NSString).pathExtension)
            && !lower.hasPrefix("__macosx") && !last.hasPrefix(".")
    }

    private nonisolated static func zipGroups(_ url: URL, single: Bool) throws -> [(title: String, write: (URL) throws -> Int)] {
        let zip = try ZipReader(url: url)
        let images = zip.entries.filter { !$0.isDirectory && isImage($0.name) }
        guard !images.isEmpty else { throw AppError.message(L("壓縮檔裡沒有圖片")) }

        func writer(_ entries: [ZipEntry]) -> (URL) throws -> Int {
            { dir in
                for (i, entry) in naturalSorted(entries, key: \.name).enumerated() {
                    let data = try zip.extract(entry)
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    try data.write(to: dir.appendingPathComponent(String(format: "%04d.%@", i + 1, ext)))
                }
                return entries.count
            }
        }

        if single {
            return [(url.deletingPathExtension().lastPathComponent, writer(images))]
        }
        // 依所在資料夾分章；全部在同一層就只有一章
        let grouped = Dictionary(grouping: images) { ($0.name as NSString).deletingLastPathComponent }
        if grouped.count <= 1 {
            return [(url.deletingPathExtension().lastPathComponent, writer(images))]
        }
        return naturalSorted(Array(grouped.keys), key: { $0 }).map { folder in
            let title = folder.isEmpty ? url.deletingPathExtension().lastPathComponent : (folder as NSString).lastPathComponent
            return (title, writer(grouped[folder] ?? []))
        }
    }

    private nonisolated static func folderGroups(_ folder: URL) -> [(title: String, write: (URL) throws -> Int)] {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        func writer(_ files: [URL]) -> (URL) throws -> Int {
            { dir in
                for (i, file) in naturalSorted(files, key: { $0.lastPathComponent }).enumerated() {
                    try fm.copyItem(at: file, to: dir.appendingPathComponent(String(format: "%04d.%@", i + 1, file.pathExtension.lowercased())))
                }
                return files.count
            }
        }

        let directImages = children.filter { isImage($0.lastPathComponent) }
        let subfolders = naturalSorted(children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true },
                                       key: { $0.lastPathComponent })
        var groups: [(title: String, write: (URL) throws -> Int)] = []
        if !directImages.isEmpty { groups.append((folder.lastPathComponent, writer(directImages))) }
        for sub in subfolders {
            let files = ((try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []).filter { isImage($0.lastPathComponent) }
            if !files.isEmpty { groups.append((sub.lastPathComponent, writer(files))) }
        }
        return groups
    }

    private nonisolated static func writePDF(_ url: URL, to dir: URL) throws -> Int {
        guard let document = PDFDocument(url: url) else { throw AppError.message(L("無法開啟 PDF")) }
        for index in 0..<document.pageCount {
            try autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(2.5, 2400 / max(bounds.width, bounds.height, 1))
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let jpeg = image.jpegData(compressionQuality: 0.88) else { return }
                try jpeg.write(to: dir.appendingPathComponent(String(format: "%04d.jpg", index + 1)))
            }
        }
        return document.pageCount
    }
}

/// 本機漫畫來源（只供閱讀；列表由書庫的「本機」分頁顯示）。
struct LocalSource: ComicSource {
    let kind = SourceKind.local
    let sortOptions = [SortOption(id: "all", title: L("全部"))]

    func browse(query: String, page: Int, sort: SortOption, filters: [String: String]) async throws -> ComicPageResult {
        let all = LocalLibrary.loadList()
        let filtered = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return ComicPageResult(items: filtered, total: filtered.count, totalPages: 1)
    }

    func detail(of summary: ComicSummary) async throws -> ComicDetail {
        guard var detail = LocalLibrary.loadDetail(summary.sid) else { throw AppError.message(L("找不到這本本機漫畫")) }
        detail.summary.coverURL = LocalLibrary.coverURL(summary.sid)
        return detail
    }

    func pages(of detail: ComicDetail, chapter: Chapter) async throws -> [ReaderPage] {
        let files = LocalLibrary.pageFiles(sid: detail.summary.sid, chapterId: chapter.id)
        guard !files.isEmpty else { throw AppError.message(L("這個章節沒有圖片")) }
        return files.enumerated().map { ReaderPage(index: $0.offset, image: ImageSpec(url: $0.element, source: .local)) }
    }
}
