import Foundation

struct RankedProposalDecision: Equatable, Sendable {
	let primaryActionId: String
	let secondaryActionIds: [String]
	let scores: [ActionRelevanceScore]
	let topScore: Double
	let reason: String
	let tieResolved: Bool
}

enum ProposalRanker {
	/// Ranks actions into one primary + secondary list for proposals.
	/// - Parameters:
	///   - reasoningPrimary: the current ReasoningEngine primary (used for tie resolution if applicable)
	static func rank(
		relevance: [ActionRelevanceScore],
		reasoningPrimary: String?
	) -> RankedProposalDecision? {
		guard !relevance.isEmpty else { return nil }

		let sorted = relevance.sorted { a, b in
			if a.score != b.score { return a.score > b.score }
			return a.actionId < b.actionId
		}
		guard let top = sorted.first else { return nil }

		var primary = top.actionId
		var tieResolved = false

		if sorted.count >= 2 {
			let second = sorted[1]
			if abs(top.score - second.score) <= 0.05 {
				let tied = Set([top.actionId, second.actionId])
				if let rp = reasoningPrimary, tied.contains(rp) {
					primary = rp
					tieResolved = true
				} else if !DynamicOnlyProposalMode.isEnabled {
					let preferred = ["explain_text", "summarize_text", "rewrite_text"]
					if let picked = preferred.first(where: { tied.contains($0) }) {
						primary = picked
						tieResolved = true
					}
				}
			}
		}

		let secondary = sorted.map(\.actionId).filter { $0 != primary }
		let topScore = sorted.first(where: { $0.actionId == primary })?.score ?? top.score
		let reason = tieResolved ? "tie" : "top"
		return RankedProposalDecision(
			primaryActionId: primary,
			secondaryActionIds: secondary,
			scores: sorted,
			topScore: topScore,
			reason: reason,
			tieResolved: tieResolved
		)
	}
}

