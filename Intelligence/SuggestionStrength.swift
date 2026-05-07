import Foundation

enum SuggestionStrength: String, Sendable {
	case weak
	case medium
	case strong
}

struct SuggestionStrengthResult: Equatable, Sendable {
	let strength: SuggestionStrength
	let score: Double
	let reason: String
}

enum SuggestionStrengthEvaluator {
	static func evaluate(
		proposal: ActionProposal,
		ranking: RankedProposalDecision,
		contextType: ContextType,
		features: ContextFeatures
	) -> SuggestionStrengthResult {
		let top = ranking.topScore

		let meaningful = features.textLength >= 100
			|| features.isLikelyLog
			|| features.isLikelyCode
			|| features.hasQuestion
			|| features.lineCount >= 3

		if top >= 0.75,
		   proposal.confidence >= 0.75,
		   contextType != .random,
		   meaningful
		{
			return SuggestionStrengthResult(strength: .strong, score: top, reason: "top>=0.75_conf>=0.75_meaningful")
		}

		if top >= 0.50, contextType != .random {
			return SuggestionStrengthResult(strength: .medium, score: top, reason: "top>=0.50_nonrandom")
		}

		return SuggestionStrengthResult(strength: .weak, score: top, reason: "weak")
	}
}

