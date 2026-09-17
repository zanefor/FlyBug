import Foundation

/// A small local set of Chinese usage hints, not a general Chinese grammar checker.
/// Particle rules stop at a clause boundary to avoid treating noun phrases such as
/// “认真的学习态度” and “他写的很好的文章” as adverbial/complement constructions.
enum ChineseWritingRules {
    private static let repeated = try? NSRegularExpression(pattern: #"(?<=[\p{Han}])的的|的的(?=[\p{Han}])"#)
    private static let adverb = try? NSRegularExpression(
        pattern: #"(?:认真|仔细|耐心|开心)[\t \u3000]*(的)[\t \u3000]*(?:学习|工作|检查|听讲|听|阅读)(?=[\t \u3000]*(?:[，。！？；：、,.!?;:\r\n]|$))"#)
    private static let complement = try? NSRegularExpression(
        pattern: #"(?:跑|走|唱|写|说|做)[\t \u3000]*(的)[\t \u3000]*(?:很|非常|特别)[\t \u3000]*(?:快|慢|好|清楚|认真|开心)(?=[\t \u3000]*(?:[，。！？；：、,.!?;:\r\n]|$))"#)
    private static let ignoredPatterns = [
        #"(?:https?://|www\.)[^\s<>\"“”‘’「」『』]+"#,
        #"`{1,3}[\s\S]*?(?:`{1,3}|$)"#,
        #"“[^”]*(?:”|$)|‘[^’]*(?:’|$)|「[^」]*(?:」|$)|『[^』]*(?:』|$)|\"[^\"\r\n]*(?:\"|$)|'[^'\r\n]*(?:'|$)"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func issues(in text: String) -> [WritingIssue] {
        let string = text as NSString
        guard string.length > 0, string.length <= 20_000 else { return [] }
        let whole = NSRange(location: 0, length: string.length)
        let ignored = ignoredPatterns.flatMap { $0.matches(in: text, range: whole).map(\.range) }
        var found: [WritingIssue] = []

        func append(_ range: NSRange, in match: NSRange, replacement: String, message: String) {
            guard range.location != NSNotFound, range.length > 0,
                  Range(range, in: text) != nil,
                  !ignored.contains(where: { NSIntersectionRange($0, match).length > 0 }),
                  !found.contains(where: { $0.range == range }) else { return }
            found.append(WritingIssue(range: range, message: message, kind: "grammar", suggestions: [replacement]))
        }

        for match in repeated?.matches(in: text, range: whole) ?? [] {
            let before = match.range.location > 0 ? string.substring(with: NSRange(location: match.range.location - 1, length: 1)) : ""
            let end = NSMaxRange(match.range)
            let after = end < string.length ? string.substring(from: end) : ""
            // “目的的实现” / “标的的价值” are valid; “的的确确” and “的的喀喀湖”
            // contain the same characters without an accidentally repeated particle.
            guard before != "目", before != "标", !after.hasPrefix("确"), !after.hasPrefix("喀喀") else { continue }
            append(match.range, in: match.range, replacement: "的", message: "重复用字提示：“的的”可能重复 · 建议：的")
        }
        for match in adverb?.matches(in: text, range: whole) ?? [] {
            append(match.range(at: 1), in: match.range, replacement: "地",
                   message: "中文用字提示：这处“的”可能应为“地”，用来修饰动作 · 建议：地")
        }
        for match in complement?.matches(in: text, range: whole) ?? [] {
            append(match.range(at: 1), in: match.range, replacement: "得",
                   message: "中文用字提示：这处“的”可能应为“得”，引出动作的程度 · 建议：得")
        }
        return Array(found.sorted { $0.range.location < $1.range.location }.prefix(12))
    }
}
