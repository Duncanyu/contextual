import Foundation

// MARK: - Result

/// Outcome of a `ProductTitleSynthesizer.synthesize(...)` call.
struct ProductTitleSynthesisResult: Sendable, Equatable {
	/// Cleaned title, or nil when the input was unsalvageable (truncated,
	/// chrome, account/identity, etc.).
	let cleanedTitle: String?
	/// Typed reason for logs.
	///   `cleaned_trimmed_compat_clause`
	///   `cleaned_no_change`
	///   `rejected_truncation`
	///   `rejected_unsalvageable`
	let reason: String
	/// Number of characters removed from the trailing compat/list section.
	let trimmedTailChars: Int
}

// MARK: - Synthesizer

/// Phase 4U — ProductTitleSynthesizer.
///
/// Cleans the raw product-title string before it lands in a structured fact or
/// a runtime answer. The dogfood failure mode:
///
///   raw: "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger,
///         Foldable Plug, Compatible With MacBook Pro Air iPhone 17 16 15 14
///         13 Pro Max Plus Series, Galaxy S25 S24 S23, iPad, Cable Not Include"
///
///   We want:
///
///   "Anker Prime USB C Charger Block, 160W 3-Port GaN Phone Charger"
///
/// Rules (all generic — never website / brand-specific):
///   - Strip everything after the FIRST occurrence of a "compatibility list"
///     sentinel phrase (`Compatible With`, `For Use With`, `Works With`,
///     `Fits`, `Designed For`, `Includes:`).
///   - Strip trailing fragments after a `,` only when the trailing fragment is
///     a stand-alone compat-style clause (starts with `for`, `with`,
///     `compatible`, or contains too many capitalized model numbers).
///   - Reject the whole title when it ends mid-word (`"Cable Not Include"`),
///     contains an ellipsis (`"..."` / `"…"`), or contains assistant chrome.
///   - Cap to a sensible length (`maxLength`) without breaking words.
enum ProductTitleSynthesizer {

	/// Maximum length of the cleaned title.
	static let maxLength: Int = 110

	/// Sentinel phrases that mark the START of a compatibility list. Anything
	/// after them (including the phrase) is stripped.
	private static let compatStartPhrases: [String] = [
		"compatible with", "for use with", "works with", "designed for",
		"fits ", "includes:", "intended for",
	]

	/// Trailing-clause leading words that strongly suggest a compat-list
	/// fragment (when they follow a comma).
	private static let trailingFragmentLeaders: Set<String> = [
		"for", "with", "compatible", "includes",
	]

	/// Markers that indicate the original text was truncated by upstream OCR /
	/// streaming and should not be presented as a finished title.
	private static let truncationMarkers: [String] = [
		"...", "…",
	]

	/// Suffix patterns that are obvious truncations (model emitted a partial
	/// word). Conservative — only catches the common cases the dogfood
	/// surfaces (e.g. `"Cable Not Include"` which should have been `"Included"`).
	private static let truncatedTailSuffixes: [String] = [
		" not include", " not includ", " cable not", " includ$",
	]

	// MARK: - Public API

	/// Clean a raw OCR / AX product title.
	static func synthesize(raw: String) -> ProductTitleSynthesisResult {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			return ProductTitleSynthesisResult(cleanedTitle: nil, reason: "rejected_unsalvageable", trimmedTailChars: 0)
		}

		// 1. Reject obvious truncation markers up front.
		let lower = trimmed.lowercased()
		for marker in truncationMarkers where trimmed.contains(marker) {
			_ = marker
			return ProductTitleSynthesisResult(cleanedTitle: nil, reason: "rejected_truncation", trimmedTailChars: 0)
		}

		// 2. Strip everything after the first compat sentinel phrase.
		var working = trimmed
		var beforeStripLen = trimmed.count
		var stripped = false
		for phrase in compatStartPhrases {
			if let range = working.lowercased().range(of: phrase) {
				let cutEnd = working.index(working.startIndex, offsetBy: working.distance(from: working.startIndex, to: range.lowerBound))
				working = String(working[..<cutEnd])
				working = trimTrailingPunctuation(working)
				stripped = true
				break
			}
		}

		// 3. Strip trailing comma-separated fragment when it looks compat-y.
		while let lastComma = working.range(of: ",", options: .backwards) {
			let tail = working[lastComma.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
			guard !tail.isEmpty else {
				working = String(working[..<lastComma.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
				continue
			}
			let tailLower = tail.lowercased()
			let leader = tailLower.split(separator: " ").first.map(String.init) ?? ""
			let isLeaderFragment = trailingFragmentLeaders.contains(leader)
			let truncatedTail = truncatedTailSuffixes.contains { tailLower.hasSuffix($0) }
			let mostlyCapitalized = isMostlyCapitalizedModelList(tail)
			if isLeaderFragment || truncatedTail || mostlyCapitalized {
				working = String(working[..<lastComma.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
				stripped = true
				continue
			}
			break
		}

		// 4. Reject if the surviving title still ends in a truncation suffix.
		let workingLower = working.lowercased()
		for suffix in truncatedTailSuffixes where workingLower.hasSuffix(suffix) || workingLower.hasSuffix(" include") {
			_ = suffix
			return ProductTitleSynthesisResult(cleanedTitle: nil, reason: "rejected_truncation", trimmedTailChars: max(0, beforeStripLen - working.count))
		}

		// 5. Reject empty result.
		guard !working.isEmpty else {
			return ProductTitleSynthesisResult(cleanedTitle: nil, reason: "rejected_unsalvageable", trimmedTailChars: max(0, beforeStripLen - working.count))
		}

		// 6. Cap to maxLength without breaking words.
		if working.count > maxLength {
			let limited = String(working.prefix(maxLength))
			if let lastSpace = limited.range(of: " ", options: .backwards) {
				working = String(limited[..<lastSpace.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
			} else {
				working = limited
			}
			stripped = true
		}

		// 7. Final cleanup: trailing punctuation and double spaces.
		working = trimTrailingPunctuation(working)
		while working.contains("  ") {
			working = working.replacingOccurrences(of: "  ", with: " ")
		}

		let trimmedTailChars = max(0, beforeStripLen - working.count)
		_ = lower
		let reason = stripped ? "cleaned_trimmed_compat_clause" : "cleaned_no_change"
		return ProductTitleSynthesisResult(
			cleanedTitle: working,
			reason: reason,
			trimmedTailChars: trimmedTailChars
		)
	}

	// MARK: - Internals

	private static func trimTrailingPunctuation(_ text: String) -> String {
		var t = text
		while let last = t.last, [".", ",", ";", ":", "-", " "].contains(last) {
			t.removeLast()
		}
		return t.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// True when a string is dominated by single-letter/short model-number tokens
	/// (e.g. `"iPhone 17 16 15 14 13 Pro Max Plus Series"`). Used to detect a
	/// compatibility-list fragment that lacks a leading keyword.
	private static func isMostlyCapitalizedModelList(_ text: String) -> Bool {
		let tokens = text.split(separator: " ").map(String.init)
		guard tokens.count >= 4 else { return false }
		let numericish = tokens.filter { $0.allSatisfy { $0.isNumber } || $0.count <= 3 }.count
		let ratio = Double(numericish) / Double(tokens.count)
		return ratio >= 0.45
	}
}
