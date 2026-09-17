import AppKit

@main
struct WritingEngineTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !condition() { fputs("FAIL: \(description)\n", stderr); exit(1) }
    }
    static func grammar(_ sentence: NSRange, _ relative: NSRange, corrections: [String] = []) -> NSTextCheckingResult {
        .grammarCheckingResult(range: sentence, details: [[
            NSGrammarRange: NSValue(range: relative),
            NSGrammarCorrections: corrections,
            NSGrammarUserDescription: "Test grammar finding"
        ]])
    }
    static func main() {
        let text = "✅ 😀 Good. I bought a apple."
        let sentence = (text as NSString).range(of: "I bought a apple.")
        let article = (text as NSString).range(of: "a apple")
        let result = grammar(sentence, NSRange(location: 9, length: 1), corrections: ["an"])
        let findings = WritingEngine.issues(from: [result], text: text, checkSpelling: true)
        expect(findings.count == 1, "one grammar issue")
        expect(findings.first?.range == NSRange(location: article.location, length: 1), "sentence-relative UTF-16 range survives emoji prefix")
        expect(findings.first?.suggestions == ["an"], "correction preserved")
        expect(findings.first?.message.contains("“a”") == true, "message quotes exact affected text")
        expect(findings.first?.kind == "grammar", "grammar classification")

        let misspelling = NSTextCheckingResult.spellCheckingResult(range: NSRange(location: 10, length: 7))
        expect(WritingEngine.issues(from: [misspelling], text: "This is a sentnce.", checkSpelling: true).count == 1, "spelling enabled")
        expect(WritingEngine.issues(from: [misspelling], text: "This is a sentnce.", checkSpelling: false).isEmpty, "spelling toggle suppresses spelling")
        expect(WritingEngine.issues(from: [result], text: text, checkSpelling: false).count == 1, "spelling toggle preserves grammar")
        expect(WritingEngine.issues(from: [result, result], text: text, checkSpelling: true).count == 1, "duplicate findings collapse")

        let corrupt = [
            grammar(sentence, NSRange(location: NSNotFound, length: 1)),
            grammar(sentence, NSRange(location: Int.max, length: 1)),
            grammar(sentence, NSRange(location: 1, length: Int.max)),
            grammar(sentence, NSRange(location: sentence.length, length: 1)),
            grammar(sentence, NSRange(location: 0, length: 0)),
            grammar(NSRange(location: Int.max, length: 1), NSRange(location: 0, length: 1))
        ]
        expect(WritingEngine.issues(from: corrupt, text: text, checkSpelling: true).isEmpty, "corrupt ranges do not crash or target unrelated text")
        let wrongType = NSTextCheckingResult.grammarCheckingResult(range: sentence, details: [
            [NSGrammarRange: "not a range"],
            [NSGrammarRange: NSValue(point: NSPoint(x: 1, y: 2))]
        ])
        expect(WritingEngine.issues(from: [wrongType], text: text, checkSpelling: true).isEmpty, "malformed grammar detail values do not crash or target a sentence")
        let noDetailRange = NSTextCheckingResult.grammarCheckingResult(range: sentence, details: [[NSGrammarUserDescription: "Whole sentence issue"]])
        expect(WritingEngine.issues(from: [noDetailRange], text: text, checkSpelling: true).first?.range == sentence, "absent detail range uses documented sentence scope")
        expect(!WritingEngine.valid(NSRange(location: 0, length: 1), in: "😀"), "split surrogate rejected")
        expect(WritingEngine.valid(NSRange(location: 0, length: 2), in: "😀"), "whole emoji UTF-16 range accepted")

        for token in ["https://example.com/sentnce", "sentnce@example.com", "get_sentnce", "getSentnce"] {
            let whole = NSRange(location: 0, length: (token as NSString).length)
            let issue = NSTextCheckingResult.spellCheckingResult(range: whole)
            expect(WritingEngine.issues(from: [issue], text: token, checkSpelling: true).isEmpty, "technical token excluded: \(token)")
        }
        let adjacentText = "Visit https://example.com and fix the sentnce."
        let adjacent = NSTextCheckingResult.spellCheckingResult(range: (adjacentText as NSString).range(of: "sentnce"))
        expect(WritingEngine.issues(from: [adjacent], text: adjacentText, checkSpelling: true).count == 1, "technical token does not hide nearby prose errors")
        let punctuation = NSTextCheckingResult.spellCheckingResult(range: NSRange(location: 0, length: 3))
        expect(WritingEngine.issues(from: [punctuation], text: "...", checkSpelling: true).isEmpty, "punctuation is not a spelling target")
        print("PASS: \(checks) writing range, grammar, spelling, and token checks")
    }
}
