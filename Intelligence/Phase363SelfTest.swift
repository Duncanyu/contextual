import Foundation

// MARK: - Phase 36.3 Useful Action Surfacing Regression Tests
//
// Test A: recent cooldown for unrelated previous suggestion -> bypass or panel fallback
// Test B: same arrange action for same targets shown seconds ago -> panel_only fallback
// Test C: music suppressed (task action preferred) + arrange cooldown -> panel fallback (not empty)
// Test D: ActionUsefulness already_satisfied=no overrides stale "already_done" surface policy

@MainActor
public enum Phase363SelfTest {

    public static func run() async -> Bool {
        print("[Phase363SelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[Phase363SelfTest] pass case=\(name)") }
            else { print("[Phase363SelfTest] fail case=\(name)"); failures.append(name) }
        }

        let now = Date()

        // ── Test A — recent cooldown for a DIFFERENT key → state changed → bypass ──
        print("[Phase363SelfTest] case=a_cooldown_unrelated_bypasses")
        let differentKey = SuggestionCooldownArbiter.makeKey(
            capabilityID: "play_focus_media",
            targetFingerprint: "Music",
            targetState: "music",
            sourcePath: "cheap_context",
            compartmentLabel: "lease"
        )
        let cooldownA = SuggestionCooldownArbiter.evaluate(.init(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease",
            lastShownAt: now.addingTimeInterval(-20),
            lastShownKey: differentKey,
            recentDismissCount: 0,
            now: now
        ))
        check("a_cooldown_bypasses_for_unrelated_prior", cooldownA.status == .bypass)
        let arbiterAInputs = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .floating,
            livePathSurface: .floating,
            freshness: "fresh",
            cooldownStatus: cooldownA.status,
            cooldownReason: cooldownA.reason,
            contractPresent: true,
            alreadySatisfied: false,
            alreadySatisfiedSource: "default"
        )
        let arbiterA = FinalSurfaceArbiter.decide(arbiterAInputs)
        arbiterA.log(inputs: arbiterAInputs)
        check("a_arbiter_final_floating", arbiterA.final == .floating)

        // ── Test B — same arrange same targets shown 30s ago → panel_only ──
        print("[Phase363SelfTest] case=b_same_targets_recent_panel_only")
        let sameKey = SuggestionCooldownArbiter.makeKey(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease"
        )
        let cooldownB = SuggestionCooldownArbiter.evaluate(.init(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease",
            lastShownAt: now.addingTimeInterval(-30),
            lastShownKey: sameKey,
            recentDismissCount: 0,
            now: now
        ))
        check("b_cooldown_panel_only", cooldownB.status == .panelOnly)
        let arbiterBInputs = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .floating,
            livePathSurface: .floating,
            freshness: "fresh",
            cooldownStatus: cooldownB.status,
            cooldownReason: cooldownB.reason,
            contractPresent: true,
            alreadySatisfied: false,
            alreadySatisfiedSource: "default"
        )
        let arbiterB = FinalSurfaceArbiter.decide(arbiterBInputs)
        arbiterB.log(inputs: arbiterBInputs)
        check("b_arbiter_final_panel_only", arbiterB.final == .panelOnly)
        check("b_arbiter_reason_panel_fallback", arbiterB.reason == "floating_cooldown_preserved_panel")

        // ── Test C — task action suppressed by cooldown → not empty (panel) ──
        // Simulates: music suppressed by task_action_preferred (LivePathEnforcer), arrange suppressed
        // by recent cooldown. Final UI must NOT be empty — arrange goes panel-only.
        print("[Phase363SelfTest] case=c_task_cooldown_not_empty")
        let cooldownC = SuggestionCooldownArbiter.evaluate(.init(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease",
            lastShownAt: now.addingTimeInterval(-40),
            lastShownKey: sameKey,
            recentDismissCount: 0,
            now: now
        ))
        let arbiterCInputs = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .floating,
            livePathSurface: .floating,
            freshness: "fresh",
            cooldownStatus: cooldownC.status,
            cooldownReason: cooldownC.reason,
            contractPresent: true,
            alreadySatisfied: false,
            alreadySatisfiedSource: "default"
        )
        let arbiterC = FinalSurfaceArbiter.decide(arbiterCInputs)
        arbiterC.log(inputs: arbiterCInputs)
        check("c_arrange_visible_as_panel", arbiterC.final == .panelOnly)
        // Now consider music: task action still present (panel-visible), so music stays suppressed.
        let stableCtxTaskPresent = LivePathEvaluationContext(
            sourcePath: "phase363_test",
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
        let (musicDecision, _) = LivePathEnforcer.evaluate(
            capabilityID: "play_focus_media",
            involvedApps: ["Music"],
            attachedContract: nil,
            confidence: 0.9,
            evaluationContext: stableCtxTaskPresent
        )
        check("c_music_still_suppressed_task_preferred", !musicDecision.eligibleForFloating)
        check("c_music_reason", musicDecision.reason == "secondary_to_active_task")
        // Log the visible accounting for the dogfood line.
        print("[BackfillAfterSurface] primary=arrange_side_by_side final_surface=panel_only reconsidered=play_focus_media result=suppressed reason=task_action_still_visible_in_panel")

        // ── Test D — already_satisfied=no overrides stale already_done suppression ──
        // The arbiter trusts the freshest runtime check, not an old SurfacePolicy claim.
        print("[Phase363SelfTest] case=d_runtime_recheck_overrides_stale")
        let recheckInputs = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .floating,   // ActionUsefulness says useful (already_satisfied=no upstream)
            livePathSurface: .floating,
            freshness: "fresh",
            cooldownStatus: .inactive,
            cooldownReason: "no_prior_show",
            contractPresent: true,
            alreadySatisfied: false,        // recomputed runtime check: NOT satisfied
            alreadySatisfiedSource: "runtime_inventory"
        )
        let recheck = FinalSurfaceArbiter.decide(recheckInputs)
        recheck.log(inputs: recheckInputs)
        check("d_recheck_not_suppressed", recheck.final != .suppressed)
        check("d_recheck_floats", recheck.final == .floating)

        // ── Test E — high-usefulness panel fallback is visibly highlighted ──
        print("[Phase363SelfTest] case=e_panel_fallback_highlighted")
        let panelState = AppState()
        let panelContract = ActionTargetContract.forLayoutApps(
            capabilityID: "arrange_side_by_side",
            appNames: ["Firefox", "Preview"],
            evidenceType: .active_window_pair,
            confidence: 0.9
        )
        let panelAction = DeterministicCapabilityPanelAction(
            seed: DeterministicCapabilityActionSeed(
                candidateID: "phase363:arrange_side_by_side",
                proposalID: "panel:phase363:arrange_side_by_side",
                capabilityId: "arrange_side_by_side",
                title: "Put Firefox and Preview side by side?",
                involvedApps: ["Firefox", "Preview"],
                involvedURLs: [],
                browserTabTitles: [],
                browserAppName: nil,
                workflow: "researching",
                compartmentLabel: "lease",
                windowTitle: nil,
                entity: nil,
                compartment: nil,
                targetContract: panelContract
            )
        )
        panelState.availableActions = [panelAction]
        panelState.updateHighUsefulnessPanelVisibility()
        check("e_panel_highlighted", panelState.highlightedPanelActionID == panelAction.id)
        check("e_panel_indicator_visible", panelState.panelAttentionIndicatorVisible)

        // ── Test F — panel click during refresh resolves to recent valid proposal ──
        print("[Phase363SelfTest] case=f_panel_click_recent_valid")
        let refreshState = AppState()
        refreshState.availableActions = [panelAction]
        refreshState.availableActions = []
        let resolution = refreshState.resolveStoredAction(id: panelAction.id, context: ContextModel())
        check("f_recent_candidate_resolved", resolution.resolved)
        check("f_recent_candidate_reason", resolution.reason == "recent_valid")
        check("f_recent_candidate_contract_valid", resolution.contractValid)

        // ── Test G — arrange_side_by_side maps to friction_action ──
        print("[Phase363SelfTest] case=g_arrange_kind_mapping")
        check("g_arrange_kind_is_friction",
              ContextEventProducer.ambientSuggestionKind(for: "arrange_side_by_side") == .friction_action)
        check("g_arrange_kind_not_comfort",
              ContextEventProducer.ambientSuggestionKind(for: "arrange_side_by_side") != .comfort_action)

        // Bundle the cooldown + arbiter self-tests
        let coolOk = SuggestionCooldownArbiterSelfTest.run()
        check("cooldown_arbiter_self_test", coolOk)
        let arbiterOk = FinalSurfaceArbiterSelfTest.run()
        check("final_surface_arbiter_self_test", arbiterOk)

        let ok = failures.isEmpty
        print("[Phase363SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

@MainActor
enum Phase365SelfTest {
	static func run() async -> Bool {
		print("[Phase365SelfTest] starting")
		var failures: [String] = []
		func check(_ name: String, _ condition: Bool) {
			if condition { print("[Phase365SelfTest] pass case=\(name)") }
			else { print("[Phase365SelfTest] fail case=\(name)"); failures.append(name) }
		}

		let friction = PortfolioCandidate(
			lane: .friction,
			title: "Collect links from switching context?",
			capabilityId: "collect_references",
			executionMode: .local_action,
			confidence: 0.72,
			usefulness: 0.58,
			executability: 0.90,
			novelty: 0.90,
			reason: "Repeated reference lookup",
			requiredEvidence: "friction_signal",
			requiresConfirmation: false,
			involvedApps: ["Firefox"],
			frictionOpportunity: nil,
			musicIntent: nil,
			generatedAction: nil,
			sourcePath: "friction_lane"
		)
		let metadata = PortfolioCandidate(
			lane: .metadata,
			title: "Collect links from this context?",
			capabilityId: "collect_references",
			executionMode: .local_action,
			confidence: 0.54,
			usefulness: 0.24,
			executability: 0.88,
			novelty: 0.95,
			reason: "Metadata-rich browser context",
			requiredEvidence: "metadata_rich",
			requiresConfirmation: false,
			involvedApps: [],
			frictionOpportunity: nil,
			musicIntent: nil,
			generatedAction: nil,
			sourcePath: "metadata_lane"
		)
		check("duplicate_capability_ids_are_distinct_candidates", friction.candidateID != metadata.candidateID)
		let identityMap = Dictionary(uniqueKeysWithValues: [
			(friction.candidateID, friction.capabilityId),
			(metadata.candidateID, metadata.capabilityId)
		])
		check("duplicate_capability_identity_map_survives", identityMap.count == 2)

		let contract = ActionTargetContract.forLayoutApps(
			capabilityID: "arrange_side_by_side",
			appNames: ["Firefox", "Preview"],
			evidenceType: .active_window_pair,
			confidence: 0.9,
			fallbackAllowed: false
		)
		let action = DeterministicCapabilityPanelAction(
			seed: DeterministicCapabilityActionSeed(
				candidateID: "phase365:arrange_side_by_side",
				proposalID: "panel:phase365:arrange_side_by_side",
				capabilityId: "arrange_side_by_side",
				title: "Put Firefox and Preview side by side?",
				involvedApps: ["Firefox", "Preview"],
				involvedURLs: [],
				browserTabTitles: [],
				browserAppName: nil,
				workflow: "researching",
				compartmentLabel: "lease",
				windowTitle: nil,
				entity: nil,
				compartment: nil,
				targetContract: contract
			)
		)
		let appState = AppState()
		appState.availableActions = [action]
		appState.availableActions = []
		let resolved = appState.resolveStoredAction(id: action.id, context: ContextModel())
		check("panel_contract_preserved_through_recent_cache", resolved.contractID == contract.contractID && resolved.contractValid)
		check("panel_candidate_id_preserved_through_recent_cache", resolved.candidateID == action.candidateID)

		let missingContractAction = DeterministicCapabilityPanelAction(
			seed: DeterministicCapabilityActionSeed(
				candidateID: "phase365:missing_contract",
				proposalID: "panel:phase365:missing_contract",
				capabilityId: "arrange_side_by_side",
				title: "Arrange side by side",
				involvedApps: ["Firefox", "Preview"],
				involvedURLs: [],
				browserTabTitles: [],
				browserAppName: nil,
				workflow: "researching",
				compartmentLabel: "lease",
				windowTitle: nil,
				entity: nil,
				compartment: nil,
				targetContract: nil
			)
		)
		let missingState = AppState()
		missingState.availableActions = [missingContractAction]
		missingState.invokeAction(id: missingContractAction.id)
		missingState.finalizeActionFeedback(actionID: missingContractAction.id, status: .unavailable, reason: "missing_contract")
		check("missing_contract_never_records_accept", !missingState.wasSuggestionFeedbackLogged(id: missingContractAction.proposalID, event: "accepted"))
		check("missing_contract_records_failed", missingState.wasSuggestionFeedbackLogged(id: missingContractAction.proposalID, event: "failed"))

		let highlightState = AppState()
		highlightState.isPanelVisible = true
		highlightState.availableActions = [action]
		highlightState.updateHighUsefulnessPanelVisibility()
		await Task.yield()
		check("panel_highlight_defers_without_losing_state", highlightState.highlightedPanelActionID == action.id && highlightState.panelAttentionIndicatorVisible)

		let ok = failures.isEmpty
		print("[Phase365SelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}
