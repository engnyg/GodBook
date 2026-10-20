import Foundation

/// 最簡單的 ZIP 寫入器（STORED，不壓縮；圖片本身已壓縮）。
final class ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    func add(name: String, data: Data) throws {
        let nameData = Data(name.utf8)
        let crc = Self.crc32(data)
        let size = UInt32(data.count)
        var header = Data()
        header += le32(0x04034B50)
        header += le16(20)
        header += le16(0x0800)      // UTF-8 檔名
        header += le16(0)           // STORED
        header += le16(0)           // 時間
        header += le16(0x0021)      // 日期 1980-01-01
        header += le32(crc)
        header += le32(size)
        header += le32(size)
        header += le16(UInt16(nameData.count))
        header += le16(0)
        header += nameData
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: data)
        entries.append(Entry(name: nameData, crc: crc, size: size, offset: UInt32(offset)))
        offset += UInt64(header.count + data.count)
    }

    func finish() throws {
        let centralStart = offset
        var central = Data()
        for entry in entries {
            central += le32(0x02014B50)
            central += le16(20)
            central += le16(20)
            central += le16(0x0800)
            central += le16(0)
            central += le16(0)
            central += le16(0x0021)
            central += le32(entry.crc)
            central += le32(entry.size)
            central += le32(entry.size)
            central += le16(UInt16(entry.name.count))
            central += le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(0)
            central += le32(entry.offset)
            central += entry.name
        }
        var end = Data()
        end += le32(0x06054B50)
        end += le16(0) + le16(0)
        end += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        end += le32(UInt32(central.count))
        end += le32(UInt32(centralStart))
        end += le16(0)
        try handle.write(contentsOf: central + end)
        try handle.close()
    }
}

enum CBZExporter {
    /// 相容舊呼叫：匯出 CBZ
    static func export(_ summary: ComicSummary) throws -> URL {
        try ComicExport.export(summary, as: .cbz)
    }
}
