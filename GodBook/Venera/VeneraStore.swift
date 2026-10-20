import Foundation

struct VeneraIndexEntry: Decodable, Identifiable {
    let name: String
    let key: String
    let version: String
    let fileName: String?
    let filename: String?
    let url: String?
    let description: String?

    var id: String { key + (fileName ?? filename ?? url ?? "") }
    var path: String? { fileName ?? filename }
}

/// 已安裝的 venera 漫畫源。App 內建一份（編譯時由 CI 放進 BundledSources），也可從網址安裝或更新。
@MainActor
final class VeneraStore: ObservableObject {
    static let shared = VeneraStore()

    @Published private(set) var sources: [VeneraInfo] = []
    @Published private(set) var isBootstrapping = false
    @Published private(set) var availableUpdates: [VeneraIndexEntry] = []
    @Published private(set) var isUpdating = false

    private let defaults = UserDefaults.standard
    private let removedKey = "venera.removed"
    private static let officialIndex = "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json"

    var defaultIndexURL: String { Self.officialIndex }

    private init() {}

    private var removed: Set<String> {
        get { Set(defaults.stringArray(forKey: removedKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: removedKey) }
    }

    // MARK: 啟動

    /// 安裝（或更新）內建腳本，並載入所有已安裝漫畫源的描述。
    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }

        await installBundled()

        let keys = installedKeys()
        for key in keys {
            do {
                let info = try await VeneraRuntime.shared.describe(key: key)
                apply(info)
            } catch {
                VeneraLog.shared.add("error", L("載入 %@", "\(key)"), error.localizedDescription)
            }
        }

        if AppSettings.shared.autoUpdateSources { _ = await checkUpdates(install: true) }
    }

    /// 檢查遠端索引有沒有較新的腳本；`install` 為 true 時直接更新。回傳可更新（或已更新）的項目數。
    @discardableResult
    func checkUpdates(install: Bool) async -> Int {
        guard !isUpdating else { return 0 }
        isUpdating = true
        defer { isUpdating = false }
        let indexURL = AppSettings.shared.sourceListURL
        guard let entries = try? await fetchIndex(indexURL) else { return 0 }

        var seen = Set<String>()
        var pending: [VeneraIndexEntry] = []
        for entry in entries where seen.insert(entry.key).inserted {
            guard let installed = isInstalled(entry.key), isNewerVersion(entry.version, than: installed.version) else { continue }
            pending.append(entry)
        }
        availableUpdates = pending
        guard install else { return pending.count }

        var updated = 0
        for entry in pending {
            do { try await self.install(entry: entry, indexURL: indexURL); updated += 1 }
            catch { VeneraLog.shared.add("error", L("更新 %@", "\(entry.name)"), error.localizedDescription) }
        }
        availableUpdates = []
        return updated
    }

    private func installedKeys() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: VeneraFiles.directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "js" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    private func installBundled() async {
        guard let folder = Bundle.main.url(forResource: "BundledSources", withExtension: nil) else { return }
        let indexURL = folder.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([VeneraIndexEntry].self, from: data) else { return }

        var seen = Set<String>()
        for entry in entries {
            guard let file = entry.path, seen.insert(entry.key).inserted else { continue } // 同 key 只裝第一個
            if removed.contains(entry.key) { continue }
            let versionKey = "venera.bundled.\(entry.key)"
            if defaults.string(forKey: versionKey) == entry.version, VeneraFiles.read(entry.key) != nil { continue }
            guard let js = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { continue }
            do {
                _ = try await install(js: js)
                defaults.set(entry.version, forKey: versionKey)
            } catch {
                VeneraLog.shared.add("error", L("內建 %@", "\(entry.name)"), error.localizedDescription)
            }
        }
    }

    /// 重新安裝所有內建腳本（包含曾被移除的）
    func restoreBundled() async {
        removed = []
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("venera.bundled.") {
            defaults.removeObject(forKey: key)
        }
        await installBundled()
    }

    // MARK: 安裝與移除

    @discardableResult
    func install(js: String) async throws -> VeneraInfo {
        let info = try await VeneraRuntime.shared.install(js: js)
        try VeneraFiles.write(js, key: info.key)
        removed.remove(info.key)
        apply(info)
        return info
    }

    func remove(key: String) {
        VeneraRuntime.shared.unload(key: key)
        VeneraFiles.delete(key)
        VeneraStorage.shared.removeAll(key)
        VeneraRegistry.shared.remove(key)
        sources.removeAll { $0.key == key }
        removed.insert(key)
    }

    private func apply(_ info: VeneraInfo) {
        VeneraRegistry.shared.set(info)
        if let index = sources.firstIndex(where: { $0.key == info.key }) {
            sources[index] = info
        } else {
            sources.append(info)
            sources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    func isInstalled(_ key: String) -> VeneraInfo? { sources.first { $0.key == key } }

    // MARK: 遠端索引

    func fetchIndex(_ urlString: String) async throws -> [VeneraIndexEntry] {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AppError.message(L("網址無效"))
        }
        let (data, response) = try await HTTP.data(for: URLRequest(url: url))
        guard response.statusCode == 200 else { throw AppError.http(response.statusCode) }
        return try JSONDecoder().decode([VeneraIndexEntry].self, from: data)
    }

    func install(entry: VeneraIndexEntry, indexURL: String) async throws {
        let target: URL
        if let direct = entry.url, let url = URL(string: direct) {
            target = url
        } else if let path = entry.path, let base = URL(string: indexURL)?.deletingLastPathComponent() {
            target = base.appendingPathComponent(path)
        } else {
            throw AppError.message(L("索引項目缺少檔案位置"))
        }
        try await install(from: target)
    }

    func install(from url: URL) async throws {
        let (data, response) = try await HTTP.data(for: URLRequest(url: url))
        guard response.statusCode == 200 else { throw AppError.http(response.statusCode) }
        guard let js = String(data: data, encoding: .utf8) else { throw AppError.message(L("腳本不是 UTF-8 文字")) }
        try await install(js: js)
    }
}
