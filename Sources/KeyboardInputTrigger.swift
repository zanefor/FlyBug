import AppKit
import ApplicationServices

/// Keyboard events wake the focused-input checker. Key contents are never
/// collected: committed text comes from the current editable control, which
/// also handles paste, input methods and edits to an existing word correctly.
final class KeyboardInputTrigger {
    var onInput: (() -> Void)?
    private var monitor: Any?
    private(set) var eventCount = 0
    var isListening: Bool { monitor != nil }

    func startIfAuthorized() {
        guard monitor == nil, AXIsProcessTrusted() else { return }
        // Global monitors are delivered by AppKit, but their callback queue is
        // not a useful contract for the rest of the monitor.  Always marshal
        // state changes to the main run loop: TextInputMonitor performs AX and
        // NSSpellChecker calls there, and mutating it from the event callback
        // used to make external apps silently miss a scan.
        let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged,
                                             .leftMouseDown, .rightMouseDown,
                                             .otherMouseDown]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.eventCount += 1
                self.onInput?()
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
