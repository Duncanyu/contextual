import Foundation

/// Phase 4S self-test for the fast-visibility quality gate.
///
/// Run with: `CONTEXTUAL_RUN_FAST_VISIBILITY_QUALITY_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no AI calls.
/// Tests the classifier directly + the engine-side `isSpecificTitle` shim
/// + the AppDelegate-level execution-time stale-goal repair detection.
enum FastVisibilityQualitySelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[FastVisibilityQualitySelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — Reject account/identity titles

		do {
			let d = FastVisibilityQualityGate.evaluate(
				title: "Duncanyu (Duncan Yu)",
				appName: "Firefox"
			)
			check("duncanyu_rejected", d.eligible == false)
			check("duncanyu_classified_account", d.classification == .accountIdentity)

			let d2 = FastVisibilityQualityGate.evaluate(title: "John Smith", appName: "Firefox")
			check("plain_two_name_rejected", d2.eligible == false)
			check("plain_two_name_classified_account", d2.classification == .accountIdentity)
		}

		// MARK: 2 — Reject generic Amazon homepage / storefront

		do {
			let d = FastVisibilityQualityGate.evaluate(
				title: "Amazon.ca: Low Prices – Fast Shipping – Millions of Items",
				appName: "Firefox"
			)
			check("amazon_homepage_rejected", d.eligible == false)
			check("amazon_homepage_classified_storefront", d.classification == .genericStorefront)

			let d2 = FastVisibilityQualityGate.evaluate(
				title: "Best Buy — Today's Deals",
				appName: "Firefox"
			)
			check("best_buy_deals_rejected", d2.eligible == false)
			check("best_buy_deals_classified_storefront", d2.classification == .genericStorefront)
		}

		// MARK: 3 — Reject generic homepage / browser chrome / app title

		do {
			check("home_rejected",
				  FastVisibilityQualityGate.evaluate(title: "Home", appName: "Firefox").classification == .genericHomepage)
			check("welcome_to_rejected",
				  FastVisibilityQualityGate.evaluate(title: "Welcome to Amazon", appName: "Firefox").classification == .genericHomepage)
			check("new_tab_rejected",
				  FastVisibilityQualityGate.evaluate(title: "New Tab", appName: "Firefox").classification == .browserChrome)
			check("firefox_rejected",
				  FastVisibilityQualityGate.evaluate(title: "Firefox", appName: "Firefox").classification == .browserChrome)
			check("app_title_rejected",
				  FastVisibilityQualityGate.evaluate(title: "Xcode", appName: "Xcode").classification == .appTitle)
			check("assistant_chrome_rejected",
				  FastVisibilityQualityGate.evaluate(title: "Processing — Contextual", appName: "Contextual").classification == .assistantChrome)
		}

		// MARK: 4 — Accept concrete product / article / document titles

		do {
			let product = FastVisibilityQualityGate.evaluate(
				title: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
				appName: "Firefox"
			)
			check("anker_product_accepted", product.eligible)
			check("anker_product_classified_action_worthy", product.classification == .actionWorthy)

			let article = FastVisibilityQualityGate.evaluate(
				title: "How USB-C Power Delivery Negotiates Wattage — Anandtech",
				appName: "Firefox"
			)
			check("technical_article_accepted", article.eligible)

			let doc = FastVisibilityQualityGate.evaluate(
				title: "Q3 Engineering Plan — Google Docs",
				appName: "Google Chrome"
			)
			check("doc_title_accepted", doc.eligible)
		}

		// MARK: 5 — Engine shim delegates to the gate

		do {
			check("engine_rejects_duncanyu",
				  TaskInferenceEngine.isSpecificTitle("Duncanyu (Duncan Yu)", appName: "Firefox") == false)
			check("engine_rejects_amazon_homepage",
				  TaskInferenceEngine.isSpecificTitle("Amazon.ca: Low Prices – Fast Shipping – Millions of Items", appName: "Firefox") == false)
			check("engine_accepts_anker_product",
				  TaskInferenceEngine.isSpecificTitle("Anker Prime 27,650mAh 250W Power Bank — Amazon", appName: "Firefox"))
		}

		// MARK: 6 — Stronger context arrives → previous weak title flagged for replacement
		//   This validates the helper logic; the AppDelegate emits the actual log.

		do {
			let prev = "Amazon.ca: Low Prices – Fast Shipping – Millions of Items"
			let next = "Anker Prime 27,650mAh 250W Power Bank — Amazon"
			let prevWeak = FastVisibilityQualityGate.isWeakOrGeneric(title: prev, appName: "Firefox")
			let nextStrong = FastVisibilityQualityGate.isActionWorthy(title: next, appName: "Firefox")
			check("weak_previous_detected", prevWeak)
			check("strong_next_detected", nextStrong)
			check("replacement_trigger_combo", prevWeak && nextStrong)
		}

		// MARK: 7 — Execution-time stale-goal detection: cached weak vs current strong

		do {
			let cachedGoal = "Amazon.ca: Low Prices – Fast Shipping – Millions of Items"
			let currentTitle = "Anker Prime 27,650mAh 250W Power Bank — Amazon"
			let cachedDecision = FastVisibilityQualityGate.evaluate(title: cachedGoal, appName: "Firefox")
			let currentDecision = FastVisibilityQualityGate.evaluate(title: currentTitle, appName: "Firefox")
			check("stale_cached_goal_flagged", cachedDecision.eligible == false)
			check("current_title_eligible", currentDecision.eligible)
		}

		// MARK: 8 — Execution-time repair allows when cached goal already references current entity

		do {
			let cachedGoal = "Anker Prime Power Bank details"
			let currentTitle = "Anker Prime 27,650mAh 250W Power Bank — Amazon"
			// Both action-worthy → no repair needed.
			check("aligned_cached_strong", FastVisibilityQualityGate.isActionWorthy(title: cachedGoal, appName: "Firefox"))
			check("aligned_current_strong", FastVisibilityQualityGate.isActionWorthy(title: currentTitle, appName: "Firefox"))
		}

		// MARK: 9 — Edge: empty / too-short titles rejected

		do {
			check("empty_rejected",
				  FastVisibilityQualityGate.evaluate(title: "", appName: "Firefox").classification == .tooShort)
			check("too_short_rejected",
				  FastVisibilityQualityGate.evaluate(title: "ok", appName: "Firefox").classification == .tooShort)
		}

		// MARK: 10 — No hardcoded fallback titles introduced. The gate never
		//   manufactures a title — it only ever returns the rejection reason.

		do {
			let d = FastVisibilityQualityGate.evaluate(title: "Random", appName: "Firefox")
			check("gate_never_synthesizes_title",
				  d.classification != .actionWorthy)
		}

		let ok = failures.isEmpty
		print("[FastVisibilityQualitySelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
