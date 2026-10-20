import Foundation

struct FavoriteItem: Codable, Identifiable, Hashable {
    var summary: ComicSummary
    var addedAt = Date()
    var tags: [String] = []
    var id: String { summary.id }
}

enum FavoriteSort: String, Codable, CaseIterable, Identifiable {
    case addedDesc, addedAsc, title, source
    var id: String { rawValue }
    var title: String {
        switch self {
        case .addedDesc: L("加入時間（新到舊）")
        case .addedAsc: L("加入時間（舊到新）")
        case .title: L("標題")
        case .source: L("來源")
        }
    }
}

struct FavoriteFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var items: [FavoriteItem] = []
    var sort = FavoriteSort.addedDesc
}

/// 本機收藏：多資料夾、排序、標籤、批次操作。
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    private static let file = "favorite_folders.json"
    private static let legacyFile = "favorites.json"

    @Published private(set) var folders: [FavoriteFolder]

    private init() {
        if let saved = Storage.load([FavoriteFolder].self, from: Self.file), !saved.isEmpty {
            folders = saved
        } else {
            // 舊版只有單一清單：搬進「預設」資料夾
            let legacy = Storage.load([ComicSummary].self, from: Self.legacyFile) ?? []
            folders = [FavoriteFolder(name: L("預設"), items: legacy.map { FavoriteItem(summary: $0) })]
        }
    }

    private func persist() { Storage.save(folders, to: Self.file) }

    private func index(of folderID: UUID) -> Int? { folders.firstIndex { $0.id == folderID } }

    // MARK: 查詢

    func isFavorite(_ summary: ComicSummary) -> Bool {
        folders.contains { $0.items.contains { $0.id == summary.id } }
    }

    func folderIDs(containing summary: ComicSummary) -> Set<UUID> {
        Set(folders.filter { $0.items.contains { $0.id == summary.id } }.map(\.id))
    }

    func sortedItems(_ folderID: UUID) -> [FavoriteItem] {
        guard let i = index(of: folderID) else { return [] }
        let folder = folders[i]
        switch folder.sort {
        case .addedDesc: return folder.items.sorted { $0.addedAt > $1.addedAt }
        case .addedAsc: return folder.items.sorted { $0.addedAt < $1.addedAt }
        case .title: return folder.items.sorted { $0.summary.title.localizedStandardCompare($1.summary.title) == .orderedAscending }
        case .source: return folder.items.sorted {
            $0.summary.source.title == $1.summary.source.title
                ? $0.addedAt > $1.addedAt : $0.summary.source.title < $1.summary.source.title
        }
        }
    }

    func allTags(in folderID: UUID) -> [String] {
        guard let i = index(of: folderID) else { return [] }
        return Array(Set(folders[i].visibleItems.flatMap(\.tags))).sorted()
    }

    // MARK: 單筆

    func add(_ summary: ComicSummary, to folderID: UUID) {
        guard let i = index(of: folderID), !folders[i].items.contains(where: { $0.id == summary.id }) else { return }
        folders[i].items.append(FavoriteItem(summary: summary))
        persist()
    }

    func remove(_ summary: ComicSummary, from folderID: UUID) {
        guard let i = index(of: folderID) else { return }
        folders[i].items.removeAll { $0.id == summary.id }
        persist()
    }

    func toggle(_ summary: ComicSummary, in folderID: UUID) {
        guard let i = index(of: folderID) else { return }
        if folders[i].items.contains(where: { $0.id == summary.id }) { remove(summary, from: folderID) }
        else { add(summary, to: folderID) }
    }

    func setTags(_ itemID: String, in folderID: UUID, tags: [String]) {
        guard let i = index(of: folderID), let j = folders[i].items.firstIndex(where: { $0.id == itemID }) else { return }
        folders[i].items[j].tags = tags
        persist()
    }

    // MARK: 資料夾

    @discardableResult
    func createFolder(_ name: String) -> UUID {
        let folder = FavoriteFolder(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? L("新資料夾") : name)
        folders.append(folder)
        persist()
        return folder.id
    }

    func rename(_ folderID: UUID, to name: String) {
        guard let i = index(of: folderID), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        folders[i].name = name
        persist()
    }

    func deleteFolder(_ folderID: UUID) {
        guard folders.count > 1 else { return } // 至少保留一個資料夾
        folders.removeAll { $0.id == folderID }
        persist()
    }

    func moveFolder(_ folderID: UUID, by offset: Int) {
        guard let i = index(of: folderID) else { return }
        let target = i + offset
        guard folders.indices.contains(target) else { return }
        folders.swapAt(i, target)
        persist()
    }

    func setSort(_ folderID: UUID, _ sort: FavoriteSort) {
        guard let i = index(of: folderID) else { return }
        folders[i].sort = sort
        persist()
    }

    // MARK: 批次

    func batchMove(_ itemIDs: Set<String>, from source: UUID, to destination: UUID) {
        guard source != destination, let s = index(of: source), let d = index(of: destination) else { return }
        let moving = folders[s].items.filter { itemIDs.contains($0.id) }
        folders[s].items.removeAll { itemIDs.contains($0.id) }
        for item in moving where !folders[d].items.contains(where: { $0.id == item.id }) { folders[d].items.append(item) }
        persist()
    }

    func batchCopy(_ itemIDs: Set<String>, from source: UUID, to destination: UUID) {
        guard source != destination, let s = index(of: source), let d = index(of: destination) else { return }
        for item in folders[s].items where itemIDs.contains(item.id) && !folders[d].items.contains(where: { $0.id == item.id }) {
            folders[d].items.append(item)
        }
        persist()
    }

    func batchDelete(_ itemIDs: Set<String>, from folderID: UUID) {
        guard let i = index(of: folderID) else { return }
        folders[i].items.removeAll { itemIDs.contains($0.id) }
        persist()
    }
}
