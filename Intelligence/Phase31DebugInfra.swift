import Foundation
import AppKit

// MARK: - Part 1: Tick Reasoning Ledger

/// Phase 31 — Compact one-line-per-tick reasoning ledger.
/// Answers: what did the assistant think, what did it have, what was it missing, what did it pick.
enum TickReasoningLedger {
    public static var lastTickBrowserURL: String? = nil

    struct TickContext {
        let tickId: String
        let activeApp: String
        let windowTitle: String
        let browserTitle: String?
        let browserURL: String?
        let semanticDomain: String
        let workflow: String
        let compartmentLabel: String?
        let availableContext: [String]
        let missingContext: [String]
        let candidateFamilies: [String]
        let familyWinners: [String]
        let selected: String?
        let reason: String
    }

    static func emit(_ ctx: TickContext) {
        lastTickBrowserURL = ctx.browserURL
        let available = ctx.availableContext.joined(separator: ",")
        let missing = ctx.missingContext.joined(separator: ",")
        let families = ctx.candidateFamilies.joined(separator: ",")
        let winners = ctx.familyWinners.joined(separator: ",")
        print("[TickReasoning]"
            + " tick_id=\(ctx.tickId)"
            + " active_app=\(ctx.activeApp)"
            + " window_title=\(String(ctx.windowTitle.prefix(40)))"
            + " browser_title=\(ctx.browserTitle.map { String($0.prefix(40)) } ?? "none")"
            + " browser_url=\(ctx.browserURL.map { String($0.prefix(60)) } ?? "none")"
            + " semantic_domain=\(ctx.semanticDomain)"
            + " workflow=\(ctx.workflow)"
            + " compartment=\(ctx.compartmentLabel ?? "none")"
            + " available_context=\(available.isEmpty ? "none" : available)"
            + " missing_context=\(missing.isEmpty ? "none" : missing)"
            + " candidate_families=\(families.isEmpty ? "none" : families)"
            + " family_winners=\(winners.isEmpty ? "none" : winners)"
            + " selected=\(ctx.selected ?? "none")"
            + " reason=\(ctx.reason)")
    }

    /// Build available/missing context lists from current state.
    static func contextInventory(
        hasWindowTitle: Bool,
        hasBrowserURL: Bool,
        hasBrowserTabs: Bool,
        hasAXText: Bool,
        hasOCR: Bool,
        hasVisualDescriptor: Bool,
        hasSelectedText: Bool,
        hasClipboard: Bool
    ) -> (available: [String], missing: [String]) {
        var available: [String] = []
        var missing: [String] = []

        func check(_ name: String, _ has: Bool) {
            if has { available.append(name) } else { missing.append(name) }
        }
        check("title", hasWindowTitle)
        check("browser_url", hasBrowserURL)
        check("browser_tabs", hasBrowserTabs)
        check("ax_text", hasAXText)
        check("ocr", hasOCR)
        check("visual", hasVisualDescriptor)
        check("selection", hasSelectedText)
        check("clipboard", hasClipboard)
        return (available, missing)
    }
}

// MARK: - Part 2: Context Acquisition Planner

/// Phase 31 — Decides what additional context to gather before executing.
/// Lightweight and deterministic. No model calls.
enum ContextAcquisitionPlanner {

    enum AcquisitionRequest: String, Sendable {
        case useTitleOnly = "use_title_only"
        case requestAXText = "request_ax_text"
        case requestOCR = "request_ocr"
        case requestVisualDescriptor = "request_visual_descriptor"
        case requestBrowserTabs = "request_browser_tabs"
        case requestSelectedText = "request_selected_text"
        case requestClipboardIfRecent = "request_clipboard_if_recent"
        case noMoreContextNeeded = "no_more_context_needed"
    }

    enum Budget: String, Sendable {
        case cheap
        case expensive
    }

    struct AcquisitionPlan: Sendable {
        let needed: Bool
        let reason: String
        let request: AcquisitionRequest
        let budget: Budget
    }

    static func plan(
        capabilityId: String,
        activeApp: String,
        bundleId: String,
        hasAXText: Bool,
        hasOCR: Bool,
        hasVisualDescriptor: Bool,
        hasBrowserTabs: Bool,
        hasSelectedText: Bool,
        hasClipboard: Bool,
        groundedFactsCount: Int,
        evidenceQuality: String
    ) -> AcquisitionPlan {
        let isPDF = bundleId == "com.apple.Preview"
            || activeApp.lowercased() == "preview"
            || activeApp.lowercased().contains("pdf")
        let isImage = activeApp.lowercased().contains("photos")
            || activeApp.lowercased().contains("pixelmator")
        let isDocumentAction = ["synthesize_sources", "compare_options", "compare_rental_options",
                                 "summarize_reference", "create_questions_to_ask_landlord",
                                 "draft_listing_ad", "create_listing_checklist"].contains(capabilityId)

        // Rule 1: PDF/Preview with title-only → request OCR
        if isPDF && !hasAXText && !hasOCR && evidenceQuality == "title_only" {
            return AcquisitionPlan(needed: true, reason: "pdf_title_only", request: .requestOCR, budget: .expensive)
        }

        // Rule 2: Image viewer with title-only → request visual descriptor
        if isImage && !hasVisualDescriptor && evidenceQuality == "title_only" {
            return AcquisitionPlan(needed: true, reason: "image_title_only", request: .requestVisualDescriptor, budget: .expensive)
        }

        // Rule 3: Document comparison but only one source known → request browser tabs
        if isDocumentAction && !hasBrowserTabs {
            return AcquisitionPlan(needed: true, reason: "document_action_no_tabs", request: .requestBrowserTabs, budget: .cheap)
        }

        // Rule 4: Browser context but no URL metadata → request browser tabs
        if evidenceQuality == "browser_context" && !hasBrowserTabs {
            return AcquisitionPlan(needed: true, reason: "browser_context_no_tabs", request: .requestBrowserTabs, budget: .cheap)
        }

        // Rule 5: Text execution with grounded_facts=0 and no AX → request AX
        if isDocumentAction && groundedFactsCount == 0 && !hasAXText {
            return AcquisitionPlan(needed: true, reason: "text_action_no_grounded_facts", request: .requestAXText, budget: .cheap)
        }

        // Rule 6: Preview/PDF stable for text action → request AX
        if isPDF && isDocumentAction && !hasAXText {
            return AcquisitionPlan(needed: true, reason: "pdf_document_action_no_ax", request: .requestAXText, budget: .cheap)
        }

        return AcquisitionPlan(needed: false, reason: "sufficient_context", request: .noMoreContextNeeded, budget: .cheap)
    }

    static func emit(_ plan: AcquisitionPlan) {
        print("[ContextAcquisition]"
            + " needed=\(plan.needed ? "yes" : "no")"
            + " reason=\(plan.reason)"
            + " requested=\(plan.request.rawValue)"
            + " budget=\(plan.budget.rawValue)")
    }
}

// MARK: - Part 3: Safe OCR / Visual On-Demand

/// Phase 31 — On-demand context acquisition for OCR and visual.
/// Does NOT enable always-on OCR. Only fires when a specific action needs document context.
enum OnDemandContextAcquisition {

    struct AcquisitionResult: Sendable {
        let source: String  // "ocr", "ax_text", "visual_descriptor", "browser_tabs"
        let success: Bool
        let chars: Int
        let reason: String
        let content: String?
    }

    /// Request OCR for a specific reason. Returns result with content if available.
    static func requestOCR(reason: String, appName: String, windowTitle: String) async -> AcquisitionResult {
        print("[OCRRequest] reason=\(reason)")
        let cap = ContextCapabilityRegistry.shared.capability(for: .screenOCR)
        guard cap?.isAvailable == true else {
            print("[ContextAcquisition] skipped reason=ocr_unavailable")
            return AcquisitionResult(source: "ocr", success: false, chars: 0, reason: "ocr_unavailable", content: nil)
        }
        let regions = await SurgicalOCR.extract(appName: appName, windowTitle: windowTitle)
        let combined = regions.map(\.text).joined(separator: "\n")
        let chars = combined.count
        print("[OCRResult] chars=\(chars)")
        if !combined.isEmpty {
            return AcquisitionResult(source: "ocr", success: true, chars: chars, reason: reason, content: String(combined.prefix(2000)))
        }
        return AcquisitionResult(source: "ocr", success: false, chars: 0, reason: "ocr_returned_empty", content: nil)
    }

    /// Request AX text extraction for current window.
    static func requestAXText(reason: String) -> AcquisitionResult {
        let ax = AXWindowContentSource.shared.extractActiveWindowContent()
        let fragments = ax?.visibleTextFragments ?? []
        let combined = fragments.joined(separator: "\n")
        let chars = combined.count
        if chars > 0 {
            print("[AXTextResult] chars=\(chars) reason=\(reason)")
            return AcquisitionResult(source: "ax_text", success: true, chars: chars, reason: reason, content: String(combined.prefix(2000)))
        }
        print("[AXTextResult] chars=0 reason=\(reason)")
        return AcquisitionResult(source: "ax_text", success: false, chars: 0, reason: "ax_returned_empty", content: nil)
    }

    /// Request visual descriptor for current window.
    static func requestVisualDescriptor(reason: String) -> AcquisitionResult {
        print("[VisualGrounding] requested=yes reason=\(reason)")
        let cap = ContextCapabilityRegistry.shared.capability(for: .visualDescriptor)
        guard cap?.isAvailable == true else {
            print("[ContextAcquisition] skipped reason=visual_descriptor_unavailable")
            return AcquisitionResult(source: "visual_descriptor", success: false, chars: 0, reason: "visual_descriptor_unavailable", content: nil)
        }
        // In v1, visual descriptor is expensive and needs model. Return placeholder.
        return AcquisitionResult(source: "visual_descriptor", success: false, chars: 0, reason: "visual_descriptor_not_wired_yet", content: nil)
    }
}

// MARK: - Part 4: Execution Context Snapshot

/// Phase 31 — Snapshot of context at proposal creation time.
/// Preserved on the proposal so execution uses the right context even if focus changed.
public struct ExecutionContextSnapshot: Sendable, Codable, Equatable {
    public let proposalId: String
    public let capabilityId: String
    public let createdAt: Date
    public let activeApp: String
    public let bundleId: String
    public let windowTitle: String
    public let browserSelectedTitle: String?
    public let browserSelectedURL: String?
    public let browserTabTitles: [String]
    public let compartmentLabel: String?
    public let compartmentWorkflow: String?
    public let evidenceQuality: String
    public let hasOCR: Bool
    public let hasAXText: Bool
    public let hasSelectedText: Bool
    public let targetApps: [String]
    public let targetURLs: [String]

    public var snapshotAge: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }

    public func emit() {
        print("[ExecutionContextSnapshot]"
            + " proposal_id=\(proposalId)"
            + " capability=\(capabilityId)"
            + " snapshot_age=\(String(format: "%.0f", snapshotAge))s"
            + " contains_browser_url=\(browserSelectedURL != nil ? "yes" : "no")"
            + " contains_ocr=\(hasOCR ? "yes" : "no")"
            + " contains_targets=\(!targetApps.isEmpty ? "yes" : "no")")
    }

    public static func build(
        proposalId: String,
        capabilityId: String,
        activeApp: String,
        bundleId: String,
        windowTitle: String,
        browserSelectedTitle: String?,
        browserSelectedURL: String?,
        browserTabTitles: [String],
        compartment: TaskCompartment?,
        evidenceQuality: String,
        hasOCR: Bool,
        hasAXText: Bool,
        hasSelectedText: Bool,
        targetApps: [String],
        targetURLs: [String]
    ) -> ExecutionContextSnapshot {
        ExecutionContextSnapshot(
            proposalId: proposalId,
            capabilityId: capabilityId,
            createdAt: Date(),
            activeApp: activeApp,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserSelectedTitle: browserSelectedTitle,
            browserSelectedURL: browserSelectedURL,
            browserTabTitles: browserTabTitles,
            compartmentLabel: compartment?.label,
            compartmentWorkflow: compartment?.workflow.rawValue,
            evidenceQuality: evidenceQuality,
            hasOCR: hasOCR,
            hasAXText: hasAXText,
            hasSelectedText: hasSelectedText,
            targetApps: targetApps,
            targetURLs: targetURLs
        )
    }
}

// MARK: - Part 6: Local Action Readiness

/// Phase 31 — Reports whether a local action can actually execute before showing it.
enum LocalActionReadiness {

    struct ReadinessReport: Sendable {
        let capabilityId: String
        let targetsFound: [String]
        let missingTargets: [String]
        let accessibilityPermission: Bool
        let canExecute: Bool
        let reason: String
    }

    static func check(
        capabilityId: String,
        involvedApps: [String],
        involvedURLs: [String],
        browserTabTitles: [String]
    ) -> ReadinessReport {
        var found: [String] = []
        var missing: [String] = []

        for app in involvedApps {
            if NSWorkspace.shared.runningApplications.contains(where: {
                $0.localizedName?.lowercased() == app.lowercased()
            }) {
                found.append(app)
            } else {
                missing.append(app)
            }
        }

        // Browser tabs are always "found" if we know about them
        for tab in browserTabTitles.prefix(4) {
            found.append("tab:\(String(tab.prefix(30)))")
        }

        let axAvailable = AXIsProcessTrusted()
        let canExecute: Bool
        let reason: String

        switch capabilityId {
        case "arrange_side_by_side":
            let verifiedPair = ArrangeVerifiedWorkPairGate.evaluate(involvedApps: involvedApps)
            canExecute = axAvailable && verifiedPair.verified
            reason = !axAvailable ? "accessibility_not_granted" : (verifiedPair.verified ? "ready" : "no_verified_work_pair")
        case "split_research_setup":
            canExecute = axAvailable && (!involvedURLs.isEmpty || !browserTabTitles.isEmpty)
            reason = !axAvailable ? "accessibility_not_granted" :
                     (involvedURLs.isEmpty && browserTabTitles.isEmpty) ? "no_url_or_tabs" : "runtime_discovery_required"
        case "open_paired_app", "switch_to_last_task_window":
            canExecute = !involvedApps.isEmpty
            reason = involvedApps.isEmpty ? "no_target_app" : "ready"
        case "copy_current_url", "copy_all_related_links":
            canExecute = !involvedURLs.isEmpty || !browserTabTitles.isEmpty
            reason = involvedURLs.isEmpty && browserTabTitles.isEmpty ? "no_urls_available" : "ready"
        case "restore_workspace":
            canExecute = !involvedApps.isEmpty && missing.count < involvedApps.count
            reason = involvedApps.isEmpty ? "no_workspace_pattern" : "ready"
        default:
            canExecute = true
            reason = "default_allowed"
        }

        let report = ReadinessReport(
            capabilityId: capabilityId,
            targetsFound: found,
            missingTargets: missing,
            accessibilityPermission: axAvailable,
            canExecute: canExecute,
            reason: reason
        )
        emit(report)
        return report
    }

    static func emit(_ report: ReadinessReport) {
        print("[LocalActionReadiness]"
            + " capability=\(report.capabilityId)"
            + " targets_found=\(report.targetsFound.isEmpty ? "none" : report.targetsFound.joined(separator: ","))"
            + " missing_targets=\(report.missingTargets.isEmpty ? "none" : report.missingTargets.joined(separator: ","))"
            + " accessibility_permission=\(report.accessibilityPermission ? "yes" : "no")"
            + " can_execute=\(report.canExecute ? "yes" : "no")"
            + " reason=\(report.reason)")
    }
}

// MARK: - Part 7: Dogfood Checklist

/// Phase 31 — Prints a systematic dogfood checklist.
/// Trigger with CONTEXTUAL_PRINT_DOGFOOD_CHECKLIST=1
enum DogfoodChecklist {

    static func printIfEnabled() {
        guard ProcessInfo.processInfo.environment["CONTEXTUAL_PRINT_DOGFOOD_CHECKLIST"] == "1" else { return }
        print("""
        [DogfoodChecklist]
        ==========================================
        Phase 31+32+33 Dogfood Verification Checklist
        ==========================================

        ACCESSIBILITY (Phase 32):
        0. [ ] AX permission state at startup
           Log: [AXPermission] trusted=yes/no

        ACTIONABLE ACTIONS:
        1. [ ] Music resume/play playlist
           Log: [MusicExecutor] started → [CapabilityExecution] completed status=success
        2. [ ] Arrange Preview + Firefox side by side (REAL window management)
           Log: [WindowManager] action=enumerate → [WindowArrange] layout=left_right
           Log: [WindowManager] action=set_frame → [WindowManager] action=verify_frame ok=yes
           Log: [ActionVerification] capability=arrange_side_by_side status=success
        3. [ ] Open paired app (Preview/Firefox)
           Log: [LocalActionExecution] capability=open_paired_app targets=...
        4. [ ] Switch back to paired app/window
           Log: [SwitchAction] target=... status=success
        5. [ ] Copy current browser URL
           Log: [LocalActionExecution] capability=copy_current_url status=success
        6. [ ] Copy all related research links
           Log: [LocalActionExecution] capability=copy_all_related_links

        BROWSER SPLIT (Phase 32):
        7. [ ] Firefox split: open URL in new window + arrange
           Log: [TabSplit] browser=Firefox strategy=open_url_new_window opened_new_window=yes
           Log: [WindowArrange] layout=left_right
        8. [ ] Chrome split (if available)
           Log: [TabSplit] browser=Google Chrome strategy=chromium_new_window
        9. [ ] Safari split (if available)
           Log: [TabSplit] browser=Safari strategy=safari_new_document

        WORKSPACE RESTORE (Phase 32):
        10. [ ] Restore workspace opens apps + URLs
            Log: [WorkspaceRestore] status=success|partial
        11. [ ] Restore workspace partial when URL fails
            Log: [WorkspaceRestore] status=partial

        FRICTION ACTIONS:
        12. [ ] Friction from compartment browser tabs (no explicit signal)
            Log: [FrictionSuggestionFamily] ... candidates=arrange_side_by_side
        13. [ ] LocalActionReadiness check before execution
            Log: [LocalActionReadiness] can_execute=yes/no reason=...

        FOCUS SHORTCUT (Phase 32):
        14. [ ] Focus shortcut detection
            Log: [FocusShortcut] available=yes/no shortcut=...
        15. [ ] Focus shortcut execution (if available)
            Log: [FocusAction] started shortcut=... exit_code=0 status=success
        16. [ ] Focus action hidden when shortcut missing
            Log: [FocusAction] method=shortcuts status=unavailable reason=shortcut_missing

        CONTEXT ACQUISITION:
        17. [ ] Text action with OCR acquisition (Preview PDF)
            Log: [ContextAcquisition] needed=yes reason=pdf_title_only requested=ocr
        18. [ ] Text action with AX/browser context
            Log: [ContextAcquisition] needed=yes ... requested=request_ax_text

        DEBUG VISIBILITY:
        19. [ ] TickReasoning prints every tick with context inventory
            Log: [TickReasoning] ... available_context=... missing_context=...
        20. [ ] ExecutionContextSnapshot preserved at proposal creation
            Log: [ExecutionContextSnapshot] ... snapshot_age=...

        PAYLOAD VALIDATION (Phase 33):
        21. [ ] Local actions only surface with valid payload
            Log: [LocalActionPayload] valid=yes/no missing=...
        22. [ ] Payload handoff from proposal to click verified
            Log: [PayloadHandoff] ok=yes/no missing=...
        23. [ ] Local action sanity printed each tick
            Log: [LocalActionSanity] arrange=valid split=invalid:missing_url ...
        24. [ ] Executable local action beats weak text proposal
            Log: [FamilySelection] selected=arrange_side_by_side reason=local_beats_weak_text

        DEBUG TRIGGERS (Phase 33):
        Run: CONTEXTUAL_DEBUG_ACTION=arrange_side_by_side
        Run: CONTEXTUAL_DEBUG_ACTION=copy_current_url
        Run: CONTEXTUAL_DEBUG_ACTION=split_research_setup
        Run: CONTEXTUAL_DEBUG_ACTION=restore_workspace
        Run: CONTEXTUAL_DEBUG_ACTION=play_music
        Expected: [DebugActionTrigger] capability=... result=success/unavailable

        HONEST BEHAVIOR:
        25. [ ] Unavailable actions say unavailable, not success
            Log: [CapabilityExecution] completed status=unavailable

        DOGFOOD MANUAL STEPS:
        A. Arrange side by side
           Setup: Open Preview lease PDF + Firefox housing page
           Expected proposal: "Put Preview lease PDF and Firefox housing page side by side?"
           Debug: CONTEXTUAL_DEBUG_ACTION=arrange_side_by_side
           Logs: [LocalActionPayload] valid=yes → [LiveActionPath] executor=WindowManager → [ActionVerification] status=success
           Visible: windows move left/right

        B. Browser split
           Setup: Open Firefox with two tabs
           Debug: CONTEXTUAL_DEBUG_ACTION=split_research_setup
           Logs: [TabSplit] browser=Firefox strategy=open_url_new_window → [ActionVerification] status=success
           Visible: second tab opens in new window, both arrange side by side

        C. Restore workspace
           Setup: Close Preview, keep Firefox open for 182 Montreal
           Expected proposal: "Reopen Preview for 182 Montreal?"
           Logs: [WorkspaceRestore] status=success

        D. Copy research links
           Setup: Open Firefox with housing tabs
           Debug: CONTEXTUAL_DEBUG_ACTION=copy_all_related_links
           Logs: [LocalActionExecution] capability=copy_all_related_links status=success
           Visible: clipboard has markdown links

        ==========================================
        Run with CONTEXTUAL_PRINT_DOGFOOD_CHECKLIST=1
        ==========================================
        """)
    }
}
