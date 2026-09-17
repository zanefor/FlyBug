import AppKit
import ApplicationServices

/// UTF-16 offsets match both AX text ranges and NSSpellChecker ranges.
enum InputTextSample {
    static let activeWordSettleDelay: TimeInterval = 0.8

    struct Sample {
        let text: String
        let offset: Int
        let startsInsideParagraph: Bool
        let endsInsideParagraph: Bool
    }

    static func extract(_ text: String, selection: NSRange, limit: Int = 4_000) -> Sample? {
        let value = text as NSString
        guard value.length > 0, limit > 0, selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= value.length, selection.length <= value.length - selection.location else { return nil }
        if value.length <= limit {
            return Sample(text: text, offset: 0, startsInsideParagraph: false, endsInsideParagraph: false)
        }
        let paragraph = value.paragraphRange(for: NSRange(location: selection.location, length: 0))
        guard paragraph.length > 0 else { return nil }
        var range = paragraph
        if range.length > limit {
            let start = max(paragraph.location, min(selection.location - limit / 2, NSMaxRange(paragraph) - limit))
            range = NSRange(location: start, length: min(limit, value.length - start))
            // Never split surrogate pairs, combining marks, or composed emoji.
            range = value.rangeOfComposedCharacterSequences(for: range)
        }
        return Sample(text: value.substring(with: range), offset: range.location,
                      startsInsideParagraph: range.location > paragraph.location,
                      endsInsideParagraph: NSMaxRange(range) < NSMaxRange(paragraph))
    }

    /// Defer the English word under the caret while typing, but also check it after a pause.
    static func activeEnglishWord(_ text: String, selection: NSRange) -> NSRange? {
        let value = text as NSString
        guard selection.length == 0, selection.location > 0, selection.location <= value.length,
              let expression = try? NSRegularExpression(pattern: "[A-Za-z]+(?:['’−-][A-Za-z]+)*") else { return nil }
        return expression.matches(in: text, range: NSRange(location: 0, length: value.length))
            .first { $0.range.location < selection.location && NSMaxRange($0.range) >= selection.location }?.range
    }

    static func shouldReport(_ issue: WritingIssue, sample: Sample, selection: NSRange,
                             stableFor: TimeInterval = 0) -> Bool {
        let length = (sample.text as NSString).length
        guard issue.range.location != NSNotFound, issue.range.location >= 0, issue.range.length > 0,
              issue.range.location <= length, issue.range.length <= length - issue.range.location else { return false }
        // A clipped word or sentence is insufficient evidence at a truncated sample boundary.
        if sample.startsInsideParagraph && issue.range.location == 0 { return false }
        if sample.endsInsideParagraph && NSMaxRange(issue.range) == length { return false }
        let localSelection = NSRange(location: max(0, selection.location - sample.offset), length: selection.length)
        if stableFor < activeWordSettleDelay,
           let active = activeEnglishWord(sample.text, selection: localSelection),
           NSIntersectionRange(active, issue.range).length > 0 { return false }
        return true
    }

    /// A long grammar finding can span several lines. Its first nonblank composed
    /// character gives AX a precise anchor without splitting emoji or accents.
    static func firstTargetRange(in text: String, range: NSRange) -> NSRange? {
        guard WritingEngine.valid(range, in: text) else { return nil }
        let value = text as NSString
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let character = value.rangeOfComposedCharacterSequence(at: cursor)
            guard NSMaxRange(character) <= NSMaxRange(range) else { return nil }
            if !value.substring(with: character).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return character
            }
            cursor = NSMaxRange(character)
        }
        return nil
    }
}

/// Reads only the currently focused editable field. It never types, captures the screen,
/// reads password values, sends text over the network, or saves input text to disk.
final class TextInputMonitor {
    /// Structural debugging only: never field labels, values or selected text.
    private(set) var healthMetadata: [String: String] = [:]
    private var targetMetadata: [String: String] = [:]
    var onIssues: (([BugDiagnostic]) -> Void)?
    var onStatus: ((String) -> Void)?
    var checkSpelling = true { didSet { if oldValue != checkSpelling { settingsChanged() } } }
    var language = "auto" { didSet { if oldValue != language { settingsChanged() } } }

    private struct Snapshot {
        let pid: pid_t
        let appName: String
        let focusedElement: AXUIElement
        let element: AXUIElement
        let window: AXUIElement
        let windowID: CGWindowID
        let windowFrame: CGRect
        let elementFrame: CGRect
        let visibleRange: NSRange?
        let text: String
        let selection: NSRange
        let sample: InputTextSample.Sample

        func matches(_ other: Snapshot) -> Bool {
            pid == other.pid && windowID == other.windowID && CFEqual(focusedElement, other.focusedElement) &&
            CFEqual(element, other.element) &&
            CFEqual(window, other.window) && windowFrame == other.windowFrame &&
            elementFrame == other.elementFrame && visibleRange == other.visibleRange &&
            text == other.text && selection == other.selection
        }
    }
    private struct TargetEvidence {
        let snapshot: Snapshot
        let range: NSRange
        let point: ScreenPoint
    }
    private var timer: Timer?
    private let keyboard = KeyboardInputTrigger()
    private let wechat = WeChatInputProbe()
    private var inputRefresh: DispatchWorkItem?
    private var settledRefresh: DispatchWorkItem?
    private var lastKeyAt: TimeInterval = -.infinity
    private var running = false
    private var generation = 0
    private var snapshot: Snapshot?
    private var changedAt: TimeInterval = 0
    private var retryAfter: TimeInterval = 0
    private var checking = false
    private var checked = false
    private var knownIssues: [WritingIssue] = []
    private var targetContexts: [String: TargetEvidence] = [:]
    private var lastPublished: [BugDiagnostic] = []
    private var lastStatus = ""
    private var unavailableReason = "等待在任意应用中输入文字"
    private var lastExternalStatus = ""

    func start() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.start() }; return }
        guard !running else { return }
        running = true
        keyboard.onInput = { [weak self] in self?.keyboardInput() }
        wechat.onFindings = { [weak self] findings in
            guard let self, self.running else { return }
            let values = findings.enumerated().map { index, finding in
                BugDiagnostic(id: "wechat-writing-\(self.generation)-\(index)-\(finding.issue.range.location)", source: "writing", message: finding.issue.message, severity: "warning", target: finding.target)
            }
            self.lastPublished = values
            self.onIssues?(values)
            self.status(values.isEmpty ? "微信 · 当前输入未发现语法或拼写问题" : "微信 · 发现 \(values.count) 处文字问题，已定位")
        }
        keyboard.startIfAuthorized()
        invalidate()
        let next = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(next, forMode: .common)
        timer = next
        tick()
    }

    func stop() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.stop() }; return }
        running = false
        keyboard.stop()
        inputRefresh?.cancel()
        settledRefresh?.cancel()
        timer?.invalidate()
        timer = nil
        invalidate()
        status("文字检查已关闭")
    }

    private func keyboardInput() {
        guard running else { return }
        lastKeyAt = ProcessInfo.processInfo.systemUptime
        inputRefresh?.cancel()
        settledRefresh?.cancel()
        // Clear the old location immediately, then let the application commit
        // the keystroke or paste before reading its focused input.
        invalidate()
        status("正在输入 · 停笔后检查拼写")
        let refresh = DispatchWorkItem { [weak self] in self?.tick() }
        inputRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: refresh)
        let settled = DispatchWorkItem { [weak self] in self?.tick() }
        settledRefresh = settled
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: settled)
    }

    /// When the application explicitly clears displayed issues, clear the producer's
    /// deduplication snapshot too so unchanged text can be checked again.
    func rescan() {
        guard running else { return }
        invalidate()
        tick()
    }

    private func settingsChanged() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.settingsChanged() }; return }
        retryAfter = 0
        invalidate()
        if running { tick() }
    }

    private func invalidate() {
        generation += 1
        snapshot = nil
        checking = false
        checked = false
        knownIssues.removeAll()
        targetContexts.removeAll()
        targetMetadata.removeAll()
        healthMetadata = healthMetadata.filter { !$0.key.hasPrefix("target") }
        lastPublished.removeAll()
        onIssues?([])
    }

    private func status(_ message: String) {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            lastExternalStatus = message
        }
        guard message != lastStatus else { return }
        lastStatus = message
        onStatus?(message)
    }

    private func tick() {
        guard running else { return }
        keyboard.startIfAuthorized()
        guard ProcessInfo.processInfo.systemUptime - lastKeyAt >= 0.12 else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tencent.xinWeChat" {
            // WeChat's custom renderer has no usable AX text node. The probe
            // only examines the bottom composer strip after recent input.
            wechat.request()
            status("微信 · 等待输入文字")
            return
        }
        guard let current = readSnapshot() else {
            if snapshot != nil || checking || !lastPublished.isEmpty { invalidate() }
            status(unavailableReason)
            return
        }
        guard let previous = snapshot, previous.matches(current) else {
            invalidate()
            snapshot = current
            changedAt = ProcessInfo.processInfo.systemUptime
            status("正在检查 \(current.appName) 的输入文字 · 停笔后检查")
            return
        }
        guard !checking else { return }
        if checked {
            // Re-evaluate deferred caret-word findings as the pause grows; also refresh geometry.
            publish(knownIssues, in: current)
            return
        }
        guard ProcessInfo.processInfo.systemUptime >= retryAfter else {
            status("系统文字检查服务暂未响应，稍后会自动重试")
            return
        }
        guard ProcessInfo.processInfo.systemUptime - changedAt >= 0.45 else { return }
        checking = true
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.running, self.generation == token, self.checking else { return }
            self.invalidate()
            self.retryAfter = ProcessInfo.processInfo.systemUptime + 10
            self.status("系统文字检查服务暂未响应，稍后会自动重试")
        }
        WritingEngine.check(current.sample.text, language: language, checkSpelling: checkSpelling) { [weak self] issues in
            guard let self, self.running, self.generation == token else { return }
            self.checking = false
            guard let latest = self.readSnapshot(), current.matches(latest) else {
                self.invalidate()
                self.status("输入位置已变化，等待停笔后重新检查")
                return
            }
            self.checked = true
            // Keep findings that are temporarily deferred, so an unchanged final word
            // becomes eligible after settling without another keystroke or checker request.
            self.knownIssues = issues
            self.publish(self.knownIssues, in: latest)
        }
    }

    private func publish(_ issues: [WritingIssue], in current: Snapshot) {
        let stableFor = ProcessInfo.processInfo.systemUptime - changedAt
        let reportable = issues.filter {
            InputTextSample.shouldReport($0, sample: current.sample, selection: current.selection, stableFor: stableFor)
        }
        var evidence: [String: TargetEvidence] = [:]
        let values = reportable.prefix(8).enumerated().map { index, issue -> BugDiagnostic in
            let range = NSRange(location: current.sample.offset + issue.range.location, length: issue.range.length)
            let id = "writing-\(generation)-\(index)-\(range.location)-\(range.length)"
            let point = rangeTarget(range, in: current)
            if let point { evidence[id] = TargetEvidence(snapshot: current, range: range, point: point) }
            return BugDiagnostic(id: id, source: "writing", message: issue.message,
                                 severity: "warning", target: point)
        }
        // Do not publish coordinates if typing, focus, window, or selection changed during AX calls.
        guard let latest = readSnapshot(), current.matches(latest) else { invalidate(); return }
        targetContexts = evidence
        if values.count != lastPublished.count || zip(values, lastPublished).contains(where: { $0.id != $1.id || $0.target != $1.target || $0.message != $1.message }) {
            lastPublished = values
            onIssues?(values)
        }
        if values.isEmpty && stableFor < InputTextSample.activeWordSettleDelay && issues.contains(where: {
            InputTextSample.shouldReport($0, sample: current.sample, selection: current.selection,
                                         stableFor: InputTextSample.activeWordSettleDelay)
        }) {
            status("\(current.appName) · 等待停笔，随后检查光标所在单词")
        } else if values.isEmpty {
            status("\(current.appName) · 当前输入未发现语法或拼写问题")
        } else if values.contains(where: { $0.target != nil }) {
            status("\(current.appName) · 发现 \(values.count) 处文字问题，已定位")
        } else {
            status("\(current.appName) · 发现 \(values.count) 处文字问题；应用未提供可见文字坐标")
        }
    }

    func isCurrentTarget(_ diagnostic: BugDiagnostic) -> Bool {
        guard Thread.isMainThread, running, diagnostic.source == "writing", let point = diagnostic.target,
              let evidence = targetContexts[diagnostic.id], point == evidence.point,
              let current = readSnapshot(), evidence.snapshot.matches(current),
              let latestPoint = rangeTarget(evidence.range, in: current), latestPoint == point,
              let after = readSnapshot(), current.matches(after) else { return false }
        return true
    }

    private func readSnapshot() -> Snapshot? {
        healthMetadata = ["stage": "permission", "keyboardListening": String(keyboard.isListening),
                          "keyboardEventCount": String(keyboard.eventCount)]
        // Targeting is followed by another snapshot read before publication.
        // Preserve its numeric evidence only while the input snapshot is valid.
        defer {
            if healthMetadata["stage"] == "ready" {
                healthMetadata.merge(targetMetadata) { _, newest in newest }
            } else { targetMetadata.removeAll() }
        }
        guard AXIsProcessTrusted() else {
            unavailableReason = "文字检查需要辅助功能权限；仅在本机检查当前输入框"
            return nil
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), !app.isHidden else {
            unavailableReason = lastExternalStatus.isEmpty ? "等待切换到其他应用的输入框" : "最近输入状态：\(lastExternalStatus)"
            return nil
        }
        healthMetadata["appName"] = app.localizedName ?? "unavailable"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        healthMetadata["stage"] = "focus"
        guard let focusedElement = resolveFocusedElement(application: axApp, pid: app.processIdentifier) else {
            unavailableReason = "\(app.localizedName ?? "当前应用") 尚未提供可读取的输入框"
            return nil
        }
        AXUIElementSetMessagingTimeout(focusedElement, 0.12)
        healthMetadata["focusRole"] = attribute(focusedElement, kAXRoleAttribute as CFString) as? String ?? "unavailable"
        // Inspect structural metadata before reading any value or selected text.
        let ancestry = safeAncestry(focusedElement)
        healthMetadata["webContent"] = String(ancestry.webContent)
        healthMetadata["protected"] = String(ancestry.protected)
        healthMetadata["stage"] = "editable"
        guard !ancestry.protected else {
            unavailableReason = "密码或受保护的输入框已跳过"
            return nil
        }
        guard let element = editableElement(focusedElement, ancestry: ancestry, pid: app.processIdentifier) else {
            unavailableReason = "\(app.localizedName ?? "当前应用") · 等待可编辑输入框；此控件未开放文字检查"
            return nil
        }
        if hasMarkedText(element) || (!CFEqual(element, focusedElement) && hasMarkedText(focusedElement)) {
            unavailableReason = "正在使用输入法组词，确认后再检查"
            return nil
        }
        let appName = app.localizedName ?? "当前应用"
        healthMetadata["stage"] = "selection"
        let reportedSelection = axRange(attribute(element, kAXSelectedTextRangeAttribute as CFString))
        healthMetadata["selection"] = reportedSelection == nil ? "unavailable" : "available"
        guard let focusedWindow = axElement(attribute(axApp, kAXFocusedWindowAttribute as CFString)) else {
            unavailableReason = "\(appName) · 未取得前台窗口"
            return nil
        }
        healthMetadata["stage"] = "window"
        guard let elementWindow = axElement(attribute(element, kAXWindowAttribute as CFString)) else {
            unavailableReason = "\(appName) · 输入框未提供所属窗口"
            return nil
        }
        guard CFEqual(focusedWindow, elementWindow) else {
            unavailableReason = "\(appName) · 输入框与前台窗口不一致"
            return nil
        }
        guard let windowFrame = frame(focusedWindow), let elementFrame = frame(element) else {
            unavailableReason = "\(appName) · 输入框或窗口没有有效屏幕边界"
            return nil
        }
        guard let windowID = visibleWindowID(pid: app.processIdentifier, application: axApp,
                                            focusedWindow: focusedWindow, frame: windowFrame,
                                            anchor: CGPoint(x: elementFrame.midX, y: elementFrame.midY)) else {
            unavailableReason = "\(appName) · 系统窗口列表无法匹配输入窗口"
            return nil
        }
        healthMetadata["stage"] = "value"
        if let count = attribute(element, kAXNumberOfCharactersAttribute as CFString) as? Int, count > 200_000 {
            unavailableReason = "当前输入过长；请在较小的输入框中检查文字"
            return nil
        }
        guard let text = attribute(element, kAXValueAttribute as CFString) as? String,
              (text as NSString).length <= 200_000 else {
            unavailableReason = "\(app.localizedName ?? "当前应用") · 输入框未开放文字内容，或文字过长"
            return nil
        }
        // Some Chromium/Electron and terminal controls expose AXValue but omit
        // AXSelectedTextRange.  Immediately after a real keyboard/mouse input,
        // treating the caret as the end of that value is safe and lets the
        // keyboard-driven checker operate.  Without a recent input event we
        // still reject the control so a static page/document cannot be scanned.
        let selection: NSRange
        if let reportedSelection {
            selection = reportedSelection
        } else if ProcessInfo.processInfo.systemUptime - lastKeyAt < 2,
                  (healthMetadata["candidateRole"] == "AXGroup" || healthMetadata["candidateRole"] == "AXTextArea" ||
                   healthMetadata["candidateRole"] == "AXTextField") {
            selection = NSRange(location: (text as NSString).length, length: 0)
            healthMetadata["selectionFallback"] = "end-after-input"
        } else {
            unavailableReason = "\(appName) · 输入框未开放字符光标范围"
            return nil
        }
        guard let sample = InputTextSample.extract(text, selection: selection) else {
            unavailableReason = "\(app.localizedName ?? "当前应用") · 等待输入文字"
            return nil
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let afterFocus = resolveFocusedElement(application: axApp, pid: app.processIdentifier), CFEqual(focusedElement, afterFocus) else { return nil }
        healthMetadata["stage"] = "ready"
        return Snapshot(pid: app.processIdentifier, appName: app.localizedName ?? "当前应用", focusedElement: focusedElement, element: element,
                        window: focusedWindow, windowID: windowID, windowFrame: windowFrame, elementFrame: elementFrame,
                        visibleRange: axRange(attribute(element, kAXVisibleCharacterRangeAttribute as CFString)),
                        text: text, selection: selection, sample: sample)
    }

    /// Some applications omit their application-level focus attribute. The
    /// system-level fallback must still belong to the verified foreground PID.
    /// Record only API errors and flags, never labels or input contents.
    private func resolveFocusedElement(application: AXUIElement, pid: pid_t) -> AXUIElement? {
        func errorLabel(_ error: AXError) -> String {
            switch error {
            case .success: return "success"
            case .cannotComplete: return "cannotComplete"
            case .attributeUnsupported: return "attributeUnsupported"
            case .noValue: return "noValue"
            case .apiDisabled: return "apiDisabled"
            case .invalidUIElement: return "invalidUIElement"
            default: return String(error.rawValue)
            }
        }
        func read(_ owner: AXUIElement, prefix: String) -> AXUIElement? {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &value)
            healthMetadata[prefix + "FocusError"] = errorLabel(error)
            guard error == .success, let element = axElement(value) else { return nil }
            var ownerPID: pid_t = 0
            let pidError = AXUIElementGetPid(element, &ownerPID)
            healthMetadata[prefix + "FocusPIDError"] = errorLabel(pidError)
            let matchesPID = pidError == .success && ownerPID == pid
            healthMetadata[prefix + "FocusPIDMatches"] = String(matchesPID)
            return matchesPID ? element : nil
        }
        if let element = read(application, prefix: "application") {
            healthMetadata["focusSource"] = "application"
            return element
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        guard let element = read(system, prefix: "system"),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        healthMetadata["focusSource"] = "system"
        return element
    }

    private func safeAncestry(_ element: AXUIElement) -> (protected: Bool, webContent: Bool, nodes: [AXUIElement]) {
        var current: AXUIElement? = element
        var webContent = false
        var seen: [AXUIElement] = []
        for _ in 0..<32 {
            guard let node = current, !seen.contains(where: { CFEqual($0, node) }) else { break }
            seen.append(node)
            AXUIElementSetMessagingTimeout(node, 0.12)
            let role = attribute(node, kAXRoleAttribute as CFString) as? String ?? ""
            let subrole = (attribute(node, kAXSubroleAttribute as CFString) as? String ?? "").lowercased()
            if role == "AXSecureTextField" || subrole.contains("secure") || subrole.contains("password") ||
                (attribute(node, "AXProtectedContent" as CFString) as? Bool == true) ||
                (attribute(node, "AXIsPassword" as CFString) as? Bool == true) {
                return (true, webContent, seen)
            }
            if role == "AXWebArea" { webContent = true }
            if role == kAXWindowRole as String || role == kAXApplicationRole as String { break }
            current = axElement(attribute(node, kAXParentAttribute as CFString))
        }
        return (false, webContent, seen)
    }

    private func editableElement(_ focused: AXUIElement,
                                 ancestry: (protected: Bool, webContent: Bool, nodes: [AXUIElement]),
                                 pid: pid_t) -> AXUIElement? {
        if isEditable(focused, inWebContent: ancestry.webContent) { return focused }
        // Chromium exposes AXEditableAncestor for text descendants of editable
        // controls. Use that relationship only when the returned control is also
        // in the focused node's actual parent chain; never search unrelated fields.
        if let ancestor = axElement(attribute(focused, "AXEditableAncestor" as CFString)),
           !CFEqual(ancestor, focused), ancestry.nodes.contains(where: { CFEqual($0, ancestor) }) {
            var ancestorPID: pid_t = 0
            if AXUIElementGetPid(ancestor, &ancestorPID) == .success, ancestorPID == pid {
                let ancestorContext = safeAncestry(ancestor)
                if ancestorContext.protected { healthMetadata["protected"] = "true" }
                if !ancestorContext.protected,
                   isEditable(ancestor, inWebContent: ancestorContext.webContent) { return ancestor }
            }
        }

        // Some web views and terminal panes expose the caret as an AXGroup and
        // do not provide AXEditableAncestor. Search only this focused node's
        // immediate subtree, with a small depth limit, so a page containing
        // many unrelated inputs is never scanned.
        var queue: [(AXUIElement, Int)] = [(focused, 0)]
        var visited: [AXUIElement] = []
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            if depth > 0, isEditable(node, inWebContent: ancestry.webContent) { return node }
            guard depth < 5, let children = attribute(node, kAXChildrenAttribute as CFString) as? [AXUIElement] else { continue }
            for child in children.prefix(40) {
                var childPID: pid_t = 0
                guard AXUIElementGetPid(child, &childPID) == .success, childPID == pid else { continue }
                queue.append((child, depth + 1))
            }
        }

        // A focused AXGroup can itself be a normal single text client. Accept
        // this coarse form only when value and caret are readable and the node
        // is not a secure/read-only control. The target will use the element
        // frame when per-range bounds are unavailable.
        let role = attribute(focused, kAXRoleAttribute as CFString) as? String ?? ""
        let coarseRole = role == "AXGroup" || role == "AXTextArea" || role == "AXTextField"
        let valueReadable = attribute(focused, kAXValueAttribute as CFString) as? String != nil
        let rangeReadable = axRange(attribute(focused, kAXSelectedTextRangeAttribute as CFString)) != nil
        let enabled = attribute(focused, kAXEnabledAttribute as CFString) as? Bool
        let readOnly = attribute(focused, "AXReadOnly" as CFString) as? Bool
        let recentInput = ProcessInfo.processInfo.systemUptime - lastKeyAt < 2
        if coarseRole && valueReadable && (rangeReadable || recentInput) && enabled != false && readOnly != true {
            healthMetadata["candidateRole"] = role
            healthMetadata["editable"] = "coarse"
            if !rangeReadable { healthMetadata["selectionFallbackCandidate"] = "recent-input" }
            return focused
        }
        return nil
    }

    private func hasMarkedText(_ element: AXUIElement) -> Bool {
        if let marked = axRange(attribute(element, "AXMarkedTextRange" as CFString)), marked.length > 0 { return true }
        return attribute(element, "AXHasMarkedText" as CFString) as? Bool == true
    }

    private func isEditable(_ element: AXUIElement, inWebContent: Bool) -> Bool {
        let enabled = attribute(element, kAXEnabledAttribute as CFString) as? Bool
        let readOnly = attribute(element, "AXReadOnly" as CFString) as? Bool
        healthMetadata["enabled"] = enabled.map(String.init) ?? "unavailable"
        healthMetadata["readOnly"] = readOnly.map(String.init) ?? "unavailable"
        guard enabled != false, readOnly != true else { return false }
        let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
        healthMetadata["candidateRole"] = role
        let editable = attribute(element, "AXEditable" as CFString) as? Bool
        healthMetadata["editable"] = editable.map(String.init) ?? "unavailable"
        if editable == false { return false }
        // Chromium/Electron (including Codex and Claude Code) often reports a
        // focused plain editor as AXGroup rather than AXTextArea and omits
        // AXEditable.  A focused group that exposes both a value and a caret
        // range is an actual text client; accept it for coarse field targeting.
        // AXWebArea is intentionally excluded here because it is also used for
        // an unfocused page/document root.
        if editable == nil, inWebContent, role == "AXGroup",
           attribute(element, kAXValueAttribute as CFString) as? String != nil,
           axRange(attribute(element, kAXSelectedTextRangeAttribute as CFString)) != nil {
            healthMetadata["editableFallback"] = "web-group-value-and-caret"
            return true
        }
        // Explicit editability also covers rich text controls exposed as a group
        // or web area. Snapshot validation still requires character ranges,
        // a text value, and a matching foreground window before any checking.
        if editable == true { return true }
        guard [kAXTextAreaRole as String, kAXTextFieldRole as String, kAXComboBoxRole as String].contains(role) else { return false }
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        healthMetadata["valueSettable"] = settableResult == .success ? String(settable.boolValue) : "unavailable"
        if settableResult == .success, settable.boolValue { return true }
        // Web contenteditable maps to text area even when AXValue is not settable.
        // A native terminal's selectable output has the same role but is not editable.
        if inWebContent && role == kAXTextAreaRole as String { return true }
        // Terminal.app and a few embedded shells expose the command line as a
        // non-settable AXTextArea.  A focused value plus caret is the only
        // portable signal available; accepting it lets keyboard-triggered
        // checks cover shell input without walking terminal output or windows.
        if role == kAXTextAreaRole as String,
           attribute(element, kAXValueAttribute as CFString) as? String != nil,
           axRange(attribute(element, kAXSelectedTextRangeAttribute as CFString)) != nil {
            healthMetadata["editableFallback"] = "native-textarea-value-and-caret"
            return true
        }
        return false
    }

    private func rangeTarget(_ range: NSRange, in snapshot: Snapshot) -> ScreenPoint? {
        targetMetadata = ["targetStage": "visible-range", "targetReason": "checking",
                          "targetIssueRange": "\(range.location),\(range.length)",
                          "targetVisibleRange": snapshot.visibleRange.map { "\($0.location),\($0.length)" } ?? "unavailable"]
        recordTargetRect(snapshot.elementFrame, prefix: "targetElementFrame")
        recordTargetRect(snapshot.windowFrame, prefix: "targetWindowFrame")
        defer {
            healthMetadata = healthMetadata.filter { !$0.key.hasPrefix("target") }
            healthMetadata.merge(targetMetadata) { _, newest in newest }
        }
        if let visible = snapshot.visibleRange {
            guard visible.length > 0, range.location >= visible.location, NSMaxRange(range) <= NSMaxRange(visible) else {
                // For a regular text field, the field itself is the only
                // reliable location when the app does not expose per-range
                // visibility.  This is deliberately coarse; rich-text range
                // positioning is no longer required for external inputs.
                return fallbackFieldTarget(snapshot, reason: "issue-outside-visible-range")
            }
        }
        targetMetadata["targetStage"] = "bounds"
        guard var rect = bounds(for: range, in: snapshot) else {
            return fallbackFieldTarget(snapshot, reason: "bounds-api-unavailable")
        }
        recordTargetRect(rect, prefix: "targetRequestedRect")
        if rect.height > 80 {
            targetMetadata["targetStage"] = "anchor-bounds"
            guard let anchor = InputTextSample.firstTargetRange(in: snapshot.text, range: range) else {
                return fallbackFieldTarget(snapshot, reason: "no-nonblank-anchor")
            }
            guard let anchorRect = bounds(for: anchor, in: snapshot) else {
                return fallbackFieldTarget(snapshot, reason: "anchor-bounds-unavailable")
            }
            rect = anchorRect
        }
        recordTargetRect(rect, prefix: "targetRangeRect")
        targetMetadata["targetStage"] = "geometry"
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else {
            return fallbackFieldTarget(snapshot, reason: "nonfinite-bounds")
        }
        guard rect.width > 0, rect.height > 0, rect.height <= 80 else {
            return fallbackFieldTarget(snapshot, reason: "invalid-bounds-size")
        }
        guard snapshot.elementFrame.intersects(rect) else {
            return fallbackFieldTarget(snapshot, reason: "bounds-outside-element")
        }
        guard snapshot.windowFrame.contains(rect) else {
            return fallbackFieldTarget(snapshot, reason: "bounds-outside-window")
        }
        let point = ScreenPoint(x: rect.midX, y: rect.midY)
        guard snapshot.elementFrame.contains(CGPoint(x: point.x, y: point.y)) else {
            return fallbackFieldTarget(snapshot, reason: "center-outside-element")
        }
        targetMetadata["targetStage"] = "visibility"
        guard isVisible(point, in: snapshot) else { return fallbackFieldTarget(snapshot, reason: "range-point-not-visible") }
        targetMetadata["targetStage"] = "ready"
        targetMetadata["targetReason"] = "located"
        return point
    }

    /// Coarse target for ordinary input controls.  AXBoundsForRange is
    /// unavailable in many terminal/Chromium controls even though AXValue and
    /// AXSelectedTextRange are readable.  Pointing at the focused field keeps
    /// the monitor useful without attempting unsafe DOM/rich-text traversal.
    private func fallbackFieldTarget(_ snapshot: Snapshot, reason: String) -> ScreenPoint? {
        targetMetadata["targetStage"] = "field-fallback"
        targetMetadata["targetReason"] = reason
        let frame = snapshot.elementFrame
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width > 0, frame.height > 0,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == snapshot.pid else { return nil }
        let point = ScreenPoint(x: frame.midX, y: frame.midY)
        guard isVisible(point, in: snapshot) else { return nil }
        targetMetadata["targetStage"] = "ready"
        targetMetadata["targetReason"] = "field-fallback-located"
        recordTargetRect(frame, prefix: "targetFallbackFrame")
        return point
    }

    private func recordTargetRect(_ rect: CGRect, prefix: String) {
        targetMetadata[prefix + "X"] = String(Double(rect.minX))
        targetMetadata[prefix + "Y"] = String(Double(rect.minY))
        targetMetadata[prefix + "Width"] = String(Double(rect.width))
        targetMetadata[prefix + "Height"] = String(Double(rect.height))
    }

    private func bounds(for range: NSRange, in snapshot: Snapshot) -> CGRect? {
        targetMetadata["targetBoundsRange"] = "\(range.location),\(range.length)"
        targetMetadata["targetBoundsMethod"] = "range"
        var requested = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &requested) else {
            targetMetadata["targetReason"] = "range-parameter-unavailable"; return nil
        }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(snapshot.element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                               parameter, &result)
        targetMetadata["targetBoundsAXError"] = error == .success ? "success" : String(error.rawValue)
        guard error == .success else { targetMetadata["targetReason"] = "bounds-api-error"; return nil }
        guard let result, CFGetTypeID(result) == AXValueGetTypeID() else {
            targetMetadata["targetReason"] = "bounds-value-unavailable"; return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect) else {
            targetMetadata["targetReason"] = "bounds-value-not-rectangle"; return nil
        }
        recordTargetRect(rect, prefix: "targetOriginalRect")
        return rect
    }

    private func isVisible(_ point: ScreenPoint, in snapshot: Snapshot) -> Bool {
        let position = CGPoint(x: point.x, y: point.y)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else {
            targetMetadata["targetReason"] = "foreground-changed"; return false
        }
        guard snapshot.windowFrame.contains(position) else {
            targetMetadata["targetReason"] = "point-outside-window"; return false
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            targetMetadata["targetReason"] = "window-list-unavailable"; return false
        }
        let visibleWindows = WindowIdentity.filteredForVisibility(windowInfo: windows, at: position,
                                                                  focusedWindow: snapshot.window, pid: snapshot.pid)
        for item in visibleWindows {
            guard let id = item[kCGWindowNumber as String] as? UInt32 else { continue }
            if id == snapshot.windowID { return true }
            if item[kCGWindowOwnerPID as String] as? Int == Int(getpid()) { continue }
            guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0.2,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            if frame.contains(position) {
                targetMetadata["targetReason"] = "covered-by-window"
                recordTargetRect(frame, prefix: "targetOccludingFrame")
                targetMetadata["targetOccludingOwnerName"] = item[kCGWindowOwnerName as String] as? String ?? "unavailable"
                targetMetadata["targetOccludingOwnerPID"] = (item[kCGWindowOwnerPID as String] as? Int).map(String.init) ?? "unavailable"
                targetMetadata["targetOccludingLayer"] = (item[kCGWindowLayer as String] as? Int).map(String.init) ?? "unavailable"
                recordTargetHit(at: position, snapshot: snapshot)
                return false
            }
        }
        targetMetadata["targetReason"] = "owner-window-not-visible"
        return false
    }

    private func recordTargetHit(at point: CGPoint, snapshot: Snapshot) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        targetMetadata["targetHitAXError"] = error == .success ? "success" : String(error.rawValue)
        guard error == .success, let hit else { return }
        AXUIElementSetMessagingTimeout(hit, 0.12)
        targetMetadata["targetHitRole"] = attribute(hit, kAXRoleAttribute as CFString) as? String ?? "unavailable"
        var hitPID: pid_t = 0
        let pidError = AXUIElementGetPid(hit, &hitPID)
        targetMetadata["targetHitPIDError"] = pidError == .success ? "success" : String(pidError.rawValue)
        if pidError == .success { targetMetadata["targetHitPID"] = String(hitPID) }
        if let window = axElement(attribute(hit, kAXWindowAttribute as CFString)) {
            targetMetadata["targetHitWindowMatches"] = String(CFEqual(window, snapshot.window))
        } else { targetMetadata["targetHitWindowMatches"] = "unavailable" }
    }

    private func visibleWindowID(pid: pid_t, application: AXUIElement, focusedWindow: AXUIElement,
                                 frame: CGRect, anchor: CGPoint) -> CGWindowID? {
        healthMetadata["axWindowX"] = String(Double(frame.minX))
        healthMetadata["axWindowY"] = String(Double(frame.minY))
        healthMetadata["axWindowWidth"] = String(Double(frame.width))
        healthMetadata["axWindowHeight"] = String(Double(frame.height))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            healthMetadata["windowList"] = "unavailable"
            return nil
        }
        healthMetadata["windowList"] = "available"
        let candidates = windows.filter {
            $0[kCGWindowOwnerPID as String] as? Int == Int(pid) && $0[kCGWindowLayer as String] as? Int == 0
        }
        healthMetadata["windowCandidates"] = String(candidates.count)
        let framed: [(item: [String: Any], bounds: CGRect)] = candidates.compactMap { item in
            guard let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let found = CGRect(dictionaryRepresentation: bounds),
                  found.minX.isFinite, found.minY.isFinite, found.width.isFinite, found.height.isFinite else { return nil }
            return (item, found)
        }
        func distance(_ other: CGRect) -> CGFloat {
            abs(other.minX - frame.minX) + abs(other.minY - frame.minY) +
            abs(other.width - frame.width) + abs(other.height - frame.height)
        }
        if let closest = framed.min(by: { distance($0.bounds) < distance($1.bounds) })?.bounds {
            healthMetadata["closestWindowDeltaX"] = String(Double(closest.minX - frame.minX))
            healthMetadata["closestWindowDeltaY"] = String(Double(closest.minY - frame.minY))
            healthMetadata["closestWindowDeltaWidth"] = String(Double(closest.width - frame.width))
            healthMetadata["closestWindowDeltaHeight"] = String(Double(closest.height - frame.height))
        }
        let matching = framed.filter {
            abs($0.bounds.minX - frame.minX) < 2 && abs($0.bounds.minY - frame.minY) < 2 &&
            abs($0.bounds.width - frame.width) < 2 && abs($0.bounds.height - frame.height) < 2
        }
        healthMetadata["windowMatches"] = String(matching.count)
        let match = WindowIdentity.resolve(pid: pid, application: application, focusedWindow: focusedWindow,
                                           frame: frame, anchor: anchor, windowInfo: windows, ignoringPID: getpid()) { details in
            for (key, value) in details { self.healthMetadata["windowDebug" + key] = value }
        }
        healthMetadata["windowMatchMethod"] = match?.method.rawValue ?? "unresolved"
        if let match { return match.id }

        // A number of otherwise ordinary controls (notably Chromium and
        // terminal text areas) expose a valid focused AX window but reject an
        // AX hit test at the window anchor.  For plain text checking the AX
        // window/frame plus a same-PID layer-zero CGWindow is sufficient; rich
        // text precision is intentionally out of scope.  Keep this fallback
        // narrow so another application's window can never become a target.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              frame.contains(anchor), pid != getpid() else { return nil }
        let fallbackCandidates = WindowIdentity.candidates(from: windows).filter {
            $0.pid == pid && $0.layer == 0 && $0.isSolid
        }
        func delta(_ candidate: WindowIdentity.Candidate) -> CGFloat {
            abs(candidate.frame.minX - frame.minX) + abs(candidate.frame.minY - frame.minY) +
            abs(candidate.frame.width - frame.width) + abs(candidate.frame.height - frame.height)
        }
        // Require one unambiguous candidate, or a near-identical one.  This
        // avoids guessing when an app has stacked windows with equal bounds.
        let near = fallbackCandidates.filter { delta($0) <= 12 }
        guard let candidate = near.count == 1 ? near[0] : nil else { return nil }
        healthMetadata["windowMatchMethod"] = "same-pid-frame-fallback"
        healthMetadata["windowFallbackDelta"] = String(Double(delta(candidate)))
        return candidate.id
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func axRange(_ value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, 0.12)
        guard let position = attribute(element, kAXPositionAttribute as CFString), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute as CFString), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
