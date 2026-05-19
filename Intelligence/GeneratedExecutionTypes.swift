import Foundation

// MARK: - Bounded execution primitives (closed set; no arbitrary operations)

/// Safe, deterministic execution primitive codes for Phase 17 plans (data-only; not invoked in T17.1).
enum ExecutionPrimitive: String, Hashable, Sendable, Codable, CaseIterable {
	case summarizeContext = "summarize_context"
	case explainError = "explain_error"
	case compareContexts = "compare_contexts"
	case extractActionItems = "extract_action_items"
	case generateChecklist = "generate_checklist"
	case organizeInformation = "organize_information"
	case generateStudyNotes = "generate_study_notes"
	case synthesizeResearchSummary = "synthesize_research_summary"
	case answerFromContext = "answer_from_context"
	case classifyWorkflow = "classify_workflow"
	case structureNotes = "structure_notes"
}

/// Explicit lifecycle states for future bounded execution runtime (metadata-only in T17.1).
enum ExecutionState: String, Hashable, Sendable, Codable, CaseIterable {
	case idle
	case validating
	case gatheringContext = "gathering_context"
	case executing
	case synthesizingResult = "synthesizing_result"
	case completed
	case failed
	case cancelled
	case timedOut = "timed_out"
}

/// Workflow category carried on executable generated actions (codes only).
enum WorkflowType: String, Hashable, Sendable, Codable, CaseIterable {
	case debugging
	case writing
	case research
	case browsing
	case editing
	case reviewing
	case studying
	case comparing
	case organizing
	case unknown
}

/// Execution intent category (distinct from `SynthesizedIntentType`; maps in later tickets).
enum IntentType: String, Hashable, Sendable, Codable, CaseIterable {
	case summarize
	case explain
	case compare
	case extract
	case organize
	case classify
	case answer
	case synthesize
	case review
	case structure
	case unknown
}

/// Coarse context prerequisites for executable actions (never raw payloads).
enum ContextRequirementType: String, Hashable, Sendable, Codable, CaseIterable {
	case textSnippet = "text_snippet"
	case selectedText = "selected_text"
	case fusedVisual = "fused_visual"
	case screenCapture = "screen_capture"
	case multiSource = "multi_source"
	case workflowContext = "workflow_context"
	case errorContext = "error_context"
	case notesContext = "notes_context"
	case none
}

/// Permission codes required before execution may proceed (validated in future runtime).
enum PermissionRequirement: String, Hashable, Sendable, Codable, CaseIterable {
	case accessibility
	case screenRecording = "screen_recording"
	case clipboard
	case automation
	case none
}

/// How a plan should degrade when inputs or budget are insufficient (deterministic codes only).
enum ExecutionFallbackBehavior: String, Hashable, Sendable, Codable, CaseIterable {
	case failFast = "fail_fast"
	case degradeToSummary = "degrade_to_summary"
	case requestMoreContext = "request_more_context"
	case skipVision = "skip_vision"
	case cancel
}

/// Relative priority when applying adaptive execution budgets.
enum BudgetPriority: String, Hashable, Sendable, Codable, CaseIterable {
	case low
	case normal
	case high
	case userInitiated = "user_initiated"
}

/// Terminal and in-flight result status for execution output records.
enum ExecutionResultStatus: String, Hashable, Sendable, Codable, CaseIterable {
	case pending
	case success
	case partialSuccess = "partial_success"
	case failed
	case cancelled
	case timedOut = "timed_out"
}

/// Provenance of a generated execution action (metadata-only).
enum GenerationSource: String, Hashable, Sendable, Codable, CaseIterable {
	case synthesizedIntent = "synthesized_intent"
	case generatedAction = "generated_action"
	case userRequested = "user_requested"
	case reuseCache = "reuse_cache"
	case selfTest = "self_test"
}

/// Hard caps for plan composition — enforced by future builders, documented here for reviewability.
enum GeneratedExecutionBounds {
	static let maxPrimitivesPerPlan = 6
	static let maxRequiredContextTypes = 8
	static let maxFollowUpSuggestions = 5
}
