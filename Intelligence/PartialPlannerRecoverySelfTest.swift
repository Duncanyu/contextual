import Foundation

/// Phase 4R self-test for partial planner-JSON recovery and the router
/// grounding-sufficiency upgrade.
///
/// Run with: `CONTEXTUAL_RUN_PARTIAL_PLANNER_RECOVERY_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no AI calls.
enum PartialPlannerRecoverySelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[PartialPlannerRecoverySelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — Partial JSON: unsafe first object closed, safe second truncated.
		//   The trailing-title probe must surface the safe candidate so the
		//   downstream validator can drop the unsafe one and keep the safe one.

		do {
			let raw = """
			{
			  "actions": [
			    { "title": "Purchase Anker Prime USB C Charger", "caps": "context,extract", "confidence": 0.78, "novelty": 0.6 },
			    { "title": "Summarize Anker Prime power bank specs", "caps": "context,extract", "confidence": 0.72, "novelty"
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(raw)
			check("salvage_returns_non_nil", result != nil)
			let titles = result?.candidates.map(\.title) ?? []
			check("salvage_includes_unsafe_first", titles.contains("Purchase Anker Prime USB C Charger"))
			check("salvage_recovers_truncated_safe_second",
				  titles.contains("Summarize Anker Prime power bank specs"))
			check("salvage_recovered_at_least_two", titles.count >= 2)
		}

		// MARK: 2 — Partial JSON: BOTH objects truncated. Trailing-title probe
		//   still recovers them because their titles closed before the truncation.

		do {
			let raw = """
			{
			  "actions": [
			    { "title": "Extract Anker Prime wattage from the page", "caps": "extract,context", "confidence": 0.81, "novelty": 0.55,
			    { "title": "Identify missing Anker Prime spec info", "caps": "extract,reason", "confidence": 0.74, "novelty"
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(raw)
			let titles = result?.candidates.map(\.title) ?? []
			check("both_truncated_titles_recovered",
				  titles.contains("Extract Anker Prime wattage from the page")
				  && titles.contains("Identify missing Anker Prime spec info"))
		}

		// MARK: 3 — Unsafe-first scenario classified correctly so the loop
		//   counters (unsafe_skipped / safe_remaining) reflect reality.

		do {
			let titles = [
				"Purchase Anker Prime USB C Charger",
				"Summarize Anker Prime power bank specs",
			]
			let probe = PlannerCapabilityRepairGate.allUnsafe(titles: titles)
			check("mixed_set_not_all_unsafe", probe.allUnsafe == false)
			let categories = titles.map(PlannerCapabilityRepairGate.classify(title:))
			check("unsafe_first_classified_purchase", categories[0] == .purchase)
			check("safe_second_classified_summarize", categories[1] == .safeSummarize)
		}

		// MARK: 4 — Router grounding upgrade: strong OCR product page upgrades
		//   need_more_context → enough_context when requests are redundant.

		do {
			let ocr = String(repeating: "Anker Prime 27,650mAh 250W Power Bank\n$129.99\n4.7 out of 5 stars\n", count: 5)
			let decision = RouterGroundingHeuristic.evaluate(
				modelDecision: "need_more_context",
				requestedContexts: ["ocr"],
				windowTitle: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
				appName: "Firefox",
				workflow: "shopping",
				ocrExcerpt: ocr,
				selectedText: nil,
				hasVisualDescriptor: false,
				hasAXText: false
			)
			check("router_upgrades_strong_ocr", decision.shouldUpgrade)
			check("router_upgrade_reason_sufficient", decision.reason == "sufficient_grounded_context")
			check("router_decision_entities_counted", decision.entityCount >= 2)
			check("router_decision_specs_counted", decision.specCount >= 1)
		}

		// MARK: 5 — Router upgrade refuses to fire when OCR is weak / no signal.

		do {
			let decision = RouterGroundingHeuristic.evaluate(
				modelDecision: "need_more_context",
				requestedContexts: [],
				windowTitle: "New Tab",
				appName: "Firefox",
				workflow: "browsing",
				ocrExcerpt: "Blank page",
				selectedText: nil,
				hasVisualDescriptor: false,
				hasAXText: false
			)
			check("router_no_upgrade_weak_ocr", decision.shouldUpgrade == false)
		}

		// MARK: 6 — Router upgrade now bypasses visual_descriptor when grounding is strong.

		do {
			let ocr = String(repeating: "Anker Prime 27,650mAh 250W Power Bank $129.99 4.7 out of 5 stars\n", count: 5)
			let decision = RouterGroundingHeuristic.evaluate(
				modelDecision: "need_more_context",
				requestedContexts: ["visual_descriptor"], // now bypassed for strong product contexts
				windowTitle: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
				appName: "Firefox",
				workflow: "shopping",
				ocrExcerpt: ocr,
				selectedText: nil,
				hasVisualDescriptor: false,
				hasAXText: false
			)
			check("router_upgrades_even_with_visual_descriptor_request", decision.shouldUpgrade == true)
			check("router_upgrade_reason_strong_satisfies_visual", decision.reason == "strong_ocr_ax_title_satisfies_visual_descriptor")
		}

		// MARK: 7 — Router upgrade refuses on non-content workflow.

		do {
			let ocr = String(repeating: "Anker Prime 27,650mAh 250W Power Bank $129.99 4.7 out of 5 stars\n", count: 5)
			let decision = RouterGroundingHeuristic.evaluate(
				modelDecision: "need_more_context",
				requestedContexts: [],
				windowTitle: "Anker Prime — Amazon",
				appName: "Firefox",
				workflow: "communication", // wrong family
				ocrExcerpt: ocr,
				selectedText: nil,
				hasVisualDescriptor: false,
				hasAXText: false
			)
			check("router_no_upgrade_wrong_workflow", decision.shouldUpgrade == false)
		}

		// MARK: 8 — Strict retry still works (Phase 4Q regression).

		do {
			let titles = ["Purchase Anker Prime", "Add to Cart", "Search Amazon for Anker"]
			let probe = PlannerCapabilityRepairGate.allUnsafe(titles: titles)
			check("strict_retry_still_armed_for_all_unsafe", probe.allUnsafe)
		}

		// MARK: 9 — No hardcoded titles in the salvage path. The salvage never
		//   manufactures a title — it only echoes whatever the model wrote.

		do {
			let rawNoTitles = """
			{
			  "actions": [
			    { "caps": "extract,context", "confidence": 0.85 }
			  ]
			}
			"""
			let result = TaskInferenceEngine.salvagePartialPlannerOutput(rawNoTitles)
			check("salvage_returns_nil_when_no_titles", result == nil)
		}

		let ok = failures.isEmpty
		print("[PartialPlannerRecoverySelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
