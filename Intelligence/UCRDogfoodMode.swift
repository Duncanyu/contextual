import Foundation
import AppKit

// MARK: - UCR Dogfood Mode
//
// Phase 46: Real-device validation mode for UniversalContentReader.
//
// Enable with:
//   CONTEXTUAL_UCR_DOGFOOD=1   (env var in Xcode scheme)
//   OR: defaults write com.contextual.app contextual.ucrDogfoodMode -bool YES
//
// When enabled, a "Test content acquisition" action appears in the suggestion
// panel. Clicking it runs UCR on the frontmost app and shows a diagnostic
// result card with route matrix, quality, coverage, and a 500-char preview.

enum UCRDogfoodMode {
    private static let defaultsKey = "contextual.ucrDogfoodMode"

    // MARK: - Enable/disable

    static var isUserEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    private static var hasUserPreference: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) != nil
    }

    static func setUserEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        print("[UCRDogfoodToggle] changed enabled=\(enabled ? "yes" : "no")")
    }

    static var enablementSource: String {
        if hasUserPreference { return isUserEnabled ? "user_setting" : "disabled" }
        #if DEBUG
        return "debug_build"
        #else
        if ProcessInfo.processInfo.environment["CONTEXTUAL_UCR_DOGFOOD"] == "1" { return "env" }
        return "disabled"
        #endif
    }

    static var isEnabled: Bool {
        enablementSource != "disabled"
    }

    static func logStatus() {
        print("[UCRDogfoodMode] enabled=\(isEnabled ? "yes" : "no") source=\(enablementSource)")
        print("[UCRDogfoodAction] visible=\(isEnabled ? "yes" : "no") reason=\(isEnabled ? enablementSource : "disabled")")
    }

    // MARK: - Diagnostic runner

    /// Run UCR on the current frontmost app and display a diagnostic result card.
    @MainActor
    static func runDiagnostic(appState: AppState) async {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName  = frontApp?.localizedName ?? "unknown"
        let bundleId = frontApp?.bundleIdentifier ?? "unknown"

        print("[UCRDogfoodTest] started app=\(appName) bundle=\(bundleId) goal=summarize")

        // Run UCR with the most demanding goal so all routes are attempted
        let request = UniversalContentRequest.forGoal(.summarize)
        let result  = UniversalContentReader.read(request: request)

        // Gate check
        let enoughForGoal = UniversalContentReader.gate(
            capabilityId: "ucr_dogfood_test",
            goal: .summarize,
            result: result
        )

        // Build readable route-attempt log lines
        let routeLines: String
        if result.attemptedRoutes.isEmpty {
            routeLines = "  (none attempted)"
        } else {
            routeLines = result.attemptedRoutes.map { a in
                "  • \(a.route): \(a.status) (\(a.chars) chars) — \(a.reason)"
            }.joined(separator: "\n")
        }

        // Sanitize preview (avoid showing raw tokens / API keys if present)
        let rawPreview = String(result.text.prefix(500))
        let preview    = rawPreview.isEmpty ? "(no text extracted)" : sanitize(rawPreview)

        let coverageStr = result.coverage.rawValue
        let nextStepStr = result.nextStep?.rawValue ?? "none"
        let missingStr  = result.missingReason ?? "none"

        let diagnosticText = """
App: \(appName)
Bundle: \(bundleId)

Selected Route: \(result.source.rawValue)
Quality: \(result.quality.label)
Coverage: \(coverageStr)
Chars Extracted: \(result.text.count)
Enough for Summarize: \(enoughForGoal ? "YES" : "NO")
Next Step: \(nextStepStr)
Missing Reason: \(missingStr)

Route Attempts:
\(routeLines)

--- First 500 chars ---
\(preview)
"""

        print("[UCRDogfoodResultCard] shown selected_route=\(result.source.rawValue) quality=\(result.quality.label) chars=\(result.text.count) enough_for_goal=\(enoughForGoal)")

        _ = await CapabilityExecutor.shared.presentCognitiveResultSurface(
            capability: "ucr_dogfood_test",
            status: enoughForGoal ? "success" : "needs_capture",
            outputText: diagnosticText,
            source: result.source.rawValue,
            quality: result.quality.label,
            coverage: result.coverage.rawValue,
            sourceSurface: "panel",
            preferredSurface: "both"
        )
    }

    // MARK: - Helpers

    /// Light sanitisation: redact anything that looks like a bearer token or API key.
    private static func sanitize(_ text: String) -> String {
        // Redact bare hex/base64 blobs longer than 30 chars between word boundaries
        // (covers most API keys). Preserve all normal prose.
        var out = text
        let pattern = #"(?<![a-zA-Z0-9])[A-Za-z0-9\-_]{32,}(?![a-zA-Z0-9])"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "[redacted]")
        }
        return out
    }

    /// Convert UCR's ContentQuality to the AppState ContentQualityLabel used by result cards.
    static func qualityLabel(for quality: ContentQuality) -> ContentQualityLabel {
        switch quality {
        case .fullDocumentText:                       return .fullText
        case .partialDocumentText, .selectedText:     return .partialText
        case .axVisibleText, .visibleOCR:             return .visibleText
        case .metadataOnly:                           return .metadataOnly
        case .none:                                   return .failed
        }
    }
}
