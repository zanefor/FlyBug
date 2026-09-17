import Foundation
import CoreGraphics

@main
struct DiagnosticTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !condition() { fputs("FAIL: \(description)\n", stderr); exit(1) }
    }
    static func main() throws {
        let errors = [
            "TypeError: Cannot read properties of undefined (reading 'id')",
            "SyntaxError: invalid syntax",
            "Uncaught TypeError: x is not a function",
            "Unhandled RuntimeException: missing config",
            "src/main.swift:12:8: error: cannot find 'x' in scope",
            "/tmp/demo.ts(42,7): error TS2322: Type 'string' is not assignable",
            "error[E0308]: mismatched types",
            "Traceback (most recent call last):",
            "panic: runtime error: index out of range",
            "thread 'main' panicked at src/main.rs:9:5:",
            "FAILED tests/test_math.py::test_add",
            "错误：变量未定义"
        ]
        for value in errors { expect(DiagnosticText.severity(in: value, includeWarnings: false) == "error", "recognize \(value)") }
        let sourceAndNeutralText = [
            "let message = \"TypeError: cannot find x\"",
            "const error = new Error('bad input')",
            "throw new Error('bad input')",
            "raise TypeError('bad input')",
            "// TypeError: example from the docs",
            "# error: example comment",
            "\"TypeError: not an actual error\"",
            "'Error: sample'",
            "print(\"error: demo\")",
            "console.error('error: demo')",
            "No errors found",
            "0 errors, 2 warnings",
            "function handleError(error) {",
            "The Error: explanation is in the docs",
            "return Error: message"
        ]
        for value in sourceAndNeutralText { expect(DiagnosticText.severity(in: value, includeWarnings: true) == nil, "ignore source/neutral \(value)") }
        expect(DiagnosticText.severity(in: "warning: unused variable", includeWarnings: false) == nil, "warnings disabled")
        expect(DiagnosticText.severity(in: "warning: unused variable", includeWarnings: true) == "warning", "warnings enabled")
        expect(DiagnosticText.severity(in: "main.swift:12:8: warning: unused variable", includeWarnings: true) == "warning", "compiler warning")

        expect(DiagnosticText.uniqueSnippetIndex("return data.value", line: 42, rows: ["41 let data = nil", "42 return data.value"]) == 1, "visible gutter maps correct line")
        expect(DiagnosticText.uniqueSnippetIndex("return data.value", line: 42, rows: ["19 return data.value"]) == nil, "different gutter rejected")
        expect(DiagnosticText.uniqueSnippetIndex("return data.value", line: nil, rows: ["return data.value", "return data.value"]) == nil, "duplicate code is ambiguous")
        expect(DiagnosticText.uniqueSnippetIndex("return data.value", line: 42, rows: ["19 return data.value", "42 return data.value"]) == 1, "gutter disambiguates duplicates")
        expect(DiagnosticText.uniqueSnippetIndex("}", line: 42, rows: ["42 }"]) == nil, "short snippets cannot target arbitrary brace")
        expect(DiagnosticText.uniqueSnippetIndex("return data.value", line: nil, rows: ["returndata.value"]) == 0, "OCR whitespace variance")
        expect(DiagnosticText.messageIndex("TypeError: cannot read property 'id'", rows: ["some other error", "TypeError: cannot read property 'id'"]) == 1, "exact visible error")
        expect(DiagnosticText.messageIndex("TypeError: cannot read property 'id'", rows: ["TypeError: cannot read property 'id'", "TypeError: cannot read property 'id'"]) == nil, "duplicate error locations rejected")
        expect(DiagnosticText.messageIndex("Error", rows: ["Error"]) == nil, "generic message too short")

        expect(DiagnosticText.fileMatches("/project/src/main.ts", document: "file:///project/src/main.ts", title: "Anything"), "AX document verifies absolute file")
        expect(!DiagnosticText.fileMatches("/project/src/main.ts", document: "file:///other/src/main.ts", title: "main.ts — Code"), "conflicting AX document overrides title")
        expect(DiagnosticText.fileMatches("main.ts", document: "file:///project/src/main.ts", title: ""), "relative bridge file matches document filename")
        expect(DiagnosticText.fileMatches("/project/src/main.ts", document: nil, title: "main.ts — project — Visual Studio Code"), "visible filename verifies OCR context")
        expect(!DiagnosticText.fileMatches("/project/src/main.ts", document: nil, title: "other-main.ts — Code"), "partial filename rejected")
        expect(!DiagnosticText.fileMatches("/project/src/main.ts", document: nil, title: "main.tsx — Code"), "different extension rejected")
        expect(!DiagnosticText.fileMatches("/project/src/main.ts", document: nil, title: "Settings"), "unrelated file rejected")

        let p = DiagnosticText.point(normalizedBox: CGRect(x: 0.2, y: 0.7, width: 0.2, height: 0.1), window: CGRect(x: 100, y: 50, width: 1000, height: 800))
        expect(abs(p.x - 400) < 0.001 && abs(p.y - 250) < 0.001, "Vision bottom-left converts to Quartz top-left")
        let second = DiagnosticText.point(normalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1), window: CGRect(x: -1920, y: -200, width: 1920, height: 1080))
        expect(second == ScreenPoint(x: -960, y: 340), "secondary display negative origin retained")
        let id = DiagnosticText.diagnosticID("same error")
        expect(id == DiagnosticText.diagnosticID("same error") && id != DiagnosticText.diagnosticID("other error"), "stable deduplication IDs")
        let diagnostic = BugDiagnostic(id: "test", source: "bridge", message: "test", severity: "error", file: "main.ts", line: 42, target: p)
        let decoded = try JSONDecoder().decode(BugDiagnostic.self, from: JSONEncoder().encode(diagnostic))
        expect(decoded.target == p && decoded.line == 42 && decoded.column == nil, "bridge JSON round trip")
        print("PASS: \(checks) diagnostic parser, identity, matching, coordinate, and JSON checks")
    }
}
