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
    ///
    /// NOTE: this is a thin coordinator. Actual `VNRecognizeTextRequest`
    /// invocation lives in the existing OCR pipeline — this function reports
    /// *which crop would be used* and produces no synthetic terms.
    public static func extract(appName: String, windowTitle: String) async -> [OCRRegion] {
        guard let derived = contentRect(forApp: appName) else {
            print("[SurgicalOCR] skipped reason=no_ax_frame app=\(appName)")
            return []
        }
        let rect = derived.rect
        print("[SurgicalOCR] crop_source=\(derived.source)")
        print("[SurgicalOCR] crop_rect=\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.size.width)),\(Int(rect.size.height))")
        guard let screenFrame = ScreenCaptureSource.captureSingleFrame() else {
            print("[SurgicalOCR] skipped reason=capture_failed")
            return []
        }
        
        guard let cropped = screenFrame.image.cropping(to: rect) else {
            print("[SurgicalOCR] skipped reason=crop_failed")
            return []
        }
        
        let result = await OCRProcessor.shared.recognizeText(from: cropped)
        if result.text.isEmpty {
            return []
        }
        
        let qualityResult = ContentQualityModel.evaluate(text: result.text, frame: rect, source: "surgical_ocr_\(derived.source)")
        print("[TargetedOCRDecision] type=\(qualityResult.type.rawValue) score=\(qualityResult.qualityScore) text_len=\(result.text.count)")
        
        if qualityResult.type == .unknown || qualityResult.type == .chrome || qualityResult.type == .ad {
            print("[SurgicalOCR] rejected reason=junk_content type=\(qualityResult.type.rawValue)")
            return []
        }
        
        return [OCRRegion(text: result.text, frame: rect, confidence: Double(result.confidenceAverage ?? 0.0))]
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
        
        // Simple heuristics for junk vs content
        if trimmed.count < 25 && (source.contains("ocr") || source.contains("ax")) {
            // Short bursts are often nav or chrome
            if lower.contains("menu") || lower.contains("home") || lower.contains("search") || lower.contains("login") {
                return ContentRegion(text: text, frame: frame, type: .nav, qualityScore: 0.1)
            }
            return ContentRegion(text: text, frame: frame, type: .chrome, qualityScore: 0.2)
        }
        
        // If it's very repetitive or looks like a list of links
        let words = trimmed.split(separator: " ")
        if words.count > 5 && Set(words).count < words.count / 3 {
            return ContentRegion(text: text, frame: frame, type: .ad, qualityScore: 0.1)
        }
        
        if lower.contains("sponsored") || lower.contains("advertisement") {
            return ContentRegion(text: text, frame: frame, type: .ad, qualityScore: 0.1)
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
