import Foundation

/// 把網址 / 車號 / 文字解析成某個來源的漫畫（用於貼上連結直接開啟、godbook:// 深層連結）。
enum LinkResolver {
    static func looksLikeLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
    }

    @MainActor
    static func resolve(_ raw: String) async -> ComicSummary? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let settings = AppSettings.shared

        // nhentai：…/g/123456/
        if settings.isEnabled(.nhentai),
           let id = firstMatch(#"nhentai\.[a-z.]+/g/(\d+)"#, in: text) {
            return ComicSummary(source: .nhentai, sid: id, title: "#\(id)")
        }
        // 禁漫：…/album/123456 或 …/photo/123456；或 "JM123456"
        if settings.isEnabled(.jmcomic) {
            let lower = text.lowercased()
            if looksLikeLink(text), lower.contains("jm") || lower.contains("18comic"),
               let id = firstMatch(#"/(?:album|photo)/(\d+)"#, in: text) {
                return ComicSummary(source: .jmcomic, sid: id, title: "JM\(id)")
            }
            if let id = firstMatch(#"^(?:JM|jm)(\d{3,})$"#, in: text) {
                return ComicSummary(source: .jmcomic, sid: id, title: "JM\(id)")
            }
        }
        // venera 漫畫源：由腳本的 link / idMatch 決定
        for info in VeneraRegistry.shared.all where settings.isEnabled(info.kind) {
            guard info.comic?.hasLink == true || info.idMatch != nil else { continue }
            let value = try? await VeneraRuntime.shared.callValue(info.key, "__linkToId", [text])
            if let id = value as? String, !id.isEmpty {
                return ComicSummary(source: info.kind, sid: id, title: id)
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// godbook://open?url=<編碼後的網址>
@MainActor
final class DeepLink: ObservableObject {
    static let shared = DeepLink()
    @Published var summary: ComicSummary?

    func handle(_ url: URL) {
        guard url.scheme == "godbook",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "url" })?.value else { return }
        Task { summary = await LinkResolver.resolve(target) }
    }
}
