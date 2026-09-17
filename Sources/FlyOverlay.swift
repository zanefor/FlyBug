import AppKit

private func flyColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

enum FlyArtwork {
    static func path(_ points: [NSPoint], width: CGFloat, color: NSColor) {
        guard let first = points.first else { return }
        let p = NSBezierPath(); p.move(to: first)
        for point in points.dropFirst() { p.line(to: point) }
        p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round
        color.setStroke(); p.stroke()
    }

    static func ellipse(_ rect: NSRect, colors: [NSColor], angle: CGFloat = 0) {
        let p = NSBezierPath(ovalIn: rect)
        NSGradient(colors: colors)?.draw(in: p, angle: angle)
    }

    static func drawWings(phase: CGFloat, flying: Bool) {
        for side in [-1.0, 1.0] {
            NSGraphicsContext.saveGraphicsState()
            let t = AffineTransform(scaleByX: CGFloat(side), byY: 1)
            (t as NSAffineTransform).concat()
            let rotation = NSAffineTransform()
            rotation.translateX(by: 9, yBy: 13)
            rotation.rotate(byDegrees: flying ? sin(phase * 3.7) * 18 - 10 : 3)
            rotation.translateX(by: -9, yBy: -13)
            rotation.concat()
            let wing = NSBezierPath()
            wing.move(to: NSPoint(x: 6, y: 17))
            wing.curve(to: NSPoint(x: 54, y: -36), controlPoint1: NSPoint(x: 26, y: 16), controlPoint2: NSPoint(x: 62, y: -18))
            wing.curve(to: NSPoint(x: 29, y: -48), controlPoint1: NSPoint(x: 55, y: -57), controlPoint2: NSPoint(x: 36, y: -60))
            wing.curve(to: NSPoint(x: 6, y: 17), controlPoint1: NSPoint(x: 17, y: -31), controlPoint2: NSPoint(x: 11, y: -4))
            NSGradient(colors: [flyColor(0.80, 0.86, 0.88, 0.48), flyColor(0.75, 0.82, 0.82, 0.17), flyColor(0.97, 0.93, 0.82, 0.40)])?.draw(in: wing, angle: 130)
            flyColor(0.19, 0.22, 0.20, 0.56).setStroke(); wing.lineWidth = 0.65; wing.stroke()
            let vein = flyColor(0.22, 0.27, 0.24, 0.48)
            path([.init(x: 8, y: 15), .init(x: 23, y: -5), .init(x: 48, y: -36)], width: 0.7, color: vein)
            path([.init(x: 9, y: 12), .init(x: 22, y: -17), .init(x: 33, y: -49)], width: 0.55, color: vein)
            path([.init(x: 16, y: 6), .init(x: 31, y: -2), .init(x: 52, y: -25)], width: 0.5, color: vein)
            path([.init(x: 23, y: -5), .init(x: 24, y: -22), .init(x: 46, y: -44)], width: 0.5, color: vein)
            path([.init(x: 24, y: -22), .init(x: 36, y: -22), .init(x: 42, y: -32)], width: 0.45, color: vein)
            path([.init(x: 18, y: -9), .init(x: 20, y: -26), .init(x: 29, y: -40)], width: 0.45, color: vein)
            // A faint secondary wing impression gives a fast, translucent wing beat.
            if flying {
                let blur = NSAffineTransform(); blur.rotate(byDegrees: 12); blur.concat()
                flyColor(0.62, 0.69, 0.68, 0.12).setFill(); wing.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static let body: NSImage = {
        let image = NSImage(size: NSSize(width: 220, height: 220))
        image.lockFocus()
        let t = NSAffineTransform(); t.translateX(by: 110, yBy: 110); t.scale(by: 1.8); t.concat()
        drawBody()
        image.unlockFocus()
        return image
    }()

    static func drawBody() {
        let dark = flyColor(0.07, 0.08, 0.07)
        for side: CGFloat in [-1, 1] {
            let legs: [[NSPoint]] = [
                [.init(x: side * 9, y: 17), .init(x: side * 22, y: 33), .init(x: side * 25, y: 51), .init(x: side * 35, y: 57)],
                [.init(x: side * 12, y: 5), .init(x: side * 28, y: 9), .init(x: side * 45, y: -3), .init(x: side * 54, y: 1)],
                [.init(x: side * 10, y: -5), .init(x: side * 22, y: -22), .init(x: side * 25, y: -47), .init(x: side * 37, y: -57)]
            ]
            for leg in legs {
                path(Array(leg.prefix(2)), width: 2.8, color: dark)
                path(Array(leg.dropFirst()), width: 1.35, color: dark)
                path([leg.last!, .init(x: leg.last!.x + side * 4, y: leg.last!.y + 2)], width: 0.65, color: dark)
                for i in 1...6 {
                    let f = CGFloat(i) / 7
                    let p = NSPoint(x: leg[1].x + (leg[2].x - leg[1].x) * f, y: leg[1].y + (leg[2].y - leg[1].y) * f)
                    path([p, .init(x: p.x + side * 3.4, y: p.y + 1.7)], width: 0.42, color: dark)
                }
            }
        }
        ellipse(NSRect(x: -12, y: -38, width: 24, height: 41), colors: [dark, flyColor(0.30, 0.32, 0.24), dark], angle: 12)
        let abdomen = NSBezierPath(ovalIn: NSRect(x: -12, y: -38, width: 24, height: 41))
        NSGraphicsContext.saveGraphicsState(); abdomen.addClip()
        for i in 0...5 {
            let y = CGFloat(i) * 6 - 33
            let p = NSBezierPath(); p.move(to: NSPoint(x: -13, y: y))
            p.curve(to: NSPoint(x: 13, y: y), controlPoint1: NSPoint(x: -5, y: y - 4), controlPoint2: NSPoint(x: 5, y: y - 4))
            p.lineWidth = 1.7; flyColor(0.05, 0.06, 0.04, 0.75).setStroke(); p.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        ellipse(NSRect(x: -15, y: -7, width: 30, height: 39), colors: [dark, flyColor(0.42, 0.45, 0.39), flyColor(0.16, 0.18, 0.16), dark], angle: -12)
        let thorax = NSBezierPath(ovalIn: NSRect(x: -15, y: -7, width: 30, height: 39))
        NSGraphicsContext.saveGraphicsState(); thorax.addClip()
        for x: CGFloat in [-9, -3, 3, 9] {
            path([.init(x: x, y: 29), .init(x: x * 0.85, y: 15), .init(x: x * 0.65, y: 2)], width: 2.3, color: flyColor(0.08, 0.10, 0.08, 0.88))
        }
        for i in 0..<110 {
            let x = CGFloat(sin(Double(i) * 17.13)) * 14
            let y = CGFloat(cos(Double(i) * 7.71)) * 20 + 13
            path([.init(x: x, y: y), .init(x: x + 0.6, y: y + 1.4)], width: 0.35, color: flyColor(0.76, 0.77, 0.62, 0.34))
        }
        NSGraphicsContext.restoreGraphicsState()
        // Short bristles along the thorax and abdomen silhouette.
        for i in 0..<44 {
            let a = CGFloat(i) * .pi * 2 / 44
            let r: CGFloat = i % 3 == 0 ? 4.3 : 2.5
            let p = NSPoint(x: sin(a) * 13, y: cos(a) * 19 + 12)
            path([p, .init(x: p.x + sin(a) * r, y: p.y + cos(a) * r)], width: 0.48, color: dark)
        }
        ellipse(NSRect(x: -13, y: 28, width: 26, height: 18), colors: [dark, flyColor(0.27, 0.29, 0.23), dark], angle: 25)
        for side: CGFloat in [-1, 1] {
            let eye = NSRect(x: side < 0 ? -14 : 4, y: 30, width: 10, height: 15)
            ellipse(eye, colors: [flyColor(0.13, 0.055, 0.035), flyColor(0.47, 0.20, 0.11), flyColor(0.20, 0.065, 0.035)], angle: 35)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(ovalIn: eye).addClip()
            for row in 0...10 {
                for col in 0...7 {
                    let dot = NSRect(x: eye.minX + CGFloat(col) * 1.6 + CGFloat(row % 2) * 0.8,
                                     y: eye.minY + CGFloat(row) * 1.55, width: 0.65, height: 0.65)
                    flyColor(0.07, 0.03, 0.02, 0.56).setFill(); NSBezierPath(ovalIn: dot).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            path([.init(x: side * 3, y: 43), .init(x: side * 5, y: 49), .init(x: side * 10, y: 51)], width: 1.3, color: dark)
        }
    }

    static func draw(size: CGFloat, heading: CGFloat, phase: CGFloat, flying: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform(); t.rotate(byRadians: heading); t.scale(by: size / 100); t.concat()
        drawWings(phase: phase, flying: flying)
        body.draw(in: NSRect(x: -61.11, y: -61.11, width: 122.22, height: 122.22), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 256, height: 256))
        image.lockFocus()
        let bg = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 248, height: 248), xRadius: 55, yRadius: 55)
        flyColor(0.88, 0.95, 0.33).setFill(); bg.fill()
        let t = NSAffineTransform(); t.translateX(by: 128, yBy: 128); t.concat()
        draw(size: 180, heading: -0.4, phase: 0, flying: false)
        image.unlockFocus()
        return image
    }
}

final class FlyView: NSView {
    var flySize: CGFloat = 28
    var heading: CGFloat = 0
    var phase: CGFloat = 0
    var flying = true
    var hunting = false
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform(); t.translateX(by: bounds.midX, yBy: bounds.midY); t.concat()
        if hunting {
            let mark = NSBezierPath(ovalIn: NSRect(x: -3, y: -flySize * 0.60 - 9, width: 6, height: 6))
            flyColor(0.85, 0.31, 0.12, 0.9).setFill(); mark.fill()
        }
        FlyArtwork.draw(size: flySize, heading: heading, phase: phase, flying: flying)
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class FlyOverlay {
    private let window: NSPanel
    private let view: FlyView
    private var timer: Timer?
    private var position = NSPoint(x: 400, y: 400)
    private var destination = NSPoint(x: 600, y: 500)
    private var velocity = NSPoint.zero
    private var target: NSPoint?
    private var nextWander: TimeInterval = 0
    private var lastFrame: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var phase: CGFloat = 0
    var running = true { didSet { updateVisibility() } }
    var idleFlight = true { didSet { updateVisibility() } }
    var speed: Double = 1
    var opacity: Double = 1 { didSet { window.alphaValue = opacity } }
    var size: Double = 28 { didSet { view.flySize = size } }

    /// Both points use the top-left display coordinate system used by diagnostics.
    /// Read only on the main thread, alongside the animation timer.
    var healthCoordinates: (position: ScreenPoint, target: ScreenPoint?) {
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        func converted(_ point: NSPoint) -> ScreenPoint {
            ScreenPoint(x: point.x, y: screenTop - point.y)
        }
        return (converted(position), target.map(converted))
    }

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 190, height: 190), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = FlyView(frame: NSRect(x: 0, y: 0, width: 190, height: 190))
        window.contentView = view
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.sharingType = .none
        if let screen = NSScreen.main { position = NSPoint(x: screen.visibleFrame.midX + 250, y: screen.visibleFrame.midY) }
        chooseDestination()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        updateVisibility()
    }

    func setTarget(_ point: ScreenPoint?) {
        guard let point else { target = nil; view.hunting = false; updateVisibility(); return }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let converted = NSPoint(x: point.x, y: screenTop - point.y)
        guard NSScreen.screens.contains(where: { $0.frame.contains(converted) }) else { setTarget(nil); return }
        target = converted
        view.hunting = true
        updateVisibility()
    }

    func stop() { timer?.invalidate(); timer = nil; window.orderOut(nil) }

    private func updateVisibility() {
        if running && (idleFlight || target != nil) { window.orderFrontRegardless() }
        else { window.orderOut(nil) }
    }

    private func chooseDestination() {
        let screens = NSScreen.screens
        guard let screen = screens.randomElement() else { return }
        let rect = screen.visibleFrame.insetBy(dx: 60, dy: 60)
        destination = NSPoint(x: CGFloat.random(in: rect.minX...max(rect.minX, rect.maxX)), y: CGFloat.random(in: rect.minY...max(rect.minY, rect.maxY)))
        nextWander = ProcessInfo.processInfo.systemUptime + Double.random(in: 1.3...3.4) / speed
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(0.04, max(0.001, now - lastFrame))); lastFrame = now
        guard running && (idleFlight || target != nil) else { return }
        if let target, !NSScreen.screens.contains(where: { $0.frame.contains(target) }) { setTarget(nil) }
        if target == nil && now > nextWander { chooseDestination() }
        // Disconnecting a monitor must not strand the fly off screen.
        if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -110, dy: -110).contains(position) }), let screen = NSScreen.main {
            position = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        }
        let goal = target ?? destination
        let dx = goal.x - position.x, dy = goal.y - position.y
        let distance = hypot(dx, dy)
        phase += dt * 24
        let landing = target != nil && distance < 8
        if landing {
            velocity.x *= 0.65; velocity.y *= 0.65
            position.x += dx * min(1, dt * 8)
            position.y += dy * min(1, dt * 8)
        } else {
            let maxSpeed = CGFloat(260 * speed)
            let pace = min(maxSpeed, distance * (target == nil ? 1.5 : 3.5))
            let jitter: CGFloat = target == nil ? 55 : min(distance * 0.14, 24)
            let vx = dx / max(distance, 1) * pace + sin(phase * 0.73) * jitter
            let vy = dy / max(distance, 1) * pace + cos(phase * 1.13) * jitter
            let smoothing = min(1, dt * 6)
            velocity.x += (vx - velocity.x) * smoothing
            velocity.y += (vy - velocity.y) * smoothing
            position.x += velocity.x * dt; position.y += velocity.y * dt
            let angle = atan2(velocity.y, velocity.x) - .pi / 2
            var delta = angle - view.heading
            while delta > .pi { delta -= .pi * 2 }
            while delta < -.pi { delta += .pi * 2 }
            view.heading += delta * min(1, dt * 9)
        }
        view.flying = !landing; view.phase = phase
        window.setFrameOrigin(NSPoint(x: position.x - 95, y: position.y - 95))
        view.needsDisplay = true
    }
}
