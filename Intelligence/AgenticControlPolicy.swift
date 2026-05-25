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
	/// Actions executed so far this session.
	let priorActions: [String]
	/// Scroll actions already used this session.
	let scrollsUsed: Int
	/// Find-on-page actions already used this session.
	let findsUsed: Int
	/// Per-session scroll cap.
	let maxScrolls: Int
	/// Per-session find-on-page cap.
	let maxFinds: Int
	/// If true, no real OS events will be posted (test/preview mode).
	let dryRun: Bool
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

	/// Window title substrings that indicate a high-risk context.
	/// These block ALL controlled actions regardless of workflow.
	static let highRiskWindowKeywords: [String] = [
		"login", "log in", "sign in", "sign-in", "password", "forgot password",
		"checkout", "payment", "billing", "credit card", "debit card",
		"bank", "banking", "wire transfer", "medical", "health record",
		"government", "secure", "authentication", "verify your", "two-factor",
		"2fa", "captcha", "account locked", "purchase", "buy now", "place order"
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
		return Self.highRiskWindowKeywords.contains { title.contains($0) }
	}

	/// Deterministic find query from goal text. Covers common research patterns.
	/// Never allows arbitrary user data — always maps to a bounded keyword.
	static func determineFindQuery(goal: String) -> String {
		let g = goal.lowercased()
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
		// Extract first significant content word from goal
		let stopWords: Set<String> = [
			"this", "that", "with", "from", "find", "show", "what", "does", "when",
			"where", "about", "look", "tell", "give", "want", "need", "please",
			"help", "get", "search", "have", "make", "take", "just", "also"
		]
		let words = g.components(separatedBy: .whitespaces)
			.map { $0.trimmingCharacters(in: .punctuationCharacters) }
			.filter { $0.count > 3 && !stopWords.contains($0) }
		return words.first ?? "information"
	}
}
