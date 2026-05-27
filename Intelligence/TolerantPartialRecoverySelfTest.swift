import Foundation

/// Phase 4T self-test for tolerant partial planner recovery + recent_changes
/// sanitization.
///
/// Run with: `CONTEXTUAL_RUN_TOLERANT_PARTIAL_RECOVERY_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no AI calls.
enum TolerantPartialRecoverySelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[TolerantPartialRecoverySelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — Incomplete candidate with title + polluted caps + confidence is recovered.
		//   Dogfood case: model emitted `caps: "compare, recent_pages=[...]"` and then
		//   timed out before closing the object. The salvage path must surface the
		//   "Compare Anker Prime USB C Charger" candidate so it can validate.

		do {
			let raw = """
			{
			  "should_surface_softly": true,
			  "actions": [
			    {
			      "title": "Compare Anker Prime USB C Charger",
			      "caps": "compare, recent_pages=[Anker Prime, USB C, 27,650mAh Power Bank]",
			      "confidence": 0.95,
			      "novelty"
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(raw)
			check("incomplete_candidate_recovered", result != nil)
			let titles = result?.candidates.map(\.title) ?? []
			check("incomplete_candidate_title_present",
				  titles.contains("Compare Anker Prime USB C Charger"))
			let cand = result?.candidates.first(where: { $0.title == "Compare Anker Prime USB C Charger" })
			check("sanitized_caps_drop_recent_pages",
				  !(cand?.caps.contains(where: { $0.contains("recent_pages") || $0.contains("=") }) ?? false))
			check("sanitized_caps_keep_compare",
				  cand?.caps.contains("compare") == true)
			check("recovered_confidence_present",
				  (cand?.confidence ?? 0) > 0)
		}

		// MARK: 2 — Multiple polluted caps reduce to the in-vocabulary tokens.

		do {
			let raw = """
			{
			  "actions": [
			    {
			      "title": "Inspect current Anker product page",
			      "caps": "inspect, gather, recent_pages=[a,b], random_junk=42",
			      "confidence": 0.7
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(raw)
			let cand = result?.candidates.first(where: { $0.title == "Inspect current Anker product page" })
			check("sanitized_caps_drop_junk_and_recent_pages",
				  cand?.caps.allSatisfy { !$0.contains("=") && !$0.contains("[") } == true)
			let kept = Set(cand?.caps ?? [])
			check("sanitized_caps_keep_inspect", kept.contains("inspect"))
			check("sanitized_caps_keep_gather", kept.contains("gather"))
		}

		// MARK: 3 — Recovered candidate validates against an active product page.
		//   Uses the ProposalCapabilityValidator directly to confirm safety/grounding
		//   rules accept the recovered title once recent_changes pollution is gone.

		do {
			let isolated = IsolatedProposalContext(
				appName: "Firefox",
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
				selectedText: nil,
				ocrExcerpt: "Anker Prime 27,650mAh 250W Power Bank\n$129.99\n4.7 out of 5 stars",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title", "ocr_excerpt"],
				excludedSources: []
			)
			let result = ProposalCapabilityValidator.validate(
				title: "Compare Anker Prime USB C Charger",
				goal: "Compare Anker Prime details",
				isolated: isolated,
				stage: "early"
			)
			check("recovered_title_validates", result.accepted)
			check("recovered_title_reason_valid_grounded", result.reason == "valid_grounded")
		}

		// MARK: 4 — recent_changes sanitization: weak titles flagged for removal.
		//   The engine drops "Duncanyu (Duncan Yu)" before the planner sees the
		//   recent_changes channel; the strong Anker title is kept.

		do {
			let weak = "Duncanyu (Duncan Yu)"
			let strong = "Anker Prime 27,650mAh 250W Power Bank — Amazon"
			check("weak_title_classified_weak",
				  FastVisibilityQualityGate.isWeakOrGeneric(title: weak, appName: "Firefox"))
			check("strong_title_classified_action_worthy",
				  FastVisibilityQualityGate.isActionWorthy(title: strong, appName: "Firefox"))
			// The engine-side filter would drop `weak` and keep `strong`.
			let recent = [weak, strong]
			let kept = recent.filter {
				!FastVisibilityQualityGate.isWeakOrGeneric(title: $0, appName: "Firefox")
			}
			check("recent_changes_drops_weak_keeps_strong", kept == [strong])
		}

		// MARK: 5 — Single safe candidate survives even when accompanied by an
		//   earlier unsafe candidate (Phase 4Q/4R regression cross-check).

		do {
			let raw = """
			{
			  "actions": [
			    { "title": "Purchase Anker Prime USB C Charger", "caps": "extract", "confidence": 0.6 },
			    { "title": "Compare Anker Prime USB C Charger", "caps": "compare", "confidence": 0.9
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(raw)
			let titles = result?.candidates.map(\.title) ?? []
			check("both_candidates_recovered", titles.count >= 2)
			check("safe_candidate_present", titles.contains("Compare Anker Prime USB C Charger"))
		}

		// MARK: 6 — No hardcoded fallback titles. With no titles in the raw input
		//   the salvage path returns nil — it does not manufacture anything.

		do {
			let raw = """
			{ "actions": [ { "caps": "compare", "confidence": 0.95 } ] }
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(raw)
			check("no_titles_no_recovery", result == nil)
		}

		// MARK: 7 — Detailed partial salvage tests.
		
		// Case 1: partial planner JSON with one complete action object and trailing truncation => salvages the complete object.
		do {
			let raw = """
			{
			  "actions": [
			    { "title": "Summarize mechanical keyboards", "caps": "summarize", "confidence": 0.85, "requires": ["ocr"] },
			    { "title": "Compare mechanical keyboard spec
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(raw)
			check("test_1_salvages_complete_leading", result?.candidates.count == 1 && result?.candidates.first?.title == "Summarize mechanical keyboards")
		}

		// Case 2: partial planner JSON with only truncated title => salvages zero.
		do {
			let raw = """
			{
			  "actions": [
			    { "title": "Summarize mecha
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(raw)
			check("test_2_salvages_zero_on_truncated_title", result == nil || result!.candidates.isEmpty)
		}

		// Case 3: salvaged object with invalid caps => rejected.
		do {
			check("test_3_valid_caps_check_summarize", TaskInferenceEngine.isValidCapOrPrimitive("summarize"))
			check("test_3_valid_caps_check_summarize_context", TaskInferenceEngine.isValidCapOrPrimitive("summarize_context"))
			check("test_3_valid_caps_check_summarizecontext", TaskInferenceEngine.isValidCapOrPrimitive("summarizecontext"))
			check("test_3_invalid_caps_check_junk", !TaskInferenceEngine.isValidCapOrPrimitive("some_invalid_random_junk_cap"))
		}

		// Case 4: salvaged object requiring unavailable source => rejected.
		do {
			let snap = CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Firefox",
				windowTitle: "Anker Prime Specs",
				bundleIdentifier: "org.mozilla.firefox",
				inferredWorkflow: .browsing,
				selectedText: nil,
				clipboardText: nil,
				recentOCRExcerpt: "some ocr text", // OCR present, selectedText absent
				contextSummary: nil,
				workflowConfidence: 0.8,
				availableContextTypes: [.textSnippet],
				permissionAvailability: [:],
				generatedAt: Date(),
				freshnessScore: 0.8
			)
			check("test_4_source_ocr_exists", TaskInferenceEngine.contextSourceExists("ocr", snapshot: snap))
			check("test_4_source_selected_text_absent", !TaskInferenceEngine.contextSourceExists("selected_text", snapshot: snap))
		}

		// Case 5: salvaged object still passes through existing validators.
		do {
			let isolated = IsolatedProposalContext(
				appName: "Firefox",
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
				selectedText: nil,
				ocrExcerpt: "Anker Prime 27,650mAh 250W Power Bank\n$129.99\n4.7 out of 5 stars",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title", "ocr_excerpt"],
				excludedSources: []
			)
			
			// Safe & grounded candidate passes
			let resultSafe = ProposalCapabilityValidator.validate(
				title: "Compare Anker Prime USB C Charger",
				goal: "Compare specs",
				isolated: isolated,
				stage: "early"
			)
			check("test_5_safe_passes_validation", resultSafe.accepted)
			
			// Unsafe candidate (Purchase prefix) rejected
			let resultUnsafe = ProposalCapabilityValidator.validate(
				title: "Purchase Anker Prime USB C Charger",
				goal: "Buy charger",
				isolated: isolated,
				stage: "early"
			)
			check("test_5_unsafe_rejected_validation", !resultUnsafe.accepted)
		}

		// Case 6: planner full valid JSON path remains unchanged.
		do {
			let raw = """
			{
			  "should_surface_softly": true,
			  "actions": [
			    {
			      "title": "Summarize mechanical keyboards",
			      "caps": "summarize",
			      "confidence": 0.85,
			      "novelty": 0.6,
			      "requires": ["ocr"]
			    }
			  ]
			}
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(raw)
			check("test_6_full_valid_json_path_salvaged", result?.candidates.count == 1 && result?.candidates.first?.title == "Summarize mechanical keyboards")
		}

		// Case 7: browser chrome / generic titles still produce zero candidates in validator and fast visibility.
		do {
			let isolatedGeneric = IsolatedProposalContext(
				appName: "Firefox",
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: "New Tab",
				selectedText: nil,
				ocrExcerpt: nil,
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title"],
				excludedSources: []
			)
			
			// Raw generic title with no action intent is rejected by the validator
			let resultGeneric = ProposalCapabilityValidator.validate(
				title: "New Tab",
				goal: "Review",
				isolated: isolatedGeneric,
				stage: "early"
			)
			check("test_7_generic_title_rejected_by_validator", !resultGeneric.accepted)
			
			// Generic browser chrome title is recognized as weak/not specific
			check("test_7_is_specific_title_false_for_chrome", !TaskInferenceEngine.isSpecificTitle("New Tab", appName: "Firefox"))
			check("test_7_is_weak_title_true_for_chrome", FastVisibilityQualityGate.isWeakOrGeneric(title: "New Tab", appName: "Firefox"))
		}

		// Case 8: Normalize requires on visual_descriptor
		do {
			let snap = CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Safari",
				windowTitle: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
				bundleIdentifier: "com.apple.Safari",
				selectedText: nil,
				clipboardText: nil,
				recentOCRExcerpt: "Anker Prime 27,650mAh",
				contextSummary: nil,
				visualContextAvailability: GeneratedExecutionVisualContextAvailability(hasWindowSnapshot: true, visualSummaryExcerpt: nil)
			)
			let normalized = TaskInferenceEngine.normalizeRequires(
				for: "Extract Product Details",
				requires: ["ocr", "visual_descriptor"],
				snapshot: snap
			)
			check("test_8_normalizes_visual_descriptor", !normalized.contains("visual_descriptor") && normalized.contains("screen_capture"))
		}

		let ok = failures.isEmpty
		print("[TolerantPartialRecoverySelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
