import Foundation

// MARK: - Decision

/// Outcome of a planner-refinement alignment check.
///
/// The gate is intentionally lossy: callers only need `aligned` and `reason`
/// to decide whether to publish the refined proposal. The classified families
/// are surfaced so logs and self-tests can explain rejections.
struct PlannerRefinementAlignmentDecision: Sendable, Equatable {
	let aligned: Bool
	/// Typed token. One of:
	///   `aligned` / `task_family_mismatch` /
	///   `browser_chrome_navigation_misaligned` /
	///   `unsafe_commerce_verb` / `unknown_old_or_new`
	let reason: String
	let oldFamily: String
	let newFamily: String
}

// MARK: - Gate

/// Phase 4N — Planner Refinement Alignment Gate.
///
/// Pure value type. Given a fast-shell title (the safe deterministic shell
/// surfaced first) and a planner-refined candidate title, returns whether the
/// refinement preserves the user's intent or redirects the task into a
/// browser-chrome / unsafe-commerce / wrong-family goal.
///
/// **Non-negotiable design rules:**
///   - No website-specific logic. The gate operates on generic task families
///     and chrome-vocabulary tokens.
///   - No model/network calls. Fully deterministic; <100 µs per call.
///   - Conservative on ambiguity: when classification fails on either side,
///     the gate prefers to reject and keep the safe fast shell.
///
/// **Logs (emitted by the caller):**
///   `[PlannerRefinementGate] old_family=… new_family=… aligned=yes|no reason=…`
enum PlannerRefinementAlignmentGate {

	// MARK: - Vocabularies

	/// Tokens that mark a browser/OS chrome or app-control target rather than
	/// page content. A refinement that introduces any of these (when the
	/// original shell had none) is treated as a misaligned navigation goal.
	static let chromeTokens: Set<String> = [
		// browser app names
		"firefox", "safari", "chrome", "edge", "brave", "opera", "vivaldi",
		"chromium",
		// generic browser-chrome surfaces
		"browser", "history", "bookmarks", "tabs", "tab",
		"settings", "preferences", "downloads", "extensions",
		"sidebar", "toolbar", "menubar", "addressbar",
		// OS shells
		"finder", "spotlight",
	]

	/// Verbs that indicate commerce / authentication / destructive actions.
	/// Phrases (containing a space) are matched as substrings; single tokens
	/// are matched on word boundaries so legitimate uses (e.g. "buying guide")
	/// are not falsely rejected.
	static let unsafePhrases: [String] = [
		"buy now", "add to cart", "place order", "check out",
		"sign in", "log in",
	]

	static let unsafeTokens: Set<String> = [
		"purchase", "checkout", "delete", "remove",
		"login", "logout", "signup",
		"subscribe", "unsubscribe", "donate", "transfer",
	]

	/// Verbs whose presence (as a token) classifies the title's task family.
	/// Order matters — first match wins.
	private static let familyVerbs: [(family: String, tokens: [String])] = [
		("summarize", ["summarize", "summarise", "summary", "tldr"]),
		("review",    ["review", "reviews"]),
		("compare",   ["compare", "comparison", "versus", "vs"]),
		("analyze",   ["analyze", "analyse", "analysis"]),
		("extract",   ["extract", "list"]),
		("describe",  ["describe", "explain"]),
		("read",      ["read"]),
		("search",    ["search"]),
		("navigate",  ["navigate", "switch", "goto"]),
		("open",      ["open"]),
	]

	/// Families that operate on visible page content. A refinement that comes
	/// from one of these and lands in a non-content family is rejected.
	private static let contentFamilies: Set<String> = [
		"summarize", "review", "compare", "analyze",
		"extract", "describe", "read",
	]

	/// Families that target navigation / chrome / external scope. Allowed only
	/// when the original shell was already in this group.
	private static let nonContentFamilies: Set<String> = [
		"search", "navigate", "open", "browser_chrome",
	]

	// MARK: - Public API

	/// Evaluate whether a refinement preserves the safe fast shell intent.
	///
	/// `pageWindowTitle`, `pageBundleIdentifier`, and `workflow` are accepted
	/// but currently unused by the rules; they are part of the contract so
	/// future entity-alignment checks can be added without changing call sites.
	static func evaluate(
		oldShellTitle: String,
		newRefinedTitle: String,
		pageWindowTitle: String = "",
		pageBundleIdentifier: String? = nil,
		workflow: String? = nil
	) -> PlannerRefinementAlignmentDecision {
		let oldLower = normalize(oldShellTitle)
		let newLower = normalize(newRefinedTitle)
		let oldFamily = classifyFamily(oldLower)
		let newFamily = classifyFamily(newLower)

		// 0. Empty/degenerate new title → reject so caller keeps the shell.
		if newLower.isEmpty {
			return PlannerRefinementAlignmentDecision(
				aligned: false,
				reason: "unknown_old_or_new",
				oldFamily: oldFamily,
				newFamily: newFamily
			)
		}

		// 1. Browser/OS chrome targeting in the refinement.
		//    Exception: original shell was already chrome-targeted (we currently
		//    do not ship such shells, but the gate stays correct if we do).
		let newTokens = tokenize(newLower)
		let chromeHits = newTokens.intersection(chromeTokens)
		if !chromeHits.isEmpty {
			let oldChromeHits = tokenize(oldLower).intersection(chromeTokens)
			if oldChromeHits.isEmpty {
				return PlannerRefinementAlignmentDecision(
					aligned: false,
					reason: "browser_chrome_navigation_misaligned",
					oldFamily: oldFamily,
					newFamily: contentFamilies.contains(oldFamily) ? "browser_chrome" : newFamily
				)
			}
		}

		// 2. Unsafe commerce / auth / destructive verbs.
		for phrase in unsafePhrases where newLower.contains(phrase) {
			return PlannerRefinementAlignmentDecision(
				aligned: false,
				reason: "unsafe_commerce_verb",
				oldFamily: oldFamily,
				newFamily: newFamily
			)
		}
		if !newTokens.intersection(unsafeTokens).isEmpty {
			return PlannerRefinementAlignmentDecision(
				aligned: false,
				reason: "unsafe_commerce_verb",
				oldFamily: oldFamily,
				newFamily: newFamily
			)
		}

		// 3. Content family must not collapse to non-content family.
		if contentFamilies.contains(oldFamily), nonContentFamilies.contains(newFamily) {
			return PlannerRefinementAlignmentDecision(
				aligned: false,
				reason: "task_family_mismatch",
				oldFamily: oldFamily,
				newFamily: newFamily
			)
		}

		// 4. Content shell must keep a recognizable content family. "unknown"
		//    new family from a content shell almost always means the planner
		//    dropped the verb entirely (e.g. "Anker Laptop Charger 140W").
		if contentFamilies.contains(oldFamily), newFamily == "unknown" {
			return PlannerRefinementAlignmentDecision(
				aligned: false,
				reason: "task_family_mismatch",
				oldFamily: oldFamily,
				newFamily: newFamily
			)
		}

		return PlannerRefinementAlignmentDecision(
			aligned: true,
			reason: "aligned",
			oldFamily: oldFamily,
			newFamily: newFamily
		)
	}

	// MARK: - Classification helpers

	/// Lowercase + collapse runs of whitespace. Keeps punctuation so
	/// `tokenize(_:)` can still split on non-alphanumerics.
	static func normalize(_ raw: String) -> String {
		raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Split title into lowercased alphanumeric tokens.
	static func tokenize(_ lowered: String) -> Set<String> {
		let separators = CharacterSet.alphanumerics.inverted
		let tokens = lowered.components(separatedBy: separators)
			.map { $0.lowercased() }
			.filter { !$0.isEmpty }
		return Set(tokens)
	}

	/// Classify a normalized title into a task family.
	///
	/// Browser-chrome targeting wins over verb-based classification: a title
	/// that contains a chrome token is family `browser_chrome` even when it
	/// also contains "search" or "open" (e.g. "Search Firefox History").
	static func classifyFamily(_ lowered: String) -> String {
		let tokens = tokenize(lowered)
		if !tokens.intersection(chromeTokens).isEmpty {
			return "browser_chrome"
		}
		for (family, verbs) in familyVerbs {
			for verb in verbs {
				if lowered.contains(verb) { return family }
			}
		}
		return "unknown"
	}
}
