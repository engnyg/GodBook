import PDFKit
import UIKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case cbz, pdf, epub
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

struct ExportChapter {
    let title: String
    let files: [URL]
}

/// 把已下載或本機的漫畫匯出成 CBZ / PDF / EPUB（存到 Documents/Exports）。
enum ComicExport {
    static func chapters(for summary: ComicSummary) -> [ExportChapter] {
        if summary.source.isLocal {
            guard let detail = LocalLibrary.loadDetail(summary.sid) else { return [] }
            return detail.chapters.map {
                ExportChapter(title: $0.title, files: LocalLibrary.pageFiles(sid: summary.sid, chapterId: $0.id))
            }.filter { !$0.files.isEmpty }
        }
        let detail = DownloadStorage.loadDetail(summary)
        let all = detail?.chapters ?? []
        return all.compactMap { chapter in
            let dir = DownloadStorage.chapterDir(summary, chapter.id)
            guard DownloadStorage.isDone(dir) else { return nil }
            let files = DownloadStorage.imageFiles(in: dir)
            return files.isEmpty ? nil : ExportChapter(title: chapter.title, files: files)
        }
    }

    static func export(_ summary: ComicSummary, as format: ExportFormat) throws -> URL {
        let chapters = chapters(for: summary)
        guard !chapters.isEmpty else { throw AppError.message(L("沒有可匯出的內容")) }
        let url = DownloadStorage.exports.appendingPathComponent("\(sanitize(summary.title)).\(format.rawValue)")
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .cbz: try writeCBZ(chapters, to: url)
        case .pdf: try writePDF(chapters, to: url)
        case .epub: try writeEPUB(summary, chapters, to: url)
        }
        return url
    }

    // MARK: CBZ

    private static func writeCBZ(_ chapters: [ExportChapter], to url: URL) throws {
        let zip = try ZipWriter(url: url)
        for (index, chapter) in chapters.enumerated() {
            let prefix = chapters.count > 1 ? String(format: "%03d_%@/", index + 1, sanitize(chapter.title)) : ""
            for file in chapter.files {
                try autoreleasepool { try zip.add(name: prefix + file.lastPathComponent, data: try Data(contentsOf: file)) }
            }
        }
        try zip.finish()
    }

    // MARK: PDF

    private static func writePDF(_ chapters: [ExportChapter], to url: URL) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { context in
            for file in chapters.flatMap(\.files) {
                autoreleasepool {
                    guard let image = UIImage(contentsOfFile: file.path) else { return }
                    let rect = CGRect(origin: .zero, size: image.size)
                    context.beginPage(withBounds: rect, pageInfo: [:])
                    image.draw(in: rect)
                }
            }
        }
    }

    // MARK: EPUB（固定版面，一頁一張圖）

    private static func writeEPUB(_ summary: ComicSummary, _ chapters: [ExportChapter], to url: URL) throws {
        let zip = try ZipWriter(url: url)
        try zip.add(name: "mimetype", data: Data("application/epub+zip".utf8))
        try zip.add(name: "META-INF/container.xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8))

        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        var spine = ""
        var navItems = ""
        var number = 0
        for chapter in chapters {
            var firstPage: String?
            for file in chapter.files {
                number += 1
                let ext = file.pathExtension.lowercased()
                let imageName = String(format: "images/%05d.%@", number, ext)
                let pageName = String(format: "page_%05d.xhtml", number)
                let size = imageSize(file)
                try zip.add(name: "OEBPS/\(imageName)", data: try Data(contentsOf: file))
                try zip.add(name: "OEBPS/\(pageName)", data: Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(number)</title><meta name="viewport" content="width=\(Int(size.width)), height=\(Int(size.height))"/><style>html,body{margin:0;padding:0}img{width:100%;height:100%}</style></head><body><img src="\(imageName)" alt=""/></body></html>
                """.utf8))
                let cover = number == 1 ? " properties=\"cover-image\"" : ""
                manifest += "<item id=\"img\(number)\" href=\"\(imageName)\" media-type=\"\(mediaType(ext))\"\(cover)/>\n"
                manifest += "<item id=\"p\(number)\" href=\"\(pageName)\" media-type=\"application/xhtml+xml\"/>\n"
                spine += "<itemref idref=\"p\(number)\"/>\n"
                if firstPage == nil { firstPage = pageName }
            }
            if let firstPage { navItems += "<li><a href=\"\(firstPage)\">\(xmlEscape(chapter.title))</a></li>\n" }
        }

        try zip.add(name: "OEBPS/nav.xhtml", data: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目錄</title></head><body><nav epub:type="toc"><ol>
        \(navItems)</ol></nav></body></html>
        """.utf8))
        try zip.add(name: "OEBPS/content.opf", data: Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(xmlEscape(summary.title))</dc:title><dc:language>zh</dc:language><meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta><meta property="rendition:layout">pre-paginated</meta></metadata>
        <manifest>
        \(manifest)</manifest>
        <spine>
        \(spine)</spine></package>
        """.utf8))
        try zip.finish()
    }

    private static func imageSize(_ file: URL) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return CGSize(width: 1000, height: 1400)
        }
        return CGSize(width: w, height: h)
    }

    private static func mediaType(_ ext: String) -> String {
        switch ext {
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }

    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "comic" : cleaned).prefix(80))
    }
}
