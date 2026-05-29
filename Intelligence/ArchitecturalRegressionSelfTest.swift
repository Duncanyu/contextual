import Foundation

/// Deterministic unit tests to verify grounding, OCR sanitization,
/// family requirements, and dynamic goal echo suppression rules.
enum ArchitecturalRegressionSelfTest {

	static func run() -> Bool {
		print("==========================================")
		print("[ArchitecturalRegressionSelfTest] STARTED")
		print("==========================================")

		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[ArchitecturalRegressionSelfTest] FAIL: \(name)")
			} else {
				print("[ArchitecturalRegressionSelfTest] PASS: \(name)")
			}
		}

		// ----------------------------------------------------
		// Scenario 1: Reddit page + Anker tab visible must not produce product/spec evidence
		// ----------------------------------------------------
		let isStrongMixed = RouterGroundingHeuristic.isStrongActionablePageContext(
			title: "Reddit: the front page of the internet",
			appName: "Google Chrome",
			ocrExcerpt: "reddit.com hardware discussion and anker charger specs"
		)
		check("mixed_reddit_anker_no_strong_context", isStrongMixed == false)

		let ocrLines = [
			"reddit.com/r/hardware",
			"Anker Prime 140W Specs ✕",
			"New Tab"
		]
		let sanitizedOcr = OCRProcessor.sanitizeOcrLines(ocrLines)
		check("mixed_tabs_and_chrome_removed", !sanitizedOcr.contains("Anker Prime 140W Specs ✕") && !sanitizedOcr.contains("New Tab"))

		// ----------------------------------------------------
		// Scenario 2: Extract Reddit URL does not use product schema
		// ----------------------------------------------------
		let reqsForReddit = AgenticEvidenceRequirementsInferrer.infer(
			goal: "Extract Reddit URL",
			workflow: "browsing",
			windowTitle: "Post on Reddit",
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "social"
		)
		let hasProductSchema = reqsForReddit.contains { req in
			req.kind == .productTitle || req.kind == .specs || req.kind == .price || req.kind == .rating || req.kind == .comparisonCandidate
		}
		check("reddit_goal_no_product_schema", hasProductSchema == false)
		
		let hasSocialSchema = reqsForReddit.contains { req in
			req.kind == .pageUrl || req.kind == .keyPostContent
		}
		check("reddit_goal_has_social_schema", hasSocialSchema == true)

		// ----------------------------------------------------
		// Scenario 3: Recovery mode disabled for Reddit verification/profile/title-only pages
		// ----------------------------------------------------
		let isStrongProfile = RouterGroundingHeuristic.isStrongActionablePageContext(
			title: "duncanyu (u/duncanyu) - Reddit",
			appName: "Google Chrome",
			ocrExcerpt: "user profile posts comments overview"
		)
		check("reddit_profile_not_strong", isStrongProfile == false)

		let isStrongVerify = RouterGroundingHeuristic.isStrongActionablePageContext(
			title: "reddit.com/verify - Verification Required",
			appName: "Google Chrome",
			ocrExcerpt: "please log in to verify your identity"
		)
		check("reddit_verify_not_strong", isStrongVerify == false)

		let isStrongTitleOnly = RouterGroundingHeuristic.isStrongActionablePageContext(
			title: "reddit.com/r/science",
			appName: "Google Chrome",
			ocrExcerpt: "science post" // < 80 characters
		)
		check("reddit_title_only_not_strong", isStrongTitleOnly == false)

		// ----------------------------------------------------
		// Scenario 4: Exact runtime goal echo never becomes evidence
		// ----------------------------------------------------
		let support = GeneratedChromeFilter.GroundingSupport(
			windowTitle: "Extract Reddit URL",
			axText: "Extract Reddit URL",
			groundedNodeTexts: ["Extract Reddit URL"],
			semanticTexts: ["Extract Reddit URL"]
		)
		let suppressionResult = GeneratedChromeFilter.shouldSuppress(
			line: "Extract Reddit URL",
			runtimeGoal: "Extract Reddit URL",
			proposalTitle: "Extract Reddit URL",
			groundingSupport: support
		)
		check("exact_goal_echo_suppressed_completely", suppressionResult.suppressed == true && suppressionResult.reason == "runtime_goal_echo_exact")

		// ----------------------------------------------------
		// Scenario 5: Product page still allows product/schema extraction
		// ----------------------------------------------------
		let isStrongProduct = RouterGroundingHeuristic.isStrongActionablePageContext(
			title: "Anker USB C Hub, 555 USB-C Hub (8-in-1) - Amazon.com",
			appName: "Safari",
			ocrExcerpt: "Specs: 100W Power Delivery, 4K HDMI, Price: $45.99 customer reviews out of 5 stars"
		)
		check("product_page_is_strong", isStrongProduct == true)

		let reqsForProduct = AgenticEvidenceRequirementsInferrer.infer(
			goal: "Compare Anker Hubs",
			workflow: "shopping",
			windowTitle: "Anker 555 Hub Specs",
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "shopping"
		)
		let hasProductTitleAndSpecs = reqsForProduct.contains { $0.kind == .productTitle } && reqsForProduct.contains { $0.kind == .specs }
		check("product_goal_uses_product_schema", hasProductTitleAndSpecs == true)

		// ----------------------------------------------------
		// Scenario 6: Proposal visibility remains working on product page
		// ----------------------------------------------------
		let validationResult = ProposalCapabilityValidator.validate(
			title: "Compare Anker Chargers",
			goal: "Compare Anker Chargers",
			isolated: IsolatedProposalContext(
				appName: "Safari",
				bundleIdentifier: "com.apple.Safari",
				windowTitle: "Anker Prime 140W Charger specs",
				selectedText: nil,
				ocrExcerpt: "Anker Prime 140W specs 3-port charger fast charging in stock reviews",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["ocr"],
				excludedSources: []
			),
			stage: "test"
		)
		check("product_proposal_visibility_working", validationResult.accepted == true)

		// ----------------------------------------------------
		// Scenario 7: Anker product page search salvage
		// ----------------------------------------------------
		let searchCandidate = TaskInferenceEngine.PlannerCandidate(
			title: "Search Anker Laptop Charger on Amazon",
			caps: [], // empty caps
			confidence: 0.75,
			novelty: 0.5,
			requires: ["title"],
			whyUseful: "Search for a charger"
		)
		let salvagedCandidate = TaskInferenceEngine.normalizeCandidate(searchCandidate)
		check("search_salvaged_caps_not_empty", salvagedCandidate.caps == ["inspect"])
		check("search_salvaged_is_soft", salvagedCandidate.isSoftProposal == true)

		let salvagedValidation = ProposalCapabilityValidator.validate(
			title: salvagedCandidate.title,
			goal: salvagedCandidate.whyUseful ?? "",
			isolated: IsolatedProposalContext(
				appName: "Safari",
				bundleIdentifier: "com.apple.Safari",
				windowTitle: "Anker Laptop Charger specs",
				selectedText: nil,
				ocrExcerpt: "Anker Prime Specs 100W PD charger",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["title"],
				excludedSources: []
			),
			stage: "test"
		)
		check("salvaged_search_validation_accepted", salvagedValidation.accepted == true)
		check("salvaged_search_validation_is_soft", salvagedValidation.isSoftProposal == true || salvagedCandidate.isSoftProposal == true)

		let mappedExec = GeneratedExecutionProposalCandidate(
			id: "search_exec",
			title: salvagedCandidate.title,
			description: "salvaged_search",
			source: .generatedExecution,
			workflowType: .browsing,
			intentType: .explain,
			confidence: salvagedCandidate.confidence,
			interruptionCost: 0.2,
			explainabilitySummary: "salvaged",
			expectedOutputSummary: "search",
			requiredContextTypes: [.textSnippet],
			executionAction: nil,
			generatedActionId: nil,
			primitiveSignature: "search",
			isExecutableGeneratedProposal: true,
			isSoftProposal: true,
			softReasons: ["salvaged_empty_caps"]
		)
		let activResult = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [],
				generatedExecutionCandidates: [mappedExec],
				snapshot: CanonicalGeneratedExecutionContextSnapshot(
					activeApp: "Safari",
					windowTitle: "Anker Laptop Charger specs",
					bundleIdentifier: "com.apple.Safari",
					inferredWorkflow: .browsing,
					selectedText: nil,
					clipboardText: nil,
					recentOCRExcerpt: "Anker Prime Specs 100W PD charger",
					contextSummary: "",
					workflowConfidence: 0.8,
					availableContextTypes: [],
					visualContextAvailability: GeneratedExecutionVisualContextAvailability(
						hasVisualDescriptor: true,
						hasWindowSnapshot: true,
						visualSummaryExcerpt: "Anker Prime Specs 100W PD charger"
					),
					permissionAvailability: [:],
					generatedAt: Date(),
					freshnessScore: 0.9
				),
				referenceTime: Date()
			)
		)
		check("salvaged_search_surfaces_softly_in_panel", activResult.visibleProposals.contains { $0.id == "search_exec" })
		check("salvaged_search_is_blocked_from_floating", activResult.floatingGeneratedProposalId == nil)

		// ----------------------------------------------------
		// Scenario 8: OCR active title preservation
		// ----------------------------------------------------
		let rawOcrLines = ["Anker Prime Charger Specs ✕", "New Tab"]
		let preservedOcr = OCRProcessor.sanitizeOcrLines(rawOcrLines, activeTitle: "Anker Prime Charger Specs")
		check("sanitizer_preserves_overlapping_active_title", preservedOcr.contains("Anker Prime Charger Specs ✕"))
		check("sanitizer_removes_unrelated_tab_strip", !preservedOcr.contains("New Tab"))

		// ----------------------------------------------------
		// Scenario 9: Low-grounding panel-only surfacing
		// ----------------------------------------------------
		let lowGroundingValidation = ProposalCapabilityValidator.validate(
			title: "Compare Macbook Air",
			goal: "Compare Macbook Air",
			isolated: IsolatedProposalContext(
				appName: "Safari",
				bundleIdentifier: "com.apple.Safari",
				windowTitle: "Google Search",
				selectedText: nil,
				ocrExcerpt: "some random text on page",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["title"],
				excludedSources: []
			),
			stage: "test"
		)
		check("low_grounding_accepted_as_soft", lowGroundingValidation.accepted == true && lowGroundingValidation.isSoftProposal == true)

		// ----------------------------------------------------
		// Scenario 10: Unsafe proposal hard blocked
		// ----------------------------------------------------
		let buyValidation = ProposalCapabilityValidator.validate(
			title: "Buy Anker USB C Hub",
			goal: "Buy Anker USB C Hub",
			isolated: IsolatedProposalContext(
				appName: "Safari",
				bundleIdentifier: "com.apple.Safari",
				windowTitle: "Anker 555 Hub Specs",
				selectedText: nil,
				ocrExcerpt: "Specs: 100W Power Delivery",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["title"],
				excludedSources: []
			),
			stage: "test"
		)
		check("unsafe_buy_is_hard_blocked", buyValidation.accepted == false)

		let deleteValidation = ProposalCapabilityValidator.validate(
			title: "Delete this file",
			goal: "Delete this file",
			isolated: IsolatedProposalContext(
				appName: "Finder",
				bundleIdentifier: "com.apple.finder",
				windowTitle: "Documents",
				selectedText: nil,
				ocrExcerpt: "some file name",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["title"],
				excludedSources: []
			),
			stage: "test"
		)
		check("unsafe_delete_is_hard_blocked", deleteValidation.accepted == false)

		// ----------------------------------------------------
		// Scenario 11: Reddit permissive recovery
		// ----------------------------------------------------
		let isRedditStrong = RouterGroundingHeuristic.isStrongActionablePageContext(
			title: "Interesting hardware post on reddit.com",
			appName: "Google Chrome",
			ocrExcerpt: "Check out this new charger spec post on reddit"
		)
		check("reddit_post_page_with_ocr_is_strong", isRedditStrong == true)

		let redditUrlReqs = AgenticEvidenceRequirementsInferrer.infer(
			goal: "Summarize Reddit post",
			workflow: "browsing",
			windowTitle: "Reddit post about tech",
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "social"
		)
		let redditUsesProductSchema = redditUrlReqs.contains { $0.kind == .productTitle || $0.kind == .specs }
		check("reddit_summarize_does_not_use_product_schema", redditUsesProductSchema == false)

		// ----------------------------------------------------
		// Scenario 12: Amazon page + planner title "Review Active Permissions" => rejected by PromptLeakFilter
		// ----------------------------------------------------
		let leakValidation = ProposalCapabilityValidator.validate(
			title: "Review Active Permissions",
			goal: "Review active permissions for this page",
			isolated: IsolatedProposalContext(
				appName: "Safari",
				bundleIdentifier: "com.apple.Safari",
				windowTitle: "Amazon.com: Anker Prime USB C Charger",
				selectedText: nil,
				ocrExcerpt: "Anker Prime 100W PD charger Specs",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["title"],
				excludedSources: []
			),
			stage: "test"
		)
		check("leak_permissions_is_rejected_by_prompt_leak_filter", leakValidation.accepted == false && leakValidation.reason == "internal_term_not_grounded")

		// ----------------------------------------------------
		// Scenario 13: Product page + "Extract product details" => allowed
		// ----------------------------------------------------
		let extractValidation = ProposalCapabilityValidator.validate(
			title: "Extract product details",
			goal: "Extract details for Anker charger",
			isolated: IsolatedProposalContext(
				appName: "Safari",
				bundleIdentifier: "com.apple.Safari",
				windowTitle: "Anker prime specs on Amazon",
				selectedText: nil,
				ocrExcerpt: "Anker Prime 100W specs 3-port charger",
				axExcerpt: nil,
				recentChanges: nil,
				includedSources: ["title"],
				excludedSources: []
			),
			stage: "test"
		)
		check("extract_product_details_allowed_on_product_page", extractValidation.accepted == true)

		// ----------------------------------------------------
		// Scenario 14: Product page + generic "Inspect page" => forces observe_once first, then infers product schema
		// ----------------------------------------------------
		let genericGoal = "Inspect page"
		let isAmbiguous = AgenticDecider.isAmbiguousOrSoftGoal(genericGoal)
		check("inspect_page_is_identified_as_ambiguous", isAmbiguous == true)

		let initialReqs = AgenticEvidenceRequirementsInferrer.infer(
			goal: genericGoal,
			workflow: "browsing",
			windowTitle: nil, // no window title yet
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: nil
		)
		let initialUsesProductSchema = initialReqs.contains { $0.kind == .productTitle || $0.kind == .specs }
		check("inspect_page_initially_does_not_use_product_schema", initialUsesProductSchema == false)

		// Simulating observe_once refreshes context to show a product page
		let refreshedReqs = AgenticEvidenceRequirementsInferrer.infer(
			goal: genericGoal,
			workflow: "browsing",
			windowTitle: "Anker Prime Specs on Amazon.com",
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "shopping"
		)
		let refreshedUsesProductSchema = refreshedReqs.contains { $0.kind == .productTitle || $0.kind == .specs }
		check("inspect_page_after_observe_once_infers_product_schema", refreshedUsesProductSchema == true)

		// ----------------------------------------------------
		// Scenario 15: Generic "review permissions" does not map to product_detail
		// ----------------------------------------------------
		let permissionsReqs = AgenticEvidenceRequirementsInferrer.infer(
			goal: "Review permissions",
			workflow: "browsing",
			windowTitle: "Settings",
			evidenceObservations: [],
			semanticEntities: [],
			contextCategory: "settings"
		)
		let permissionsUsesProductSchema = permissionsReqs.contains { $0.kind == .productTitle || $0.kind == .specs }
		check("review_permissions_does_not_use_product_schema", permissionsUsesProductSchema == false)
		
		let permissionsUsesSummarySchema = permissionsReqs.contains { $0.kind == .pageSummary || $0.kind == .documentKeyPoint }
		check("review_permissions_uses_generic_summary_schema", permissionsUsesSummarySchema == true)

		// ----------------------------------------------------
		// Scenario 16: Visual Grounding integration
		// ----------------------------------------------------
		// 1. Verify coordinate parsing works robustly on various VLM responses
		let parsed1 = VisualGrounder.parseCoordinates(from: "[120, 230, 340, 450]")
		check("visual_grounder_parses_bracketed_coords", parsed1?.x1 == 120 && parsed1?.y1 == 230 && parsed1?.x2 == 340 && parsed1?.y2 == 450)
		
		let parsed2 = VisualGrounder.parseCoordinates(from: "The region is 150, 250, 300, 400. No explanation.")
		check("visual_grounder_parses_comma_separated_coords", parsed2?.x1 == 150 && parsed2?.y1 == 250 && parsed2?.x2 == 300 && parsed2?.y2 == 400)
		
		// 2. Verify auto-scaling mapping logic to actual screen points
		let scale1 = VisualGrounder.resolveNormalizedCenter(numbers: (150, 200, 350, 300), imgWidth: 2000, imgHeight: 1000)
		// Max value is 350 <= 1000, so grid is 1000x1000
		// cx = (150 + 350)/2 = 250 -> 250 / 1000 * 2000 = 500
		// cy = (200 + 300)/2 = 250 -> 250 / 1000 * 1000 = 250
		check("visual_grounder_auto_scales_1000_grid", scale1.x == 500 && scale1.y == 250)
		
		let scale2 = VisualGrounder.resolveNormalizedCenter(numbers: (15, 20, 35, 30), imgWidth: 2000, imgHeight: 1000)
		// Max value is 35 <= 100, so grid is 100x100
		// cx = (15 + 35)/2 = 25 -> 25 / 100 * 2000 = 500
		// cy = (20 + 30)/2 = 25 -> 25 / 100 * 1000 = 250
		check("visual_grounder_auto_scales_100_grid", scale2.x == 500 && scale2.y == 250)

		// ----------------------------------------------------
		// Scenario 17: ActionableUIAnalyzer, ExplorationMemory, and AnswerReadinessGate Integration
		// ----------------------------------------------------
		let analysisTest = ActionableUIAnalyzer.analyze(
			ocr: "Install Chrome now\nClick to continue reading specs\nUnrelated static text",
			contextSummary: "AXButton: Sign in\nAXTextField: Search Google",
			vlmCaption: "There is an Install button and a Search text field.",
			goal: "Navigate and Install Chrome"
		)
		check("actionable_ui_analyzer_detects_install", analysisTest.actionableControls.contains { $0.label.contains("Install") })
		check("actionable_ui_analyzer_detects_continue", analysisTest.actionableControls.contains { $0.label.contains("continue") })
		check("actionable_ui_analyzer_detects_signin", analysisTest.actionableControls.contains { $0.label == "Sign in" })
		check("actionable_ui_analyzer_detects_search", analysisTest.actionableControls.contains { $0.label == "Search Google" })
		check("actionable_ui_analyzer_score_is_positive", analysisTest.explorationScore > 0.0)

		// Verification of AnswerReadinessGate
		let gateBlock = AnswerReadinessGate.shouldAllowAnswer(
			interactionAttempts: 0,
			explorationScore: analysisTest.explorationScore,
			unexploredActionableControlsCount: analysisTest.actionableControls.count,
			hasUnexploredScroll: true
		)
		check("answer_gate_blocks_when_no_interactions_and_controls_exist", gateBlock.allowed == false && gateBlock.reason == "interaction_required")

		let gateAllow = AnswerReadinessGate.shouldAllowAnswer(
			interactionAttempts: 1,
			explorationScore: analysisTest.explorationScore,
			unexploredActionableControlsCount: 0,
			hasUnexploredScroll: false
		)
		check("answer_gate_allows_when_sufficient_exploration", gateAllow.allowed == true && gateAllow.reason == "sufficient_exploration")

		// Verification of ExplorationMemory
		var memory = ExplorationMemory()
		memory.recordObserve(windowTitle: "Browser", textHash: "hash1")
		memory.recordObserve(windowTitle: "Browser", textHash: "hash1")
		memory.recordObserve(windowTitle: "Browser", textHash: "hash1")
		check("exploration_memory_detects_observe_loop", memory.isStuckInObserveLoop() == true)

		memory.recordClick(label: "Install", x: 100, y: 200)
		check("exploration_memory_clears_observe_loop_after_click", memory.isStuckInObserveLoop() == false)
		check("exploration_memory_tracks_click_label", memory.hasClicked("Install") == true)

		let ok = failures.isEmpty
		let detail = failures.joined(separator: "; ")
		print("==========================================")
		print("[ArchitecturalRegressionSelfTest] COMPLETED ok=\(ok) failures=\(failures.count) detail=\(detail)")
		print("==========================================")
		return ok
	}
}
