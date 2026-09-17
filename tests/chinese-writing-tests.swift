import Foundation

@main
struct ChineseWritingTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !condition() { fputs("FAIL: \(description)\n", stderr); exit(1) }
    }

    static func main() {
        let examples: [(String, String, String)] = [
            ("这是我的的书。", "的的", "的"),
            ("她认真的学习。", "的", "地"),
            ("请仔细 的 检查。", "的", "地"),
            ("他耐心的听讲。", "的", "地"),
            ("我们开心的工作。", "的", "地"),
            ("他跑的很快。", "的", "得"),
            ("她写 的 非常 好！", "的", "得"),
            ("他说的特别清楚", "的", "得")
        ]
        for (text, fragment, suggestion) in examples {
            let results = ChineseWritingRules.issues(in: text)
            expect(results.count == 1, "one focused hint for \(text)")
            if let issue = results.first {
                expect((text as NSString).substring(with: issue.range) == fragment, "precise error range for \(text)")
                expect(issue.suggestions == [suggestion] && issue.kind == "grammar", "correct particle/repetition suggestion")
            }
        }

        let untouched = [
            "这是我的书。", "她认真地学习。", "他跑得很快。", "认真的态度很重要。",
            "认真的学习态度。", "他写的很好的文章值得阅读。", "目的的实现需要努力。",
            "标的的价值有所提高。", "这件事的的确确发生过。", "的的喀喀湖很美。",
            "好的的确不多。", "的的", "He go to school.", "",
            "这是“我的的书”。", "示例：‘她认真的学习。’", "例句：「他跑的很快。」",
            "引用『他跑的很快。』。", "\"她认真的学习。\"", "'我的的书'",
            "`他跑的很快。`", "```text\n我的的书\n```", "引用未结束：“我的的书",
            "未闭合代码：`我的的书", "https://example.com/我的的书", "www.example.com/我的的书"
        ]
        for text in untouched { expect(ChineseWritingRules.issues(in: text).isEmpty, "leave valid/ambiguous/quoted text untouched: \(text)") }

        let emoji = "🪰😀他跑的很快。"
        let emojiIssue = ChineseWritingRules.issues(in: emoji).first
        expect(emojiIssue?.range == (emoji as NSString).range(of: "的"), "emoji prefix preserves UTF-16 position")
        let mixed = "https://example.com/我的的书；\n这也是我的的书。她认真的学习。"
        let mixedIssues = ChineseWritingRules.issues(in: mixed)
        expect(mixedIssues.count == 2, "ignore URL but check later prose")
        expect(mixedIssues.map(\.range.location) == mixedIssues.map(\.range.location).sorted(), "stable document order")
        expect(ChineseWritingRules.issues(in: String(repeating: "我", count: 20_001) + "的的书").isEmpty, "bounded input size")
        expect(ChineseWritingRules.issues(in: String(repeating: "我的的书。", count: 30)).count == 12, "bounded hint count")
        print("PASS: \(checks) Chinese usage, context, exclusion, UTF-16 and bounds checks")
    }
}
