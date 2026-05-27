import Foundation

/// Phase 4U self-test for agentic runtime quality:
///   - Compare → extract pivot when only one live product is on the page.
///   - History-only comparison candidates rejected.
///   - Anchored price wins over tiny unrelated UI price.
///   - Product title cleanup removes truncated compatibility fragments.
///
/// Run with: `CONTEXTUAL_RUN_AGENTIC_RUNTIME_QUALITY_SELFTEST=1`
///
/// Deterministic — no AppKit, no network, no AI calls.
enum AgenticRuntimeQualitySelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[AgenticRuntimeQualitySelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — Single product page → ComparePivotGate pivots to extract.

		do {
			let d = ComparePivotGate.evaluate(
				goal: "Compare Anker Prime USB C Charger",
				liveGroundedCandidateCount: 1
			)
			check("single_product_pivot_required", d.shouldPivot)
			check("single_product_pivot_family_extract", d.pivotedFamily == "extract")
			check("single_product_reason_typed",
				  d.reason == "pivot_compare_to_extract_single_product")
			check("single_product_repaired_goal_starts_with_extract",
				  d.repairedGoal.lowercased().hasPrefix("extract "))
			check("single_product_repaired_goal_preserves_entity",
				  d.repairedGoal.lowercased().contains("anker prime"))
		}

		// MARK: 2 — Compare requires two live grounded candidates.

		do {
			let two = ComparePivotGate.evaluate(
				goal: "Compare laptop chargers",
				liveGroundedCandidateCount: 2
			)
			check("two_live_candidates_keep_compare", two.shouldPivot == false)
			check("two_live_candidates_family_compare", two.pivotedFamily == "compare")

			let zero = ComparePivotGate.evaluate(
				goal: "Compare Anker Prime",
				liveGroundedCandidateCount: 0
			)
			check("zero_live_candidates_pivot", zero.shouldPivot)
			check("zero_live_candidates_reason",
				  zero.reason == "pivot_compare_to_extract_no_live_candidates")
		}

		// MARK: 3 — Non-compare goals are not pivoted.

		do {
			let d = ComparePivotGate.evaluate(
				goal: "Summarize Anker Prime details",
				liveGroundedCandidateCount: 0
			)
			check("non_compare_not_pivoted", d.shouldPivot == false)
			check("non_compare_reason_typed", d.reason == "not_a_compare_goal")
			check("non_compare_repaired_equals_input",
				  d.repairedGoal == "Summarize Anker Prime details")
		}

		// MARK: 4 — Browsing-history-only candidate rejected by validator.

		do {
			let state = AgenticEvidenceState(
				goal: "Compare Anker Prime",
				requirements: [],
				satisfied: [],
				missing: [],
				missingOptional: [],
				confidence: 0,
				shouldGatherMore: false,
				recommendedAction: .present
			)
			let observations: [AgenticEvidenceObservation] = [
				AgenticEvidenceObservation(
					id: "o_live",
					kind: .productTitle,
					text: "Anker Prime 27,650mAh 250W Power Bank",
					normalized: "anker prime",
					confidence: 0.9,
					source: .ocr,
					reason: "ocr_extract"
				),
				// History-only Dexter title must be ignored.
				AgenticEvidenceObservation(
					id: "o_hist",
					kind: .comparisonCandidate,
					text: "Dexter Season Finale Review",
					normalized: "dexter",
					confidence: 0.5,
					source: .browsingHistory,
					reason: "browsing_memory"
				),
			]
			let result = ComparisonEvidenceValidator.validate(
				state: state,
				observations: observations,
				entities: [],
				facts: []
			)
			check("history_only_candidate_excluded", result.isValid == false)
			check("history_only_validator_missing_second",
				  result.missingElements.contains("second_valid_comparison_candidate"))
		}

		// MARK: 5 — AnchoredPriceResolver picks anchored OCR price over tiny UI fee.

		do {
			let strong = AnchoredPriceCandidate(
				rawText: "$29.99",
				anchorContext: "price: $29.99 buy now in stock",
				confidence: 0.88,
				occurrenceCount: 2,
				source: "ocr"
			)
			let weak = AnchoredPriceCandidate(
				rawText: "$5.01",
				anchorContext: "shipping $5.01",
				confidence: 0.55,
				occurrenceCount: 1,
				source: "ocr"
			)
			let decision = AnchoredPriceResolver.resolve(candidates: [weak, strong])
			check("price_resolver_picks_anchored",
				  decision.selected?.rawText == "$29.99")
			check("price_resolver_rejects_weak",
				  decision.rejected.contains(where: { $0.rawText == "$5.01" }))
			check("price_resolver_reason_typed",
				  decision.reason == "stronger_anchor" || decision.reason == "weak_anchor")
		}

		// MARK: 6 — AnchoredPriceResolver returns nil only when input is empty.

		do {
			let decision = AnchoredPriceResolver.resolve(candidates: [])
			check("price_resolver_empty_returns_nil", decision.selected == nil)
			check("price_resolver_empty_reason", decision.reason == "no_candidates")
		}

		// MARK: 7 — ProductTitleSynthesizer trims the compat-list tail.

		do {
			let raw = """
			Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger, Foldable Plug, Compatible With MacBook Pro Air iPhone 17 16 15 14 13 Pro Max Plus Series, Galaxy S25 S24 S23, iPad, Cable Not Include
			"""
			let result = ProductTitleSynthesizer.synthesize(raw: raw)
			check("title_cleanup_returns_non_nil", result.cleanedTitle != nil)
			let cleaned = result.cleanedTitle ?? ""
			check("title_cleanup_keeps_brand_and_model",
				  cleaned.contains("Anker Prime USB C Charger Block"))
			check("title_cleanup_strips_compat_with",
				  !cleaned.lowercased().contains("compatible with"))
			check("title_cleanup_strips_truncated_cable",
				  !cleaned.lowercased().contains("cable not include"))
			check("title_cleanup_capped_length",
				  cleaned.count <= ProductTitleSynthesizer.maxLength)
			check("title_cleanup_reason_typed",
				  result.reason == "cleaned_trimmed_compat_clause")
		}

		// MARK: 8 — Reject obvious truncation markers.

		do {
			let result = ProductTitleSynthesizer.synthesize(
				raw: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone..."
			)
			check("title_truncation_marker_rejected", result.cleanedTitle == nil)
			check("title_truncation_reason", result.reason == "rejected_truncation")
		}

		// MARK: 9 — Already-clean title round-trips unchanged.

		do {
			let result = ProductTitleSynthesizer.synthesize(
				raw: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger"
			)
			check("title_already_clean_returns_input",
				  result.cleanedTitle == "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger")
			check("title_already_clean_reason", result.reason == "cleaned_no_change")
		}

		// MARK: 10 — Goal alignment validator pivots compare on single-product page.

		do {
			let decision = AgenticGoalAlignmentValidator.validate(
				title: "Compare Anker Prime USB C Charger",
				goal: "Compare Anker Prime USB C Charger",
				workflow: "shopping",
				appName: "Firefox",
				bundleId: "org.mozilla.firefox",
				windowTitle: "Anker Prime 27,650mAh 250W Power Bank — Amazon",
				ocrExcerpt: "Anker Prime 27,650mAh 250W Power Bank $29.99 4.7 out of 5 stars",
				axExcerpt: nil,
				evidenceObservations: [],
				semanticEntities: [
					GroundedSemanticEntity(
						id: "e_title",
						type: .productTitle,
						text: "Anker Prime 27,650mAh 250W Power Bank",
						normalizedValue: "anker prime",
						confidence: 0.9,
						sourceNodeId: "n1",
						role: .heading,
						tags: []
					)
				],
				allowedCapabilities: []
			)
			check("goal_alignment_pivots_compare_to_extract",
				  decision.status == .repaired)
			check("goal_alignment_reason_compare_to_extract",
				  decision.reason == "compare_to_extract_pivot")
			check("goal_alignment_repairs_visible_title",
				  decision.alignedTitle.lowercased().hasPrefix("extract "))
			check("goal_alignment_repaired_goal_extract",
				  decision.alignedGoal.lowercased().hasPrefix("extract "))
		}

		// MARK: 11 — Goal alignment KEEPS compare when two live products are on page.

		do {
			let decision = AgenticGoalAlignmentValidator.validate(
				title: "Compare laptop chargers",
				goal: "Compare laptop chargers",
				workflow: "shopping",
				appName: "Firefox",
				bundleId: "org.mozilla.firefox",
				windowTitle: "Laptop Chargers — Best Buy",
				ocrExcerpt: "Anker Prime $29.99 Belkin BoostCharge $39.99",
				axExcerpt: nil,
				evidenceObservations: [],
				semanticEntities: [
					GroundedSemanticEntity(id: "e1", type: .productTitle, text: "Anker Prime Charger", normalizedValue: "anker", confidence: 0.9, sourceNodeId: "n1", role: .heading, tags: []),
					GroundedSemanticEntity(id: "e2", type: .productTitle, text: "Belkin BoostCharge", normalizedValue: "belkin", confidence: 0.9, sourceNodeId: "n2", role: .heading, tags: []),
				],
				allowedCapabilities: []
			)
			// Either accepted or repaired for another reason (e.g. generic_summary on product) —
			// but never the compare_to_extract pivot.
			check("two_live_products_no_compare_pivot",
				  decision.detectedIssue != "pivot_compare_to_extract_single_product"
				  && decision.detectedIssue != "pivot_compare_to_extract_no_live_candidates")
		}

		// MARK: 12 — Rendered answer uses anchored price + synthesized title.

		do {
			let now = Date()
			let titleRaw = "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger, Foldable Plug, Compatible With MacBook Pro Air iPhone 17 16 15 14 13 Pro Max Plus Series, Galaxy S25 S24 S23, iPad, Cable Not Include"
			let observation = AgenticObservation(
				stepIndex: 1,
				activeApp: "Firefox",
				windowTitle: titleRaw,
				contextSummary: nil,
				selectedText: nil,
				ocrExcerpt: nil,
				quality: .metadata_only,
				freshnessScore: 0.95,
				observedAt: now,
				sources: ["window_title"],
				isPostControlObservation: false,
				snapshotID: UUID(),
				previousSnapshotID: nil,
				textHash: nil
			)

			let strongNode = ScreenStateNode(
				stableId: "n_price_strong",
				role: .price,
				title: "$29.99",
				text: "Price",
				frame: nil,
				visible: true,
				interactable: false,
				confidence: 0.9,
				source: .ocr,
				semanticTags: ["price", "buy"],
				parentId: nil,
				childIds: [],
				viewportVisibility: 0.8
			)
			let weakNode = ScreenStateNode(
				stableId: "n_price_weak",
				role: .price,
				title: "$5.01",
				text: "Shipping",
				frame: nil,
				visible: true,
				interactable: false,
				confidence: 0.55,
				source: .ocr,
				semanticTags: ["shipping"],
				parentId: nil,
				childIds: [],
				viewportVisibility: 0.8
			)
			let graph = ScreenStateGraph(rootId: "root", nodes: [strongNode, weakNode])

			let priceStrong = GroundedSemanticEntity(
				id: "e_price_strong",
				type: .price,
				text: "$29.99",
				normalizedValue: "29.99",
				confidence: 0.88,
				sourceNodeId: strongNode.stableId,
				role: .price,
				tags: ["price"]
			)
			let priceWeak = GroundedSemanticEntity(
				id: "e_price_weak",
				type: .price,
				text: "$5.01",
				normalizedValue: "5.01",
				confidence: 0.55,
				sourceNodeId: weakNode.stableId,
				role: .price,
				tags: ["shipping"]
			)

			let session = AgenticSessionState(
				planId: "p",
				goal: "Extract product details",
				workflow: "browsing",
				stepIndex: 1,
				maxSteps: 5,
				llmCallsUsed: 0,
				ocrCallsUsed: 0,
				scrollsUsed: 0,
				findsUsed: 0,
				maxScrolls: 1,
				maxFinds: 1,
				startedAt: now,
				observations: [observation],
				extractedFacts: [],
				finalAnswer: nil,
				stopReason: nil,
				actionsExecuted: [],
				forceObserveNext: false,
				lastActionWasControl: false,
				blockedActions: [],
				controlDecisionLog: [],
				ineffectiveControlCount: 0,
				failedControlActions: [],
				worldStateTransitions: [],
				discoveredEntities: [],
				lastObservationSnapshotID: nil,
				lastObservationTextHash: nil,
				screenStateGraph: graph,
				groundedTargets: [],
				primaryGroundedTarget: nil,
				semanticEntities: [priceWeak, priceStrong],
				structuredFacts: [],
				semanticReadiness: nil,
				evidenceRequirements: [],
				evidenceState: nil,
				evidenceObservations: []
			)

			let runtime = AgenticRuntime()
			let answer = runtime.buildPremiumAnswer(session: session)
			check("answer_prefers_anchored_price",
				  answer.contains("$29.99") && !answer.contains("$5.01"))
			check("answer_synthesizes_product_title",
				  answer.contains("Anker Prime USB C Charger Block")
				  && !answer.lowercased().contains("cable not include")
				  && !answer.lowercased().contains("compatible with"))
		}

		let ok = failures.isEmpty
		print("[AgenticRuntimeQualitySelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
