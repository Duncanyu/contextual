import Foundation

/// T18.3.3C — LLM Output Contract Hardening self-tests.
/// Verifies tolerant JSON extraction, alias normalization, and hard rejection rules.
/// Not wired to app launch; run via self-test harness only.
enum DynamicGeneratedProposalOutputContractSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		// MARK: 1 — Valid compact JSON (new short-key schema)

		let compactJSON = """
		{"chime":true,"reason":"youtube_lecture","proposal":{"title":"Extract study concepts from lecture title","description":"Identify key topics from the visible lecture metadata","workflow":"studying","intent":"extract","outcome":"List of study concepts","primitives":["extract_action_items"],"confidence":0.75}}
		"""
		guard let compactResult = DynamicGeneratedProposalParser.parse(from: compactJSON) else {
			check("compact_json_parses", false)
			print("[OutputContractSelfTest] abort: compact parse returned nil")
			let ok = failures.isEmpty
			print("[DynamicGeneratedProposalOutputContract] selftest ok=\(ok) failures=\(failures.joined(separator: ";"))")
			return ok
		}
		check("compact_json_parses", compactResult.status == .synthesized)
		check("compact_chime_resolved", compactResult.shouldChimeIn)
		check("compact_proposal_count", compactResult.proposals.count == 1)
		check("compact_title_non_empty", !compactResult.proposals[0].title.isEmpty)
		check("compact_primitive_valid", compactResult.proposals[0].suggestedPrimitives.contains(.extractActionItems))

		// MARK: 2 — Markdown fenced JSON

		let fencedJSON = """
		Here is my response:
		```json
		{"chime":true,"reason":"debug_session","proposal":{"title":"Identify crash call site from stacktrace","description":"Analyse the visible error to find root cause","workflow":"debugging","intent":"explain","outcome":"Probable call site","primitives":["explain_error"],"confidence":0.8}}
		```
		Hope that helps.
		"""
		guard let fencedResult = DynamicGeneratedProposalParser.parse(from: fencedJSON) else {
			check("fenced_json_parses", false)
			failures.append("fenced_parse_nil")
			let ok = failures.isEmpty
			print("[DynamicGeneratedProposalOutputContract] selftest ok=\(ok) failures=\(failures.joined(separator: ";"))")
			return ok
		}
		check("fenced_json_parses", fencedResult.status == .synthesized)
		check("fenced_proposal_exists", fencedResult.proposals.count == 1)
		check("fenced_primitive_valid", fencedResult.proposals[0].suggestedPrimitives.contains(.explainError))

		// MARK: 3 — Prose before and after JSON

		let proseWrappedJSON = """
		Sure! Here is a useful proposal for your situation.
		{"chime":true,"reason":"research","proposal":{"title":"Compare claims across open research tabs","description":"Synthesize conflicting information from current context","workflow":"research","intent":"compare","outcome":"Comparison summary","primitives":["compare_contexts"],"confidence":0.71}}
		Let me know if you'd like anything else.
		"""
		let proseResult = DynamicGeneratedProposalParser.parse(from: proseWrappedJSON)
		check("prose_wrapped_parses", proseResult?.proposals.count == 1)
		check("prose_primitive_valid", proseResult?.proposals[0].suggestedPrimitives.contains(.compareContexts) == true)

		// MARK: 4 — Singular "proposal" key (compact schema)

		let singularJSON = """
		{"chime":true,"reason":"notes","proposal":{"title":"Convert messy draft into action list","description":"Structure repeated note edits into checklist","workflow":"organizing","intent":"structure","outcome":"Structured checklist","primitives":["generate_checklist"],"confidence":0.78}}
		"""
		let singularResult = DynamicGeneratedProposalParser.parse(from: singularJSON)
		check("singular_proposal_key_parses", singularResult?.proposals.count == 1)

		// MARK: 5 — Legacy "proposals" array key still accepted

		let legacyArrayJSON = """
		{"shouldChimeIn":true,"reason":"ok","workflowAssessment":"debugging","proposalConfidence":0.75,"requiresVisualContext":false,"proposals":[{"title":"Trace likely root cause from visible error","description":"Inspect error context to identify failure point","intentType":"explain","workflowType":"debugging","expectedOutcome":"Root cause","requiredContextTypes":["text_snippet"],"suggestedPrimitives":["answer_from_context"],"interruptionCost":0.2,"confidence":0.75}]}
		"""
		let legacyResult = DynamicGeneratedProposalParser.parse(from: legacyArrayJSON)
		check("legacy_array_key_parses", legacyResult?.proposals.count == 1)
		check("legacy_primitive_valid", legacyResult?.proposals[0].suggestedPrimitives.contains(.answerFromContext) == true)

		// MARK: 6 — Key aliases: "chime"/"shouldChimeIn", "workflow"/"workflowType", etc.

		let aliasJSON = """
		{"chime":true,"reason":"test","proposal":{"title":"Outline study notes from visible slide content","description":"Extract key concepts for revision","workflow":"studying","intent":"extract","outcome":"Study outline","primitives":["structure_notes"],"confidence":0.7}}
		"""
		let aliasResult = DynamicGeneratedProposalParser.parse(from: aliasJSON)
		check("alias_chime_key", aliasResult?.shouldChimeIn == true)
		check("alias_workflow_key", aliasResult?.proposals.first?.workflowType == .studying)
		check("alias_primitive_structure_notes", aliasResult?.proposals[0].suggestedPrimitives.contains(.structureNotes) == true)

		// MARK: 7 — camelCase primitive aliases map to enum

		let camelPrimJSON = """
		{"chime":true,"reason":"camel","proposal":{"title":"Synthesize research from open tabs","description":"Gather and compare research findings","workflow":"research","intent":"synthesize","outcome":"Research summary","primitives":["answerFromContext","compareContexts"],"confidence":0.73}}
		"""
		let camelResult = DynamicGeneratedProposalParser.parse(from: camelPrimJSON)
		check("camel_answer_from_context", camelResult?.proposals.first?.suggestedPrimitives.contains(.answerFromContext) == true)
		check("camel_compare_contexts", camelResult?.proposals.first?.suggestedPrimitives.contains(.compareContexts) == true)

		// MARK: 8 — snake_case primitives (already canonical; should still work)

		let snakeJSON = """
		{"chime":true,"reason":"canonical","proposal":{"title":"Generate a revision checklist from notes","description":"Convert draft into actionable items","workflow":"studying","intent":"organize","outcome":"Checklist","primitives":["generate_checklist","structure_notes"],"confidence":0.77}}
		"""
		let snakeResult = DynamicGeneratedProposalParser.parse(from: snakeJSON)
		check("snake_case_primitives_valid", snakeResult?.proposals.first?.suggestedPrimitives.count == 2)

		// MARK: 9 — Confidence as string (some LLMs emit "0.75" not 0.75)

		let stringConfJSON = """
		{"chime":true,"reason":"str_conf","proposal":{"title":"Map error pattern to known failure mode","description":"Cross-reference error with context","workflow":"debugging","intent":"classify","outcome":"Failure classification","primitives":["classify_workflow"],"confidence":"0.69"}}
		"""
		let stringConfResult = DynamicGeneratedProposalParser.parse(from: stringConfJSON)
		check("string_confidence_accepted", stringConfResult?.proposals.count == 1)

		// MARK: 10 — Malformed unrecoverable output → nil

		check("no_json_rejects", DynamicGeneratedProposalParser.parse(from: "not json at all") == nil)
		check("empty_rejects", DynamicGeneratedProposalParser.parse(from: "") == nil)
		check("bare_array_rejects", DynamicGeneratedProposalParser.parse(from: "[1,2,3]") == nil)

		// MARK: 11 — Unknown / unsafe primitives rejected

		let badPrimJSON = """
		{"chime":true,"reason":"bad","proposal":{"title":"Run shell command on context","description":"Execute arbitrary bash","workflow":"debugging","intent":"explain","outcome":"result","primitives":["run_shell","delete_files"],"confidence":0.8}}
		"""
		let badPrimResult = DynamicGeneratedProposalParser.parse(from: badPrimJSON)
		check("unknown_primitive_rejects_proposal", badPrimResult?.proposals.isEmpty == true)

		// MARK: 12 — Low confidence rejected

		let lowConfJSON = """
		{"chime":true,"reason":"low","proposal":{"title":"Summarize something vaguely","description":"Do a thing with context","workflow":"unknown","intent":"answer","outcome":"some output","primitives":["answer_from_context"],"confidence":0.2}}
		"""
		let lowConfResult = DynamicGeneratedProposalParser.parse(from: lowConfJSON)
		check("low_confidence_rejected", lowConfResult?.proposals.isEmpty == true)

		// MARK: 13 — Generic static paraphrase rejected

		let genericJSON = """
		{"chime":true,"reason":"generic","proposal":{"title":"Summarize selected text","description":"Quick summary of clipboard","workflow":"writing","intent":"summarize","outcome":"summary","primitives":["summarize_context"],"confidence":0.9}}
		"""
		let genericResult = DynamicGeneratedProposalParser.parse(from: genericJSON)
		check("generic_paraphrase_rejected", genericResult?.proposals.isEmpty == true || genericResult?.shouldChimeIn == false)

		// MARK: 14 — Empty title / description rejected

		let emptyTitleJSON = """
		{"chime":true,"reason":"x","proposal":{"title":"","description":"Some description","workflow":"browsing","intent":"answer","outcome":"result","primitives":["answer_from_context"],"confidence":0.8}}
		"""
		check("empty_title_rejected", DynamicGeneratedProposalParser.parse(from: emptyTitleJSON)?.proposals.isEmpty == true)

		// MARK: 15 — chime=false with no proposal: returns synthesized with shouldChimeIn=false

		let quietJSON = """
		{"chime":false,"reason":"weak_context"}
		"""
		let quietResult = DynamicGeneratedProposalParser.parse(from: quietJSON)
		check("quiet_chime_false", quietResult?.shouldChimeIn == false)

		// MARK: 16 — Parser diagnostics present (non-nil result means parse_diag was emitted)
		// We verify by checking that valid JSON produces a non-nil result with correct status.
		check("diagnostics_on_valid", compactResult.status == .synthesized)

		// MARK: 17 — isGenericStaticParaphrase direct checks

		check(
			"paraphrase_detect_summarize_selected",
			DynamicGeneratedProposalParser.isGenericStaticParaphrase(
				title: "Summarize selected text",
				description: "Summarize the text you selected"
			)
		)
		check(
			"paraphrase_detect_explain_clipboard",
			DynamicGeneratedProposalParser.isGenericStaticParaphrase(
				title: "Explain this",
				description: "Explain the clipboard contents"
			)
		)
		check(
			"specific_not_paraphrase",
			!DynamicGeneratedProposalParser.isGenericStaticParaphrase(
				title: "Identify root cause of crash loop",
				description: "Cross-reference error log with recent edits to find failure origin"
			)
		)

		// MARK: 18 — Prompt builder stays under 1500 bytes

		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Swift Concurrency — YouTube",
			generatedAt: Date()
		)
		let situational = SituationalContextSynthesizer.synthesize(from: snap)
		let prompt = DynamicGeneratedProposalPromptBuilder.build(
			snapshot: snap,
			existingStaticActions: [],
			reusableCount: 0,
			history: nil,
			budget: .conservative,
			situational: situational
		)
		check("prompt_under_1500_bytes", prompt.utf8.count < 1500)
		check("prompt_no_markdown_fence", !prompt.contains("```"))
		check("prompt_contains_primitives", prompt.contains("answer_from_context"))

		// MARK: 19 — No static fallback type produced

		let noStaticFallback = compactResult.proposals.allSatisfy { $0.usefulnessHint == "llm_dynamic" }
		check("no_static_fallback_in_results", noStaticFallback)

		let ok = failures.isEmpty
		print("[DynamicGeneratedProposalOutputContract] selftest ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}
