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

/// Tunable thresholds for intent suppression (deterministic, bounded, in-memory only).
struct IntentSuppressionProfile: Equatable, Sendable {
	var minConfidenceAuto: Double = 0.52
	var minConfidenceManual: Double = 0.45
	var minConfidenceStaleWorkflowAuto: Double = 0.60
	var minConfidenceStaleWorkflowManual: Double = 0.52
	var weakMultimodalFusionMax: Double = 0.48
	var weakMultimodalConflictMin: Double = 0.55
	var weakMultimodalMinConfidenceAuto: Double = 0.53
	var weakMultimodalMinConfidenceManual: Double = 0.46
	var browsingFusionMax: Double = 0.52
	var browsingFreshnessMax: Double = 0.48
	var browsingMinConfidence: Double = 0.58
	var browsingSummarizeMinConfidence: Double = 0.56
	var interactionBurstMinConfidence: Double = 0.64
	var interactionBurstMinConfidenceManual: Double = 0.58
	var repeatWindowAuto: TimeInterval = 42
	var repeatWindowManual: TimeInterval = 30
	var ringCapacity: Int = 56
}

enum IntentSuppressionReason: String, Hashable, Sendable, CaseIterable {
	case lowConfidence = "low_confidence"
	case repeatedIntent = "repeated_intent"
	case activeInteractionBurst = "active_interaction"
	case staleWorkflow = "stale_workflow"
	case staleIntent = "stale_intent"
	case weakMultimodalAgreement = "weak_multimodal"
	case weakBrowsingContext = "weak_browsing"
}

struct IntentSuppressionEntry: Equatable, Sendable {
	let intentType: SynthesizedIntentType
	let reason: IntentSuppressionReason
}

struct IntentSuppressionDecision: Equatable, Sendable {
	let rawIntents: [SynthesizedIntent]
	let allowed: [SynthesizedIntent]
	/// Metadata-only: intent type + suppression reason (no raw text).
	let suppressed: [IntentSuppressionEntry]
	let reasonCodes: [IntentSuppressionReason]
}

/// Bounded, temporary synthesis output (in-memory only).
struct IntentSynthesisResult: Equatable, Sendable {
	let intents: [SynthesizedIntent]
	let suppressedReason: String?
	let skippedReason: String?
	let synthesizedAt: Date
	/// Present when post-synthesis suppression ran on a non-empty intent list.
	let suppression: IntentSuppressionDecision?

	init(
		intents: [SynthesizedIntent],
		suppressedReason: String?,
		skippedReason: String?,
		synthesizedAt: Date,
		suppression: IntentSuppressionDecision? = nil
	) {
		self.intents = intents
		self.suppressedReason = suppressedReason
		self.skippedReason = skippedReason
		self.synthesizedAt = synthesizedAt
		self.suppression = suppression
	}

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
