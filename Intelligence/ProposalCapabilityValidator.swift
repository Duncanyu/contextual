import Foundation

/// Pure validation and safety layer for capability-constrained proposal generation.
/// Enforces limits, safety rules, and literal scans, completely rejecting invalid proposals instead of rewriting.
enum ProposalCapabilityValidator {

	struct ValidationResult: Sendable, Equatable {
		let accepted: Bool
		let reason: String
		let diagnosticTag: String?
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

		// Phase 4S — Helpfulness gate: the title must indicate an assistant action intent,
		// not just echo an entity/window title.
		let actionIntent = hasActionIntent(lower)
		print("[ProposalHelpfulness] action_intent_detected=\(actionIntent ? "yes" : "no") stage=\(stage)")

		// Phase 4S — Reject raw-title proposals (title equals the context entity/window title)
		// when no action intent is present. Prevents the "fast visibility" path from
		// surfacing copied window titles as executable actions.
		if !actionIntent, isEffectivelyContextTitle(lower, isolated: isolated) {
			print("[ProposalValidation] rejected stage=\(stage) reason=non_action_title title_equals_context_entity=yes title=\"\(title)\"")
			return ValidationResult(accepted: false, reason: "non_action_title", diagnosticTag: "diag:non_action_title")
		}

		// Titles that are not action-like should not surface, even if grounded.
		if !actionIntent {
			print("[ProposalValidation] rejected stage=\(stage) reason=non_action_title action_intent_detected=no title=\"\(title)\"")
			return ValidationResult(accepted: false, reason: "non_action_title", diagnosticTag: "diag:non_action_title")
		}

		// 1. Literal scans for generic template strings.
		let cannedPhrases = [
			"review visible",
			"analyze visible",
			"review product",
			"analyze code",
			"inspect content",
			"compare visible"
		]
		for phrase in cannedPhrases {
			if lower.contains(phrase) {
				print("[ProposalValidation] rejected stage=\(stage) reason=generic_semantic_template title=\"\(title)\" matched=\"\(phrase)\"")
				return ValidationResult(accepted: false, reason: "generic_semantic_template", diagnosticTag: "diag:generic_semantic_template")
			}
		}

		// 2. Safety verb prefix scans.
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

		// 2b. Phase 4Q — substring scans for unsafe verbs/nouns that appear
		// anywhere in the title (not just as a prefix). Catches LLM outputs like
		// "Add Anker Prime to Wishlist" or "Save Charger to Wishlist".
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

		// 3b. Phase 4R — Context family mismatch guard.
		// Prevent profile/settings/account proposals from surfacing when the active grounded
		// context does not support that family (e.g. transient profile-name titles in a browser
		// session replacing a strong product/article context).
		let familyNeedles = ["profile", "settings", "account", "edit profile"]
		if familyNeedles.contains(where: { lower.contains($0) }) {
			let ctxLower = isolated.groundingText.lowercased()
			let ctxHasFamily = familyNeedles.contains(where: { ctxLower.contains($0) })
			if !ctxHasFamily {
				print("[ProposalValidation] rejected stage=\(stage) reason=context_family_mismatch title=\"\(title)\"")
				return ValidationResult(accepted: false, reason: "context_family_mismatch", diagnosticTag: "diag:context_family_mismatch")
			}
		}

		// 4. Phase 4P — Stale-context-entity rejection (dev-artifact branch only).
		// Reject titles whose dev/file artifact tokens (.md, .swift, AppDelegate,
		// implementation_plan, etc.) are not present in the isolated active
		// context. Catches "Review AGENTS.md File" when the user is in Firefox.
		//
		// Pure zero-overlap (no dev artifact, but no overlap either) intentionally
		// falls through to the legacy `low_grounding` rule below so existing tests
		// and dogfood reasoning stay aligned on a single reason for unrelated text.
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

		// 5. Grounding verification — preserved as defense-in-depth.
		let contextWords = substantiveWords(from: isolated.groundingText)
		if contextWords.count >= 2 {
			let titleWords = substantiveWords(from: lower)
			if !titleWords.isEmpty && titleWords.isDisjoint(with: contextWords) {
				print("[ProposalValidation] rejected stage=\(stage) reason=low_grounding title=\"\(title)\" context_overlap=none")
				return ValidationResult(accepted: false, reason: "low_grounding", diagnosticTag: "diag:low_grounding")
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
		// Validation only (not generation): ensure the title implies a concrete assistant action.
		// This intentionally uses a small allowlist of verb families.
		let verbs = [
			"inspect", "extract", "summarize", "compare", "identify",
			"gather", "explain", "review", "analyze", "understand",
			// Synonyms that map to the same intent families:
			"find", "list", "check", "trace", "diagnose", "organize", "outline",
			// Unsafe/unsupported verbs to allow safety check triggers:
			"purchase", "buy", "delete", "checkout", "install", "login", "order"
		]
		for v in verbs {
			if lowerTitle.hasPrefix(v + " ") { return true }
			if lowerTitle.contains(" " + v + " ") { return true }
		}
		return false
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
