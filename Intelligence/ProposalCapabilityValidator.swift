import Foundation

/// Pure validation and safety layer for capability-constrained proposal generation.
/// Enforces limits, safety rules, and literal scans, completely rejecting invalid proposals instead of rewriting.
enum ProposalCapabilityValidator {

	struct ValidationResult: Sendable, Equatable {
		let accepted: Bool
		let reason: String
		let diagnosticTag: String?
		var isSoftProposal: Bool = false
		var softReasons: [String] = []

		init(accepted: Bool, reason: String, diagnosticTag: String?, isSoftProposal: Bool = false, softReasons: [String] = []) {
			self.accepted = accepted
			self.reason = reason
			self.diagnosticTag = diagnosticTag
			self.isSoftProposal = isSoftProposal
			self.softReasons = softReasons
		}
	}

	/// Checks if a proposed title, goal, or candidate actions are safe, grounded, and within capability bounds.
	///
	/// Legacy entry point. Internally wraps the inputs in an `IsolatedProposalContext`
	/// so all paths share the same grounding / stale-entity rules.
	static func validate(
		title: String,
		goal: String,
		appName: String,
		windowTitle: String,
		selectedText: String? = nil,
		ocrExcerpt: String? = nil,
		allowedPrimitives: Set<ExecutionPrimitive> = [.summarizeContext, .explainError, .extractActionItems, .organizeInformation, .synthesizeResearchSummary, .structureNotes, .classifyWorkflow, .answerFromContext]
	) -> ValidationResult {
		let isolated = IsolatedProposalContext(
			appName: appName,
			bundleIdentifier: nil,
			windowTitle: windowTitle,
			selectedText: selectedText,
			ocrExcerpt: ocrExcerpt,
			axExcerpt: nil,
			recentChanges: nil,
			includedSources: ["window_title"],
			excludedSources: []
		)
		return validate(title: title, goal: goal, isolated: isolated, stage: "legacy", allowedPrimitives: allowedPrimitives)
	}

	/// Phase 4P primary entry point. Validates against an `IsolatedProposalContext`
	/// that the caller already screened for clipboard / dev / log leaks. `stage` is
	/// emitted in every log line so dogfood can distinguish early vs activation
	/// rejection — and the SAME rules fire at both stages, eliminating the
	/// "accepted at early, rejected at activation" inconsistency.
	static func validate(
		title: String,
		goal: String,
		isolated: IsolatedProposalContext,
		stage: String,
		allowedPrimitives: Set<ExecutionPrimitive> = [.summarizeContext, .explainError, .extractActionItems, .organizeInformation, .synthesizeResearchSummary, .structureNotes, .classifyWorkflow, .answerFromContext]
	) -> ValidationResult {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			print("[ProposalValidation] rejected stage=\(stage) reason=empty_title")
			return ValidationResult(accepted: false, reason: "empty_title", diagnosticTag: "diag:empty_title")
		}

		let lower = trimmed.lowercased()

		// Dev vocabulary block on product shopping pages
		let appLower = isolated.appName.lowercased()
		let bundleLower = (isolated.bundleIdentifier ?? "").lowercased()
		let titleLower = isolated.windowTitle.lowercased()
		
		let isIDE = bundleLower.contains("xcode") || appLower.contains("xcode") ||
		            bundleLower.contains("vscode") || bundleLower.contains("terminal") ||
		            appLower.contains("terminal") || appLower.contains("vs code") ||
		            appLower.contains("intellij") || bundleLower.contains("intellij")
		let isDevContext = isIDE || titleLower.contains(".swift") || titleLower.contains(".py") ||
		                   titleLower.contains(".rs") || titleLower.contains(".go") ||
		                   titleLower.contains(".js") || titleLower.contains(".ts") ||
		                   titleLower.contains(".json") || titleLower.contains("codebase") ||
		                   titleLower.contains("repository")
		
		let allContextText = "\(isolated.appName) \(isolated.windowTitle) \(isolated.ocrExcerpt ?? "") \(isolated.selectedText ?? "") \(isolated.axExcerpt ?? "")".lowercased()
		
		let shoppingPlatformKeys = ["amazon", "bestbuy", "best buy", "newegg", "ebay",
		                            "walmart", "target", "etsy", "shopify", "apple store"]
		let isShoppingPlatform = shoppingPlatformKeys.contains {
			bundleLower.contains($0) || appLower.contains($0) || titleLower.contains($0)
		}
		
		let productSignals = [
			"add to cart", "buy now", "in stock", "sold by", "free shipping",
			"customer reviews", "verified purchase", "return policy", "model number",
			"ships free", "compatible with", "compare models", "warranty included",
			"price:", "list price", "sale price"
		]
		let hasPricePattern = allContextText.range(
			of: #"\$\d"#, options: .regularExpression
		) != nil
		let hasProductSignal = productSignals.contains { allContextText.contains($0) }
		let isProductPage = isShoppingPlatform || hasProductSignal || hasPricePattern
		let isShopping = isShoppingPlatform || isProductPage
		
		if isShopping && !isDevContext {
			let proposalText = "\(title) \(goal)".lowercased()
			let forbiddenTerms = [
				"build plan", "repository", "codebase", "implementation",
				"self-test", "commit", "file", "source", "version compatibility"
			]
			for term in forbiddenTerms {
				if proposalText.contains(term) {
					print("[ProposalValidation] rejected reason=dev_vocabulary_on_product_page title=\"\(title)\"")
					return ValidationResult(accepted: false, reason: "dev_vocabulary_on_product_page", diagnosticTag: "diag:dev_vocabulary_on_product_page")
				}
			}
		}

		// PromptLeakFilter: Reject titles containing internal/tooling terms when page context does not support them
		let leakTerms = [
			"active permissions", "permissions", "capability", "router", "prompt", "planner",
			"system", "context pipeline", "agents", "appdelegate", "xcode"
		]
		for term in leakTerms {
			if lower.contains(term) {
				let contextLower = isolated.groundingText.lowercased()
				if !contextLower.contains(term) {
					print("[PromptLeakFilter] rejected title=\"\(title)\" reason=internal_term_not_grounded")
					return ValidationResult(accepted: false, reason: "internal_term_not_grounded", diagnosticTag: "diag:internal_term_not_grounded")
				}
			}
		}

		// Reject raw-title / duplicates of context window title (raw chrome/duplicates)
		if isEffectivelyContextTitle(lower, isolated: isolated) {
			print("[ProposalValidation] rejected stage=\(stage) reason=non_action_title title_equals_context_entity=yes title=\"\(title)\"")
			return ValidationResult(accepted: false, reason: "non_action_title", diagnosticTag: "diag:non_action_title")
		}

		// 2. Safety verb prefix scans (unsafe/destructive check).
		let unsafePrefixes = [
			"purchase ", "buy now ", "buy ", "checkout ", "add to cart ", "add to wishlist ",
			"order ", "submit ", "login ", "log in ", "delete ", "close app ", "install "
		]
		for prefix in unsafePrefixes {
			if lower.hasPrefix(prefix) {
				print("[ProposalValidation] rejected stage=\(stage) reason=unsafe_capability title=\"\(title)\" matched_unsafe_prefix=\"\(prefix)\"")
				return ValidationResult(accepted: false, reason: "unsupported_capability", diagnosticTag: "diag:unsupported_capability")
			}
		}

		// 2b. Phase 4Q — substring scans for unsafe verbs/nouns
		let unsafeSubstrings = [
			"wishlist", "wish list",
		]
		for substr in unsafeSubstrings {
			if lower.contains(substr) {
				print("[ProposalValidation] rejected stage=\(stage) reason=unsafe_capability title=\"\(title)\" matched_unsafe_substring=\"\(substr)\"")
				return ValidationResult(accepted: false, reason: "unsupported_capability", diagnosticTag: "diag:unsupported_capability")
			}
		}

		// Download verb check
		if lower.hasPrefix("download ") {
			let isSafeInfo = lower.contains("info") || lower.contains("summary") || lower.contains("details") || lower.contains("pdf") || lower.contains("text") || lower.contains("file")
			if !isSafeInfo {
				print("[ProposalValidation] rejected stage=\(stage) reason=unsafe_capability title=\"\(title)\" matched_unsafe_download=yes")
				return ValidationResult(accepted: false, reason: "unsupported_capability", diagnosticTag: "diag:unsupported_capability")
			}
		}

		// 3. Disallowed interaction primitive scans in the title.
		let disallowedActions = [
			"click ", "click on ", "type ", "press ", "navigate to ", "go to ",
			"fill form ", "enter password ", "log into ", "sign in ", "close window "
		]
		for action in disallowedActions {
			if lower.contains(action) {
				print("[ProposalValidation] rejected stage=\(stage) reason=unsupported_capability title=\"\(title)\" matched_action=\"\(action)\"")
				return ValidationResult(accepted: false, reason: "unsupported_capability", diagnosticTag: "diag:unsupported_capability")
			}
		}

		// 4. Phase 4P — Stale-context-entity rejection (stale context check).
		if let staleReason = ProposalContextIsolationGate.staleContextEntityReason(
			title: title,
			isolated: isolated
		), staleReason == "dev_artifact_not_in_active_context" {
			let overlap = ProposalContextIsolationGate.contentTokens(in: lower)
				.intersection(ProposalContextIsolationGate.contentTokens(in: isolated.groundingText.lowercased()))
			let pct = isolated.hasAnyContent ? Double(overlap.count) : 0.0
			print("[ProposalValidation] rejected stage=\(stage) reason=stale_context_entity title=\"\(title)\" detail=\(staleReason)")
			print("[ProposalValidation] active_context_overlap=\(String(format: "%.2f", pct))")
			return ValidationResult(accepted: false, reason: "stale_context_entity", diagnosticTag: "diag:stale_context_entity")
		}

		let bodyText = ((isolated.ocrExcerpt ?? "") + " " + (isolated.selectedText ?? "") + " " + (isolated.axExcerpt ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
		if !bodyText.isEmpty {
			let bodyWords = substantiveWords(from: bodyText)
			let titleAndGoalWords = substantiveWords(from: lower + " " + goal.lowercased())
			if !titleAndGoalWords.isEmpty && titleAndGoalWords.isDisjoint(with: bodyWords) {
				print("[ProposalValidation] soft_warning stage=\(stage) reason=low_grounding title=\"\(title)\" ocr_body_overlap=none")
				return ValidationResult(accepted: true, reason: "low_grounding", diagnosticTag: "diag:low_grounding", isSoftProposal: true, softReasons: ["low_grounding"])
			}
		}

		// 5. Grounding verification — preserved as defense-in-depth.
		let contextWords = substantiveWords(from: isolated.groundingText)
		if contextWords.count >= 2 {
			let titleWords = substantiveWords(from: lower)
			if !titleWords.isEmpty && titleWords.isDisjoint(with: contextWords) {
				print("[ProposalValidation] soft_warning stage=\(stage) reason=low_grounding title=\"\(title)\" context_overlap=none")
				return ValidationResult(accepted: true, reason: "low_grounding", diagnosticTag: "diag:low_grounding", isSoftProposal: true, softReasons: ["low_grounding"])
			}
		}

		print("[ProposalValidation] accepted=yes stage=\(stage) reason=valid_grounded title=\"\(title)\"")
		return ValidationResult(accepted: true, reason: "valid_grounded", diagnosticTag: nil)
	}

	private static func substantiveWords(from text: String) -> Set<String> {
		let stopwords: Set<String> = [
			"this", "that", "with", "from", "have", "will", "your", "what", "want",
			"page", "here", "help", "more", "like", "just", "them", "they", "when",
			"some", "about", "which", "their", "there", "these", "those", "been",
			"said", "does", "make", "into", "than", "then", "time", "only", "also",
			"details", "context", "summary", "visible", "content", "specifications",
			"ratings", "specs", "smart", "review", "analyze", "inspect", "compare"
		]
		let words = text.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { $0.count >= 3 }
			.filter { !stopwords.contains($0) }
		return Set(words)
	}

	// MARK: - Phase 4S helpers (intent + raw-title suppression)

	private static func hasActionIntent(_ lowerTitle: String) -> Bool {
		return true
	}

	private static func isEffectivelyContextTitle(_ lowerTitle: String, isolated: IsolatedProposalContext) -> Bool {
		let ctxTitle = normalizeComparableTitle(isolated.windowTitle)
		let t = normalizeComparableTitle(lowerTitle)
		guard !t.isEmpty, !ctxTitle.isEmpty else { return false }
		if t == ctxTitle { return true }
		// Allow small suffix/prefix differences (" - amazon", " | firefox"), but still treat
		// as a raw-title echo when nearly identical.
		if ctxTitle.contains(t) && t.count >= max(12, ctxTitle.count / 2) { return true }
		if t.contains(ctxTitle) && ctxTitle.count >= max(12, t.count / 2) { return true }
		return false
	}

	private static func normalizeComparableTitle(_ input: String) -> String {
		let lower = input.lowercased()
		let stripped = lower.replacingOccurrences(of: #"[\|\-–—•·]+"#, with: " ", options: .regularExpression)
		let collapsed = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		// Drop generic trailing store/app segments after a separator-like token.
		return collapsed
	}
}
