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
        // The actual screen capture + Vision pass is owned by the existing OCR
        // path; we only expose the rectangle here. Returning an empty regions
        // array prevents any synthetic terms from leaking into downstream
        // judgment.
        print("[SurgicalOCR] regions=0 reason=crop_only_no_capture_in_phase20d_scope")
        return []
    }
}
