import Foundation

// MARK: - Policy Context

/// All inputs the control policy needs to make a safety decision.
struct AgenticControlPolicyContext: Sendable {
	/// The action being evaluated.
	let action: AgenticNextAction
	/// Active app bundle identifier (from snapshot).
	let bundleIdentifier: String?
	/// Window title at decision time.
	let windowTitle: String
	/// Active app name.
	let activeApp: String
	/// Workflow type from the plan.
	let workflow: String
	/// Current step index in the loop.
	let stepIndex: Int
	/// Maximum steps for the loop.
	let maxSteps: Int
	/// Actions executed so far this session.
	let priorActions: [String]
	/// Scroll actions already used this session.
	let scrollsUsed: Int
	/// Find-on-page actions already used this session.
	let findsUsed: Int
	/// OCR calls already used this session (perception budget proxy).
	let ocrCallsUsed: Int
	/// OCR call budget for this plan (perception budget proxy).
	let ocrCallsBudget: Int
	/// Per-session scroll cap.
	let maxScrolls: Int
	/// Per-session find-on-page cap.
	let maxFinds: Int
	/// If true, no real OS events will be posted (test/preview mode).
	let dryRun: Bool
	// MARK: - Phase 4M: Execution-focus guard
	/// Expected frontmost bundle for this proposal (from `TargetWindowAnchor`).
	/// When nil, the focus guard is inactive (legacy behavior).
	let expectedTargetBundle: String?
	/// Actual frontmost bundle observed by the runtime immediately before scoring this action.
	/// When nil, the focus guard is inactive (legacy behavior).
	let currentFrontmostBundle: String?

	init(
		action: AgenticNextAction,
		bundleIdentifier: String?,
		windowTitle: String,
		activeApp: String,
		workflow: String,
		stepIndex: Int,
		maxSteps: Int,
		priorActions: [String],
		scrollsUsed: Int,
		findsUsed: Int,
		ocrCallsUsed: Int,
		ocrCallsBudget: Int,
		maxScrolls: Int,
		maxFinds: Int,
		dryRun: Bool,
		expectedTargetBundle: String? = nil,
		currentFrontmostBundle: String? = nil
	) {
		self.action = action
		self.bundleIdentifier = bundleIdentifier
		self.windowTitle = windowTitle
		self.activeApp = activeApp
		self.workflow = workflow
		self.stepIndex = stepIndex
		self.maxSteps = maxSteps
		self.priorActions = priorActions
		self.scrollsUsed = scrollsUsed
		self.findsUsed = findsUsed
		self.ocrCallsUsed = ocrCallsUsed
		self.ocrCallsBudget = ocrCallsBudget
		self.maxScrolls = maxScrolls
		self.maxFinds = maxFinds
		self.dryRun = dryRun
		self.expectedTargetBundle = expectedTargetBundle
		self.currentFrontmostBundle = currentFrontmostBundle
	}
}

// MARK: - Policy Result

struct AgenticControlPolicyResult: Sendable {
	let allowed: Bool
	let reason: String
	/// Deterministic find query to use; non-nil only when `action == .find_on_page`.
	let findQuery: String?
}

// MARK: - Policy

/// Deterministic safety policy for Phase 4D controlled actions.
///
/// Guards `scroll_small` and `find_on_page` against:
///   - High-risk page contexts (login, checkout, banking, medical, government)
///   - Disallowed workflows (anything outside browse/research/product/review/shopping)
///   - Unsupported browsers (find_on_page requires a known browser bundle)
///   - Per-session budget exhaustion (maxScrolls = 2, maxFinds = 1)
///
/// Everything else (click, type into forms, navigate, submit) remains fully blocked.
///
/// Logs:
///   [AgenticControlPolicy] action=... allowed=yes/no reason=...
///   [AgenticControlPolicy] budget scrolls=.../N finds=.../N
///   [AgenticControlPolicy] blocked reason=...
struct AgenticControlPolicy: Sendable {

	// MARK: - Defaults

	static let maxScrollsDefault = 2
	static let maxFindsDefault = 1

	/// Workflows where controlled page interaction is permitted.
	static let allowedWorkflows: Set<String> = [
		"browsing", "research", "product", "review", "shopping", "reading"
	]

	/// Browser bundle identifiers that support Cmd+F find-on-page.
	static let supportedBrowserBundles: Set<String> = [
		"com.apple.safari",
		"org.mozilla.firefox",
		"com.google.chrome",
		"com.brave.browser",
		"com.microsoft.edgemac",
		"com.operasoftware.opera",
		"com.vivaldi.vivaldi",
		"org.chromium.chromium"
	]

	/// High-risk phrases (substring match) and tokens (word match) that indicate a risky context.
	/// These block ALL controlled actions regardless of workflow.
	///
	/// IMPORTANT: tokens are matched on word boundaries to avoid false positives like "power bank".
	static let highRiskPhrases: [String] = [
		"log in", "sign in", "sign-in", "forgot password",
		"credit card", "debit card",
		"wire transfer", "health record",
		"verify your", "two-factor",
		"account locked", "place order",
		"bank account", "online banking"
	]

	static let highRiskTokens: Set<String> = [
		"login", "password",
		"checkout", "payment", "billing",
		"bank", "banking",
		"medical", "government",
		"secure", "authentication",
		"2fa", "captcha",
		"purchase",
	]

	// MARK: - Evaluation

	func evaluate(_ ctx: AgenticControlPolicyContext) -> AgenticControlPolicyResult {
		guard ctx.action == .scroll_small || ctx.action == .find_on_page else {
			return AgenticControlPolicyResult(
				allowed: false,
				reason: "not_a_controlled_action_type",
				findQuery: nil
			)
		}

		// 0. Phase 4R — Terminal-step control guard.
		//
		// scroll_small/find_on_page only make sense when we can still observe the
		// post-control state (at least one remaining step AND perception budget).
		// Without this, the loop can waste its final step on a control action and
		// terminate without being able to extract any new evidence.
		let remainingStepsAfterAction = max(0, ctx.maxSteps - ctx.stepIndex)
		let remainingPerceptionBudget = max(0, ctx.ocrCallsBudget - ctx.ocrCallsUsed)
		if remainingStepsAfterAction < 1 || remainingPerceptionBudget <= 0 {
			let reason = "terminal_step_no_observation_budget"
			print("[AgenticControlPolicy] action=\(ctx.action.rawValue) allowed=no reason=\(reason)")
			return AgenticControlPolicyResult(allowed: false, reason: reason, findQuery: nil)
		}

		// 0. Phase 4M — Execution-focus guard.
		// Refuse control whenever we know the target anchor AND we observed the
		// frontmost app — and they don't match. Without this, find/scroll would
		// be sent to whatever app happens to be frontmost (often Contextual or
		// the previous user app), which produces invalid macOS sounds and
		// pollutes user state. When either piece of information is missing the
		// guard is inactive — legacy behavior is preserved.
		if let expected = ctx.expectedTargetBundle,
		   let actual = ctx.currentFrontmostBundle {
			if expected != actual {
				let reason = "frontmost_mismatch"
				print("[AgenticControlFocusGuard] allowed=no target=\(expected) actual=\(actual) action=\(ctx.action.rawValue)")
				print("[AgenticControlFocusGuard] blocked reason=\(reason) action=\(ctx.action.rawValue)")
				return AgenticControlPolicyResult(allowed: false, reason: reason, findQuery: nil)
			}
			print("[AgenticControlFocusGuard] allowed=yes target=\(expected) actual=\(actual) action=\(ctx.action.rawValue)")
		}

		// 1. High-risk context is always blocked
		if isHighRiskContext(windowTitle: ctx.windowTitle) {
			let reason = "high_risk_context"
			print("[AgenticControlPolicy] action=\(ctx.action.rawValue) allowed=no reason=\(reason) window=\(ctx.windowTitle.prefix(40))")
			return AgenticControlPolicyResult(allowed: false, reason: reason, findQuery: nil)
		}

		// 2. Workflow must be in the allowed set
		if !Self.allowedWorkflows.contains(ctx.workflow.lowercased()) {
			let reason = "workflow_not_allowed:\(ctx.workflow)"
			print("[AgenticControlPolicy] blocked reason=\(reason)")
			return AgenticControlPolicyResult(allowed: false, reason: reason, findQuery: nil)
		}

		// 3. find_on_page: must be a supported browser
		if ctx.action == .find_on_page {
			let bundle = ctx.bundleIdentifier?.lowercased() ?? ""
			if !Self.supportedBrowserBundles.contains(bundle) {
				let reason = "unsupported_browser:\(ctx.bundleIdentifier ?? "nil")"
				print("[AgenticControlPolicy] blocked reason=\(reason)")
				return AgenticControlPolicyResult(allowed: false, reason: reason, findQuery: nil)
			}
		}

		// 4. Per-session budget checks
		if ctx.action == .scroll_small {
			print("[AgenticControlPolicy] budget scrolls=\(ctx.scrollsUsed)/\(ctx.maxScrolls) finds=\(ctx.findsUsed)/\(ctx.maxFinds)")
			if ctx.scrollsUsed >= ctx.maxScrolls {
				print("[AgenticControlPolicy] blocked reason=scroll_budget_exhausted")
				return AgenticControlPolicyResult(allowed: false, reason: "scroll_budget_exhausted", findQuery: nil)
			}
		}
		if ctx.action == .find_on_page {
			print("[AgenticControlPolicy] budget scrolls=\(ctx.scrollsUsed)/\(ctx.maxScrolls) finds=\(ctx.findsUsed)/\(ctx.maxFinds)")
			if ctx.findsUsed >= ctx.maxFinds {
				print("[AgenticControlPolicy] blocked reason=find_budget_exhausted")
				return AgenticControlPolicyResult(allowed: false, reason: "find_budget_exhausted", findQuery: nil)
			}
		}

		// 5. Allowed — derive find query if needed
		let findQuery = ctx.action == .find_on_page ? Self.determineFindQuery(goal: "") : nil
		let suffix = ctx.dryRun ? " dry_run=yes" : ""
		print("[AgenticControlPolicy] action=\(ctx.action.rawValue) allowed=yes reason=policy_pass\(suffix)")
		return AgenticControlPolicyResult(allowed: true, reason: "allowed", findQuery: findQuery)
	}

	// MARK: - Helpers

	private func isHighRiskContext(windowTitle: String) -> Bool {
		let title = windowTitle.lowercased()

		// Phrase match (multi-word / explicit patterns).
		if Self.highRiskPhrases.contains(where: { title.contains($0) }) {
			return true
		}

		// Token match (word boundary) with small false-positive guards.
		let tokens = title
			.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
			.map { String($0) }
			.filter { !$0.isEmpty }

		for (idx, tok) in tokens.enumerated() {
			guard Self.highRiskTokens.contains(tok) else { continue }

			// Guard: "power bank" is not a banking context.
			if tok == "bank", idx > 0, tokens[idx - 1] == "power" {
				continue
			}

			return true
		}

		return false
	}

	/// Deterministic find query from goal text. Covers common research patterns.
	/// Never allows arbitrary user data — always maps to a bounded keyword.
	// MARK: - Phase 4O: evidence-kind-aware query selection

	/// Returns a deterministic `find_on_page` query for the given evidence kind.
	///
	/// The runtime calls this when it knows *which* evidence requirement is
	/// missing — picking the query from the requirement instead of from the
	/// goal text avoids leaking app names ("firefox") or goal echoes
	/// ("Search Firefox History …") into the find bar.
	///
	/// Falls back to `determineFindQuery(goal:)` when the kind has no preferred
	/// query (e.g. `.unknown`, `.pageSummary`).
	static func determineFindQuery(forMissingKind kind: AgenticEvidenceKind, goal: String) -> String {
		switch kind {
		case .productTitle:        return "product"
		case .price:               return "price"
		case .specs:               return "specs"
		case .rating:              return "rating"
		case .reviewCount:         return "reviews"
		case .reviewText:          return "customer"
		case .comparisonCandidate: return "compare"
		case .inboxContext:        return "inbox"
		case .messageList:         return "inbox"
		case .emailSubject:        return "subject"
		case .emailSnippet:        return "unread"
		case .emailSender:         return "from"
		case .unreadCount:         return "unread"
		case .timestamp:           return "today"
		case .pageSummary, .documentKeyPoint:
			return determineFindQuery(goal: goal)
		case .codeSnippet:         return "function"
		case .errorMessage:        return "error"
		case .unknown:
			return determineFindQuery(goal: goal)
		}
	}

	/// Phase 4N — Browser/OS chrome words that must never become a find_on_page
	/// query. These come from misaligned planner refinements (e.g. "Search
	/// Firefox History for ‘Anker Laptop Charger’") and would point the find
	/// bar at chrome strings instead of page content.
	static let findQueryBlocklist: Set<String> = [
		// browser app names
		"firefox", "safari", "chrome", "edge", "brave", "opera",
		"vivaldi", "chromium",
		// browser-chrome surfaces
		"browser", "history", "bookmarks", "tabs", "tab",
		"settings", "preferences", "downloads", "extensions",
		"sidebar", "toolbar", "menubar", "addressbar",
		// generic command verbs that should not be the query
		"open", "close", "switch", "navigate", "search", "find",
	]

	static func determineFindQuery(goal: String) -> String {
		let g = goal.lowercased()
		// Keyword-class queries take priority — these are deterministic and
		// always content-aligned.
		if g.contains("review") || g.contains("rating") || g.contains("star") || g.contains("testimonial") {
			return "review"
		}
		if g.contains("price") || g.contains("cost") || g.contains("dollar") || g.contains("deal") || g.contains("discount") {
			return "price"
		}
		if g.contains("spec") || g.contains("dimension") || g.contains("measurement") || g.contains("size") || g.contains("weight") {
			return "spec"
		}
		if g.contains("compat") || g.contains("works with") || g.contains("support") {
			return "compatible"
		}
		if g.contains("complaint") || g.contains("issue") || g.contains("problem") || g.contains("defect") {
			return "issue"
		}
		if g.contains("battery") || g.contains("charging") || g.contains("power") {
			return "battery"
		}
		if g.contains("color") || g.contains("colour") || g.contains("finish") || g.contains("design") {
			return "color"
		}
		if g.contains("warranty") || g.contains("return") || g.contains("refund") {
			return "warranty"
		}
		if g.contains("feature") || g.contains("function") || g.contains("capabilit") {
			return "feature"
		}
		if g.contains("material") || g.contains("build") || g.contains("quality") {
			return "quality"
		}

		// Extract first significant content word from goal.
		// Phase 4N: drop app names + chrome verbs so a misaligned goal like
		// "Search Firefox History for 'Anker Laptop Charger'" can never yield
		// query=firefox/history — falls through to a real content token
		// ("anker", "laptop", "charger") or the neutral "information" fallback.
		let stopWords: Set<String> = [
			"this", "that", "with", "from", "show", "what", "does", "when",
			"where", "about", "look", "tell", "give", "want", "need", "please",
			"help", "have", "make", "take", "just", "also", "your", "their",
		]
		let words = g.components(separatedBy: .whitespaces)
			.map { $0.trimmingCharacters(in: .punctuationCharacters) }
			.filter { $0.count > 3 && !stopWords.contains($0) && !findQueryBlocklist.contains($0) }
		if let chosen = words.first { return chosen }
		print("[AgenticControlDecision] find_query_fallback reason=goal_all_chrome_or_stopwords goal=\(g.prefix(60))")
		return "information"
	}
}
