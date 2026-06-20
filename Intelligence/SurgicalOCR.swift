import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Phase 20D upgrade — drops the hardcoded `CGRect(0, 100, 1000, 800)` crop in
/// favour of the AXWebArea / AXScrollArea frame the browser exposes. When AX
/// gives no frame, the OCR is skipped cleanly (we log the reason) instead of
/// running against the wrong region.
public struct SurgicalOCR: Sendable {

    public struct OCRRegion: Sendable {
        public let text: String
        public let frame: CGRect
        public let confidence: Double
    }

    /// Try to derive a content-area crop rect via Accessibility for a known
    /// browser. Returns nil when the active app isn't a browser, when AX is
    /// not trusted, or when the relevant frame is unavailable.
    public static func contentRect(forApp appName: String) -> (rect: CGRect, source: String)? {
        guard let bc = BrowserContextExtractor.extract(appName: appName, activeAppPID: nil) else {
            return nil
        }
        if let f = bc.webAreaFrame { return (f, "ax_web_area") }
        if let f = bc.scrollAreaFrame { return (f, "ax_scroll_area") }
        return nil
    }

    /// Phase 20D entry point. Returns structured regions (frame + text +
    /// confidence) for the downstream judgment layer to consume. When AX has
    /// no frame for the current app, this function logs the reason and skips
    /// rather than running OCR against the wrong region.
    public static func extract(appName: String, windowTitle: String) async -> [OCRRegion] {
        guard let derived = contentRect(forApp: appName) else {
            print("[SurgicalOCR] skipped reason=no_ax_frame app=\(appName)")
            return []
        }
        guard let windowCapture = captureFrontBrowserWindow(appName: appName) else {
            print("[SurgicalOCR] skipped reason=window_capture_failed app=\(appName)")
            return []
        }

        let windowFrame = windowCapture.frame
        let contentScreen = refinedContentRect(screenRect: derived.rect, windowFrame: windowFrame, source: derived.source)
        let localRect = screenRectToImageRect(contentScreen, windowFrame: windowFrame, imageSize: CGSize(width: windowCapture.image.width, height: windowCapture.image.height))

        print("[SurgicalOCR] crop_source=\(derived.source)")
        print("[SurgicalOCR] window_frame=\(Int(windowFrame.origin.x)),\(Int(windowFrame.origin.y)),\(Int(windowFrame.size.width)),\(Int(windowFrame.size.height))")
        print("[SurgicalOCR] crop_rect=\(Int(localRect.origin.x)),\(Int(localRect.origin.y)),\(Int(localRect.size.width)),\(Int(localRect.size.height))")

        guard localRect.width >= 80, localRect.height >= 80,
              let cropped = windowCapture.image.cropping(to: localRect.integral) else {
            print("[SurgicalOCR] skipped reason=crop_failed")
            return []
        }

        let result = await OCRProcessor.shared.recognizeText(from: cropped)
        if result.text.isEmpty {
            return []
        }

        let qualityResult = ContentQualityModel.evaluate(text: result.text, frame: localRect, source: "surgical_ocr_\(derived.source)")
        print("[TargetedOCRDecision] type=\(qualityResult.type.rawValue) score=\(qualityResult.qualityScore) text_len=\(result.text.count)")

        if qualityResult.type == .unknown || qualityResult.type == .chrome || qualityResult.type == .nav || qualityResult.type == .ad {
            print("[SurgicalOCR] rejected reason=junk_content type=\(qualityResult.type.rawValue)")
            return []
        }

        return [OCRRegion(text: result.text, frame: localRect, confidence: Double(result.confidenceAverage ?? 0.0))]
    }

    // MARK: - Window capture + coordinate conversion

    private static func captureFrontBrowserWindow(appName: String) -> (image: CGImage, frame: CGRect)? {
        guard ScreenCaptureSource.isScreenRecordingAuthorized() else { return nil }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else { return nil }
        let pid = app.processIdentifier
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        struct Candidate { let id: CGWindowID; let bounds: CGRect; let area: CGFloat }
        let candidates: [Candidate] = raw.compactMap { dict in
            guard (dict[kCGWindowOwnerPID as String] as? Int) == Int(pid) else { return nil }
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0, dict[kCGWindowIsOnscreen as String] as? Bool ?? false else { return nil }
            guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] else { return nil }
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) ?? .zero
            guard bounds.width >= 240, bounds.height >= 180 else { return nil }
            let idInt = dict[kCGWindowNumber as String] as? Int ?? 0
            guard idInt > 0 else { return nil }
            return Candidate(id: CGWindowID(idInt), bounds: bounds, area: bounds.width * bounds.height)
        }
        guard let best = candidates.max(by: { $0.area < $1.area }) else { return nil }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, best.id, [.bestResolution]) else { return nil }
        print("[SurgicalOCR] window_capture mode=target_window id=\(best.id) size=\(image.width)x\(image.height)")
        return (image, best.bounds)
    }

    /// Trim bookmark bars / in-page chrome from the AX web area before OCR.
    private static func refinedContentRect(screenRect: CGRect, windowFrame: CGRect, source: String) -> CGRect {
        var rect = screenRect.intersection(windowFrame)
        guard rect.width > 80, rect.height > 80 else { return screenRect.intersection(windowFrame) }

        // Bookmark bars and favicon rows sit at the top of the web area — skip them.
        let topInset = min(160, max(72, rect.height * 0.12))
        rect.origin.y += topInset
        rect.size.height -= topInset

        // Ignore thin strips that are mostly browser UI chrome.
        if source == "ax_scroll_area", rect.height > windowFrame.height * 0.92 {
            let extraTop = min(80, windowFrame.height * 0.08)
            rect.origin.y += extraTop
            rect.size.height -= extraTop
        }

        return rect
    }

    /// Convert a screen-space rect into pixel coordinates for a window capture image.
    private static func screenRectToImageRect(_ screenRect: CGRect, windowFrame: CGRect, imageSize: CGSize) -> CGRect {
        let local = CGRect(
            x: screenRect.origin.x - windowFrame.origin.x,
            y: screenRect.origin.y - windowFrame.origin.y,
            width: screenRect.width,
            height: screenRect.height
        )
        guard windowFrame.width > 1, windowFrame.height > 1 else { return local }
        let scaleX = imageSize.width / windowFrame.width
        let scaleY = imageSize.height / windowFrame.height
        return CGRect(
            x: local.origin.x * scaleX,
            y: local.origin.y * scaleY,
            width: local.width * scaleX,
            height: local.height * scaleY
        )
    }
}

public enum ContentRegionType: String, Sendable, Equatable {
    case mainContent = "main_content"
    case chrome = "chrome"
    case nav = "nav"
    case ad = "ad"
    case unknown = "unknown"
}

public struct ContentRegion: Sendable, Equatable {
    public let text: String
    public let frame: CGRect?
    public let type: ContentRegionType
    public let qualityScore: Double
}

public struct ContentQualityResult: Sendable, Equatable {
    public let regions: [ContentRegion]
    public let usableChars: Int

    public var usableText: String {
        regions.filter { $0.type == .mainContent }.map { $0.text }.joined(separator: "\n")
    }
}

public enum ContentQualityModel {
    public static func evaluate(text: String, frame: CGRect? = nil, source: String) -> ContentRegion {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ContentRegion(text: text, frame: frame, type: .unknown, qualityScore: 0) }

        let lower = trimmed.lowercased()
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        // Bookmark / tab-strip dumps: many short lines, mostly URLs or single tokens.
        if lines.count >= 4 {
            let shortLines = lines.filter { $0.count <= 28 }.count
            let urlish = lines.filter { $0.contains("http") || $0.contains(".com") || $0.contains(".org") }.count
            if shortLines >= lines.count * 2 / 3 || urlish >= lines.count / 2 {
                return ContentRegion(text: text, frame: frame, type: .nav, qualityScore: 0.1)
            }
        }

        if trimmed.count < 25 && (source.contains("ocr") || source.contains("ax")) {
            if lower.contains("menu") || lower.contains("home") || lower.contains("search") || lower.contains("login") || lower.contains("bookmark") {
                return ContentRegion(text: text, frame: frame, type: .nav, qualityScore: 0.1)
            }
            return ContentRegion(text: text, frame: frame, type: .chrome, qualityScore: 0.2)
        }

        let words = trimmed.split(separator: " ")
        if words.count > 5 && Set(words).count < words.count / 3 {
            return ContentRegion(text: text, frame: frame, type: .ad, qualityScore: 0.1)
        }

        if lower.contains("sponsored") || lower.contains("advertisement") {
            return ContentRegion(text: text, frame: frame, type: .ad, qualityScore: 0.1)
        }

        // Icon-garbage OCR: lots of single-character "words".
        let singleCharTokens = words.filter { $0.count == 1 }.count
        if words.count >= 8, singleCharTokens >= words.count / 3 {
            return ContentRegion(text: text, frame: frame, type: .chrome, qualityScore: 0.15)
        }

        return ContentRegion(text: text, frame: frame, type: .mainContent, qualityScore: 0.9)
    }

    public static func evaluate(texts: [String], source: String) -> ContentQualityResult {
        let regions = texts.map { evaluate(text: $0, source: source) }
        let usable = regions.filter { $0.type == .mainContent }.reduce(0) { $0 + $1.text.count }

        let summaryTypeCounts = regions.reduce(into: [String: Int]()) { $0[$1.type.rawValue, default: 0] += 1 }
        let summary = summaryTypeCounts.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[ContentQualitySummary] source=\(source) regions=\(regions.count) usable_chars=\(usable) breakdown: \(summary)")

        return ContentQualityResult(regions: regions, usableChars: usable)
    }
}
