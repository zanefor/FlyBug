import AppKit
import WebKit

struct FlySettings: Codable {
    var size: Double = 28
    var speed: Double = 1
    var opacity: Double = 0.9
    var idleFlight = true
    var includeWarnings = false
    // Keep editor/terminal diagnostics useful on a fresh install. Users can
    // still turn screen observation off from the control panel.
    var screenMonitoring = true
    var scanInterval: Double = 3
    var textChecking = true
    var checkSpelling = true
    var textLanguage = "auto"

    static func restored(from data: Data?) -> FlySettings {
        var result = FlySettings()
        if let data, let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { result.update(values) }
        return result
    }

    mutating func update(_ values: [String: Any]) {
        func number(_ key: String, current: Double, range: ClosedRange<Double>) -> Double {
            guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return current }
            return min(range.upperBound, max(range.lowerBound, value.doubleValue))
        }
        size = number("size", current: size, range: 20...42)
        speed = number("speed", current: speed, range: 0.4...2)
        opacity = number("opacity", current: opacity, range: 0.35...1)
        scanInterval = number("scanInterval", current: scanInterval, range: 2...10)
        if let value = values["idleFlight"] as? Bool { idleFlight = value }
        if let value = values["includeWarnings"] as? Bool { includeWarnings = value }
        if let value = values["screenMonitoring"] as? Bool { screenMonitoring = value }
        if let value = values["textChecking"] as? Bool { textChecking = value }
        if let value = values["checkSpelling"] as? Bool { checkSpelling = value }
        if let value = values["textLanguage"] as? String, ["auto", "en_US", "zh_Hans"].contains(value) { textLanguage = value }
    }
}

private struct DiagnosticRecord {
    var diagnostic: BugDiagnostic
    var updatedAt: Date
    var ownerPID: pid_t?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var settings = FlySettings()
    private var running = true
    private var controllerWindow: NSWindow!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private var pauseMenuItem: NSMenuItem!
    private var overlay: FlyOverlay!
    private let monitor = DiagnosticMonitor()
    private let textMonitor = TextInputMonitor()
    private var writingDemo: WritingDemoController?
    private var writingDiagnostics: [BugDiagnostic] = []
    private var writingDemoIssues: [BugDiagnostic] = []
    private var textStatus = "等待文字检查启动"
    private var checkingText = false
    private var bridge: BridgeServer!
    private var bridgePort = 0
    private var bridgeStatus = "正在启动本地接入"
    private var lastBridge = Date.distantPast
    private var records: [String: DiagnosticRecord] = [:]
    private var current: BugDiagnostic?
    private var events: [[String: String]] = []
    private var status = "自由飞行中；可连接编辑器或开启屏幕观察。"
    private var heartbeat: Timer?
    private var activationObserver: NSObjectProtocol?
    private var locateInFlight = false
    private var locateGeneration = 0
    private var tickCount = 0
    private var monitoring = false
    private var webReady = false
    private var lastStateJSON = ""
    private var demoWindow: NSWindow?
    private var demoExpires = Date.distantPast
    private var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FlyBug", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        settings = FlySettings.restored(from: UserDefaults.standard.data(forKey: "settings"))
        // Older builds persisted the old false default. Migrate that implicit
        // default once so a normal Terminal/Codex session is monitored without
        // requiring the user to discover a hidden switch first.
        if !UserDefaults.standard.bool(forKey: "screenMonitoringMigratedV2") {
            settings.screenMonitoring = true
            UserDefaults.standard.set(true, forKey: "screenMonitoringMigratedV2")
        }
        NSApp.applicationIconImage = FlyArtwork.icon()
        createMenu()
        overlay = FlyOverlay()
        createController()
        monitor.onDiagnostic = { [weak self] diagnostic in self?.receiveObserved(diagnostic) }
        monitor.onStatus = { [weak self] value in
            guard let self, self.running else { return }
            if self.current == nil { self.status = value; self.publish() }
        }
        textMonitor.onIssues = { [weak self] issues in
            guard let self else { return }
            let previousIDs = Set(self.writingDiagnostics.map(\.id))
            self.writingDiagnostics = self.running && self.settings.textChecking ? issues : []
            if let current = self.current, current.source == "writing",
               !self.writingDiagnostics.contains(where: { $0.id == current.id && $0.target == current.target }) {
                self.current = nil; self.overlay.setTarget(nil)
            }
            self.locateGeneration += 1
            for issue in self.writingDiagnostics where !previousIDs.contains(issue.id) { self.addEvent(issue.message, severity: "warning") }
            self.refreshCurrent()
        }
        textMonitor.onStatus = { [weak self] value in self?.textStatus = value; self?.publish() }
        bridge = BridgeServer(directory: dataDirectory)
        bridge.onState = { [weak self] port, value in self?.bridgePort = port; self?.bridgeStatus = value; self?.publish() }
        bridge.onDiagnostics = { [weak self] envelope in self?.receive(envelope) }
        bridge.start()
        applySettings()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.locateGeneration += 1
            self.overlay.setTarget(nil)
            self.writingDiagnostics.removeAll()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
                self.demoExpires = .distantPast
                if self.current?.source == "demo" { self.current = nil }
            }
            self.records = self.records.filter { !["screen", "accessibility"].contains($0.value.diagnostic.source) }
            if self.current?.source != "demo" { self.current?.target = nil }
            if self.checkingText { self.textMonitor.rescan() }
            self.refreshCurrent()
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common); heartbeat = timer
        addEvent("FlyBug 已启动 · 所有识别在本地运行", severity: "info")
        showController()
    }

    private func createMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "FlyBug 控制面板", action: #selector(showController), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 FlyBug", action: #selector(quit), keyEquivalent: "q").target = self
        let edit = NSMenuItem(); edit.title = "编辑"; edit.submenu = NSMenu(title: "编辑")
        edit.submenu?.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(edit)
        let windowMenu = NSMenuItem(); windowMenu.title = "窗口"; windowMenu.submenu = NSMenu(title: "窗口")
        windowMenu.submenu?.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(windowMenu); NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "FlyBug"
        statusItem.button?.toolTip = "桌面捕虫器"
        let menu = NSMenu()
        menu.addItem(withTitle: "打开控制面板", action: #selector(showController), keyEquivalent: "").target = self
        pauseMenuItem = menu.addItem(withTitle: "暂停飞行", action: #selector(toggleRunning), keyEquivalent: "p")
        pauseMenuItem.keyEquivalentModifierMask = [.command, .shift]; pauseMenuItem.target = self
        menu.addItem(withTitle: "试飞一下", action: #selector(demo), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 FlyBug", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    private func createController() {
        controllerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 770), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        controllerWindow.title = "FlyBug · 捕虫器"
        controllerWindow.minSize = NSSize(width: 560, height: 550)
        controllerWindow.isReleasedWhenClosed = false; controllerWindow.delegate = self
        controllerWindow.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.91, alpha: 1)
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "flybug")
        webView = WKWebView(frame: controllerWindow.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        controllerWindow.contentView = webView
        controllerWindow.center()
        if let directory = Bundle.main.resourceURL {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        }
    }

    @objc func showController() {
        guard controllerWindow != nil else { return }
        controllerWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        publish()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showController(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeat?.invalidate(); monitor.stop(); textMonitor.stop(); writingDemo?.stop(); overlay?.stop(); bridge?.stop()
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === demoWindow { demoExpires = .distantPast; clearCurrentDemo() }
    }

    func windowDidMove(_ notification: Notification) {
        if notification.object as? NSWindow === demoWindow, current?.source == "demo", demoExpires > Date() { demo() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === controllerWindow, current?.source == "demo" {
            demoExpires = .distantPast; clearCurrentDemo()
        }
    }

    @objc private func toggleRunning() {
        running.toggle()
        locateGeneration += 1
        if !running { overlay.setTarget(nil) }
        status = running ? "已恢复飞行。" : "已暂停飞行和屏幕观察。"
        applySettings(); addEvent(status, severity: "info"); publish()
    }

    private func applySettings() {
        overlay.size = settings.size; overlay.speed = settings.speed; overlay.opacity = settings.opacity
        overlay.idleFlight = settings.idleFlight; overlay.running = running
        monitor.includeWarnings = settings.includeWarnings; monitor.interval = settings.scanInterval
        let shouldMonitor = running && settings.screenMonitoring
        if shouldMonitor != monitoring {
            monitoring = shouldMonitor
            if shouldMonitor { monitor.start() } else { monitor.stop(); locateGeneration += 1 }
        }
        if !settings.includeWarnings {
            records = records.filter { $0.value.diagnostic.severity != "warning" }
        }
        if !settings.screenMonitoring {
            records = records.filter { !["screen", "accessibility"].contains($0.value.diagnostic.source) }
        }
        textMonitor.checkSpelling = settings.checkSpelling
        textMonitor.language = settings.textLanguage
        let shouldCheckText = running && settings.textChecking
        if shouldCheckText != checkingText {
            checkingText = shouldCheckText
            if shouldCheckText { textMonitor.start() } else {
                textMonitor.stop(); writingDiagnostics.removeAll(); writingDemoIssues.removeAll()
                textStatus = settings.textChecking ? "文字检查已暂停" : "文字检查已关闭"
                if current.map({ isWriting($0) }) == true { current = nil; overlay.setTarget(nil) }
            }
        }
        writingDemo?.configure(enabled: shouldCheckText, language: settings.textLanguage, checkSpelling: settings.checkSpelling)
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
        pauseMenuItem.title = running ? "暂停飞行" : "恢复飞行"
        statusItem.button?.appearsDisabled = !running
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.webView === webView,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready": webReady = true; lastStateJSON = ""
        case "toggleRunning": toggleRunning()
        case "demo": demo()
        case "writingDemo": showWritingDemo()
        case "clear":
            records.removeAll(); writingDiagnostics.removeAll(); writingDemoIssues.removeAll(); current = nil; events.removeAll(); demoExpires = .distantPast
            locateGeneration += 1; overlay.setTarget(nil)
            textMonitor.rescan()
            status = "记录已清空；仍存在的报错会在下次检查时重新出现。"
        case "settings":
            if let values = body["settings"] as? [String: Any] {
                locateGeneration += 1
                settings.update(values); applySettings(); refreshCurrent()
            }
        case "permission":
            if body["kind"] as? String == "screen" {
                DiagnosticMonitor.requestScreen()
                openPermissionPane("Privacy_ScreenCapture")
                status = "在系统设置中允许 FlyBug 录制屏幕，然后重新打开应用使权限生效。"
            } else if body["kind"] as? String == "accessibility" {
                DiagnosticMonitor.requestAccessibility()
                openPermissionPane("Privacy_Accessibility")
                status = "在系统设置中允许 FlyBug 使用辅助功能，以便检查输入框并定位文字和代码。"
            }
        case "openDataFolder":
            try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dataDirectory)
        case "copyBridgeCommand": copyBridgeExample()
        case "quit": quit()
        default: break
        }
        publish()
    }

    private func openPermissionPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    private func copyBridgeExample() {
        let script = """
        python3 - <<'PY'
        import json, pathlib, urllib.request
        p = pathlib.Path.home() / 'Library/Application Support/FlyBug/bridge.json'
        config = json.loads(p.read_text())
        body = {'source': 'custom-tool', 'replace': True, 'diagnostics': [
            {'id': 'example-1', 'source': 'custom-tool', 'severity': 'error',
             'message': '请替换为实际诊断信息', 'file': '/absolute/path/to/your/file.py',
             'line': 12, 'lineText': '请替换为出错行的完整代码'}]}
        request = urllib.request.Request('http://127.0.0.1:%s/diagnostics' % config['port'],
            data=json.dumps(body).encode(), headers={'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + config['token']}, method='POST')
        print(urllib.request.urlopen(request, timeout=3).read().decode())
        PY
        """
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(script, forType: .string)
        status = "接入示例已复制。替换文件、行号和代码后运行；当前令牌不会写入剪贴板。"
    }

    private func key(_ diagnostic: BugDiagnostic) -> String { diagnostic.source + "\u{001F}" + diagnostic.id }

    private func isWriting(_ diagnostic: BugDiagnostic) -> Bool { ["writing", "writing-demo"].contains(diagnostic.source) }

    private func isCurrentTarget(_ diagnostic: BugDiagnostic) -> Bool {
        if diagnostic.source == "writing" { return textMonitor.isCurrentTarget(diagnostic) }
        if diagnostic.source == "writing-demo" { return writingDemo?.isCurrentTarget(diagnostic) ?? false }
        return monitor.isCurrentTarget(diagnostic)
    }

    private func receiveObserved(_ diagnostic: BugDiagnostic) {
        guard running, settings.screenMonitoring, settings.includeWarnings || diagnostic.severity != "warning" else { return }
        let recordKey = key(diagnostic)
        let isNew = records[recordKey] == nil
        records[recordKey] = DiagnosticRecord(diagnostic: diagnostic, updatedAt: Date(), ownerPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        if isNew { addEvent(diagnostic.message, severity: diagnostic.severity) }
        refreshCurrent()
    }

    private func receive(_ envelope: DiagnosticEnvelope) {
        lastBridge = Date()
        let old = records
        if envelope.replace ?? true { records = records.filter { $0.value.diagnostic.source != envelope.source } }
        for var diagnostic in envelope.diagnostics where settings.includeWarnings || diagnostic.severity != "warning" {
            // The screen locator verifies file visibility; never trust old client coordinates.
            diagnostic.target = nil
            let recordKey = key(diagnostic)
            if old[recordKey]?.diagnostic.message != diagnostic.message { addEvent(diagnostic.message, severity: diagnostic.severity) }
            if let existing = old[recordKey], existing.diagnostic.file == diagnostic.file,
               existing.diagnostic.line == diagnostic.line, existing.diagnostic.lineText == diagnostic.lineText,
               existing.diagnostic.column == diagnostic.column, existing.diagnostic.message == diagnostic.message,
               monitor.isCurrentTarget(existing.diagnostic) {
                diagnostic.target = existing.diagnostic.target
            }
            records[recordKey] = DiagnosticRecord(diagnostic: diagnostic, updatedAt: Date(), ownerPID: nil)
        }
        locateGeneration += 1
        refreshCurrent()
        publish()
    }

    private func refreshCurrent() {
        guard running else { publish(); return }
        if demoExpires > Date(), let current, current.source == "demo" { overlay.setTarget(current.target); return }
        let writing = settings.textChecking ? writingDemoIssues + writingDiagnostics : []
        if let issue = writing.first(where: { isCurrentTarget($0) }) {
            current = issue; overlay.setTarget(issue.target)
            status = "发现文字问题，已定位到对应文字。"; publish(); return
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let available = records.values.filter {
            ($0.ownerPID == nil || ($0.ownerPID == pid && monitor.isCurrentTarget($0.diagnostic))) &&
            (settings.includeWarnings || $0.diagnostic.severity == "error")
        }
        let sorted = available.sorted {
            if key($0.diagnostic) == key($1.diagnostic) { return false }
            if $0.diagnostic.severity != $1.diagnostic.severity { return $0.diagnostic.severity == "error" }
            if let current, key($0.diagnostic) == key(current) { return true }
            if let current, key($1.diagnostic) == key(current) { return false }
            let aBridge = $0.ownerPID == nil, bBridge = $1.ownerPID == nil
            if aBridge != bBridge { return aBridge }
            return $0.updatedAt > $1.updatedAt
        }
        guard let chosen = sorted.first else {
            current = writing.first(where: { $0.target == nil }); overlay.setTarget(nil)
            status = current != nil ? "发现文字问题；此输入框未提供可靠的文字位置。" : settings.screenMonitoring ? "正在观察当前代码工具中的可见报错。" : "自由飞行中；文字检查、编辑器接入可独立工作。"
            publish(); return
        }
        if chosen.ownerPID != nil {
            current = chosen.diagnostic; overlay.setTarget(chosen.diagnostic.target); status = "发现可见报错，已定位。"
        } else {
            locateCandidates(Array(sorted.filter { $0.ownerPID == nil }.prefix(6)).map(\.diagnostic),
                             observed: sorted.first(where: { $0.ownerPID != nil })?.diagnostic)
        }
        publish()
    }

    private func locateCandidates(_ candidates: [BugDiagnostic], observed: BugDiagnostic?) {
        guard running, !locateInFlight, let first = candidates.first else { return }
        locateInFlight = true
        let generation = locateGeneration
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        func attempt(_ index: Int) {
            guard self.running, generation == self.locateGeneration, pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                self.locateInFlight = false; return
            }
            guard index < candidates.count else {
                self.locateInFlight = false
                if let observed, self.monitor.isCurrentTarget(observed) {
                    self.current = observed; self.overlay.setTarget(observed.target); self.status = "发现可见报错，已定位。"
                } else {
                    var pending = first; pending.target = nil
                    self.current = pending; self.overlay.setTarget(nil)
                    self.status = "已收到诊断；请将对应文件和代码行显示在前台，并授权辅助功能或屏幕录制以定位。"
                }
                self.publish(); return
            }
            let diagnostic = candidates[index]
            guard self.records[self.key(diagnostic)] != nil, self.settings.includeWarnings || diagnostic.severity == "error" else {
                attempt(index + 1); return
            }
            // Bridge diagnostics are explicit reports from Codex, Claude Code,
            // terminals and editor integrations.  They may be rendered by a
            // web view or an app unknown to the screen monitor, so let the
            // locator use the foreground app and its conservative fallback.
            self.monitor.locate(diagnostic, allowAnyFrontApp: true) { [weak self] located in
                guard let self else { return }
                guard self.running, generation == self.locateGeneration,
                      pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                    self.locateInFlight = false; return
                }
                guard self.records[self.key(diagnostic)] != nil, self.settings.includeWarnings || diagnostic.severity == "error" else {
                    attempt(index + 1); return
                }
                self.records[self.key(diagnostic)]?.diagnostic.target = located.target
                if located.target != nil {
                    self.locateInFlight = false; self.current = located; self.overlay.setTarget(located.target)
                    self.status = "已定位到屏幕上的报错代码。"; self.publish()
                } else { attempt(index + 1) }
            }
        }
        attempt(0)
    }

    private func tick() {
        tickCount += 1
        let now = Date()
        records = records.filter { _, record in
            let ttl: Double = record.ownerPID != nil ? max(10, settings.scanInterval * 3) : record.diagnostic.source.hasPrefix("vscode:") ? 18 : 45
            return now.timeIntervalSince(record.updatedAt) < ttl
        }
        if let current, current.source != "demo", current.target != nil, !isCurrentTarget(current) {
            self.current?.target = nil; overlay.setTarget(nil)
        }
        if demoExpires <= now, current?.source == "demo" { clearCurrentDemo() }
        if tickCount % 2 == 0 { refreshCurrent() }
        publish()
    }

    private func clearCurrentDemo() {
        if current?.source == "demo" { current = nil; overlay.setTarget(nil); refreshCurrent() }
    }

    private func showWritingDemo() {
        if !running { running = true }
        settings.textChecking = true; applySettings()
        if writingDemo == nil {
            let demo = WritingDemoController()
            demo.onIssues = { [weak self] issues in
                guard let self else { return }
                let previousIDs = Set(self.writingDemoIssues.map(\.id))
                self.writingDemoIssues = self.running && self.settings.textChecking ? issues : []
                if let current = self.current, current.source == "writing-demo",
                   !self.writingDemoIssues.contains(where: { $0.id == current.id && $0.target == current.target }) {
                    self.current = nil; self.overlay.setTarget(nil)
                }
                self.locateGeneration += 1
                for issue in self.writingDemoIssues where !previousIDs.contains(issue.id) { self.addEvent(issue.message, severity: "warning") }
                self.refreshCurrent()
            }
            writingDemo = demo
        }
        writingDemo?.configure(enabled: true, language: settings.textLanguage, checkSpelling: settings.checkSpelling)
        writingDemo?.show()
    }

    @objc private func demo() {
        if !running { running = true; applySettings() }
        if demoWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "FlyBug 试飞靶场 · 演示数据"
            window.isReleasedWhenClosed = false; window.delegate = self
            window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
            let text = NSTextView(frame: NSRect(x: 24, y: 65, width: 565, height: 205))
            text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
            text.textContainerInset = NSSize(width: 8, height: 12)
            let code = "// demo.js · 故意留下的一处错误\n\n01  const price = 29;\n02  const quantity = 3;\n03  const total = price * count;\n\nReferenceError: count is not defined"
            let attr = NSMutableAttributedString(string: code, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular), .foregroundColor: NSColor(calibratedWhite: 0.87, alpha: 1)])
            attr.addAttribute(.foregroundColor, value: NSColor(calibratedRed: 1, green: 0.46, blue: 0.34, alpha: 1), range: (code as NSString).range(of: "count;"))
            attr.addAttribute(.foregroundColor, value: NSColor(calibratedRed: 1, green: 0.58, blue: 0.43, alpha: 1), range: (code as NSString).range(of: "ReferenceError: count is not defined"))
            text.textStorage?.setAttributedString(attr)
            window.contentView?.addSubview(text)
            let label = NSTextField(wrappingLabelWithString: "苍蝇将停在第 3 行的 count 附近。它不拦截点击，15 秒后恢复巡游。")
            label.font = .systemFont(ofSize: 12); label.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
            label.frame = NSRect(x: 34, y: 18, width: 540, height: 38); window.contentView?.addSubview(label)
            window.center(); demoWindow = window
        }
        guard let window = demoWindow else { return }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let text = window.contentView?.subviews.compactMap({ $0 as? NSTextView }).first,
                  let layout = text.layoutManager, let container = text.textContainer else { return }
            let range = (text.string as NSString).range(of: "count;")
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
            let local = text.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let screen = window.convertPoint(toScreen: local)
            let point = ScreenPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            self.locateGeneration += 1
            self.current = BugDiagnostic(id: "demo", source: "demo", message: "演示：ReferenceError: count is not defined", severity: "error", file: "demo.js", line: 3, lineText: "const total = price * count;", target: point)
            self.demoExpires = Date().addingTimeInterval(15)
            self.overlay.setTarget(point)
            self.status = "试飞演示中 · 此错误为内置示例，15 秒后恢复自由飞行。"
            self.addEvent("试飞演示 · demo.js:3", severity: "info"); self.publish()
        }
    }

    private func addEvent(_ message: String, severity: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        events.insert(["time": formatter.string(from: Date()), "message": String(message.prefix(500)), "severity": severity], at: 0)
        events = Array(events.prefix(30))
    }

    private func publish() {
        // Keep headless health reporting alive even when the control panel has not
        // finished loading. Inspecting it must never steal focus from the input.
        let coordinates = overlay?.healthCoordinates
        let knownSources = ["writing", "writing-demo", "demo", "screen", "accessibility"]
        let source = current.map { knownSources.contains($0.source) ? $0.source : "bridge" }
        bridge?.updateHealth(BridgeHealthSnapshot(
            running: running,
            accessibility: DiagnosticMonitor.accessibilityGranted(),
            screen: DiagnosticMonitor.screenGranted(),
            textChecking: settings.textChecking,
            checkSpelling: settings.checkSpelling,
            textStatus: textStatus,
            inputMetadata: textMonitor.healthMetadata,
            writingIssueCount: writingDiagnostics.count,
            writingTargetCount: writingDiagnostics.filter { $0.target != nil }.count,
            currentSource: source,
            flyTarget: coordinates?.target,
            flyPosition: coordinates?.position))
        guard webReady, webView != nil else { return }
        let settingsObject = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) ?? [:]
        let diagnosticObject: Any = current.flatMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
        let state: [String: Any] = ["running": running, "settings": settingsObject,
            "permissions": ["accessibility": DiagnosticMonitor.accessibilityGranted(), "screen": DiagnosticMonitor.screenGranted()],
            "bridge": ["port": bridgePort, "connected": Date().timeIntervalSince(lastBridge) < 18, "status": bridgeStatus],
            "status": status, "textStatus": textStatus, "diagnostic": diagnosticObject, "events": events, "version": "1.2.0"]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) else { return }
        guard json != lastStateJSON else { return }
        lastStateJSON = json
        // JSON is passed as a JS function argument; diagnostic text never enters HTML.
        webView.evaluateJavaScript("window.flybugUpdate && window.flybugUpdate(\(json));", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.isFileURL,
           let resources = Bundle.main.resourceURL,
           url.standardizedFileURL.path.hasPrefix(resources.standardizedFileURL.path + "/") { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }
}
