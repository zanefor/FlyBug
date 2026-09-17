import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--render-fly"), CommandLine.arguments.count > index + 1 {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(calibratedRed: 0.956, green: 0.949, blue: 0.916, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 300)).fill()
    for (x, size, label): (CGFloat, CGFloat, String) in [(140, 28, "DESKTOP / 28 PX"), (430, 160, "DETAIL / ENLARGED")] {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by: x, yBy: 155); transform.concat()
        FlyArtwork.draw(size: size, heading: -0.3, phase: 0, flying: false)
        NSGraphicsContext.restoreGraphicsState()
        (label as NSString).draw(at: NSPoint(x: x - 78, y: 35), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.darkGray])
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    NativeChecks.run()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
