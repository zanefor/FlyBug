import AppKit
import ApplicationServices

/// AX and CGWindow bounds use the same global desktop points, but applications
/// can disagree about their window decorations. Match identity without scaling,
/// flipping coordinates, or guessing the nearest window.
enum WindowIdentity {
    enum Method: String { case exact, windowNumber, hitTest }

    struct Match: Equatable {
        let id: CGWindowID
        let frame: CGRect
        let method: Method
    }

    struct Candidate {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let alpha: Double
        let frame: CGRect

        var isSolid: Bool {
            id != kCGNullWindowID && alpha.isFinite && alpha > 0.2 && WindowIdentity.valid(frame)
        }
    }

    static func candidates(from info: [[String: Any]]) -> [Candidate] {
        info.compactMap { item in
            guard let id = item[kCGWindowNumber as String] as? UInt32,
                  let rawPID = item[kCGWindowOwnerPID as String] as? Int,
                  let pid = Int32(exactly: rawPID),
                  let layer = item[kCGWindowLayer as String] as? Int,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return Candidate(id: id, pid: pid, layer: layer,
                             alpha: item[kCGWindowAlpha as String] as? Double ?? 1, frame: frame)
        }
    }

    /// Pure identity selection. `windows` must retain CGWindow's front-to-back
    /// order. Exact geometry establishes identity, while the fallback additionally
    /// requires an AX hit in the focused window and an unobstructed anchor point.
    /// Callers must still revalidate visibility at the final error coordinate.
    static func choose(pid: pid_t, frame: CGRect, anchor: CGPoint, windows: [Candidate],
                       focusedWindowHit: Bool, ignoringPID: pid_t) -> Match? {
        guard valid(frame), pid != ignoringPID else { return nil }
        let exact = exactCandidates(pid: pid, frame: frame, windows: windows)
        if exact.count == 1 {
            return Match(id: exact[0].id, frame: exact[0].frame, method: .exact)
        }
        guard focusedWindowHit, anchor.x.isFinite, anchor.y.isFinite, frame.contains(anchor) else { return nil }
        // A same-PID popup at a different layer or another app covering the
        // anchor is an obstruction, never a candidate to skip past.
        for window in windows where window.pid != ignoringPID && window.isSolid && window.frame.contains(anchor) {
            guard window.pid == pid, window.layer == 0 else { return nil }
            return Match(id: window.id, frame: window.frame, method: .hitTest)
        }
        return nil
    }

    static func resolve(pid: pid_t, application: AXUIElement, focusedWindow: AXUIElement,
                        frame: CGRect, anchor: CGPoint, windowInfo: [[String: Any]],
                        ignoringPID: pid_t, diagnostics: (([String: String]) -> Void)? = nil) -> Match? {
        let windows = candidates(from: windowInfo)
        // Structural metadata only: no titles, labels, values, or selected text.
        var debug = ["windowMatchMethod": "unresolved", "hitAXError": "not_attempted",
                     "hitWindowMatches": "not_checked", "foregroundWindowMatches": "not_checked",
                     "ignoredDesktopOverlayCount": "0",
                     "anchorX": String(Double(anchor.x)), "anchorY": String(Double(anchor.y)),
                     "anchorInsideAXFrame": String(frame.contains(anchor)),
                     "identityExactMatches": String(exactCandidates(pid: pid, frame: frame, windows: windows).count)]
        defer { diagnostics?(debug) }
        if let covering = windows.first(where: { $0.pid != ignoringPID && $0.isSolid && $0.frame.contains(anchor) }) {
            debug["firstCoveringWindowID"] = String(covering.id)
            debug["firstCoveringPID"] = String(covering.pid)
            debug["firstCoveringPIDMatches"] = String(covering.pid == pid)
            debug["firstCoveringLayer"] = String(covering.layer)
            debug["firstCoveringAlpha"] = String(covering.alpha)
            debug["firstCoveringX"] = String(Double(covering.frame.minX))
            debug["firstCoveringY"] = String(Double(covering.frame.minY))
            debug["firstCoveringWidth"] = String(Double(covering.frame.width))
            debug["firstCoveringHeight"] = String(Double(covering.frame.height))
            if let ownerName = windowInfo.first(where: { $0[kCGWindowNumber as String] as? UInt32 == covering.id })?[kCGWindowOwnerName as String] as? String {
                debug["firstCoveringOwnerName"] = String(ownerName.prefix(100))
            }
        } else {
            debug["firstCoveringWindowID"] = "none"
        }
        if let exact = choose(pid: pid, frame: frame, anchor: anchor, windows: windows,
                              focusedWindowHit: false, ignoringPID: ignoringPID) {
            debug["windowMatchMethod"] = exact.method.rawValue
            return exact
        }
        let applicationPIDMatches = belongs(application, to: pid)
        let focusedWindowPIDMatches = belongs(focusedWindow, to: pid)
        debug["identityApplicationPIDMatches"] = String(applicationPIDMatches)
        debug["identityFocusedWindowPIDMatches"] = String(focusedWindowPIDMatches)
        guard valid(frame), pid != ignoringPID, applicationPIDMatches, focusedWindowPIDMatches else { return nil }

        // Some AX implementations expose a window number. It is direct identity
        // evidence only when that ID also names one of the exact same-PID/frame
        // CG candidates; an unmatched or malformed value never widens matching.
        var numberValue: CFTypeRef?
        let numberError = AXUIElementCopyAttributeValue(focusedWindow, "AXWindowNumber" as CFString, &numberValue)
        debug["axWindowNumberError"] = errorLabel(numberError)
        if numberError == .success, let numberValue, CFGetTypeID(numberValue) == CFNumberGetTypeID(),
           let number = numberValue as? NSNumber, number.doubleValue.isFinite,
           let id = UInt32(exactly: number.doubleValue), id != kCGNullWindowID {
            debug["axWindowNumber"] = String(id)
            let numbered = windowNumberMatch(pid: pid, frame: frame, windows: windows, number: id, ignoringPID: ignoringPID)
            debug["axWindowNumberMatches"] = String(numbered != nil)
            if let numbered {
                let current = element(attribute(application, kAXFocusedWindowAttribute as CFString))
                let stillFocused = current.map { CFEqual($0, focusedWindow) } ?? false
                debug["foregroundWindowMatches"] = String(stillFocused)
                guard stillFocused else { return nil }
                debug["windowMatchMethod"] = numbered.method.rawValue
                return numbered
            }
        }
        guard valid(frame), frame.contains(anchor), anchor.x.isFinite, anchor.y.isFinite,
              abs(anchor.x) <= CGFloat(Float.greatestFiniteMagnitude),
              abs(anchor.y) <= CGFloat(Float.greatestFiniteMagnitude) else { return nil }
        let visibleInfo = filteredForVisibility(windowInfo: windowInfo, at: anchor, focusedWindow: focusedWindow, pid: pid) {
            debug.merge($0) { _, new in new }
        }
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(application, Float(anchor.x), Float(anchor.y), &hit)
        debug["hitAXError"] = errorLabel(hitError)
        guard hitError == .success, let hit else { return nil }
        debug["hitRole"] = String((attribute(hit, kAXRoleAttribute as CFString) as? String ?? "unavailable").prefix(64))
        let hitPIDMatches = belongs(hit, to: pid)
        debug["hitPIDMatches"] = String(hitPIDMatches)
        guard hitPIDMatches else { return nil }
        let hitMatches = hitBelongsToWindow(hit, window: focusedWindow, pid: pid, diagnostics: &debug)
        debug["hitWindowMatches"] = String(hitMatches)
        let current = element(attribute(application, kAXFocusedWindowAttribute as CFString))
        let stillFocused = current.map { CFEqual($0, focusedWindow) } ?? false
        debug["foregroundWindowMatches"] = String(stillFocused)
        guard hitMatches, stillFocused else { return nil }
        let match = choose(pid: pid, frame: frame, anchor: anchor, windows: candidates(from: visibleInfo),
                           focusedWindowHit: true, ignoringPID: ignoringPID)
        debug["windowMatchMethod"] = match?.method.rawValue ?? "unresolved"
        return match
    }

    /// Dock can publish a transparent desktop surface with window alpha 1. Only
    /// the observed full-display layer is eligible, and only when a system-wide
    /// AX hit proves that the requested application's focused window is visible
    /// through it at this exact point. Ordinary Dock windows remain blockers.
    static func filteredForVisibility(windowInfo: [[String: Any]], at point: CGPoint,
                                      focusedWindow: AXUIElement, pid: pid_t,
                                      diagnostics: (([String: String]) -> Void)? = nil) -> [[String: Any]] {
        var debug = ["ignoredDesktopOverlayCount": "0", "systemHitAXError": "not_attempted"]
        defer { diagnostics?(debug) }
        let displays = activeDisplayFrames()
        let windows = candidates(from: windowInfo)
        var bundles: [pid_t: String] = [:]
        for candidate in windows where candidate.layer == 20 && candidate.frame.contains(point) {
            if let bundle = NSRunningApplication(processIdentifier: candidate.pid)?.bundleIdentifier {
                bundles[candidate.pid] = bundle
            }
        }
        let possible = windows.filter {
            $0.frame.contains(point) && shouldIgnoreDesktopOverlay($0, ownerBundleID: bundles[$0.pid],
                                                                  displayFrames: displays, systemHitMatches: true)
        }
        debug["possibleDesktopOverlayCount"] = String(possible.count)
        guard !possible.isEmpty || diagnostics != nil else { return windowInfo }
        guard point.x.isFinite, point.y.isFinite,
              abs(point.x) <= CGFloat(Float.greatestFiniteMagnitude),
              abs(point.y) <= CGFloat(Float.greatestFiniteMagnitude),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              belongs(focusedWindow, to: pid) else { return windowInfo }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        guard let current = element(attribute(axApp, kAXFocusedWindowAttribute as CFString)),
              CFEqual(current, focusedWindow) else {
            debug["desktopOverlayFocusedWindowMatches"] = "false"
            return windowInfo
        }
        debug["desktopOverlayFocusedWindowMatches"] = "true"
        let hitMatches = systemHitMatchesWindow(at: point, focusedWindow: focusedWindow, pid: pid, diagnostics: &debug)
        guard hitMatches, !possible.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let after = element(attribute(axApp, kAXFocusedWindowAttribute as CFString)),
              CFEqual(after, focusedWindow) else { return windowInfo }
        let ignored = Set(possible.filter {
            shouldIgnoreDesktopOverlay($0, ownerBundleID: bundles[$0.pid], displayFrames: displays,
                                       systemHitMatches: hitMatches)
        }.map(\.id))
        debug["ignoredDesktopOverlayCount"] = String(ignored.count)
        return windowInfo.filter { item in
            guard let id = item[kCGWindowNumber as String] as? UInt32 else { return true }
            return !ignored.contains(id)
        }
    }

    /// Pure screening rule. The caller supplies actual runtime bundle identity,
    /// CGDisplayBounds values and the independently verified system-wide AX hit.
    static func shouldIgnoreDesktopOverlay(_ candidate: Candidate, ownerBundleID: String?,
                                          displayFrames: [CGRect], systemHitMatches: Bool) -> Bool {
        systemHitMatches && candidate.isSolid && ownerBundleID == "com.apple.dock" && candidate.layer == 20 &&
            displayFrames.contains(where: { valid($0) && $0 == candidate.frame })
    }

    private static func activeDisplayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var received: UInt32 = 0
        let result = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(count, buffer.baseAddress, &received)
        }
        guard result == .success else { return [] }
        return displays.prefix(min(Int(received), displays.count)).map { CGDisplayBounds($0) }
    }

    private static func systemHitMatchesWindow(at point: CGPoint, focusedWindow: AXUIElement, pid: pid_t,
                                              diagnostics: inout [String: String]) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var systemHit: AXUIElement?
        let systemError = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &systemHit)
        diagnostics["systemHitAXError"] = errorLabel(systemError)
        guard systemError == .success, let systemHit else { return false }
        AXUIElementSetMessagingTimeout(systemHit, 0.12)
        diagnostics["systemHitRole"] = String((attribute(systemHit, kAXRoleAttribute as CFString) as? String ?? "unavailable").prefix(64))
        var systemPID: pid_t = 0
        let pidError = AXUIElementGetPid(systemHit, &systemPID)
        diagnostics["systemHitPIDError"] = errorLabel(pidError)
        guard pidError == .success else { return false }
        diagnostics["systemHitPID"] = String(systemPID)
        diagnostics["systemHitPIDMatches"] = String(systemPID == pid)
        if let ownerName = NSRunningApplication(processIdentifier: systemPID)?.localizedName {
            diagnostics["systemHitOwnerName"] = String(ownerName.prefix(100))
        }
        var windowDetail: [String: String] = [:]
        let matches = hitBelongsToWindow(systemHit, window: focusedWindow, pid: pid, diagnostics: &windowDetail)
        diagnostics["systemHitWindowMatches"] = String(matches)
        for (key, value) in windowDetail {
            diagnostics["system" + key.prefix(1).uppercased() + String(key.dropFirst())] = value
        }
        return matches
    }

    static func windowNumberMatch(pid: pid_t, frame: CGRect, windows: [Candidate], number: CGWindowID,
                                  ignoringPID: pid_t) -> Match? {
        guard valid(frame), pid != ignoringPID, number != kCGNullWindowID else { return nil }
        let numbered = exactCandidates(pid: pid, frame: frame, windows: windows).filter { $0.id == number }
        guard numbered.count == 1 else { return nil }
        return Match(id: numbered[0].id, frame: numbered[0].frame, method: .windowNumber)
    }

    private static func exactCandidates(pid: pid_t, frame: CGRect, windows: [Candidate]) -> [Candidate] {
        windows.filter {
            $0.isSolid && $0.pid == pid && $0.layer == 0 &&
                abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2 &&
                abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2
        }
    }

    private static func hitBelongsToWindow(_ hit: AXUIElement, window: AXUIElement, pid: pid_t,
                                         diagnostics: inout [String: String]) -> Bool {
        var current: AXUIElement? = hit
        var seen: [AXUIElement] = []
        for depth in 0..<32 {
            guard let node = current, belongs(node, to: pid),
                  !seen.contains(where: { CFEqual($0, node) }) else { return false }
            seen.append(node)
            diagnostics["hitWindowDepth"] = String(depth)
            if CFEqual(node, window) {
                diagnostics["hitWindowEvidence"] = "parent_chain"
                return true
            }
            AXUIElementSetMessagingTimeout(node, 0.12)
            var ownerValue: CFTypeRef?
            let ownerError = AXUIElementCopyAttributeValue(node, kAXWindowAttribute as CFString, &ownerValue)
            diagnostics["hitWindowAttributeError"] = errorLabel(ownerError)
            if let owner = element(ownerValue), ownerError == .success {
                // An explicit conflicting owner is stronger than geometry.
                diagnostics["hitWindowEvidence"] = "AXWindow"
                return CFEqual(owner, window)
            }
            current = element(attribute(node, kAXParentAttribute as CFString))
        }
        return false
    }

    private static func errorLabel(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .noValue: return "noValue"
        case .apiDisabled: return "apiDisabled"
        case .invalidUIElement: return "invalidUIElement"
        case .notImplemented: return "notImplemented"
        default: return String(error.rawValue)
        }
    }

    private static func belongs(_ element: AXUIElement, to pid: pid_t) -> Bool {
        var owner: pid_t = 0
        return AXUIElementGetPid(element, &owner) == .success && owner == pid
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
