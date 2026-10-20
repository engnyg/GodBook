import Foundation

enum Blocklist {
    /// 標題、副標題或標籤包含任何屏蔽關鍵字就回傳 true
    static func blocks(_ summary: ComicSummary) -> Bool {
        if SafeMode.hides(summary) { return true }
        let words = AppSettings.shared.blockedWords.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        let haystack = ([summary.title, summary.subtitle ?? ""] + (summary.tags ?? [])).joined(separator: "\n").lowercased()
        return words.contains { haystack.contains($0) }
    }

    static func blocksComment(_ text: String) -> Bool {
        let lower = text.lowercased()
        return AppSettings.shared.blockedCommentWords.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
    }
}
