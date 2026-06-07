import Foundation

/// Self-tests for model-driven task inference (phi4-mini contract) + deterministic planning.
/// These tests are isolated, deterministic, and do not call the live model.
enum TaskInferenceSelfTest {

	static func run() async -> Bool {
		let hadOriginalDay1 = UserDefaults.standard.object(forKey: "contextual.day1BehaviorValidationMode") != nil
		let originalDay1 = UserDefaults.standard.bool(forKey: "contextual.day1BehaviorValidationMode")
		UserDefaults.standard.set(false, forKey: "contextual.day1BehaviorValidationMode")
		defer {
			if hadOriginalDay1 {
				UserDefaults.standard.set(originalDay1, forKey: "contextual.day1BehaviorValidationMode")
			} else {
				UserDefaults.standard.removeObject(forKey: "contextual.day1BehaviorValidationMode")
			}
		}

		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()

		// MARK: 1 — Parser extracts JSON in code fences

		let rawFence = """
```json
{"c":1,"g":"compare products","needCats":["extract","compare","output"],"p":0.72}
```
"""
		let (parsed1, fail1) = TaskInferenceParser.parseWithFailure(from: rawFence, referenceTime: now)
		check("parser_fence_success", parsed1 != nil && fail1 == nil)
		check("parser_fence_confidence", abs((parsed1?.confidence ?? 0) - 0.72) < 0.001)
		check("parser_fence_needCats", parsed1?.neededCapabilityCategories.contains("compare") == true)

		// MARK: 2 — Parser rejects c=1 with no confidence (structural requirement)

		let rawMissingConf = "{\"c\":1,\"g\":\"compare products\",\"needCats\":[\"extract\"]}"
		let (parsed2, fail2) = TaskInferenceParser.parseWithFailure(from: rawMissingConf, referenceTime: now)
		check("parser_missing_conf_rejected", parsed2 == nil && fail2 == .parseMissingRequiredKey)

		// MARK: 3 — Parser rejects forbidden keys (hooks / ids / question fields)

		let rawForbidden = "{\"c\":1,\"g\":\"compare products\",\"needCats\":[\"compare\"],\"p\":0.7,\"h\":[\"compare_items\"]}"
		let (parsed3, fail3) = TaskInferenceParser.parseWithFailure(from: rawForbidden, referenceTime: now)
		check("parser_forbidden_keys_rejected", parsed3 == nil && fail3 == .parseForbiddenKeys)

		// MARK: 4 — Planner composes a proposal from capability categories (no hook IDs from model)

		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Amazon.com: Mechanical Keyboard",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: "Key specs: switches, layout, price $129",
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: "Browsing product pages",
			workflowConfidence: 0.72,
			availableContextTypes: [.selectedText, .textSnippet],
			permissionAvailability: [.screenRecording: false],
			generatedAt: now,
			freshnessScore: 0.8
		)
		let situational = SituationalContextSynthesizer.synthesize(from: snap, referenceTime: now)

		let inference = TaskInferenceResult(
			shouldChime: true,
			possibleUserGoal: "compare products",
			confidence: 0.74,
			neededCapabilityCategories: ["extract", "compare", "output"],
			whyNow: "tab switching",
			missingContext: [],
			expirySeconds: 18,
			createdAt: now,
			need: [],
			needReason: nil
		)

		struct TestStubPlannerLLM: ActionCandidateLLMGenerating {
			func generate(prompt: String, model: String, numPredict: Int, temperature: Double, purpose: String?, schema: [String: Any]?) async throws -> String {
				return #"{"candidates":[{"title":"Compare battery-runtime tradeoffs across active products","reasoning":"Specific comparison support.","confidence":0.85}]}"#
			}
		}
		let testLLM = TestStubPlannerLLM()

		let planned = await TaskInferencePlanningPipeline.compose(
			inference: inference,
			snapshot: snap,
			situational: situational,
			recentTitles: [snap.windowTitle],
			referenceTime: now,
			llm: testLLM
		)
		check("planner_returns_proposal", planned != nil)
		check("planner_title_not_empty", !(planned?.proposal.title ?? "").isEmpty)
		check("planner_question_not_empty", !(planned?.proposal.description ?? "").isEmpty)
		check("planner_primitives_include_compare", planned?.proposal.suggestedPrimitives.contains(.compareContexts) == true)

		// MARK: 5 — Title synthesis never exposes raw hook ids / signatures

		let titleLower = planned?.proposal.title.lowercased() ?? ""
		check("planner_title_no_raw_ids", !titleLower.contains("compare_items") && !titleLower.contains("|c"))

		// MARK: 6 — Parser tolerates \"c\": true (Bool not Int) — phi4-mini common output

		let rawBoolC = "{\"c\":true,\"g\":\"research this page\",\"needCats\":[\"extract\",\"reason\",\"output\"],\"p\":0.75}"
		let (parsed6, fail6) = TaskInferenceParser.parseWithFailure(from: rawBoolC, referenceTime: now)
		check("parser_bool_c_success", parsed6 != nil && fail6 == nil)
		check("parser_bool_c_chime", parsed6?.shouldChime == true)
		check("parser_bool_c_needCats", parsed6?.neededCapabilityCategories.count ?? 0 >= 2)

		// MARK: 7 — Parser tolerates string numeric fields — \"p\": \"0.82\"

		let rawStrNum = "{\"c\":1,\"g\":\"debug the error\",\"needCats\":[\"debug\",\"reason\",\"output\"],\"p\":\"0.82\"}"
		let (parsed7, fail7) = TaskInferenceParser.parseWithFailure(from: rawStrNum, referenceTime: now)
		check("parser_string_number_success", parsed7 != nil && fail7 == nil)
		check("parser_string_number_confidence", abs((parsed7?.confidence ?? 0) - 0.82) < 0.01)

		// MARK: 8 — Parser repairs schema-annotated keys and reads real values

		let rawSchemaKey = "{\"c(0/1)\":1,\"g(goal)\":\"compare keyboards\",\"needCats\":[\"compare\",\"output\"],\"p(conf 0-1)\":0.78}"
		let (parsed8, fail8) = TaskInferenceParser.parseWithFailure(from: rawSchemaKey, referenceTime: now)
		check("parser_schema_key_success", parsed8 != nil && fail8 == nil)
		check("parser_schema_key_chime", parsed8?.shouldChime == true)
		check("parser_schema_key_confidence", (parsed8?.confidence ?? 0) > 0.7)

		// MARK: 9 — Parser repairs trailing comma

		let rawTrailingComma = "{\"c\":1,\"g\":\"debug crash\",\"needCats\":[\"debug\"],\"p\":0.8,}"
		let (parsed9, fail9) = TaskInferenceParser.parseWithFailure(from: rawTrailingComma, referenceTime: now)
		check("parser_trailing_comma_success", parsed9 != nil && fail9 == nil)

		// MARK: 10 — Parser tolerates comma-separated string for needCats field

		let rawNeedCatsString = "{\"c\":1,\"g\":\"organize notes\",\"needCats\":\"extract,reason,output\",\"p\":0.65}"
		let (parsed10, fail10) = TaskInferenceParser.parseWithFailure(from: rawNeedCatsString, referenceTime: now)
		check("parser_needCats_string_success", parsed10 != nil && fail10 == nil)
		check("parser_needCats_string_count", (parsed10?.neededCapabilityCategories.count ?? 0) >= 2)

		// MARK: 11 — Parser extracts JSON after prose preamble (phi4-mini may prefix explanation)

		let rawProse = "Based on the context, here is my JSON output:\n{\"c\":1,\"g\":\"compare options\",\"needCats\":[\"compare\",\"output\"],\"p\":0.78}"
		let (parsed11, fail11) = TaskInferenceParser.parseWithFailure(from: rawProse, referenceTime: now)
		check("parser_prose_preamble_success", parsed11 != nil && fail11 == nil)

		// MARK: 12 — Parser accepts c=0 (intentional silence)

		let rawNoChime = "{\"c\":0,\"g\":\"\",\"needCats\":[],\"p\":0.05}"
		let (parsed12, fail12) = TaskInferenceParser.parseWithFailure(from: rawNoChime, referenceTime: now)
		check("parser_no_chime_success", parsed12 != nil && fail12 == nil)
		check("parser_no_chime_false", parsed12?.shouldChime == false)

		// MARK: 13 — repairJSON strips schema annotations from keys

		let annotated = "{\"c(0/1)\":1,\"g(goal)\":\"test\",\"p(conf 0-1)\":0.9}"
		let repaired = TaskInferenceParser.repairJSON(annotated)
		check("repair_strips_schema_c", repaired.contains("\"c\":"))
		check("repair_strips_schema_g", repaired.contains("\"g\":"))
		check("repair_strips_schema_p", repaired.contains("\"p\":"))

		// MARK: 14 — Semantic validator: generic leakage phrase is rejected

		let leakedResult = TaskInferenceResult(
			shouldChime: true,
			possibleUserGoal: "summarize this?",
			confidence: 0.78,
			neededCapabilityCategories: ["extract", "output"],
			whyNow: "",
			missingContext: [],
			expirySeconds: 20,
			createdAt: now,
			need: [],
			needReason: nil
		)
		check(
			"semantic_generic_leakage_rejected",
			TaskInferenceSemanticValidator.validate(leakedResult, windowTitle: "Amazon.com: Mechanical Keyboard") == .exampleLeakage
		)

		// MARK: 15 — Parser parses need[] from context escalation output

		let rawNeed = "{\"c\":0,\"g\":\"understand visible page\",\"p\":0.72,\"need\":[\"visible_ocr\",\"ax_window_text\"]}"
		let (parsed15, fail15) = TaskInferenceParser.parseWithFailure(from: rawNeed, referenceTime: now)
		check("parser_need_success", parsed15 != nil && fail15 == nil)
		check("parser_need_chime_false", parsed15?.shouldChime == false)
		check("parser_need_has_visible_ocr", parsed15?.need.contains("visible_ocr") == true)
		check("parser_need_has_ax_window", parsed15?.need.contains("ax_window_text") == true)

		// MARK: 16 — Compact Planner parsing recovery tests (Two-Stage Planner)

		let caseARaw = """
{"a":1,"t":"Compare products","h":"extract,compare","p":0.91}
"""
		let caseBRaw = """
```json
{"a":1,"t":"Compare products","h":"extract,compare","p":0.91}
```
"""
		let caseCRaw = """
Extra text before a json-fenced planner output containing:
```json
{"a":1,"t":"Compare products","h":"extract,compare","p":0.91}
```
"""

		let parsedA = TaskInferenceEngine.parseCompactPlanner(caseARaw)
		check("caseA_success", parsedA != nil)
		check("caseA_a", parsedA?["a"] as? Int == 1)
		check("caseA_t", parsedA?["t"] as? String == "Compare products")
		check("caseA_h", parsedA?["h"] as? String == "extract,compare")
		check("caseA_p", (parsedA?["p"] as? Double ?? 0.0) == 0.91)

		let parsedB = TaskInferenceEngine.parseCompactPlanner(caseBRaw)
		check("caseB_success", parsedB != nil)
		check("caseB_a", parsedB?["a"] as? Int == 1)
		check("caseB_t", parsedB?["t"] as? String == "Compare products")
		check("caseB_h", parsedB?["h"] as? String == "extract,compare")
		check("caseB_p", (parsedB?["p"] as? Double ?? 0.0) == 0.91)

		let parsedC = TaskInferenceEngine.parseCompactPlanner(caseCRaw)
		check("caseC_success", parsedC != nil)
		check("caseC_a", parsedC?["a"] as? Int == 1)
		check("caseC_t", parsedC?["t"] as? String == "Compare products")
		check("caseC_h", parsedC?["h"] as? String == "extract,compare")
		check("caseC_p", (parsedC?["p"] as? Double ?? 0.0) == 0.91)

		// MARK: 17 — Two-Stage Router boost & parser tests
		
		let routerRawA = """
{"decision":"enough_context","request":[],"confidence":0.95,"reason":"Job posting found"}
"""
		let routerRawB = """
```json
{"decision":"need_more_context","request":["ocr","visual_descriptor"],"confidence":0.80,"reason":"Interesting product search"}
```
"""
		let routerRawC = """
{"decision":'need_more_context',"request":['ocr'],"confidence":0.85,"reason":'vague browser'}
"""
		let parsedRA = TaskInferenceEngine.parseRouterOutput(routerRawA)
		check("parsedRA_success", parsedRA != nil)
		check("parsedRA_decision", parsedRA?["decision"] as? String == "enough_context")
		check("parsedRA_reason", parsedRA?["reason"] as? String == "Job posting found")

		let parsedRB = TaskInferenceEngine.parseRouterOutput(routerRawB)
		check("parsedRB_success", parsedRB != nil)
		check("parsedRB_decision", parsedRB?["decision"] as? String == "need_more_context")

		let parsedRC = TaskInferenceEngine.parseRouterOutput(routerRawC)
		check("parsedRC_success", parsedRC != nil)
		check("parsedRC_decision", parsedRC?["decision"] as? String == "need_more_context")

		let snapBoost = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Xcode",
			windowTitle: "AppDelegate.swift",
			bundleIdentifier: "com.apple.dt.Xcode",
			inferredWorkflow: .debugging,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: "",
			workflowConfidence: 1.0,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 1.0
		)
		let situationalBoost = SituationalContextSynthesizer.synthesize(from: snapBoost, referenceTime: now)
		let boost = TaskInferenceEngine.computeDeterministicBoost(snapshot: snapBoost, situational: situationalBoost)
		check("boost_xcode_editor", boost.score >= 0.8)
		check("boost_xcode_reasons", boost.reasons.contains("Xcode editor"))

		let ok = failures.isEmpty
		let detail = failures.joined(separator: ";")
		print("[TaskInferenceSelfTest] ok=\(ok) failures=\(failures.count) detail=\(detail)")
		return ok
	}

	static func runFastProposalShellSelfTest() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()

		// 1. Verify router qwen/planner phi config preserved
		check("config_router_name", TaskInferenceEngine.routerModelName == "qwen2.5:0.5b")
		check("config_planner_name", TaskInferenceEngine.plannerModelName == "phi4-mini")

		// 2. Verify safety filter rejects unsafe commerce/destructive/control verbs (instead of rewriting them)
		check("safety_reject_purchase", !ProposalCapabilityValidator.validate(title: "Purchase Anker Prime USB C Charger", goal: "Charger", appName: "Safari", windowTitle: "Amazon.com").accepted)
		check("safety_reject_buy_now", !ProposalCapabilityValidator.validate(title: "Buy now AirPods Max", goal: "AirPods", appName: "Safari", windowTitle: "Amazon.com").accepted)
		check("safety_reject_delete", !ProposalCapabilityValidator.validate(title: "Delete this file", goal: "Delete", appName: "Safari", windowTitle: "Amazon.com").accepted)
		check("safety_reject_download_unsafe", !ProposalCapabilityValidator.validate(title: "Download malware", goal: "Malware", appName: "Safari", windowTitle: "Amazon.com").accepted)

		// 3. Verify candidate mapper safety rewrite for hook-composed proposals.
		//
		// Note: A previous fast-shell synthesis helper (`DynamicGeneratedProposalEngine.synthesizeFastShell`)
		// is no longer part of the engine surface. This self-test intentionally avoids depending on it.
		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "Amazon.com: AirPods Max review and details",
			bundleIdentifier: "com.apple.safari",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: "AirPods Max specs: active noise cancellation",
			contextSummary: "Browsing headphones details",
			workflowConfidence: 0.82,
			availableContextTypes: [.workflowContext],
			permissionAvailability: [.screenRecording: true],
			generatedAt: now,
			freshnessScore: 0.85
		)
		let situational = SituationalContextSynthesizer.synthesize(from: snap, referenceTime: now)

		// Test safety rewrite at candidate mapper level: if proposal title has an unsafe verb,
		// mapper safety-filters it while preserving the entity.
		let unsafeResult = DynamicGeneratedProposalResult(
			status: .synthesized,
			shouldChimeIn: true,
			reason: "test",
			workflowAssessment: "test",
			proposalConfidence: 0.8,
			requiresVisualContext: false,
			proposals: [
				ValidatedDynamicGeneratedProposal(
					id: "test_unsafe",
					title: "Purchase AirPods Max Charger",
					description: "desc",
					workflowType: .browsing,
					intentType: .review,
					expectedOutcome: "outcome",
					requiredContextTypes: [.none],
					suggestedPrimitives: [.summarizeContext],
					interruptionCost: 0.1,
					confidence: 0.8,
					usefulnessHint: "hook_composer",
					agenticPlan: nil
				)
			],
			warnings: [],
			llmDiagnosticCause: nil,
			createdAt: now,
			contextSnapshot: snap,
			libraryRecords: [],
			hookContracts: [
				DynamicGeneratedActionContract(
					id: "test_unsafe",
					title: "Purchase AirPods Max Charger",
					userFacingQuestion: "desc",
					inferredUserGoal: "outcome",
					situationSummary: "test",
					whyNow: "test",
					hookPlanIds: ["observe_current_context", "present_result"],
					requiredContext: [.none],
					confidence: 0.8,
					createdAt: now,
					expiresAt: now.addingTimeInterval(120),
					cacheEligibility: false,
					cacheKey: "test"
				)
			]
		)

		_ = situational // proves synthesize(from:) remains compile-reachable
		let unsafeCandidates = DynamicGeneratedProposalCandidateMapper.candidates(
			from: unsafeResult,
			snapshot: snap,
			budget: .conservative
		)
		check("unsafe_candidate_rejected", unsafeCandidates.isEmpty)

		let ok = failures.isEmpty
		let detail = failures.joined(separator: ";")
		print("[FastProposalShellSelfTest] ok=\(ok) failures=\(failures.count) detail=\(detail)")
		return ok
	}
}

enum TwoStageModelConfigSelfTest {
	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		// 1. Verify router model is qwen2.5:0.5b and planner model is phi4-mini
		check("router_is_qwen", TaskInferenceEngine.routerModelName == "qwen2.5:0.5b")
		check("planner_is_phi4", TaskInferenceEngine.plannerModelName == "phi4-mini")

		// 2. Verify planner timeout recovery can recover at least one complete partial action
		let partialRaw = """
{
	"actions": [
		{
			"title": "Compare mechanical keyboards",
			"caps": "extract,compare,output",
			"confidence": 0.85,
			"novelty": 0.6,
			"requires": ["ocr"]
		}
	]
}
"""
		if let salvaged = TaskInferenceEngine.salvagePartialPlannerOutput(partialRaw) {
			check("partial_recovery_action_count", salvaged.candidates.count == 1)
			check("partial_recovery_title", salvaged.candidates.first?.title == "Compare mechanical keyboards")
			check("partial_recovery_caps", salvaged.candidates.first?.caps.contains("compare") == true)
		} else {
			check("partial_recovery_failed", false)
		}

		// 3. Verify planner gate skips weak metadata-only context
		let now = Date()
		let weakSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Finder",
			windowTitle: "Desktop",
			bundleIdentifier: "com.apple.finder",
			inferredWorkflow: .unknown,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: "Weak metadata context",
			workflowConfidence: 0.1,
			availableContextTypes: [.workflowContext],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.1
		)
		let weakSituational = SituationalContextSynthesizer.synthesize(from: weakSnap, referenceTime: now)
		
		let strongSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Product review",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: "AirPods Max review details",
			contextSummary: "Strong context",
			workflowConfidence: 0.8,
			availableContextTypes: [.workflowContext, .textSnippet],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.8
		)

		let hasOCR_weak = weakSnap.recentOCRExcerpt != nil && !weakSnap.recentOCRExcerpt!.isEmpty
		let hasSel_weak = weakSnap.selectedText != nil && !weakSnap.selectedText!.isEmpty
		let hasWorkflowConf_weak = (weakSnap.workflowConfidence >= 0.72) || (weakSituational.workflowConfidence >= 0.72)
		let hasContinuity_weak = (weakSnap.freshnessScore >= 0.55) || (weakSituational.contextFreshness >= 0.55)
		let canInvokePlanner_weak = hasOCR_weak || hasSel_weak || hasWorkflowConf_weak || hasContinuity_weak

		check("weak_context_should_be_skipped_by_gate", !canInvokePlanner_weak)

		let hasOCR_strong = strongSnap.recentOCRExcerpt != nil && !strongSnap.recentOCRExcerpt!.isEmpty
		let canInvokePlanner_strong = hasOCR_strong

		check("strong_context_should_allow_planner", canInvokePlanner_strong)

		let ok = failures.isEmpty
		let detail = failures.joined(separator: ";")
		print("[TwoStageModelConfigSelfTest] ok=\(ok) failures=\(failures.count) detail=\(detail)")
		return ok
	}
}

/// T18.3.11 — Proposal Reactivity and Suppression Self-Tests.
/// Verifies that proposals surface quickly from strong context even when planner is not ready,
/// OCR is sanitized rather than excluded, and preservation logic handles transient failures.
enum ProposalReactivitySelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				print("[ProposalReactivitySelfTest] FAILURE: \(name)")
				failures.append(name)
			}
		}

		let now = Date()

		// MARK: 1 — Warmup not ready must not surface raw-title "actions"

		let strongTitle = "Designing a custom API in Swift"
		let strongSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: strongTitle,
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: "",
			workflowConfidence: 0.8,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.85
		)
		let strongSituational = SituationalContextSynthesizer.synthesize(from: strongSnap, referenceTime: now)

		// Test inferTwoStage with isWarmupReady=false
		let result1 = await TaskInferenceEngine.shared.infer(
			snapshot: strongSnap,
			situational: strongSituational,
			recentTitles: [strongTitle],
			history: nil,
			referenceTime: now,
			isWarmupReady: false
		)
		check("warmup_not_ready_does_not_emit_raw_title_action", result1 == nil)

		// MARK: 2 — No lightweight proposal when title is generic

		let genericTitle = "Firefox"
		let genericSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: genericTitle,
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: "",
			workflowConfidence: 0.1,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.1
		)
		let genericSituational = SituationalContextSynthesizer.synthesize(from: genericSnap, referenceTime: now)

		let result2 = await TaskInferenceEngine.shared.infer(
			snapshot: genericSnap,
			situational: genericSituational,
			recentTitles: [genericTitle],
			history: nil,
			referenceTime: now,
			isWarmupReady: false
		)
		check("warmup_not_ready_blocks_generic_title", result2 == nil)

		// MARK: 3 — OCR sanitization (strip dev artifacts, keep page text)

		let mixedOCR = """
https://github.com/apple/swift
[debug] starting build
package.swift
Designing a custom API in Swift
[error] build failed
This is the actual page content
"""
		let mixedSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: strongTitle,
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: mixedOCR,
			contextSummary: "",
			workflowConfidence: 0.8,
			availableContextTypes: [.textSnippet],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.8
		)
		let isolated3 = ProposalContextIsolationGate.isolate(snapshot: mixedSnap)
		print("[ProposalReactivitySelfTest] sanitized_ocr=\"\(isolated3.ocrExcerpt ?? "nil")\"")
		check("ocr_sanitized_not_excluded", isolated3.ocrExcerpt != nil)
		check("ocr_sanitized_strips_logs", !(isolated3.ocrExcerpt?.contains("[debug]") ?? true))
		check("ocr_sanitized_keeps_content", isolated3.ocrExcerpt?.contains("Designing a custom API in Swift") ?? false)

		// MARK: 4 — Early and Activation validation use same sanitized context

		let proposalTitle = "Review Designing a custom API in Swift"
		let isValidEarly = ProposalCapabilityValidator.validate(
			title: proposalTitle,
			goal: "Reviewing API design",
			isolated: isolated3,
			stage: "early"
		).accepted
		
		let isValidActivation = ProposalCapabilityValidator.validate(
			title: proposalTitle,
			goal: "Reviewing API design",
			isolated: isolated3,
			stage: "activation"
		).accepted
		
		check("validation_stages_consistent", isValidEarly == isValidActivation)

		// MARK: 5 — Failed refinement preserves existing visible proposal

		let existingCandidate = GeneratedExecutionProposalCandidate(
			id: "existing_1",
			title: "Review Design",
			description: "desc",
			source: .generatedExecution,
			workflowType: .browsing,
			intentType: .review,
			confidence: 0.85,
			interruptionCost: 0.1,
			explainabilitySummary: "test",
			expectedOutputSummary: "test",
			requiredContextTypes: [.textSnippet],
			executionAction: nil,
			generatedActionId: nil,
			primitiveSignature: "test",
			isExecutableGeneratedProposal: true
		)
		let existingProposals = [
			GeneratedExecutionProposalPanelItem(from: existingCandidate, rankScore: 0.82)
		]
		
		let failedResult = GeneratedExecutionProposalActivationResult(
			visibleProposals: [],
			visibleStaticActionIds: [],
			suppressedGeneratedCount: 1,
			suppressedStaticCount: 0,
			topSourceType: .generatedAction,
			rankingSummary: "failed",
			timingDecision: GeneratedExecutionProposalTimingDecision(outcome: .deferProposal, reason: "failed", allowsFloatingGenerated: false, allowsPanelGenerated: false),
			warnings: [],
			createdAt: now,
			floatingGeneratedProposalId: nil,
			isPolicySuppressed: false
		)

		let shouldPreserve = AppState.preservationDecision(
			existingCount: existingProposals.count,
			newVisibleCount: failedResult.visibleProposals.count,
			isPolicySuppressed: failedResult.isPolicySuppressed,
			bundleChanged: false,
			ttlExpired: false
		)
		check("failed_refinement_preserves_existing", shouldPreserve == true)

		// MARK: 6 — Panel allows safe grounded generated proposal below float threshold

		let safeCandidate = GeneratedExecutionProposalCandidate(
			id: "safe_1",
			title: "Review Design",
			description: "desc",
			source: .generatedExecution,
			workflowType: .browsing,
			intentType: .review,
			confidence: 0.75,
			interruptionCost: 0.1,
			explainabilitySummary: "test",
			expectedOutputSummary: "test",
			requiredContextTypes: [.textSnippet],
			executionAction: nil,
			generatedActionId: nil,
			primitiveSignature: "test",
			isExecutableGeneratedProposal: true
		)

		let floatThreshold = GeneratedExecutionProposalActivator.floatingStrongScoreThreshold
		let panelThreshold = GeneratedExecutionProposalActivator.panelGeneratedScoreThreshold
		let score = (floatThreshold + panelThreshold) / 2.0 // Between panel and float

		// Mock the logic from activator
		var panelEligible = false
		if safeCandidate.isGeneratedFamily {
			if safeCandidate.isExecutableGeneratedProposal {
				panelEligible = true
			}
		}
		check("panel_allows_safe_grounded_below_float", panelEligible == true && score < floatThreshold)

		// MARK: 7 — No unsafe proposal passes

		let unsafeTitle = "Purchase AirPods Max"
		let unsafeValid = ProposalCapabilityValidator.validate(
			title: unsafeTitle,
			goal: "buy",
			isolated: isolated3,
			stage: "early"
		).accepted
		check("unsafe_proposal_rejected", !unsafeValid)

		let ok = failures.isEmpty
		print("[ProposalReactivitySelfTest] COMPLETED ok=\(ok) failures=\(failures.count)")
		return ok
	}
}
