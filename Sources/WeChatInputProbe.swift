import AppKit
import Vision
import CoreGraphics

/// WeChat 4.x paints its composer in a custom surface and exposes only a
/// window-level AX node. This probe reads a narrow bottom composer strip only
/// after a real key/mouse event; it never OCRs the conversation area.
final class WeChatInputProbe {
    struct Finding { let issue: WritingIssue; let target: ScreenPoint? }
    private var busy = false
    private var lastRun: TimeInterval = -.infinity
    var onFindings: (([Finding]) -> Void)?

    func request() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !busy, now - lastRun > 0.65,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.tencent.xinWeChat" else { return }
        guard let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])?.first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }), let number = info[kCGWindowNumber as String] as? UInt32,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 300, frame.height > 200 else { return }
        busy = true; lastRun = now
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let findings = self?.scan(windowID: number, frame: frame) ?? []
            DispatchQueue.main.async { self?.busy = false; self?.onFindings?(findings) }
        }
    }

    private func scan(windowID: CGWindowID, frame: CGRect) -> [Finding] {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution, .boundsIgnoreFraming]) else { return [] }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let cropHeight = min(height, max(150, height * 0.28))
        let cropY = height - cropHeight
        let crop = CGRect(x: 0, y: cropY, width: width, height: cropHeight)
        guard let cgCrop = image.cropping(to: crop) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.minimumTextHeight = 0.012
        do { try VNImageRequestHandler(cgImage: cgCrop, options: [:]).perform([request]) } catch { return [] }
        let rows = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.45 else { return nil }
            return (candidate.string, observation.boundingBox)
        }.sorted { $0.1.midY > $1.1.midY }
        guard !rows.isEmpty else { return [] }
        let text = rows.map { $0.0 }.joined(separator: " ")
        var offsets: [NSRange] = []; var cursor = 0
        for row in rows { let length = (row.0 as NSString).length; offsets.append(NSRange(location: cursor, length: length)); cursor += length + 1 }
        var result: [Finding] = []
        let semaphore = DispatchSemaphore(value: 0)
        WritingEngine.check(text, language: "auto", checkSpelling: true) { issues in
            for issue in issues {
                guard let index = offsets.firstIndex(where: { NSIntersectionRange($0, issue.range).length > 0 }) else { continue }
                let box = rows[index].1
                let localX = box.midX * width
                let localTop = height - (cropY + box.maxY * cropHeight)
                let point = ScreenPoint(x: frame.minX + localX / width * frame.width,
                                        y: frame.minY + localTop / height * frame.height)
                result.append(Finding(issue: issue, target: point))
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 8)
        return result
    }
}
