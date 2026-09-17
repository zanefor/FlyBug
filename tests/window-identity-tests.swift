import AppKit
import ApplicationServices

@main
struct WindowIdentityTests {
    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        let pid: pid_t = 200
        let flyPID: pid_t = 900
        let axFrame = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let anchor = CGPoint(x: 350, y: 350)
        let decorated = CGRect(x: 94, y: 72, width: 1012, height: 734)
        func window(_ id: CGWindowID, frame: CGRect = CGRect(x: 94, y: 72, width: 1012, height: 734),
                    owner: pid_t = 200, layer: Int = 0, alpha: Double = 1) -> WindowIdentity.Candidate {
            .init(id: id, pid: owner, layer: layer, alpha: alpha, frame: frame)
        }
        func choose(_ windows: [WindowIdentity.Candidate], hit: Bool = true,
                    frame: CGRect = CGRect(x: 100, y: 100, width: 1000, height: 700),
                    point: CGPoint = CGPoint(x: 350, y: 350)) -> WindowIdentity.Match? {
            WindowIdentity.choose(pid: pid, frame: frame, anchor: point, windows: windows,
                                  focusedWindowHit: hit, ignoringPID: flyPID)
        }

        let exact = choose([window(1, frame: axFrame)], hit: false)
        expect(exact?.id == 1 && exact?.method == .exact, "Unique matching PID/layer/frame is an exact identity")
        expect(choose([window(9, frame: axFrame, owner: 400), window(1, frame: axFrame)], hit: false)?.id == 1,
               "An identical frame from a different process cannot be mistaken for the focused app")
        expect(choose([window(1, frame: axFrame, layer: 8)], hit: false) == nil,
               "A popup is not a normal exact window candidate")
        expect(choose([window(1, frame: axFrame), window(2, frame: axFrame)], hit: false) == nil,
               "Coincident same-app windows require more evidence")
        let coincident = choose([window(2, frame: axFrame), window(1, frame: axFrame)])
        expect(coincident?.id == 2 && coincident?.method == .hitTest,
               "AX-confirmed overlap follows front-to-back window order")

        let fallback = choose([window(3)])
        expect(fallback?.id == 3 && fallback?.frame == decorated && fallback?.method == .hitTest,
               "AX hit evidence allows decoration differences and returns actual CG bounds")
        expect(choose([window(3)], hit: false) == nil,
               "Even the sole geometrically nearby window is rejected without AX evidence")
        expect(choose([window(4), window(3)], hit: false) == nil,
               "A hit in another same-PID window cannot be replaced by nearest-window guessing")
        expect(choose([window(4, frame: CGRect(x: 200, y: 200, width: 600, height: 400)), window(3)])?.id == 4,
               "Once AX confirms the focused window, choose the foremost solid window at the anchor")

        expect(choose([window(8, owner: 400), window(3)]) == nil,
               "A foreign application covering the anchor blocks fallback")
        expect(choose([window(8, frame: CGRect(x: 1200, y: 100, width: 100, height: 100), owner: 400), window(3)])?.id == 3,
               "A foreground window away from the anchor does not obstruct it")
        expect(choose([window(8, layer: 8), window(3)]) == nil,
               "A same-app popup covering the anchor blocks fallback rather than being skipped")
        expect(choose([window(8, owner: flyPID, layer: 25), window(3)])?.id == 3,
               "Only FlyBug's own process is ignored for its overlay")
        expect(choose([window(8, owner: 400, alpha: 0.2), window(3)])?.id == 3,
               "A window at the transparent threshold does not block")
        expect(choose([window(8, owner: 400, alpha: 0.21), window(3)]) == nil,
               "A visible window just above the opacity threshold blocks")

        expect(choose([window(3)], point: CGPoint(x: 95, y: 350)) == nil,
               "Anchor must belong to the AX frame as well as the CG frame")
        expect(choose([window(3, frame: CGRect(x: 500, y: 100, width: 600, height: 700))]) == nil,
               "A CG window not containing the anchor is not an identity")
        expect(choose([window(3)], point: CGPoint(x: CGFloat.nan, y: 350)) == nil,
               "Invalid anchor cannot enter fallback")
        expect(choose([window(3)], frame: CGRect(x: 100, y: 100, width: 0, height: 700)) == nil,
               "Empty AX frame is invalid evidence")

        for shift in [CGPoint(x: -1600, y: 0), CGPoint(x: 0, y: -1000), CGPoint(x: -600, y: -400)] {
            let movedAX = axFrame.offsetBy(dx: shift.x, dy: shift.y)
            let movedCG = decorated.offsetBy(dx: shift.x, dy: shift.y)
            let movedPoint = CGPoint(x: anchor.x + shift.x, y: anchor.y + shift.y)
            let match = choose([window(3, frame: movedCG)], frame: movedAX, point: movedPoint)
            expect(match?.id == 3 && match?.frame == movedCG,
                   "Negative and cross-display coordinates stay in desktop points without flipping or scaling")
        }
        let fractional = CGRect(x: 100.5, y: 100.5, width: 1000.5, height: 700.5)
        expect(choose([window(1, frame: fractional)], hit: false)?.frame == fractional,
               "Fractional logical-point geometry is preserved")
        let beyondExact = CGRect(x: 102, y: 100, width: 1000, height: 700)
        expect(choose([window(1, frame: beyondExact)], hit: false) == nil,
               "Fallback must prove identity when the strict threshold is exceeded")

        func raw(_ id: UInt32, owner: Int) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: owner,
             kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0,
             kCGWindowBounds as String: decorated.dictionaryRepresentation]
        }
        let parsed = WindowIdentity.candidates(from: [raw(8, owner: 400), [:], raw(3, owner: Int(pid))])
        expect(parsed.map(\.id) == [8, 3], "CG metadata decoding retains front-to-back order")
        expect(parsed.last?.pid == pid && parsed.last?.frame == decorated,
               "CG metadata decodes native integer PIDs and actual bounds")

        let numbered = WindowIdentity.windowNumberMatch(pid: pid, frame: axFrame,
                                                        windows: [window(1, frame: axFrame), window(2, frame: axFrame)],
                                                        number: 2, ignoringPID: flyPID)
        expect(numbered?.id == 2 && numbered?.method == .windowNumber,
               "An explicit AX window number disambiguates otherwise identical window frames")
        expect(WindowIdentity.windowNumberMatch(pid: pid, frame: axFrame, windows: [window(2)],
                                               number: 2, ignoringPID: flyPID) == nil,
               "A window number cannot override conflicting frame evidence")
        expect(WindowIdentity.windowNumberMatch(pid: pid, frame: axFrame,
                                               windows: [window(2, frame: axFrame, owner: 400)],
                                               number: 2, ignoringPID: flyPID) == nil,
               "A window number cannot override conflicting process evidence")

        let primaryDisplay = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let desktop = window(17, frame: primaryDisplay, owner: 522, layer: 20)
        func ignoreDesktop(_ candidate: WindowIdentity.Candidate, bundle: String? = "com.apple.dock",
                           hit: Bool = true, displays: [CGRect] = [CGRect(x: 0, y: 0, width: 1512, height: 982)]) -> Bool {
            WindowIdentity.shouldIgnoreDesktopOverlay(candidate, ownerBundleID: bundle,
                                                      displayFrames: displays, systemHitMatches: hit)
        }
        expect(ignoreDesktop(desktop),
               "Confirmed system-wide hit through Dock's exact full-display layer permits filtering")
        expect(!ignoreDesktop(desktop, hit: false),
               "A hit in another PID or AX window leaves the full-display layer in place")
        expect(!ignoreDesktop(desktop, bundle: "com.apple.finder"),
               "A full-display layer from another application is never filtered")
        expect(!ignoreDesktop(desktop, bundle: nil),
               "Unknown runtime bundle identity cannot be inferred from a Dock-like name")
        let dockPopup = window(18, frame: CGRect(x: 250, y: 250, width: 300, height: 200), owner: 522, layer: 20)
        expect(!ignoreDesktop(dockPopup), "Ordinary Dock popups remain blockers even when layer 20")
        expect(!ignoreDesktop(window(19, frame: primaryDisplay, owner: 522, layer: 25)),
               "A fullscreen Dock surface at a different layer is not the proven desktop layer")
        expect(!ignoreDesktop(window(19, frame: primaryDisplay.offsetBy(dx: 0.1, dy: 0), owner: 522, layer: 20)),
               "Nearly full-display geometry is not treated as exact desktop evidence")
        expect(!ignoreDesktop(desktop, displays: []), "Unavailable display bounds prevent filtering")
        let secondaryDisplay = primaryDisplay.offsetBy(dx: -1512, dy: -300)
        expect(ignoreDesktop(window(20, frame: secondaryDisplay, owner: 522, layer: 20), displays: [secondaryDisplay]),
               "An actual secondary-display desktop layer retains global negative coordinates")
        expect(!ignoreDesktop(window(20, frame: CGRect(x: 0, y: 0, width: 3024, height: 982), owner: 522, layer: 20),
                              displays: [primaryDisplay, primaryDisplay.offsetBy(dx: 1512, dy: 0)]),
               "A combined surface spanning displays is not one exact display desktop layer")
        let filteredDesktop = [desktop, window(3)].filter { !ignoreDesktop($0, bundle: $0.pid == 522 ? "com.apple.dock" : "test.editor") }
        expect(choose(filteredDesktop)?.id == 3, "Removing the proven desktop surface unblocks the real focused window")
        let popupStillPresent = [desktop, dockPopup, window(3)].filter { !ignoreDesktop($0, bundle: $0.pid == 522 ? "com.apple.dock" : "test.editor") }
        expect(choose(popupStillPresent) == nil,
               "Filtering the desktop surface does not accidentally remove a Dock popup hiding the editor")
        let foreignStillPresent = [desktop, window(8, owner: 400), window(3)].filter { !ignoreDesktop($0, bundle: $0.pid == 522 ? "com.apple.dock" : "test.other") }
        expect(choose(foreignStillPresent) == nil,
               "Other application occluders remain effective after transparent desktop filtering")
        print("PASS: \(checks) window identity, occlusion, ambiguity, and display-coordinate checks")
    }
}
