import Foundation

/// Self-tests for model-driven task inference (qwen contract) + deterministic planning.
/// These tests are isolated, deterministic, and do not call the live model.
enum TaskInferenceSelfTest {

	static func run() async -> Bool {
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

		let planned = await TaskInferencePlanningPipeline.compose(
			inference: inference,
			snapshot: snap,
			situational: situational,
			recentTitles: [snap.windowTitle],
			referenceTime: now
		)
		check("planner_returns_proposal", planned != nil)
		check("planner_title_not_empty", !(planned?.proposal.title ?? "").isEmpty)
		check("planner_question_not_empty", !(planned?.proposal.description ?? "").isEmpty)
		check("planner_primitives_include_compare", planned?.proposal.suggestedPrimitives.contains(.compareContexts) == true)

		// MARK: 5 — Title synthesis never exposes raw hook ids / signatures

		let titleLower = planned?.proposal.title.lowercased() ?? ""
		check("planner_title_no_raw_ids", !titleLower.contains("compare_items") && !titleLower.contains("|c"))

		// MARK: 6 — Parser tolerates \"c\": true (Bool not Int) — qwen common output

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

		// MARK: 11 — Parser extracts JSON after prose preamble (qwen may prefix explanation)

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

}
