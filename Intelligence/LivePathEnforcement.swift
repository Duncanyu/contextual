import Foundation
import AppKit

// MARK: - Phase 36.1 — Live Path Enforcement
//
// Enforces, at proposal-selection time, that:
//   1. Proposal-bound capabilities (window/workspace/browser-state mutators) carry an
//      ActionTargetContract; without one they cannot float, and the live executor will
//      not fall back to runtime discovery.
//   2. Metadata utilities (copy URL, collect references, etc.) are panel-only unless
//      there is strong explicit usefulness evidence.
//   3. Unverified browser-state mutators (pin_reference_tabs as currently implemented —
//      it just opens URLs and cannot prove a friction-reducing tab reorganization) are
//      panel-only/suppressed regardless of ranking score.
//   4. Music can only float in stable, work-relevant contexts; weak/unknown/transient
//      contexts route it to panel_only or suppress it.
//   5. The final floating selection only considers candidates whose surface=floating.
//      Highest family-winner score alone is not sufficient.
//
// Required log lines (greppable, contract for dogfood verification):
//   [LivePathEnforcement] capability=<id> path=<source_path> contract_required=<yes/no>
//                         contract_present=<yes/no> allowed=<yes/no> surface=<...> reason=<...>
//   [VisibleActionPath] capability=<id> surface=<floating|panel> source=<...>
//                       execution_path=<contract_bound|metadata_utility|music|preview_only|legacy_runtime>
//                       contract_required=<yes/no> contract_present=<yes/no>
//   [FinalSelection] rejected_floating capability=<id> reason=<panel_only_surface|suppressed|missing_target_contract>
//   [FinalSelection] candidate=<id> surface=<...> eligible_for_floating=<yes/no>

// MARK: - Execution path classification

enum LiveExecutionPath: String, Sendable {
    case contractBound = "contract_bound"
    case metadataUtility = "metadata_utility"
    case music
    case previewOnly = "preview_only"
    case legacyRuntime = "legacy_runtime"
}

// MARK: - Decision

struct LivePathDecision: Sendable {
    let capabilityID: String
    let sourcePath: String                // cheap_portfolio | opportunity_engine | environment | generated | ambient
    let surface: ActionSurface
    let executionPath: LiveExecutionPath
    let contractRequired: Bool
    let contractPresent: Bool
    let allowedToExecute: Bool
    let eligibleForFloating: Bool
    let reason: String

    func logEnforcement(candidateID: String? = nil, lane: String? = nil) {
        let candidate = candidateID.map { " candidate_id=\($0)" } ?? ""
        let laneLabel = lane.map { " lane=\($0)" } ?? ""
        print("[LivePathEnforcement] capability=\(capabilityID)\(candidate)\(laneLabel) path=\(sourcePath) contract_required=\(contractRequired ? "yes" : "no") contract_present=\(contractPresent ? "yes" : "no") allowed=\(allowedToExecute ? "yes" : "no") surface=\(surface.rawValue) reason=\(reason)")
    }

    func logVisible(candidateID: String? = nil, lane: String? = nil) {
        let surfaceLabel: String
        switch surface {
        case .floating: surfaceLabel = "floating"
        case .panelOnly: surfaceLabel = "panel"
        case .suppressed: surfaceLabel = "suppressed"
        }
        let candidate = candidateID.map { "candidate_id=\($0) " } ?? ""
        let laneLabel = lane.map { "lane=\($0) " } ?? ""
        print("[VisibleActionPath] \(candidate)capability=\(capabilityID) \(laneLabel)surface=\(surfaceLabel) source=\(sourcePath) execution_path=\(executionPath.rawValue) contract_required=\(contractRequired ? "yes" : "no") contract_present=\(contractPresent ? "yes" : "no")")
    }

    func logFinalSelectionCandidate(candidateID: String? = nil, lane: String? = nil) {
        let candidate = candidateID.map { " candidate_id=\($0)" } ?? ""
        let laneLabel = lane.map { " lane=\($0)" } ?? ""
        print("[FinalSelection] candidate=\(capabilityID)\(candidate)\(laneLabel) surface=\(surface.rawValue) eligible_for_floating=\(eligibleForFloating ? "yes" : "no")")
        if !eligibleForFloating {
            let reasonLabel: String
            switch surface {
            case .panelOnly: reasonLabel = "panel_only_surface"
            case .suppressed: reasonLabel = "suppressed"
            case .floating: reasonLabel = reason
            }
            print("[FinalSelection] rejected_floating capability=\(capabilityID) reason=\(reasonLabel)")
        }
    }
}

// MARK: - Context inputs

struct LivePathEvaluationContext: Sendable {
    let sourcePath: String                // e.g. "cheap_portfolio"
    let contextStability: String          // "stable" | "weak" | "transient"
    let isMusicAlreadyPlaying: Bool
    let hasHigherPriorityTaskAction: Bool
    let recentFeedbackCooldownActive: Bool
    let userFeedbackHistory: String       // "neutral" | "negative" | "positive"
    let alreadySatisfied: Bool            // for layout: already arranged
    let evidenceAvailable: Bool
    let hasExplicitUsageSignal: Bool
    let activityMatch: Bool
    let compartmentLabel: String?
    let currentEntity: String
    let workflow: String

    init(
        sourcePath: String,
        contextStability: String,
        isMusicAlreadyPlaying: Bool,
        hasHigherPriorityTaskAction: Bool,
        recentFeedbackCooldownActive: Bool,
        userFeedbackHistory: String,
        alreadySatisfied: Bool,
        evidenceAvailable: Bool,
        hasExplicitUsageSignal: Bool,
        activityMatch: Bool,
        compartmentLabel: String? = nil,
        currentEntity: String = "",
        workflow: String = ""
    ) {
        self.sourcePath = sourcePath
        self.contextStability = contextStability
        self.isMusicAlreadyPlaying = isMusicAlreadyPlaying
        self.hasHigherPriorityTaskAction = hasHigherPriorityTaskAction
        self.recentFeedbackCooldownActive = recentFeedbackCooldownActive
        self.userFeedbackHistory = userFeedbackHistory
        self.alreadySatisfied = alreadySatisfied
        self.evidenceAvailable = evidenceAvailable
        self.hasExplicitUsageSignal = hasExplicitUsageSignal
        self.activityMatch = activityMatch
        self.compartmentLabel = compartmentLabel
        self.currentEntity = currentEntity
        self.workflow = workflow
    }
}

// MARK: - Capability classification

private let proposalBoundCapabilities: Set<String> = [
    "arrange_side_by_side",
    "switch_to_paired_app",
    "split_research_setup",
    "restore_workspace"
]

private let metadataUtilityIDs: Set<String> = [
    "copy_current_url",
    "collect_references",
    "copy_all_related_links",
    "remember_workspace",
    "open_current_task_panel",
    "extract_and_organize"
]

private let unverifiedBrowserStateMutators: Set<String> = [
    // pin_reference_tabs currently delegates to restoreResearchTabs which only opens URLs.
    // It has no contract for verified pin/reorganize, so it cannot prove friction reduction.
    // It stays here until a verified browser-state contract exists.
    "pin_reference_tabs"
]

enum ArrangeVerifiedWorkPairGate {

    struct Decision: Sendable {
        let verified: Bool
        let reason: String
    }

    static func evaluate(involvedApps: [String]) -> Decision {
        guard let pair = WorkPairMemory.shared.bestPair() else {
            return Decision(verified: false, reason: "no_verified_work_pair")
        }
        let matches = involvedApps.count >= 2 &&
            involvedApps.contains(where: { $0.caseInsensitiveCompare(pair.appA) == .orderedSame }) &&
            involvedApps.contains(where: { $0.caseInsensitiveCompare(pair.appB) == .orderedSame })
        return Decision(verified: matches, reason: matches ? "verified_work_pair" : "no_verified_work_pair")
    }
}

// MARK: - Live Path Enforcer

enum LivePathEnforcer {

    /// Decide surface and execution path for a single candidate.
    /// Synthesizes a target contract for layout candidates when `involvedApps.count >= 2`
    /// so the cheap portfolio path can carry a live contract through to execution.
    static func evaluate(
        capabilityID: String,
        involvedApps: [String],
        attachedContract: ActionTargetContract?,
        confidence: Double,
        evaluationContext: LivePathEvaluationContext
    ) -> (LivePathDecision, ActionTargetContract?) {
        let reqCheck = ActionRequirementGate.evaluate(
            capabilityID: capabilityID,
            involvedApps: involvedApps,
            evaluationContext: evaluationContext,
            confidence: confidence,
            attachedContract: attachedContract
        )
        if !reqCheck.allowed {
            if capabilityID == "arrange_side_by_side" {
                print("[PanelAction] hidden capability=arrange_side_by_side reason=\(reqCheck.reason)")
                print("[FloatingSuggestion] suppressed capability=arrange_side_by_side reason=\(reqCheck.reason)")
            }
            let decision = LivePathDecision(
                capabilityID: capabilityID,
                sourcePath: evaluationContext.sourcePath,
                surface: .suppressed,
                executionPath: .contractBound,
                contractRequired: false,
                contractPresent: false,
                allowedToExecute: false,
                eligibleForFloating: false,
                reason: reqCheck.reason
            )
            return (decision, nil)
        }


        // 1. Unverified browser-state mutators (pin_reference_tabs as implemented today)
        if unverifiedBrowserStateMutators.contains(capabilityID) {
            let decision = LivePathDecision(
                capabilityID: capabilityID,
                sourcePath: evaluationContext.sourcePath,
                surface: .panelOnly,
                executionPath: .legacyRuntime,
                contractRequired: true,
                contractPresent: false,
                allowedToExecute: true,        // panel click still allowed; just not floating
                eligibleForFloating: false,
                reason: "unverified_browser_state_change"
            )
            print("[ActionUsefulness] capability=\(capabilityID) surface=panel_only reason=unverified_browser_state_change")
            return (decision, nil)
        }

        // 2. Metadata utilities → panel_only unless explicit usefulness signal
        if metadataUtilityIDs.contains(capabilityID) {
            let canFloat = evaluationContext.hasExplicitUsageSignal && evaluationContext.activityMatch
            let surface: ActionSurface = canFloat ? .floating : .panelOnly
            let reason = canFloat ? "metadata_utility_explicit_signal" : "metadata_utility_low_interrupt"
            let decision = LivePathDecision(
                capabilityID: capabilityID,
                sourcePath: evaluationContext.sourcePath,
                surface: surface,
                executionPath: .metadataUtility,
                contractRequired: false,
                contractPresent: false,
                allowedToExecute: true,
                eligibleForFloating: canFloat,
                reason: reason
            )
            print("[ActionUsefulness] capability=\(capabilityID) surface=\(surface.rawValue) reason=\(reason)")
            return (decision, nil)
        }

        // 3. Music: stable-context gate
        if capabilityID == "play_focus_media" || capabilityID == "resume_focus_media" {
            if evaluationContext.isMusicAlreadyPlaying {
                let decision = LivePathDecision(
                    capabilityID: capabilityID,
                    sourcePath: evaluationContext.sourcePath,
                    surface: .suppressed,
                    executionPath: .music,
                    contractRequired: false, contractPresent: false,
                    allowedToExecute: false,
                    eligibleForFloating: false,
                    reason: "already_playing"
                )
                print("[MusicSuggestion] suppressed reason=already_playing")
                print("[ActionUsefulness] capability=\(capabilityID) eligible=no surface=suppressed reason=already_playing")
                return (decision, nil)
            }
            // Phase 40 — task action preferred no longer suppresses music; it demotes to panel.
            // Music must remain visible in the panel even when a task/friction action is floating.
            if evaluationContext.hasHigherPriorityTaskAction {
                let decision = LivePathDecision(
                    capabilityID: capabilityID,
                    sourcePath: evaluationContext.sourcePath,
                    surface: .panelOnly,
                    executionPath: .music,
                    contractRequired: false, contractPresent: false,
                    allowedToExecute: true,
                    eligibleForFloating: false,
                    reason: "secondary_to_active_task"
                )
                print("[MusicSuggestion] surface=panel reason=secondary_to_active_task")
                print("[ActionUsefulness] capability=\(capabilityID) eligible=yes surface=panel_only reason=secondary_to_active_task")
                return (decision, nil)
            }
            if evaluationContext.contextStability != "stable" || confidence < 0.55 {
                // Weak/transient context — keep music in panel so it isn't dropped entirely.
                let decision = LivePathDecision(
                    capabilityID: capabilityID,
                    sourcePath: evaluationContext.sourcePath,
                    surface: .panelOnly,
                    executionPath: .music,
                    contractRequired: false, contractPresent: false,
                    allowedToExecute: true,
                    eligibleForFloating: false,
                    reason: "weak_or_transient_context"
                )
                print("[MusicSuggestion] surface=panel reason=weak_or_transient_context")
                print("[ActionUsefulness] capability=\(capabilityID) eligible=yes surface=panel_only reason=weak_or_transient_context")
                return (decision, nil)
            }
            if evaluationContext.recentFeedbackCooldownActive {
                let decision = LivePathDecision(
                    capabilityID: capabilityID,
                    sourcePath: evaluationContext.sourcePath,
                    surface: .panelOnly,
                    executionPath: .music,
                    contractRequired: false, contractPresent: false,
                    allowedToExecute: true,
                    eligibleForFloating: false,
                    reason: "recent_feedback_cooldown"
                )
                print("[ActionUsefulness] capability=\(capabilityID) eligible=no surface=panel_only reason=recent_feedback_cooldown")
                return (decision, nil)
            }
            // Music passed all gates — eligible to float in stable, work-relevant context
            let decision = LivePathDecision(
                capabilityID: capabilityID,
                sourcePath: evaluationContext.sourcePath,
                surface: .floating,
                executionPath: .music,
                contractRequired: false, contractPresent: false,
                allowedToExecute: true,
                eligibleForFloating: true,
                reason: "stable_work_context_no_higher_priority"
            )
            print("[MusicSuggestion] surface=floating reason=stable_work_context_no_higher_priority")
            print("[ActionUsefulness] capability=\(capabilityID) eligible=yes surface=floating reason=stable_work_context_no_higher_priority")
            return (decision, nil)
        }

        // 4. Proposal-bound capabilities: require contract or synthesize from involvedApps
        if proposalBoundCapabilities.contains(capabilityID) {
            // Already-satisfied check before contract creation
            if evaluationContext.alreadySatisfied {
                let decision = LivePathDecision(
                    capabilityID: capabilityID,
                    sourcePath: evaluationContext.sourcePath,
                    surface: .suppressed,
                    executionPath: .contractBound,
                    contractRequired: true,
                    contractPresent: attachedContract != nil,
                    allowedToExecute: false,
                    eligibleForFloating: false,
                    reason: "already_satisfied"
                )
                print("[ActionUsefulness] capability=\(capabilityID) target_present=yes already_satisfied=yes eligible=no surface=suppressed reason=already_satisfied")
                return (decision, attachedContract)
            }

            let contract: ActionTargetContract? = attachedContract ?? synthesizeLayoutContract(
                capabilityID: capabilityID,
                involvedApps: involvedApps,
                confidence: confidence
            )

            guard let resolvedContract = contract else {
                // No contract attachable — block from floating, allow panel as best-effort
                let decision = LivePathDecision(
                    capabilityID: capabilityID,
                    sourcePath: evaluationContext.sourcePath,
                    surface: .panelOnly,
                    executionPath: .contractBound,
                    contractRequired: true,
                    contractPresent: false,
                    allowedToExecute: false,
                    eligibleForFloating: false,
                    reason: "missing_target_contract"
                )
                print("[ActionUsefulness] capability=\(capabilityID) target_present=no eligible=no surface=panel_only reason=missing_target_contract")
                return (decision, nil)
            }

            if !evaluationContext.evidenceAvailable {
                let decision = LivePathDecision(
                    capabilityID: capabilityID,
                    sourcePath: evaluationContext.sourcePath,
                    surface: .suppressed,
                    executionPath: .contractBound,
                    contractRequired: true,
                    contractPresent: true,
                    allowedToExecute: false,
                    eligibleForFloating: false,
                    reason: "insufficient_evidence"
                )
                print("[ActionUsefulness] capability=\(capabilityID) eligible=no surface=suppressed reason=insufficient_evidence")
                return (decision, resolvedContract)
            }

            // Calibrate freshness of layout / workspace memory suggestions
            let calibration = FreshnessCalibrator.calibrate(
                capabilityID: capabilityID,
                involvedApps: involvedApps,
                compartmentLabel: evaluationContext.compartmentLabel,
                currentEntity: evaluationContext.currentEntity,
                workflow: evaluationContext.workflow
            )

            // Phase 51 — manual-only arrange (no verified pair) must never float.
            // It stays a panel action the user can click; proactive surfacing
            // requires the verified pair that reqCheck would have confirmed.
            let manualOnlyArrange = capabilityID == "arrange_side_by_side"
                && (reqCheck.reason == "manual_arrange_available" || evaluationContext.sourcePath == "manual_arrange_panel")
            let canFloat = calibration.surface == .floating && evaluationContext.activityMatch && !manualOnlyArrange
            let surface: ActionSurface = manualOnlyArrange ? .panelOnly : calibration.surface
            let reason = manualOnlyArrange
                ? "manual_arrange_panel_only"
                : (calibration.surface == .floating ? "high_usefulness_low_cost" : "moderate_usefulness")
            let decision = LivePathDecision(
                capabilityID: capabilityID,
                sourcePath: evaluationContext.sourcePath,
                surface: surface,
                executionPath: .contractBound,
                contractRequired: true,
                contractPresent: true,
                allowedToExecute: surface != .suppressed,
                eligibleForFloating: canFloat,
                reason: reason
            )
            let timeSaved = canFloat ? "high" : "medium"
            print("[ActionUsefulness] capability=\(capabilityID) target_present=yes already_satisfied=no time_saved=\(timeSaved) surface=\(surface.rawValue) reason=\(reason)")
            return (decision, resolvedContract)
        }

        // 5. Other actions (cognitive, research, comfort): rank-driven; let usefulness policy decide
        let policy = ActionUsefulnessPolicy.evaluate(
            capabilityID: capabilityID,
            targetPresent: !involvedApps.isEmpty || evaluationContext.evidenceAvailable,
            alreadySatisfied: evaluationContext.alreadySatisfied,
            contractFresh: true,
            activityMatch: evaluationContext.activityMatch,
            userFeedbackHistory: evaluationContext.userFeedbackHistory,
            confidence: confidence,
            evidenceAvailable: evaluationContext.evidenceAvailable,
            hasExplicitUsageSignal: evaluationContext.hasExplicitUsageSignal
        )
        let decision = LivePathDecision(
            capabilityID: capabilityID,
            sourcePath: evaluationContext.sourcePath,
            surface: policy.surface,
            executionPath: .legacyRuntime,
            contractRequired: false,
            contractPresent: false,
            allowedToExecute: policy.eligible,
            eligibleForFloating: policy.surface == .floating,
            reason: policy.reason
        )
        return (decision, nil)
    }

    /// Synthesize a contract for layout/workspace candidates when we have ≥1-2 involved apps.
    private static func synthesizeLayoutContract(
        capabilityID: String,
        involvedApps: [String],
        confidence: Double
    ) -> ActionTargetContract? {
        switch capabilityID {
        case "arrange_side_by_side", "switch_to_paired_app", "split_research_setup":
            guard involvedApps.count >= 2 else { return nil }
            return ActionTargetContract.forLayoutApps(
                capabilityID: capabilityID,
                appNames: involvedApps,
                evidenceType: .active_window_pair,
                confidence: confidence,
                fallbackAllowed: false
            )
        case "restore_workspace":
            guard !involvedApps.isEmpty else { return nil }
            return ActionTargetContract.forLayoutApps(
                capabilityID: capabilityID,
                appNames: involvedApps,
                evidenceType: .workspace_pattern,
                confidence: confidence,
                fallbackAllowed: false
            )
        default:
            return nil
        }
    }

    /// Returns whether a given capability requires a contract on the live execution path.
    /// pin_reference_tabs is excluded — it is panel-only by surface policy but executable
    /// from the panel; it does not have a verified browser-state contract yet so we cannot
    /// require one without breaking the existing tab-open behavior.
    static func requiresContract(_ capabilityID: String) -> Bool {
        proposalBoundCapabilities.contains(capabilityID)
    }

    /// Returns the metadata utility set (for tests).
    static var metadataUtilities: Set<String> { metadataUtilityIDs }
}

// MARK: - Self-test

enum LivePathEnforcementSelfTest {

    static func run() -> Bool {
        print("[LivePathEnforcementSelfTest] starting")
        let savedSnapshot = WorkspaceRuntimeInventoryProvider.testSnapshot
        defer {
            WorkspaceRuntimeInventoryProvider.testSnapshot = savedSnapshot
        }
        
        let wp = WorkPairMemory.shared
        wp.recordSwitch(app: "Firefox", title: "Rental Postings", pid: 101)
        wp.recordSwitch(app: "Preview", title: "Lease Document", pid: 102)
        wp.recordSwitch(app: "Firefox", title: "Rental Postings", pid: 101)
        wp.recordSwitch(app: "Preview", title: "Lease Document", pid: 102)

        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
            ],
            visibleWindows: [
                WindowSnapshot(
                    windowID: 99,
                    appName: "Firefox",
                    bundleID: "org.mozilla.firefox",
                    pid: 101,
                    title: "Rental Postings",
                    frame: CGRect(x: 0, y: 0, width: 400, height: 800),
                    layer: 0,
                    isOnScreen: true,
                    isOnActiveScreen: true
                ),
                WindowSnapshot(
                    windowID: 100,
                    appName: "Preview",
                    bundleID: "com.apple.Preview",
                    pid: 102,
                    title: "Lease Document",
                    frame: CGRect(x: 500, y: 0, width: 400, height: 800),
                    layer: 0,
                    isOnScreen: true,
                    isOnActiveScreen: true
                )
            ],
            browserTabTitles: ["Rental Postings"],
            currentURLs: ["https://rental-postings.com"],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )

        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[LivePathEnforcementSelfTest] pass case=\(name)") }
            else { print("[LivePathEnforcementSelfTest] fail case=\(name)"); failures.append(name) }
        }

        let stableCtx = LivePathEvaluationContext(
            sourcePath: "cheap_portfolio",
            contextStability: "stable",
            isMusicAlreadyPlaying: false,
            hasHigherPriorityTaskAction: false,
            recentFeedbackCooldownActive: false,
            userFeedbackHistory: "neutral",
            alreadySatisfied: false,
            evidenceAvailable: true,
            hasExplicitUsageSignal: false,
            activityMatch: true
        )

        // Test A: metadata utility with no explicit signal → panel_only
        let (copyDecision, _) = LivePathEnforcer.evaluate(
            capabilityID: "copy_current_url",
            involvedApps: ["Browser"],
            attachedContract: nil,
            confidence: 0.9,
            evaluationContext: stableCtx
        )
        check("a_copy_url_panel_only", copyDecision.surface == .panelOnly)
        check("a_copy_url_not_floating", !copyDecision.eligibleForFloating)

        // Test B: pin_reference_tabs (unverified browser-state) → panel_only with unverified_browser_state_change
        let (pinDecision, _) = LivePathEnforcer.evaluate(
            capabilityID: "pin_reference_tabs",
            involvedApps: ["Browser"],
            attachedContract: nil,
            confidence: 0.9,
            evaluationContext: stableCtx
        )
        check("b_pin_panel_only", pinDecision.surface == .panelOnly)
        check("b_pin_not_floating", !pinDecision.eligibleForFloating)
        check("b_pin_reason", pinDecision.reason == "unverified_browser_state_change")

        // Test C: arrange_side_by_side with no contract and no apps.
        // Phase 51 — no verified pair no longer suppresses arrange entirely: it stays
        // a manual panel action (the executor resolves live targets on click), but it
        // must never float without a verified pair.
        let (arrangeNoContract, _) = LivePathEnforcer.evaluate(
            capabilityID: "arrange_side_by_side",
            involvedApps: [],
            attachedContract: nil,
            confidence: 0.9,
            evaluationContext: stableCtx
        )
        check("c_arrange_no_contract_panel_only", arrangeNoContract.surface == .panelOnly || arrangeNoContract.surface == .suppressed)
        check("c_arrange_no_contract_reason", arrangeNoContract.reason == "missing_target_contract" || arrangeNoContract.reason == "no_verified_work_pair")
        check("c_arrange_no_contract_not_floating", !arrangeNoContract.eligibleForFloating)

        // Test D: arrange_side_by_side with 2 involved apps → contract synthesized, can float
        let (arrangeOk, contractOk) = LivePathEnforcer.evaluate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            attachedContract: nil,
            confidence: 0.85,
            evaluationContext: stableCtx
        )
        check("d_arrange_contract_synthesized", contractOk != nil)
        check("d_arrange_can_float", arrangeOk.eligibleForFloating)

        // Test E: play_focus_media in weak context → panelOnly weak_or_transient_context (Phase 40: not suppressed)
        let weakCtx = LivePathEvaluationContext(
            sourcePath: "cheap_portfolio",
            contextStability: "weak",
            isMusicAlreadyPlaying: false,
            hasHigherPriorityTaskAction: false,
            recentFeedbackCooldownActive: false,
            userFeedbackHistory: "neutral",
            alreadySatisfied: false,
            evidenceAvailable: true,
            hasExplicitUsageSignal: false,
            activityMatch: true
        )
        let (musicWeak, _) = LivePathEnforcer.evaluate(
            capabilityID: "play_focus_media",
            involvedApps: [],
            attachedContract: nil,
            confidence: 0.9,
            evaluationContext: weakCtx
        )
        // Phase 40: weak context keeps music in panel (not suppressed) so it remains accessible.
        check("e_music_weak_suppressed", musicWeak.surface == .panelOnly)
        check("e_music_weak_reason", musicWeak.reason == "weak_or_transient_context")

        // Test F: play_focus_media in stable context with higher-priority task → suppressed task_action_preferred
        let taskCtx = LivePathEvaluationContext(
            sourcePath: "cheap_portfolio",
            contextStability: "stable",
            isMusicAlreadyPlaying: false,
            hasHigherPriorityTaskAction: true,
            recentFeedbackCooldownActive: false,
            userFeedbackHistory: "neutral",
            alreadySatisfied: false,
            evidenceAvailable: true,
            hasExplicitUsageSignal: false,
            activityMatch: true
        )
        let (musicTask, _) = LivePathEnforcer.evaluate(
            capabilityID: "play_focus_media",
            involvedApps: [],
            attachedContract: nil,
            confidence: 0.9,
            evaluationContext: taskCtx
        )
        check("f_music_task_preferred", musicTask.reason == "secondary_to_active_task")

        // Test G: arrange_side_by_side already_satisfied → suppressed
        let satisfiedCtx = LivePathEvaluationContext(
            sourcePath: "cheap_portfolio",
            contextStability: "stable",
            isMusicAlreadyPlaying: false,
            hasHigherPriorityTaskAction: false,
            recentFeedbackCooldownActive: false,
            userFeedbackHistory: "neutral",
            alreadySatisfied: true,
            evidenceAvailable: true,
            hasExplicitUsageSignal: false,
            activityMatch: true
        )
        let (arrangeSat, _) = LivePathEnforcer.evaluate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            attachedContract: nil,
            confidence: 0.85,
            evaluationContext: satisfiedCtx
        )
        check("g_arrange_satisfied_suppressed", arrangeSat.surface == .suppressed)
        check("g_arrange_satisfied_reason", arrangeSat.reason == "already_satisfied")

        let ok = failures.isEmpty
        print("[LivePathEnforcementSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

// MARK: - Freshness Calibrator

enum FreshnessCalibrator {
    
    enum EvidenceLevel: String {
        case low
        case medium
        case high
    }
    
    struct CalibrationResult {
        let liveEvidence: EvidenceLevel
        let durableMemory: Bool
        let recentInteraction: Bool
        let currentSessionSupport: Bool
        let confidence: Double
        let surface: ActionSurface
    }
    
    static func calibrate(
        capabilityID: String,
        involvedApps: [String],
        compartmentLabel: String?,
        currentEntity: String,
        workflow: String
    ) -> CalibrationResult {
        // Retrieve durable memory
        let runningAppNames = Set(WorkspaceRuntimeInventoryProvider.snapshot().runningApps.map(\.appName))
        let visibleAppNames = Set(WorkspaceRuntimeInventoryProvider.snapshot().visibleWindows.map(\.appName))
        let inventoryApps = runningAppNames.union(visibleAppNames)
        
        let durablePattern = DurableMemory.shared.bestDurableWorkspacePattern(
            workflow: workflow,
            compartment: compartmentLabel,
            currentApps: inventoryApps
        )
        let durableAppNames = durablePattern?.apps.map(\.appName) ?? []
        
        let isDurableMemory = !durableAppNames.isEmpty && involvedApps.allSatisfy { app in
            durableAppNames.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
        }
        
        // Log used_as for WorkspaceMemory
        let usedAs: String
        let workspaceReason: String
        if isDurableMemory {
            let workPair = WorkPairMemory.shared.bestPair()
            let interactedWithBoth = involvedApps.count >= 2 && workPair != nil &&
                involvedApps.contains(where: { $0.caseInsensitiveCompare(workPair!.appA) == .orderedSame }) &&
                involvedApps.contains(where: { $0.caseInsensitiveCompare(workPair!.appB) == .orderedSame })
            if interactedWithBoth {
                usedAs = "supporting_evidence"
                workspaceReason = "durable_pattern_supported_by_recent_interaction"
            } else {
                usedAs = "hint"
                workspaceReason = "durable_pattern_alone"
            }
        } else {
            usedAs = "hint"
            workspaceReason = "no_durable_pattern_matched"
        }
        print("[WorkspaceMemory] used_as=\(usedAs) reason=\(workspaceReason)")
        
        // Check recent interaction
        let workPair = WorkPairMemory.shared.bestPair()
        let recentInteraction = involvedApps.count >= 2 && workPair != nil &&
            involvedApps.contains(where: { $0.caseInsensitiveCompare(workPair!.appA) == .orderedSame }) &&
            involvedApps.contains(where: { $0.caseInsensitiveCompare(workPair!.appB) == .orderedSame })
        
        // Check if both targets are currently visible
        let visibleWindows = WorkspaceRuntimeInventoryProvider.snapshot().visibleWindows
        let visibleInvolved = involvedApps.filter { app in
            visibleWindows.contains { $0.appName.caseInsensitiveCompare(app) == .orderedSame && $0.isOnActiveScreen }
        }
        let bothVisible = visibleInvolved.count >= 2
        
        // Check if windows are not arranged
        let primaryWin = visibleWindows.first { $0.appName.caseInsensitiveCompare(involvedApps.first ?? "") == .orderedSame }
        let secondaryWin = visibleWindows.first { $0.appName.caseInsensitiveCompare(involvedApps.dropFirst().first ?? "") == .orderedSame }
        let isArranged = classifyLayout(primary: primaryWin, secondary: secondaryWin) == "already_arranged"
        let notArranged = !isArranged
        
        // Check current task semantic match / active compartment match
        let combined = [currentEntity, compartmentLabel ?? ""].joined(separator: " ").lowercased()
        let tokens = Set(combined.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 })
        let semanticMatch = involvedApps.contains { app in
            tokens.contains { app.lowercased().contains($0) }
        }
        
        let compartmentMatch = compartmentLabel != nil && !compartmentLabel!.isEmpty
        let currentSessionSupport = recentInteraction || (compartmentMatch && semanticMatch)
        
        // Calculate live evidence level
        var liveScore = 0
        if bothVisible { liveScore += 2 }
        if recentInteraction { liveScore += 2 }
        if notArranged { liveScore += 1 }
        if semanticMatch { liveScore += 1 }
        if compartmentMatch { liveScore += 1 }
        
        let liveEvidence: EvidenceLevel
        if liveScore >= 5 {
            liveEvidence = .high
        } else if liveScore >= 3 {
            liveEvidence = .medium
        } else {
            liveEvidence = .low
        }
        
        // Calculate confidence and surface
        var confidence = 0.5
        if isDurableMemory {
            confidence += 0.2
        }
        if liveEvidence == .high {
            confidence += 0.25
        } else if liveEvidence == .medium {
            confidence += 0.15
        } else {
            confidence -= 0.15
        }
        if recentInteraction {
            confidence += 0.1
        }
        confidence = max(0.1, min(0.95, confidence))
        
        let surface: ActionSurface
        if isDurableMemory && !currentSessionSupport && liveEvidence != .high {
            surface = .panelOnly
        } else if (liveEvidence == .high || liveEvidence == .medium) && notArranged {
            surface = .floating
        } else if isArranged {
            surface = .suppressed
        } else {
            surface = .panelOnly
        }
        
        // Clear/decay stale temporal stream
        if let pair = workPair {
            var shiftReason: String? = nil
            let debugApps: Set<String> = ["Xcode", "Terminal", "iTerm2", "iTerm", "Console"]
            let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            if debugApps.contains(currentApp) && !debugApps.contains(pair.appA) && !debugApps.contains(pair.appB) {
                shiftReason = "debug_context"
            } else if let comp = compartmentLabel, !comp.isEmpty {
                let compLower = comp.lowercased()
                let matchA = pair.appA.lowercased().contains(compLower) || pair.titleA.lowercased().contains(compLower)
                let matchB = pair.appB.lowercased().contains(compLower) || pair.titleB.lowercased().contains(compLower)
                if !matchA && !matchB {
                    shiftReason = "compartment_shift"
                }
            } else if !currentEntity.isEmpty {
                let pairTokens = Set("\(pair.appA) \(pair.titleA) \(pair.appB) \(pair.titleB)".lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 })
                let entityTokens = Set(currentEntity.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 })
                if pairTokens.intersection(entityTokens).isEmpty && currentApp != pair.appA && currentApp != pair.appB {
                    shiftReason = "session_shift"
                }
            }
            
            if let reason = shiftReason {
                print("[TemporalStream] cleared_stale_pair=\(pair.appA)+\(pair.appB) reason=\(reason)")
                WorkPairMemory.shared.reset()
            }
        }
        
        print("[FreshnessCalibration] capability=\(capabilityID) live_evidence=\(liveEvidence.rawValue) durable_memory=\(isDurableMemory ? "yes" : "no") recent_interaction=\(recentInteraction ? "yes" : "no") current_session_support=\(currentSessionSupport ? "yes" : "no") confidence=\(String(format: "%.2f", confidence)) surface=\(surface.rawValue)")
        
        return CalibrationResult(
            liveEvidence: liveEvidence,
            durableMemory: isDurableMemory,
            recentInteraction: recentInteraction,
            currentSessionSupport: currentSessionSupport,
            confidence: confidence,
            surface: surface
        )
    }
    
    private static func classifyLayout(primary: WindowSnapshot?, secondary: WindowSnapshot?) -> String {
        guard let a = primary, let b = secondary else { return "unknown" }
        guard let screen = NSScreen.main else { return "unknown" }
        let screenFrame = screen.visibleFrame

        let frameA = a.frame
        let frameB = b.frame

        let halfWidth = screenFrame.width / 2.0
        let centerA = frameA.midX
        let centerB = frameB.midX
        let onDifferentHalves =
            (centerA <= screenFrame.midX + 30 && centerB >= screenFrame.midX - 30) ||
            (centerB <= screenFrame.midX + 30 && centerA >= screenFrame.midX - 30)
        let widthsAreHalf = abs(frameA.width - halfWidth) < halfWidth * 0.30
            && abs(frameB.width - halfWidth) < halfWidth * 0.30
        if onDifferentHalves && widthsAreHalf { return "already_arranged" }
        return "not_arranged"
    }
}

// MARK: - Useful Action Opportunity Registry

struct UsefulActionOpportunity: Sendable {
    let family: String
    let capabilityID: String
    let requiredEvidence: String
    let execution: String
    let verification: String
    let failureMode: String
}

enum UsefulActionOpportunityRegistry {
    static let opportunities: [String: UsefulActionOpportunity] = [
        "arrange_side_by_side": .init(family: "layout", capabilityID: "arrange_side_by_side", requiredEvidence: "runtime_workspace_friction", execution: "local", verification: "ax_frame_check", failureMode: "ax_resisted_move"),
        "switch_to_paired_app": .init(family: "layout", capabilityID: "switch_to_paired_app", requiredEvidence: "work_pair_alternation", execution: "local", verification: "frontmost_app_check", failureMode: "process_not_found"),
        "restore_workspace": .init(family: "layout", capabilityID: "restore_workspace", requiredEvidence: "durable_workspace_record", execution: "local", verification: "app_presence_check", failureMode: "failed_to_restore_workspace"),
        
        "play_focus_media": .init(family: "media", capabilityID: "play_focus_media", requiredEvidence: "work_context", execution: "local", verification: "player_state_check", failureMode: "player_error"),
        "pause_media": .init(family: "media", capabilityID: "pause_media", requiredEvidence: "foreground_media_active", execution: "local", verification: "player_state_check", failureMode: "player_error"),
        
        "explicit_visible_capture_summary": .init(family: "research", capabilityID: "explicit_visible_capture_summary", requiredEvidence: "visible_capture", execution: "acquisition", verification: "output_presence_check", failureMode: "content_unavailable"),
        "extract_action_items": .init(family: "research", capabilityID: "extract_action_items", requiredEvidence: "visible_capture", execution: "acquisition", verification: "output_presence_check", failureMode: "content_unavailable"),
        
        "rewrite_text": .init(family: "writing", capabilityID: "rewrite_text", requiredEvidence: "selected_text", execution: "generated", verification: "output_presence_check", failureMode: "content_unavailable"),
        
        "diagnose_error": .init(family: "coding", capabilityID: "diagnose_error", requiredEvidence: "selected_text", execution: "generated", verification: "output_presence_check", failureMode: "content_unavailable"),
        
        "draft_reply": .init(family: "communication", capabilityID: "draft_reply", requiredEvidence: "selected_text", execution: "generated", verification: "output_presence_check", failureMode: "content_unavailable")
    ]
    
    static func logRegistry() {
        for opp in opportunities.values.sorted(by: { $0.capabilityID < $1.capabilityID }) {
            print("[UsefulActionOpportunityRegistry] family=\(opp.family) capability=\(opp.capabilityID) required_evidence=\(opp.requiredEvidence) execution=\(opp.execution) verification=\(opp.verification)")
        }
    }
}

// MARK: - Action Requirement Gate

enum ActionRequirementGate {
    static func evaluate(
        capabilityID: String,
        involvedApps: [String],
        evaluationContext: LivePathEvaluationContext,
        confidence: Double,
        attachedContract: ActionTargetContract?
    ) -> (allowed: Bool, reason: String) {
        
        // 1. arrange_side_by_side requirements check
        if capabilityID == "arrange_side_by_side" {
            let res = checkArrangeRequirements(involvedApps: involvedApps, evaluationContext: evaluationContext)
            print("[ArrangePreSurfaceCheck] capability=arrange_side_by_side verified_work_pair=\(res.verifiedWorkPair ? "yes" : "no") allowed=\(res.allowed ? "yes" : "no") reason=\(res.reason)")
            print("[ActionRequirement] capability=arrange_side_by_side allowed=\(res.allowed ? "yes" : "no") reason=\(res.reason)")
            
            if !res.allowed {
                print("[ActionRequirementFailure] capability=arrange_side_by_side missing=\(res.invalidContext ?? "none") invalid_context=\(res.invalidContext ?? "none")")
                return (false, res.reason)
            } else {
                print("[ActionRequirementPass] capability=arrange_side_by_side reason=\(res.reason)")
                return (true, res.reason)
            }
        }
        
        // 2. Generic research actions checks
        let researchActions: Set<String> = [
            "explicit_visible_capture_summary", "summarize_visible_content", "extract_action_items", "create_checklist"
        ]
        let selectionActions: Set<String> = [
            "rewrite_text", "explain_context", "draft_reply", "diagnose_error"
        ]
        
        let evidence: String
        let allowed: Bool
        let reason: String
        let invalidContext: String?
        
        if researchActions.contains(capabilityID) {
            let hasVisible = evaluationContext.evidenceAvailable || evaluationContext.contextStability != "weak"
            evidence = "visible_capture"
            allowed = hasVisible
            reason = hasVisible ? "visible_content_available" : "metadata_only_blocked"
            invalidContext = hasVisible ? nil : "missing_visible_capture"
        } else if selectionActions.contains(capabilityID) {
            let hasSelection = evaluationContext.evidenceAvailable
            evidence = "selected_text"
            allowed = hasSelection
            reason = hasSelection ? "selected_text_available" : "no_selection_blocked"
            invalidContext = hasSelection ? nil : "missing_selected_text"
        } else if capabilityID == "synthesize_sources" {
            let hasFull = evaluationContext.evidenceAvailable && evaluationContext.contextStability == "stable"
            evidence = "full_content"
            allowed = hasFull
            reason = hasFull ? "full_content_available" : "content_unavailable_metadata_only"
            invalidContext = hasFull ? nil : "missing_full_content"
        } else {
            evidence = "none"
            allowed = true
            reason = "always_allowed"
            invalidContext = nil
        }
        
        print("[ActionRequirement] capability=\(capabilityID) allowed=\(allowed ? "yes" : "no") reason=\(reason) evidence=\(evidence)")
        if !allowed {
            print("[ActionRequirementFailure] capability=\(capabilityID) missing=\(invalidContext ?? "none") invalid_context=\(invalidContext ?? "none")")
        } else {
            print("[ActionRequirementPass] capability=\(capabilityID) reason=\(reason)")
        }
        
        return (allowed, reason)
    }
    
    private static func classifyLayout(primary: WindowSnapshot?, secondary: WindowSnapshot?) -> String {
        guard let a = primary, let b = secondary else { return "not_arranged" }
        guard let screen = NSScreen.main else { return "not_arranged" }
        let screenFrame = screen.visibleFrame

        let frameA = a.frame
        let frameB = b.frame

        let halfWidth = screenFrame.width / 2.0
        let centerA = frameA.midX
        let centerB = frameB.midX
        let onDifferentHalves =
            (centerA <= screenFrame.midX + 30 && centerB >= screenFrame.midX - 30) ||
            (centerB <= screenFrame.midX + 30 && centerA >= screenFrame.midX - 30)
        let widthsAreHalf = abs(frameA.width - halfWidth) < halfWidth * 0.30
            && abs(frameB.width - halfWidth) < halfWidth * 0.30
        if onDifferentHalves && widthsAreHalf { return "already_arranged" }
        return "not_arranged"
    }
    
    private static func checkArrangeRequirements(
        involvedApps: [String],
        evaluationContext: LivePathEvaluationContext
    ) -> (allowed: Bool, reason: String, evidence: String, invalidContext: String?, verifiedWorkPair: Bool) {
        let verifiedPair = ArrangeVerifiedWorkPairGate.evaluate(involvedApps: involvedApps)
        print("[ProactiveArrangeGate] allowed=\(verifiedPair.verified ? "yes" : "no") reason=\(verifiedPair.reason)")
        if !verifiedPair.verified {
            // Phase 51 — no verified pair kills the PROACTIVE surface only.
            // Manual arrange stays available in the panel when two reasonable
            // cross-app windows exist; the executor resolves live targets on click.
            let runtime = WorkspaceRuntimeInventoryProvider.snapshot()
            let crossAppWindows = Set(
                runtime.visibleWindows
                    .filter { $0.isOnActiveScreen && !WorkspaceAppFilter.isSystemApp($0.appName) }
                    .map(\.appName)
            )
            if crossAppWindows.count >= 2 {
                print("[ArrangeRequirement] allowed=manual_only reason=manual_arrange_available windows=\(crossAppWindows.count)")
                return (true, "manual_arrange_available", "runtime_windows", nil, false)
            }
            print("[ArrangeRequirement] blocked reason=no_verified_work_pair")
            return (false, "no_verified_work_pair", "none", "no_verified_work_pair", false)
        }

        let workPair = WorkPairMemory.shared.bestPair()
        
        let hasAlternation = involvedApps.count >= 2 && workPair != nil &&
            involvedApps.contains(where: { $0.caseInsensitiveCompare(workPair!.appA) == .orderedSame }) &&
            involvedApps.contains(where: { $0.caseInsensitiveCompare(workPair!.appB) == .orderedSame })
        let switches = hasAlternation ? workPair!.switches : 0
        let recentAlternation = switches >= 2
        
        let combinedText = "\(evaluationContext.currentEntity) \(evaluationContext.compartmentLabel ?? "") \(evaluationContext.workflow)".lowercased()
        let hasComparisonIntent = combinedText.contains("compare") ||
                                  combinedText.contains("comparison") ||
                                  combinedText.contains("research") ||
                                  combinedText.contains("referencing") ||
                                  combinedText.contains("reference")
        
        let sourceTransfer = (evaluationContext.hasExplicitUsageSignal) ? "yes" : "no"
        
        let visibleWindows = WorkspaceRuntimeInventoryProvider.snapshot().visibleWindows
        let visibleInvolved = involvedApps.filter { app in
            visibleWindows.contains { $0.appName.caseInsensitiveCompare(app) == .orderedSame && $0.isOnActiveScreen }
        }
        let bothVisible = visibleInvolved.count >= 2
        
        let workflowLower = evaluationContext.workflow.lowercased()
        let isComparisonResearchWorkflow = workflowLower.contains("research") || workflowLower.contains("compare") || workflowLower.contains("comparison")
        let currentSessionResearchFriction = isComparisonResearchWorkflow && bothVisible
        
        let entityLower = evaluationContext.currentEntity.lowercased()
        let entityReferencesBoth = involvedApps.count >= 2 &&
            entityLower.contains(involvedApps[0].lowercased()) &&
            entityLower.contains(involvedApps[1].lowercased())
            
        let isManualInvocation = evaluationContext.sourcePath == "environment"
            || evaluationContext.sourcePath == "manual"
            || evaluationContext.sourcePath == "manual_arrange_panel"

        let helperApps: Set<String> = [
            "Steam Helper", "Control Center", "SystemUIServer", "Dock", "Spotlight", "universalaccessd", "Accessibility", "Notification Center", "Notification Centre"
        ]
        
        let hasHelper = involvedApps.contains { app in
            helperApps.contains { app.caseInsensitiveCompare($0) == .orderedSame } || app.contains("Helper")
        }
        
        let primaryWin = visibleWindows.first { $0.appName.caseInsensitiveCompare(involvedApps.first ?? "") == .orderedSame }
        let secondaryWin = visibleWindows.first { $0.appName.caseInsensitiveCompare(involvedApps.dropFirst().first ?? "") == .orderedSame }
        let alreadyArranged = classifyLayout(primary: primaryWin, secondary: secondaryWin) == "already_arranged"
        
        let activeAppName = WorkspaceRuntimeInventoryProvider.snapshot().frontmostAppName
        let activeWin = visibleWindows.first { $0.appName.caseInsensitiveCompare(activeAppName) == .orderedSame && $0.isOnActiveScreen }
        let activeTitle = activeWin?.title ?? ""
        
        let isShoppingContext = activeTitle.lowercased().contains("amazon") ||
                                activeTitle.lowercased().contains("anker") ||
                                activeAppName.lowercased().contains("amazon") ||
                                activeAppName.lowercased().contains("anker")
        
        var isShoppingContextBlocked = false
        if isShoppingContext && involvedApps.count >= 2 {
            let otherApp = involvedApps.first(where: { $0.caseInsensitiveCompare(activeAppName) != .orderedSame }) ?? ""
            if otherApp.caseInsensitiveCompare("Preview") == .orderedSame && switches < 2 {
                isShoppingContextBlocked = true
            }
        }
        
        // Target Validity Required check
        let targetValidity = (involvedApps.count >= 2 && !hasHelper && !alreadyArranged && !isShoppingContextBlocked)
        
        // Active Friction Required check
        let activeFriction = recentAlternation || hasComparisonIntent || currentSessionResearchFriction || entityReferencesBoth || evaluationContext.hasExplicitUsageSignal || isManualInvocation
        
        let visibilitySupport = bothVisible ? "yes" : "no"
        let allowed = targetValidity && activeFriction
        
        print("[ArrangeRequirement] target_validity=\(targetValidity ? "pass" : "fail") active_friction=\(activeFriction ? "pass" : "fail") visibility_support=\(visibilitySupport) allowed=\(allowed ? "yes" : "no")")
        
        if hasHelper {
            print("[ArrangeRequirement] blocked reason=helper_app_pair")
            return (false, "helper_app_pair", "none", "helper_app_pair", true)
        }
        if alreadyArranged {
            print("[ArrangeRequirement] blocked reason=already_arranged")
            return (false, "already_arranged", "none", "already_arranged", true)
        }
        if isShoppingContextBlocked {
            print("[ArrangeRequirement] blocked reason=unrelated_context")
            return (false, "unrelated_context", "none", "unrelated_context", true)
        }
        
        if !allowed {
            let blockReason: String
            if bothVisible {
                blockReason = "visibility_only_no_friction"
            } else {
                blockReason = "no_recent_pair"
            }
            print("[ArrangeRequirement] blocked reason=\(blockReason)")
            return (false, blockReason, "none", blockReason, true)
        }
        
        let passedReason: String
        if switches >= 2 {
            passedReason = "recent_exact_pair_alternation"
        } else if hasComparisonIntent || currentSessionResearchFriction || entityReferencesBoth {
            passedReason = "explicit_comparison_intent"
        } else {
            passedReason = "source_transfer_between_targets"
        }
        
        print("[ArrangeRequirement] passed reason=\(passedReason)")
        return (true, "requirements_passed", passedReason, nil, true)
    }
}
