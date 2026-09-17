import AppKit

struct WritingIssue {
    var range: NSRange
    var message: String
    var kind: String
    var suggestions: [String]
}

enum WritingEngine {
    static func valid(_ range: NSRange, in text: String) -> Bool {
        let length = (text as NSString).length
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= length, range.length <= length - range.location else { return false }
        // Foundation's String.Index conversion accepts some interior UTF-16 offsets.
        // Composed-character validation prevents splitting surrogates or combining marks.
        return (text as NSString).rangeOfComposedCharacterSequences(for: range) == range
    }

    /// Translate grammar's sentence-relative ranges to the original UTF-16 string.
    /// Invalid details are dropped; absent ranges mean the sentence, per NSSpellServer.
    static func issues(from results: [NSTextCheckingResult], text: String, checkSpelling: Bool) -> [WritingIssue] {
        let string = text as NSString
        var found: [WritingIssue] = []
        let technical = try? NSRegularExpression(pattern: #"https?://\S+|\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\b|\b[a-z]+(?:[A-Z][a-z0-9]+)+\b"#)
        let ignored = technical?.matches(in: text, range: NSRange(location: 0, length: string.length)).map(\.range) ?? []
        func append(_ range: NSRange, kind: String, explanation: String?, suggestions: [String]) {
            guard valid(range, in: text), !ignored.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
            let fragment = String(string.substring(with: range).prefix(80))
            guard fragment.contains(where: { $0.isLetter }), fragment.count >= (kind == "spelling" ? 2 : 1) else { return }
            let proposed = Array(suggestions.filter { !$0.isEmpty }.prefix(3)).map { String($0.prefix(120)) }
            let title = kind == "grammar" ? "语法提示" : "拼写提示"
            let detail = explanation.map { String($0.prefix(250)) }
            let suffix = proposed.isEmpty ? (detail.map { " · " + $0 } ?? "") : " · 建议：" + proposed.joined(separator: " / ")
            let issue = WritingIssue(range: range, message: "\(title)：“\(fragment)”\(suffix)", kind: kind, suggestions: proposed)
            if !found.contains(where: { $0.range == issue.range && $0.kind == issue.kind }) { found.append(issue) }
        }
        for result in results.prefix(80) {
            guard valid(result.range, in: text) else { continue }
            if result.resultType == .grammar {
                let details = result.grammarDetails ?? []
                if details.isEmpty { append(result.range, kind: "grammar", explanation: "系统检查器提示这处表达可能有误", suggestions: []) }
                for detail in details.prefix(20) {
                    if let value = detail[NSGrammarRange] {
                        guard let rangeValue = value as? NSValue,
                              String(cString: rangeValue.objCType) == String(cString: NSValue(range: NSRange()).objCType) else { continue }
                    }
                    let relative = (detail[NSGrammarRange] as? NSValue)?.rangeValue ?? NSRange(location: 0, length: result.range.length)
                    guard relative.location != NSNotFound, relative.location >= 0, relative.length > 0,
                          relative.location <= result.range.length, relative.length <= result.range.length - relative.location else { continue }
                    let range = NSRange(location: result.range.location + relative.location, length: relative.length)
                    append(range, kind: "grammar", explanation: detail[NSGrammarUserDescription] as? String,
                           suggestions: detail[NSGrammarCorrections] as? [String] ?? [])
                }
            } else if checkSpelling && result.resultType == .spelling {
                append(result.range, kind: "spelling", explanation: nil, suggestions: [])
            }
        }
        return Array(found.sorted {
            if $0.kind != $1.kind { return $0.kind == "grammar" }
            return $0.range.location < $1.range.location
        }.prefix(12))
    }

    static func check(_ text: String, language: String, checkSpelling: Bool, completion: @escaping ([WritingIssue]) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { check(text, language: language, checkSpelling: checkSpelling, completion: completion) }; return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (text as NSString).length <= 20_000 else {
            completion([]); return
        }
        let chinese = language == "en_US" ? [] : ChineseWritingRules.issues(in: text)
        if language == "zh_Hans" { completion(chinese); return }
        let checker = NSSpellChecker.shared
        checker.automaticallyIdentifiesLanguages = true
        var types = NSTextCheckingResult.CheckingType.grammar.rawValue
        if checkSpelling { types |= NSTextCheckingResult.CheckingType.spelling.rawValue }
        var options: [NSSpellChecker.OptionKey: Any]? = nil
        if language == "auto" { types |= NSTextCheckingResult.CheckingType.orthography.rawValue }
        else { options = [.orthography: NSOrthography.defaultOrthography(forLanguage: language)] }
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        var completed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            guard !completed else { return }
            completed = true
            checker.closeSpellDocument(withTag: tag)
            // The monitor owns user-visible timeout/retry behavior; an unavailable
            // checker must not be converted into a false "no issues" result.
        }
        checker.requestChecking(of: text, range: NSRange(location: 0, length: (text as NSString).length), types: types,
                                options: options, inSpellDocumentWithTag: tag) { _, results, _, _ in
            DispatchQueue.main.async {
                guard !completed else { return }
                completed = true
                checker.closeSpellDocument(withTag: tag)
                let combined = chinese + issues(from: results, text: text, checkSpelling: checkSpelling)
                completion(Array(combined.sorted {
                    if $0.kind != $1.kind { return $0.kind == "grammar" }
                    return $0.range.location < $1.range.location
                }.prefix(12)))
            }
        }
    }
}
