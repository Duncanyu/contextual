import Foundation

/// Bounded self-tests for the Phase 4S Stateful Agentic Loop.
/// Enabled by environment variable: CONTEXTUAL_RUN_STATEFUL_AGENTIC_LOOP_SELFTEST=1
enum StatefulAgenticLoopSelfTest {

	static func run() async -> Bool {
		print("[StatefulAgenticLoopSelfTest] starting stateful agentic loop tests...")
		var failures: [String] = []

		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[StatefulAgenticLoopSelfTest] FAIL: \(name)")
			} else {
				print("[StatefulAgenticLoopSelfTest] PASS: \(name)")
			}
		}

		let decider = AgenticDecider()
		let runtime = AgenticRuntime()

		// MARK: - Test 1: missing reviews chooses find_on_page reviews
		do {
			let goal = "Find product price and reviews"
			let requirements = [
				AgenticEvidenceRequirement(kind: .price, required: true),
				AgenticEvidenceRequirement(kind: .reviewText, required: true)
			]
			let satisfied: [AgenticEvidenceKind] = [.price]
			let missing: [AgenticEvidenceKind] = [.reviewText]
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: satisfied,
				missing: missing,
				missingOptional: [],
				confidence: 0.5,
				shouldGatherMore: true,
				recommendedAction: .findOnPage
			)
			
			let decision = await decider.decide(
				goal: goal,
				workflow: "browsing",
				observations: [makeObservation(app: "Safari", window: "Product page", contextSummary: "product page info")],
				extractedFacts: [],
				stepIndex: 1,
				maxSteps: 5,
				llmCallsUsed: 0,
				llmCallsBudget: 5,
				ocrCallsUsed: 0,
				ocrCallsBudget: 2,
				legalActions: [.find_on_page, .scroll_small],
				forceObserveNext: false,
				evidenceState: state
			)
			
			check("missing_reviews_chooses_find", decision.nextAction == .find_on_page)
			check("missing_reviews_query_is_reviews", decision.findQuery == "reviews")
		}

		// MARK: - Test 2: missing specs chooses find_on_page/details or scroll
		do {
			let goal = "Find the specifications and wattage of the charger"
			let requirements = [
				AgenticEvidenceRequirement(kind: .productTitle, required: true),
				AgenticEvidenceRequirement(kind: .specs, required: true)
			]
			let satisfied: [AgenticEvidenceKind] = [.productTitle]
			let missing: [AgenticEvidenceKind] = [.specs]
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: satisfied,
				missing: missing,
				missingOptional: [],
				confidence: 0.5,
				shouldGatherMore: true,
				recommendedAction: .findOnPage
			)
			
			let decision = await decider.decide(
				goal: goal,
				workflow: "browsing",
				observations: [makeObservation(app: "Safari", window: "Product page", contextSummary: "product details")],
				extractedFacts: [],
				stepIndex: 1,
				maxSteps: 5,
				llmCallsUsed: 0,
				llmCallsBudget: 5,
				ocrCallsUsed: 0,
				ocrCallsBudget: 2,
				legalActions: [.find_on_page, .scroll_small],
				forceObserveNext: false,
				evidenceState: state
			)
			
			check("missing_specs_chooses_find_or_scroll", decision.nextAction == .find_on_page || decision.nextAction == .scroll_small)
			check("missing_specs_query_contains_wattage_or_details", decision.findQuery == "wattage" || decision.findQuery == "details")
		}

		// MARK: - Test 3: compare missing second candidate chooses scroll/search
		do {
			let goal = "Compare AirPods Pro 2 versus AirPods 4"
			let requirements = [
				AgenticEvidenceRequirement(kind: .productTitle, required: true),
				AgenticEvidenceRequirement(kind: .comparisonCandidate, required: true)
			]
			let satisfied: [AgenticEvidenceKind] = [.productTitle]
			let missing: [AgenticEvidenceKind] = [.comparisonCandidate]
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: satisfied,
				missing: missing,
				missingOptional: [],
				confidence: 0.5,
				shouldGatherMore: true,
				recommendedAction: .scrollSmall
			)
			
			let decision = await decider.decide(
				goal: goal,
				workflow: "browsing",
				observations: [makeObservation(app: "Safari", window: "Comparison page", contextSummary: "apple page")],
				extractedFacts: [],
				stepIndex: 1,
				maxSteps: 5,
				llmCallsUsed: 0,
				llmCallsBudget: 5,
				ocrCallsUsed: 0,
				ocrCallsBudget: 2,
				legalActions: [.find_on_page, .scroll_small],
				forceObserveNext: false,
				evidenceState: state
			)
			
			check("compare_missing_second_candidate_chooses_scroll_or_find", decision.nextAction == .scroll_small || decision.nextAction == .find_on_page)
			if decision.nextAction == .find_on_page {
				check("compare_missing_second_candidate_query_is_compare", decision.findQuery == "compare")
			}
		}

		// MARK: - Test 4: rich OCR alone does not trigger final answer if evidence missing
		do {
			let goal = "Find Anker Charger price"
			let requirements = [
				AgenticEvidenceRequirement(kind: .productTitle, required: true),
				AgenticEvidenceRequirement(kind: .price, required: true)
			]
			let satisfied: [AgenticEvidenceKind] = [.productTitle]
			let missing: [AgenticEvidenceKind] = [.price]
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: satisfied,
				missing: missing,
				missingOptional: [],
				confidence: 0.5,
				shouldGatherMore: true,
				recommendedAction: .findOnPage
			)
			
			// Even though observations have usable content (usable/rich OCR), decider should choose safe control actions since price is still missing
			let decision = await decider.decide(
				goal: goal,
				workflow: "browsing",
				observations: [makeObservation(app: "Safari", window: "Anker Charger", ocrExcerpt: "Anker 140W Charger is high quality.")],
				extractedFacts: [],
				stepIndex: 1,
				maxSteps: 5,
				llmCallsUsed: 0,
				llmCallsBudget: 5,
				ocrCallsUsed: 1,
				ocrCallsBudget: 2,
				legalActions: [.find_on_page, .scroll_small, .present_answer],
				forceObserveNext: false,
				evidenceState: state
			)
			
			check("rich_ocr_alone_does_not_trigger_present", decision.nextAction != .present_answer)
		}

		// MARK: - Test 5: control success requires evidence delta
		do {
			let sessionBefore = makeSession(goal: "Price", satisfied: [.productTitle], missing: [.price])
			let snapshotBefore = makeSnapshot(ocr: "Title: Product A")
			let before = AgenticWorldStateSnapshot.capture(session: sessionBefore, snapshot: snapshotBefore)
			
			let sessionAfter = makeSession(goal: "Price", satisfied: [.productTitle], missing: [.price])
			let snapshotAfter = makeSnapshot(ocr: "Title: Product A (Visual shift)")
			let after = AgenticWorldStateSnapshot.capture(session: sessionAfter, snapshot: snapshotAfter)
			
			let ocrChanged = before.ocrHash != after.ocrHash
			let evidenceSatisfiedChanged = before.evidenceSatisfied != after.evidenceSatisfied
			
			check("visual_shift_changes_ocr_hash", ocrChanged)
			check("visual_shift_does_not_satisfy_evidence", !evidenceSatisfiedChanged)
		}

		// MARK: - Test 6: ineffective find then scroll switches strategy
		do {
			let goal = "Find Charger Price"
			let requirements = [
				AgenticEvidenceRequirement(kind: .productTitle, required: true),
				AgenticEvidenceRequirement(kind: .price, required: true)
			]
			// We tried find_on_page and it was ineffective
			let state = AgenticEvidenceState(
				goal: goal,
				requirements: requirements,
				satisfied: [.productTitle],
				missing: [.price],
				missingOptional: [],
				confidence: 0.5,
				shouldGatherMore: true,
				recommendedAction: .findOnPage
			)
			
			let decision = await decider.decide(
				goal: goal,
				workflow: "browsing",
				observations: [makeObservation(app: "Safari", window: "Anker")],
				extractedFacts: [],
				stepIndex: 2,
				maxSteps: 5,
				llmCallsUsed: 0,
				llmCallsBudget: 5,
				ocrCallsUsed: 1,
				ocrCallsBudget: 2,
				legalActions: [.find_on_page, .scroll_small],
				forceObserveNext: false,
				evidenceState: state,
				priorActions: [AgenticNextAction.find_on_page.rawValue],
				ineffectiveControlCount: 1
			)
			
			check("ineffective_find_switches_to_scroll", decision.nextAction == .scroll_small)
		}

		// MARK: - Test 7: partial answer includes found evidence, not "No relevant information found"
		do {
			var session = makeSession(goal: "Find charger details", satisfied: [.productTitle, .specs], missing: [.price, .reviewText])
			session.structuredFacts = [
				StructuredFact(id: "fact_product_1", category: "product", title: "Anker 140W Charger", attributes: ["specs": "140W, 4-Port, GaN"], confidence: 0.9, sourceEntityIds: [])
			]
			session.semanticEntities = [
				GroundedSemanticEntity(id: "e1", type: .productTitle, text: "Anker 140W Charger", normalizedValue: nil, confidence: 0.9, sourceNodeId: "n1", role: .heading, tags: []),
				GroundedSemanticEntity(id: "e2", type: .specification, text: "140W, 4-Port, GaN", normalizedValue: nil, confidence: 0.8, sourceNodeId: "n2", role: .bodyText, tags: [])
			]
			
			_ = await runtime.execute(plan: makePlan(goal: "Find price", maxSteps: 1), action: nil, snapshot: nil)
			let partialAnswer = runtime.buildPremiumAnswerTest(session: session)
			
			check("partial_answer_contains_product_title", partialAnswer.contains("Anker 140W Charger"))
			check("partial_answer_contains_specs", partialAnswer.contains("140W, 4-Port, GaN"))
			check("partial_answer_shows_missing_price", partialAnswer.contains("price not visible"))
			check("partial_answer_shows_missing_reviews", partialAnswer.contains("reviews not found"))
			check("partial_answer_does_not_contain_no_relevant", !partialAnswer.contains("No relevant information found"))
		}

		// MARK: - Test 8: evidence satisfied leads to summarize/present
		do {
			let goal = "Find details"
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
			
			let decision = await decider.decide(
				goal: goal,
				workflow: "browsing",
				observations: [makeObservation(app: "Safari", window: "Anker")],
				extractedFacts: ["Summary: Anker is found"],
				stepIndex: 2,
				maxSteps: 5,
				llmCallsUsed: 0,
				llmCallsBudget: 5,
				ocrCallsUsed: 1,
				ocrCallsBudget: 2,
				legalActions: [.extract_facts, .summarize_observation, .present_answer],
				forceObserveNext: false,
				evidenceState: state,
				evidenceObservations: [
					AgenticEvidenceObservation(
						id: "test_obs",
						kind: .productTitle,
						text: "Anker 140W Charger",
						normalized: "anker 140w charger",
						confidence: 0.9,
						source: .windowTitle,
						reason: "test"
					)
				]
			)
			
			check("evidence_satisfied_leads_to_present_or_summarize", decision.nextAction == .present_answer || decision.nextAction == .summarize_observation || decision.nextAction == .extract_facts)
		}

		// MARK: - Test 9: world-state transition detects evidence improvement
		do {
			let sessionBefore = makeSession(goal: "Price", satisfied: [.productTitle], missing: [.price])
			let snapshotBefore = makeSnapshot(ocr: "Title: Product A")
			let before = AgenticWorldStateSnapshot.capture(session: sessionBefore, snapshot: snapshotBefore)
			
			let sessionAfter = makeSession(goal: "Price", satisfied: [.productTitle, .price], missing: [])
			let snapshotAfter = makeSnapshot(ocr: "Title: Product A | Price: $29")
			let after = AgenticWorldStateSnapshot.capture(session: sessionAfter, snapshot: snapshotAfter)
			
			let newlySatisfied = after.evidenceSatisfied.subtracting(before.evidenceSatisfied)
			check("newly_satisfied_contains_price", newlySatisfied.contains("price"))
		}

		// MARK: - Test 10: focus mismatch blocks control
		do {
			let policy = AgenticControlPolicy()
				let context = AgenticControlPolicyContext(
					action: .scroll_small,
					bundleIdentifier: "com.apple.Safari",
					windowTitle: "Search Results",
					activeApp: "Safari",
					workflow: "browsing",
					stepIndex: 1,
					maxSteps: 5,
					priorActions: [],
					scrollsUsed: 0,
					findsUsed: 0,
					ocrCallsUsed: 0,
					ocrCallsBudget: 2,
					maxScrolls: 2,
					maxFinds: 1,
					dryRun: false,
					expectedTargetBundle: "com.google.Chrome",
					currentFrontmostBundle: "com.apple.Safari" // Frontmost app doesn't match expected target!
				)
			
			let result = policy.evaluate(context)
			check("focus_mismatch_blocks_control", !result.allowed)
			check("focus_mismatch_reason_is_frontmost_mismatch", result.reason == "frontmost_mismatch")
		}

		let ok = failures.isEmpty
		print("[StatefulAgenticLoopSelfTest] finished. ok=\(ok), failures=\(failures.count)")
		return ok
	}

	// MARK: - Helpers

	private static func makeObservation(
		app: String,
		window: String,
		selectedText: String? = nil,
		contextSummary: String? = nil,
		ocrExcerpt: String? = nil
	) -> AgenticObservation {
		AgenticObservation(
			stepIndex: 1,
			activeApp: app,
			windowTitle: window,
			contextSummary: contextSummary,
			selectedText: selectedText,
			ocrExcerpt: ocrExcerpt,
			quality: ocrExcerpt != nil || selectedText != nil ? .usable : .weak,
			freshnessScore: 0.8,
			observedAt: Date(),
			sources: [],
			isPostControlObservation: false,
			snapshotID: UUID(),
			previousSnapshotID: nil,
			textHash: "somehash"
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
			recommendedAction: .findOnPage
		)
		
		return AgenticSessionState(
			planId: UUID().uuidString,
			goal: goal,
			workflow: "browsing",
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

	private static func makeSnapshot(ocr: String) -> CanonicalGeneratedExecutionContextSnapshot {
		CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "Product page",
			bundleIdentifier: "com.apple.Safari",
			inferredWorkflow: .browsing,
			inferredIntent: nil,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: ocr,
			contextSummary: nil,
			workflowConfidence: 0.9,
			availableContextTypes: [],
			visualContextAvailability: .init(),
			permissionAvailability: [:],
			generatedAt: Date(),
			freshnessScore: 0.9
		)
	}

	private static func makePlan(goal: String, maxSteps: Int) -> AgenticTaskPlan {
		AgenticTaskPlan(
			id: UUID().uuidString,
			goal: goal,
			workflow: "browsing",
			sourceProposalId: nil,
			allowedActionFamilies: [.observe, .extract, .summarize, .present, .stop],
			requiredObservations: [],
			successCriteria: [],
			stopConditions: [],
			maxSteps: maxSteps,
			maxLLMCalls: 5,
			maxOCRCalls: 2,
			maxRuntimeSeconds: 15,
			requiresPermission: false,
			safetyLevel: .preview_only,
			createdAt: Date()
		)
	}
}

extension AgenticRuntime {
	nonisolated fileprivate func buildPremiumAnswerTest(session: AgenticSessionState) -> String {
		return self.buildPremiumAnswerTestBridge(session: session)
	}
}
