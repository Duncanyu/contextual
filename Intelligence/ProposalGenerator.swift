import Foundation

struct ActionProposal: Equatable {
	let title: String
	/// Short input hint for panel/floating (no raw text). Empty when redundant with the title.
	let sourceCaption: String
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
		decision: ReasoningDecision,
		inputSourcePreference: InputSourceChoice
	) -> ActionProposal? {
		guard decision.shouldSurface else { return nil }
		guard let primary = decision.primaryActionId, !primary.isEmpty else { return nil }

		let secondary = decision.rankedActionIds.filter { $0 != primary }
		let channel = resolveCopyChannel(triggerPacket: triggerPacket, inputSourcePreference: inputSourcePreference, context: context)
		let title = titleFor(primaryActionId: primary, channel: channel, triggerType: triggerPacket.triggerType)
		let caption = sourceCaption(for: channel, primaryActionId: primary)

		let proposal = ActionProposal(
			title: title,
			sourceCaption: caption,
			primaryActionId: primary,
			secondaryActionIds: secondary,
			confidence: decision.confidence,
			reason: decision.reason
		)

		let titleHash = String(Self.fnv1a64(title), radix: 16)
		print("[ProposalGenerator] proposal primary=\(primary) confidence=\(decision.confidence) titleHash=\(titleHash)")
		return proposal
	}

	private enum ProposalCopyChannel {
		case selectedText
		case clipboard
		case screenText
		case neutral
	}

	private func resolveCopyChannel(
		triggerPacket: TriggerPacket,
		inputSourcePreference: InputSourceChoice,
		context: ContextModel
	) -> ProposalCopyChannel {
		switch inputSourcePreference {
		case .clipboard:
			return context.clipboardTextAvailable ? .clipboard : .neutral
		case .selectedText:
			return context.selectedTextAvailable ? .selectedText : .neutral
		case .screenOCR:
			return context.screenOCRAvailable ? .screenText : .neutral
		case .automatic:
			break
		}

		switch triggerPacket.triggerType {
		case .clipboardTextEligible:
			return .clipboard
		case .selectedTextEligible:
			return .selectedText
		case .manualInvocation:
			if context.selectedTextAvailable { return .selectedText }
			if context.clipboardTextAvailable { return .clipboard }
			if context.screenOCRAvailable { return .screenText }
			return .neutral
		}
	}

	private func sourceCaption(for channel: ProposalCopyChannel, primaryActionId: String) -> String {
		if primaryActionId == "analyze_screen" {
			return "Using screen text"
		}
		switch channel {
		case .selectedText:
			return "Using selected text"
		case .clipboard:
			return "Using clipboard"
		case .screenText:
			return "Using screen text"
		case .neutral:
			return ""
		}
	}

	private func titleFor(primaryActionId: String, channel: ProposalCopyChannel, triggerType: TriggerType) -> String {
		if primaryActionId == "analyze_screen" {
			return "Want to analyze what's on screen?"
		}

		switch channel {
		case .neutral:
			switch triggerType {
			case .manualInvocation:
				return "What would you like to do with this?"
			default:
				return "Want help with this?"
			}

		case .selectedText:
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

		case .clipboard:
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

		case .screenText:
			switch primaryActionId {
			case "summarize_text":
				return "Want a quick summary of this screen text?"
			case "explain_text":
				return "Want help understanding this screen text?"
			case "rewrite_text":
				return "Want me to clean up this screen text?"
			default:
				return "Want help with this screen text?"
			}
		}
	}

	private static func fnv1a64(_ text: String) -> UInt64 {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for b in text.utf8 {
			hash ^= UInt64(b)
			hash &*= 1_099_511_628_211
		}
		return hash
	}
}

