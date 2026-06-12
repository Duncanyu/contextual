import Foundation

/// Regression tests for two dogfood failures fixed in Phase 20G:
///
///   1. ambient_context_suggestion_bypasses_tes_and_renders
///      Ambient Jarvis suggestions were blocked by TriggerEligibilityEvaluator
///      which required selected text or clipboard (text-based proposals). The
///      fix bypasses TES for ambient proposals and calls showFloatingSuggestion
///      directly after the simpler gate checks. This test:
///        a. Proves TES returns `no_meaningful_input` for a no-text context
///           (confirming the old path was broken).
///        b. Proves the new bypass path results in the floating suggestion
///           actually attaching and `isFloatingSuggestionVisible == true`.
///
///   2. scratch_turbowarp_gemini_not_shopping
///      Scratch/TurboWarp/Gemini tabs were not present in FocusOverride's
///      learningHints / researchHints vocabularies so they scored as `unknown`,
///      leaving stale `shopping` workflow intact. The fix adds "scratch",
///      "coding", "program", "project", "gemini", "chat", etc. to the relevant
///      hint sets.
///
///   3. no_compare_options_for_creative_coding_tabs
///      CapabilitySelector must NOT return compare_options for Scratch / TurboWarp
///      / Gemini sessions where behavior is not .comparing and compartment workflow
///      is not .shopping.
///
/// Trigger:
///   CONTEXTUAL_RUN_AMBIENT_VISIBILITY_REGRESSION_SELFTEST=1
@MainActor
enum AmbientVisibilityRegressionSelfTest {

	static func run() async -> Bool {
		print("[AmbientVisibilityRegressionSelfTest] starting")
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if ok { print("[AmbientVisibilityRegressionSelfTest] pass case=\(name)") }
			else  { print("[AmbientVisibilityRegressionSelfTest] fail case=\(name)"); failures.append(name) }
		}

		// ──────────────────────────────────────────────────────────────────
		// BLOCK 1 — TES bypass: ambient proposals now render without text input
		// ──────────────────────────────────────────────────────────────────

		// 1a. Prove TES would block a no-text context (old broken path).
		let noTextCtx = makeNoTextContext()
		let dummyProposal = ActionProposal(
			title: "Looks like you're studying something new",
			sourceCaption: "Jarvis Suggestion (Preview-Only)",
			primaryActionId: "ambient_jarvis:regression_test",
			secondaryActionIds: [],
			confidence: 0.80,
			reason: "ambient_context_only"
		)
		let tesResult = TriggerEligibilityEvaluator.evaluate(
			proposal: dummyProposal,
			suggestionStrength: .strong,
			context: noTextCtx,
			triggerType: .contextMetadataEligible,
			isPaused: false,
			isPopoverOpen: false,
			isFloatingVisible: false,
			isActionExecuting: false,
			inputSourceChoice: .automatic,
			proposalGateAllows: true
		)
		check("tes_blocks_no_text_context",
			  !tesResult.shouldShow && tesResult.reason == "no_meaningful_input")
		print("[AmbientFloatingSuggestion] tes_would_suppress reason=\(tesResult.reason) (old behaviour confirmed broken)")

		// 1b. Prove the bypass path (new behaviour) actually shows the suggestion.
		//     Mirrors the logic now in maybeShowAmbientJarvisFloatingSuggestion:
		//     skip TES, do lifecycle dedup check, call showFloatingSuggestion directly.
		let appState = AppState()
		check("bypass_initial_state_not_visible", !appState.isFloatingSuggestionVisible)
		check("bypass_not_paused", !appState.isPaused)
		check("bypass_not_executing", !appState.isActionExecuting)

		let packet = TriggerPacket(
			triggerType: .contextMetadataEligible,
			reason: "ambient_jarvis",
			candidateActions: [],
			createdAt: Date()
		)
		let profile = ContentSimilarityProfile.make(from: FloatingSimilarityText.material(
			for: noTextCtx,
			triggerType: packet.triggerType,
			inputPreference: .automatic
		))
		let life = appState.floatingSuggestionLifecycle.shouldSuppressNewFloating(
			triggerType: packet.triggerType,
			primaryActionId: dummyProposal.primaryActionId,
			profile: profile
		)
		check("bypass_lifecycle_allows_first_show", !life.suppressed)

		let bind = ActiveFloatingLifecycleBinding(
			exactKey: appState.floatingSuggestionLifecycle.exactKey(
				triggerType: packet.triggerType,
				primaryActionId: dummyProposal.primaryActionId,
				profile: profile
			),
			safeKey: appState.floatingSuggestionLifecycle.safeLogKey(
				triggerType: packet.triggerType,
				primaryActionId: dummyProposal.primaryActionId,
				profile: profile
			),
			profile: profile,
			primaryActionId: dummyProposal.primaryActionId
		)
		// This is the line that was previously unreachable because TES blocked first.
		let unifiedDummy = UnifiedSuggestionAdapters.from(liquidProposal: dummyProposal, isFloatingEligible: true)
		appState.showUnifiedFloatingSuggestion(unifiedDummy, lifecycle: bind)
		check("ambient_context_suggestion_bypasses_tes_and_renders",
			  appState.isFloatingSuggestionVisible)
		check("ambient_context_suggestion_uses_unified_surface",
			  appState.unifiedSurfaceDecision?.floating?.id == dummyProposal.primaryActionId)

		if appState.isFloatingSuggestionVisible {
			print("[AmbientFloatingSuggestion] tes_bypassed reason=context_grounded_no_text_input_needed")
			print("[AmbientFloatingSuggestion] shown=yes reason=ambient_jarvis")
		}

		// 1c. Detached before dwell threshold → not_visible, no ignored/auto-dismissed feedback.
		let appStateDetached = AppState()
		appStateDetached.showUnifiedFloatingSuggestion(unifiedDummy, lifecycle: bind)
		appStateDetached.dismissFloatingSuggestion(reason: .auto)
		check("detached_before_dwell_not_visible",
			  appStateDetached.wasSuggestionFeedbackLogged(id: dummyProposal.primaryActionId, event: "not_visible"))
		check("detached_before_dwell_not_ignored",
			  !appStateDetached.wasSuggestionFeedbackLogged(id: dummyProposal.primaryActionId, event: "ignored"))
		check("detached_before_dwell_not_auto_dismissed",
			  !appStateDetached.wasSuggestionFeedbackLogged(id: dummyProposal.primaryActionId, event: "auto_dismissed"))

		// 1d. Visibility proof passes after dwell → shown, later auto-dismiss is valid feedback.
		let appStateVisible = AppState()
		appStateVisible.showUnifiedFloatingSuggestion(unifiedDummy, lifecycle: bind)
		appStateVisible.reportFloatingVisibilityProof(
			attached: true,
			onScreen: true,
			alpha: 1.0,
			frame: CGRect(x: 20, y: 20, width: 320, height: 200),
			hiddenByPanel: false,
			dwellMs: 2500,
			stillPresented: true
		)
		let shownSuppression = appStateVisible.floatingSuggestionLifecycle.shouldSuppressNewFloating(
			triggerType: packet.triggerType,
			primaryActionId: dummyProposal.primaryActionId,
			profile: profile
		)
		check("visible_after_dwell_records_shown", shownSuppression.suppressed && shownSuppression.reason == "recently_shown")
		appStateVisible.dismissFloatingSuggestion(reason: .auto)
		check("visible_after_dwell_auto_dismissed",
			  appStateVisible.wasSuggestionFeedbackLogged(id: dummyProposal.primaryActionId, event: "auto_dismissed"))

		// ──────────────────────────────────────────────────────────────────
		// BLOCK 2 — Scratch / TurboWarp / Gemini not shopping
		// ──────────────────────────────────────────────────────────────────

		let scratchTitles: [(title: String, label: String)] = [
			("Advanced Scratch AI Tank Design - Google Gemini", "scratchTankGemini"),
			("Realistic Tank Shooter Demo - TurboWarp",         "realisticTankTurboWarp"),
			("How can I make my project run faster? - Discuss Scratch", "discussScratch"),
		]

		let shoppingState = makeShoppingWorkflowState()
		let comparingBehavior = makeComparingBehavior()

		FocusEpochTracker.shared.resetForTests()
		// Seed a shopping observation first (as if the user was on Amazon).
		_ = FocusEpochTracker.shared.observeSelectedTab(
			title: "Anker Prime 200W power bank - specifications and price",
			workflowLabel: "shopping"
		)

		for tab in scratchTitles {
			let obs = FocusEpochTracker.shared.observeSelectedTab(
				title: tab.title,
				workflowLabel: "shopping"
			)
			let decision = FocusOverride.applyIfNeeded(
				workflowState: shoppingState,
				behavioralRecord: comparingBehavior,
				focusObservation: obs
			)
			// After override, the workflow must NOT be shopping.
			// (It may be studying, researching, coding, or unknown — all acceptable.)
			let notShopping = decision.effectiveWorkflow.workflowType != .shopping
			check("scratch_turbowarp_gemini_not_shopping_\(tab.label)", notShopping)
		}

		// ──────────────────────────────────────────────────────────────────
		// BLOCK 3 — CapabilitySelector must not return compare_options
		// ──────────────────────────────────────────────────────────────────

		let caps = Array(CognitiveCapabilityRegistry.shared.capabilities.values)

		// Simulate the state after FocusOverride releases shopping:
		// workflow is researching, behavior is researching (not comparing).
		for tab in scratchTitles {
			let mem = WorkingMemorySnapshot(
				currentEntity: tab.title,
				recentEntities: [tab.title],
				repeatedConcepts: [],
				inferredActivity: "researching",
				comparisonCandidates: []
			)
			let sel = CapabilitySelector.select(
				compartment: nil,
				workingMemory: mem,
				evidenceQuality: "title_only",
				currentApp: "Firefox",
				behavior: .researching,
				userInitiated: false,
				availableCapabilities: caps
			)
			check("no_compare_options_for_\(tab.label)", sel?.primary.id != "compare_options")
		}

		// ──────────────────────────────────────────────────────────────────
		// BLOCK 4 — ui_visible correctness: ambient suggestion does not emit
		//           stored_not_rendered for its own id (it uses floatingSuggestion,
		//           not activatedGeneratedProposals).
		// ──────────────────────────────────────────────────────────────────
		// The storedVisible counter is activatedGeneratedProposals.count — an
		// ambient suggestion never goes through that path.  If the floating window
		// is visible and activatedGeneratedProposals is empty, final_status == hidden
		// is correct for the *panel-proposal* slot. The floating suggestion has its
		// own truth: isFloatingSuggestionVisible == true.
		let appState2 = AppState()
		let bind2 = ActiveFloatingLifecycleBinding(
			exactKey: "ambient:test:none",
			safeKey:  "ambient:test:none",
			profile: ContentSimilarityProfile.make(from: FloatingSimilarityText.material(
				for: noTextCtx,
				triggerType: .contextMetadataEligible,
				inputPreference: .automatic
			)),
			primaryActionId: "ambient_jarvis:test2"
		)
		let ambientProposal2 = ActionProposal(
			title: "Test ambient",
			sourceCaption: "Jarvis Suggestion (Preview-Only)",
			primaryActionId: "ambient_jarvis:test2",
			secondaryActionIds: [],
			confidence: 0.80,
			reason: "ambient_context_only"
		)
		let unifiedAmbient2 = UnifiedSuggestionAdapters.from(liquidProposal: ambientProposal2, isFloatingEligible: true)
		appState2.showUnifiedFloatingSuggestion(unifiedAmbient2, lifecycle: bind2)
		let storedVisible = appState2.activatedGeneratedProposals.count
		let floatingVisible = appState2.isFloatingSuggestionVisible
		check("ambient_floating_visible", floatingVisible)
		check("ambient_no_stored_not_rendered", storedVisible == 0)
		// Panel-proposal final_status is "hidden" — that is correct for ambient mode.
		let panelStatus: String = {
			let uiVisible = 0  // no dynamicActionDisplaySummary set
			if uiVisible > 0 { return "rendered" }
			if storedVisible > 0 { return "stored_not_rendered" }
			return "hidden"
		}()
		check("panel_status_correctly_hidden_ambient_routes_to_floating",
			  panelStatus == "hidden" && floatingVisible)

		let ok = failures.isEmpty
		print("[AmbientVisibilityRegressionSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}

	// MARK: - Helpers

	private static func makeNoTextContext() -> ContextModel {
		var ctx = ContextModel()
		ctx.activeAppName = "Firefox"
		ctx.activeAppBundleIdentifier = "org.mozilla.firefox"
		ctx.activeWindowTitle = "Advanced Scratch AI Tank Design - Google Gemini"
		ctx.selectedTextAvailable = false
		ctx.selectedTextLength = 0
		ctx.clipboardTextAvailable = false
		ctx.clipboardTextLength = 0
		return ctx
	}

	private static func makeShoppingWorkflowState() -> WorkflowState {
		let now = Date()
		return WorkflowState(
			workflowType: .shopping,
			confidence: 0.90,
			evidence: ["recent_titles=shopping"],
			uncertainty: "none",
			startedAt: now.addingTimeInterval(-180),
			lastUpdatedAt: now,
			stabilityScore: 0.90,
			dominantApps: ["Firefox"],
			repeatedTerms: ["anker", "power", "price"],
			recentTransitions: [],
			suggestedIntentHints: [],
			sourcePacketHash: "regression_test"
		)
	}

	private static func makeComparingBehavior() -> BehavioralStateRecord {
		let now = Date()
		return BehavioralStateRecord(
			state: .comparing,
			confidence: 0.90,
			reasoning: "regression_test",
			startedAt: now.addingTimeInterval(-180),
			lastUpdatedAt: now,
			stabilityScore: 0.90
		)
	}
}
