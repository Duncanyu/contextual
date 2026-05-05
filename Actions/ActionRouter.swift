import Foundation

/// Maps trigger `candidateActions` identifiers to action instances. Does not execute.
struct ActionRouter {
	func matchingActions(for packet: TriggerPacket) -> [any ActionProtocol] {
		var result: [any ActionProtocol] = []
		for raw in packet.candidateActions {
			switch raw {
			case SummarizeAction.summarizeTextId:
				result.append(SummarizeAction())
			case ExplainAction.explainTextId:
				result.append(ExplainAction())
			case RewriteAction.rewriteTextId:
				result.append(RewriteAction())
			default:
				break
			}
		}
		return result
	}
}
