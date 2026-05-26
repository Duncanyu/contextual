import Foundation

/// Bounded self-tests for the Phase 4T Evidence Quality Gate and Validation Layer.
/// Enabled by environment variable: CONTEXTUAL_RUN_EVIDENCE_QUALITY_GATE_SELFTEST=1
enum EvidenceQualityGateSelfTest {

	static func run() async -> Bool {
		print("[EvidenceQualityGateSelfTest] starting evidence quality tests...")
		var failures: [String] = []

		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[EvidenceQualityGateSelfTest] FAIL: \(name)")
			} else {
				print("[EvidenceQualityGateSelfTest] PASS: \(name)")
			}
		}

		let decider = AgenticDecider()
		let runtime = AgenticRuntime()

		// MARK: 1 — Malformed product title like "Blo X" is rejected
		do {
			let isTruncated = EvidenceQualityGate.detectTruncation("Anker Prime USB Charger Blo X")
			check("blo_x_is_detected_as_truncated", isTruncated)
			
			let isChrome = EvidenceQualityGate.detectChromeLeak("Processing Compare Anker")
			check("processing_is_detected_as_chrome", isChrome)
			
			let isMashed = EvidenceQualityGate.detectMashedWord("ankercharger")
			check("ankercharger_is_detected_as_mashed", isMashed)
		}

		// MARK: 2 — Compare goal with one product only fails quality gate
		do {
			let goal = "Compare Anker Chargers"
			let requirements = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: "shopping")
			let satisfied: [AgenticEvidenceKind] = [.productTitle]
			let missing: [AgenticEvidenceKind] = [.comparisonCandidate, .specs]
			
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: satisfied,
				missing: missing,
				missingOptional: [],
				confidence: 0.33,
				shouldGatherMore: true,
				recommendedAction: .scrollSmall
			)
			
			let observations = [
				makeObservation(kind: .productTitle, text: "Anker 140W Charger", source: .windowTitle)
			]
			
			let quality = EvidenceQualityGate.evaluate(
				goal: goal,
				state: state,
				observations: observations,
				entities: [],
				facts: []
			)
			
			check("one_product_fails_quality_gate", quality.overallScore < EvidenceQualityGate.overallScoreThreshold)
		}

		// MARK: 3 — Compare goal with browser-history-only second candidate fails
		do {
			let goal = "Compare Anker Chargers"
			let requirements = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: "shopping")
			
			// We have 2 satisfied candidate slots, but one is ONLY in browser history!
			let satisfied: [AgenticEvidenceKind] = [.productTitle, .comparisonCandidate, .specs]
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: satisfied,
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)
			
			let observations = [
				makeObservation(kind: .productTitle, text: "Anker 140W Charger", source: .windowTitle),
				makeObservation(kind: .comparisonCandidate, text: "Old Anker Charger Block", source: .browsingHistory),
				makeObservation(kind: .specs, text: "140W", source: .windowTitle)
			]
			
			let quality = EvidenceQualityGate.evaluate(
				goal: goal,
				state: state,
				observations: observations,
				entities: [],
				facts: []
			)
			
			check("browser_history_only_second_fails_overall_score", quality.overallScore < EvidenceQualityGate.overallScoreThreshold)
		}

		// MARK: 4 — Compare goal with two live grounded candidates passes
		do {
			let goal = "Compare Anker Chargers"
			let requirements = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: "shopping")
			let satisfied: [AgenticEvidenceKind] = [.productTitle, .comparisonCandidate, .specs]
			
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: satisfied,
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)
			
			let observations = [
				makeObservation(kind: .productTitle, text: "Anker 140W Charger", source: .windowTitle),
				makeObservation(kind: .comparisonCandidate, text: "Anker 160W Charger block", source: .ocr),
				makeObservation(kind: .specs, text: "140W", source: .windowTitle),
				makeObservation(kind: .specs, text: "160W", source: .ocr)
			]
			
			let quality = EvidenceQualityGate.evaluate(
				goal: goal,
				state: state,
				observations: observations,
				entities: [],
				facts: []
			)
			
			check("two_live_grounded_candidates_passes_quality_gate", quality.overallScore >= EvidenceQualityGate.overallScoreThreshold)
		}

		// MARK: 5 — Validator rejects assistant/generated chrome evidence
		do {
			let goal = "Check specs"
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: [],
				satisfied: [.productTitle],
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)
			
			// Leaked Chrome string in observations
			let observations = [
				makeObservation(kind: .productTitle, text: "Processing Check specs...", source: .ocr)
			]
			
			let validation = EvidenceValidator.validate(
				goal: goal,
				state: state,
				observations: observations,
				entities: [],
				facts: []
			)
			
			check("validator_rejects_chrome_evidence", !validation.isValid)
			check("validator_reason_is_chrome_leakage", validation.reason == "assistant_chrome_leakage_detected")
		}

		// MARK: 6 — Final answer never says comparison evidence sufficient when comparison candidates invalid
		do {
			var session = makeSession(goal: "Compare Chargers", satisfied: [.productTitle], missing: [.comparisonCandidate])
			session.semanticEntities = [
				GroundedSemanticEntity(id: "e1", type: .productTitle, text: "Anker Blo X", normalizedValue: nil, confidence: 0.9, sourceNodeId: "n1", role: .heading, tags: [])
			]
			
			let answer = runtime.buildPremiumAnswerTestBridge(session: session)
			check("never_claims_comparison_sufficient_when_candidates_invalid", answer.contains("I found one likely product and several reliable specs, but I do not yet have enough clean evidence to compare it with another charger."))
			check("partial_answer_contains_missing_second_candidate", answer.contains("- second valid comparison candidate"))
		}

		// MARK: 7 — evidence_satisfied blocked in decider when quality is low
		do {
			let goal = "Compare Chargers"
			let requirements = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: "shopping")
			
			// Under Phase 4S, ev.allRequiredSatisfied is true, but under 4T quality score is 0
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: [.productTitle, .comparisonCandidate, .specs],
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)
			
			// Low quality observations (mostly empty/history only)
			let observations = [
				makeObservation(kind: .comparisonCandidate, text: "Anker Blo X", source: .browsingHistory)
			]
			
			let decision = await decider.decide(
				goal: goal,
				workflow: "shopping",
				observations: [],
				extractedFacts: [],
				stepIndex: 2,
				maxSteps: 5,
				llmCallsUsed: 0,
				llmCallsBudget: 0,
				ocrCallsUsed: 0,
				ocrCallsBudget: 0,
				legalActions: [.scroll_small, .present_answer],
				forceObserveNext: false,
				evidenceState: state,
				evidenceObservations: observations
			)
			
			// Blocks early present_answer!
			check("evidence_satisfied_blocked_on_low_quality", decision.nextAction == .scroll_small)
		}

		// MARK: 8 — evidence_satisfied allowed when initial evidence is strong
		do {
			let goal = "Compare Chargers"
			let requirements = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: "shopping")
			
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: [.productTitle, .comparisonCandidate, .specs],
				missing: [],
				missingOptional: [],
				confidence: 1.0,
				shouldGatherMore: false,
				recommendedAction: .present
			)
			
			// Very high quality observations
			let observations = [
				makeObservation(kind: .productTitle, text: "Anker Prime 140W Charger", source: .windowTitle),
				makeObservation(kind: .comparisonCandidate, text: "Anker Prime 160W Charger block", source: .ocr),
				makeObservation(kind: .specs, text: "140W", source: .windowTitle),
				makeObservation(kind: .specs, text: "160W", source: .ocr)
			]
			
			let decision = await decider.decide(
				goal: goal,
				workflow: "shopping",
				observations: [],
				extractedFacts: ["Summary: 2 products ready"],
				stepIndex: 2,
				maxSteps: 5,
				llmCallsUsed: 0,
				llmCallsBudget: 0,
				ocrCallsUsed: 0,
				ocrCallsBudget: 0,
				legalActions: [.scroll_small, .present_answer],
				forceObserveNext: false,
				evidenceState: state,
				evidenceObservations: observations
			)
			
			check("evidence_satisfied_allowed_on_high_quality", decision.nextAction == .present_answer)
		}

		let ok = failures.isEmpty
		print("[EvidenceQualityGateSelfTest] finished. ok=\(ok), failures=\(failures.count)")
		return ok
	}

	// MARK: - Helpers

	private static func makeObservation(
		kind: AgenticEvidenceKind,
		text: String,
		source: AgenticEvidenceObservationSource
	) -> AgenticEvidenceObservation {
		AgenticEvidenceObservation(
			id: "test_obs_\(kind.rawValue)_\(text.hashValue)",
			kind: kind,
			text: text,
			normalized: text.lowercased(),
			confidence: 0.85,
			source: source,
			reason: "mocked"
		)
	}

	private static func makeSession(
		goal: String,
		satisfied: [AgenticEvidenceKind],
		missing: [AgenticEvidenceKind]
	) -> AgenticSessionState {
		let requirements = (satisfied + missing).map { AgenticEvidenceRequirement(kind: $0, required: true) }
		let state = AgenticEvidenceState(
			goal: goal,
			requirements: requirements,
			satisfied: satisfied,
			missing: missing,
			missingOptional: [],
			confidence: Double(satisfied.count) / Double(satisfied.count + missing.count),
			shouldGatherMore: !missing.isEmpty,
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
