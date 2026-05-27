import Foundation

/// Phase 4S — Pending action-intent retry must reach planner
///
/// Ensures that when we retry after warmup due to a fast-visibility action-worthy
/// context, we do not allow the router to terminate the pipeline with
/// `need_more_context` purely because selection is missing.
///
/// Run with: `CONTEXTUAL_RUN_ACTION_INTENT_PLANNER_BRIDGE_SELFTEST=1`
enum ActionIntentPlannerBridgeSelfTest {
	actor StubModelManager: DynamicGeneratedProposalAvailabilityChecking {
		func isGenerationAvailable() async -> Bool { true }
	}

	actor StubLLM: TaskInferenceLLMGenerating {
		var routerCalls = 0
		var plannerCalls = 0

		func generate(
			prompt: String,
			model: String,
			numPredict: Int,
			temperature: Double,
			purpose: String?,
			schema: [String: Any]?
		) async throws -> String {
			"{}"
		}

		func generateStreamingJSON(
			prompt: String,
			model: String,
			numPredict: Int,
			temperature: Double,
			purpose: String?,
			schema: [String: Any]?,
			onProgress: (@Sendable (String) -> Void)?
		) async throws -> String {
			if purpose == "task_inference_router" {
				routerCalls += 1
				// Router asks for selection, but this must be overridden when forcePlanner is true.
				return #"{"decision":"need_more_context","request":["selected_text","window_title"],"confidence":0.8,"reason":"wants selection"}"#
			}
			if purpose == "task_inference_planner" {
				plannerCalls += 1
				// Minimal valid planner output with one safe candidate.
				return #"{"should_surface_softly":true,"actions":[{"title":"Review Anker Prime USB C Charger","caps":"extract","confidence":0.85,"why_useful":"grounded review","novelty":0.5,"requires":["title"]}]}"#
			}
			return #"{}"#
		}
	}

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				print("[ActionIntentPlannerBridgeSelfTest] FAIL \(name)")
				failures.append(name)
			} else {
				print("[ActionIntentPlannerBridgeSelfTest] PASS \(name)")
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
			recentOCRExcerpt: nil,
			contextSummary: "",
			workflowConfidence: 0.35,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.9
		)
		let situational = SituationalContextSynthesizer.synthesize(from: snap, referenceTime: now)
		let stubLLM = StubLLM()
		let engine = TaskInferenceEngine(modelManager: StubModelManager(), llm: stubLLM)

		let result = await engine.infer(
			snapshot: snap,
			situational: situational,
			recentTitles: [snap.windowTitle],
			history: nil,
			referenceTime: now,
			isEnrichedPass: true,
			isWarmupReady: true,
			forcePlannerFromPendingActionIntentRetry: true
		)

		check("result_non_nil", result != nil)
		check("result_should_chime", result?.shouldChime == true)
		let plannerCalls = await stubLLM.plannerCalls
		check("planner_called_despite_router_need_more_context", plannerCalls >= 1)

		// Negative case: if the title is browser chrome / generic, forcePlanner flag must
		// NOT cause planner execution.
		let weakSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Firefox",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: "",
			workflowConfidence: 0.2,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.2
		)
		let weakSituational = SituationalContextSynthesizer.synthesize(from: weakSnap, referenceTime: now)
		let before = await stubLLM.plannerCalls
		_ = await engine.infer(
			snapshot: weakSnap,
			situational: weakSituational,
			recentTitles: [weakSnap.windowTitle],
			history: nil,
			referenceTime: now,
			isEnrichedPass: true,
			isWarmupReady: true,
			forcePlannerFromPendingActionIntentRetry: true
		)
		let after = await stubLLM.plannerCalls
		check("planner_not_called_for_browser_chrome", after == before)

		let ok = failures.isEmpty
		print("[ActionIntentPlannerBridgeSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
