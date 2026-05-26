import Foundation

final class RouterEmptyEscalationSelfTest: @unchecked Sendable {
	static func run() async -> Bool {
		print("[RouterEmptyEscalationSelfTest] starting router empty-escalation recovery tests...")
		var failures: [String] = []

		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[RouterEmptyEscalationSelfTest] FAIL: \(name)")
			} else {
				print("[RouterEmptyEscalationSelfTest] PASS: \(name)")
			}
		}

		let now = Date()

		// 1. Generic title like Mozilla Firefox is weak context
		do {
			let isStrong = TaskInferenceEngine.isSpecificTitle("Mozilla Firefox", appName: "Firefox")
			check("generic_title_firefox_is_weak", !isStrong)
			
			let isStrongChrome = TaskInferenceEngine.isSpecificTitle("Google Chrome", appName: "Chrome")
			check("generic_title_chrome_is_weak", !isStrongChrome)
		}

		// 2. Product-like title is considered strong context without website-specific rules
		do {
			let isStrong = TaskInferenceEngine.isSpecificTitle("Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger...", appName: "Safari")
			check("product_title_is_strong", isStrong)
		}

		// 3. Router prompt/schema forbids empty requested_context for need_more_context
		do {
			let schema = TaskInferenceEngine.routerSchema
			if let req = schema["properties"] as? [String: Any],
			   let requestField = req["request"] as? [String: Any],
			   let items = requestField["items"] as? [String: Any],
			   let enums = items["enum"] as? [String] {
				check("schema_contains_ocr", enums.contains("ocr"))
				check("schema_contains_ax", enums.contains("ax"))
				check("schema_contains_selection", enums.contains("selection"))
				check("schema_contains_window_title", enums.contains("window_title"))
				check("schema_contains_visual_snapshot", enums.contains("visual_snapshot"))
			} else {
				check("schema_validation_failed", false)
			}
			
			let prompt = TwoStageRouterPromptBuilder.build(
				snapshot: makeSnapshot(title: "Anker Prime"),
				situational: makeSituational(title: "Anker Prime"),
				recentTitles: [],
				history: nil,
				referenceTime: now
			)
			check("prompt_requires_need_more_context_source", prompt.contains("If decision is need_more_context, request at least one available context source from"))
			check("prompt_excludes_semantic_examples", !prompt.contains("Compare smart charger specs"))
		}

		// Let's create an instance of TaskInferenceEngine to test the routing & recovery logic in isolation!
		let client = MockAIClient()
		let engine = TaskInferenceEngine(modelManager: MockModelManager(), llm: client)

		// 4. need_more_context + empty request + weak title requests visual context
		do {
			client.responseJSON = "{\"decision\":\"need_more_context\",\"request\":[],\"confidence\":0.8,\"reason\":\"weak title\"}"
			let snap = makeSnapshot(title: "Safari")
			let sit = makeSituational(title: "Safari", app: "Safari")
			let result = await engine.infer(
				snapshot: snap,
				situational: sit,
				recentTitles: [],
				history: nil,
				referenceTime: now
			)
			check("weak_title_requests_context", result != nil)
			check("weak_title_has_ocr_requirement", result?.need.contains("visible_ocr") == true)
			check("weak_title_has_ax_requirement", result?.need.contains("ax_window_text") == true)
			check("weak_title_no_proposal_title", result?.possibleUserGoal.isEmpty == true)
		}

		// 5. need_more_context + empty request + strong title routes to planner
		// Let's make the planner succeed here to verify it went to planner!
		do {
			client.responseJSON = "{\"decision\":\"need_more_context\",\"request\":[],\"confidence\":0.85,\"reason\":\"strong title\"}"
			client.plannerResponseJSON = """
			{
				"actions": [
					{
						"title": "Compare smart charger specs",
						"caps": "extract,compare,output",
						"confidence": 0.9,
						"novelty": 0.7,
						"requires": ["ocr"]
					}
				],
				"should_surface_softly": true
			}
			"""
			let snap = makeSnapshot(title: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger...")
			let sit = makeSituational(title: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger...", app: "Safari")
			let result = await engine.infer(
				snapshot: snap,
				situational: sit,
				recentTitles: [],
				history: nil,
				referenceTime: now
			)
			check("strong_title_routes_to_planner", result != nil)
			check("strong_title_gets_proposal", result?.possibleUserGoal == "Compare smart charger specs")
			check("strong_title_no_canned_fallback", result?.possibleUserGoal != "Compare Chargers")
		}

		// 6. planner timeout with no existing proposal produces no visible proposal
		do {
			client.responseJSON = "{\"decision\":\"need_more_context\",\"request\":[],\"confidence\":0.85,\"reason\":\"strong title\"}"
			client.shouldTimeoutPlanner = true
			
			// Force reset lastSuccessfulResult inside engine (by recreating engine or calling it)
			let newEngine = TaskInferenceEngine(modelManager: MockModelManager(), llm: client)
			let snap = makeSnapshot(title: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger...")
			let sit = makeSituational(title: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger...", app: "Safari")
			let result = await newEngine.infer(
				snapshot: snap,
				situational: sit,
				recentTitles: [],
				history: nil,
				referenceTime: now
			)
			check("timeout_no_existing_proposal_is_quiet", result != nil)
			check("timeout_no_existing_proposal_title_is_empty", result?.possibleUserGoal.isEmpty == true)
			check("timeout_no_existing_proposal_should_chime_false", result?.shouldChime == false)
		}

		// 7. existing visible proposal is preserved on planner timeout
		do {
			client.responseJSON = "{\"decision\":\"need_more_context\",\"request\":[],\"confidence\":0.85,\"reason\":\"strong title\"}"
			client.shouldTimeoutPlanner = false
			client.plannerResponseJSON = """
			{
				"actions": [
					{
						"title": "Compare Anker Specs",
						"caps": "extract,compare,output",
						"confidence": 0.9,
						"novelty": 0.7,
						"requires": ["ocr"]
					}
				],
				"should_surface_softly": true
			}
			"""
			
			let newEngine = TaskInferenceEngine(modelManager: MockModelManager(), llm: client)
			let snap = makeSnapshot(title: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger...")
			let sit = makeSituational(title: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger...", app: "Safari")
			
			// 1st run: planner succeeds, saves "Compare Anker Specs" to lastSuccessfulResult
			let result1 = await newEngine.infer(
				snapshot: snap,
				situational: sit,
				recentTitles: [],
				history: nil,
				referenceTime: now
			)
			check("first_run_succeeds", result1?.possibleUserGoal == "Compare Anker Specs")
			
			// 2nd run: planner times out, should return the existing "Compare Anker Specs"
			client.shouldTimeoutPlanner = true
			let result2 = await newEngine.infer(
				snapshot: snap,
				situational: sit,
				recentTitles: [],
				history: nil,
				referenceTime: now
			)
			check("timeout_preserves_existing_proposal", result2 != nil)
			check("timeout_preserved_title_matches", result2?.possibleUserGoal == "Compare Anker Specs")
		}

		let ok = failures.isEmpty
		print("[RouterEmptyEscalationSelfTest] finished. ok=\(ok), failures=\(failures.count)")
		return ok
	}

	// MARK: - Mock Helpers

	private static func makeSnapshot(title: String) -> CanonicalGeneratedExecutionContextSnapshot {
		CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: title,
			bundleIdentifier: "com.apple.safari",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: nil,
			workflowConfidence: 0.9,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: Date(),
			freshnessScore: 0.9
		)
	}

	private static func makeSituational(title: String, app: String = "Safari") -> SituationalContextSnapshot {
		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: app,
			windowTitle: title,
			bundleIdentifier: "com.apple.\(app.lowercased())",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: nil,
			workflowConfidence: 0.9,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: Date(),
			freshnessScore: 0.9
		)
		return SituationalContextSynthesizer.synthesize(from: snap, referenceTime: Date())
	}

	private final class MockModelManager: @unchecked Sendable, DynamicGeneratedProposalAvailabilityChecking {
		func checkModelAvailability() async -> ModelRuntimeState {
			.ready
		}
		func isDynamicProposalModeEnabled() -> Bool {
			true
		}
		func isGenerationAvailable() async -> Bool {
			true
		}
	}

	private final class MockAIClient: @unchecked Sendable, TaskInferenceLLMGenerating {
		var responseJSON = ""
		var plannerResponseJSON = ""
		var shouldTimeoutPlanner = false

		func generate(
			prompt: String,
			model: String,
			numPredict: Int,
			temperature: Double,
			purpose: String?,
			schema: [String: Any]?
		) async throws -> String {
			if model == TaskInferenceEngine.routerModelName {
				return responseJSON
			} else {
				if shouldTimeoutPlanner {
					throw TaskInferenceEngine.TaskInferenceTimeoutError.timeout
				}
				return plannerResponseJSON
			}
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
			if model == TaskInferenceEngine.routerModelName {
				return responseJSON
			} else {
				if shouldTimeoutPlanner {
					throw TaskInferenceEngine.TaskInferenceTimeoutError.timeout
				}
				return plannerResponseJSON
			}
		}
	}
}
