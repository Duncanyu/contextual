import Foundation

/// Phase 20G.3 — Current focus overrides stale workflow/behavior for Jarvis.
///
/// Trigger:
///   CONTEXTUAL_RUN_FOCUS_OVERRIDE_SELFTEST=1
@MainActor
enum FocusOverrideSelfTest {
	static func run() async -> Bool {
		print("[FocusOverrideSelfTest] starting")
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if ok { print("[FocusOverrideSelfTest] pass case=\(name)") }
			else  { print("[FocusOverrideSelfTest] fail case=\(name)"); failures.append(name) }
		}

		FocusEpochTracker.shared.resetForTests()
		let now = Date()

		_ = FocusEpochTracker.shared.observeSelectedTab(
			title: "Portable power bank 20000mah - specs and price",
			workflowLabel: "shopping",
			at: now
		)
		let courseObs = FocusEpochTracker.shared.observeSelectedTab(
			title: "Week 2 — Intro to Computing: problem solving",
			workflowLabel: "shopping",
			at: now.addingTimeInterval(3)
		)
		check("focus_shift_detected", courseObs.focusShiftDetected)

		let shoppingState = WorkflowState(
			workflowType: .shopping,
			confidence: 0.9,
			evidence: ["recent_titles=shopping"],
			uncertainty: "none",
			startedAt: now.addingTimeInterval(-120),
			lastUpdatedAt: now,
			stabilityScore: 0.9,
			dominantApps: ["Browser"],
			repeatedTerms: ["power", "bank", "price"],
			recentTransitions: [],
			suggestedIntentHints: [],
			sourcePacketHash: "test"
		)
		let comparingBehavior = BehavioralStateRecord(
			state: .comparing,
			confidence: 0.9,
			reasoning: "test",
			startedAt: now.addingTimeInterval(-120),
			lastUpdatedAt: now,
			stabilityScore: 0.9
		)

		let decision = FocusOverride.applyIfNeeded(
			workflowState: shoppingState,
			behavioralRecord: comparingBehavior,
			focusObservation: courseObs
		)
		check("override_applied_for_learning_focus", decision.applied)
		check("workflow_overridden_from_shopping", decision.effectiveWorkflow.workflowType != .shopping)
		check("behavior_overridden_from_comparing", decision.effectiveBehavior.state != .comparing)
		check("workflow_is_studying_or_researching", decision.effectiveWorkflow.workflowType == .studying || decision.effectiveWorkflow.workflowType == .researching || decision.effectiveWorkflow.workflowType == .reading)

		// Creative coding + AI tools (Scratch / TurboWarp / Gemini) must NOT
		// be classified as productLike, so stale shopping workflow is released.
		FocusEpochTracker.shared.resetForTests()
		_ = FocusEpochTracker.shared.observeSelectedTab(
			title: "Anker Prime 200W power bank - specifications",
			workflowLabel: "shopping",
			at: now
		)
		let scratchObs = FocusEpochTracker.shared.observeSelectedTab(
			title: "Scratch - Imagine, Program, Share",
			workflowLabel: "shopping",
			at: now.addingTimeInterval(4)
		)
		let scratchDecision = FocusOverride.applyIfNeeded(
			workflowState: shoppingState,
			behavioralRecord: comparingBehavior,
			focusObservation: scratchObs
		)
		check("scratch_not_classified_as_shopping",
			  scratchDecision.effectiveWorkflow.workflowType != .shopping)

		FocusEpochTracker.shared.resetForTests()
		_ = FocusEpochTracker.shared.observeSelectedTab(
			title: "Anker SOLIX C800 - product comparison",
			workflowLabel: "shopping",
			at: now
		)
		let geminiObs = FocusEpochTracker.shared.observeSelectedTab(
			title: "Gemini - chat with your AI assistant",
			workflowLabel: "shopping",
			at: now.addingTimeInterval(4)
		)
		let geminiDecision = FocusOverride.applyIfNeeded(
			workflowState: shoppingState,
			behavioralRecord: comparingBehavior,
			focusObservation: geminiObs
		)
		check("gemini_classified_as_research_not_shopping",
			  geminiDecision.effectiveWorkflow.workflowType != .shopping)

		// Product-to-product focus shifts must not override shopping/comparing.
		FocusEpochTracker.shared.resetForTests()
		_ = FocusEpochTracker.shared.observeSelectedTab(
			title: "Laptop charger 65w - specs and price",
			workflowLabel: "shopping",
			at: now
		)
		let productObs = FocusEpochTracker.shared.observeSelectedTab(
			title: "USB C docking station 100w - specs and price",
			workflowLabel: "shopping",
			at: now.addingTimeInterval(3)
		)
		check("product_focus_shift_detected", productObs.focusShiftDetected)
		let noOverride = FocusOverride.applyIfNeeded(
			workflowState: shoppingState,
			behavioralRecord: comparingBehavior,
			focusObservation: productObs
		)
		check("no_override_for_product_to_product", !noOverride.applied)

		let ok = failures.isEmpty
		print("[FocusOverrideSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}

