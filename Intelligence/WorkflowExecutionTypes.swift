import Foundation

/// How synthesized execution results are grouped (deterministic templates only).
enum ResultCompositionStyle: String, Hashable, Sendable, Codable, CaseIterable {
	case linear
	case debuggingReport = "debugging_report"
	case researchBrief = "research_brief"
	case writingOutline = "writing_outline"
	case studyNotes = "study_notes"
	case reviewSummary = "review_summary"
}

/// Explainability tone for workflow-shaped execution (metadata codes).
enum WorkflowExplanationStyle: String, Hashable, Sendable, Codable, CaseIterable {
	case concise
	case diagnostic
	case analytical
	case instructional
}

/// Static execution preferences for a workflow category (no runtime behavior).
struct WorkflowExecutionProfile: Equatable, Sendable, Codable {
	let workflowType: WorkflowType
	let preferredIntentTypes: [IntentType]
	let preferredPrimitives: [ExecutionPrimitive]
	let avoidedPrimitives: [ExecutionPrimitive]
	let resultCompositionStyle: ResultCompositionStyle
	let confidenceMultiplier: Double
	let interruptionCostAdjustment: Double
	let defaultBudgetPriority: BudgetPriority
	let requiresFreshContext: Bool
	let allowsContextExpansion: Bool
	let explanationStyle: WorkflowExplanationStyle

	init(
		workflowType: WorkflowType,
		preferredIntentTypes: [IntentType],
		preferredPrimitives: [ExecutionPrimitive],
		avoidedPrimitives: [ExecutionPrimitive],
		resultCompositionStyle: ResultCompositionStyle,
		confidenceMultiplier: Double,
		interruptionCostAdjustment: Double,
		defaultBudgetPriority: BudgetPriority,
		requiresFreshContext: Bool,
		allowsContextExpansion: Bool,
		explanationStyle: WorkflowExplanationStyle
	) {
		self.workflowType = workflowType
		self.preferredIntentTypes = preferredIntentTypes
		self.preferredPrimitives = preferredPrimitives
		self.avoidedPrimitives = avoidedPrimitives
		self.resultCompositionStyle = resultCompositionStyle
		self.confidenceMultiplier = min(1.15, max(0.75, confidenceMultiplier))
		self.interruptionCostAdjustment = min(0.2, max(-0.2, interruptionCostAdjustment))
		self.defaultBudgetPriority = defaultBudgetPriority
		self.requiresFreshContext = requiresFreshContext
		self.allowsContextExpansion = allowsContextExpansion
		self.explanationStyle = explanationStyle
	}
}

/// Output of workflow plan shaping (data-only).
struct WorkflowExecutionPlanResult: Equatable, Sendable {
	let plan: ExecutionPlan
	let profile: WorkflowExecutionProfile
	let planningWarnings: [String]
	let usedFallback: Bool
	let shapedConfidence: Double
	let compositionStyle: ResultCompositionStyle
}
