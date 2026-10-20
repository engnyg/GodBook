import Foundation

/// 章節清單的排列方向：有些來源是舊到新，有些是新到舊（最新一話在最前面）。
/// 依章節標題（其次是章節 ID）裡的數字判斷；無法判斷時當作舊到新。
extension ComicDetail {
    var chaptersDescending: Bool {
        guard chapters.count > 1 else { return false }
        if let result = Self.compare(chapters.map(\.title), first: true) { return result }
        if let result = Self.compare(chapters.map(\.id), first: false) { return result }
        return false
    }

    /// 從頭閱讀時該從哪一章開始（舊到新 = 第一個；新到舊 = 最後一個）
    var firstReadIndex: Int { chaptersDescending ? max(chapters.count - 1, 0) : 0 }

    /// 依閱讀順序的下一章 / 上一章索引（沒有則為 nil）
    func nextIndex(after index: Int) -> Int? {
        let target = chaptersDescending ? index - 1 : index + 1
        return chapters.indices.contains(target) ? target : nil
    }

    func previousIndex(before index: Int) -> Int? {
        let target = chaptersDescending ? index + 1 : index - 1
        return chapters.indices.contains(target) ? target : nil
    }

    private static func number(in text: String, first: Bool) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard let match = first ? matches.first : matches.last, let r = Range(match.range, in: text) else { return nil }
        return Double(text[r])
    }

    /// 比較清單前段與後段的平均數字：前段較大 = 新到舊；兩者相同或抓不到數字回傳 nil
    private static func compare(_ texts: [String], first: Bool) -> Bool? {
        let numbers = texts.map { number(in: $0, first: first) }
        let head = numbers.prefix(4).compactMap { $0 }
        let tail = numbers.suffix(4).compactMap { $0 }
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        let headAverage = head.reduce(0, +) / Double(head.count)
        let tailAverage = tail.reduce(0, +) / Double(tail.count)
        if headAverage == tailAverage { return nil }
        return headAverage > tailAverage
    }
}
