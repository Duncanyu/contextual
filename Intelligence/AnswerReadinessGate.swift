import Foundation

public struct AnswerReadinessGate: Sendable {
	
	public static func shouldAllowAnswer(
		interactionAttempts: Int,
		explorationScore: Double,
		unexploredActionableControlsCount: Int,
		hasUnexploredScroll: Bool
	) -> (allowed: Bool, reason: String) {
		
		// If we have unexplored actionable controls, and interactionAttempts is 0, we MUST block.
		if unexploredActionableControlsCount > 0 && interactionAttempts < 1 {
			let reason = "interaction_required"
			print("[AnswerGate] blocked reason=\(reason)")
			return (false, reason)
		}
		
		// If we have scrollable content that is unexplored, and interactionAttempts is 0, block.
		if hasUnexploredScroll && interactionAttempts < 1 {
			let reason = "interaction_required"
			print("[AnswerGate] blocked reason=\(reason)")
			return (false, reason)
		}
		
		let reason = "sufficient_exploration"
		print("[AnswerGate] allowed reason=\(reason)")
		return (true, reason)
	}
}
