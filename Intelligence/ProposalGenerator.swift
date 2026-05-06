import Foundation

struct ActionProposal: Equatable {
	let title: String
	let primaryActionId: String
	let secondaryActionIds: [String]
	let confidence: Double
	let reason: String
}

final class ProposalGenerator {
	static let shared = ProposalGenerator()
	private init() {}

	func generate(
		context: ContextModel,
		triggerPacket: TriggerPacket,
		decision: ReasoningDecision
	) -> ActionProposal? {
		_ = context

		guard decision.shouldSurface else { return nil }
		guard let primary = decision.primaryActionId, !primary.isEmpty else { return nil }

		let secondary = decision.rankedActionIds.filter { $0 != primary }
		let title = titleFor(triggerPacket: triggerPacket, primaryActionId: primary)

		let proposal = ActionProposal(
			title: title,
			primaryActionId: primary,
			secondaryActionIds: secondary,
			confidence: decision.confidence,
			reason: decision.reason
		)

		print("[ProposalGenerator] proposal primary=\(primary) confidence=\(decision.confidence) title=\"\(title)\"")
		return proposal
	}

	private func titleFor(triggerPacket: TriggerPacket, primaryActionId: String) -> String {
		switch triggerPacket.triggerType {
		case .manualInvocation:
			return "What would you like to do with this?"

		case .selectedTextEligible:
			switch primaryActionId {
			case "summarize_text":
				return "Want me to summarize this selected text?"
			case "explain_text":
				return "Want me to explain this selected text?"
			case "rewrite_text":
				return "Want me to rewrite this selected text?"
			default:
				return "Want help with this?"
			}

		case .clipboardTextEligible:
			switch primaryActionId {
			case "summarize_text":
				return "Want a quick summary of what you copied?"
			case "explain_text":
				return "Want help understanding what you copied?"
			case "rewrite_text":
				return "Want me to clean up what you copied?"
			default:
				return "Want help with this?"
			}
		}
	}
}

