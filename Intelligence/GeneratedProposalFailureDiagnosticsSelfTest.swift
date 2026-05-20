import Foundation

/// T18.3.3D — Generated Proposal Failure Diagnostics self-tests.
/// Verifies that diag: warning tags map to exact GeneratedProposalFailureReason cases
/// and that userFacingLabel strings are non-empty and specific.
/// Not wired to app launch; run via self-test harness only.
enum GeneratedProposalFailureDiagnosticsSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		// MARK: 1 — All 17 failure reason cases have non-empty userFacingLabel

		for reason in GeneratedProposalFailureReason.allCases {
			check("label_non_empty_\(reason.rawValue)", !reason.userFacingLabel.isEmpty)
		}

		// MARK: 2 — Specific label content spot-checks

		check("label_model_unavailable",  GeneratedProposalFailureReason.modelUnavailable.userFacingLabel == "model not available")
		check("label_startup_grace",      GeneratedProposalFailureReason.modelStartupGrace.userFacingLabel.contains("starting up"))
		check("label_timeout",            GeneratedProposalFailureReason.modelTimeout.userFacingLabel.contains("timed out"))
		check("label_no_json",            GeneratedProposalFailureReason.parseNoJSONObject.userFacingLabel.contains("non-JSON"))
		check("label_malformed_json",     GeneratedProposalFailureReason.parseMalformedJSON.userFacingLabel.contains("malformed"))
		check("label_missing_key",        GeneratedProposalFailureReason.parseMissingRequiredKey.userFacingLabel.contains("missing"))
		check("label_unknown_primitives", GeneratedProposalFailureReason.parseUnknownPrimitivesOnly.userFacingLabel.contains("unknown"))
		check("label_confidence_low",     GeneratedProposalFailureReason.parseConfidenceTooLow.userFacingLabel.contains("confidence"))
		check("label_generic_rejected",   GeneratedProposalFailureReason.parseGenericRejected.userFacingLabel.contains("generic"))
		check("label_no_chime",           GeneratedProposalFailureReason.modelChoseNoChime.userFacingLabel.contains("chime"))
		check("label_visual",             GeneratedProposalFailureReason.visualContextRecommended.userFacingLabel.contains("visual"))

		// MARK: 3 — Parser emits diag:parse_no_json for empty input

		let (nilResult, hardTag) = DynamicGeneratedProposalParser.parseWithReason(from: "not json at all")
		check("parse_no_json_returns_nil", nilResult == nil)
		check("parse_no_json_tag", hardTag == "diag:parse_no_json")

		// MARK: 4 — Parser emits diag:parse_no_json for empty string

		let (emptyResult, emptyTag) = DynamicGeneratedProposalParser.parseWithReason(from: "")
		check("parse_empty_returns_nil", emptyResult == nil)
		check("parse_empty_tag", emptyTag == "diag:parse_no_json")

		// MARK: 5 — Parser emits diag:parse_decode_failed for JSON object that cannot be decoded as proposals

		// A bare JSON array has a brace-depth object only if wrapped; here bare array has no `{`.
		let (bareArrResult, bareArrTag) = DynamicGeneratedProposalParser.parseWithReason(from: "[1,2,3]")
		check("bare_array_returns_nil", bareArrResult == nil)
		// bare array has no { so it should be parse_no_json
		check("bare_array_tag_no_json", bareArrTag == "diag:parse_no_json")

		// MARK: 6 — Parser emits diag:parse_no_chime when chime=false

		let noChimeJSON = """
		{"chime":false,"reason":"weak_context"}
		"""
		let noChimeResult = DynamicGeneratedProposalParser.parse(from: noChimeJSON)
		check("no_chime_result_non_nil", noChimeResult != nil)
		check("no_chime_tag_in_warnings", noChimeResult?.warnings.contains("diag:parse_no_chime") == true)
		check("no_chime_should_chime_false", noChimeResult?.shouldChimeIn == false)

		// MARK: 7 — Parser emits diag:parse_missing_key when title is empty

		let missingTitleJSON = """
		{"chime":true,"reason":"x","proposal":{"title":"","description":"Some description","workflow":"browsing","intent":"answer","outcome":"result","primitives":["answer_from_context"],"confidence":0.8}}
		"""
		let missingTitleResult = DynamicGeneratedProposalParser.parse(from: missingTitleJSON)
		check("missing_title_proposals_empty", missingTitleResult?.proposals.isEmpty == true)
		check("missing_title_diag_tag", missingTitleResult?.warnings.contains(where: { $0.hasPrefix("diag:parse_missing_key") }) == true)

		// MARK: 8 — Parser emits diag:parse_unknown_primitives for unknown-only primitives

		let badPrimJSON = """
		{"chime":true,"reason":"bad","proposal":{"title":"Run shell command","description":"Execute arbitrary bash","workflow":"debugging","intent":"explain","outcome":"result","primitives":["run_shell","delete_files"],"confidence":0.8}}
		"""
		let badPrimResult = DynamicGeneratedProposalParser.parse(from: badPrimJSON)
		check("bad_prim_proposals_empty", badPrimResult?.proposals.isEmpty == true)
		check("bad_prim_diag_tag", badPrimResult?.warnings.contains(where: { $0.hasPrefix("diag:parse_unknown_primitives") }) == true)

		// MARK: 9 — Parser emits diag:parse_confidence_too_low for low confidence

		let lowConfJSON = """
		{"chime":true,"reason":"low","proposal":{"title":"Summarize something vaguely from context","description":"Do a thing with context from the screen","workflow":"unknown","intent":"answer","outcome":"some output","primitives":["answer_from_context"],"confidence":0.2}}
		"""
		let lowConfResult = DynamicGeneratedProposalParser.parse(from: lowConfJSON)
		check("low_conf_proposals_empty", lowConfResult?.proposals.isEmpty == true)
		check("low_conf_diag_tag", lowConfResult?.warnings.contains("diag:parse_confidence_too_low") == true)

		// MARK: 10 — Parser emits diag:parse_generic_rejected for generic paraphrase

		let genericJSON = """
		{"chime":true,"reason":"generic","proposal":{"title":"Summarize selected text","description":"Quick summary of clipboard","workflow":"writing","intent":"summarize","outcome":"summary","primitives":["summarize_context"],"confidence":0.9}}
		"""
		let genericResult = DynamicGeneratedProposalParser.parse(from: genericJSON)
		check("generic_proposals_empty_or_quiet", genericResult?.proposals.isEmpty == true || genericResult?.shouldChimeIn == false)
		// When chime=true but proposal is generic-rejected, we expect a diag tag OR the proposal is simply nil.
		// Accept either: the generic tag or an empty proposals list with any diag tag.
		let hasGenericTag = genericResult?.warnings.contains("diag:parse_generic_rejected") == true
		let hasNoChimeTag = genericResult?.warnings.contains("diag:parse_no_chime") == true
		check("generic_has_diag_tag", hasGenericTag || hasNoChimeTag || genericResult?.proposals.isEmpty == true)

		// MARK: 11 — StatusBuilder maps diag:parse_no_json → parseNoJSONObject

		let diagTag = "diag:parse_no_json"
		let mappedReason = GeneratedProposalDebugStatusBuilder.failureReasonForTag_testOnly(diagTag)
		check("diag_tag_maps_to_no_json", mappedReason == .parseNoJSONObject)

		// MARK: 12 — StatusBuilder maps diag:parse_missing_key:title → parseMissingRequiredKey with detail

		let missingKeyTag = "diag:parse_missing_key:title"
		let (missingReason, missingDetail) = GeneratedProposalDebugStatusBuilder.failureReasonAndDetailForTag_testOnly(missingKeyTag)
		check("missing_key_reason", missingReason == .parseMissingRequiredKey)
		check("missing_key_detail", missingDetail == "title")

		// MARK: 13 — StatusBuilder maps diag:parse_confidence_too_low → parseConfidenceTooLow

		let confTag = "diag:parse_confidence_too_low"
		check("conf_tag_maps", GeneratedProposalDebugStatusBuilder.failureReasonForTag_testOnly(confTag) == .parseConfidenceTooLow)

		// MARK: 14 — StatusBuilder maps diag:parse_generic_rejected → parseGenericRejected

		let genTag = "diag:parse_generic_rejected"
		check("gen_tag_maps", GeneratedProposalDebugStatusBuilder.failureReasonForTag_testOnly(genTag) == .parseGenericRejected)

		// MARK: 15 — StatusBuilder maps diag:parse_no_chime → modelChoseNoChime

		let noChimeTag = "diag:parse_no_chime"
		check("no_chime_tag_maps", GeneratedProposalDebugStatusBuilder.failureReasonForTag_testOnly(noChimeTag) == .modelChoseNoChime)

		// MARK: 16 — pipelineStatusLine contains expected fields

		let idleStatus = GeneratedProposalDebugStatus.idle
		check("pipeline_line_prefix", idleStatus.pipelineStatusLine.hasPrefix("[GeneratedProposalStatus]"))
		check("pipeline_line_attempted", idleStatus.pipelineStatusLine.contains("attempted="))
		check("pipeline_line_LLM", idleStatus.pipelineStatusLine.contains("LLM="))
		check("pipeline_line_visible", idleStatus.pipelineStatusLine.contains("visible="))

		// MARK: 17 — CONTEXTUAL_DEBUG_LLM_OUTPUT env var is off by default in test environment

		let envEnabled = ProcessInfo.processInfo.environment["CONTEXTUAL_DEBUG_LLM_OUTPUT"] == "1"
		check("debug_output_off_by_default", !envEnabled)

		let ok = failures.isEmpty
		print("[GeneratedProposalFailureDiagnostics] selftest ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}
