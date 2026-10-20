import Foundation
import SwiftSoup

/// 把評論內容（純文字或含少量 HTML 標籤）轉成可顯示的 AttributedString。
/// 支援 a / b / strong / i / em / u / s / del / br / span(style) / img，並自動偵測 http(s) 連結。
enum RichComment {
    struct Parsed {
        var text: AttributedString
        var images: [URL]
    }

    private struct Style {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var link: URL?
    }

    static func parse(_ raw: String) -> Parsed {
        guard raw.contains("<"), raw.contains(">"),
              let document = try? SwiftSoup.parseBodyFragment(raw), let body = document.body() else {
            return Parsed(text: linkified(AttributedString(raw.trimmingCharacters(in: .whitespacesAndNewlines))), images: [])
        }
        var output = AttributedString()
        var images: [URL] = []
        walk(body, Style(), &output, &images)
        let plain = String(output.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.isEmpty && images.isEmpty { return Parsed(text: AttributedString(raw), images: []) }
        return Parsed(text: linkified(output), images: images)
    }

    private static func walk(_ node: Node, _ style: Style, _ output: inout AttributedString, _ images: inout [URL]) {
        for child in node.getChildNodes() {
            if let text = child as? TextNode {
                var piece = AttributedString(text.getWholeText())
                var intent: InlinePresentationIntent = []
                if style.bold { intent.insert(.stronglyEmphasized) }
                if style.italic { intent.insert(.emphasized) }
                if !intent.isEmpty { piece.inlinePresentationIntent = intent }
                if style.underline { piece.underlineStyle = .single }
                if style.strike { piece.strikethroughStyle = .single }
                if let link = style.link { piece.link = link }
                output.append(piece)
            } else if let element = child as? Element {
                var next = style
                switch element.tagName().lowercased() {
                case "br":
                    output.append(AttributedString("\n"))
                    continue
                case "b", "strong": next.bold = true
                case "i", "em": next.italic = true
                case "u": next.underline = true
                case "s", "del", "strike": next.strike = true
                case "a":
                    if let href = try? element.attr("href"), let url = URL(string: href), ["http", "https"].contains(url.scheme?.lowercased()) {
                        next.link = url
                    }
                case "img":
                    if let src = try? element.attr("src"), let url = URL(string: src) { images.append(url) }
                    continue
                case "span":
                    let css = ((try? element.attr("style")) ?? "").lowercased()
                    if css.contains("font-weight:bold") || css.contains("font-weight: bold") || css.contains("font-weight:700") { next.bold = true }
                    if css.contains("font-style:italic") || css.contains("font-style: italic") { next.italic = true }
                    if css.contains("underline") { next.underline = true }
                    if css.contains("line-through") { next.strike = true }
                default: break
                }
                walk(element, next, &output, &images)
            }
        }
    }

    private static func linkified(_ text: AttributedString) -> AttributedString {
        var result = text
        let string = String(text.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        let matches = detector.matches(in: string, range: NSRange(string.startIndex..., in: string))
        for match in matches {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()),
                  let range = Range(match.range, in: string) else { continue }
            let lower = result.index(result.startIndex, offsetByCharacters: string.distance(from: string.startIndex, to: range.lowerBound))
            let upper = result.index(result.startIndex, offsetByCharacters: string.distance(from: string.startIndex, to: range.upperBound))
            if result[lower..<upper].link == nil { result[lower..<upper].link = url }
        }
        return result
    }
}
