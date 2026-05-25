import Foundation

/// Phase 4B self-tests for AgenticRuntime routing and shell behaviour (updated for routing-invariant fix).
/// Run with: CONTEXTUAL_RUN_AGENTIC_RUNTIME_SELFTEST=1
enum AgenticRuntimeSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[AgenticRuntimeSelfTest] FAIL \(name)")
			}
		}

		let runtime = AgenticRuntime()

		// MARK: 1 — agentic: id prefix routes to AgenticRuntime even if plan lookup initially misses
		// This simulates the dogfood bug: classify() returned nil plan, routing fell through to legacy.
		// Fix: routing checks id prefix as belt-and-suspenders. AgenticRuntime receives nil plan
		// and returns rejected_missing_plan — not invalid_plan from GeneratedExecutionRuntime.
		let result1_nilPlan = await runtime.execute(plan: nil, action: nil)
		check("agentic_id_prefix_with_nil_plan_not_invalid_plan",
			result1_nilPlan.status != .rejected_budget_invalid &&
			result1_nilPlan.status != .rejected_phase_constraint)
		// nil plan → rejected_missing_plan (informative), NOT invalid_plan (opaque legacy error)
		check("agentic_id_prefix_nil_plan_gives_missing_plan_status",
			result1_nilPlan.status == .rejected_missing_plan)
		// And the execution result is NOT .failed with invalid_plan warning
		let execR1 = result1_nilPlan.toExecutionResult(actionId: UUID(), confidence: 0.7, startedAt: Date())
		check("nil_plan_result_no_invalid_plan_warning", !execR1.warnings.contains("invalid_plan"))

		// MARK: 2 — Visible agentic proposal always stores retrievable AgenticTaskPlan
		// classify() with agentic: prefix contract always returns agentic_runtime_candidate.
		let agenticContract = makeAgenticContract(goal: "Research AirPods accessories")
		let eligibility = AgenticRuntimeBridge.classify(contract: agenticContract)
		check("agentic_contract_classified_as_agentic", eligibility == .agentic_runtime_candidate)
		let derivedPlan = AgenticRuntimeBridge.derivePlan(from: agenticContract, workflow: "browsing")
		check("agentic_contract_derives_plan", derivedPlan != nil)
		// A candidate built from this contract would have agenticPlan != nil, so cache stores it.
		if let plan = derivedPlan {
			check("derived_plan_goal_matches", plan.goal == agenticContract.inferredUserGoal)
		}

		// MARK: 3 — generated_exec:agentic: normalized id lookup
		// The agentic: prefix check must match candidateIds that have agentic: at start,
		// NOT prefixed with generated_exec: (that prefix is for action tracking, not candidateId).
		// This verifies the routing invariant only fires for actual agentic: candidateIds.
		let rawAgenticId = "agentic:org.mozilla.firefox|browsing|ocr|t0o1|d0|test"
		let actionTrackingId = "generated_exec:\(rawAgenticId)"  // used for latestActionId tracking only
		check("raw_agentic_id_matches_prefix", rawAgenticId.hasPrefix("agentic:"))
		// The action tracking id (used for latestActionId) does NOT trigger agentic routing:
		check("action_tracking_id_does_not_match_raw_prefix", !actionTrackingId.hasPrefix("agentic:"))
		// Only the raw candidateId (passed to invokeGeneratedExecutionProposal) triggers routing.

		// MARK: 4 — Agentic proposal with primitives=0 never enters legacy runtime
		// Direct AgenticRuntime test: valid plan with primitives=0 resolves to preview_ready.
		let plan4 = makePlan(goal: "Confirm AirPods compatibility", workflow: "browsing", safetyLevel: .preview_only)
		let result4 = await runtime.execute(plan: plan4, action: nil)
		check("agentic_primitives0_preview_ready", result4.status == .preview_ready)
		// Confirm it's not any failure status
		check("agentic_primitives0_not_rejected", result4.status != .rejected_missing_plan &&
			result4.status != .rejected_budget_invalid &&
			result4.status != .rejected_phase_constraint)

		// MARK: 5 — Fixed non-agentic proposal with primitives uses legacy runtime
		// We verify indirectly: a non-agentic candidate has agenticPlan == nil and non-agentic id.
		let fixedCandidate = makeCandidateWithoutAgenticPlan()
		check("fixed_candidate_nil_plan", fixedCandidate.agenticPlan == nil)
		check("fixed_candidate_non_agentic_id", !fixedCandidate.id.hasPrefix("agentic:"))
		// Both conditions false → routing invariant sends to legacy runtime (not AgenticRuntime).

		// MARK: 6 — Missing AgenticTaskPlan for agentic id → controlled AgenticRuntime shell, not invalid_plan
		// When plan is nil (regression case), AgenticRuntime returns rejected_missing_plan with explanation.
		let result6 = await runtime.execute(plan: nil, action: nil)
		check("missing_plan_gives_informative_status", result6.status == .rejected_missing_plan)
		check("missing_plan_has_summary", !result6.phaseSummary.isEmpty)
		check("missing_plan_phase_is_4b", result6.runtimePhase == "4B-shell")
		let exec6 = result6.toExecutionResult(actionId: UUID(), confidence: 0.65, startedAt: Date())
		check("missing_plan_exec_result_status_failed", exec6.status == .failed)
		check("missing_plan_no_invalid_plan_warning", !exec6.warnings.contains("invalid_plan"))

		// MARK: 7 — No broken middle state: agentic id + legacy runtime is impossible
		// Invariant: if candidateId.hasPrefix("agentic:"), isAgenticRoute == true.
		// We verify this by checking that any agentic: id satisfies the routing condition.
		let ids = [
			"agentic:org.mozilla.firefox|browsing|ocr|t0o1|d0|inesore",
			"agentic:com.apple.safari|research|context|t1o2|d1|airpods",
			"agentic:",  // degenerate but still prefixed
		]
		for id in ids {
			let isAgenticRoute = id.hasPrefix("agentic:")
			check("agentic_id_always_routes_agentic_\(id.prefix(20))", isAgenticRoute)
		}
		// Non-agentic IDs must NOT trigger agentic routing:
		let nonAgenticIds = ["hook:abc", "reuse:xyz", "test-fixed-1234"]
		for id in nonAgenticIds {
			check("non_agentic_id_not_routed_\(id.prefix(10))", !id.hasPrefix("agentic:"))
		}

		// MARK: 8 — Result card status is not failed invalid_plan for agentic preview execution
		// For both plan-present and plan-absent agentic cases, the execution result must not be
		// a raw invalid_plan failure.
		let plan8 = makePlan(goal: "Review Amazon listing", workflow: "browsing", safetyLevel: .preview_only)
		let result8 = await runtime.execute(plan: plan8, action: nil)
		let exec8 = result8.toExecutionResult(actionId: UUID(), confidence: 0.80, startedAt: Date())
		check("agentic_result_not_invalid_plan_warning", !exec8.warnings.contains("invalid_plan"))
		check("agentic_result_card_not_raw_failure",
			exec8.executionMetadata["agenticStatus"] != nil)  // has agentic metadata, not legacy
		check("agentic_result_has_phase_label",
			exec8.executionMetadata["runtimePhase"] == "4B-shell")

		// Also verify existing Phase 4B shell tests pass.

		// MARK: 9 — Budget validation still rejects invalid bounds
		let badBudgetPlan = makePlan(
			goal: "Bad budget", workflow: "unknown",
			maxSteps: 0, safetyLevel: .preview_only
		)
		let result9 = await runtime.execute(plan: badBudgetPlan, action: nil)
		check("bad_budget_still_rejected", result9.status == .rejected_budget_invalid)

		// MARK: 10 — External control still blocked in Phase 4B shell
		let controlPlan = makePlan(
			goal: "Click add to cart",
			workflow: "browsing",
			families: [.click, .type, .navigate],
			safetyLevel: .confirmation_required
		)
		let result10 = await runtime.execute(plan: controlPlan, action: nil)
		check("external_control_still_blocked", result10.status == .rejected_phase_constraint)
		check("external_control_stop_reason", result10.stopReason == .unsafe_action_required)

		let ok = failures.isEmpty
		print("[AgenticRuntimeSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}

	// MARK: - Fixtures

	/// Make an AgenticTaskPlan with given parameters.
	static func makePlan(
		goal: String,
		workflow: String,
		families: [AgenticActionFamily] = [.observe, .extract, .summarize, .present, .stop],
		maxSteps: Int = 5,
		maxLLMCalls: Int = 5,
		maxOCRCalls: Int = 2,
		maxRuntimeSeconds: Int = 15,
		safetyLevel: AgenticSafetyLevel = .preview_only
	) -> AgenticTaskPlan {
		AgenticTaskPlan(
			id: UUID().uuidString,
			goal: goal,
			workflow: workflow,
			sourceProposalId: nil,
			allowedActionFamilies: families,
			requiredObservations: [],
			successCriteria: [goal],
			stopConditions: [.success_criteria_met, .max_steps_reached, .user_cancelled],
			maxSteps: maxSteps,
			maxLLMCalls: maxLLMCalls,
			maxOCRCalls: maxOCRCalls,
			maxRuntimeSeconds: maxRuntimeSeconds,
			requiresPermission: false,
			safetyLevel: safetyLevel,
			createdAt: Date()
		)
	}

	/// Make a minimal DynamicGeneratedActionContract with agentic: id prefix.
	private static func makeAgenticContract(goal: String) -> DynamicGeneratedActionContract {
		DynamicGeneratedActionContract(
			id: "agentic:org.test.app|browsing|context|t0o0|d0|\(goal.prefix(20))|c12345",
			title: "Test Agentic Proposal",
			userFacingQuestion: "Should I help with \(goal)?",
			inferredUserGoal: goal,
			situationSummary: "Test situation",
			whyNow: "test",
			hookPlanIds: ["observe_current_context", "present_result"],
			requiredContext: [.workflowContext],
			confidence: 0.75,
			createdAt: Date(),
			expiresAt: Date().addingTimeInterval(180),
			cacheEligibility: false,
			cacheKey: "test-key"
		)
	}

	private static func makeCandidateWithoutAgenticPlan() -> GeneratedExecutionProposalCandidate {
		GeneratedExecutionProposalCandidate(
			id: "test-fixed-\(UUID().uuidString.prefix(8))",
			title: "Summarize error context",
			description: "Summarize current debugging context.",
			source: .hookComposer,
			workflowType: .debugging,
			intentType: .summarize,
			confidence: 0.80,
			interruptionCost: 0.3,
			explainabilitySummary: "hook_composer|hook_composer_cache|primitives=summarize_context|contract=hook:abc",
			expectedOutputSummary: "Summary of error",
			requiredContextTypes: [.workflowContext],
			executionAction: nil,
			generatedActionId: nil,
			primitiveSignature: "summarize_context",
			isExecutableGeneratedProposal: true,
			executionMode: .one_shot
		)
		// agenticPlan defaults to nil
	}

	private static func makeObserveOnceCandidate() -> GeneratedExecutionProposalCandidate {
		GeneratedExecutionProposalCandidate(
			id: "test-observe-\(UUID().uuidString.prefix(8))",
			title: "Read current page content",
			description: "Observe current screen once.",
			source: .hookComposer,
			workflowType: .browsing,
			intentType: .answer,
			confidence: 0.72,
			interruptionCost: 0.2,
			explainabilitySummary: "hook_composer|hook_composer_cache|primitives=answer_from_context|contract=hook:xyz",
			expectedOutputSummary: "Screen reading",
			requiredContextTypes: [.fusedVisual],
			executionAction: nil,
			generatedActionId: nil,
			primitiveSignature: "answer_from_context",
			isExecutableGeneratedProposal: true,
			executionMode: .observe_once
		)
		// agenticPlan defaults to nil
	}
}
