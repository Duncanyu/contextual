import Foundation

/// Thin adapter between Phase 15–16 workflow/intent types and Phase 17 execution types.
enum WorkflowExecutionMapper {

	static func workflowType(from inferred: InferredWorkflow) -> WorkflowType {
		switch inferred {
		case .debugging: .debugging
		case .writing: .writing
		case .research: .research
		case .browsing: .browsing
		case .editing: .editing
		case .reviewing: .reviewing
		case .unknown: .unknown
		}
	}

	static func workflowType(fromRaw raw: String) -> WorkflowType {
		if let wf = InferredWorkflow(rawValue: raw) {
			return workflowType(from: wf)
		}
		return WorkflowType(rawValue: raw) ?? .unknown
	}

	static func intentType(from synthesized: SynthesizedIntentType) -> IntentType {
		switch synthesized {
		case .explainLikelyError, .identifyPossibleBugSource, .explainApiResponse, .explainScreenContext:
			.explain
		case .summarizeCurrentArticle, .summarizeCodeChange:
			.summarize
		case .extractActionItems, .turnNotesIntoChecklist:
			.extract
		case .compareSelectedSnippets:
			.compare
		case .draftReply:
			.synthesize
		case .reviewSelectedText:
			.review
		case .unknown:
			.unknown
		}
	}

	static func intentType(fromRaw raw: String) -> IntentType {
		if let it = SynthesizedIntentType(rawValue: raw) {
			return intentType(from: it)
		}
		return IntentType(rawValue: raw) ?? .unknown
	}
}
