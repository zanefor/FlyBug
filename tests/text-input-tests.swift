import AppKit

@main
struct TextInputTests {
    static func main() {
        var count = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        func issue(_ location: Int, _ length: Int, kind: String = "spelling") -> WritingIssue {
            WritingIssue(range: NSRange(location: location, length: length), message: "Test", kind: kind, suggestions: [])
        }

        let text = "中文🪰 This are a test."
        let utf16 = text as NSString
        let sample = InputTextSample.extract(text, selection: NSRange(location: utf16.length, length: 0))!
        expect(sample.text == text && sample.offset == 0, "Short text retains full UTF-16 context")
        expect(InputTextSample.extract(text, selection: NSRange(location: -1, length: 0)) == nil, "Reject negative caret")
        expect(InputTextSample.extract(text, selection: NSRange(location: utf16.length + 1, length: 0)) == nil, "Reject out-of-bounds caret")
        expect(InputTextSample.extract(text, selection: NSRange(location: 0, length: Int.max)) == nil, "Reject overflowing selection")
        expect(InputTextSample.extract("", selection: NSRange(location: 0, length: 0)) == nil, "Empty fields are not checked")

        let incomplete = "This is a missspel"
        let end = (incomplete as NSString).length
        let partial = InputTextSample.extract(incomplete, selection: NSRange(location: end, length: 0))!
        expect(!InputTextSample.shouldReport(issue(10, 8), sample: partial, selection: NSRange(location: end, length: 0)), "Do not flag the unfinished word under the caret")
        let finished = InputTextSample.extract(incomplete + " ", selection: NSRange(location: end + 1, length: 0))!
        expect(InputTextSample.shouldReport(issue(10, 8), sample: finished, selection: NSRange(location: end + 1, length: 0)), "Check the word after a separator")
        expect(InputTextSample.shouldReport(issue(0, 4, kind: "grammar"), sample: partial, selection: NSRange(location: end, length: 0)), "Earlier grammar issues remain eligible while typing elsewhere")
        let typo = InputTextSample.extract("hollw", selection: NSRange(location: 5, length: 0))!
        let caretAtEnd = NSRange(location: 5, length: 0)
        expect(!InputTextSample.shouldReport(issue(0, 5), sample: typo, selection: caretAtEnd, stableFor: 0.45), "Initial debounce defers a possibly unfinished English word")
        expect(!InputTextSample.shouldReport(issue(0, 5), sample: typo, selection: caretAtEnd, stableFor: 0.79), "Allow a little more time to finish the caret word")
        expect(InputTextSample.shouldReport(issue(0, 5), sample: typo, selection: caretAtEnd, stableFor: 0.8), "A final typo such as hollw is checked after settling without a trailing space")
        expect(InputTextSample.shouldReport(issue(0, 5), sample: typo, selection: caretAtEnd, stableFor: 20), "An unchanged final typo remains eligible on subsequent ticks")
        expect(!InputTextSample.shouldReport(issue(0, 5), sample: typo, selection: caretAtEnd, stableFor: 0), "Resuming typing resets the pause and defers the active word again")
        let grammarText = "This are a test"
        let grammarEnd = (grammarText as NSString).length
        let grammarSample = InputTextSample.extract(grammarText, selection: NSRange(location: grammarEnd, length: 0))!
        let grammarCaret = NSRange(location: grammarEnd, length: 0)
        let sentenceIssue = issue(0, grammarEnd, kind: "grammar")
        expect(!InputTextSample.shouldReport(sentenceIssue, sample: grammarSample, selection: grammarCaret, stableFor: 0.45), "A sentence-wide grammar finding waits while its final word is being typed")
        expect(InputTextSample.shouldReport(sentenceIssue, sample: grammarSample, selection: grammarCaret, stableFor: 0.8), "Grammar spanning the final word is reported after settling without punctuation")
        expect(InputTextSample.shouldReport(issue(0, 5), sample: typo, selection: NSRange(location: 0, length: 5), stableFor: 0.45), "A selected completed word does not need the caret-word delay")
        expect(InputTextSample.activeEnglishWord("中文", selection: NSRange(location: 2, length: 0)) == nil, "Do not suppress completed Chinese text")
        expect(!InputTextSample.shouldReport(issue(Int.max, 10), sample: sample, selection: NSRange(location: 0, length: 0)), "Reject invalid checker offsets")

        let unicodeLong = String(repeating: "🪰e\u{301} ", count: 1_600)
        let unicodeSample = InputTextSample.extract(unicodeLong, selection: NSRange(location: 3_555, length: 0))!
        expect((unicodeSample.text as NSString).length <= 4_010, "Long paragraphs use a bounded sample")
        let reconstructedRange = NSRange(location: unicodeSample.offset, length: (unicodeSample.text as NSString).length)
        expect(Range(reconstructedRange, in: unicodeLong) != nil, "Sampling preserves Unicode boundaries")
        expect(unicodeSample.text == (unicodeLong as NSString).substring(with: reconstructedRange), "Offsets reconstruct original text exactly")
        expect(!InputTextSample.shouldReport(issue(0, 2), sample: unicodeSample, selection: NSRange(location: 3_555, length: 0)), "Clipped leading fragment is not a spelling finding")
        expect(!InputTextSample.shouldReport(issue(0, 2), sample: unicodeSample, selection: NSRange(location: 3_555, length: 0), stableFor: 20), "Settling never makes a clipped sample boundary reliable")

        let longDocument = String(repeating: "First paragraph.\n", count: 300) + "中文🪰 This are a test.\n"
        let paragraph = InputTextSample.extract(longDocument, selection: NSRange(location: (longDocument as NSString).length - 2, length: 0))!
        expect(paragraph.text == "中文🪰 This are a test.\n", "Long documents check the paragraph around the caret")
        expect(paragraph.offset == (String(repeating: "First paragraph.\n", count: 300) as NSString).length, "Paragraph offsets remain UTF-16 offsets")
        expect(InputTextSample.firstTargetRange(in: " \n\te\u{301} sentence", range: NSRange(location: 0, length: 14)) == NSRange(location: 3, length: 2), "A multiline grammar anchor skips blanks and retains a full accented character")
        expect(InputTextSample.firstTargetRange(in: " 🪰 sentence", range: NSRange(location: 0, length: 12)) == NSRange(location: 1, length: 2), "Anchor ranges never split an emoji surrogate pair")
        expect(InputTextSample.firstTargetRange(in: "prefix word", range: NSRange(location: 7, length: 4)) == NSRange(location: 7, length: 1), "Anchor stays within the reported grammar range")
        expect(InputTextSample.firstTargetRange(in: " \n\t", range: NSRange(location: 0, length: 3)) == nil, "Blank text cannot supply a target")
        expect(InputTextSample.firstTargetRange(in: "🪰", range: NSRange(location: 1, length: 1)) == nil, "Malformed UTF-16 anchor ranges are rejected")
        print("PASS: \(count) text input sampling and typing checks")
    }
}
