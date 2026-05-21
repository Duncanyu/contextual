import Foundation

/// Self-tests for model-driven task inference + hook composition.
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
{"chime":true,"goal":"compare items","conf":0.72,"task":"comparing similar shopping options","evidence":"title diversity","caps":["extract_product_attributes","compare_items","present_result"],"verb":"compare","obj":"these options","why":"tab switching","risk":0.35,"missing":[],"expiry":18}
```
"""
		let (parsed1, fail1) = TaskInferenceParser.parseWithFailure(from: rawFence, referenceTime: now)
		check("parser_fence_success", parsed1 != nil && fail1 == nil)
		check("parser_fence_confidence", abs((parsed1?.confidence ?? 0) - 0.72) < 0.001)
		check("parser_fence_caps", parsed1?.neededCapabilities.contains("compare_items") == true)

		// MARK: 2 — Parser rejects c=1 with no confidence (structural requirement)
		// Input uses compact "c" key so the parser correctly reads chime=1.

		let rawMissingConf = "{\"c\":1,\"g\":\"debug the error\"}"
		let (parsed2, fail2) = TaskInferenceParser.parseWithFailure(from: rawMissingConf, referenceTime: now)
		check("parser_missing_conf_rejected", parsed2 == nil && fail2 == .parseMissingRequiredKey)

		// MARK: 3 — Composer maps capabilities to primitives (no hardcoded behavior branches)

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
			inferredTaskType: "comparing similar shopping options",
			evidenceSummary: "tab switching",
			neededCapabilities: ["extract_product_attributes", "compare_items", "present_result"],
			suggestedActionVerb: "compare",
			suggestedObject: "these options",
			userFacingQuestion: "",
			whyNow: "tab switching",
			interruptionRisk: 0.32,
			missingContext: [],
			expirySeconds: 18,
			createdAt: now,
			need: [],
			needReason: nil
		)

		let composed = ModelDrivenHookComposer.compose(
			inference: inference,
			snapshot: snap,
			situational: situational,
			recentTitles: [snap.windowTitle],
			referenceTime: now
		)
		check("composer_returns_proposal", composed != nil)
		check("composer_title_not_empty", !(composed?.proposal.title ?? "").isEmpty)
		check("composer_question_not_empty", !(composed?.proposal.description ?? "").isEmpty)
		check("composer_primitives_include_compare", composed?.proposal.suggestedPrimitives.contains(ExecutionPrimitive.compareContexts) == true)

		// MARK: 4 — Title synthesis never exposes raw hook ids / signatures

		let title = composed?.proposal.title.lowercased() ?? ""
		check("composer_title_no_raw_ids", !title.contains("extract_product_attributes") && !title.contains("|h"))

		// MARK: 5 — Parser tolerates "c": true (Bool not Int) — qwen common output

		let rawBoolC = "{\"c\":true,\"g\":\"summarize page\",\"a\":\"summarize\",\"o\":\"page content\",\"h\":[\"summarize_context\"],\"q\":\"Want me to summarize?\",\"p\":0.75}"
		let (parsed5, fail5) = TaskInferenceParser.parseWithFailure(from: rawBoolC, referenceTime: now)
		check("parser_bool_c_success", parsed5 != nil && fail5 == nil)
		check("parser_bool_c_chime", parsed5?.shouldChime == true)
		check("parser_bool_c_confidence", (parsed5?.confidence ?? 0) > 0.7)

		// MARK: 6 — Parser tolerates string numeric fields — "p": "0.82"

		let rawStrNum = "{\"c\":1,\"g\":\"extract error details\",\"a\":\"extract\",\"o\":\"the errors\",\"h\":[\"extract_error_messages\"],\"q\":\"Want me to extract the errors?\",\"p\":\"0.82\"}"
		let (parsed6, fail6) = TaskInferenceParser.parseWithFailure(from: rawStrNum, referenceTime: now)
		check("parser_string_number_success", parsed6 != nil && fail6 == nil)
		check("parser_string_number_confidence", abs((parsed6?.confidence ?? 0) - 0.82) < 0.01)
		check("parser_string_number_question", !(parsed6?.userFacingQuestion ?? "").isEmpty)

		// MARK: 7 — Parser repairs schema-annotated keys and reads real values

		let rawSchemaKey = "{\"c(0/1)\":1,\"g(goal)\":\"browse product comparison\",\"a\":\"compare\",\"o\":\"these keyboards\",\"h\":[\"compare_items\",\"present_result\"],\"q\":\"Compare these keyboards?\",\"p\":0.78}"
		let (parsed7, fail7) = TaskInferenceParser.parseWithFailure(from: rawSchemaKey, referenceTime: now)
		check("parser_schema_key_success", parsed7 != nil && fail7 == nil)
		check("parser_schema_key_chime", parsed7?.shouldChime == true)
		check("parser_schema_key_confidence", (parsed7?.confidence ?? 0) > 0.7)
		check("parser_schema_key_goal", (parsed7?.possibleUserGoal ?? "").contains("browse") || (parsed7?.possibleUserGoal ?? "").contains("product") || (parsed7?.possibleUserGoal ?? "").contains("comparison"))

		// MARK: 8 — Parser repairs trailing comma

		let rawTrailingComma = "{\"c\":1,\"g\":\"debug the crash\",\"a\":\"explain\",\"o\":\"the crash\",\"h\":[\"explain_visible_error\"],\"q\":\"Explain this crash?\",\"p\":0.8,}"
		let (parsed8, fail8) = TaskInferenceParser.parseWithFailure(from: rawTrailingComma, referenceTime: now)
		check("parser_trailing_comma_success", parsed8 != nil && fail8 == nil)
		check("parser_trailing_comma_chime", parsed8?.shouldChime == true)

		// MARK: 9 — Parser tolerates comma-separated string for h field

		let rawStringH = "{\"c\":1,\"g\":\"structure my notes\",\"a\":\"structure\",\"o\":\"these notes\",\"h\":\"structure_key_points,summarize_context\",\"q\":\"Structure these notes?\",\"p\":0.65}"
		let (parsed9, fail9) = TaskInferenceParser.parseWithFailure(from: rawStringH, referenceTime: now)
		check("parser_string_h_success", parsed9 != nil && fail9 == nil)
		check("parser_string_h_caps", (parsed9?.neededCapabilities.count ?? 0) >= 2)

		// MARK: 10 — Parser extracts JSON after prose preamble (qwen may prefix explanation)

		let rawProse = "Based on the context, here is my JSON output:\n{\"c\":1,\"g\":\"research comparison\",\"a\":\"compare\",\"o\":\"these options\",\"h\":[\"compare_items\",\"summarize_context\"],\"q\":\"Want me to compare these?\",\"p\":0.78}"
		let (parsed10, fail10) = TaskInferenceParser.parseWithFailure(from: rawProse, referenceTime: now)
		check("parser_prose_preamble_success", parsed10 != nil && fail10 == nil)
		check("parser_prose_preamble_goal", (parsed10?.possibleUserGoal ?? "").count > 3)

		// MARK: 11 — Parser accepts c=0 (intentional silence) without missing-required-key

		let rawNoChime = "{\"c\":0,\"g\":\"\",\"a\":\"\",\"o\":\"\",\"h\":[],\"q\":\"\",\"p\":0.05}"
		let (parsed11, fail11) = TaskInferenceParser.parseWithFailure(from: rawNoChime, referenceTime: now)
		check("parser_no_chime_success", parsed11 != nil && fail11 == nil)
		check("parser_no_chime_false", parsed11?.shouldChime == false)

		// MARK: 12 — repairJSON strips schema annotations from keys

		let annotated = "{\"c(0/1)\":1,\"g(goal)\":\"test\",\"p(conf 0-1)\":0.9}"
		let repaired = TaskInferenceParser.repairJSON(annotated)
		check("repair_strips_schema_c", repaired.contains("\"c\":"))
		check("repair_strips_schema_g", repaired.contains("\"g\":"))
		check("repair_strips_schema_p", repaired.contains("\"p\":"))
		check("repair_no_parens_remain", !repaired.contains("(0/1)") && !repaired.contains("(goal)"))

		// MARK: 13 — Semantic validator: "hook_id" literal is detected as placeholder

		let placeholderHook = TaskInferenceResult(
			shouldChime: true,
			possibleUserGoal: "compare products",
			confidence: 0.76,
			inferredTaskType: "compare",
			evidenceSummary: "",
			neededCapabilities: ["hook_id"],   // literal placeholder copied from schema
			suggestedActionVerb: "compare",
			suggestedObject: "these items",
			userFacingQuestion: "Compare?",
			whyNow: "",
			interruptionRisk: 0.3,
			missingContext: [],
			expirySeconds: 20,
			createdAt: now,
			need: [],
			needReason: nil
		)
		check("semantic_hook_id_is_placeholder", TaskInferenceSemanticValidator.validate(placeholderHook) == .placeholder)

		// MARK: 14 — Semantic validator: "goal" as goal text is placeholder

		let placeholderGoal = TaskInferenceResult(
			shouldChime: true,
			possibleUserGoal: "goal",           // literal schema placeholder
			confidence: 0.82,
			inferredTaskType: "task",
			evidenceSummary: "",
			neededCapabilities: ["summarize_context"],
			suggestedActionVerb: "summarize",
			suggestedObject: "this page",
			userFacingQuestion: "",
			whyNow: "",
			interruptionRisk: 0.3,
			missingContext: [],
			expirySeconds: 20,
			createdAt: now,
			need: [],
			needReason: nil
		)
		check("semantic_goal_placeholder_rejected", TaskInferenceSemanticValidator.validate(placeholderGoal) == .placeholder)

		// MARK: 15 — Semantic validator: empty hooks with c=1 → noHooks (not placeholder)

		let noHooksResult = TaskInferenceResult(
			shouldChime: true,
			possibleUserGoal: "understand the NAS comparison",
			confidence: 0.71,
			inferredTaskType: "compare",
			evidenceSummary: "",
			neededCapabilities: [],              // empty — model didn't select hooks
			suggestedActionVerb: "compare",
			suggestedObject: "NAS drives",
			userFacingQuestion: "Compare these NAS drives?",
			whyNow: "",
			interruptionRisk: 0.3,
			missingContext: [],
			expirySeconds: 20,
			createdAt: now,
			need: [],
			needReason: nil
		)
		check("semantic_no_hooks_is_nohooks", TaskInferenceSemanticValidator.validate(noHooksResult) == .noHooks)

		// MARK: 16 — Semantic validator: valid real-world compare proposal passes

		let validResult = TaskInferenceResult(
			shouldChime: true,
			possibleUserGoal: "compare NAS drives",
			confidence: 0.82,
			inferredTaskType: "product_comparison",
			evidenceSummary: "multiple product tabs",
			neededCapabilities: ["compare_items", "extract_product_attributes", "present_result"],
			suggestedActionVerb: "compare",
			suggestedObject: "these NAS drives",
			userFacingQuestion: "Compare these NAS options?",
			whyNow: "multiple product pages open",
			interruptionRisk: 0.25,
			missingContext: [],
			expirySeconds: 24,
			createdAt: now,
			need: [],
			needReason: nil
		)
		check("semantic_valid_passes", TaskInferenceSemanticValidator.validate(validResult) == .valid)

		// MARK: 17 — Semantic validator: c=0 is always valid regardless of other fields

		let silentResult = TaskInferenceResult(
			shouldChime: false,
			possibleUserGoal: "goal",            // would be placeholder if c=1
			confidence: 0.0,                     // would be placeholder if c=1
			inferredTaskType: "",
			evidenceSummary: "",
			neededCapabilities: ["hook_id"],     // would be placeholder if c=1
			suggestedActionVerb: "verb",
			suggestedObject: "object",
			userFacingQuestion: "",
			whyNow: "",
			interruptionRisk: 0.0,
			missingContext: [],
			expirySeconds: 20,
			createdAt: now,
			need: [],
			needReason: nil
		)
		check("semantic_c0_always_valid", TaskInferenceSemanticValidator.validate(silentResult) == .valid)

		// MARK: 18 — Semantic validator: p=0.0 with c=1 is placeholder (schema copy)

		let zeroPResult = TaskInferenceResult(
			shouldChime: true,
			possibleUserGoal: "compare NAS options",
			confidence: 0.0,                     // 0.0 copied from schema example
			inferredTaskType: "compare",
			evidenceSummary: "",
			neededCapabilities: ["compare_items"],
			suggestedActionVerb: "compare",
			suggestedObject: "NAS drives",
			userFacingQuestion: "Compare?",
			whyNow: "",
			interruptionRisk: 0.3,
			missingContext: [],
			expirySeconds: 20,
			createdAt: now,
			need: [],
			needReason: nil
		)
		check("semantic_zero_confidence_c1_is_placeholder", TaskInferenceSemanticValidator.validate(zeroPResult) == .placeholder)

		// MARK: 19 — Semantic validator: generic leakage on shopping page

		let leakedResult = TaskInferenceResult(
			shouldChime: true,
			possibleUserGoal: "summarize the article",   // generic training-data phrase
			confidence: 0.78,
			inferredTaskType: "summarize",
			evidenceSummary: "",
			neededCapabilities: ["summarize_context", "present_result"],
			suggestedActionVerb: "summarize",
			suggestedObject: "this page",
			userFacingQuestion: "Summarize this?",       // generic question, no keyboard/amazon words
			whyNow: "",
			interruptionRisk: 0.2,
			missingContext: [],
			expirySeconds: 20,
			createdAt: now,
			need: [],
			needReason: nil
		)
		// On a shopping page — "summarize this?" contains no words from keyboard/amazon context.
		check("semantic_generic_leakage_shopping", TaskInferenceSemanticValidator.validate(leakedResult, windowTitle: "Amazon.com: Mechanical Keyboard") == .exampleLeakage)

		// MARK: 20 — Semantic validator: generic leakage is ALWAYS flagged for exact phrases

		// Exact training-data phrases like "Summarize this?" are never acceptable as user-facing
		// proposals, even when the title contains overlapping words.
		check("semantic_generic_leakage_article_also_rejected", TaskInferenceSemanticValidator.validate(leakedResult, windowTitle: "The Verge — Latest news article") == .exampleLeakage)

		// MARK: 21 — Parser parses need[] from context escalation output

		let rawNeed = "{\"c\":0,\"g\":\"understand visible page\",\"p\":0.72,\"need\":[\"visible_ocr\",\"ax_window_text\"]}"
		let (parsed21, fail21) = TaskInferenceParser.parseWithFailure(from: rawNeed, referenceTime: now)
		check("parser_need_success", parsed21 != nil && fail21 == nil)
		check("parser_need_chime_false", parsed21?.shouldChime == false)
		check("parser_need_has_visible_ocr", parsed21?.need.contains("visible_ocr") == true)
		check("parser_need_has_ax_window", parsed21?.need.contains("ax_window_text") == true)

		// MARK: 22 — Parser strips unknown need values (only allow-listed values pass)

		let rawBadNeed = "{\"c\":0,\"g\":\"\",\"p\":0.1,\"need\":[\"visible_ocr\",\"send_email\",\"browser_text\"]}"
		let (parsed22, _) = TaskInferenceParser.parseWithFailure(from: rawBadNeed, referenceTime: now)
		check("parser_bad_need_filtered", parsed22?.need.contains("send_email") == false)
		check("parser_good_need_kept", parsed22?.need.contains("visible_ocr") == true && parsed22?.need.contains("browser_text") == true)

		// MARK: 23 — Substantive word extraction (grounding check helper)

		let words = TaskInferenceSemanticValidator.substantiveWords(from: "Amazon.com: Mechanical Keyboard")
		check("substantive_words_keyboard", words.contains("keyboard"))
		check("substantive_words_mechanical", words.contains("mechanical"))
		check("substantive_words_no_short", !words.contains("com"))  // < 4 chars

		let ok = failures.isEmpty
		print("[TaskInferenceSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}
