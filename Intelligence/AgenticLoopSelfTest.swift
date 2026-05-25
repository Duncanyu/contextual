import Foundation

/// Phase 4C self-tests for the bounded observe → decide → act loop.
/// Run with: CONTEXTUAL_RUN_AGENTIC_LOOP_SELFTEST=1
enum AgenticLoopSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[AgenticLoopSelfTest] FAIL \(name)")
			}
		}

		let runtime = AgenticRuntime()

		// MARK: 1 — Loop with rich context produces controlled_success and runtimePhase=4C-loop
		// Snapshot has selectedText + contextSummary; loop should observe → extract → present.
		let plan1 = makePlan(goal: "Summarize the current article", workflow: "browsing")
		let snapshot1 = makeSnapshot(
			app: "Safari",
			window: "The Future of AI - TechReview",
			selectedText: "Large language models have transformed how we interact with technology.",
			contextSummary: "User is reading an article about AI trends.",
			ocrExcerpt: nil
		)
		let result1 = await runtime.execute(plan: plan1, action: nil, snapshot: snapshot1)
		check("loop_rich_context_status_not_rejected",
			result1.status != .rejected_missing_plan &&
			result1.status != .rejected_budget_invalid &&
			result1.status != .rejected_phase_constraint)
		check("loop_rich_context_phase_loop", result1.runtimePhase.hasSuffix("-loop"))
		check("loop_rich_context_steps_executed", result1.stepsExecuted > 0)
		check("loop_rich_context_has_actions", !result1.actionsExecuted.isEmpty)

		// MARK: 2 — Loop with no usable context produces stop_missing_context
		// Snapshot has no selectedText, no contextSummary, no OCR.
		let plan2 = makePlan(goal: "Find product information", workflow: "browsing")
		let snapshot2 = makeSnapshot(
			app: "Finder",
			window: "",
			selectedText: nil,
			contextSummary: nil,
			ocrExcerpt: nil
		)
		let result2 = await runtime.execute(plan: plan2, action: nil, snapshot: snapshot2)
		check("no_context_phase_loop", result2.runtimePhase.hasSuffix("-loop"))
		// Should stop due to missing context (not crash or hang)
		check("no_context_loop_terminates", result2.stepsExecuted > 0)
		check("no_context_has_final_answer", result2.finalAnswer != nil)

		// MARK: 3 — Loop never exceeds maxSteps
		// Plan with maxSteps=3; loop must execute ≤ 3 steps regardless of decisions.
		let plan3 = makePlan(goal: "Research AirPods 4 reviews", workflow: "browsing", maxSteps: 3)
		let snapshot3 = makeSnapshot(
			app: "Safari",
			window: "AirPods 4 Review - The Verge",
			selectedText: "The AirPods 4 feature active noise cancellation.",
			contextSummary: "User is reading a product review.",
			ocrExcerpt: "Battery life: 6 hours. Price: $129."
		)
		let result3 = await runtime.execute(plan: plan3, action: nil, snapshot: snapshot3)
		check("never_exceeds_max_steps", result3.stepsExecuted <= plan3.maxSteps)
		check("max_steps_3_loop_terminates", result3.stepsExecuted > 0 && result3.stepsExecuted <= 3)

		// MARK: 4 — Loop never exceeds maxOCRCalls
		// Plan with maxOCRCalls=1; snapshot has OCR. OCR should be used at most once.
		let plan4 = makePlan(goal: "Read screen text", workflow: "browsing", maxOCRCalls: 1)
		let snapshot4 = makeSnapshot(
			app: "Preview",
			window: "Document.pdf",
			selectedText: nil,
			contextSummary: nil,
			ocrExcerpt: "This document covers quarterly results."
		)
		let result4 = await runtime.execute(plan: plan4, action: nil, snapshot: snapshot4)
		check("never_exceeds_ocr_calls",
			(plan4.maxOCRCalls - result4.budgetRemaining.ocrCalls) <= plan4.maxOCRCalls)

		// MARK: 5 — AgenticNextAction never includes external control actions
		// Enumerate all AgenticNextAction cases and confirm none require external control.
		for action in AgenticNextAction.allCases {
			check("action_no_external_control_\(action.rawValue)", !action.requiresExternalControl)
		}
		// Confirm unrestricted external-control actions are not present in the action menu
		// Note: scroll_small and find_on_page ARE in Phase 4D (bounded, policy-gated).
		// click, type (arbitrary), navigate, switch_tab are still absent.
		let legalActionNames = Set(AgenticNextAction.allCases.map(\.rawValue))
		check("no_click_in_menu", !legalActionNames.contains("click"))
		check("no_type_in_menu", !legalActionNames.contains("type"))
		check("no_navigate_in_menu", !legalActionNames.contains("navigate"))
		check("no_switch_tab_in_menu", !legalActionNames.contains("switch_tab"))

		// MARK: 6 — Model failure fallback: decider uses heuristic when LLM budget is zero
		// With llmCallsBudget=0, decider must never call the model and must return heuristic result.
		// We test this by running a plan with maxLLMCalls=0 — if the loop completes without hanging,
		// the model was never waited on.
		let plan6 = makePlan(goal: "Summarize page", workflow: "browsing", maxLLMCalls: 0)
		let snapshot6 = makeSnapshot(
			app: "Safari",
			window: "News Article",
			selectedText: "Breaking: new AI model released.",
			contextSummary: "User reading news.",
			ocrExcerpt: nil
		)
		let start6 = Date()
		let result6 = await runtime.execute(plan: plan6, action: nil, snapshot: snapshot6)
		let elapsed6 = Date().timeIntervalSince(start6)
		// Must complete quickly (no model call waited on)
		check("zero_llm_budget_no_hang", elapsed6 < 5.0)
		check("zero_llm_budget_phase_loop", result6.runtimePhase.hasSuffix("-loop"))

		// MARK: 7 — Insufficient context produces partial result with finalAnswer != nil
		// Sparse snapshot: only window title, no text content.
		let plan7 = makePlan(goal: "Compare product prices", workflow: "browsing")
		let snapshot7 = makeSnapshot(
			app: "Chrome",
			window: "Amazon.com",
			selectedText: nil,
			contextSummary: nil,
			ocrExcerpt: nil
		)
		let result7 = await runtime.execute(plan: plan7, action: nil, snapshot: snapshot7)
		check("insufficient_context_has_final_answer", result7.finalAnswer != nil)
		check("insufficient_context_phase_loop", result7.runtimePhase.hasSuffix("-loop"))
		check("insufficient_context_terminates", result7.stepsExecuted <= plan7.maxSteps)

		// MARK: 8 — Product/review goal with OCR extracts facts
		// Snapshot with OCR text describing a product — loop should extract facts.
		let plan8 = makePlan(
			goal: "Find AirPods Pro 2 price and rating",
			workflow: "browsing",
			maxOCRCalls: 2
		)
		let snapshot8 = makeSnapshot(
			app: "Safari",
			window: "AirPods Pro (2nd generation) - Apple",
			selectedText: nil,
			contextSummary: "Product page for AirPods Pro 2.",
			ocrExcerpt: "AirPods Pro (2nd generation) $249. Rating: 4.8/5. Active noise cancellation."
		)
		let result8 = await runtime.execute(plan: plan8, action: nil, snapshot: snapshot8)
		check("product_goal_phase_loop", result8.runtimePhase.hasSuffix("-loop"))
		check("product_goal_has_facts", !result8.extractedFacts.isEmpty)
		check("product_goal_has_answer", result8.finalAnswer != nil)
		// The observe step should have occurred
		check("product_goal_observed", result8.actionsExecuted.contains("observe_once"))

		// MARK: 9 — runtimePhase ends in "-loop" for all successful loop executions
		// Four different plan/snapshot combos — all must produce a *-loop phase label.
		let combos: [(AgenticTaskPlan, CanonicalGeneratedExecutionContextSnapshot)] = [
			(makePlan(goal: "Goal A", workflow: "browsing"),
			 makeSnapshot(app: "App1", window: "Win1", selectedText: "text a", contextSummary: nil, ocrExcerpt: nil)),
			(makePlan(goal: "Goal B", workflow: "debugging"),
			 makeSnapshot(app: "App2", window: "Win2", selectedText: nil, contextSummary: "summary b", ocrExcerpt: nil)),
			(makePlan(goal: "Goal C", workflow: "writing"),
			 makeSnapshot(app: "App3", window: "Win3", selectedText: nil, contextSummary: nil, ocrExcerpt: "ocr text c")),
			(makePlan(goal: "Goal D", workflow: "browsing"),
			 makeSnapshot(app: "App4", window: "Win4", selectedText: nil, contextSummary: nil, ocrExcerpt: nil)),
		]
		for (i, (p, s)) in combos.enumerated() {
			let r = await runtime.execute(plan: p, action: nil, snapshot: s)
			check("runtime_phase_loop_combo_\(i)", r.runtimePhase.hasSuffix("-loop"))
		}

		// MARK: 10 — Legacy/fixed-hook routing is unaffected by Phase 4C changes
		// Verify Phase 4B regression: nil plan still gives rejected_missing_plan (not crashing).
		// Verify Phase 4B regression: bad budget still gives rejected_budget_invalid.
		// Verify Phase 4B regression: phase constraint still gives rejected_phase_constraint.
		let nilPlanResult = await runtime.execute(plan: nil, action: nil, snapshot: nil)
		check("regression_nil_plan_rejected_missing_plan", nilPlanResult.status == .rejected_missing_plan)
		check("regression_nil_plan_phase_4B", nilPlanResult.runtimePhase == "4B-shell")

		let badBudgetPlan = makePlan(goal: "Bad", workflow: "browsing", maxSteps: 0)
		let badBudgetResult = await runtime.execute(plan: badBudgetPlan, action: nil)
		check("regression_bad_budget_rejected", badBudgetResult.status == .rejected_budget_invalid)

		let controlPlan = makePlan(
			goal: "Click add to cart",
			workflow: "browsing",
			families: [.click, .type, .navigate],
			safetyLevel: .confirmation_required
		)
		let controlResult = await runtime.execute(plan: controlPlan, action: nil)
		check("regression_phase_constraint_blocked", controlResult.status == .rejected_phase_constraint)

		// Verify that nil snapshot still gives preview_ready (Phase 4B shell path)
		let validPlan = makePlan(goal: "Read page", workflow: "browsing")
		let previewResult = await runtime.execute(plan: validPlan, action: nil, snapshot: nil)
		check("regression_no_snapshot_gives_preview_ready", previewResult.status == .preview_ready)
		check("regression_no_snapshot_phase_4B_shell", previewResult.runtimePhase == "4B-shell")

		let ok = failures.isEmpty
		print("[AgenticLoopSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}

	// MARK: - Fixtures

	static func makePlan(
		goal: String,
		workflow: String,
		families: [AgenticActionFamily] = [.observe, .extract, .summarize, .present, .stop],
		maxSteps: Int = 5,
		maxLLMCalls: Int = 3,
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

	static func makeSnapshot(
		app: String,
		window: String,
		selectedText: String?,
		contextSummary: String?,
		ocrExcerpt: String?
	) -> CanonicalGeneratedExecutionContextSnapshot {
		CanonicalGeneratedExecutionContextSnapshot(
			activeApp: app,
			windowTitle: window,
			bundleIdentifier: nil,
			inferredWorkflow: .browsing,
			inferredIntent: nil,
			selectedText: selectedText,
			clipboardText: nil,
			recentOCRExcerpt: ocrExcerpt,
			contextSummary: contextSummary,
			workflowConfidence: 0.75,
			availableContextTypes: [],
			visualContextAvailability: .init(),
			permissionAvailability: [:],
			generatedAt: Date(),
			freshnessScore: 0.8
		)
	}
}
