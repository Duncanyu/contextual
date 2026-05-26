import Foundation

/// Phase 4O self-test for the evidence requirements model, the evidence-aware
/// decider, semantic readiness gating, and the strengthened generated chrome
/// suppression on semantic entities.
///
/// Run with: `CONTEXTUAL_RUN_AGENTIC_EVIDENCE_GATE_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no AI calls.
enum AgenticEvidenceGateSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[AgenticEvidenceGateSelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — Requirement inference by task family

		do {
			let compare = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Compare Anker Laptop Chargers",
				workflow: "shopping"
			)
			check("compare_requires_comparisonCandidate",
				  compare.contains { $0.kind == .comparisonCandidate && $0.required && $0.minCount == 2 })
			check("compare_requires_specs",
				  compare.contains { $0.kind == .specs && $0.required })

			let review = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Review Anker Laptop Charger",
				workflow: "browsing"
			)
			check("review_requires_product_title",
				  review.contains { $0.kind == .productTitle && $0.required })
			check("review_specs_required",
				  review.contains { $0.kind == .specs && $0.required })

			let summarize = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Summarize Thread: Laptop charger recommendations",
				workflow: "reading"
			)
			check("summarize_requires_page_summary",
				  summarize.contains { $0.kind == .pageSummary && $0.required })

			let priceCheck = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Check price for charger",
				workflow: "shopping"
			)
			check("price_check_requires_price",
				  priceCheck.contains { $0.kind == .price && $0.required })

			let reviewsCheck = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Check reviews and rating",
				workflow: "shopping"
			)
			check("reviews_check_requires_rating",
				  reviewsCheck.contains { $0.kind == .rating && $0.required })
			check("reviews_check_requires_review_count",
				  reviewsCheck.contains { $0.kind == .reviewCount && $0.required })

			let code = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Analyze Xcode build error",
				workflow: nil
			)
			check("code_requires_code_snippet",
				  code.contains { $0.kind == .codeSnippet && $0.required })
		}

		// MARK: 2 — Assessor: compare with ONE product → missing comparisonCandidate

		do {
			let requirements = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Compare Anker Laptop Chargers",
				workflow: "shopping"
			)
			let entities: [GroundedSemanticEntity] = [
				stubEntity(type: .productTitle, text: "Anker 140W USB-C Charger", normalized: "anker 140w"),
				stubEntity(type: .specification, text: "140W"),
				stubEntity(type: .specification, text: "USB-C"),
			]
			let state = AgenticEvidenceAssessor.assess(
				goal: "Compare Anker Laptop Chargers",
				requirements: requirements,
				entities: entities,
				extractedFactsCount: 0,
				hasUsableObservation: true
			)
			check("compare_one_product_missing_comparison",
				  state.missing.contains(.comparisonCandidate))
			check("compare_one_product_should_gather", state.shouldGatherMore)
			check("compare_one_product_not_all_satisfied", !state.allRequiredSatisfied)
		}

		// MARK: 3 — Assessor: compare with TWO product candidates → satisfied
		// One candidate is a .productTitle (the primary product on the page), the
		// other is a .heading representing a comparison candidate the runtime
		// surfaced from a "related products" row. The stricter quality gate
		// requires the second candidate be a non-primary source.

		do {
			let requirements = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Compare Anker Laptop Chargers",
				workflow: "shopping"
			)
			let entities: [GroundedSemanticEntity] = [
				stubEntity(type: .productTitle, text: "Anker 140W USB-C Charger", normalized: "anker 140w"),
				stubEntity(type: .heading, text: "Anker 100W Power Bank", normalized: "anker 100w"),
				stubEntity(type: .specification, text: "140W"),
				stubEntity(type: .specification, text: "USB-C"),
				stubEntity(type: .specification, text: "100W"),
			]
			let state = AgenticEvidenceAssessor.assess(
				goal: "Compare Anker Laptop Chargers",
				requirements: requirements,
				entities: entities,
				extractedFactsCount: 0,
				hasUsableObservation: true
			)
			check("compare_two_products_satisfied",
				  state.satisfied.contains(.comparisonCandidate))
			check("compare_two_products_all_required",
				  state.allRequiredSatisfied)
		}

		// MARK: 4 — Reviews check missing reviews → recommendedAction find_on_page

		do {
			let requirements = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Check reviews and rating",
				workflow: "shopping"
			)
			let entities: [GroundedSemanticEntity] = [
				stubEntity(type: .productTitle, text: "Anker 140W USB-C Charger"),
			]
			let state = AgenticEvidenceAssessor.assess(
				goal: "Check reviews and rating",
				requirements: requirements,
				entities: entities,
				hasUsableObservation: true
			)
			check("reviews_check_missing_rating", state.missing.contains(.rating))
			check("reviews_check_recommends_find_on_page",
				  state.recommendedAction == .findOnPage)
		}

		// MARK: 5 — Rich OCR alone (no entities) does not imply readiness

		do {
			let requirements = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Review Anker Laptop Charger",
				workflow: "browsing"
			)
			let state = AgenticEvidenceAssessor.assess(
				goal: "Review Anker Laptop Charger",
				requirements: requirements,
				entities: [],
				extractedFactsCount: 0,
				hasUsableObservation: true
			)
			check("review_no_entities_missing_product_title",
				  state.missing.contains(.productTitle))
			check("review_no_entities_should_gather", state.shouldGatherMore)
		}

		// MARK: 6 — GeneratedChromeFilter rejects "Processing Compare Anker"

		do {
			let r = GeneratedChromeFilter.shouldSuppress(
				line: "Processing Compare Anker",
				runtimeGoal: "Compare Anker Laptop Chargers",
				proposalTitle: "Compare Anker Laptop Chargers"
			)
			check("processing_compare_anker_suppressed", r.suppressed)
			check("processing_compare_anker_reason_goal_echo",
				  (r.reason ?? "") == "processing_goal_echo" || (r.reason ?? "") == "processing_current_goal")

			let r2 = GeneratedChromeFilter.shouldSuppress(
				line: "Processing Review Anker Laptop Charger",
				runtimeGoal: "Review Anker Laptop Charger"
			)
			check("processing_review_suppressed", r2.suppressed)
		}

		// MARK: 7 — Semantic readiness false when required evidence missing

		do {
			let requirements = AgenticEvidenceRequirementsInferrer.infer(
				goal: "Compare Anker Laptop Chargers",
				workflow: "shopping"
			)
			let entities: [GroundedSemanticEntity] = [
				stubEntity(type: .productTitle, text: "Anker 140W USB-C Charger"),
				stubEntity(type: .specification, text: "140W"),
				stubEntity(type: .specification, text: "USB-C"),
			]
			let state = AgenticEvidenceAssessor.assess(
				goal: "Compare Anker Laptop Chargers",
				requirements: requirements,
				entities: entities,
				hasUsableObservation: true
			)
			let readiness = SemanticReadinessEvaluator.evaluate(
				facts: [],
				entities: entities,
				goal: "Compare Anker Laptop Chargers",
				evidenceState: state,
				budgetExhausted: false
			)
			check("readiness_false_when_evidence_missing", readiness.readyForFinalAnswer == false)
			check("readiness_reason_missing_required",
				  readiness.reason.contains("missing_required_evidence"))

			let readinessPartial = SemanticReadinessEvaluator.evaluate(
				facts: [],
				entities: entities,
				goal: "Compare Anker Laptop Chargers",
				evidenceState: state,
				budgetExhausted: true
			)
			check("readiness_partial_when_budget_exhausted_missing",
				  readinessPartial.reason.contains("budget_exhausted_missing_evidence"))
		}

		// MARK: 8 — Find query maps from missing kind (no app names)

		do {
			let q1 = AgenticControlPolicy.determineFindQuery(
				forMissingKind: .comparisonCandidate,
				goal: "Compare Anker Laptop Chargers"
			)
			check("find_query_for_comparison_is_compare", q1 == "compare")

			let q2 = AgenticControlPolicy.determineFindQuery(forMissingKind: .price, goal: "Check price")
			check("find_query_for_price_is_price", q2 == "price")

			let q3 = AgenticControlPolicy.determineFindQuery(forMissingKind: .rating, goal: "Check rating")
			check("find_query_for_rating_is_rating", q3 == "rating")

			let q4 = AgenticControlPolicy.determineFindQuery(forMissingKind: .reviewCount, goal: "Check reviews")
			check("find_query_for_review_count_is_reviews", q4 == "reviews")

			// Ensure no kind ever returns an app name.
			let bad: Set<String> = AgenticControlPolicy.findQueryBlocklist
			for kind in AgenticEvidenceKind.allCases {
				let q = AgenticControlPolicy.determineFindQuery(forMissingKind: kind, goal: "Test")
				check("find_query_for_\(kind.rawValue)_not_chrome", !bad.contains(q))
			}
		}

		// MARK: 9 — Stop conditions include evidence-aware cases

		do {
			let cases = AgenticStopCondition.allCases.map { $0.rawValue }
			check("stop_evidence_satisfied_exists", cases.contains("evidence_satisfied"))
			check("stop_partial_exists", cases.contains("partial_evidence_budget_exhausted"))
			check("stop_no_more_safe_actions_exists", cases.contains("no_more_safe_actions"))
		}

		// MARK: 10a — Evidence-aware decider: missing comparison → scroll_small
		//
		// The assessor recommends scroll for comparisonCandidate ("need more
		// candidates") per the Phase 4O spec example. The find-query mapping
		// (compare) is still validated independently in test 8.

		do {
			let decider = AgenticDecider()
			let goal = "Compare Anker Laptop Chargers"
			let requirements = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: "shopping")
			let entities: [GroundedSemanticEntity] = [
				stubEntity(type: .productTitle, text: "Anker 140W USB-C Charger"),
				stubEntity(type: .specification, text: "140W"),
				stubEntity(type: .specification, text: "USB-C"),
			]
			let state = AgenticEvidenceAssessor.assess(
				goal: goal,
				requirements: requirements,
				entities: entities,
				extractedFactsCount: 0,
				hasUsableObservation: true
			)
			let obs = stubObservation(quality: .rich)
			let decision = await decider.decide(
				goal: goal,
				workflow: "shopping",
				observations: [obs],
				extractedFacts: [],
				stepIndex: 2,
				maxSteps: 8,
				llmCallsUsed: 5,
				llmCallsBudget: 5,
				ocrCallsUsed: 1,
				ocrCallsBudget: 3,
				legalActions: [.observe_once, .extract_facts, .summarize_observation, .present_answer, .scroll_small, .find_on_page, .stop_missing_context, .stop_success],
				forceObserveNext: false,
				semanticReadiness: nil,
				evidenceState: state
			)
			check("missing_comparison_routes_to_scroll",
				  decision.nextAction == .scroll_small)
			check("missing_comparison_is_control_action",
				  decision.nextAction == .scroll_small || decision.nextAction == .find_on_page)
		}

		// MARK: 10b — Missing price routes to find_on_page with price query

		do {
			let decider = AgenticDecider()
			let goal = "Check price for this charger"
			let requirements = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: "shopping")
			let entities: [GroundedSemanticEntity] = [
				stubEntity(type: .productTitle, text: "Anker 140W USB-C Charger"),
			]
			let state = AgenticEvidenceAssessor.assess(
				goal: goal,
				requirements: requirements,
				entities: entities,
				extractedFactsCount: 0,
				hasUsableObservation: true
			)
			let decision = await decider.decide(
				goal: goal,
				workflow: "shopping",
				observations: [stubObservation(quality: .rich)],
				extractedFacts: [],
				stepIndex: 2,
				maxSteps: 8,
				llmCallsUsed: 5,
				llmCallsBudget: 5,
				ocrCallsUsed: 1,
				ocrCallsBudget: 3,
				legalActions: [.observe_once, .extract_facts, .summarize_observation, .present_answer, .scroll_small, .find_on_page, .stop_missing_context, .stop_success],
				forceObserveNext: false,
				semanticReadiness: nil,
				evidenceState: state
			)
			check("missing_price_routes_to_find_on_page",
				  decision.nextAction == .find_on_page)
			check("missing_price_query_is_price",
				  decision.findQuery == "price")
		}

		// MARK: 11 — Evidence satisfied + facts present → summarize/present allowed

		do {
			let decider = AgenticDecider()
			let goal = "Compare Anker Laptop Chargers"
			let requirements = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: "shopping")
			let entities: [GroundedSemanticEntity] = [
				stubEntity(type: .productTitle, text: "Anker 140W USB-C Charger"),
				stubEntity(type: .heading, text: "Anker 100W Power Bank"),
				stubEntity(type: .specification, text: "140W"),
				stubEntity(type: .specification, text: "USB-C"),
			]
			let state = AgenticEvidenceAssessor.assess(
				goal: goal,
				requirements: requirements,
				entities: entities,
				extractedFactsCount: 2,
				hasUsableObservation: true
			)
			let evidenceObservations = [
				AgenticEvidenceObservation(id: "o1", kind: .productTitle, text: "Anker 140W USB-C Charger", normalized: "anker 140w usb-c charger", confidence: 0.9, source: .ocr, reason: ""),
				AgenticEvidenceObservation(id: "o2", kind: .comparisonCandidate, text: "Anker 100W Power Bank", normalized: "anker 100w power bank", confidence: 0.9, source: .ocr, reason: ""),
				AgenticEvidenceObservation(id: "o3", kind: .specs, text: "140W", normalized: "140w", confidence: 0.9, source: .ocr, reason: "")
			]
			
			let decision = await decider.decide(
				goal: goal,
				workflow: "shopping",
				observations: [stubObservation(quality: .rich)],
				extractedFacts: ["Product: Anker 140W USB-C Charger", "Spec: 140W"],
				stepIndex: 3,
				maxSteps: 8,
				llmCallsUsed: 5,
				llmCallsBudget: 5,
				ocrCallsUsed: 2,
				ocrCallsBudget: 3,
				legalActions: [.observe_once, .extract_facts, .summarize_observation, .present_answer, .scroll_small, .find_on_page, .stop_missing_context, .stop_success],
				forceObserveNext: false,
				semanticReadiness: nil,
				evidenceState: state,
				evidenceObservations: evidenceObservations,
				entities: entities
			)
			let allowedAfterSatisfied: Set<AgenticNextAction> = [.summarize_observation, .present_answer, .extract_facts]
			check("evidence_satisfied_does_not_force_control",
				  allowedAfterSatisfied.contains(decision.nextAction))
		}

		// MARK: 12 — Partial budget-exhausted → present_answer

		do {
			let decider = AgenticDecider()
			let goal = "Compare Anker Laptop Chargers"
			let requirements = AgenticEvidenceRequirementsInferrer.infer(goal: goal, workflow: "shopping")
			let entities: [GroundedSemanticEntity] = [
				stubEntity(type: .productTitle, text: "Anker 140W USB-C Charger"),
				stubEntity(type: .specification, text: "140W"),
				stubEntity(type: .specification, text: "USB-C"),
			]
			let state = AgenticEvidenceAssessor.assess(
				goal: goal,
				requirements: requirements,
				entities: entities,
				extractedFactsCount: 1,
				hasUsableObservation: true
			)
			let decision = await decider.decide(
				goal: goal,
				workflow: "shopping",
				observations: [stubObservation(quality: .rich)],
				extractedFacts: ["Product: Anker 140W USB-C Charger"],
				stepIndex: 7,
				maxSteps: 7, // step >= max-1 so steps_remaining <= 1
				llmCallsUsed: 5,
				llmCallsBudget: 5,
				ocrCallsUsed: 3,
				ocrCallsBudget: 3,
				legalActions: [.observe_once, .extract_facts, .summarize_observation, .present_answer, .stop_missing_context, .stop_success],
				forceObserveNext: false,
				semanticReadiness: nil,
				evidenceState: state
			)
			check("partial_budget_exhausted_presents",
				  decision.nextAction == .present_answer)
		}

		let ok = failures.isEmpty
		print("[AgenticEvidenceGateSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}

	// MARK: - Stubs

	private static func stubEntity(
		type: SemanticEntityType,
		text: String,
		normalized: String? = nil,
		confidence: Double = 0.75
	) -> GroundedSemanticEntity {
		GroundedSemanticEntity(
			id: "stub_\(type.rawValue)_\(text.hashValue)",
			type: type,
			text: text,
			normalizedValue: normalized,
			confidence: confidence,
			sourceNodeId: "stub_node",
			role: .heading,
			tags: []
		)
	}

	private static func stubObservation(quality: AgenticObservationQuality) -> AgenticObservation {
		AgenticObservation(
			stepIndex: 1,
			activeApp: "Firefox",
			windowTitle: "Anker Laptop Power Bank - Amazon",
			contextSummary: nil,
			selectedText: nil,
			ocrExcerpt: "Anker 140W USB-C Charger\n$129.99\n140W output",
			quality: quality,
			freshnessScore: 0.9,
			observedAt: Date(),
			sources: ["ocr_excerpt"],
			isPostControlObservation: false,
			snapshotID: UUID(),
			previousSnapshotID: nil,
			textHash: nil
		)
	}
}
