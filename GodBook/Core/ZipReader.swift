import Compression
import Foundation

struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localOffset: Int
    let encrypted: Bool
    var isDirectory: Bool { name.hasSuffix("/") }
}

/// 最小可用的 ZIP 讀取器（STORED / DEFLATE，不支援 ZIP64 與加密）。
final class ZipReader {
    private let data: Data
    let entries: [ZipEntry]

    private static let gbk: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        self.data = data
        entries = try Self.parseEntries(data)
    }

    private static func u16(_ data: Data, _ offset: Int) -> Int {
        guard offset + 2 <= data.count else { return 0 }
        return Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return u16(data, offset) | u16(data, offset + 2) << 16
    }

    private static func parseEntries(_ data: Data) throws -> [ZipEntry] {
        guard data.count >= 22 else { throw AppError.message(L("不是有效的 ZIP 檔案")) }
        // 從檔尾往前找 End Of Central Directory
        var eocd = -1
        var position = data.count - 22
        let limit = max(0, data.count - 22 - 65535)
        while position >= limit {
            if u32(data, position) == 0x06054B50 { eocd = position; break }
            position -= 1
        }
        guard eocd >= 0 else { throw AppError.message(L("不是有效的 ZIP 檔案")) }
        let total = u16(data, eocd + 10)
        let directoryOffset = u32(data, eocd + 16)
        if directoryOffset == 0xFFFF_FFFF || total == 0xFFFF { throw AppError.message(L("不支援 ZIP64 格式")) }

        var result: [ZipEntry] = []
        var cursor = directoryOffset
        for _ in 0..<total {
            guard u32(data, cursor) == 0x02014B50 else { break }
            let flags = u16(data, cursor + 8)
            let method = UInt16(u16(data, cursor + 10))
            let compressed = u32(data, cursor + 20)
            let uncompressed = u32(data, cursor + 24)
            let nameLength = u16(data, cursor + 28)
            let extraLength = u16(data, cursor + 30)
            let commentLength = u16(data, cursor + 32)
            let localOffset = u32(data, cursor + 42)
            let nameData = data.subdata(in: (data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: gbk)
                ?? String(decoding: nameData, as: UTF8.self)
            result.append(ZipEntry(name: name, method: method, compressedSize: compressed,
                                   uncompressedSize: uncompressed, localOffset: localOffset, encrypted: flags & 1 != 0))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    func extract(_ entry: ZipEntry) throws -> Data {
        if entry.encrypted { throw AppError.message(L("不支援加密的 ZIP")) }
        let offset = entry.localOffset
        guard Self.u32(data, offset) == 0x04034B50 else { throw AppError.message(L("ZIP 資料損毀")) }
        let nameLength = Self.u16(data, offset + 26)
        let extraLength = Self.u16(data, offset + 28)
        let start = offset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { throw AppError.message(L("ZIP 資料損毀")) }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))

        switch entry.method {
        case 0:
            return raw
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = Data(count: entry.uncompressedSize)
            let written = output.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize,
                        src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else { throw AppError.message(L("解壓縮失敗：%@", "\(entry.name)")) }
            return output
        default:
            throw AppError.message(L("不支援的壓縮方式 (%@)", "\(entry.method)"))
        }
    }
}
