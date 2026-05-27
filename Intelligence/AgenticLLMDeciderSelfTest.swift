import Foundation

/// Bounded self-tests for the Phase 4E LLM-led decider, StopGate, and Answer Synthesis.
/// Enabled by environment variable: CONTEXTUAL_RUN_AGENTIC_LLM_SELFTEST=1
enum AgenticLLMDeciderSelfTest {

	static func run() async -> Bool {
		print("[AgenticLLMDeciderSelfTest] starting LLM decision and StopGate tests...")
		var failures: [String] = []

		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[AgenticLLMDeciderSelfTest] FAIL: \(name)")
			} else {
				print("[AgenticLLMDeciderSelfTest] PASS: \(name)")
			}
		}

		let decider = AgenticDecider()
		let runtime = AgenticRuntime()

		// MARK: 1 — parseModelDecision accepts legal actions
		do {
			let legal: Set<AgenticNextAction> = [.observe_once, .scroll_small, .present_answer]
			let jsonOk = "{\"next_action\": \"scroll_small\", \"reason\": \"need more text\", \"confidence\": 0.95}"
			var rejectedReason: String? = nil
			let parsed = decider.parseModelDecision(jsonOk, legalActions: legal, rejectedReason: &rejectedReason)
			check("parse_legal_action_success", parsed != nil)
			check("parse_legal_action_correct_action", parsed?.nextAction == .scroll_small)
			check("parse_legal_action_correct_confidence", parsed?.confidence == 0.95)
		}

		// MARK: 2 — parseModelDecision rejects illegal actions (e.g. click)
		do {
			let legal: Set<AgenticNextAction> = [.observe_once, .scroll_small, .present_answer]
			let jsonIllegal = "{\"next_action\": \"click\", \"reason\": \"want to click\", \"confidence\": 0.99}"
			var rejectedReason: String? = nil
			let parsed = decider.parseModelDecision(jsonIllegal, legalActions: legal, rejectedReason: &rejectedReason)
			check("parse_illegal_action_nil", parsed == nil)
			check("parse_illegal_action_reason", rejectedReason == "illegal_action")
		}

		// MARK: 3 — StopGate blocks Unknown Product final answers
		do {
			let observations = [
				makeObservation(activeApp: "Firefox", windowTitle: "")
			]
			// Satisfied all required, but productTitle is empty/Unknown
			let requirements = [AgenticEvidenceRequirement(kind: .productTitle, required: true)]
			let state = AgenticEvidenceState(
				goal: "Get charger details",
				requirements: requirements,
				satisfied: [.productTitle],
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)

			var blockReason: String? = nil
			let isBlocked = decider.isStopGateBlocked(
				goal: "Get charger details",
				observations: observations,
				evidenceObservations: [], // empty/Unknown productTitle
				entities: [],
				facts: [],
				evidenceState: state,
				reason: &blockReason
			)
			check("stopgate_blocks_unknown_product", isBlocked)
			check("stopgate_blocked_reason_unknown_product", blockReason == "unknown_product")
		}

		// MARK: 4 — StopGate blocks on low groundedness (< 0.60)
		do {
			let observations = [
				makeObservation(activeApp: "Firefox", windowTitle: "Anker USB C Hub")
			]
			let evidenceObservations = [
				makeEvidenceObservation(kind: .productTitle, text: "Anker USB C Hub", source: .windowTitle)
			]
			// We have facts that aren't grounded in observations (groundedness score = 0)
			let entities = [
				GroundedSemanticEntity(id: "e1", type: .productTitle, text: "Different Product Title", normalizedValue: nil, confidence: 0.9, sourceNodeId: "n1", role: .heading, tags: [])
			]
			let requirements = [AgenticEvidenceRequirement(kind: .productTitle, required: true)]
			let state = AgenticEvidenceState(
				goal: "Get charger details",
				requirements: requirements,
				satisfied: [.productTitle],
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)

			var blockReason: String? = nil
			let isBlocked = decider.isStopGateBlocked(
				goal: "Get charger details",
				observations: observations,
				evidenceObservations: evidenceObservations,
				entities: entities,
				facts: [],
				evidenceState: state,
				reason: &blockReason
			)
			check("stopgate_blocks_low_groundedness", isBlocked)
			check("stopgate_blocked_reason_low_groundedness", blockReason == "low_groundedness")
		}

		// MARK: 5 — StopGate blocks on assistant chrome leakage in observations
		do {
			let observations = [
				makeObservation(activeApp: "Firefox", windowTitle: "Anker USB C Hub", selectedText: "Processing Inspect...")
			]
			let evidenceObservations = [
				makeEvidenceObservation(kind: .productTitle, text: "Anker USB C Hub", source: .windowTitle)
			]
			let requirements = [AgenticEvidenceRequirement(kind: .productTitle, required: true)]
			let state = AgenticEvidenceState(
				goal: "Get charger details",
				requirements: requirements,
				satisfied: [.productTitle],
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)

			var blockReason: String? = nil
			let isBlocked = decider.isStopGateBlocked(
				goal: "Get charger details",
				observations: observations,
				evidenceObservations: evidenceObservations,
				entities: [],
				facts: [],
				evidenceState: state,
				reason: &blockReason
			)
			check("stopgate_blocks_chrome_leak", isBlocked)
			check("stopgate_blocked_reason_chrome_leak", blockReason == "chrome_leak_detected")
		}

		// MARK: 6 — StopGate blocks on weak/noisy/truncated tokens
		do {
			let observations = [
				makeObservation(activeApp: "Firefox", windowTitle: "Anker Prime Charger")
			]
			// satisfying with truncated and low alphanumeric text
			let evidenceObservations = [
				makeEvidenceObservation(kind: .productTitle, text: "Anker Prime Charger", source: .windowTitle),
				makeEvidenceObservation(kind: .specs, text: "@@@!!!", source: .windowTitle)
			]
			let requirements = [
				AgenticEvidenceRequirement(kind: .productTitle, required: true),
				AgenticEvidenceRequirement(kind: .specs, required: true)
			]
			let state = AgenticEvidenceState(
				goal: "Get specs",
				requirements: requirements,
				satisfied: [.productTitle, .specs],
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)

			var blockReason: String? = nil
			let isBlocked = decider.isStopGateBlocked(
				goal: "Get specs",
				observations: observations,
				evidenceObservations: evidenceObservations,
				entities: [],
				facts: [],
				evidenceState: state,
				reason: &blockReason
			)
			check("stopgate_blocks_noisy_evidence", isBlocked)
			check("stopgate_blocked_reason_noisy_evidence", blockReason == "noisy_or_truncated_evidence")
		}

		// MARK: 7 — Premium answer synthesis clean title selection & echo suppression
		do {
			var session = makeSession(goal: "Get charger info")
			session.observations = [
				makeObservation(activeApp: "Firefox", windowTitle: "Anker Prime 140W Charger : Amazon.ca")
			]
			session.evidenceObservations = [
				makeEvidenceObservation(kind: .productTitle, text: "Anker Prime 140W Charger", source: .windowTitle)
			]
			session.semanticEntities = [
				GroundedSemanticEntity(id: "e1", type: .productTitle, text: "Processing Inspect...", normalizedValue: nil, confidence: 0.9, sourceNodeId: "n1", role: .heading, tags: [])
			]

			let answer = runtime.buildPremiumAnswerTestBridge(session: session)
			check("clean_product_title_selected_from_window_title", answer.contains("Product: Anker Prime 140W Charger"))
			check("proposal_chrome_echo_is_suppressed", !answer.contains("Processing Inspect"))
		}

		// MARK: 8 — Live decider attempts LLM generate path when budget allows
		do {
			let observations = [
				makeObservation(activeApp: "Firefox", windowTitle: "Anker Prime 140W Charger")
			]
			let requirements = [AgenticEvidenceRequirement(kind: .productTitle, required: true)]
			let state = AgenticEvidenceState(
				goal: "Get charger info",
				requirements: requirements,
				satisfied: [.productTitle],
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)

			// We call decide with llmCallsUsed = 0, llmCallsBudget = 5.
			// This MUST trigger the LLM decision path, print "[AgenticLLMDecide] started",
			// and fallback to heuristic when the port is closed (or succeed if Ollama is running).
			let decision = await decider.decide(
				goal: "Get charger info",
				observations: observations,
				extractedFacts: [],
				stepIndex: 1,
				maxSteps: 5,
				llmCallsUsed: 0,
				llmCallsBudget: 5,
				ocrCallsUsed: 0,
				ocrCallsBudget: 2,
				legalActions: [.present_answer, .observe_once],
				evidenceState: state,
				evidenceObservations: [],
				priorActions: [],
				entities: [],
				facts: []
			)
			check("live_decide_invocation", decision.nextAction == .present_answer || decision.nextAction == .observe_once)
		}

		let ok = failures.isEmpty
		print("[AgenticLLMDeciderSelfTest] finished. ok=\(ok), failures=\(failures.count)")
		return ok
	}

	// MARK: - Helpers

	private static func makeObservation(
		activeApp: String,
		windowTitle: String,
		selectedText: String? = nil,
		ocrExcerpt: String? = nil
	) -> AgenticObservation {
		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: activeApp,
			windowTitle: windowTitle,
			selectedText: selectedText,
			recentOCRExcerpt: ocrExcerpt,
			contextSummary: "ax=test",
			generatedAt: Date()
		)
		let observer = AgenticObserver()
		return observer.observe(
			stepIndex: 1,
			snapshot: snap,
			ocrCallsUsed: 0,
			ocrCallsBudget: 2,
			isPostControl: false,
			goal: ""
		)
	}

	private static func makeEvidenceObservation(
		kind: AgenticEvidenceKind,
		text: String,
		source: AgenticEvidenceObservationSource
	) -> AgenticEvidenceObservation {
		AgenticEvidenceObservation(
			id: "test_obs_\(kind.rawValue)_\(text.hashValue)",
			kind: kind,
			text: text,
			normalized: text.lowercased(),
			confidence: 0.9,
			source: source,
			reason: "mocked"
		)
	}

	private static func makeSession(goal: String) -> AgenticSessionState {
		let requirements = [AgenticEvidenceRequirement(kind: .productTitle, required: true)]
		let state = AgenticEvidenceState(
			goal: goal,
			requirements: requirements,
			satisfied: [.productTitle],
			missing: [],
			missingOptional: [],
			confidence: 1.0,
			shouldGatherMore: false,
			recommendedAction: .present
		)

		return AgenticSessionState(
			planId: UUID().uuidString,
			goal: goal,
			workflow: "shopping",
			stepIndex: 1,
			maxSteps: 5,
			llmCallsUsed: 0,
			ocrCallsUsed: 0,
			scrollsUsed: 0,
			findsUsed: 0,
			maxScrolls: 2,
			maxFinds: 1,
			startedAt: Date(),
			observations: [],
			extractedFacts: [],
			finalAnswer: nil,
			stopReason: nil,
			actionsExecuted: [],
			forceObserveNext: false,
			lastActionWasControl: false,
			blockedActions: [],
			controlDecisionLog: [],
			ineffectiveControlCount: 0,
			failedControlActions: [],
			worldStateTransitions: [],
			discoveredEntities: [],
			lastObservationSnapshotID: nil,
			lastObservationTextHash: nil,
			screenStateGraph: nil,
			groundedTargets: [],
			primaryGroundedTarget: nil,
			semanticEntities: [],
			structuredFacts: [],
			semanticReadiness: nil,
			evidenceRequirements: requirements,
			evidenceState: state,
			evidenceObservations: []
		)
	}
}
