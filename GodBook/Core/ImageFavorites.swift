import UIKit

struct ImageFavorite: Identifiable, Codable, Hashable {
    var id = UUID()
    var summary: ComicSummary
    var chapterId: String
    var chapterTitle: String
    var pageIndex: Int
    var fileName: String
    var date = Date()
}

/// 圖片收藏：把喜歡的單張圖片存成檔案，連同出處（漫畫、章節、頁數）一起保存。
final class ImageFavoritesStore: ObservableObject {
    static let shared = ImageFavoritesStore()
    private static let file = "image_favorites.json"

    static let directory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent("ImageFavorites", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @Published private(set) var items: [ImageFavorite]

    private init() {
        items = Storage.load([ImageFavorite].self, from: Self.file) ?? []
    }

    func fileURL(_ item: ImageFavorite) -> URL { Self.directory.appendingPathComponent(item.fileName) }

    func find(_ summary: ComicSummary, chapterId: String, pageIndex: Int) -> ImageFavorite? {
        items.first { $0.summary.id == summary.id && $0.chapterId == chapterId && $0.pageIndex == pageIndex }
    }

    /// 已收藏則取消，否則加入。回傳 true 表示現在是已收藏狀態。
    @discardableResult
    func toggle(summary: ComicSummary, chapter: Chapter, pageIndex: Int, image: UIImage) -> Bool {
        if let existing = find(summary, chapterId: chapter.id, pageIndex: pageIndex) {
            remove(existing)
            return false
        }
        let name = "\(UUID().uuidString).jpg"
        guard let data = image.jpegData(compressionQuality: 0.92) else { return false }
        do { try data.write(to: Self.directory.appendingPathComponent(name), options: .atomic) } catch { return false }
        items.insert(ImageFavorite(summary: summary, chapterId: chapter.id, chapterTitle: chapter.title,
                                   pageIndex: pageIndex, fileName: name), at: 0)
        Storage.save(items, to: Self.file)
        return true
    }

    func remove(_ item: ImageFavorite) {
        try? FileManager.default.removeItem(at: fileURL(item))
        items.removeAll { $0.id == item.id }
        Storage.save(items, to: Self.file)
    }
}
