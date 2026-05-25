import Foundation

/// Phase 4F self-tests for intent grounding, proposal sanity filtering, and domain consistency.
///
/// Run with: CONTEXTUAL_RUN_AGENTIC_INTENT_GROUNDING_SELFTEST=1
///
/// Tests cover: entity extraction, allowed/forbidden domain classification,
/// semantic overlap scoring, hallucination risk detection, product/shopping detection,
/// and end-to-end filtering of misaligned proposals.
enum AgenticIntentGroundingSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[AgenticIntentGroundingSelfTest] FAIL \(name)")
			}
		}

		let extractor = AgenticIntentGroundingExtractor()
		let filter    = AgenticProposalSanityFilter()

		// MARK: - Helpers

		func makeSnapshot(
			app: String,
			bundle: String,
			windowTitle: String,
			workflow: InferredWorkflow,
			ocr: String? = nil,
			selectedText: String? = nil,
			contextSummary: String? = nil
		) -> CanonicalGeneratedExecutionContextSnapshot {
			CanonicalGeneratedExecutionContextSnapshot(
				activeApp: app,
				windowTitle: windowTitle,
				bundleIdentifier: bundle,
				inferredWorkflow: workflow,
				selectedText: selectedText,
				clipboardText: nil,
				recentOCRExcerpt: ocr,
				contextSummary: contextSummary,
				workflowConfidence: 0.85,
				freshnessScore: 0.90
			)
		}

		func makeProposal(
			title: String,
			description: String,
			workflow: WorkflowType,
			intent: IntentType,
			primitives: [ExecutionPrimitive] = [.summarizeContext],
			requiredContextTypes: [ContextRequirementType] = [.workflowContext],
			confidence: Double = 0.80
		) -> ValidatedDynamicGeneratedProposal {
			ValidatedDynamicGeneratedProposal(
				id: UUID().uuidString,
				title: title,
				description: description,
				workflowType: workflow,
				intentType: intent,
				expectedOutcome: "Completed action",
				requiredContextTypes: requiredContextTypes,
				suggestedPrimitives: primitives,
				interruptionCost: 0.3,
				confidence: confidence,
				usefulnessHint: "llm_dynamic",
				agenticPlan: nil
			)
		}

		// MARK: - Snapshots

		// Amazon AirPods 4 case page (product/shopping)
		let amazonSnapshot = makeSnapshot(
			app: "Safari",
			bundle: "com.apple.safari",
			windowTitle: "AirPods 4 Silicone Case - Spigen | Amazon",
			workflow: .browsing,
			ocr: "Spigen Silicone Fit Case for AirPods 4. Price: $12.99. Rating: 4.6/5 stars. 2,341 reviews. Add to Cart. Free shipping on orders over $25. Compatible with AirPods 4 (2024). Verified Purchase.",
			contextSummary: "User is browsing an Amazon product listing for an AirPods 4 case."
		)

		// Xcode debugger page (IDE/debugging)
		let xcodeSnapshot = makeSnapshot(
			app: "Xcode",
			bundle: "com.apple.dt.Xcode",
			windowTitle: "AgenticRuntime.swift — Contextual",
			workflow: .debugging,
			ocr: "Thread 1: EXC_BAD_ACCESS (SIGSEGV). Stack trace: AgenticRuntime.swift:142. Build failed: 3 errors.",
			selectedText: "EXC_BAD_ACCESS"
		)

		// Mail inbox page
		let mailSnapshot = makeSnapshot(
			app: "Mail",
			bundle: "com.apple.mail",
			windowTitle: "Inbox — 12 Unread",
			workflow: .reviewing,
			ocr: "From: boss@company.com Subject: Q4 Review. Unread: 12. Reply. Forward. Compose.",
			contextSummary: "User is reviewing their email inbox."
		)

		// BestBuy MacBook Pro page (shopping platform + product)
		let bestBuySnapshot = makeSnapshot(
			app: "Safari",
			bundle: "com.apple.safari",
			windowTitle: "MacBook Pro 16\" M4 Pro — Best Buy",
			workflow: .browsing,
			ocr: "MacBook Pro 16 inch. $2,499.99. Add to Cart. In Stock. Free shipping. Customer Reviews: 4.8/5. Compare models. Specs: M4 Pro chip, 24GB RAM. Warranty: 1 year.",
			contextSummary: "User is on a Best Buy MacBook Pro product page."
		)

		// MARK: - Test 1: Amazon product page rejects inbox proposal
		// An "Open inbox" proposal must be rejected on an Amazon shopping page.

		let inboxProposal = makeProposal(
			title: "Open the Inbox to check recent emails",
			description: "Navigate to your email inbox to review unread messages",
			workflow: .reviewing,
			intent: .summarize,
			requiredContextTypes: [.workflowContext]
		)

		let amazonGrounding = extractor.extract(from: amazonSnapshot)
		let inboxScore = filter.groundedProposalScore(
			proposal: inboxProposal, grounding: amazonGrounding, snapshot: amazonSnapshot
		)
		check("amazon_page_rejects_inbox_proposal",
			  inboxScore < AgenticProposalSanityFilter.rejectionThreshold)
		check("amazon_page_is_product_page", amazonGrounding.isProductPage)
		check("amazon_page_is_shopping_platform", amazonGrounding.isShoppingPlatform)
		check("amazon_page_forbids_email_domain",
			  amazonGrounding.forbiddenDomains.contains("email") ||
			  amazonGrounding.forbiddenDomains.contains("inbox"))

		// MARK: - Test 2: Shopping workflow rejects calendar proposal
		// "Schedule a calendar reminder" must be rejected on a shopping page.

		let calendarProposal = makeProposal(
			title: "Schedule a calendar reminder for this item",
			description: "Add a calendar event and appointment to remind you to buy this product",
			workflow: .browsing,
			intent: .organize,
			requiredContextTypes: [.workflowContext]
		)

		let calScore = filter.groundedProposalScore(
			proposal: calendarProposal, grounding: amazonGrounding, snapshot: amazonSnapshot
		)
		check("shopping_page_rejects_calendar_proposal",
			  calScore < AgenticProposalSanityFilter.rejectionThreshold)
		check("amazon_grounding_forbids_calendar",
			  amazonGrounding.forbiddenDomains.contains("calendar"))

		// MARK: - Test 3: Unavailable context requirement tanks availability score
		// A proposal requiring .selectedText when no text is selected must score 0 availability.
		// (Clipboard is always suppressed in agentic contexts — it has no ContextRequirementType case,
		// so we test the analogous pattern using selectedText on a snapshot without it.)

		let noSelectionSnapshot = makeSnapshot(
			app: "Safari",
			bundle: "com.apple.safari",
			windowTitle: "AirPods 4 Silicone Case - Spigen | Amazon",
			workflow: .browsing,
			ocr: "Spigen Silicone Fit Case for AirPods 4.",
			selectedText: nil    // no selected text
		)

		let selectedTextProposal = makeProposal(
			title: "Summarize the selected review text",
			description: "Analyze and summarize the text the user has currently selected on screen",
			workflow: .browsing,
			intent: .summarize,
			requiredContextTypes: [.selectedText]   // requires selection — not available
		)

		let selAvailability = filter.contextAvailabilityScore(
			proposal: selectedTextProposal, snapshot: noSelectionSnapshot
		)
		check("selected_text_required_but_absent_availability_zero", selAvailability == 0.0)

		// With no selectedText available, the availability penalty should lower the score
		let selScore = filter.groundedProposalScore(
			proposal: selectedTextProposal,
			grounding: extractor.extract(from: noSelectionSnapshot),
			snapshot: noSelectionSnapshot
		)
		// Compare to same proposal with selected text present — should be strictly lower
		let selSnapshotWithText = makeSnapshot(
			app: "Safari",
			bundle: "com.apple.safari",
			windowTitle: "AirPods 4 Silicone Case - Spigen | Amazon",
			workflow: .browsing,
			ocr: "Spigen Silicone Fit Case for AirPods 4.",
			selectedText: "AirPods 4 case review: 4.6 stars"
		)
		let selScoreWithText = filter.groundedProposalScore(
			proposal: selectedTextProposal,
			grounding: extractor.extract(from: selSnapshotWithText),
			snapshot: selSnapshotWithText
		)
		check("unavailable_context_lowers_score", selScore < selScoreWithText)

		// MARK: - Test 4: Product page accepts comparison/review proposal
		// A "Compare AirPods 4 case reviews" proposal must pass on the Amazon page.

		let compareProposal = makeProposal(
			title: "Compare AirPods 4 case reviews and ratings",
			description: "Summarize the customer reviews and ratings for this AirPods 4 silicone case from Spigen",
			workflow: .browsing,
			intent: .compare,
			primitives: [.compareContexts, .summarizeContext],
			requiredContextTypes: [.screenCapture, .workflowContext]
		)

		let compareScore = filter.groundedProposalScore(
			proposal: compareProposal, grounding: amazonGrounding, snapshot: amazonSnapshot
		)
		check("product_page_accepts_comparison_proposal",
			  compareScore >= AgenticProposalSanityFilter.rejectionThreshold)

		// Also check the filter allows it through
		let filteredCompare = filter.filter(
			proposals: [compareProposal],
			grounding: amazonGrounding,
			snapshot: amazonSnapshot
		)
		check("product_page_comparison_survives_filter", filteredCompare.count == 1)

		// MARK: - Test 5: IDE workflow rejects shopping proposal
		// A "Compare MacBook prices" proposal must be rejected in Xcode/debugging context.

		let shoppingProposal = makeProposal(
			title: "Compare MacBook Pro prices across stores",
			description: "Find the best deal by comparing MacBook prices on Amazon and BestBuy",
			workflow: .browsing,
			intent: .compare,
			requiredContextTypes: [.workflowContext]
		)

		let xcodeGrounding = extractor.extract(from: xcodeSnapshot)
		let shopScore = filter.groundedProposalScore(
			proposal: shoppingProposal, grounding: xcodeGrounding, snapshot: xcodeSnapshot
		)
		check("ide_workflow_rejects_shopping_proposal",
			  shopScore < AgenticProposalSanityFilter.rejectionThreshold)
		check("ide_grounding_forbids_shopping",
			  xcodeGrounding.forbiddenDomains.contains("shopping"))
		check("ide_grounding_allows_debugging",
			  xcodeGrounding.allowedDomains.contains("debugging"))

		// MARK: - Test 6: Strong OCR entities improve semantic overlap score
		// A proposal mentioning "Spigen" and "AirPods" should score higher than one with no overlap.

		let richProposal = makeProposal(
			title: "Summarize Spigen AirPods 4 case customer reviews",
			description: "Extract rating, price, and key review themes from the Spigen AirPods 4 silicone case listing",
			workflow: .browsing,
			intent: .summarize,
			requiredContextTypes: [.screenCapture]
		)
		let genericProposal = makeProposal(
			title: "Take action",
			description: "Perform an unrelated general task",
			workflow: .browsing,
			intent: .summarize
		)

		let richOverlap    = filter.semanticOverlapScore(proposal: richProposal, grounding: amazonGrounding)
		let genericOverlap = filter.semanticOverlapScore(proposal: genericProposal, grounding: amazonGrounding)
		check("entity_rich_proposal_higher_overlap", richOverlap > genericOverlap)
		check("entity_rich_proposal_overlap_above_zero", richOverlap > 0.0)

		// MARK: - Test 7: Low-overlap candidate rejected by filter pipeline
		// A completely off-topic proposal must be rejected by filter().

		let offTopicProposal = makeProposal(
			title: "Compile and build the Xcode project",
			description: "Run the build target and fix compile errors in the IDE debug console",
			workflow: .debugging,
			intent: .explain,
			requiredContextTypes: [.errorContext]
		)

		let offTopicFiltered = filter.filter(
			proposals: [offTopicProposal],
			grounding: amazonGrounding,
			snapshot: amazonSnapshot
		)
		check("off_topic_proposal_rejected_by_filter", offTopicFiltered.isEmpty)

		let offTopicScore = filter.groundedProposalScore(
			proposal: offTopicProposal, grounding: amazonGrounding, snapshot: amazonSnapshot
		)
		check("off_topic_proposal_score_below_threshold",
			  offTopicScore < AgenticProposalSanityFilter.rejectionThreshold)

		// MARK: - Test 8: Grounded proposal survives activation on BestBuy page
		// A "Summarize MacBook Pro specs and price" proposal must pass on the BestBuy MacBook page.
		// Multiple proposals: 1 good + 1 bad. Filter keeps the good one only.

		let bestBuyGrounding = extractor.extract(from: bestBuySnapshot)

		let macbookSpecProposal = makeProposal(
			title: "Summarize MacBook Pro specs, price, and reviews",
			description: "Extract and organize the specs, pricing, warranty, and customer review highlights for this MacBook Pro listing",
			workflow: .browsing,
			intent: .summarize,
			primitives: [.summarizeContext, .extractActionItems],
			requiredContextTypes: [.screenCapture, .workflowContext]
		)
		let badProposal = makeProposal(
			title: "Open inbox and compose email reply",
			description: "Go to the email inbox and compose a reply to the latest unread message",
			workflow: .reviewing,
			intent: .organize,
			requiredContextTypes: [.workflowContext]
		)

		let mixedFiltered = filter.filter(
			proposals: [macbookSpecProposal, badProposal],
			grounding: bestBuyGrounding,
			snapshot: bestBuySnapshot
		)

		check("bestbuy_page_is_product_page", bestBuyGrounding.isProductPage)
		check("bestbuy_page_is_shopping_platform", bestBuyGrounding.isShoppingPlatform)
		check("grounded_proposal_survives_bestbuy_filter",
			  mixedFiltered.contains(where: { $0.id == macbookSpecProposal.id }))
		check("inbox_proposal_rejected_on_bestbuy_page",
			  !mixedFiltered.contains(where: { $0.id == badProposal.id }))
		check("bestbuy_filter_keeps_exactly_one", mixedFiltered.count == 1)

		// MARK: - Bonus: Mail inbox correctly accepts inbox-type proposals

		let mailGrounding = extractor.extract(from: mailSnapshot)
		let mailProposal = makeProposal(
			title: "Summarize unread email threads",
			description: "Review and summarize the latest unread email messages in the inbox",
			workflow: .reviewing,
			intent: .summarize,
			requiredContextTypes: [.workflowContext]
		)

		let mailScore = filter.groundedProposalScore(
			proposal: mailProposal, grounding: mailGrounding, snapshot: mailSnapshot
		)
		check("mail_inbox_accepts_inbox_proposal",
			  mailScore >= AgenticProposalSanityFilter.rejectionThreshold)
		check("mail_grounding_allows_inbox",
			  mailGrounding.allowedDomains.contains("email") ||
			  mailGrounding.allowedDomains.contains("inbox") ||
			  mailGrounding.allowedDomains.contains("summarization"))

		let ok = failures.isEmpty
		print("[AgenticIntentGroundingSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
