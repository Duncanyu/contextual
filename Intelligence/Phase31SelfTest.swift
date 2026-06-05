import Foundation
import AppKit

/// Phase 31 — Self-tests for debug infra, context acquisition, local actions, and execution snapshots.
///
/// Trigger: CONTEXTUAL_RUN_PHASE31_SELFTEST=1
@MainActor
enum Phase31SelfTest {

    static func run() async -> Bool {
        print("[Phase31SelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok { print("[Phase31SelfTest] pass case=\(name)") }
            else  { print("[Phase31SelfTest] fail case=\(name)"); failures.append(name) }
        }

        // ── 1. TickReasoning prints context and selected candidate ──
        do {
            let (avail, miss) = TickReasoningLedger.contextInventory(
                hasWindowTitle: true,
                hasBrowserURL: true,
                hasBrowserTabs: true,
                hasAXText: false,
                hasOCR: false,
                hasVisualDescriptor: false,
                hasSelectedText: false,
                hasClipboard: true
            )
            check("tick_reasoning_context_inventory_available",
                  avail.contains("title") && avail.contains("browser_url") && avail.contains("clipboard"))
            check("tick_reasoning_context_inventory_missing",
                  miss.contains("ax_text") && miss.contains("ocr") && miss.contains("selection"))

            // Emit should not crash
            TickReasoningLedger.emit(TickReasoningLedger.TickContext(
                tickId: "test01",
                activeApp: "Firefox",
                windowTitle: "182 Montreal - Google Docs",
                browserTitle: "182 Montreal - Google Docs",
                browserURL: "https://docs.google.com/document/d/abc",
                semanticDomain: "researching",
                workflow: "unknown",
                compartmentLabel: "182 Montreal",
                availableContext: avail,
                missingContext: miss,
                candidateFamilies: ["text", "friction"],
                familyWinners: ["text:synthesize_sources", "friction:arrange_side_by_side"],
                selected: "synthesize_sources",
                reason: "portfolio_winner"
            ))
            check("tick_reasoning_emit_no_crash", true)
        }

        // ── 2. ContextAcquisition requests OCR for Preview PDF title-only ──
        do {
            let plan = ContextAcquisitionPlanner.plan(
                capabilityId: "synthesize_sources",
                activeApp: "Preview",
                bundleId: "com.apple.Preview",
                hasAXText: false,
                hasOCR: false,
                hasVisualDescriptor: false,
                hasBrowserTabs: false,
                hasSelectedText: false,
                hasClipboard: false,
                groundedFactsCount: 0,
                evidenceQuality: "title_only"
            )
            check("context_acquisition_requests_ocr_for_preview_pdf",
                  plan.needed && plan.request == .requestOCR && plan.reason == "pdf_title_only")
            check("context_acquisition_ocr_budget_expensive",
                  plan.budget == .expensive)
            ContextAcquisitionPlanner.emit(plan)
        }

        // ── 3. ContextAcquisition skips when context is sufficient ──
        do {
            let plan = ContextAcquisitionPlanner.plan(
                capabilityId: "synthesize_sources",
                activeApp: "Firefox",
                bundleId: "org.mozilla.firefox",
                hasAXText: true,
                hasOCR: false,
                hasVisualDescriptor: false,
                hasBrowserTabs: true,
                hasSelectedText: true,
                hasClipboard: true,
                groundedFactsCount: 3,
                evidenceQuality: "selection"
            )
            check("context_acquisition_skips_when_sufficient",
                  !plan.needed && plan.request == .noMoreContextNeeded)
        }

        // ── 4. ContextAcquisition requests browser tabs for document action ──
        do {
            let plan = ContextAcquisitionPlanner.plan(
                capabilityId: "compare_rental_options",
                activeApp: "Firefox",
                bundleId: "org.mozilla.firefox",
                hasAXText: false,
                hasOCR: false,
                hasVisualDescriptor: false,
                hasBrowserTabs: false,
                hasSelectedText: false,
                hasClipboard: false,
                groundedFactsCount: 0,
                evidenceQuality: "title_only"
            )
            check("context_acquisition_requests_tabs_for_compare",
                  plan.needed && plan.request == .requestBrowserTabs)
        }

        // ── 5. ExecutionContextSnapshot builds and emits correctly ──
        do {
            let snapshot = ExecutionContextSnapshot.build(
                proposalId: "test-proposal-001",
                capabilityId: "arrange_side_by_side",
                activeApp: "Firefox",
                bundleId: "org.mozilla.firefox",
                windowTitle: "182 Montreal - Google Docs",
                browserSelectedTitle: "182 Montreal - Google Docs",
                browserSelectedURL: "https://docs.google.com/document/d/abc",
                browserTabTitles: ["Queen's Housing Rentals", "182 Montreal - Google Docs"],
                compartment: TaskCompartment(
                    workflow: .researching,
                    label: "182 Montreal",
                    dominantTerms: ["montreal"],
                    entities: [],
                    browserTabs: [],
                    confidence: 0.9
                ),
                evidenceQuality: "browser_context",
                hasOCR: false,
                hasAXText: false,
                hasSelectedText: false,
                targetApps: ["Preview", "Firefox"],
                targetURLs: []
            )
            check("execution_snapshot_preserved",
                  snapshot.capabilityId == "arrange_side_by_side"
                    && snapshot.browserSelectedURL == "https://docs.google.com/document/d/abc"
                    && snapshot.browserTabTitles.count == 2
                    && snapshot.targetApps.count == 2)
            check("execution_snapshot_age_near_zero",
                  snapshot.snapshotAge < 1.0)
            snapshot.emit()
            check("execution_snapshot_emit_no_crash", true)
        }

        // ── 6. LocalActionReadiness reports ──
        do {
            let report = LocalActionReadiness.check(
                capabilityId: "arrange_side_by_side",
                involvedApps: ["Preview", "Firefox"],
                involvedURLs: [],
                browserTabTitles: ["Queen's Housing", "Lease - Google Docs"]
            )
            // AXIsProcessTrusted may or may not be true in test env
            check("local_action_readiness_reports_targets",
                  !report.targetsFound.isEmpty)
            check("local_action_readiness_reason_not_empty",
                  !report.reason.isEmpty)
        }

        // ── 7. open_paired_app focuses running app ──
        do {
            // Use "Finder" which is always running
            let status = Phase31LocalActions.openPairedApp(appName: "Finder", reason: "selftest")
            check("open_paired_app_finder_succeeds", status == .success)
        }

        // ── 8. open_paired_app returns unavailable for fake app ──
        do {
            let status = Phase31LocalActions.openPairedApp(appName: "NonExistentApp12345", reason: "selftest")
            check("open_paired_app_fake_unavailable", status == .unavailable)
        }

        // ── 9. copy_current_url sets clipboard ──
        do {
            let status = Phase31LocalActions.copyCurrentURL(
                url: "https://housing.queensu.ca/rentals",
                title: "Queen's Housing Rentals"
            )
            check("copy_current_url_success", status == .success)
            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            check("copy_current_url_clipboard_has_url",
                  clipboard.contains("housing.queensu.ca"))
        }

        // ── 10. copy_all_related_links sets clipboard with markdown ──
        do {
            let status = Phase31LocalActions.copyAllRelatedLinks(
                urls: ["https://housing.queensu.ca", "https://docs.google.com/doc/abc"],
                titles: ["Queen's Housing", "Lease Agreement"]
            )
            check("copy_all_related_links_success", status == .success)
            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            check("copy_all_related_links_has_markdown",
                  clipboard.contains("Queen's Housing") && clipboard.contains("docs.google.com"))
        }

        // ── 11. copy_all_related_links falls back to titles when no URLs ──
        do {
            let status = Phase31LocalActions.copyAllRelatedLinks(
                urls: [],
                titles: ["Tab 1", "Tab 2"]
            )
            check("copy_all_related_links_titles_fallback", status == .success)
        }

        // ── 12. copy_current_url returns unavailable with no URL ──
        do {
            let status = Phase31LocalActions.copyCurrentURL(url: nil, title: nil)
            check("copy_current_url_no_url_unavailable", status == .unavailable)
        }

        // ── 13. AX text request returns result ──
        do {
            let result = OnDemandContextAcquisition.requestAXText(reason: "selftest")
            // In test environment, AX may or may not return content
            check("ax_text_request_no_crash", true)
            check("ax_text_request_has_source", result.source == "ax_text")
        }

        // ── 14. DogfoodChecklist prints when enabled ──
        do {
            // Just verify the function exists and doesn't crash
            DogfoodChecklist.printIfEnabled()
            check("dogfood_checklist_no_crash", true)
        }

        let ok = failures.isEmpty
        print("[Phase31SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
