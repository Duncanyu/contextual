import Foundation

/// Phase 4Q self-test for the planner capability envelope, the strict-retry
/// prompt, and the goal-alignment capability-repair logs.
///
/// Run with: `CONTEXTUAL_RUN_PLANNER_CAPABILITY_ENVELOPE_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no AI calls.
enum PlannerCapabilityEnvelopeSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[PlannerCapabilityEnvelopeSelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — Classifier: unsafe verbs land in the right category

		do {
			check("classify_purchase",
				  PlannerCapabilityRepairGate.classify(title: "Purchase Anker Prime USB C Charger") == .purchase)
			check("classify_buy",
				  PlannerCapabilityRepairGate.classify(title: "Buy now MacBook Pro") == .purchase)
			check("classify_wishlist",
				  PlannerCapabilityRepairGate.classify(title: "Add Anker Prime to Wishlist") == .wishlist)
			check("classify_cart",
				  PlannerCapabilityRepairGate.classify(title: "Add to cart for free shipping") == .cart)
			check("classify_checkout",
				  PlannerCapabilityRepairGate.classify(title: "Checkout and pay") == .checkout)
			check("classify_signin",
				  PlannerCapabilityRepairGate.classify(title: "Sign in to Amazon") == .authentication)
			check("classify_delete",
				  PlannerCapabilityRepairGate.classify(title: "Delete current order") == .destructive)
		}

		// MARK: 2 — Classifier: navigation vs safe

		do {
			check("classify_search_navigation",
				  PlannerCapabilityRepairGate.classify(title: "Search Amazon for Anker Prime") == .searchNavigation)
			check("classify_open_navigation",
				  PlannerCapabilityRepairGate.classify(title: "Open Firefox settings") == .openNavigation)
			check("classify_click",
				  PlannerCapabilityRepairGate.classify(title: "Click the Add to Cart button") == .clickInteraction)
			check("classify_type",
				  PlannerCapabilityRepairGate.classify(title: "Type address into search box") == .typeInteraction)
		}

		// MARK: 3 — Classifier: safe families

		do {
			check("classify_compare",
				  PlannerCapabilityRepairGate.classify(title: "Compare Anker Prime specs") == .safeCompare)
			check("classify_summarize",
				  PlannerCapabilityRepairGate.classify(title: "Summarize Anker Prime details") == .safeSummarize)
			check("classify_extract",
				  PlannerCapabilityRepairGate.classify(title: "Extract Anker Prime wattage") == .safeExtract)
			check("classify_inspect",
				  PlannerCapabilityRepairGate.classify(title: "Inspect Anker Prime page") == .safeInspect)
			check("classify_gather",
				  PlannerCapabilityRepairGate.classify(title: "Gather more visible product evidence") == .safeGather)
		}

		// MARK: 4 — allUnsafe across a candidate list

		do {
			let unsafeOnly = ["Purchase Anker Prime", "Add Anker Prime to Wishlist", "Search Amazon for Anker"]
			let probe1 = PlannerCapabilityRepairGate.allUnsafe(titles: unsafeOnly)
			check("allUnsafe_true_for_unsafe_only", probe1.allUnsafe)
			check("allUnsafe_categories_count_matches",
				  probe1.categories.count == unsafeOnly.count)

			let mixed = ["Purchase Anker Prime", "Compare Anker Prime specs"]
			let probe2 = PlannerCapabilityRepairGate.allUnsafe(titles: mixed)
			check("allUnsafe_false_for_mixed", probe2.allUnsafe == false)

			let empty: [String] = []
			let probe3 = PlannerCapabilityRepairGate.allUnsafe(titles: empty)
			check("allUnsafe_false_for_empty", probe3.allUnsafe == false)
		}

		// MARK: 5 — Strict planner prompt: forbidden vocabulary + allowed intents present

		do {
			let snapshot = makeSnapshot()
			let situational = makeSituational()
			let strict = TwoStageCompactPlannerPromptBuilder.build(
				snapshot: snapshot,
				situational: situational,
				recentTitles: [],
				history: nil,
				referenceTime: Date(),
				comparisonHint: nil,
				strict: true
			)
			check("strict_prompt_mentions_envelope",
				  strict.contains("CAPABILITY ENVELOPE"))
			check("strict_prompt_lists_forbidden_verbs",
				  strict.lowercased().contains("forbidden") && strict.lowercased().contains("purchase")
				  && strict.lowercased().contains("wishlist") && strict.lowercased().contains("cart"))
			check("strict_prompt_lists_allowed_intents",
				  strict.lowercased().contains("inspect") && strict.lowercased().contains("extract")
				  && strict.lowercased().contains("summarize") && strict.lowercased().contains("compare"))
			check("strict_prompt_no_canned_titles",
				  !strict.contains("Review visible") && !strict.contains("Analyze visible")
				  && !strict.contains("Inspect content") && !strict.contains("Compare visible"))
		}

		// MARK: 6 — Non-strict prompt does NOT carry the envelope preface

		do {
			let snapshot = makeSnapshot()
			let situational = makeSituational()
			let normal = TwoStageCompactPlannerPromptBuilder.build(
				snapshot: snapshot,
				situational: situational,
				recentTitles: [],
				history: nil,
				referenceTime: Date(),
				comparisonHint: nil,
				strict: false
			)
			check("normal_prompt_no_envelope_preface",
				  !normal.contains("CAPABILITY ENVELOPE"))
		}

		// MARK: 7 — Validator rejects unsafe candidates (preserves Phase 4P contract)

		do {
			let isolated = IsolatedProposalContext(
				appName: "Firefox",
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
				selectedText: nil,
				ocrExcerpt: "Anker Prime 27,650mAh 250W Power Bank",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["window_title", "ocr_excerpt"],
				excludedSources: []
			)
			let r1 = ProposalCapabilityValidator.validate(
				title: "Purchase Anker Prime USB C Charger",
				goal: "Buy",
				isolated: isolated,
				stage: "early"
			)
			check("validator_rejects_purchase",
				  r1.accepted == false && r1.reason == "unsupported_capability")

			let r2 = ProposalCapabilityValidator.validate(
				title: "Add Anker Prime to Wishlist",
				goal: "Wishlist",
				isolated: isolated,
				stage: "early"
			)
			check("validator_rejects_wishlist",
				  r2.accepted == false)
		}

		// MARK: 8 — Goal-alignment repairs Search on current context

		do {
			let decision = AgenticGoalAlignmentValidator.validate(
				title: "Search Amazon for Anker Prime USB C Charger",
				goal: "Search Amazon for Anker Prime",
				workflow: "shopping",
				appName: "Firefox",
				bundleId: "org.mozilla.firefox",
				windowTitle: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
				ocrExcerpt: "Anker Prime 27,650mAh 250W Power Bank $129.99"
			)
			check("alignment_repaired_for_search_on_current_context",
				  decision.status == .repaired)
			check("repaired_goal_uses_extract_phrasing",
				  decision.alignedGoal.lowercased().contains("extract")
				  && !decision.alignedGoal.lowercased().hasPrefix("review visible")
				  && !decision.alignedGoal.lowercased().hasPrefix("analyze visible"))
			check("repaired_visible_title_unchanged",
				  decision.alignedTitle == "Search Amazon for Anker Prime USB C Charger")
		}

		// MARK: 9 — Valid current-page gather title passes the envelope

		do {
			check("gather_candidate_is_safe",
				  PlannerCapabilityRepairGate.classify(title: "Gather visible product evidence on this page").isAllowed)
			check("summarize_candidate_is_safe",
				  PlannerCapabilityRepairGate.classify(title: "Summarize Anker Prime details on this page").isAllowed)
		}

		// MARK: 10 — Envelope flags consistency

		do {
			check("purchase_is_unsafe_not_allowed",
				  PlannerCapabilityCategory.purchase.isUnsafe && !PlannerCapabilityCategory.purchase.isAllowed)
			check("search_navigation_is_navigation_not_allowed",
				  PlannerCapabilityCategory.searchNavigation.isNavigation
				  && !PlannerCapabilityCategory.searchNavigation.isAllowed)
			check("safe_extract_is_allowed_not_unsafe",
				  PlannerCapabilityCategory.safeExtract.isAllowed
				  && !PlannerCapabilityCategory.safeExtract.isUnsafe)
		}

		let ok = failures.isEmpty
		print("[PlannerCapabilityEnvelopeSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}

	// MARK: - Stubs

	private static func makeSnapshot() -> CanonicalGeneratedExecutionContextSnapshot {
		CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: "Anker Prime 27,650mAh 250W Power Bank\n$129.99\n4.7 out of 5 stars",
			contextSummary: nil,
			workflowConfidence: 0.85,
			freshnessScore: 0.92
		)
	}

	private static func makeSituational() -> SituationalContextSnapshot {
		// Use the production synthesizer to avoid coupling the test to the full
		// `SituationalContextSnapshot` field list (it carries many signals).
		SituationalContextSynthesizer.synthesize(from: makeSnapshot())
	}
}
