import CryptoKit
import Foundation
import Network
import UIKit

/// 章節打包（CBZ，不壓縮）與解開
enum CloudPackager {
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]

    /// 把章節資料夾的圖片打包成暫存的 CBZ
    static func makeCBZ(from dir: URL) throws -> URL {
        let files = DownloadStorage.imageFiles(in: dir)
        guard !files.isEmpty else { throw AppError.message(L("這個章節沒有已下載的圖片")) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString).cbz")
        do {
            let writer = try ZipWriter(url: url)
            for file in files { try writer.add(name: file.lastPathComponent, data: try Data(contentsOf: file)) }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// 解開 CBZ 到資料夾（先寫到暫存資料夾，完成後才替換），最後寫入 .done
    static func extract(_ cbz: URL, into dir: URL) throws {
        let reader = try ZipReader(url: cbz)
        let partial = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".partial", isDirectory: true)
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        var count = 0
        for entry in reader.entries where !entry.isDirectory {
            let name = (entry.name as NSString).lastPathComponent
            guard imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            try reader.extract(entry).write(to: partial.appendingPathComponent(name), options: .atomic)
            count += 1
        }
        guard count > 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw AppError.message(L("雲端的章節檔案沒有圖片"))
        }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.moveItem(at: partial, to: dir)
        DownloadStorage.markDone(dir)
    }
}

/// 閱讀「僅雲端」章節時的暫存區（Caches，系統空間不足時可能被清除）
enum CloudCache {
    static let root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GodBookCloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func dir(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash, isDirectory: true)
    }

    static func pages(in dir: URL, source: SourceKind) -> [ReaderPage]? {
        guard DownloadStorage.isDone(dir) else { return nil }
        let files = DownloadStorage.imageFiles(in: dir)
        guard !files.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        return files.enumerated().map { ReaderPage(index: $0.offset, image: ImageSpec(url: $0.element, source: source)) }
    }

    static func size() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func clear() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 超過上限時，從最久沒讀的章節開始刪除
    static func trim(limitMB: Int) {
        let limit = Int64(max(0, limitMB)) << 20
        guard limit > 0 else { return }
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .map { url -> (url: URL, date: Date, size: Int64) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let size = DownloadStorage.imageFiles(in: url).reduce(Int64(0)) { $0 + CloudHTTP.fileSize($1) }
                return (url, date, size)
            }
            .sorted { $0.date < $1.date }
        var total = dirs.reduce(Int64(0)) { $0 + $1.size }
        for dir in dirs where total > limit {
            try? FileManager.default.removeItem(at: dir.url)
            total -= dir.size
        }
    }
}

enum CloudTaskState: Equatable {
    case queued
    case uploading(Double)
    case downloading
    case failed(String)
}

/// 一部作品在雲端的狀態（顯示用）
struct CloudComicStatus {
    /// 雲端上的章節數
    var uploaded = 0
    /// 只在雲端（本機已釋放）的章節數
    var cloudOnly = 0
    /// 本機已下載、還沒上傳的章節數
    var notUploaded = 0
    var active = false
    var failed: String?

    var localBackedUp: Int { uploaded - cloudOnly }
}

/// 雲端同步：上傳佇列、本機保存策略、雲端閱讀與跨裝置的下載清單。
///
/// 本機下載（DownloadManager）與雲端紀錄各自獨立：章節釋放本機空間後只剩雲端紀錄，
/// 閱讀時改從雲端下載到暫存區；作品的 detail.json 與封面會保留在本機供離線顯示。
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    /// 已上傳的章節（key 與 DownloadItem.id 相同）
    @Published private(set) var records: [String: CloudRecord]
    @Published private(set) var tasks: [String: CloudTaskState] = [:]
    @Published private(set) var queue: [String]
    /// 已連結的服務（CloudKind.rawValue → 帳號名稱）
    @Published private(set) var accounts: [String: String]
    @Published private(set) var waitingForWiFi = false
    @Published private(set) var message: String?
    /// 本機檔案增減時遞增，讓畫面重新檢查
    @Published private(set) var revision = 0

    private let settings = CloudSettings.shared
    private var tombstones: [CloudTombstone]
    /// 從雲端下載回本機的章節：保存策略不會自動釋放，直到使用者手動釋放或刪除
    @Published private(set) var pinned: Set<String>
    private var worker: Task<Void, Never>?
    private var syncing = false
    private var started = false
    private var onWiFi = true
    private let monitor = NWPathMonitor()

    private static let recordsFile = "cloud_manifest.json"
    private static let queueFile = "cloud_queue.json"
    private static let tombstoneFile = "cloud_tombstones.json"
    private static let pinnedFile = "cloud_pinned.json"
    /// 帳號名稱不用 "cloud." 開頭，避免被放進備份（權杖在 Keychain，換裝置後要重新連結）
    private static let accountPrefix = "cloudAccount."
    private static let dirtyKey = "cloudSync.dirtyIndex"

    private init() {
        records = Storage.load([String: CloudRecord].self, from: Self.recordsFile) ?? [:]
        queue = Storage.load([String].self, from: Self.queueFile) ?? []
        tombstones = Storage.load([CloudTombstone].self, from: Self.tombstoneFile) ?? []
        pinned = Storage.load(Set<String>.self, from: Self.pinnedFile) ?? []
        var names: [String: String] = [:]
        for kind in CloudKind.allCases {
            guard let name = UserDefaults.standard.string(forKey: Self.accountPrefix + kind.rawValue) else { continue }
            if kind.usesOAuth && OAuthStore.load(kind) == nil { continue }
            names[kind.rawValue] = name
        }
        accounts = names
        for id in queue { tasks[id] = .queued }
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let wifi = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in CloudSync.shared.networkChanged(wifi) }
        }
        monitor.start(queue: DispatchQueue(label: "godbook.cloud.network"))
        if settings.autoUpload { enqueuePending() }
        applyRetention()
        pump()
    }

    private func networkChanged(_ wifi: Bool) {
        onWiFi = wifi
        if wifi && waitingForWiFi { pump() }
    }

    /// 設定變更後（Wi-Fi 限制、上傳目標）重新排程
    func settingsChanged() {
        if settings.autoUpload { enqueuePending() }
        pump()
    }

    // MARK: 查詢

    func record(_ id: String) -> CloudRecord? { records[id] }

    func hasRecords(_ comicId: String) -> Bool { records.values.contains { $0.summary.id == comicId } }

    func isConnected(_ kind: CloudKind) -> Bool { accounts[kind.rawValue] != nil }

    var connectedKinds: [CloudKind] { CloudKind.allCases.filter(isConnected) }

    /// 目前的上傳目標（必須已連結）
    var target: CloudKind? { settings.target.flatMap { isConnected($0) ? $0 : nil } }

    nonisolated static func isLocal(_ item: DownloadItem) -> Bool {
        item.state == .finished && DownloadStorage.isDone(DownloadStorage.chapterDir(item.summary, item.chapter.id))
    }

    /// 有雲端紀錄的作品（最近上傳的在前）
    var cloudComics: [ComicSummary] {
        var latest: [String: (ComicSummary, Date)] = [:]
        for record in records.values where (latest[record.summary.id]?.1 ?? .distantPast) < record.uploadedAt {
            latest[record.summary.id] = (record.summary, record.uploadedAt)
        }
        return latest.values.sorted { $0.1 > $1.1 }.map(\.0)
    }

    func status(for summary: ComicSummary) -> CloudComicStatus {
        let local = DownloadManager.shared.items(for: summary).filter { $0.state == .finished }
        let localIds = Set(local.map(\.id))
        let cloud = records.filter { $0.value.summary.id == summary.id }
        var status = CloudComicStatus()
        status.uploaded = cloud.count
        status.cloudOnly = cloud.keys.filter { !localIds.contains($0) }.count
        status.notUploaded = local.filter { cloud[$0.id] == nil }.count
        for key in localIds.union(cloud.keys) {
            switch tasks[key] {
            case .failed(let text): status.failed = text
            case .some: status.active = true
            case nil: break
            }
        }
        return status
    }

    // MARK: 帳號

    func connect(_ kind: CloudKind) async throws {
        if kind.usesOAuth { try await OAuth.signIn(kind) }
        do {
            let name = try await CloudDrives.drive(kind).account()
            accounts[kind.rawValue] = name
            UserDefaults.standard.set(name, forKey: Self.accountPrefix + kind.rawValue)
        } catch {
            if kind.usesOAuth { OAuthStore.delete(kind) }
            throw error
        }
        if target == nil { settings.target = kind }
        message = nil
        settingsChanged()
    }

    func disconnect(_ kind: CloudKind) {
        OAuthStore.delete(kind)
        if kind == .googleDrive { GoogleDriveDrive.shared.resetCache() }
        accounts[kind.rawValue] = nil
        UserDefaults.standard.removeObject(forKey: Self.accountPrefix + kind.rawValue)
        if settings.target == kind { settings.target = connectedKinds.first }
    }

    // MARK: 上傳佇列

    func enqueue(_ ids: [String]) {
        for id in ids where !queue.contains(id) && records[id] == nil {
            queue.append(id)
            tasks[id] = .queued
        }
        persistQueue()
        pump()
    }

    func enqueue(comic summary: ComicSummary) {
        enqueue(DownloadManager.shared.items(for: summary).filter { Self.isLocal($0) }.map(\.id))
    }

    /// 所有已下載、尚未上傳的章節
    func enqueuePending() {
        enqueue(DownloadManager.shared.items.filter { records[$0.id] == nil && Self.isLocal($0) }.map(\.id))
    }

    func retryFailed() {
        let failed = tasks.compactMap { key, value -> String? in
            if case .failed = value { return key } else { return nil }
        }
        for key in failed { tasks[key] = nil }
        enqueue(failed)
    }

    func cancelQueue() {
        for id in queue { tasks[id] = nil }
        queue = []
        persistQueue()
    }

    /// 由 DownloadManager 在章節下載完成時呼叫
    func chapterDownloaded(_ item: DownloadItem) {
        if settings.autoUpload { enqueue([item.id]) }
        applyRetention(for: item.summary)
    }

    private func pump() {
        guard worker == nil else { return }
        let existing = Set(DownloadManager.shared.items.map(\.id))
        let stale = queue.filter { records[$0] != nil || !existing.contains($0) }
        if !stale.isEmpty {
            queue.removeAll { stale.contains($0) }
            for id in stale where tasks[id] == .queued { tasks[id] = nil }
            persistQueue()
        }
        guard let id = queue.first else {
            waitingForWiFi = false
            syncIndexes()
            return
        }
        guard let kind = target else {
            message = L("尚未選擇上傳目標，請先連結雲端服務")
            return
        }
        if settings.wifiOnly && !onWiFi {
            waitingForWiFi = true
            return
        }
        waitingForWiFi = false
        message = nil
        worker = Task {
            await upload(id, to: kind)
            worker = nil
            pump()
        }
    }

    private func upload(_ id: String, to kind: CloudKind) async {
        queue.removeAll { $0 == id }
        persistQueue()
        guard let item = DownloadManager.shared.items.first(where: { $0.id == id }), Self.isLocal(item) else {
            tasks[id] = nil
            return
        }
        tasks[id] = .uploading(0)
        nonisolated(unsafe) var background = UIBackgroundTaskIdentifier.invalid // 只在主執行緒讀寫
        background = UIApplication.shared.beginBackgroundTask(withName: "GodBook.cloudUpload") {
            UIApplication.shared.endBackgroundTask(background)
        }
        defer { UIApplication.shared.endBackgroundTask(background) }

        let dir = DownloadStorage.chapterDir(item.summary, item.chapter.id)
        let root = CloudPath.root
        let folder = CloudPath.folder(for: item.summary)
        let fileName = CloudPath.fileName(for: item.chapter)
        let comicPath = CloudPath.comic(folder, root: root)
        let path = comicPath + [fileName]
        let drive = CloudDrives.drive(kind)
        do {
            let cbz = try await Task.detached(priority: .utility) { try CloudPackager.makeCBZ(from: dir) }.value
            defer { try? FileManager.default.removeItem(at: cbz) }
            let localSize = CloudHTTP.fileSize(cbz)

            if !records.values.contains(where: { $0.kind == kind && $0.comicPath == comicPath }) {
                await uploadCover(item.summary, to: comicPath, drive: drive)
            }
            let result = try await drive.upload(cbz, to: path) { value in
                Task { @MainActor in CloudSync.shared.reportProgress(id, value) }
            }
            // 確認雲端檔案大小與本機一致才記錄為已上傳（之後才可能刪除本機檔案）
            var remoteSize = result.size
            if remoteSize == nil { remoteSize = try await drive.size(of: path, remoteId: result.remoteId) }
            guard remoteSize == localSize else {
                throw AppError.message(L("雲端檔案大小不符（本機 %@、雲端 %@）", "\(localSize)", "\(remoteSize ?? 0)"))
            }
            records[id] = CloudRecord(kind: kind, summary: item.summary, chapter: item.chapter, folder: folder,
                                      fileName: fileName, size: localSize, uploadedAt: Date(), remoteId: result.remoteId,
                                      root: root)
            persistRecords()
            tombstones.removeAll { $0.kind == kind && $0.comicId == item.summary.id && $0.chapterId == item.chapter.id }
            persistTombstones()
            markIndexDirty(kind)
            tasks[id] = nil
            applyRetention(for: item.summary)
        } catch {
            tasks[id] = error is CancellationError ? nil : .failed(error.localizedDescription)
        }
    }

    private func reportProgress(_ id: String, _ value: Double) {
        if case .uploading = tasks[id] { tasks[id] = .uploading(value) }
    }

    private func uploadCover(_ summary: ComicSummary, to comicPath: [String], drive: CloudDrive) async {
        let cover = DownloadStorage.coverFile(summary)
        guard FileManager.default.fileExists(atPath: cover.path) else { return }
        _ = try? await drive.upload(cover, to: comicPath + ["cover.jpg"]) { _ in }
    }

    // MARK: 本機空間

    /// 刪除已上傳章節的本機檔案（只保留雲端）
    @discardableResult
    func offload(_ item: DownloadItem) -> Bool {
        guard let record = records[item.id], record.size > 0, item.state == .finished, tasks[item.id] == nil else { return false }
        DownloadManager.shared.remove(item.id)
        revision += 1
        return true
    }

    func offload(comic summary: ComicSummary) {
        for item in DownloadManager.shared.items(for: summary) { offload(item) }
    }

    /// 刪除本機下載的單一章節（已上傳的仍可從雲端閱讀）
    func removeLocal(_ item: DownloadItem) {
        DownloadManager.shared.remove(item.id)
        revision += 1
    }

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    /// 本機下載被刪除時由 DownloadManager 呼叫：之後重新下載的章節要照保存策略處理
    func unpin(_ ids: [String]) {
        let before = pinned.count
        pinned.subtract(ids)
        if pinned.count != before { persistPinned() }
    }

    /// 依保存策略釋放本機空間；summary 為 nil 時檢查全部作品
    func applyRetention(for summary: ComicSummary? = nil) {
        let history = Storage.load([HistoryEntry].self, from: "history.json") ?? []
        let items = DownloadManager.shared.items.filter {
            $0.state == .finished && records[$0.id] != nil && !pinned.contains($0.id) && (summary == nil || $0.summary.id == summary?.id)
        }
        for (comicId, group) in Dictionary(grouping: items, by: { $0.summary.id }) {
            switch settings.policy(for: comicId) {
            case .keep, .auto:
                continue
            case .offload:
                for item in group { offload(item) }
            case .recent:
                guard let keep = recentWindow(group[0].summary, history: history) else { continue }
                for item in group where !keep.contains(item.chapter.id) { offload(item) }
            }
        }
        freeSpaceIfNeeded(history: history)
    }

    /// 目前閱讀位置起（依閱讀順序）要保留的章節
    private func recentWindow(_ summary: ComicSummary, history: [HistoryEntry]) -> Set<String>? {
        guard let detail = DownloadStorage.loadDetail(summary), !detail.chapters.isEmpty else { return nil }
        let count = max(1, settings.keepRecent)
        let reading = history.first { $0.summary.id == summary.id }
        var index = reading.flatMap { entry in detail.chapters.firstIndex { $0.id == entry.chapterId } } ?? detail.firstReadIndex
        var keep: Set<String> = [detail.chapters[index].id]
        while keep.count < count, let next = detail.nextIndex(after: index) {
            index = next
            keep.insert(detail.chapters[next].id)
        }
        return keep
    }

    /// 「空間不足時才釋放」：剩餘空間低於門檻時，從最久沒讀的作品開始釋放
    private func freeSpaceIfNeeded(history: [HistoryEntry]) {
        let threshold = Int64(max(0, settings.lowSpaceGB)) << 30
        guard threshold > 0, Self.availableSpace() < threshold else { return }
        let lastRead = Dictionary(history.map { ($0.summary.id, $0.date) }, uniquingKeysWith: { first, _ in first })
        let candidates = DownloadManager.shared.items
            .filter { records[$0.id] != nil && !pinned.contains($0.id) && settings.policy(for: $0.summary.id) == .auto && Self.isLocal($0) }
            .sorted { (lastRead[$0.summary.id] ?? .distantPast) < (lastRead[$1.summary.id] ?? .distantPast) }
        for item in candidates {
            guard Self.availableSpace() < threshold else { break }
            offload(item)
        }
    }

    nonisolated static func availableSpace() -> Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: 從雲端讀取

    /// 閱讀用：章節在雲端時下載到暫存區並回傳頁面；沒有雲端紀錄時回傳 nil
    func pages(summary: ComicSummary, chapterId: String) async throws -> [ReaderPage]? {
        let key = "\(summary.id)|\(chapterId)"
        guard let record = records[key] else { return nil }
        let dir = CloudCache.dir(for: key)
        if let cached = CloudCache.pages(in: dir, source: summary.source) { return cached }
        try await fetch(record, key: key, into: dir)
        let limit = settings.cacheLimitMB
        Task.detached(priority: .utility) { CloudCache.trim(limitMB: limit) }
        return CloudCache.pages(in: dir, source: summary.source)
    }

    /// 把只在雲端的章節下載回本機。下載回來的章節會暫時保留（不受保存策略自動釋放），
    /// 作品本身的保存策略不變；之後可在詳情頁逐話或整部手動釋放。
    func restoreLocal(_ summary: ComicSummary, chapterIds: Set<String>? = nil) async {
        let localIds = Set(DownloadManager.shared.items(for: summary).map(\.id))
        let order = Dictionary((DownloadStorage.loadDetail(summary)?.chapters ?? []).enumerated().map { ($1.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        let targets = records
            .filter { $0.value.summary.id == summary.id && !localIds.contains($0.key) && (chapterIds?.contains($0.value.chapter.id) ?? true) }
            .sorted { (order[$0.value.chapter.id] ?? .max) < (order[$1.value.chapter.id] ?? .max) }
        for (key, record) in targets {
            let dir = DownloadStorage.chapterDir(record.summary, record.chapter.id)
            guard (try? await fetch(record, key: key, into: dir)) != nil else { continue }
            DownloadManager.shared.adopt(record.summary, record.chapter)
            pinned.insert(key)
            persistPinned()
        }
    }

    private func fetch(_ record: CloudRecord, key: String, into dir: URL) async throws {
        guard isConnected(record.kind) else {
            let error = AppError.message(L("請先在「雲端儲存」連結 %@", record.kind.title))
            tasks[key] = .failed(error.localizedDescription)
            throw error
        }
        tasks[key] = .downloading
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString).cbz")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await CloudDrives.drive(record.kind).download(record.path, remoteId: record.remoteId, to: temp)
            try await Task.detached(priority: .userInitiated) { try CloudPackager.extract(temp, into: dir) }.value
            tasks[key] = nil
            revision += 1
        } catch {
            tasks[key] = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: 從雲端刪除

    func deleteFromCloud(_ summary: ComicSummary) async throws {
        let related = records.filter { $0.value.summary.id == summary.id }
        for kind in Set(related.values.map(\.kind)) {
            guard isConnected(kind) else { throw AppError.message(L("請先在「雲端儲存」連結 %@", kind.title)) }
            // 改過雲端資料夾時，同一部作品可能分散在不同資料夾
            for comicPath in Set(related.values.filter { $0.kind == kind }.map(\.comicPath)) {
                try await CloudDrives.drive(kind).delete(comicPath, remoteId: nil)
            }
            for (key, record) in related where record.kind == kind {
                records[key] = nil
                tasks[key] = nil
                tombstones.append(CloudTombstone(kind: kind, comicId: summary.id, chapterId: record.chapter.id))
            }
            markIndexDirty(kind)
        }
        persistRecords()
        persistTombstones()
        // 本機也沒有下載時，連同詳情與封面一起清掉
        if DownloadManager.shared.items(for: summary).isEmpty { DownloadStorage.removeComic(summary) }
        revision += 1
        syncIndexes()
    }

    // MARK: 雲端下載清單（GodBook/index.json）

    private func markIndexDirty(_ kind: CloudKind) {
        var dirty = Set(UserDefaults.standard.stringArray(forKey: Self.dirtyKey) ?? [])
        dirty.insert(kind.rawValue)
        UserDefaults.standard.set(Array(dirty), forKey: Self.dirtyKey)
    }

    /// 上傳佇列清空後，把變動寫進各服務的雲端清單
    private func syncIndexes() {
        guard !syncing, worker == nil else { return }
        let dirty = (UserDefaults.standard.stringArray(forKey: Self.dirtyKey) ?? []).compactMap(CloudKind.init(rawValue:))
        let ready = dirty.filter(isConnected)
        guard !ready.isEmpty else { return }
        syncing = true
        Task {
            for kind in ready {
                do {
                    try await syncIndex(kind)
                    let remaining = (UserDefaults.standard.stringArray(forKey: Self.dirtyKey) ?? []).filter { $0 != kind.rawValue }
                    UserDefaults.standard.set(remaining, forKey: Self.dirtyKey)
                } catch {
                    message = L("更新雲端清單失敗：%@", error.localizedDescription)
                }
            }
            syncing = false
        }
    }

    /// 下載雲端清單；雲端還沒有清單時回傳 nil（連線錯誤會丟出，避免用空清單覆蓋）
    private func downloadIndex(_ drive: CloudDrive) async throws -> CloudIndex? {
        guard try await drive.size(of: CloudPath.index, remoteId: nil) != nil else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await drive.download(CloudPath.index, remoteId: nil, to: temp)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudIndex.self, from: Data(contentsOf: temp))
    }

    /// 合併雲端清單與本機紀錄後上傳（保留其他裝置上傳的項目）
    private func syncIndex(_ kind: CloudKind) async throws {
        let drive = CloudDrives.drive(kind)
        var index = try await downloadIndex(drive) ?? CloudIndex()
        for stone in tombstones where stone.kind == kind {
            index.comics[stone.comicId]?.chapters[stone.chapterId] = nil
            if index.comics[stone.comicId]?.chapters.isEmpty == true { index.comics[stone.comicId] = nil }
        }
        for record in records.values where record.kind == kind {
            let comicId = record.summary.id
            let detail = DownloadStorage.loadDetail(record.summary).map(Self.slim)
            if index.comics[comicId] == nil {
                index.comics[comicId] = CloudIndex.Comic(
                    detail: detail ?? ComicDetail(summary: record.summary, chapters: [record.chapter]),
                    folder: record.folder, chapters: [:])
            } else if let detail {
                index.comics[comicId]?.detail = detail
            }
            index.comics[comicId]?.chapters[record.chapter.id] = CloudIndex.Entry(
                title: record.chapter.title, fileName: record.fileName, size: record.size,
                uploadedAt: record.uploadedAt, remoteId: record.remoteId, root: record.root ?? CloudPath.defaultRoot)
        }
        index.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temp) }
        try encoder.encode(index).write(to: temp, options: .atomic)
        _ = try await drive.upload(temp, to: CloudPath.index) { _ in }
        tombstones.removeAll { $0.kind == kind }
        persistTombstones()
    }

    private static func slim(_ detail: ComicDetail) -> ComicDetail {
        var copy = detail
        copy.related = []
        copy.preloadedPages = nil
        copy.thumbnails = nil
        return copy
    }

    /// 換裝置後：依雲端清單把作品（僅雲端）加回下載列表。回傳新增的章節數。
    func restoreList(from kind: CloudKind) async throws -> Int {
        let drive = CloudDrives.drive(kind)
        guard let index = try await downloadIndex(drive) else {
            throw AppError.message(L("雲端的「%@」資料夾裡還沒有 GodBook 的下載清單", CloudPath.root.joined(separator: "/")))
        }
        var added = 0
        for comic in index.comics.values {
            let summary = comic.detail.summary
            if DownloadStorage.loadDetail(summary) == nil { DownloadStorage.saveDetail(comic.detail) }
            let cover = DownloadStorage.coverFile(summary)
            if !FileManager.default.fileExists(atPath: cover.path) {
                let root = comic.chapters.values.first?.root ?? CloudPath.defaultRoot
                try? await drive.download(CloudPath.comic(comic.folder, root: root) + ["cover.jpg"], remoteId: nil, to: cover)
            }
            for (chapterId, entry) in comic.chapters {
                let chapter = comic.detail.chapters.first { $0.id == chapterId } ?? Chapter(id: chapterId, title: entry.title)
                let key = DownloadItem.makeID(summary, chapter)
                guard records[key] == nil else { continue }
                records[key] = CloudRecord(kind: kind, summary: summary, chapter: chapter, folder: comic.folder,
                                           fileName: entry.fileName, size: entry.size, uploadedAt: entry.uploadedAt,
                                           remoteId: entry.remoteId, root: entry.root ?? CloudPath.defaultRoot)
                added += 1
            }
        }
        persistRecords()
        revision += 1
        return added
    }

    // MARK: 儲存

    private func persistRecords() { Storage.save(records, to: Self.recordsFile) }
    private func persistQueue() { Storage.save(queue, to: Self.queueFile) }
    private func persistTombstones() { Storage.save(tombstones, to: Self.tombstoneFile) }
    private func persistPinned() { Storage.save(pinned, to: Self.pinnedFile) }
}
