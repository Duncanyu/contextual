import Foundation

// MARK: - Phase 36.1 Live Path Regression Tests
//
// These tests prove that the live path enforces:
//   A. metadata utility highest score -> panel only, no floating winner
//   B. pin_reference_tabs high score -> panel_only, never floating winner
//   C. arrange_side_by_side visible action without contract -> blocked before execution
//   D. arrange_side_by_side with contract and missing target -> blocked, no runtime fallback
//   E. play_focus_media in weak/unknown context -> suppressed/panel_only, not floating
//   F. final selection ignores panel-only candidates for floating

@MainActor
public enum Phase361LivePathSelfTest {

    public static func run() async -> Bool {
        print("[Phase361LivePathSelfTest] starting")
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
            if ok { print("[Phase361LivePathSelfTest] pass case=\(name)") }
            else { print("[Phase361LivePathSelfTest] fail case=\(name)"); failures.append(name) }
        }

        let stable = LivePathEvaluationContext(
            sourcePath: "regression_test",
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

        // ── A. Metadata utility highest score → panel_only, no floating ─────
        print("[Phase361LivePathSelfTest] case=a_metadata_highest_score_panel_only")
        let (copyURL, _) = LivePathEnforcer.evaluate(
            capabilityID: "copy_current_url",
            involvedApps: ["Browser"],
            attachedContract: nil,
            confidence: 0.99,
            evaluationContext: stable
        )
        check("a_copy_url_surface_panel_only", copyURL.surface == .panelOnly)
        check("a_copy_url_not_floating", !copyURL.eligibleForFloating)
        check("a_copy_url_reason_metadata", copyURL.reason == "metadata_utility_low_interrupt")

        let (collect, _) = LivePathEnforcer.evaluate(
            capabilityID: "collect_references",
            involvedApps: ["Browser"],
            attachedContract: nil,
            confidence: 0.99,
            evaluationContext: stable
        )
        check("a_collect_refs_panel_only", collect.surface == .panelOnly)
        check("a_collect_refs_not_floating", !collect.eligibleForFloating)

        // ── B. pin_reference_tabs high score but no verified browser-state contract ──
        print("[Phase361LivePathSelfTest] case=b_pin_reference_tabs_panel_only")
        let (pin, _) = LivePathEnforcer.evaluate(
            capabilityID: "pin_reference_tabs",
            involvedApps: ["Browser"],
            attachedContract: nil,
            confidence: 0.95,
            evaluationContext: stable
        )
        check("b_pin_surface_panel_only", pin.surface == .panelOnly)
        check("b_pin_never_floating", !pin.eligibleForFloating)
        check("b_pin_reason_unverified", pin.reason == "unverified_browser_state_change")

        // ── C. arrange_side_by_side visible action without contract → blocked at executor ──
        print("[Phase361LivePathSelfTest] case=c_arrange_without_contract_blocked_at_executor")
        let arrangeCap = CognitiveCapability(
            id: "arrange_side_by_side",
            label: "Arrange side by side",
            inputRequirements: [],
            outputType: "system_action",
            evidenceThreshold: "none",
            riskLevel: .light_action,
            requiresConfirmation: true,
            executionMode: .local_action
        )
        CapabilityExecutor.testHooks.arrangeSideBySide = nil
        let executorResult = await CapabilityExecutor.shared.execute(
            capability: arrangeCap,
            context: ["confirmation_satisfied": true, "apps": ["UnknownAppX", "UnknownAppY"]]
        )
        check("c_executor_blocks_without_contract", executorResult == .unavailable)

        // ── D. arrange_side_by_side with contract and missing target → blocked, no runtime fallback ──
        // Phase 51 — stage a verified work pair so the proactive gate passes and the
        // CONTRACT preflight is what blocks (the behavior under test).
        print("[Phase361LivePathSelfTest] case=d_arrange_with_contract_missing_target_blocked")
        WorkPairMemory.shared.reset()
        WorkPairMemory.shared.recordSwitch(app: "DefinitelyMissing361A", title: "A", pid: 99101)
        WorkPairMemory.shared.recordSwitch(app: "DefinitelyMissing361B", title: "B", pid: 99102)
        WorkPairMemory.shared.recordSwitch(app: "DefinitelyMissing361A", title: "A", pid: 99101)
        let missingContract = ActionTargetContract.forLayoutApps(
            capabilityID: "arrange_side_by_side",
            appNames: ["DefinitelyMissing361A", "DefinitelyMissing361B"],
            evidenceType: .active_window_pair,
            confidence: 0.9,
            fallbackAllowed: false
        )
        let withContractResult = await CapabilityExecutor.shared.execute(
            capability: arrangeCap,
            context: [
                "confirmation_satisfied": true,
                "apps": ["DefinitelyMissing361A", "DefinitelyMissing361B"],
                "targetContract": missingContract as Any
            ]
        )
        WorkPairMemory.shared.reset()
        check("d_with_contract_missing_target_blocked", withContractResult == .unavailable)

        // ── E. play_focus_media in weak/unknown context → suppressed ──
        print("[Phase361LivePathSelfTest] case=e_music_weak_context_suppressed")
        let weakCtx = LivePathEvaluationContext(
            sourcePath: "regression_test",
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
        // Focus-music revision — a FORMED focus context (stability "weak", not the
        // flickering "transient") now floats music instead of burying it in the
        // panel during sustained focus work. Only truly transient/low-confidence
        // context stays panel-only (asserted by the transient case below).
        check("e_music_weak_surface_floating", musicWeak.surface == .floating)
        check("e_music_weak_floating_eligible", musicWeak.eligibleForFloating)
        check("e_music_weak_reason", musicWeak.reason == "stable_work_context_no_higher_priority")

        let transientCtx = LivePathEvaluationContext(
            sourcePath: "regression_test",
            contextStability: "transient",
            isMusicAlreadyPlaying: false,
            hasHigherPriorityTaskAction: false,
            recentFeedbackCooldownActive: false,
            userFeedbackHistory: "neutral",
            alreadySatisfied: false,
            evidenceAvailable: true,
            hasExplicitUsageSignal: false,
            activityMatch: true
        )
        let (musicTransient, _) = LivePathEnforcer.evaluate(
            capabilityID: "play_focus_media",
            involvedApps: [],
            attachedContract: nil,
            confidence: 0.9,
            evaluationContext: transientCtx
        )
        check("e_music_transient_not_floating", !musicTransient.eligibleForFloating)

        // ── F. Final selection ignores panel-only candidates for floating ──
        print("[Phase361LivePathSelfTest] case=f_final_selection_skips_panel_only")
        // Simulate a slate of candidates where the highest-scoring is a metadata utility
        // (panel-only). The floating winner must NOT be that candidate.
        let candidateIDs = [
            ("copy_current_url", 0.99),
            ("collect_references", 0.95),
            ("pin_reference_tabs", 0.90),
            ("arrange_side_by_side", 0.60)
        ]
        var anyMetadataFloating = false
        var anyPinFloating = false
        for (id, conf) in candidateIDs {
            let involved: [String] = (id == "arrange_side_by_side") ? ["Firefox", "Preview"] : ["Browser"]
            let (decision, _) = LivePathEnforcer.evaluate(
                capabilityID: id,
                involvedApps: involved,
                attachedContract: nil,
                confidence: conf,
                evaluationContext: stable
            )
            if id == "copy_current_url" || id == "collect_references" {
                if decision.eligibleForFloating { anyMetadataFloating = true }
            }
            if id == "pin_reference_tabs" {
                if decision.eligibleForFloating { anyPinFloating = true }
            }
            // Print rejected_floating for visual confirmation in logs
            decision.logFinalSelectionCandidate()
        }
        check("f_metadata_not_floating_winner", !anyMetadataFloating)
        check("f_pin_not_floating_winner", !anyPinFloating)

        // The arrange with apps should be eligible (high time saved, contract synthesized).
        // Phase 51 — floating eligibility now requires a verified recent work pair;
        // stage one so the proactive path is what's under test.
        WorkPairMemory.shared.reset()
        WorkPairMemory.shared.recordSwitch(app: "Firefox", title: "Rental Postings", pid: 88801)
        WorkPairMemory.shared.recordSwitch(app: "Preview", title: "Lease Document", pid: 88802)
        WorkPairMemory.shared.recordSwitch(app: "Firefox", title: "Rental Postings", pid: 88801)
        let (arrange, contract) = LivePathEnforcer.evaluate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            attachedContract: nil,
            confidence: 0.7,
            evaluationContext: stable
        )
        check("f_arrange_with_apps_eligible", arrange.eligibleForFloating)
        check("f_arrange_contract_synthesized", contract != nil)

        let ok = failures.isEmpty
        print("[Phase361LivePathSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
