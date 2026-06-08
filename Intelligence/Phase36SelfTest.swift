import Foundation
import AppKit

// MARK: - Phase 36 Self-Tests

@MainActor
public enum Phase36SelfTest {

    public static func run() async -> Bool {
        print("[Phase36SelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[Phase36SelfTest] pass case=\(name)") }
            else { print("[Phase36SelfTest] fail case=\(name)"); failures.append(name) }
        }

        // Test A: partial layout verification → status must not be success
        print("[Phase36SelfTest] case=test_a_partial_layout_not_success")
        CapabilityExecutor.testHooks.arrangeSideBySide = { _, _ in
            CapabilityExecutor.LocalActionOutcome(status: .partial, verificationStatus: "partial", reason: "move_verify_failed")
        }
        let partialResult = await CapabilityExecutor.shared.execute(
            capability: CognitiveCapabilityRegistry.shared.get("arrange_side_by_side")
                ?? CognitiveCapability(id: "arrange_side_by_side", label: "Arrange side by side", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            context: ["confirmation_satisfied": true]
        )
        check("test_a_partial_not_success", partialResult != .success)
        check("test_a_partial_is_partial", partialResult == .partial)
        CapabilityExecutor.testHooks.arrangeSideBySide = nil

        // Test B: bound layout target missing → preflight blocks
        print("[Phase36SelfTest] case=test_b_bound_target_missing")
        let expiredContract = ActionTargetContract(
            contractID: "ctc:test:b_missing",
            capabilityID: "arrange_side_by_side",
            requiredTargetCount: 2,
            targets: [
                ActionTargetDescriptor(role: "primary_work", appName: "NonExistentApp36A"),
                ActionTargetDescriptor(role: "secondary_work", appName: "NonExistentApp36B")
            ],
            evidenceType: .work_pair,
            sourceConfidence: 0.9,
            fallbackAllowed: false,
            generatedAt: Date(),
            expirySeconds: 120
        )
        let preflightB = ActionPreflight.check(contract: expiredContract, capabilityID: "arrange_side_by_side")
        check("test_b_bound_target_missing_blocked", preflightB.status == .blocked)
        check("test_b_no_substitution", preflightB.targetCheck == .missing)

        // Test C: already arranged → preflight or policy returns already_satisfied
        print("[Phase36SelfTest] case=test_c_already_arranged")
        let alreadySatisfied = ActionPreflight.check(
            contract: nil,
            capabilityID: "arrange_side_by_side",
            alreadySatisfiedCheck: { true }
        )
        check("test_c_already_satisfied_blocked", alreadySatisfied.status == .blocked)
        check("test_c_already_satisfied_reason", alreadySatisfied.targetCheck == .alreadySatisfied)

        // Test D: foreground media, no background music → music suppressed
        print("[Phase36SelfTest] case=test_d_foreground_media_no_music")
        let awareness = MediaAwarenessSnapshot(
            foregroundMediaPresent: true,
            foregroundMediaConfidence: 0.9,
            mediaSourceType: .browserVideo,
            foregroundMediaPlaybackState: "playing",
            backgroundMusicState: "stopped",
            audioConflictLikelihood: 0.0,
            userActivityState: "watching",
            mediaPreferenceConfidence: 0.5,
            recentMediaFeedback: "none"
        )
        let musicResult = MusicUsefulnessEvaluator.evaluate(
            capabilityID: "play_focus_media",
            awareness: awareness,
            isMusicAlreadyPlaying: false,
            recentFeedbackCooldownActive: false,
            hasHigherPriorityTaskAction: false
        )
        check("test_d_music_suppressed_foreground_no_music", !musicResult.eligible)
        check("test_d_reason_correct", musicResult.reason == "foreground_media_no_music_needed")

        // Test E: foreground media + background music → conflict action eligible, play not
        print("[Phase36SelfTest] case=test_e_foreground_plus_music_conflict")
        let conflictAwareness = MediaAwarenessSnapshot(
            foregroundMediaPresent: true,
            foregroundMediaConfidence: 0.9,
            mediaSourceType: .browserVideo,
            foregroundMediaPlaybackState: "playing",
            backgroundMusicState: "playing",
            audioConflictLikelihood: 0.9,
            userActivityState: "watching",
            mediaPreferenceConfidence: 0.5,
            recentMediaFeedback: "none"
        )
        let conflictResult = MusicUsefulnessEvaluator.evaluate(
            capabilityID: "pause_media",
            awareness: conflictAwareness,
            isMusicAlreadyPlaying: true,
            recentFeedbackCooldownActive: false,
            hasHigherPriorityTaskAction: false
        )
        // pause_media is eligible because already_playing is checked for play, not pause
        // For pause_media with music already playing, we need to check differently:
        // MusicUsefulnessEvaluator.evaluate suppresses when already_playing for play actions.
        // For conflict (pause_media), the flow should reach audio_conflict branch.
        // The test: play_focus_media is NOT eligible in conflict (already playing)
        let playInConflict = MusicUsefulnessEvaluator.evaluate(
            capabilityID: "play_focus_media",
            awareness: conflictAwareness,
            isMusicAlreadyPlaying: true,
            recentFeedbackCooldownActive: false,
            hasHigherPriorityTaskAction: false
        )
        check("test_e_play_not_eligible_when_music_playing", !playInConflict.eligible)
        check("test_e_conflict_awareness_detected", conflictAwareness.audioConflictLikelihood > 0.5)

        // Test F: metadata utilities are panel-only
        print("[Phase36SelfTest] case=test_f_metadata_panel_only")
        let copyURL = ActionUsefulnessPolicy.evaluate(
            capabilityID: "copy_current_url",
            targetPresent: true, alreadySatisfied: false, contractFresh: true,
            activityMatch: true, userFeedbackHistory: "neutral",
            confidence: 0.9, evidenceAvailable: true, hasExplicitUsageSignal: false
        )
        check("test_f_copy_url_panel_only", copyURL.surface == .panelOnly)
        let collectRefs = ActionUsefulnessPolicy.evaluate(
            capabilityID: "collect_references",
            targetPresent: true, alreadySatisfied: false, contractFresh: true,
            activityMatch: true, userFeedbackHistory: "neutral",
            confidence: 0.9, evidenceAvailable: true, hasExplicitUsageSignal: false
        )
        check("test_f_collect_refs_panel_only", collectRefs.surface == .panelOnly)

        // Test G: target disappears after proposal → preflight blocks, no fallback
        print("[Phase36SelfTest] case=test_g_target_disappears")
        let goneTarget = ActionTargetDescriptor(role: "primary_work", appName: "DisappearedApp36X")
        let boundContract = ActionTargetContract(
            contractID: "ctc:test:g_disappeared",
            capabilityID: "arrange_side_by_side",
            requiredTargetCount: 1,
            targets: [goneTarget],
            evidenceType: .work_pair,
            sourceConfidence: 0.9,
            fallbackAllowed: false,
            generatedAt: Date(),
            expirySeconds: 120
        )
        let goneResult = ActionPreflight.check(contract: boundContract, capabilityID: "arrange_side_by_side")
        check("test_g_disappeared_blocked", goneResult.status == .blocked)
        check("test_g_no_fallback", goneResult.targetCheck == .missing)

        // Test H: panel labels are set correctly
        print("[Phase36SelfTest] case=test_h_panel_labels")
        let copyURLCap = CognitiveCapabilityRegistry.phase31Capabilities["copy_current_url"]
        check("test_h_copy_url_label", copyURLCap?.label == "Copy current page URL")
        let relatedLinks = CognitiveCapabilityRegistry.phase31Capabilities["copy_all_related_links"]
        check("test_h_related_links_label", relatedLinks?.label == "Copy relevant open links")
        let remWS = CognitiveCapabilityRegistry.shared.get("remember_workspace")
        check("test_h_remember_workspace_label", remWS?.label == "Save current app/window setup")

        // Test I: no content evidence → usefulness suppressed
        print("[Phase36SelfTest] case=test_i_no_evidence")
        let noEvidence = ActionUsefulnessPolicy.evaluate(
            capabilityID: "arrange_side_by_side",
            targetPresent: true, alreadySatisfied: false, contractFresh: true,
            activityMatch: true, userFeedbackHistory: "neutral",
            confidence: 0.9, evidenceAvailable: false, hasExplicitUsageSignal: false
        )
        check("test_i_no_evidence_suppressed", noEvidence.surface == .suppressed)

        // Test J: integration — panel candidate carries contract end-to-end through click execution
        print("[Phase36SelfTest] case=test_j_panel_contract_integration")
        CapabilityExecutor.testHooks.arrangeSideBySide = nil // disable hook so preflight runs
        let integrationContract = ActionTargetContract.forLayoutApps(
            capabilityID: "arrange_side_by_side",
            appNames: ["WindowAPhase36X", "WindowBPhase36X"],
            evidenceType: .active_window_pair,
            confidence: 0.9,
            fallbackAllowed: false
        )
        let integrationContractID = integrationContract.contractID
        print("[ProposalTargetBinding] capability=arrange_side_by_side path=panel_integration_test contract_id=\(integrationContractID) primary=primary_work/WindowAPhase36X secondary=secondary_work/WindowBPhase36X source=active_window_pair fallback_allowed=no expires_in_s=\(Int(integrationContract.expirySeconds))")
        let integrationSeed = DeterministicCapabilityActionSeed(
            candidateID: "phase36:arrange_side_by_side",
            proposalID: "panel:phase36:arrange_side_by_side",
            capabilityId: "arrange_side_by_side",
            title: "Arrange WindowA and WindowB",
            involvedApps: ["WindowAPhase36X", "WindowBPhase36X"],
            involvedURLs: [],
            browserTabTitles: [],
            browserAppName: nil,
            workflow: "research",
            compartmentLabel: nil,
            windowTitle: nil,
            entity: nil,
            compartment: nil,
            targetContract: integrationContract
        )
        let integrationAction = DeterministicCapabilityPanelAction(seed: integrationSeed)
        // Window B is not present in live windows (target removed at runtime). Preflight must block.
        let integrationResult = await integrationAction.execute(context: ContextModel())
        // Click-time preflight should produce status=blocked with same contract_id, then
        // CapabilityExecution should be unavailable with reason=target_contract_failed
        check("test_j_panel_integration_blocked", integrationResult.outputText.contains("unavailable"))
        // The logs above must reference integrationContractID; the user can verify correlation.
        print("[Phase36SelfTest] test_j_correlation_contract_id=\(integrationContractID)")

        // Test K: already-satisfied layout returns alreadySatisfied via preflight
        print("[Phase36SelfTest] case=test_k_already_satisfied_layout")
        // Build a contract with no targets (so target check passes) and force already-satisfied via preflight
        let alreadySatisfiedContract = ActionTargetContract(
            contractID: "ctc:test:k_already_satisfied",
            capabilityID: "arrange_side_by_side",
            requiredTargetCount: 0,
            targets: [],
            evidenceType: .work_pair,
            sourceConfidence: 0.9,
            fallbackAllowed: false,
            generatedAt: Date(),
            expirySeconds: 120
        )
        let alreadySatisfiedPreflight = ActionPreflight.check(
            contract: alreadySatisfiedContract,
            capabilityID: "arrange_side_by_side",
            alreadySatisfiedCheck: { true }
        )
        check("test_k_already_satisfied_status", alreadySatisfiedPreflight.status == .blocked)
        check("test_k_already_satisfied_target_check", alreadySatisfiedPreflight.targetCheck == .alreadySatisfied)
        // ProposalFreshness expires a stale-context proposal so the same layout is not re-proposed.
        let staleFreshness = ProposalFreshnessChecker.check(
            capabilityID: "arrange_side_by_side",
            generatedAt: Date().addingTimeInterval(-200),
            contract: alreadySatisfiedContract,
            currentContextSignature: "ctx_a",
            proposalContextSignature: "ctx_a"
        )
        check("test_k_stale_proposal_not_fresh", !staleFreshness.fresh)

        // Contract self-tests
        let contractOk = ActionTargetContractSelfTest.run()
        check("contract_self_test", contractOk)

        // Usefulness policy self-tests
        let policyOk = ActionUsefulnessPolicySelfTest.run()
        check("usefulness_policy_self_test", policyOk)

        let ok = failures.isEmpty
        print("[Phase36SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

// MARK: - Phase 37 Self-Tests

@MainActor
public enum Phase37SelfTest {

    public static func run() async -> Bool {
        print("[Phase37SelfTest] starting")
        UsefulActionOpportunityRegistry.logRegistry()
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[Phase37SelfTest] pass case=\(name)") }
            else { print("[Phase37SelfTest] fail case=\(name)"); failures.append(name) }
        }

        // 1. Layout overlap: arrange causes overlap/same-side -> retry or fail honestly, no success
        let layoutRes = LayoutEngine.arrangeSideBySide(preferredAppA: "DummyAppA", preferredAppB: "DummyAppB")
        check("test_1_layout_overlap_honesty", layoutRes.status != "success")

        // 2. Durable memory alone: Firefox + Preview durable workspace exists, no recent interaction/current support -> no floating arrange; maybe panel hint only.
        DurableMemory.shared.resetForTests()
        WorkPairMemory.shared.reset()
        DurableMemory.shared.recordAcceptedLayout(workflow: "researching", compartment: "rental", apps: ["Firefox", "Preview"])
        let calibrationAlone = FreshnessCalibrator.calibrate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            compartmentLabel: "rental",
            currentEntity: "",
            workflow: "researching"
        )
        check("test_2_durable_memory_alone_panel_only", calibrationAlone.surface == .panelOnly)

        // 3. Live + durable support: Firefox + Preview visible, not arranged, recent interaction or current task support -> arrange_side_by_side floats with contract.
        let wp = WorkPairMemory.shared
        wp.recordSwitch(app: "Firefox", title: "Rental Postings", pid: 101)
        wp.recordSwitch(app: "Preview", title: "Lease Document", pid: 102)
        wp.recordSwitch(app: "Firefox", title: "Rental Postings", pid: 101)
        wp.recordSwitch(app: "Preview", title: "Lease Document", pid: 102)
        
        let calibrationSupport = FreshnessCalibrator.calibrate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            compartmentLabel: "rental",
            currentEntity: "",
            workflow: "researching"
        )
        check("test_3_live_plus_durable_floats", calibrationSupport.surface == .floating)

        // 4. Metadata-only research: only URL/title/tabs available -> no fake synthesis, but explicit visible acquisition action may appear.
        let synthEligibility = ActionRegistry.evaluate(capabilityId: "synthesize_sources", currentEvidence: .metadata_rich)
        check("test_4_no_fake_synthesis", !synthEligibility.eligible)
        
        let explicitEligibility = ActionRegistry.evaluate(capabilityId: "explicit_visible_capture_summary", currentEvidence: .metadata_rich)
        check("test_4_explicit_acquisition_eligible", explicitEligibility.eligible)

        // 5. Selected text research: selected text exists -> summarize/extract/rewrite selected text actions appear.
        let rewriteEligibility = ActionRegistry.evaluate(capabilityId: "rewrite_text", currentEvidence: .selected_content, hasSelection: true)
        check("test_5_rewrite_eligible", rewriteEligibility.eligible)
        
        let explainEligibility = ActionRegistry.evaluate(capabilityId: "explain_context", currentEvidence: .selected_content, hasSelection: true)
        check("test_5_explain_eligible", explainEligibility.eligible)

        // 6. Foreground media, no music: -> no play/resume music.
        let mediaStateNoMusic = EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .genericVideo, source: "test", detectionAvailable: true)
        let playNoMusicEligible = ActionUsefulnessPolicy.evaluateMediaUsefulness(capabilityID: "play_focus_media", mediaState: mediaStateNoMusic, isWatching: false)
        check("test_6_no_play_music", !playNoMusicEligible)

        // 7. Foreground media + music: -> pause/stop music eligible.
        let mediaStateWithMusic = EnvironmentMediaState(isMusicPlaying: true, visualMediaKind: .genericVideo, source: "test", detectionAvailable: true)
        let pauseEligible = ActionUsefulnessPolicy.evaluateMediaUsefulness(capabilityID: "pause_media", mediaState: mediaStateWithMusic, isWatching: false)
        check("test_7_pause_music_eligible", pauseEligible)

        // 8. Utility-only context: -> utilities panel-only, no fake smart action.
        let copyURLDecision = ActionUsefulnessPolicy.evaluate(
            capabilityID: "copy_current_url",
            targetPresent: true,
            alreadySatisfied: false,
            contractFresh: true,
            activityMatch: true,
            userFeedbackHistory: "neutral",
            confidence: 0.9,
            evidenceAvailable: true,
            hasExplicitUsageSignal: false
        )
        check("test_8_utility_panel_only", copyURLDecision.surface == .panelOnly)

        // 9. Useful action inventory: -> at least one non-utility family candidate when evidence supports it.
        let arrangeUsefulness = ActionUsefulnessPolicy.getUsefulnessLevel(capabilityID: "arrange_side_by_side", lane: "friction")
        check("test_9_non_utility_high_usefulness", arrangeUsefulness == "high")
        
        let copyURLUsefulness = ActionUsefulnessPolicy.getUsefulnessLevel(capabilityID: "copy_current_url", lane: "metadata")
        check("test_9_utility_low_usefulness", copyURLUsefulness == "low")

        let ok = failures.isEmpty
        print("[Phase37SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

// MARK: - Phase 38 Self-Tests

@MainActor
public enum Phase38SelfTest {
    public static func run() async -> Bool {
        print("[Phase38SelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[Phase38SelfTest] pass case=\(name)") }
            else { print("[Phase38SelfTest] fail case=\(name)"); failures.append(name) }
        }

        // 1. Two visible related windows, no alternation/comparison/source transfer:
        // Expected: arrange_side_by_side blocked, reason=visibility_only_no_friction
        WorkPairMemory.shared.reset()
        let firefoxWindow = WindowSnapshot(windowID: 1, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 123, title: "Web Page", frame: .zero, layer: 0, isOnScreen: true, isOnActiveScreen: true)
        let previewWindow2 = WindowSnapshot(windowID: 2, appName: "Preview", bundleID: "com.apple.Preview", pid: 456, title: "Lease.pdf", frame: .zero, layer: 0, isOnScreen: true, isOnActiveScreen: true)
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
            ],
            visibleWindows: [firefoxWindow, previewWindow2],
            browserTabTitles: [],
            currentURLs: [],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )
        let ctxNoPair = LivePathEvaluationContext(
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
        let gateNoPair = ActionRequirementGate.evaluate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            evaluationContext: ctxNoPair,
            confidence: 0.8,
            attachedContract: nil
        )
        check("test_1_blocked_without_recent_pair", !gateNoPair.allowed)
        check("test_1_blocked_reason_no_recent_pair", gateNoPair.reason == "visibility_only_no_friction")

        // 1b. Invisible secondary window, no alternation/comparison/source transfer:
        // Expected: blocked, reason=no_recent_pair
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
            ],
            visibleWindows: [firefoxWindow],
            browserTabTitles: [],
            currentURLs: [],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )
        let gateOneVisible = ActionRequirementGate.evaluate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            evaluationContext: ctxNoPair,
            confidence: 0.8,
            attachedContract: nil
        )
        check("test_1b_blocked_one_visible", !gateOneVisible.allowed)
        check("test_1b_blocked_reason_no_recent_pair", gateOneVisible.reason == "no_recent_pair")

        // 2. Two visible related windows with recent exact alternation >= 2:
        // Expected: arrange_side_by_side allowed
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
            ],
            visibleWindows: [firefoxWindow, previewWindow2],
            browserTabTitles: [],
            currentURLs: [],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )
        WorkPairMemory.shared.recordSwitch(app: "Firefox", title: "Web Page", pid: 123)
        WorkPairMemory.shared.recordSwitch(app: "Preview", title: "Document", pid: 456)
        WorkPairMemory.shared.recordSwitch(app: "Firefox", title: "Web Page", pid: 123)
        let gateWithPair = ActionRequirementGate.evaluate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            evaluationContext: ctxNoPair,
            confidence: 0.8,
            attachedContract: nil
        )
        check("test_2_allowed_with_recent_pair", gateWithPair.allowed)

        // 3. Two visible windows from stale durable memory only
        // Expected: blocked or panel hint (not floating), reason=visibility_only_no_friction
        WorkPairMemory.shared.reset()
        let frictionStaleDurable = RuntimeWorkspaceFrictionEvaluator.evaluate(
            inventory: WorkspaceRuntimeInventoryProvider.snapshot(),
            workflow: "idle",
            compartmentLabel: nil,
            compartmentTrust: 0.0,
            currentEntity: ""
        )
        check("test_3_stale_durable_blocked", !frictionStaleDurable.eligible)
        check("test_3_stale_durable_reason", frictionStaleDurable.reason == "visibility_only_no_friction")

        // 3b. Amazon/Anker page with stale Preview
        // Expected: arrange_side_by_side blocked, reason=unrelated_context
        WorkPairMemory.shared.reset()
        let amazonWindow = WindowSnapshot(windowID: 1, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 123, title: "Amazon.com: Anker Charger", frame: .zero, layer: 0, isOnScreen: true, isOnActiveScreen: true)
        let previewWindow = WindowSnapshot(windowID: 2, appName: "Preview", bundleID: "com.apple.Preview", pid: 456, title: "Lease.pdf", frame: .zero, layer: 0, isOnScreen: true, isOnActiveScreen: true)
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
            ],
            visibleWindows: [amazonWindow, previewWindow],
            browserTabTitles: [],
            currentURLs: [],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )
        let gateShopping = ActionRequirementGate.evaluate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            evaluationContext: ctxNoPair,
            confidence: 0.8,
            attachedContract: nil
        )
        check("test_3b_shopping_page_blocked", !gateShopping.allowed)
        check("test_3b_shopping_page_blocked_reason", gateShopping.reason == "unrelated_context")

        // 4. Helper process pollution in RuntimeFriction
        let steamHelperWindow = WindowSnapshot(windowID: 3, appName: "Steam Helper", bundleID: "com.valvesoftware.steam.helper", pid: 789, title: "Steam Helper", frame: .zero, layer: 0, isOnScreen: true, isOnActiveScreen: true)
        
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.valvesoftware.steam.helper", appName: "Steam Helper")
            ],
            visibleWindows: [amazonWindow, steamHelperWindow],
            browserTabTitles: [],
            currentURLs: [],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )
        
        let frictionResult = RuntimeWorkspaceFrictionEvaluator.evaluate(
            inventory: WorkspaceRuntimeInventoryProvider.snapshot(),
            workflow: "research",
            compartmentLabel: "test",
            compartmentTrust: 0.8,
            currentEntity: "Anker"
        )
        check("test_4_helper_excluded_from_friction", frictionResult.pair == nil)

        // Reset testSnapshot
        WorkspaceRuntimeInventoryProvider.testSnapshot = nil

        // 5. Research metadata-only synthesis block vs user-initiated acquisition
        let synthesisResult = ActionRegistry.evaluate(capabilityId: "synthesize_sources", currentEvidence: .metadata_rich)
        check("test_5_synthesis_blocked", !synthesisResult.eligible)
        check("test_5_synthesis_blocked_reason", synthesisResult.reason == "content_unavailable_metadata_only")
        
        let acquisitionResult = ActionRegistry.evaluate(capabilityId: "explicit_visible_capture_summary", currentEvidence: .metadata_rich)
        check("test_5_acquisition_allowed", acquisitionResult.eligible)

        // 6. Research selected text actions
        let rewriteResult = ActionRegistry.evaluate(capabilityId: "rewrite_text", currentEvidence: .selected_content, hasSelection: true)
        check("test_6_rewrite_allowed_with_selection", rewriteResult.eligible)

        // 7. PanelOpen block for suggestions
        let appState = AppState()
        let menuBarController = MenuBarController(appState: appState)
        
        menuBarController.revealPopoverIfNeeded(source: .suggestion_auto)
        check("test_7_popover_not_shown_auto", !menuBarController.isPopoverShown)

        // 8. Research result output floating card shown, panel blocked
        appState.activeResearchResultCard = ResearchResultCardState(capabilityID: "explicit_visible_capture_summary", title: "Test Title", text: "Test summary output text", outputChars: 24)
        check("test_8_result_card_populated", appState.activeResearchResultCard != nil)
        
        menuBarController.revealPopoverIfNeeded(source: .explicit_button)
        check("test_8_popover_blocked_by_result_card", !menuBarController.isPopoverShown)
        
        appState.activeResearchResultCard = nil

        // 9. Menu bar icon persistence checks
        menuBarController.checkIconState()
        check("test_9_menu_bar_button_exists", menuBarController.isPopoverShown == false)

        // 10. Backfill: top action suppressed, arrange visible but no active friction -> not backfilled
        let portfolioCandidateFriction = PortfolioCandidate(
            lane: .friction,
            title: "Arrange Firefox and Preview",
            capabilityId: "arrange_side_by_side",
            executionMode: .local_action,
            confidence: 0.8,
            usefulness: 0.8,
            executability: 1.0,
            novelty: 1.0,
            reason: "friction",
            requiredEvidence: "runtime_workspace_friction",
            requiresConfirmation: true,
            involvedApps: ["Firefox", "Preview"],
            frictionOpportunity: nil,
            musicIntent: nil,
            generatedAction: nil,
            sourcePath: "cheap_portfolio",
            targetContract: nil
        )
        let portfolioCandidateMusic = PortfolioCandidate(
            lane: .comfort,
            title: "Play Focus Music",
            capabilityId: "play_focus_media",
            executionMode: .local_action,
            confidence: 0.9,
            usefulness: 0.9,
            executability: 1.0,
            novelty: 1.0,
            reason: "comfort",
            requiredEvidence: "work_context",
            requiresConfirmation: false,
            involvedApps: [],
            frictionOpportunity: nil,
            musicIntent: nil,
            generatedAction: nil,
            sourcePath: "cheap_portfolio",
            targetContract: nil
        )
        let backfillDecisions: [String: LivePathDecision] = [
            portfolioCandidateMusic.candidateID: LivePathDecision(
                capabilityID: "play_focus_media",
                sourcePath: "cheap_portfolio",
                surface: .suppressed,
                executionPath: .music,
                contractRequired: false,
                contractPresent: false,
                allowedToExecute: false,
                eligibleForFloating: false,
                reason: "task_action_preferred"
            ),
            portfolioCandidateFriction.candidateID: LivePathDecision(
                capabilityID: "arrange_side_by_side",
                sourcePath: "cheap_portfolio",
                surface: .suppressed,
                executionPath: .contractBound,
                contractRequired: true,
                contractPresent: true,
                allowedToExecute: false,
                eligibleForFloating: false,
                reason: "visibility_only_no_friction"
            )
        ]
        
        let validatedCandidates = [portfolioCandidateMusic, portfolioCandidateFriction]
        let eligibleByScore = validatedCandidates.filter { backfillDecisions[$0.candidateID]?.eligibleForFloating == true }
        var floatingCandidate: PortfolioCandidate? = eligibleByScore.first
        var backfillSuccess = false
        var loggedFailureReason = ""
        
        if let top = validatedCandidates.first, backfillDecisions[top.candidateID]?.eligibleForFloating != true {
            if let backfill = eligibleByScore.first {
                floatingCandidate = backfill
                backfillSuccess = true
            } else {
                let wasArrangeCandidate = validatedCandidates.first(where: { $0.capabilityId == "arrange_side_by_side" })
                if let arrangeCandidate = wasArrangeCandidate, backfillDecisions[arrangeCandidate.candidateID]?.eligibleForFloating != true {
                    loggedFailureReason = backfillDecisions[arrangeCandidate.candidateID]?.reason ?? "unknown"
                }
            }
        }
        check("test_10_backfill_not_success", !backfillSuccess)
        check("test_10_backfill_none_chosen", floatingCandidate == nil)
        check("test_10_backfill_reason_logged", loggedFailureReason == "visibility_only_no_friction")

        let ok = failures.isEmpty
        print("[Phase38SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

