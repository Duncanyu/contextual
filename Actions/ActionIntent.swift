import Foundation

enum ActionIntentKind: Sendable, Equatable {
	case summarize
	case explain
	case rewrite
	case analyzeScreen
	case generated
}

struct ActionIntent: Sendable, Equatable {
	let kind: ActionIntentKind
	let actionId: String
	let title: String
	/// Short origin label (e.g. "builtin", "generated"). Not user text.
	let source: String
	let isGenerated: Bool
}

enum ActionIntentRegistry {
	static func intent(for actionId: String) -> ActionIntent? {
		switch actionId {
		case SummarizeAction.summarizeTextId:
			return ActionIntent(kind: .summarize, actionId: actionId, title: "Summarize", source: "builtin", isGenerated: false)
		case ExplainAction.explainTextId:
			return ActionIntent(kind: .explain, actionId: actionId, title: "Explain", source: "builtin", isGenerated: false)
		case RewriteAction.rewriteTextId:
			return ActionIntent(kind: .rewrite, actionId: actionId, title: "Rewrite", source: "builtin", isGenerated: false)
		case ScreenAnalyzeAction.analyzeScreenId:
			return ActionIntent(kind: .analyzeScreen, actionId: actionId, title: "Analyze Screen", source: "builtin", isGenerated: false)
		default:
			return nil
		}
	}

	static func title(for actionId: String) -> String? {
		intent(for: actionId)?.title
	}
}

