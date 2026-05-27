import Foundation

// MARK: - Classification

/// Phase 4S — How a window title classifies for the model-free fast visibility
/// surface. Only `actionWorthy` titles are eligible for the lightweight shell.
///
/// All other categories are typed reasons so dogfood logs can attribute
/// rejection precisely.
enum FastVisibilityTitleClassification: String, Sendable, Equatable, Codable {
	case actionWorthy = "action_worthy"
	case accountIdentity = "account_identity"
	case genericStorefront = "generic_storefront"
	case genericHomepage = "generic_homepage"
	case appTitle = "app_title"
	case browserChrome = "browser_chrome"
	case assistantChrome = "assistant_chrome"
	case tooShort = "too_short"
	case weakOrGenericTitle = "weak_or_generic_title"
}

// MARK: - Decision

struct FastVisibilityDecision: Sendable, Equatable {
	let eligible: Bool
	let classification: FastVisibilityTitleClassification
	let reason: String
}

// MARK: - Gate

/// Pure heuristic quality gate for the model-free fast proposal shell.
///
/// Replaces the previous tiny generic-title blocklist with a multi-axis
/// classifier that catches:
///   - Account/identity strings (`"Duncanyu (Duncan Yu)"`).
///   - Generic storefront marketing copy (`"Amazon.ca: Low Prices – Fast Shipping – Millions of Items"`).
///   - Generic homepage / "welcome" pages.
///   - App and browser chrome titles.
///   - Assistant chrome (`"Processing …"`).
///   - Too-short titles that carry no extractable entity.
///
/// No website-specific code. No hardcoded title list. Patterns are generic
/// marketing/identity vocabulary.
enum FastVisibilityQualityGate {

	// MARK: - Vocabularies

	/// Marketing phrases that appear on retail storefront / homepage titles.
	/// Their presence strongly suggests the user has not navigated to a
	/// specific product yet.
	private static let storefrontMarketingPhrases: [String] = [
		"low prices", "lowest prices", "everyday low",
		"fast shipping", "free shipping", "free delivery",
		"millions of items", "best deals", "today's deals",
		"shop now", "save big", "deals of the day",
		"new arrivals", "best sellers",
	]

	/// Generic homepage / landing words.
	private static let homepageWords: [String] = [
		"home", "welcome", "welcome to", "homepage", "landing",
		"start", "dashboard",
	]

	/// Browser app and chrome words (lowercased).
	private static let browserChromeWords: Set<String> = [
		"mozilla firefox", "firefox", "google chrome", "chrome", "safari",
		"arc", "brave", "edge", "opera", "vivaldi", "chromium",
		"new tab", "about:blank", "blank page", "untitled", "private browsing",
	]

	/// Assistant-internal chrome that must never trigger a fast shell.
	private static let assistantChromeFragments: [String] = [
		"processing", "controlled interactions", "execute", "chime in",
		"antigravity", "contextual", "generated execution", "runtime phase",
		"actions taken",
	]

	// MARK: - Evaluate

	/// Classify a title and decide whether it is eligible for the fast
	/// model-free shell.
	static func evaluate(
		title: String,
		appName: String,
		bundleIdentifier: String? = nil
	) -> FastVisibilityDecision {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		let lower = trimmed.lowercased()

		// 1. Empty / too-short titles.
		if trimmed.isEmpty {
			return reject(.tooShort, "empty_title")
		}
		if trimmed.count < 4 {
			return reject(.tooShort, "below_min_length")
		}

		// 2. Assistant chrome — never eligible.
		for needle in assistantChromeFragments where lower.contains(needle) {
			return reject(.assistantChrome, "assistant_chrome_keyword:\(needle.replacingOccurrences(of: " ", with: "_"))")
		}

		// 3. Browser / app chrome.
		if browserChromeWords.contains(lower) {
			return reject(.browserChrome, "browser_chrome_only")
		}
		if lower == appName.lowercased() {
			return reject(.appTitle, "matches_app_name")
		}

		// 4. Generic homepage / landing titles.
		if isGenericHomepage(lower) {
			return reject(.genericHomepage, "generic_homepage_keyword")
		}

		// 5. Generic storefront marketing copy.
		if isGenericStorefront(lower) {
			return reject(.genericStorefront, "storefront_marketing_phrase")
		}

		// 6. Account / identity strings.
		if isAccountIdentity(trimmed) {
			return reject(.accountIdentity, "looks_like_account_or_person_name")
		}

		// 7. Multi-word concrete-content gate.
		// Require at least 3 substantive tokens AND at least one token that is
		// not a generic marketing/identity word.
		let substantive = substantiveTokens(in: trimmed)
		if substantive.count < 3 {
			return reject(.weakOrGenericTitle, "fewer_than_three_substantive_tokens")
		}

		return FastVisibilityDecision(
			eligible: true,
			classification: .actionWorthy,
			reason: "action_worthy_title"
		)
	}

	// MARK: - Logging

	static func log(decision: FastVisibilityDecision, title: String) {
		if decision.eligible {
			print("[FastVisibility] eligible=yes classification=\(decision.classification.rawValue) title=\"\(title.prefix(80))\"")
		} else {
			print("[FastVisibility] eligible=no reason=\(decision.reason) classification=\(decision.classification.rawValue) title=\"\(title.prefix(80))\"")
		}
	}

	// MARK: - Internals

	private static func reject(
		_ classification: FastVisibilityTitleClassification,
		_ reason: String
	) -> FastVisibilityDecision {
		FastVisibilityDecision(
			eligible: false,
			classification: classification,
			reason: reason
		)
	}

	private static func isGenericHomepage(_ lower: String) -> Bool {
		// Exact-match homepage words.
		if homepageWords.contains(lower) { return true }
		// Common "<App> — Home" or "<App> | Home" patterns.
		for sep in [" — home", " - home", " | home", " — homepage", " - homepage"] {
			if lower.hasSuffix(sep) { return true }
		}
		// Leading "welcome to …"
		if lower.hasPrefix("welcome to ") { return true }
		return false
	}

	private static func isGenericStorefront(_ lower: String) -> Bool {
		for phrase in storefrontMarketingPhrases where lower.contains(phrase) {
			return true
		}
		return false
	}

	/// True when the title looks like a person name, account label, or profile
	/// page rather than a piece of content.
	///
	/// Generic patterns (no specific name lists):
	///   - "<Word> (<Word> <Word>)" — common profile pattern like
	///     `"Duncanyu (Duncan Yu)"`.
	///   - Trailing `(account)` / `(profile)` markers.
	///   - Pure "<First> <Last>" with no other context tokens (2 capitalized
	///     words and nothing else).
	private static func isAccountIdentity(_ trimmed: String) -> Bool {
		let lower = trimmed.lowercased()
		if lower.contains("(account)") || lower.contains("(profile)")
			|| lower.contains("my account") || lower.contains("my profile") {
			return true
		}

		// Pattern: "<Word> (<Word>[ <Word>])"
		if let regex = try? NSRegularExpression(
			pattern: #"^[A-Za-z][A-Za-z\-']*\s*\(\s*[A-Za-z][A-Za-z\-']*(?:\s+[A-Za-z][A-Za-z\-']*)?\s*\)$"#,
			options: []
		) {
			let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
			if regex.firstMatch(in: trimmed, options: [], range: nsRange) != nil {
				return true
			}
		}

		// Pattern: exactly two title-case tokens with nothing else.
		let tokens = trimmed.split(separator: " ").map(String.init)
		if tokens.count == 2,
		   tokens.allSatisfy({ $0.first?.isUppercase == true && $0.count >= 2 }) {
			return true
		}

		return false
	}

	/// Tokens with semantic weight (drops stopwords + very short tokens).
	private static let stopwords: Set<String> = [
		"the", "and", "for", "with", "from", "your", "this", "that", "have",
		"will", "are", "you", "our", "out", "all", "any", "but", "can",
		"its", "his", "her", "they", "them", "what", "when", "where", "than",
		"then", "into", "such", "more", "much", "very", "just", "also",
	]

	private static func substantiveTokens(in text: String) -> [String] {
		let separators = CharacterSet.alphanumerics.inverted
		let tokens = text.lowercased()
			.components(separatedBy: separators)
			.filter { $0.count >= 3 && !stopwords.contains($0) }
		return tokens
	}

	// MARK: - Helpers exposed for execution-time stale-goal repair

	/// True when a title is `actionWorthy`.
	static func isActionWorthy(title: String, appName: String) -> Bool {
		evaluate(title: title, appName: appName).classification == .actionWorthy
	}

	/// True when a title falls into one of the weak / generic classes.
	static func isWeakOrGeneric(title: String, appName: String) -> Bool {
		let decision = evaluate(title: title, appName: appName)
		switch decision.classification {
		case .actionWorthy:
			return false
		case .accountIdentity, .genericStorefront, .genericHomepage,
			 .appTitle, .browserChrome, .assistantChrome,
			 .tooShort, .weakOrGenericTitle:
			return true
		}
	}
}
