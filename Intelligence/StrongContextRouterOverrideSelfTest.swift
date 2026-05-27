import Foundation

/// Phase 4S — Strong context router override
///
/// Ensures the router grounding heuristic upgrades `need_more_context` to
/// `enough_context` for strong product-like browsing contexts even when the
/// router requests optional `selected_text` / `window_title`.
///
/// Run with: `CONTEXTUAL_RUN_STRONG_CONTEXT_ROUTER_OVERRIDE_SELFTEST=1`
enum StrongContextRouterOverrideSelfTest {
	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				print("[StrongContextRouterOverrideSelfTest] FAIL \(name)")
				failures.append(name)
			} else {
				print("[StrongContextRouterOverrideSelfTest] PASS \(name)")
			}
		}

		let strongOCR = """
		Anker Prime USB C Charger Block 160W 3-Port GaN Charger.
		Supports up to 140W max output. Price $76.00. Customer reviews 4.6 out of 5.
		Product details include GaN, USB-C, multi-device fast charging.
		""" + String(repeating: "x", count: 300)

		let strong = RouterGroundingHeuristic.evaluate(
			modelDecision: "need_more_context",
			requestedContexts: ["selected_text", "window_title"],
			windowTitle: "Anker Prime USB C Charger Block, 160W 3-Port GaN Charger",
			appName: "Firefox",
			workflow: "browsing",
			ocrExcerpt: strongOCR,
			selectedText: nil,
			hasVisualDescriptor: false,
			hasAXText: false
		)
		check("strong_context_upgrades", strong.shouldUpgrade)
		check("strong_context_reason_mentions_selection", strong.reason.contains("ignore_selection") || strong.reason.contains("sufficient_grounded_context"))

		let quietSelectedText = RouterGroundingHeuristic.evaluate(
			modelDecision: "quiet",
			requestedContexts: ["selected_text", "window_title"],
			windowTitle: "Anker Prime USB C Charger Block, 160W 3-Port GaN Charger",
			appName: "Firefox",
			workflow: "browsing",
			ocrExcerpt: strongOCR,
			selectedText: nil,
			hasVisualDescriptor: false,
			hasAXText: false
		)
		check("quiet_with_selection_request_upgrades_on_strong_context", quietSelectedText.shouldUpgrade)

		let weak = RouterGroundingHeuristic.evaluate(
			modelDecision: "need_more_context",
			requestedContexts: ["selected_text"],
			windowTitle: "Duncanyu (Duncan Yu)",
			appName: "Firefox",
			workflow: "browsing",
			ocrExcerpt: nil,
			selectedText: nil,
			hasVisualDescriptor: false,
			hasAXText: false
		)
		check("weak_context_does_not_upgrade", weak.shouldUpgrade == false)

		let ok = failures.isEmpty
		print("[StrongContextRouterOverrideSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
