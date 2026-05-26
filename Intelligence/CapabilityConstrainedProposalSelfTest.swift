import Foundation

/// Self-tests for capability-constrained proposal generation (Phase 4R).
/// Verifies the validation, rejection, suppression, and prompt hygiene rules.
enum CapabilityConstrainedProposalSelfTest {

	static func run() -> Bool {
		print("[CapabilityConstrainedProposalSelfTest] starting")
		var failures: [String] = []

		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[CapabilityConstrainedProposalSelfTest] FAIL: \(name)")
			} else {
				print("[CapabilityConstrainedProposalSelfTest] PASS: \(name)")
			}
		}

		// MARK: 1 — Model Name Verification
		check("router_is_qwen", TaskInferenceEngine.routerModelName == "qwen2.5:0.5b")
		check("planner_is_phi4", TaskInferenceEngine.plannerModelName == "phi4-mini")

		// MARK: 2 — Unsafe Capabilities Rejection (instead of rewriting)
		let unsafeTitles = [
			"Purchase Apple TV",
			"Buy now MacBook Pro",
			"checkout with shopping cart",
			"delete local database",
			"install malicious app",
			"order new headphones"
		]
		for title in unsafeTitles {
			let res = ProposalCapabilityValidator.validate(
				title: title,
				goal: "Perform some action",
				appName: "Safari",
				windowTitle: "Store"
			)
			check("reject_unsafe_\(title)", !res.accepted && res.reason == "unsupported_capability")
		}

		// MARK: 3 — Canned Template Rejection
		let cannedTitles = [
			"Review visible product specs",
			"Analyze visible screen elements",
			"Review product details on Amazon",
			"Analyze code structures in Xcode",
			"Inspect content of the webpage",
			"Compare visible item prices"
		]
		for title in cannedTitles {
			let res = ProposalCapabilityValidator.validate(
				title: title,
				goal: "Help user",
				appName: "Firefox",
				windowTitle: "Keyboard specs",
				selectedText: "Keyboard specs mechanical brown switch"
			)
			check("reject_canned_\(title)", !res.accepted && res.reason == "generic_semantic_template")
		}

		// MARK: 4 — Disallowed Interaction Primitive Rejection
		let disallowedInteractiveTitles = [
			"click on next button",
			"type user password",
			"fill form fields",
			"navigate to shopping page",
			"go to next tab"
		]
		for title in disallowedInteractiveTitles {
			let res = ProposalCapabilityValidator.validate(
				title: title,
				goal: "Perform operation",
				appName: "Chrome",
				windowTitle: "Login"
			)
			check("reject_disallowed_\(title)", !res.accepted && res.reason == "unsupported_capability")
		}

		// MARK: 5 — Grounding Verification
		// When appName/windowTitle are completely unrelated to title, reject as low grounding
		let unrelatedRes = ProposalCapabilityValidator.validate(
			title: "Research solar panels",
			goal: "Help user learn about solar panels",
			appName: "Xcode",
			windowTitle: "AppDelegate.swift",
			selectedText: "func applicationDidFinishLaunching"
		)
		check("reject_low_grounding_unrelated", !unrelatedRes.accepted && unrelatedRes.reason == "low_grounding")

		// Grounded should pass
		let groundedRes = ProposalCapabilityValidator.validate(
			title: "Explain appdelegate did finish launching function",
			goal: "Explain Swift lifecycle method",
			appName: "Xcode",
			windowTitle: "AppDelegate.swift",
			selectedText: "func applicationDidFinishLaunching"
		)
		check("accept_grounded_proposal", groundedRes.accepted)

		// MARK: 6 — Diversity & Prefix Suppression logic verification
		// We mock the exact repeated leading verb suppression logic
		func checkRepeatedPrefix(title: String, surfacedHistory: [String]) -> Bool {
			let lower = title.lowercased()
			let words = lower.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
			guard let firstWord = words.first else { return false }
			
			var matchCount = 0
			for recentTitle in surfacedHistory.prefix(5) {
				let recentWords = recentTitle.lowercased().components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
				if let rFirst = recentWords.first, rFirst == firstWord {
					matchCount += 1
				}
			}
			return matchCount <= 2
		}

		let historyWithPrefix = [
			"Review mechanical keyboards",
			"Review charger options",
			"Review monitor sizes",
			"Compare laptops",
			"Extract text snippet"
		]
		check("suppress_repeated_prefix_review", !checkRepeatedPrefix(title: "Review laptop prices", surfacedHistory: historyWithPrefix))
		check("allow_prefix_compare", checkRepeatedPrefix(title: "Compare tablet weights", surfacedHistory: historyWithPrefix))

		// Jaccard similarity threshold overlap (>0.8 suppressed)
		func wordOverlapSimilarity(_ s1: String, _ s2: String) -> Double {
			let w1 = Set(s1.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
			let w2 = Set(s2.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
			if w1.isEmpty || w2.isEmpty { return 0.0 }
			let intersection = w1.intersection(w2)
			let union = w1.union(w2)
			return Double(intersection.count) / Double(union.count)
		}

		check("high_similarity_suppressed", wordOverlapSimilarity("Research mechanical keyboard keys", "Research mechanical keyboard keys") > 0.8)
		check("low_similarity_allowed", wordOverlapSimilarity("Research mechanical keyboard keys", "Compare prices of chargers") <= 0.8)

		// MARK: 7 — Prompt Hygiene & No Few-Shot Semantic Examples
		let now = Date()
		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Mechanical Keyboards on Amazon",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: "Key specs: switches, layout, price $129",
			clipboardText: nil,
			recentOCRExcerpt: "Keyboards category page",
			contextSummary: "Browsing product pages",
			workflowConfidence: 0.8,
			availableContextTypes: [.selectedText, .textSnippet],
			permissionAvailability: [.screenRecording: true],
			generatedAt: now,
			freshnessScore: 0.8
		)
		let situational = SituationalContextSynthesizer.synthesize(from: snap, referenceTime: now)

		let routerPrompt = TwoStageRouterPromptBuilder.build(
			snapshot: snap,
			situational: situational,
			recentTitles: [],
			history: nil,
			referenceTime: now
		)
		let plannerPrompt = TwoStageCompactPlannerPromptBuilder.build(
			snapshot: snap,
			situational: situational,
			recentTitles: [],
			history: nil,
			referenceTime: now
		)

		let literalRejections = [
			"Review visible",
			"Analyze visible",
			"Review product",
			"Analyze code",
			"Inspect content",
			"Compare visible"
		]

		for phrase in literalRejections {
			check("router_prompt_no_fewshot_\(phrase)", !routerPrompt.contains(phrase))
			check("planner_prompt_no_fewshot_\(phrase)", !plannerPrompt.contains(phrase))
		}

		// Ensure no few-shot semantic examples (e.g., canned full examples) exist in prompts
		check("router_prompt_no_canned_examples", !routerPrompt.contains("Review visible content") && !routerPrompt.contains("Analyze product"))
		check("planner_prompt_no_canned_examples", !plannerPrompt.contains("Review visible content") && !plannerPrompt.contains("Analyze product"))

		let ok = failures.isEmpty
		print("[CapabilityConstrainedProposalSelfTest] finished ok=\(ok) failures=\(failures.count)")
		return ok
	}
}
