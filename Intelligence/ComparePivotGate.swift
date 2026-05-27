import Foundation

// MARK: - Decision

/// Outcome of a single `ComparePivotGate` evaluation.
struct ComparePivotDecision: Sendable, Equatable {
	/// True when the goal should be repaired from "compare" to a single-item
	/// goal family (extract / inspect / summarize).
	let shouldPivot: Bool
	/// Replacement goal text when `shouldPivot=true`; same as input otherwise.
	let repairedGoal: String
	/// Typed reason. Always one of:
	///   `keep_compare_two_or_more_live_candidates`
	///   `pivot_compare_to_extract_single_product`
	///   `pivot_compare_to_extract_no_live_candidates`
	///   `not_a_compare_goal`
	let reason: String
	/// New family the goal should be classified under once repaired.
	/// `compare` when no pivot; otherwise `extract`.
	let pivotedFamily: String
}

// MARK: - Gate

/// Phase 4U — ComparePivotGate.
///
/// A compare goal only makes sense when at least two distinct live grounded
/// product candidates exist on the current page. The dogfood failure mode is:
///
///   1. Planner emits "Compare Anker Prime …" against a single-product page.
///   2. Evidence requirements add `comparison_candidate` (required minCount 2).
///   3. Runtime burns its control budget hunting a non-existent second product
///      and presents a partial / incoherent result.
///
/// This pure gate runs both at planner-acceptance time (via
/// `AgenticGoalAlignmentValidator`) and at runtime pivot time (when the
/// evidence assessor reports `history_only` after the first observation).
///
/// **No website-specific rules. No hardcoded titles.**
enum ComparePivotGate {

	/// Minimum number of distinct live grounded product candidates required to
	/// keep a `compare` goal. Browsing-history-only candidates do NOT count
	/// — the caller passes only live grounded counts.
	static let minLiveCandidates: Int = 2

	/// Verbs recognized as "compare family" in a goal string. Generic; never
	/// expanded with site-specific vocabulary.
	private static let compareVerbs: [String] = [
		"compare", "comparison", "versus", " vs ", "vs.", "compare ",
	]

	/// Verbs recognized as already-extract family (in case the planner emits a
	/// hybrid like "Compare and extract …").
	private static let extractVerbs: [String] = [
		"extract", "inspect", "summarize", "summarise", "identify", "describe",
	]

	// MARK: - Evaluate

	/// Decide whether a goal should pivot from compare → extract based on the
	/// number of distinct *live* grounded product candidates on the current page.
	///
	/// `liveGroundedCandidateCount` is the count of distinct product titles
	/// that appear in OCR / AX / screen graph entities — NOT browsing-history
	/// observations. The caller is responsible for filtering those out.
	static func evaluate(
		goal: String,
		liveGroundedCandidateCount: Int
	) -> ComparePivotDecision {
		let lower = goal.lowercased()
		let isCompare = compareVerbs.contains(where: { lower.contains($0.trimmingCharacters(in: .whitespaces)) })
		guard isCompare else {
			return ComparePivotDecision(
				shouldPivot: false,
				repairedGoal: goal,
				reason: "not_a_compare_goal",
				pivotedFamily: "compare"
			)
		}

		if liveGroundedCandidateCount >= minLiveCandidates {
			return ComparePivotDecision(
				shouldPivot: false,
				repairedGoal: goal,
				reason: "keep_compare_two_or_more_live_candidates",
				pivotedFamily: "compare"
			)
		}

		let repaired = repairGoal(originalGoal: goal)
		let reason: String = liveGroundedCandidateCount == 1
			? "pivot_compare_to_extract_single_product"
			: "pivot_compare_to_extract_no_live_candidates"
		return ComparePivotDecision(
			shouldPivot: true,
			repairedGoal: repaired,
			reason: reason,
			pivotedFamily: "extract"
		)
	}

	// MARK: - Logging

	/// Standard `[AgenticPivot]` log emission. Caller decides when to call.
	static func log(decision: ComparePivotDecision) {
		guard decision.shouldPivot else { return }
		print("[AgenticPivot] compare_to_extract reason=no_live_comparison_candidate detail=\(decision.reason)")
		print("[AgenticPivot] repaired_goal=\"\(decision.repairedGoal.prefix(100))\"")
	}

	// MARK: - Internals

	/// Replace the compare verb in the original goal with an extract verb,
	/// preserving the noun phrase. We don't manufacture a new title — we
	/// transform what the planner already wrote.
	///
	/// Examples:
	///   "Compare Anker Prime USB C Charger"
	///     → "Extract Anker Prime USB C Charger details"
	///   "Compare laptop chargers vs. desktop chargers"
	///     → "Extract laptop chargers details"
	///   "Anker vs Belkin comparison"
	///     → "Extract Anker details"  (best-effort — pre-vs noun kept)
	static func repairGoal(originalGoal: String) -> String {
		let trimmed = originalGoal.trimmingCharacters(in: .whitespacesAndNewlines)
		// If already extract-family, return as-is.
		let lower = trimmed.lowercased()
		if extractVerbs.contains(where: { lower.contains($0) }) {
			return trimmed
		}

		// Try to find the noun phrase by stripping the compare verb prefix.
		let prefixes: [(verb: String, drop: Int)] = [
			("compare ", "compare ".count),
			("comparison of ", "comparison of ".count),
			("comparison ", "comparison ".count),
		]
		var noun: String?
		for (verb, drop) in prefixes {
			if lower.hasPrefix(verb) {
				let index = trimmed.index(trimmed.startIndex, offsetBy: drop)
				noun = String(trimmed[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
				break
			}
		}

		// Drop a trailing " vs <…>" or " versus <…>" clause if present.
		if let n = noun {
			let cleaned = stripVersusClause(n)
			noun = cleaned
		} else {
			// No clean compare prefix — try splitting on " vs " in the original.
			noun = stripVersusClause(trimmed)
		}

		let nounPhrase = (noun?.isEmpty == false ? noun! : trimmed)
		// We never *add* template wording beyond a single "details" hint —
		// the runtime treats the result as a free-form goal string.
		return "Extract \(nounPhrase) details"
	}

	/// Repair a compare-family *title* into an extract-family title.
	///
	/// This is a minimal verb-family transform (compare → extract) and never
	/// manufactures a new topic/entity.
	static func repairTitle(originalTitle: String) -> String {
		let trimmed = originalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		let lower = trimmed.lowercased()
		let isCompare = compareVerbs.contains(where: { lower.contains($0.trimmingCharacters(in: .whitespaces)) })
		guard isCompare else { return trimmed }
		return repairGoal(originalGoal: trimmed)
	}

	private static func stripVersusClause(_ text: String) -> String {
		let separators = [" vs ", " vs. ", " versus "]
		var current = text
		for sep in separators {
			if let range = current.lowercased().range(of: sep) {
				let index = current.index(current.startIndex, offsetBy: current.distance(from: current.startIndex, to: range.lowerBound))
				current = String(current[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
			}
		}
		return current
	}
}
