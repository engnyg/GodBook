import CryptoKit
import Foundation

/// 圖片磁碟快取（Caches/GodBookImages）。以最近使用時間為準，超出上限時刪除最舊的檔案。
enum ImageDiskCache {
    private static let lock = NSLock()
    private static var writesSinceTrim = 0

    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GodBookImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash)
    }

    static func read(_ key: String) -> Data? {
        let url = file(for: key)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    static func write(_ key: String, _ data: Data) {
        guard !data.isEmpty else { return }
        try? data.write(to: file(for: key), options: .atomic)
        lock.lock()
        writesSinceTrim += 1
        let shouldTrim = writesSinceTrim >= 25
        if shouldTrim { writesSinceTrim = 0 }
        lock.unlock()
        if shouldTrim { trim() }
    }

    static func size() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 超出 `cacheLimitMB`（0 = 不限制）時，從最舊的檔案開始刪除，直到降到上限的 80%。
    static func trim() {
        let limit = Int64(AppSettings.shared.cacheLimitMB) << 20
        guard limit > 0 else { return }
        var items = entries()
        var total = items.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        items.sort { $0.date < $1.date }
        let target = limit * 8 / 10
        for item in items where total > target {
            try? FileManager.default.removeItem(at: item.url)
            total -= item.size
        }
    }

    private static func entries() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
}
