import Foundation

// MARK: - Candidate

/// One price candidate observed somewhere on the page.
///
/// `anchorContext` is a snippet of text around the price (a few words on each
/// side of the OCR/AX match). The resolver inspects this snippet for anchor
/// signals like `"price"`, `"buy"`, `"add to cart"`, `"deal"`, etc.
struct AnchoredPriceCandidate: Sendable, Equatable {
	/// Raw matched text, e.g. `"$29.99"`.
	let rawText: String
	/// Surrounding context window for anchor scoring (lowercased ok).
	let anchorContext: String
	/// Per-candidate confidence from upstream (e.g. `PriceNormalizer.normalize`).
	let confidence: Double
	/// How many times this same normalized price appears across the page.
	let occurrenceCount: Int
	/// Source label for logs (e.g. `"ocr"`, `"ax"`).
	let source: String
}

// MARK: - Decision

struct AnchoredPriceDecision: Sendable, Equatable {
	let selected: AnchoredPriceCandidate?
	let rejected: [AnchoredPriceCandidate]
	let reason: String
	let allScores: [(candidate: AnchoredPriceCandidate, score: Double, anchorScore: Double, valueScore: Double)]

	/// Manual Equatable (tuple in allScores isn't Equatable by default).
	static func == (lhs: AnchoredPriceDecision, rhs: AnchoredPriceDecision) -> Bool {
		lhs.selected == rhs.selected
			&& lhs.rejected == rhs.rejected
			&& lhs.reason == rhs.reason
			&& lhs.allScores.count == rhs.allScores.count
			&& zip(lhs.allScores, rhs.allScores).allSatisfy {
				$0.0.candidate == $0.1.candidate
				&& $0.0.score == $0.1.score
				&& $0.0.anchorScore == $0.1.anchorScore
				&& $0.0.valueScore == $0.1.valueScore
			}
	}
}

// MARK: - Resolver

/// Phase 4U — AnchoredPriceResolver.
///
/// `PriceNormalizer` validates the shape of a single price string. This
/// resolver picks the *right* price when the page surfaces several candidates.
///
/// Scoring is deterministic:
///   - **anchorScore** (×0.55): proximity to anchor words (`price`, `buy`,
///     `add to cart`, `subtotal`, `total`, `was`, `deal`) in `anchorContext`.
///   - **confidence**  (×0.30): per-candidate confidence from the normalizer.
///   - **valueScore**  (×0.15): higher dollar values get a small boost — tiny
///     UI prices like the `$5.01` shipping fee don't compete with real prices.
///
/// **No website-specific code**: the anchor vocabulary is generic commerce
/// language. The resolver only re-orders inputs; it never invents a price.
enum AnchoredPriceResolver {

	static let priceAnchors: [String] = [
		"price", "buy", "add to cart", "checkout", "subtotal", "total",
		"was", "now", "deal", "list price", "discount", "save", "today only",
	]

	/// Penalty applied to candidates whose raw text decimal value falls below
	/// this floor AND who lack any anchor signal. Stops `$5.01` from beating
	/// a properly-anchored `$29.99`.
	static let smallValueFloor: Double = 10.0

	/// Resolve the strongest candidate from the input set.
	///
	/// Returns the selected candidate (nil if input was empty) + the list of
	/// rejected candidates + the human-readable reason for the choice.
	static func resolve(candidates: [AnchoredPriceCandidate]) -> AnchoredPriceDecision {
		guard !candidates.isEmpty else {
			return AnchoredPriceDecision(
				selected: nil,
				rejected: [],
				reason: "no_candidates",
				allScores: []
			)
		}

		let scored: [(candidate: AnchoredPriceCandidate, score: Double, anchorScore: Double, valueScore: Double)] = candidates.map { c in
			let anchor = anchorScore(for: c)
			let value = valueScore(for: c)
			let base = (anchor * 0.55) + (c.confidence * 0.30) + (value * 0.15)
			// Repeated occurrences (e.g. price appears in summary AND buy box)
			// nudge confidence up slightly.
			let occurrenceBoost = min(0.05, Double(max(0, c.occurrenceCount - 1)) * 0.025)
			let final = max(0.0, min(1.0, base + occurrenceBoost))
			return (c, final, anchor, value)
		}.sorted { $0.score > $1.score }

		let winner = scored.first!
		let losers = scored.dropFirst().map(\.candidate)

		let reason = decisionReason(for: winner, losers: losers, allScores: scored)
		emitLogs(decision: winner, losers: losers, reason: reason)

		return AnchoredPriceDecision(
			selected: winner.candidate,
			rejected: losers,
			reason: reason,
			allScores: scored
		)
	}

	// MARK: - Internals

	private static func anchorScore(for c: AnchoredPriceCandidate) -> Double {
		let lower = c.anchorContext.lowercased()
		var hits = 0
		for anchor in priceAnchors where lower.contains(anchor) {
			hits += 1
			if hits >= 3 { break }
		}
		switch hits {
		case 0: return 0.10
		case 1: return 0.65
		case 2: return 0.85
		default: return 1.00
		}
	}

	private static func valueScore(for c: AnchoredPriceCandidate) -> Double {
		guard let value = numericValue(of: c.rawText) else { return 0.0 }
		if value <= 1.0 { return 0.05 }
		if value < smallValueFloor { return 0.30 }
		if value < 100 { return 0.75 }
		if value < 1000 { return 0.85 }
		return 0.90
	}

	private static func numericValue(of raw: String) -> Double? {
		let stripped = raw.unicodeScalars
			.filter { CharacterSet(charactersIn: "0123456789.").contains($0) }
			.map(String.init)
			.joined()
		return Double(stripped)
	}

	private static func decisionReason(
		for winner: (candidate: AnchoredPriceCandidate, score: Double, anchorScore: Double, valueScore: Double),
		losers: [AnchoredPriceCandidate],
		allScores: [(candidate: AnchoredPriceCandidate, score: Double, anchorScore: Double, valueScore: Double)]
	) -> String {
		guard let runnerUp = allScores.dropFirst().first else {
			return "single_candidate"
		}
		if winner.anchorScore > runnerUp.anchorScore {
			return runnerUp.anchorScore < 0.5 ? "weak_anchor" : "stronger_anchor"
		}
		if winner.candidate.confidence > runnerUp.candidate.confidence {
			return "higher_confidence"
		}
		if winner.valueScore > runnerUp.valueScore {
			return "higher_value_anchor"
		}
		return "tiebreaker_first"
	}

	private static func emitLogs(
		decision: (candidate: AnchoredPriceCandidate, score: Double, anchorScore: Double, valueScore: Double),
		losers: [AnchoredPriceCandidate],
		reason: String
	) {
		let rejectedString = losers.map { "\"\($0.rawText)\"" }.joined(separator: ",")
		print("[PriceResolver] selected=\"\(decision.candidate.rawText)\" rejected=\(rejectedString.isEmpty ? "none" : rejectedString) reason=\(reason)")
		print("[PriceResolver] anchor_score=\(String(format: "%.2f", decision.anchorScore)) confidence=\(String(format: "%.2f", decision.candidate.confidence)) value_score=\(String(format: "%.2f", decision.valueScore))")
	}
}
