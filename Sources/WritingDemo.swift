import AppKit

/// An actual editable text field exercising the same language checker without AX permission.
final class WritingDemoController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    var onIssues: (([BugDiagnostic]) -> Void)?
    private let textView = NSTextView()
    private let resultLabel = NSTextField(wrappingLabelWithString: "正在检查…")
    private var debounce: Timer?
    private var generation = 0
    private var enabled = true
    private var language = "auto"
    private var spelling = true
    private var evidence: [String: (text: String, range: NSRange)] = [:]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 370),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "FlyBug · 文字试写"
        window.minSize = NSSize(width: 540, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = window.contentView!
        content.wantsLayer = true; content.layer?.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.91, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "试着写一句话，或修正下面的句子。")
        title.font = .systemFont(ofSize: 20, weight: .semibold); title.frame = NSRect(x: 26, y: 315, width: 570, height: 30)
        title.autoresizingMask = [.width, .minYMargin]; content.addSubview(title)
        let hint = NSTextField(wrappingLabelWithString: "使用真实的 macOS 拼写 / 语法检查。修改后约 1 秒更新；中文检查能力有限。")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 26, y: 270, width: 565, height: 36); hint.autoresizingMask = [.width, .minYMargin]; content.addSubview(hint)
        let scroll = NSScrollView(frame: NSRect(x: 26, y: 94, width: 568, height: 162))
        scroll.autoresizingMask = [.width, .height]; scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        textView.frame = NSRect(x: 0, y: 0, width: 548, height: 162)
        textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true; textView.textContainer?.containerSize = NSSize(width: 548, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.font = .systemFont(ofSize: 20); textView.textColor = .textColor; textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false; textView.isGrammarCheckingEnabled = false
        textView.string = "This is is a sentence.\nI bought a apple.\n这是我的的计划。"
        textView.delegate = self; scroll.documentView = textView; content.addSubview(scroll)
        resultLabel.font = .systemFont(ofSize: 13); resultLabel.frame = NSRect(x: 26, y: 22, width: 568, height: 58)
        resultLabel.autoresizingMask = [.width, .maxYMargin]; content.addSubview(resultLabel)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(enabled: Bool, language: String, checkSpelling: Bool) {
        let changed = self.enabled != enabled || self.language != language || spelling != checkSpelling
        self.enabled = enabled; self.language = language; spelling = checkSpelling
        if changed { schedule() }
    }

    func show() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true); schedule()
    }

    func stop() { generation += 1; debounce?.invalidate(); evidence.removeAll(); onIssues?([]) }
    func textDidChange(_ notification: Notification) { schedule() }
    func textViewDidChangeSelection(_ notification: Notification) { schedule() }
    func windowDidMove(_ notification: Notification) { schedule() }
    func windowDidResize(_ notification: Notification) { schedule() }
    func windowDidResignKey(_ notification: Notification) { stop() }
    func windowDidBecomeKey(_ notification: Notification) { schedule() }
    func windowWillClose(_ notification: Notification) { stop() }

    private func schedule() {
        generation += 1; debounce?.invalidate(); evidence.removeAll(); onIssues?([])
        guard enabled, window?.isKeyWindow == true else { resultLabel.stringValue = "文字检查已暂停或关闭。"; return }
        resultLabel.stringValue = "等待输入停顿后检查…"
        debounce = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in self?.check() }
    }

    private func point(for range: NSRange) -> ScreenPoint? {
        guard let window, window.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
              let layout = textView.layoutManager, let container = textView.textContainer,
              WritingEngine.valid(range, in: textView.string) else { return nil }
        layout.ensureLayout(for: container)
        let glyph = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyph, in: container)
        rect.origin.x += textView.textContainerOrigin.x; rect.origin.y += textView.textContainerOrigin.y
        guard rect.width > 0, rect.height > 0, rect.height < 65, textView.visibleRect.contains(NSPoint(x: rect.midX, y: rect.midY)) else { return nil }
        let point = window.convertPoint(toScreen: textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
        return ScreenPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    func isCurrentTarget(_ diagnostic: BugDiagnostic) -> Bool {
        guard enabled, let evidence = evidence[diagnostic.id], evidence.text == textView.string,
              let current = point(for: evidence.range), current == diagnostic.target else { return false }
        return true
    }

    private func check() {
        guard enabled, window?.isKeyWindow == true, !textView.hasMarkedText() else { return }
        let token = generation, text = textView.string
        guard (text as NSString).length <= 20_000 else { resultLabel.stringValue = "试写内容过长，请保留 20,000 个字符以内。"; return }
        var completed = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !completed, self.generation == token, self.window?.isKeyWindow == true else { return }
            self.resultLabel.stringValue = "系统文字检查服务暂未响应，请稍后编辑文字重试。"
        }
        WritingEngine.check(text, language: language, checkSpelling: spelling) { [weak self] issues in
            guard let self, self.enabled, self.generation == token, self.textView.string == text, self.window?.isKeyWindow == true else { return }
            completed = true
            let diagnostics = issues.map { issue -> BugDiagnostic in
                let id = DiagnosticText.diagnosticID("writing-demo:\(text):\(issue.range):\(issue.kind)")
                self.evidence[id] = (text, issue.range)
                return BugDiagnostic(id: id, source: "writing-demo", message: issue.message, severity: "warning", target: self.point(for: issue.range))
            }
            self.resultLabel.stringValue = diagnostics.first?.message ?? "系统检查器未提示问题。未提示不代表语法一定正确。"
            self.onIssues?(diagnostics)
        }
    }
}
