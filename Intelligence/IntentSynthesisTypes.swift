import Foundation

/// Non-executable conceptual assistance labels (metadata-only; no tool/code execution).
enum SynthesizedIntentType: String, Hashable, Sendable, Codable, CaseIterable {
	case explainLikelyError = "explain_likely_error"
	case summarizeCurrentArticle = "summarize_current_article"
	case extractActionItems = "extract_action_items"
	case identifyPossibleBugSource = "identify_possible_bug_source"
	case summarizeCodeChange = "summarize_code_change"
	case explainApiResponse = "explain_api_response"
	case turnNotesIntoChecklist = "turn_notes_into_checklist"
	case compareSelectedSnippets = "compare_selected_snippets"
	case draftReply = "draft_reply"
	case reviewSelectedText = "review_selected_text"
	case explainScreenContext = "explain_screen_context"
	case unknown = "unknown"
}

/// Coarse context prerequisites (codes only; never raw payloads).
enum IntentRequiredContext: String, Hashable, Sendable, Codable, CaseIterable {
	case textSnippet = "text_snippet"
	case fusedVisual = "fused_visual"
	case screenCapture = "screen_capture"
	case multiSource = "multi_source"
	case none = "none"
}

/// Inputs for one synthesis pass (all optional except reference paths through fused/inference).
struct IntentSynthesisRequest: Equatable, Sendable {
	let workflowInference: WorkflowInferenceResult?
	let sessionState: ContextualSessionState?
	let fused: FusedContextPacket?
	let features: ContextFeatures?
	let candidateActionIds: [String]
	let triggerType: TriggerType?
	let lastSourceTrigger: String?
}

/// Bounded, temporary synthesis output (in-memory only).
struct IntentSynthesisResult: Equatable, Sendable {
	let intents: [SynthesizedIntent]
	let suppressedReason: String?
	let skippedReason: String?
	let synthesizedAt: Date

	var topIntentType: SynthesizedIntentType? {
		intents.max(by: { $0.confidence < $1.confidence })?.type
	}

	var topConfidence: Double {
		intents.map(\.confidence).max() ?? 0
	}
}

/// One scored, human-readable intent concept (titles/descriptions are fixed templates).
struct SynthesizedIntent: Equatable, Sendable, Identifiable {
	let id: UUID
	let type: SynthesizedIntentType
	let title: String
	let description: String
	let confidence: Double
	let workflow: InferredWorkflow
	let requiredContext: [IntentRequiredContext]
	let supportingSignals: [String]
	let interruptionCost: Double
	let freshness: Double
	let createdAt: Date
	let isStale: Bool
	let sourceReasonCodes: [String]
}
