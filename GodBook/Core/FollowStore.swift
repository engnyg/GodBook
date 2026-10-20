import Foundation

struct FollowInfo: Codable, Hashable {
    var chapterCount: Int
    var latestTitle: String
    var hasUpdate = false
    var checkedAt = Date()
}

/// 追蹤更新：定期檢查被追蹤資料夾內的漫畫有沒有新章節。
@MainActor
final class FollowStore: ObservableObject {
    static let shared = FollowStore()
    private static let file = "follow_updates.json"
    private static let folderKey = "lib.followFolder"
    private static let lastCheckKey = "lib.followLastCheck"

    @Published private(set) var infos: [String: FollowInfo]
    @Published private(set) var isChecking = false
    @Published private(set) var progress = (done: 0, total: 0)

    private init() {
        infos = Storage.load([String: FollowInfo].self, from: Self.file) ?? [:]
    }

    var followedFolderID: UUID? {
        get { UserDefaults.standard.string(forKey: Self.folderKey).flatMap(UUID.init(uuidString:)) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.folderKey)
        }
    }

    var lastCheck: Date? { UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date }

    var updateCount: Int { infos.values.filter(\.hasUpdate).count }

    private func persist() { Storage.save(infos, to: Self.file) }

    /// 開啟詳情頁時呼叫：把目前章節數記為已讀
    func markRead(_ summary: ComicSummary, chapterCount: Int, latestTitle: String) {
        guard infos[summary.id] != nil else { return }
        infos[summary.id] = FollowInfo(chapterCount: chapterCount, latestTitle: latestTitle, hasUpdate: false)
        persist()
    }

    func checkIfDue(favorites: FavoritesStore, minimumInterval: TimeInterval = 6 * 3600) async {
        guard followedFolderID != nil else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < minimumInterval { return }
        await check(favorites: favorites)
    }

    func check(favorites: FavoritesStore) async {
        guard !isChecking, let folderID = followedFolderID else { return }
        let items = (favorites.folders.first { $0.id == folderID }?.items ?? []).filter { !SafeMode.hides($0.summary) }
        guard !items.isEmpty else { return }
        isChecking = true
        progress = (0, items.count)
        defer { isChecking = false; UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey) }

        // 每次最多同時檢查 3 本，避免被來源限流
        var index = 0
        while index < items.count {
            let batch = Array(items[index..<min(index + 3, items.count)])
            index += batch.count
            await withTaskGroup(of: (String, Int, String)?.self) { group in
                for item in batch where item.summary.source != .local {
                    group.addTask {
                        guard let detail = try? await SourceRegistry.source(item.summary.source).detail(of: item.summary) else { return nil }
                        return (item.summary.id, detail.chapters.count, detail.chapters.last?.title ?? "")
                    }
                }
                for await result in group {
                    guard let (id, count, title) = result else { continue }
                    if var updated = infos[id] {
                        updated.latestTitle = title
                        updated.checkedAt = Date()
                        // 已讀基準（chapterCount）維持不變，直到使用者開啟該漫畫
                        if count > updated.chapterCount { updated.hasUpdate = true }
                        infos[id] = updated
                    } else {
                        infos[id] = FollowInfo(chapterCount: count, latestTitle: title) // 第一次：記為基準，不算更新
                    }
                }
            }
            progress.done = min(index, items.count)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        persist()
    }

    func clear() {
        infos = [:]
        persist()
    }
}
