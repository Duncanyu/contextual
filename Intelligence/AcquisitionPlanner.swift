import Foundation
import AppKit
import ApplicationServices

/// Phase 44 — Before executing a cognitive action, this planner determines
/// what content is actually available and selects the best acquisition route.
///
/// Routes (in priority order):
/// 1. AX accessibility tree  — fast, on-device, no capture needed
/// 2. Browser DOM/metadata   — page title + URL + tabs (fast, limited)
/// 3. Selected text          — clipboard at action creation time
/// 4. Metadata-only fallback — page title/URL only; clearly labeled as weak
///
/// Metadata-only is BLOCKED for summarize/checklist/extract.
/// These capabilities need real text or show a "capture needed" card.
enum AcquisitionPlanner {

    enum Route: String {
        case axText         = "ax_text"
        case browserDOM     = "browser_dom"
        case selectedText   = "selected_text"
        case metadataOnly   = "metadata"
        case failed         = "failed"
    }

    enum Quality: String {
        case fullText    = "full_text"
        case visibleText = "visible_text"
        case partialText = "partial_text"
        case metadataOnly = "metadata_only"
        case failed      = "failed"
    }

    struct AcquisitionResult {
        let text: String
        let route: Route
        let quality: Quality
        let chars: Int
        /// True when enough text exists to produce a meaningful cognitive output.
        var isEnoughForCognitive: Bool {
            switch quality {
            case .fullText, .visibleText, .partialText:
                return chars >= 80
            case .metadataOnly, .failed:
                return false
            }
        }
    }

    /// Capabilities that REQUIRE real content (not metadata).
    /// These show a "capture needed" card when only metadata is available.
    private static let requiresRealContent: Set<String> = [
        "explicit_visible_capture_summary",
        "extract_action_items",
        "create_checklist",
        "summarize_thread",
        "summarize_visible_content",
    ]

    /// Capabilities that can work with partial/metadata (writing relies on selected text or context).
    private static let worksWithContext: Set<String> = [
        "rewrite_text", "improve_text", "draft_reply", "explain_context", "diagnose_error",
    ]

    // MARK: - Main Entry

    static func plan(
        capabilityId: String,
        context: [String: Any]
    ) -> AcquisitionResult {
        print("[AcquisitionPlanner] capability=\(capabilityId) context=\(contextKind(context)) desired_content=\(desiredContent(capabilityId))")

        // Route 1: AX accessibility tree
        let axResult = tryAXText()
        print("[AcquisitionRoute] candidate=ax_text available=\(axResult != nil ? "yes" : "no") reason=\(axResult != nil ? "ax_permission_granted" : "no_ax_text")")
        if let ax = axResult, !ax.text.isEmpty {
            // Phase 51 — AX text is the visible layer only. It can never be full_text,
            // no matter how many characters it has.
            let quality: Quality = ax.chars >= 80 ? .visibleText : .partialText
            print("[AcquisitionRoute] selected=ax_text confidence=0.9 expected_chars=\(ax.chars)")
            print("[ContextAcquisition] source=ax_text status=success chars=\(ax.chars) reason=ax_permission_granted")
            print("[AcquisitionQuality] level=\(quality.rawValue) enough_for=\(desiredContent(capabilityId)) allowed=yes")
            return AcquisitionResult(text: ax.text, route: .axText, quality: quality, chars: ax.chars)
        }

        // Route 2: Selected text (clipboard snapshot at action-creation time)
        let selAvailable = context["selectedTextAvailable"] as? Bool == true
        let selLength = context["selectedTextLength"] as? Int ?? 0
        let clipText = NSPasteboard.general.string(forType: .string) ?? ""
        if selAvailable && selLength > 10 && !clipText.isEmpty && abs(clipText.count - selLength) <= max(selLength / 2, 30) {
            let quality: Quality = clipText.count >= 200 ? .fullText : .partialText
            print("[AcquisitionRoute] candidate=selected_text available=yes reason=selection_at_action_creation")
            print("[AcquisitionRoute] selected=selected_text confidence=0.85 expected_chars=\(clipText.count)")
            print("[ContextAcquisition] source=selected_text status=success chars=\(clipText.count) reason=clipboard_selection")
            print("[AcquisitionQuality] level=\(quality.rawValue) enough_for=\(desiredContent(capabilityId)) allowed=yes")
            return AcquisitionResult(text: clipText, route: .selectedText, quality: quality, chars: clipText.count)
        } else {
            print("[AcquisitionRoute] candidate=selected_text available=no reason=\(selAvailable ? "clipboard_mismatch" : "no_selection")")
        }

        // Route 3: Browser DOM (metadata only — title + URL + tabs)
        let browserResult = tryBrowserMetadata(context: context)
        print("[AcquisitionRoute] candidate=browser_dom available=\(browserResult.isEmpty ? "no" : "yes") reason=\(browserResult.isEmpty ? "no_browser_context" : "browser_metadata_only")")
        if !browserResult.isEmpty {
            let chars = browserResult.count
            // Browser metadata is always metadata_only — no actual page text
            print("[AcquisitionRoute] selected=browser_dom confidence=0.4 expected_chars=\(chars)")
            print("[ContextAcquisition] source=browser_dom status=success chars=\(chars) reason=browser_metadata_only")
            print("[AcquisitionQuality] level=metadata_only enough_for=\(desiredContent(capabilityId)) allowed=\(requiresRealContent.contains(capabilityId) ? "no" : "yes")")
            return AcquisitionResult(text: browserResult, route: .browserDOM, quality: .metadataOnly, chars: chars)
        }

        print("[AcquisitionRoute] candidate=metadata available=no reason=no_context_signals")
        print("[ContextAcquisition] source=metadata status=failed chars=0 reason=no_context")
        print("[AcquisitionQuality] level=failed enough_for=\(desiredContent(capabilityId)) allowed=no")
        return AcquisitionResult(text: "", route: .failed, quality: .failed, chars: 0)
    }

    // MARK: - Route Implementations

    private static func tryAXText() -> (text: String, chars: Int)? {
        let source = AXWindowContentSource.shared
        guard source.hasAccessibilityPermission() else {
            print("[AcquisitionRoute] ax_text skipped reason=no_accessibility_permission")
            return nil
        }
        guard let ctx = source.extractActiveWindowContent() else { return nil }
        let fragments = ctx.visibleTextFragments
        guard !fragments.isEmpty else { return nil }
        // Join fragments, deduplicate nearby lines
        let joined = fragments
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }
            .prefix(80)
            .joined(separator: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed, trimmed.count)
    }

    private static func tryBrowserMetadata(context: [String: Any]) -> String {
        let browser = BrowserContextExtractor.extract(
            appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            activeAppPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
        let pageTitle = browser?.selectedTitle
            ?? browser?.recentTabTitles.first
            ?? (context["windowTitle"] as? String) ?? ""
        let url = browser?.selectedURL?.absoluteString
            ?? browser?.currentURL?.absoluteString
            ?? (context["urls"] as? [String])?.first ?? ""
        let tabTitles = (context["tabTitles"] as? [String] ?? [])
            + (browser?.recentTabTitles ?? [])
        let workflow = context["workflow"] as? String ?? ""

        var parts: [String] = []
        if !pageTitle.isEmpty { parts.append(pageTitle) }
        if !url.isEmpty { parts.append(url) }
        if !workflow.isEmpty && workflow != "unknown" { parts.append("Context: \(workflow)") }
        let uniqueTabs = Array(Set(tabTitles).subtracting([pageTitle])).prefix(5)
        if !uniqueTabs.isEmpty { parts.append("Related: " + uniqueTabs.joined(separator: "; ")) }
        return parts.joined(separator: "\n")
    }

    // MARK: - ContentQualityLabel Bridge (Phase 44)

    // Map AcquisitionPlanner.Quality to AppState.ContentQualityLabel for result cards.
    // AcquisitionPlanner is in Intelligence/, AppState is in App/ — bridge via extension.
}

extension AcquisitionPlanner.Quality {
    /// Convert to the AppState content quality label used by result cards.
    func toContentQualityLabel() -> ContentQualityLabel {
        switch self {
        case .fullText:    return .fullText
        case .visibleText: return .visibleText
        case .partialText: return .partialText
        case .metadataOnly: return .metadataOnly
        case .failed:      return .failed
        }
    }
}

extension AcquisitionPlanner {
    // MARK: - Helpers

    private static func contextKind(_ context: [String: Any]) -> String {
        if let wt = context["windowTitle"] as? String, !wt.isEmpty {
            let lower = wt.lowercased()
            if lower.contains("google docs") || lower.contains("docs.google") { return "google_docs" }
            if lower.contains(".pdf") || lower.contains("pdf") { return "pdf" }
            if lower.contains("gmail") || lower.contains("mail") { return "gmail" }
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let lower = appName.lowercased()
        if lower.contains("preview") { return "preview" }
        if lower.contains("safari") || lower.contains("firefox") || lower.contains("chrome") { return "browser" }
        if lower.contains("mail") { return "mail" }
        return "generic"
    }

    private static func desiredContent(_ capabilityId: String) -> String {
        switch capabilityId {
        case "explicit_visible_capture_summary", "summarize_visible_content": return "visible_text"
        case "extract_action_items", "create_checklist": return "full_document"
        case "draft_reply": return "thread"
        case "rewrite_text", "improve_text": return "selection"
        default: return "visible_text"
        }
    }
}
