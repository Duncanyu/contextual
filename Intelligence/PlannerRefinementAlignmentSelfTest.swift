import Foundation

/// Phase 4N self-test for the planner-refinement alignment gate,
/// the find-on-page query hardening, and the generated chrome filter.
///
/// Run with: `CONTEXTUAL_RUN_PLANNER_REFINEMENT_ALIGNMENT_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no AI calls.
enum PlannerRefinementAlignmentSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[PlannerRefinementAlignmentSelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — Bad refinement: Summarize shell → Search Firefox History (browser chrome)

		do {
			let d = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Summarize Anker Laptop Charger",
				newRefinedTitle: "Search Firefox History for 'Anker Laptop Charger'",
				pageWindowTitle: "Anker Laptop Power Bank - Amazon",
				pageBundleIdentifier: "org.mozilla.firefox",
				workflow: "browsing"
			)
			check("rejects_search_firefox_history", d.aligned == false)
			check("reason_browser_chrome_misaligned", d.reason == "browser_chrome_navigation_misaligned")
			check("old_family_summarize", d.oldFamily == "summarize")
		}

		// MARK: 2 — Good refinement: same family, page entity added

		do {
			let d = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Summarize Anker Laptop Charger",
				newRefinedTitle: "Summarize this Amazon product page",
				pageWindowTitle: "Anker Laptop Power Bank - Amazon",
				pageBundleIdentifier: "org.mozilla.firefox"
			)
			check("accepts_same_family_summarize", d.aligned)
			check("reason_aligned_summarize", d.reason == "aligned")

			let d2 = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Review Anker Laptop Charger",
				newRefinedTitle: "Review Anker Laptop Charger details",
				pageWindowTitle: "Anker Laptop Charger - Amazon"
			)
			check("accepts_review_with_entity", d2.aligned)

			let d3 = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Compare Laptop Chargers",
				newRefinedTitle: "Compare Anker Laptop Charger specs",
				pageWindowTitle: "Anker Laptop Charger - Amazon"
			)
			check("accepts_compare_with_entity", d3.aligned)
		}

		// MARK: 3 — Bad refinement: Review shell → Purchase verb

		do {
			let d = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Review Anker Laptop Charger",
				newRefinedTitle: "Purchase Anker Laptop Charger",
				pageWindowTitle: "Anker Laptop Charger - Amazon"
			)
			check("rejects_purchase_verb", d.aligned == false)
			check("reason_unsafe_commerce_verb", d.reason == "unsafe_commerce_verb")
		}

		// MARK: 4 — Bad refinement: Review shell → Open Firefox settings (chrome)

		do {
			let d = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Review Anker Laptop Charger",
				newRefinedTitle: "Open Firefox settings",
				pageWindowTitle: "Anker Laptop Charger - Amazon",
				pageBundleIdentifier: "org.mozilla.firefox"
			)
			check("rejects_open_firefox_settings", d.aligned == false)
			check("reason_chrome_open_settings", d.reason == "browser_chrome_navigation_misaligned")
		}

		// MARK: 5 — Bad refinement: Summarize → unknown family (drops verb)

		do {
			let d = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Summarize Anker Laptop Charger",
				newRefinedTitle: "Anker Laptop Charger 140W",
				pageWindowTitle: "Anker Laptop Charger - Amazon"
			)
			check("rejects_dropped_verb", d.aligned == false)
			check("reason_task_family_mismatch_dropped", d.reason == "task_family_mismatch")
		}

		// MARK: 6 — Phrase-based unsafe (no single token)

		do {
			let d = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Review Anker Laptop Charger",
				newRefinedTitle: "Add to cart for free shipping"
			)
			check("rejects_add_to_cart_phrase", d.aligned == false)
			check("reason_unsafe_phrase", d.reason == "unsafe_commerce_verb")
		}

		// MARK: 7 — find_on_page query hardening: app names & chrome words excluded

		do {
			let goal = "Search Firefox History for 'Anker Laptop Charger'"
			let q = AgenticControlPolicy.determineFindQuery(goal: goal)
			check("find_query_not_firefox", q != "firefox")
			check("find_query_not_history", q != "history")
			check("find_query_not_search", q != "search")
			// Should land on a content token (anker / laptop / charger) — any
			// of these is acceptable. The "information" fallback would be a
			// regression because the goal does contain real content tokens.
			let contentCandidates: Set<String> = ["anker", "laptop", "charger"]
			check("find_query_is_content_token", contentCandidates.contains(q))

			let goal2 = "Open Firefox bookmarks"
			let q2 = AgenticControlPolicy.determineFindQuery(goal: goal2)
			check("find_query_chrome_only_falls_back",
				  q2 == "information" || !AgenticControlPolicy.findQueryBlocklist.contains(q2))

			// Verify keyword-class queries still take priority.
			let q3 = AgenticControlPolicy.determineFindQuery(goal: "Read customer reviews")
			check("find_query_review_keyword_wins", q3 == "review")
		}

		// MARK: 8 — GeneratedChromeFilter suppresses Processing <goal>

		do {
			let ocr = """
			Anker Laptop Charger
			Processing Search Firefox History for 'Anker Laptop Charger'
			$129.99
			Search Firefox History for 'Anker Laptop Charger'
			Summarize Anker Laptop Charger
			"""
			let r = GeneratedChromeFilter.filter(
				text: ocr,
				runtimeGoal: "Search Firefox History for 'Anker Laptop Charger'",
				proposalTitle: "Summarize Anker Laptop Charger"
			)
			check("suppresses_processing_current_goal",
				  r.suppressedReasons.contains(where: { $0.contains("processing_current_goal") || $0 == "processing_current_title" }))
			check("suppresses_exact_current_goal",
				  r.suppressedReasons.contains("matches_current_goal"))
			check("suppresses_exact_current_title",
				  r.suppressedReasons.contains("matches_current_title"))
			check("keeps_real_content_anker",
				  r.filteredText.contains("Anker Laptop Charger"))
			check("keeps_real_price",
				  r.filteredText.contains("$129.99"))
		}

		// MARK: 9 — GeneratedChromeFilter assistant runtime chrome

		do {
			let ocr = """
			Generated Execution
			Runtime Phase
			Actions Taken
			Controlled Interactions
			Anker Laptop Charger
			Open
			Execute
			"""
			let r = GeneratedChromeFilter.filter(text: ocr, runtimeGoal: nil)
			check("suppresses_assistant_runtime_chrome",
				  r.suppressedReasons.contains("assistant_runtime_chrome"))
			check("suppresses_single_token_open",
				  r.suppressedReasons.contains("single_token_assistant_chrome"))
			check("keeps_real_product_among_chrome",
				  r.filteredText.contains("Anker Laptop Charger"))
		}

		// MARK: 10 — Edge cases

		do {
			let empty = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Summarize Anker Laptop Charger",
				newRefinedTitle: ""
			)
			check("rejects_empty_refinement", empty.aligned == false)

			let unchanged = PlannerRefinementAlignmentGate.evaluate(
				oldShellTitle: "Summarize Anker Laptop Charger",
				newRefinedTitle: "Summarize Anker Laptop Charger"
			)
			check("accepts_unchanged_title", unchanged.aligned)
		}

		let ok = failures.isEmpty
		print("[PlannerRefinementAlignmentSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
