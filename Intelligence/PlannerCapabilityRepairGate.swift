import Foundation

// MARK: - Category

/// Phase 4Q — classification of a planner-candidate title against the runtime
/// capability envelope. Deterministic, no website-specific logic.
///
/// `safe*` cases are inside the envelope (executable by the agentic runtime
/// using observe / extract / find / scroll / summarize / present).
/// All other cases are outside the envelope and must be rejected by validators.
enum PlannerCapabilityCategory: String, Sendable, Hashable, Codable {
	// Outside the envelope (unsafe / unsupported)
	case purchase
	case wishlist
	case cart
	case checkout
	case authentication
	case destructive
	case searchNavigation = "search_navigation"
	case openNavigation = "open_navigation"
	case clickInteraction = "click_interaction"
	case typeInteraction = "type_interaction"

	// Inside the envelope (executable today)
	case safeInspect = "safe_inspect"
	case safeExtract = "safe_extract"
	case safeSummarize = "safe_summarize"
	case safeCompare = "safe_compare"
	case safeGather = "safe_gather"

	case unknown

	/// True when this category can be executed by the current runtime.
	var isAllowed: Bool {
		switch self {
		case .safeInspect, .safeExtract, .safeSummarize, .safeCompare, .safeGather:
			return true
		default:
			return false
		}
	}

	/// True when this category is unsafe (commerce / auth / destructive / interaction).
	/// Used to detect the "all candidates unsafe" condition that triggers the
	/// strict-envelope retry.
	var isUnsafe: Bool {
		switch self {
		case .purchase, .wishlist, .cart, .checkout, .authentication, .destructive,
			 .clickInteraction, .typeInteraction:
			return true
		default:
			return false
		}
	}

	/// True when the category is search/open navigation — outside the envelope
	/// but potentially repairable into an in-envelope gather goal when the
	/// target entity is already present in the active context.
	var isNavigation: Bool {
		switch self {
		case .searchNavigation, .openNavigation:
			return true
		default:
			return false
		}
	}
}

// MARK: - Gate

/// Pure classifier — no model calls, no AppKit dependency.
///
/// Vocabulary is intentionally generic. We do NOT add canned titles or
/// website-specific words; the rules check for verbs and well-known commerce
/// nouns (cart, wishlist, checkout) that have one meaning in any app.
enum PlannerCapabilityRepairGate {

	// MARK: - Vocabularies

	private static let purchaseVerbs: [String] = [
		"purchase", "buy now", "buy ", "order now", "place order", "preorder",
		"pre-order",
	]
	private static let wishlistPhrases: [String] = [
		"wishlist", "wish list",
	]
	private static let cartPhrases: [String] = [
		"add to cart", "add to basket", "add to bag", "remove from cart",
		" cart ", " cart.", " cart$",
	]
	private static let checkoutPhrases: [String] = [
		"checkout", "check out and pay", "complete order",
	]
	private static let authPhrases: [String] = [
		"sign in", "log in", "login", "sign up", "create account",
	]
	private static let destructivePhrases: [String] = [
		"delete ", "remove ", "uninstall ", "wipe ", "format ",
	]
	private static let searchVerbs: [String] = [
		"search ", "look up", "lookup ",
	]
	private static let openNavigationVerbs: [String] = [
		"open ", "navigate to", "go to ", "visit ", "switch to ", "switch tab",
	]
	private static let clickVerbs: [String] = [
		"click ", "press ", "tap ",
	]
	private static let typeVerbs: [String] = [
		"type ", "enter ", "fill in", "fill out",
	]
	private static let inspectVerbs: [String] = [
		"inspect", "review", "examine", "evaluate",
	]
	private static let extractVerbs: [String] = [
		"extract", "identify", "list", "collect", "pull",
	]
	private static let summarizeVerbs: [String] = [
		"summarize", "summarise", "tl;dr", "tldr", "describe", "explain",
	]
	private static let compareVerbs: [String] = [
		"compare", "comparison", "versus", " vs ",
	]
	private static let gatherVerbs: [String] = [
		"gather", "find evidence", "find supporting", "scan for", "check for",
	]

	// MARK: - Classification

	/// Classify a title against the runtime envelope. Earliest match wins.
	static func classify(title: String) -> PlannerCapabilityCategory {
		let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		guard !lower.isEmpty else { return .unknown }

		// Unsafe / commerce families. Wishlist + checkout + auth + destructive
		// take priority because they have one meaning in any app.
		if matchesAny(lower, prefixesOrContains: purchaseVerbs) { return .purchase }
		if matchesAny(lower, prefixesOrContains: wishlistPhrases) { return .wishlist }
		if matchesAny(lower, prefixesOrContains: checkoutPhrases) { return .checkout }
		if matchesAny(lower, prefixesOrContains: authPhrases) { return .authentication }
		if matchesAny(lower, prefixesOrContains: destructivePhrases) { return .destructive }

		// Interaction families before cart/navigation so "click the add to cart
		// button" classifies as a click action (the dominant intent verb), not
		// as a cart action.
		if matchesAny(lower, prefixesOrContains: clickVerbs) { return .clickInteraction }
		if matchesAny(lower, prefixesOrContains: typeVerbs) { return .typeInteraction }

		// Cart.
		if matchesAny(lower, prefixesOrContains: cartPhrases) { return .cart }

		// Navigation families (potentially repairable).
		if matchesAny(lower, prefixesOrContains: openNavigationVerbs) { return .openNavigation }
		if matchesAny(lower, prefixesOrContains: searchVerbs) { return .searchNavigation }

		// Safe families.
		if matchesAny(lower, prefixesOrContains: compareVerbs) { return .safeCompare }
		if matchesAny(lower, prefixesOrContains: summarizeVerbs) { return .safeSummarize }
		if matchesAny(lower, prefixesOrContains: extractVerbs) { return .safeExtract }
		if matchesAny(lower, prefixesOrContains: gatherVerbs) { return .safeGather }
		if matchesAny(lower, prefixesOrContains: inspectVerbs) { return .safeInspect }

		return .unknown
	}

	/// True when EVERY title classifies into an unsafe category. Used by the
	/// planner loop to decide whether to retry with the strict-envelope prompt.
	static func allUnsafe(titles: [String]) -> (allUnsafe: Bool, categories: [PlannerCapabilityCategory]) {
		guard !titles.isEmpty else { return (false, []) }
		let categories = titles.map { classify(title: $0) }
		let unsafeCount = categories.filter { $0.isUnsafe || $0.isNavigation }.count
		return (unsafeCount == categories.count, categories)
	}

	// MARK: - Internal

	private static func matchesAny(_ haystack: String, prefixesOrContains needles: [String]) -> Bool {
		for n in needles {
			if haystack.hasPrefix(n) || haystack.contains(n) { return true }
		}
		return false
	}
}
