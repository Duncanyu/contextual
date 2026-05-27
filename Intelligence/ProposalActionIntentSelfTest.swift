import Foundation

/// Phase 4S — Proposal action-intent gate self-test.
///
/// Run with: `CONTEXTUAL_RUN_PROPOSAL_ACTION_INTENT_SELFTEST=1`
enum ProposalActionIntentSelfTest {
	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				print("[ProposalActionIntentSelfTest] FAIL \(name)")
				failures.append(name)
			} else {
				print("[ProposalActionIntentSelfTest] PASS \(name)")
			}
		}

		let now = Date()
		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Anker Prime USB C Charger Block, 160W 3-Port GaN Charger",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: "Anker Prime USB C Charger Block 160W 3-Port GaN",
			contextSummary: "",
			workflowConfidence: 0.8,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.8
		)
		let situational = SituationalContextSynthesizer.synthesize(from: snap, referenceTime: now)

		// 1) Raw product title rejected as non-action title.
		do {
			let iso = IsolatedProposalContext(
				appName: "Firefox",
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: snap.windowTitle,
				selectedText: nil,
				ocrExcerpt: snap.recentOCRExcerpt,
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title", "ocr"],
				excludedSources: []
			)
			let res = ProposalCapabilityValidator.validate(title: snap.windowTitle, goal: snap.windowTitle, isolated: iso, stage: "selftest")
			check("raw_product_title_rejected", res.accepted == false && res.reason == "non_action_title")
		}

		// 2) Raw Xcode project title rejected.
		do {
			let title = "Contextual — Contextual.xcodeproj"
			let iso = IsolatedProposalContext(
				appName: "Xcode",
				bundleIdentifier: "com.apple.dt.Xcode",
				windowTitle: title,
				selectedText: nil,
				ocrExcerpt: nil,
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title"],
				excludedSources: []
			)
			let res = ProposalCapabilityValidator.validate(title: title, goal: title, isolated: iso, stage: "selftest")
			check("raw_xcode_title_rejected", res.accepted == false && res.reason == "non_action_title")
		}

		// 3) Raw account/person title rejected.
		do {
			let title = "Duncanyu (Duncan Yu)"
			let iso = IsolatedProposalContext(
				appName: "Firefox",
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: title,
				selectedText: nil,
				ocrExcerpt: nil,
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title"],
				excludedSources: []
			)
			let res = ProposalCapabilityValidator.validate(title: title, goal: title, isolated: iso, stage: "selftest")
			check("raw_person_title_rejected", res.accepted == false && res.reason == "non_action_title")
		}

		// 4) Action-intent title grounded in entity accepted.
		do {
			let title = "Review Anker Prime USB C Charger"
			let iso = IsolatedProposalContext(
				appName: "Firefox",
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: snap.windowTitle,
				selectedText: nil,
				ocrExcerpt: snap.recentOCRExcerpt,
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title", "ocr"],
				excludedSources: []
			)
			let res = ProposalCapabilityValidator.validate(title: title, goal: title, isolated: iso, stage: "selftest")
			check("action_intent_plus_entity_accepted", res.accepted == true)
		}

		// 5) Fast visibility may detect entity but must not generate an action when warmup isn't ready.
		do {
			let result = await TaskInferenceEngine.shared.infer(
				snapshot: snap,
				situational: situational,
				recentTitles: [snap.windowTitle],
				history: nil,
				referenceTime: now,
				isWarmupReady: false
			)
			check("fast_visibility_no_action_without_intent", result == nil)
		}

		let ok = failures.isEmpty
		print("[ProposalActionIntentSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
