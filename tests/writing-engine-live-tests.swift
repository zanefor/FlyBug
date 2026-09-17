import AppKit

@main
struct EngineLiveTests {
    static func runCheck(_ sample: String, language: String) -> [WritingIssue] {
        var completed = false
        var result: [WritingIssue] = []
        WritingEngine.check(sample, language: language, checkSpelling: true) { issues in
            result = issues
            completed = true
        }
        let deadline = Date().addingTimeInterval(15)
        while !completed && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard completed else { fputs("FAIL: engine timeout \(language)\n", stderr); exit(1) }
        return result
    }
    static func main() {
        _ = NSApplication.shared
        let sample = "This is is a sentence. I bought a apple. This is a sentnce."
        var checks = 0
        for language in ["auto", "en_US"] {
            let result = runCheck(sample, language: language)
            let string = sample as NSString
            print("LANGUAGE", language)
            for issue in result { print(issue.kind, issue.range, string.substring(with: issue.range), issue.suggestions) }
            guard result.contains(where: { $0.kind == "grammar" && string.substring(with: $0.range) == "is is" }) else {
                fputs("FAIL: doubled-word grammar missing \(language)\n", stderr); exit(1)
            }
            checks += 1
            guard result.contains(where: { $0.kind == "grammar" && string.substring(with: $0.range) == "a" && $0.suggestions.contains("an") }) else {
                fputs("FAIL: article grammar missing \(language)\n", stderr); exit(1)
            }
            checks += 1
            guard result.contains(where: { $0.kind == "spelling" && string.substring(with: $0.range) == "sentnce" }) else {
                fputs("FAIL: spelling missing \(language)\n", stderr); exit(1)
            }
            checks += 1
        }
        let corrected = "This is a sentence. I bought an apple. This is a sentence."
        for language in ["auto", "en_US"] {
            let result = runCheck(corrected, language: language)
            print("CORRECTED", language, "issues", result.count)
            guard result.isEmpty else { fputs("FAIL: corrected English flagged \(language)\n", stderr); exit(1) }
            checks += 1
        }
        let chineseCorrect = "这是我的计划。她认真地工作。他跑得很快。"
        let chineseResult = runCheck(chineseCorrect, language: "zh_Hans")
        print("CHINESE CORRECTED issues", chineseResult.count)
        guard chineseResult.isEmpty else { fputs("FAIL: correct Chinese flagged\n", stderr); exit(1) }
        checks += 1
        let chineseIncorrect = "这是我的的计划。"
        let chineseHints = runCheck(chineseIncorrect, language: "zh_Hans")
        print("CHINESE REPEATED issues", chineseHints.count)
        guard chineseHints.count == 1,
              (chineseIncorrect as NSString).substring(with: chineseHints[0].range) == "的的",
              chineseHints[0].suggestions == ["的"] else { fputs("FAIL: Chinese duplicate particle missing or mislocated\n", stderr); exit(1) }
        checks += 1
        print("PASS: \(checks) live native engine checks")
    }
}
