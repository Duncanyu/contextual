// GoalEvidenceAlignmentSelfTest.swift
//
// Self-test suite verifying the generalized goal/evidence alignment, cache protection,
// chrome filtering, and partial answer synthesis.

import Foundation

@MainActor
struct GoalEvidenceAlignmentSelfTest {
	
	static func run() {
		print("[GoalEvidenceAlignmentSelfTest] starting goal/evidence alignment tests...")
		
		testSearchCurrentContextIsRepaired()
		testNonRedundantSearchIsPassed()
		testEvidenceRequirementsAlignedContext()
		testPlanCacheStoresRepairedGoal()
		testFinalAnswerUsesGroundedEvidence()
		testGeneratedChromeFilterSuppression()
		testUnsafeActionsRejected()
		
		print("[GoalEvidenceAlignmentSelfTest] finished. ok=true, failures=0")
		print("[GoalEvidenceAlignmentSelfTest] env selftest ok=true")
	}
	
	// MARK: - Tests
	
	private static func testSearchCurrentContextIsRepaired() {
		let windowTitle = "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger..."
		let title = "Search for Anker Prime USB C Charger Block on Amazon"
		let goal = "Search for Anker Prime USB C Charger Block on Amazon"
		
		let decision = AgenticGoalAlignmentValidator.validate(
			title: title,
			goal: goal,
			workflow: "browsing",
			appName: "Safari",
			bundleId: "com.apple.safari",
			windowTitle: windowTitle,
			ocrExcerpt: "Anker Prime USB C Charger Block 160W GaN Phone Charger"
		)
		
		check("search_current_context_is_repaired", decision.status == .repaired)
		check("repaired_goal_has_context_extraction", decision.alignedGoal.contains("Extract useful product evidence"))
		check("repaired_goal_identifies_anker", decision.alignedGoal.contains("Anker Prime USB C Charger Block"))
		check("repaired_title_remains_original", decision.alignedTitle == title)
	}
	
	private static func testNonRedundantSearchIsPassed() {
		let windowTitle = "Apple MacBook Pro 14-inch Specs"
		let title = "Search for Anker Prime USB C Charger Block on Amazon"
		let goal = "Search for Anker Prime USB C Charger Block on Amazon"
		
		let decision = AgenticGoalAlignmentValidator.validate(
			title: title,
			goal: goal,
			workflow: "browsing",
			appName: "Safari",
			bundleId: "com.apple.safari",
			windowTitle: windowTitle,
			ocrExcerpt: "MacBook Pro M3 Max specs"
		)
		
		check("non_redundant_search_is_accepted", decision.status == .accepted)
		check("non_redundant_goal_unchanged", decision.alignedGoal == goal)
	}
	
	private static func testEvidenceRequirementsAlignedContext() {
		let windowTitle = "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger..."
		let goal = "Extract useful product evidence for Anker Prime USB C Charger Block"
		
		let reqs = AgenticEvidenceRequirementsInferrer.infer(
			goal: goal,
			workflow: "browsing",
			windowTitle: windowTitle,
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "com.apple.safari"
		)
		
		let kinds = reqs.map(\.kind)
		check("aligned_context_infers_product_title", kinds.contains(.productTitle))
		check("aligned_context_infers_specs", kinds.contains(.specs))
		check("aligned_context_does_not_infer_only_summary", !kinds.contains(.pageSummary) || kinds.contains(.productTitle))
	}
	
	private static func testPlanCacheStoresRepairedGoal() {
		let state = AppState()
		
		let originalGoal = "Search for Anker Prime USB C Charger Block on Amazon"
		let plan = AgenticTaskPlan(
			id: "agentic:test_cache_id",
			goal: originalGoal,
			workflow: "browsing",
			sourceProposalId: "prop_test_id",
			allowedActionFamilies: [.observe, .scroll, .stop],
			requiredObservations: ["ocr"],
			successCriteria: [originalGoal],
			stopConditions: [.success_criteria_met],
			maxSteps: 5,
			maxLLMCalls: 2,
			maxOCRCalls: 2,
			maxRuntimeSeconds: 30,
			requiresPermission: false,
			safetyLevel: .preview_only,
			createdAt: Date()
		)
		
		let execution = GeneratedExecutionAction(
			title: "Search Amazon",
			description: "Search for charger block",
			workflowType: .browsing,
			intentType: .summarize,
			confidence: 0.85,
			interruptionCost: 0.1,
			requiredContextTypes: [.fusedVisual],
			executionPlan: ExecutionPlan(primitives: [], estimatedCost: 0.2, estimatedRuntime: 10, requiresVision: false, requiresOCR: false, requiresUserIntent: false, requiredPermissions: [], fallbackBehavior: .degradeToSummary, executionBudget: .conservative, planConfidence: 0.85),
			explainabilitySummary: "test",
			generationSource: .hookComposer,
			targetAnchor: nil,
			createdAt: Date(),
			expirationDate: Date().addingTimeInterval(300),
			isReusable: false,
			reuseScore: 0.8
		)
		
		let candidate = GeneratedExecutionProposalCandidate(
			id: "prop_test_id",
			title: "Search Amazon",
			description: "Search Amazon",
			source: .hookComposer,
			workflowType: .browsing,
			intentType: .summarize,
			confidence: 0.85,
			interruptionCost: 0.1,
			explainabilitySummary: "test",
			expectedOutputSummary: "details",
			requiredContextTypes: [.fusedVisual],
			executionAction: execution,
			generatedActionId: nil,
			primitiveSignature: nil,
			isExecutableGeneratedProposal: true,
			executionMode: .interactive_loop
		)
		
		var alignedCandidate = candidate
		alignedCandidate.agenticPlan = plan
		
		// Prime snapshot in state so validator gets matching context
		let snapshot = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger...",
			bundleIdentifier: "com.apple.safari",
			inferredWorkflow: .browsing,
			recentOCRExcerpt: "Anker Prime USB C Charger Block 160W GaN Phone Charger"
		)
		state.updateLatestCanonicalSnapshot(snapshot)
		
		state.cacheGeneratedExecutionCandidateActions([alignedCandidate])
		
		if let cachedPlan = state.cachedAgenticPlan(candidateId: "prop_test_id") {
			check("cache_stores_repaired_goal", cachedPlan.goal.contains("Extract useful product evidence"))
			check("cache_does_not_store_bad_goal", cachedPlan.goal != originalGoal)
		} else {
			check("cache_lookup_failed", false)
		}
	}
	
	private static func testFinalAnswerUsesGroundedEvidence() {
		// Mock a session state with product title, specs, price in evidenceObservations
		let goal = "Extract useful product evidence for Anker Prime USB C Charger Block"
		let requirements = [
			AgenticEvidenceRequirement(kind: .productTitle, required: true),
			AgenticEvidenceRequirement(kind: .specs, required: true),
			AgenticEvidenceRequirement(kind: .price, required: false)
		]
		let state = AgenticEvidenceState(
			goal: goal,
			requirements: requirements,
			satisfied: [.productTitle, .specs, .price],
			missing: [],
			missingOptional: [],
			confidence: 1.0,
			shouldGatherMore: false,
			recommendedAction: .present
		)

		let session = AgenticSessionState(
			planId: UUID().uuidString,
			goal: goal,
			workflow: "browsing",
			stepIndex: 1,
			maxSteps: 5,
			llmCallsUsed: 0,
			ocrCallsUsed: 0,
			scrollsUsed: 0,
			findsUsed: 0,
			maxScrolls: 3,
			maxFinds: 3,
			startedAt: Date(),
			observations: [],
			extractedFacts: [],
			finalAnswer: nil,
			stopReason: .evidence_satisfied,
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
			evidenceObservations: [
				AgenticEvidenceObservation(id: "pt1", kind: .productTitle, text: "Anker Prime USB C Charger Block", normalized: "anker prime usb c charger block", confidence: 0.90, source: .windowTitle, reason: "wt"),
				AgenticEvidenceObservation(id: "sp1", kind: .specs, text: "160W 3-Port GaN", normalized: "160w 3 port gan", confidence: 0.85, source: .ocr, reason: "ocr"),
				AgenticEvidenceObservation(id: "pr1", kind: .price, text: "$47.49", normalized: "47 49", confidence: 0.80, source: .ocr, reason: "ocr")
			]
		)
		
		let runtime = AgenticRuntime()
		let answer = runtime.buildPremiumAnswerTestBridge(session: session)
		
		check("answer_contains_product_title", answer.contains("Product: Anker Prime USB C Charger Block"))
		check("answer_contains_specs", answer.contains("Specs: 160W 3-Port GaN") || answer.contains("Specs: 160W"))
		check("answer_contains_price", answer.contains("Price: $47.49"))
		check("answer_does_not_contain_no_relevant", !answer.contains("No relevant information found"))
	}
	
	private static func testGeneratedChromeFilterSuppression() {
		let goal = "Search for Anker Prime USB C Charger Block on Amazon"
		
		// 1. Exact goal match
		let r1 = GeneratedChromeFilter.shouldSuppress(line: goal, runtimeGoal: goal)
		check("suppress_exact_goal", r1.suppressed)
		
		// 2. Leaked prefix phrase
		let leakedPrefix = "Search for Anker Prime USB C Charger Block"
		let r2 = GeneratedChromeFilter.shouldSuppress(line: leakedPrefix, runtimeGoal: goal)
		check("suppress_prefix_phrase", r2.suppressed)
		check("suppress_reason_is_echo", r2.reason == "proposal_title_echo")
		
		// 3. Leading verb chrome heading
		let leakedHeading = "Search for Anker Prime"
		let r3 = GeneratedChromeFilter.shouldSuppress(line: leakedHeading, runtimeGoal: goal)
		check("suppress_chrome_heading", r3.suppressed)
	}
	
	private static func testUnsafeActionsRejected() {
		let title = "Purchase Apple TV"
		let goal = "Purchase Apple TV"
		
		let decision = AgenticGoalAlignmentValidator.validate(
			title: title,
			goal: goal,
			workflow: "browsing",
			appName: "Safari",
			bundleId: "com.apple.safari",
			windowTitle: "Apple TV",
			ocrExcerpt: "Apple TV purchase specs"
		)
		
		check("unsafe_action_is_rejected", decision.status == .rejected)
	}
	
	// MARK: - Helpers
	
	private static func check(_ name: String, _ condition: Bool) {
		if !condition {
			print("[GoalEvidenceAlignmentSelfTest] FAIL: \(name)")
			fatalError("[GoalEvidenceAlignmentSelfTest] test failed: \(name)")
		} else {
			print("[GoalEvidenceAlignmentSelfTest] PASS: \(name)")
		}
	}
}

// MARK: - Test extensions
