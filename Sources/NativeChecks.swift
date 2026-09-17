import Foundation

enum NativeChecks {
    static func run() {
        var count = 0
        func check(_ passed: @autoclosure () -> Bool, _ message: String) {
            guard passed() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            count += 1
        }
        func request(_ text: String) -> HTTPParseResult { HTTPParser.parse(Data(text.utf8)) }
        if case .incomplete = request("GET /health HTTP/1.1\r\nHost: 127.") { count += 1 } else { check(false, "fragmented header") }
        if case .incomplete = request("POST /diagnostics HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}") { count += 1 } else { check(false, "fragmented body") }
        if case .invalid(400) = request("POST /diagnostics HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 5\r\n\r\n{}") { count += 1 } else { check(false, "duplicate content length rejected") }
        if case .invalid(400) = request("POST /diagnostics HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") { count += 1 } else { check(false, "chunked rejected") }
        if case .invalid(413) = request("POST /diagnostics HTTP/1.1\r\nContent-Length: 900000\r\n\r\n") { count += 1 } else { check(false, "oversize body rejected before allocation") }
        if case .invalid(400) = request("GET /health HTTP/1.1\r\n\r\nEXTRA") { count += 1 } else { check(false, "pipelining rejected") }
        if case .request(let parsed) = request("GET /health HTTP/1.1\r\nAuthorization: Bearer abc\r\n\r\n") {
            check(HTTPParser.authorized(parsed, token: "abc"), "correct auth")
            check(!HTTPParser.authorized(parsed, token: "xyz"), "wrong auth")
        } else { check(false, "valid request parse") }
        if case .request(let parsed) = request("GET /health HTTP/1.1\r\nAuthorization: Bearer abc\r\nOrigin: https://example.com\r\n\r\n") {
            check(!HTTPParser.authorized(parsed, token: "abc"), "web Origin rejected even with token")
        } else { check(false, "origin parse") }
        var settings = FlySettings()
        settings.update(["size": 999, "speed": -2, "opacity": Double.infinity, "screenMonitoring": true])
        check(settings.size == 42 && settings.speed == 0.4, "settings clamped")
        check(settings.opacity == 0.9 && settings.screenMonitoring, "invalid numeric setting ignored")
        let previousSettings = Data(#"{"size":24,"speed":0.8,"opacity":0.65,"idleFlight":false,"includeWarnings":true,"screenMonitoring":true,"scanInterval":5}"#.utf8)
        let restored = FlySettings.restored(from: previousSettings)
        check(restored.size == 24 && restored.speed == 0.8 && restored.opacity == 0.65 && !restored.idleFlight, "v1.0 appearance settings migrate")
        check(restored.includeWarnings && restored.screenMonitoring && restored.scanInterval == 5, "v1.0 diagnostic settings migrate")
        check(restored.textChecking && restored.checkSpelling && restored.textLanguage == "auto", "new writing options get defaults without resetting old settings")
        var writingSettings = restored
        writingSettings.update(["textChecking": false, "checkSpelling": false, "textLanguage": "zh_Hans"])
        check(!writingSettings.textChecking && !writingSettings.checkSpelling && writingSettings.textLanguage == "zh_Hans", "writing toggles are independent")
        writingSettings.update(["textLanguage": "invalid"])
        check(writingSettings.textLanguage == "zh_Hans", "unsupported language setting ignored")
        check(DiagnosticText.severity(in: "TypeError: undefined is not an object", includeWarnings: false) == "error", "visible exception recognized")
        check(DiagnosticText.severity(in: "throw new Error('oops')", includeWarnings: true) == nil, "source statement not an error report")
        check(DiagnosticText.severity(in: "warning: unused variable", includeWarnings: false) == nil, "warnings opt in")
        check(DiagnosticText.uniqueSnippetIndex("const result = price * count;", line: 3, rows: ["3 const result = price * count;"]) == 0, "line gutter recognized")
        check(DiagnosticText.uniqueSnippetIndex("return value;", line: nil, rows: ["return value;", "return value;"]) == nil, "ambiguous code not targeted")
        let p = DiagnosticText.point(normalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1), window: CGRect(x: -1000, y: 100, width: 800, height: 600))
        check(abs(p.x + 840) < 0.01 && abs(p.y - 550) < 0.01, "OCR coordinate conversion on secondary display")
        print("PASS: \(count) native checks")
    }
}
