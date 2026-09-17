import AppKit
import ApplicationServices
import Vision
import ScreenCaptureKit

/// Coordinates use Quartz's global desktop space: origin at the primary display's top left.
struct ScreenPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct BugDiagnostic: Codable {
    var id: String
    var source: String
    var message: String
    var severity: String
    var file: String?
    var line: Int?
    var column: Int?
    var lineText: String?
    var target: ScreenPoint?
}

/// Pure helpers are kept separate so matching can be tested without screen permissions.
enum DiagnosticText {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func severity(in raw: String, includeWarnings: Bool) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6, text.count <= 2_000 else { return nil }
        // Source strings, comments, and error-handling statements are not diagnostics.
        if matches(#"^(?:\d+\s+)?(?:[\"'`]|//|/\*|\*|#|(?:let|var|const|return|throw|raise|print|printf|assert|console\.|logger\.|log\.)\b)"#, text) { return nil }
        if matches(#"^(?:Traceback \(most recent call last\):|panic:|thread ['"].+['"] panicked at|Assertion failed:|(?:uncaught|unhandled)\s+(?:[\w.]*error|[\w.]*exception)\b)"#, text) { return "error" }
        if matches(#"^(?:[\w.]*Error|[\w.]*Exception|fatal error|error(?:\[[A-Z]\d+\])?):\s*\S"#, text) { return "error" }
        if matches(#"^.+\.[A-Za-z0-9]{1,10}(?::\d+(?::\d+)?|\(\d+(?:,\d+)?\)):\s*(?:fatal\s+)?error\b"#, text) { return "error" }
        if matches(#"^(?:FAILED\s+[\w./-]+|FAIL\s+[\w./-]+|(?:错误|异常|编译失败|构建失败)\s*[:：]\s*\S)"#, text) { return "error" }
        if includeWarnings && matches(#"^(?:warning(?:\[[\w-]+\])?:\s*\S|.+\.[A-Za-z0-9]{1,10}:\d+(?::\d+)?:\s*warning\b|警告\s*[:：]\s*\S)"#, text) { return "warning" }
        return nil
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    static func removingGutter(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\s*\d+\s+[│|]?\s*"#, with: "", options: .regularExpression)
    }

    static func gutterLine(_ text: String) -> Int? {
        guard let range = text.range(of: #"^\s*\d+(?=\s)"#, options: .regularExpression) else { return nil }
        return Int(text[range].trimmingCharacters(in: .whitespaces))
    }

    /// Duplicate snippets only match when an OCR-visible gutter disambiguates the line.
    static func uniqueSnippetIndex(_ needle: String, line: Int?, rows: [String]) -> Int? {
        let sought = normalized(needle)
        guard sought.count >= 5 else { return nil }
        let candidates = rows.indices.filter { index in
            let text = normalized(rows[index])
            let withoutGutter = normalized(removingGutter(rows[index]))
            return text == sought || withoutGutter == sought
        }
        if let line {
            let numbered = candidates.filter { gutterLine(rows[$0]) == line }
            if numbered.count == 1 { return numbered[0] }
            // A visible different line number is evidence of the wrong occurrence.
            let unnumbered = candidates.filter { gutterLine(rows[$0]) == nil }
            return unnumbered.count == 1 && candidates.count == 1 ? unnumbered[0] : nil
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Vision OCR often drops punctuation or changes one glyph in an editor
    /// line. Keep matching conservative, but allow a unique high-overlap row
    /// so VS Code/Cursor diagnostics do not fall back to the editor center.
    static func fuzzySnippetIndex(_ needle: String, line: Int?, rows: [String]) -> Int? {
        let sought = normalized(needle).lowercased()
        guard sought.count >= 5 else { return nil }
        let scored: [(Int, Double)] = rows.indices.compactMap { index in
            let candidate = normalized(removingGutter(rows[index])).lowercased()
            guard candidate.count >= 4 else { return nil }
            let overlap: Double
            if candidate.contains(sought) || sought.contains(candidate) {
                overlap = Double(min(candidate.count, sought.count)) / Double(max(candidate.count, sought.count))
            } else {
                let a = Set(candidate), b = Set(sought)
                overlap = Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
            }
            guard overlap >= 0.62 else { return nil }
            if let line, gutterLine(rows[index]) == line { return (index, overlap + 0.25) }
            return (index, overlap)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }),
              scored.filter({ $0.1 >= best.1 - 0.08 }).count == 1 else { return nil }
        return best.0
    }

    static func messageIndex(_ message: String, rows: [String]) -> Int? {
        let sought = normalized(message).lowercased()
        guard sought.count >= 10 else { return nil }
        let candidates = rows.indices.filter {
            let candidate = normalized(rows[$0]).lowercased()
            return candidate == sought || (candidate.count >= 16 && sought.contains(candidate) && Double(candidate.count) / Double(sought.count) >= 0.75)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func fileMatches(_ file: String, document: String?, title: String) -> Bool {
        let fileURL = file.hasPrefix("file:") ? URL(string: file) : URL(fileURLWithPath: file)
        guard let expected = fileURL, !expected.lastPathComponent.isEmpty else { return false }
        if let document, !document.isEmpty {
            let actual = document.hasPrefix("file:") ? URL(string: document) : URL(fileURLWithPath: document)
            if let actual {
                // A document path is stronger evidence than a window title; never ignore a conflict.
                if file.hasPrefix("/") || file.hasPrefix("file:") {
                    return actual.standardizedFileURL.path == expected.standardizedFileURL.path
                }
                return actual.lastPathComponent == expected.lastPathComponent
            }
        }
        let escaped = NSRegularExpression.escapedPattern(for: expected.lastPathComponent)
        return matches("(?:^|[\\s/—–·•|\\[\\(])" + escaped + "(?:$|[\\s—–·•|\\]\\)])", title)
    }

    static func point(normalizedBox: CGRect, window: CGRect) -> ScreenPoint {
        ScreenPoint(x: window.minX + normalizedBox.midX * window.width,
                    y: window.minY + (1 - normalizedBox.midY) * window.height)
    }

    static func diagnosticID(_ value: String) -> String {
        // Stable within and across runs; no source code is written to disk.
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return "visible-" + String(hash, radix: 16)
    }
}

final class DiagnosticMonitor {
    var onDiagnostic: ((BugDiagnostic) -> Void)?
    var onStatus: ((String) -> Void)?
    var includeWarnings = false
    var interval: Double = 3 {
        didSet { if running { installTimer() } }
    }

    private struct WindowSnapshot: Equatable {
        let pid: pid_t
        let id: CGWindowID
        let frame: CGRect
        let title: String
        let appName: String
        let bundleID: String
        let document: String?
    }
    private struct TextRow {
        let text: String
        let box: CGRect
    }
    private var timer: Timer?
    private var running = false
    private var generation = 0
    private var scanning = false
    private var lastStatus = ""
    private var recentlySeen: [String: (date: Date, target: ScreenPoint?)] = [:]
    private var targetContexts: [String: (window: WindowSnapshot, point: ScreenPoint, date: Date)] = [:]
    // Consecutive bridge candidates share only ephemeral OCR text, never a saved image.
    private var rowCache: (window: WindowSnapshot, generation: Int, capturedAt: TimeInterval, rows: [TextRow])?
    private let ocrQueue = DispatchQueue(label: "local.flybug.ocr", qos: .utility)

    static func accessibilityGranted() -> Bool { AXIsProcessTrusted() }
    static func screenGranted() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func requestScreen() { _ = CGRequestScreenCaptureAccess() }

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        rowCache = nil
        installTimer()
        tick()
    }

    func stop() {
        running = false
        generation += 1
        scanning = false
        timer?.invalidate()
        timer = nil
        recentlySeen.removeAll()
        targetContexts.removeAll()
        rowCache = nil
        status("监测已暂停")
    }

    private func installTimer() {
        timer?.invalidate()
        let next = Timer(timeInterval: max(1.5, min(30, interval)), repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func status(_ message: String) {
        guard lastStatus != message else { return }
        lastStatus = message
        onStatus?(message)
    }

    private func tick() {
        guard running, !scanning else { return }
        guard let window = frontWindow(), isCodingContext(window) else {
            status("等待切换到代码编辑器、开发工具或终端")
            return
        }
        let token = generation
        let ax = Self.accessibilityGranted()
        let screen = Self.screenGranted()
        if ax, let element = focusedElement(window.pid), let value = attribute(element, kAXValueAttribute as CFString) as? String {
            let diagnostics = accessibleErrors(value, element: element, window: window)
            if !diagnostics.isEmpty, isCurrent(window, token: token) {
                diagnostics.forEach(emit)
                status("正在监测 \(window.appName) · 辅助功能定位")
                return
            }
        }
        guard screen else {
            status(ax ? "辅助功能已启用；开启屏幕录制可兼容更多编辑器" : "需要辅助功能或屏幕录制权限，才可自动定位可见错误")
            return
        }
        scanning = true
        captureRows(window, token: token) { [weak self] rows in
            guard let self, self.generation == token else { return }
            self.scanning = false
            guard self.isCurrent(window, token: token) else { return }
            guard let rows else { return }
            self.status("正在监测 \(window.appName) · 本地屏幕识别")
            let errors = rows.compactMap { row -> BugDiagnostic? in
                guard let severity = DiagnosticText.severity(in: row.text, includeWarnings: self.includeWarnings) else { return nil }
                let target = DiagnosticText.point(normalizedBox: row.box, window: window.frame)
                guard self.isVisible(target, in: window) else { return nil }
                return BugDiagnostic(id: DiagnosticText.diagnosticID("\(window.pid):\(window.id):\(row.text)"), source: "screen", message: row.text, severity: severity, target: target)
            }
            errors.prefix(4).forEach(self.emit)
        }
    }

    private func emit(_ diagnostic: BugDiagnostic) {
        let now = Date()
        recentlySeen = recentlySeen.filter { now.timeIntervalSince($0.value.date) < 120 }
        if let window = frontWindow() { rememberTarget(diagnostic, in: window) }
        // A moved error must refresh immediately; unchanged errors refresh every two scans.
        if let previous = recentlySeen[diagnostic.id], previous.target == diagnostic.target,
           now.timeIntervalSince(previous.date) < max(1.5, min(30, interval)) * 1.5 { return }
        recentlySeen[diagnostic.id] = (now, diagnostic.target)
        onDiagnostic?(diagnostic)
    }

    private func targetKey(_ diagnostic: BugDiagnostic) -> String { diagnostic.source + "\u{001F}" + diagnostic.id }

    private func rememberTarget(_ diagnostic: BugDiagnostic, in window: WindowSnapshot) {
        let now = Date()
        targetContexts = targetContexts.filter { now.timeIntervalSince($0.value.date) < 120 }
        if let point = diagnostic.target {
            targetContexts[targetKey(diagnostic)] = (window, point, now)
        } else {
            targetContexts.removeValue(forKey: targetKey(diagnostic))
        }
    }

    /// Cheap, capture-free validation for a previously returned coordinate. The owner should
    /// call this before reusing a stored target and on its heartbeat to clear moved/switched windows.
    /// It verifies window identity/geometry and occlusion; live text is rechecked by locate/scan.
    func isCurrentTarget(_ diagnostic: BugDiagnostic) -> Bool {
        guard let point = diagnostic.target, let evidence = targetContexts[targetKey(diagnostic)],
              point == evidence.point, Date().timeIntervalSince(evidence.date) < 120,
              isCurrent(evidence.window, token: generation) else { return false }
        return isVisible(point, in: evidence.window)
    }

    /// Locate a diagnostic in the current foreground window.  Automatic screen
    /// monitoring remains restricted to coding contexts, but bridge reports are
    /// allowed to target any foreground app: Codex/Claude may be a web view,
    /// and user supplied editor integrations can use an app name we do not know.
    /// The bridge path also gets a conservative window fallback when the app
    /// exposes no text range, so a confirmed report still produces a visible
    /// response instead of silently doing nothing.
    func locate(_ diagnostic: BugDiagnostic, allowAnyFrontApp: Bool = false,
                completion: @escaping (BugDiagnostic) -> Void) {
        var unresolved = diagnostic
        unresolved.target = nil
        guard let window = frontWindow(), (allowAnyFrontApp || isCodingContext(window)) else {
            completion(unresolved); return
        }
        let token = generation
        if Self.accessibilityGranted(), let target = accessibleTarget(diagnostic, window: window), isCurrent(window, token: token) {
            unresolved.target = target
            rememberTarget(unresolved, in: window)
            completion(unresolved)
            return
        }
        guard Self.screenGranted() else {
            // Accessibility alone is common on a fresh install.  Keep the
            // bridge path visibly responsive even when screen capture has not
            // been granted yet; automatic OCR still requires that permission.
            if allowAnyFrontApp, let fallback = bridgeFallbackTarget(in: window) {
                unresolved.target = fallback
                rememberTarget(unresolved, in: window)
            }
            completion(unresolved)
            return
        }
        captureRows(window, token: token) { [weak self] rows in
            var result = unresolved
            guard let self, self.isCurrent(window, token: token), let rows else { completion(result); return }
            let texts = rows.map(\.text)
            var match: Int?
            // OCR cannot prove which file an editor displays without visible identity.
            let identity = diagnostic.file.map { DiagnosticText.fileMatches($0, document: window.document, title: window.title) } ?? true
            if identity, let lineText = diagnostic.lineText {
                match = DiagnosticText.uniqueSnippetIndex(lineText, line: diagnostic.line, rows: texts)
                if match == nil { match = DiagnosticText.fuzzySnippetIndex(lineText, line: diagnostic.line, rows: texts) }
            }
            if match == nil { match = DiagnosticText.messageIndex(diagnostic.message, rows: texts) }
            if let match {
                let target = DiagnosticText.point(normalizedBox: rows[match].box, window: window.frame)
                if self.isVisible(target, in: window) { result.target = target }
            }
            self.rememberTarget(result, in: window)
            if result.target == nil, allowAnyFrontApp,
               let fallback = self.bridgeFallbackTarget(in: window) {
                result.target = fallback
                self.rememberTarget(result, in: window)
            }
            completion(result)
        }
    }

    /// Return a safe point in the foreground window when an application does
    /// not expose the source text through Accessibility.  This is deliberately
    /// used only for explicit bridge diagnostics; automatic OCR never falls
    /// back to an arbitrary point.  It makes Codex/Claude web views and custom
    /// terminals visibly acknowledge a confirmed diagnostic while preserving
    /// exact line targeting whenever available.
    private func bridgeFallbackTarget(in window: WindowSnapshot) -> ScreenPoint? {
        if Self.accessibilityGranted(), let element = focusedElement(window.pid),
           let frame = accessibilityFrame(element), frame.width > 2, frame.height > 2 {
            let point = ScreenPoint(x: frame.midX, y: frame.midY)
            if isVisible(point, in: window) { return point }
        }
        let point = ScreenPoint(x: window.frame.midX, y: window.frame.midY)
        return isVisible(point, in: window) ? point : nil
    }

    private func frontWindow() -> WindowSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), !app.isHidden,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var focusedFrame: CGRect?
        var focusedTitle: String?
        var focusedDocument: String?
        var focusedAXWindow: AXUIElement?
        var axApplication: AXUIElement?
        var focusedAnchor: CGPoint?
        if Self.accessibilityGranted() {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            axApplication = axApp
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            if let focused = axElement(attribute(axApp, kAXFocusedWindowAttribute as CFString)) {
                focusedAXWindow = focused
                focusedTitle = attribute(focused, kAXTitleAttribute as CFString) as? String
                focusedFrame = accessibilityFrame(focused)
                focusedDocument = attribute(focused, kAXDocumentAttribute as CFString) as? String
            }
            if let editor = axElement(attribute(axApp, kAXFocusedUIElementAttribute as CFString)) {
                if let document = attribute(editor, kAXDocumentAttribute as CFString) as? String {
                    focusedDocument = document
                }
                if let focusedAXWindow,
                   let editorWindow = axElement(attribute(editor, kAXWindowAttribute as CFString)),
                   CFEqual(editorWindow, focusedAXWindow), let editorFrame = accessibilityFrame(editor) {
                    let center = CGPoint(x: editorFrame.midX, y: editorFrame.midY)
                    if focusedFrame?.contains(center) == true { focusedAnchor = center }
                }
            }
        }
        if let focusedFrame, let focusedAXWindow, let axApplication {
            let anchor = focusedAnchor ?? CGPoint(x: focusedFrame.midX, y: focusedFrame.midY)
            guard let identity = WindowIdentity.resolve(pid: app.processIdentifier, application: axApplication,
                                                        focusedWindow: focusedAXWindow, frame: focusedFrame,
                                                        anchor: anchor, windowInfo: windows, ignoringPID: getpid()),
                  identity.frame.width > 200, identity.frame.height > 100,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
            let cgTitle = windows.first { $0[kCGWindowNumber as String] as? UInt32 == identity.id }?[kCGWindowName as String] as? String
            return WindowSnapshot(pid: app.processIdentifier, id: identity.id, frame: identity.frame,
                                  title: focusedTitle ?? cgTitle ?? "", appName: app.localizedName ?? "开发工具",
                                  bundleID: app.bundleIdentifier ?? "", document: focusedDocument)
        }
        // Without an AX window, preserve the original frontmost CG-window path.
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let number = window[kCGWindowNumber as String] as? UInt32,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 200, frame.height > 100 else { continue }
            let title = window[kCGWindowName as String] as? String ?? ""
            return WindowSnapshot(pid: app.processIdentifier, id: number, frame: frame, title: title, appName: app.localizedName ?? "开发工具", bundleID: app.bundleIdentifier ?? "", document: focusedDocument)
        }
        return nil
    }

    private func isCodingContext(_ window: WindowSnapshot) -> Bool {
        let identity = (window.bundleID + " " + window.appName).lowercased()
        let names = ["visual studio", "vscode", "com.microsoft.vs", "cursor", "windsurf", "xcode", "terminal", "iterm", "wezterm", "alacritty", "zed", "jetbrains", "intellij", "pycharm", "webstorm", "goland", "clion", "rider", "fleet", "android studio", "sublime", "nova", "bbedit", "textmate", "emacs", "vim", "kitty", "codex", "trae", "positron", "antigravity", "rustrover", "datagrip", "rstudio", "eclipse", "netbeans", "dev-c++", "opencode", "claude", "ghostty", "warp", "hyper", "tabby"]
        if names.contains(where: identity.contains) || window.appName.lowercased() == "rio" || window.bundleID.lowercased().hasSuffix(".rio") { return true }
        let title = window.title.lowercased()
        return ["github", "gitlab", "replit", "codesandbox", "stackblitz", "devtools", "developer tools", "jupyter", "colab", "leetcode", "code-server", "vscode", "开发者工具"].contains(where: title.contains)
    }

    private func isCurrent(_ window: WindowSnapshot, token: Int) -> Bool {
        guard generation == token, let current = frontWindow() else { return false }
        return current == window
    }

    private func isVisible(_ point: ScreenPoint, in window: WindowSnapshot) -> Bool {
        let cg = CGPoint(x: point.x, y: point.y)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
              window.frame.insetBy(dx: 1, dy: 1).contains(cg),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        var visibleWindows = windows
        if Self.accessibilityGranted() {
            let axApp = AXUIElementCreateApplication(window.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.12)
            if let focusedWindow = axElement(attribute(axApp, kAXFocusedWindowAttribute as CFString)) {
                visibleWindows = WindowIdentity.filteredForVisibility(windowInfo: windows, at: cg,
                                                                      focusedWindow: focusedWindow, pid: window.pid)
            }
        }
        // Any solid window above the target window can hide that part of the editor.
        for item in visibleWindows {
            guard let id = item[kCGWindowNumber as String] as? UInt32 else { continue }
            if id == window.id { return true }
            if (item[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) { continue }
            guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0.2,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            if frame.contains(cg) { return false }
        }
        return false
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute as CFString), CFGetTypeID(position) == AXValueGetTypeID(),
              let dimensions = attribute(element, kAXSizeAttribute as CFString), CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(dimensions as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func focusedElement(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let focused = axElement(attribute(app, kAXFocusedUIElementAttribute as CFString)) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.2)
        return focused
    }

    private func rangeTarget(_ range: NSRange, element: AXUIElement, window: WindowSnapshot) -> ScreenPoint? {
        if let visible = attribute(element, kAXVisibleCharacterRangeAttribute as CFString), CFGetTypeID(visible) == AXValueGetTypeID() {
            var visibleRange = CFRange()
            if AXValueGetValue(visible as! AXValue, .cfRange, &visibleRange) {
                guard visibleRange.location >= 0, visibleRange.length > 0,
                      NSIntersectionRange(range, NSRange(location: visibleRange.location, length: visibleRange.length)).length > 0 else { return nil }
            }
        }
        var value = CFRange(location: range.location, length: max(1, range.length))
        guard let parameter = AXValueCreate(.cfRange, &value) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0, rect.height < 120 else { return nil }
        let point = ScreenPoint(x: rect.midX, y: rect.midY)
        return isVisible(point, in: window) ? point : nil
    }

    private func accessibleErrors(_ value: String, element: AXUIElement, window: WindowSnapshot) -> [BugDiagnostic] {
        let text = value as NSString
        guard text.length <= 500_000 else { return [] }
        var found: [BugDiagnostic] = []
        var offset = 0
        for row in value.components(separatedBy: "\n") {
            let length = (row as NSString).length
            defer { offset += length + 1 }
            guard let severity = DiagnosticText.severity(in: row, includeWarnings: includeWarnings),
                  let target = rangeTarget(NSRange(location: offset, length: max(1, length)), element: element, window: window) else { continue }
            found.append(BugDiagnostic(id: DiagnosticText.diagnosticID("\(window.pid):\(window.id):\(row)"), source: "accessibility", message: row, severity: severity, target: target))
            if found.count == 4 { break }
        }
        return found
    }

    private func accessibleTarget(_ diagnostic: BugDiagnostic, window: WindowSnapshot) -> ScreenPoint? {
        guard let element = focusedElement(window.pid), let value = attribute(element, kAXValueAttribute as CFString) as? String, (value as NSString).length <= 500_000 else { return nil }
        var document = attribute(element, kAXDocumentAttribute as CFString) as? String
        if document == nil, let axWindow = axElement(attribute(element, kAXWindowAttribute as CFString)) {
            document = attribute(axWindow, kAXDocumentAttribute as CFString) as? String
        }
        let identity = diagnostic.file.map { DiagnosticText.fileMatches($0, document: document, title: window.title) } ?? false
        let lines = value.components(separatedBy: "\n")
        var matched: Int?
        if identity, let line = diagnostic.line, line > 0, line <= lines.count {
            let index = line - 1
            if diagnostic.lineText == nil || DiagnosticText.normalized(lines[index]) == DiagnosticText.normalized(diagnostic.lineText!) { matched = index }
        }
        if matched == nil, (diagnostic.file == nil || identity), let snippet = diagnostic.lineText {
            matched = DiagnosticText.uniqueSnippetIndex(snippet, line: nil, rows: lines)
        }
        if let index = matched {
            let offset = lines.prefix(index).reduce(0) { $0 + ($1 as NSString).length + 1 }
            let line = lines[index] as NSString
            guard line.length > 0 else { return nil }
            let column = max(0, min(line.length - 1, (diagnostic.column ?? 1) - 1))
            if let point = rangeTarget(NSRange(location: offset + column, length: 1), element: element, window: window) { return point }
        }
        // A diagnostic may also be visibly displayed in the focused terminal/problems panel.
        if let index = DiagnosticText.messageIndex(diagnostic.message, rows: lines) {
            let offset = lines.prefix(index).reduce(0) { $0 + ($1 as NSString).length + 1 }
            return rangeTarget(NSRange(location: offset, length: max(1, (lines[index] as NSString).length)), element: element, window: window)
        }
        return nil
    }

    private func captureRows(_ window: WindowSnapshot, token: Int, completion: @escaping ([TextRow]?) -> Void) {
        guard generation == token, Self.screenGranted() else { completion(nil); return }
        if let cache = rowCache, cache.generation == token, cache.window == window,
           ProcessInfo.processInfo.systemUptime - cache.capturedAt <= 0.7,
           isCurrent(window, token: token) {
            completion(cache.rows)
            return
        }
        rowCache = nil
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(window, token: token) else { completion(nil); return }
                guard error == nil, let captureWindow = content?.windows.first(where: { $0.windowID == window.id }), captureWindow.isOnScreen else {
                    self.status("暂时无法读取前台窗口；请检查屏幕录制权限")
                    completion(nil)
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(ceil(window.frame.width * 2)))
                configuration.height = max(1, Int(ceil(window.frame.height * 2)))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                configuration.scalesToFit = true
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, error in
                    guard let self else { DispatchQueue.main.async { completion(nil) }; return }
                    guard let image, error == nil else {
                        DispatchQueue.main.async {
                            if self.isCurrent(window, token: token) { self.status("屏幕读取暂时不可用；可使用编辑器桥接发送诊断") }
                            completion(nil)
                        }
                        return
                    }
                    let capturedAt = ProcessInfo.processInfo.systemUptime
                    self.ocrQueue.async {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = false
                        request.recognitionLanguages = ["en-US", "zh-Hans"]
                        request.minimumTextHeight = 0.008
                        do {
                            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                            let rows = (request.results ?? []).compactMap { observation -> TextRow? in
                                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.45 else { return nil }
                                return TextRow(text: candidate.string, box: observation.boundingBox)
                            }.sorted { $0.box.midY > $1.box.midY }
                            DispatchQueue.main.async {
                                guard self.isCurrent(window, token: token) else { completion(nil); return }
                                self.rowCache = (window, token, capturedAt, rows)
                                completion(rows)
                            }
                        } catch {
                            DispatchQueue.main.async {
                                if self.isCurrent(window, token: token) { self.status("本地文字识别暂时不可用") }
                                completion(nil)
                            }
                        }
                    }
                }
            }
        }
    }
}
