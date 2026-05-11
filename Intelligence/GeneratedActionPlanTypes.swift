import Foundation

/// Which composition template produced the plan (metadata-only codes).
enum PrimitiveCompositionRule: String, Hashable, Sendable, Codable, CaseIterable {
	case singlePrimitive = "single_primitive"
	case summarizeThenExtract = "summarize_then_extract"
	case compareThenExplain = "compare_then_explain"
	case structureThenSummarize = "structure_then_summarize"
	case classifyThenExtract = "classify_then_extract"
	case reviewThenExplain = "review_then_explain"
	case extractThenChecklist = "extract_then_checklist"
	case draftThenReview = "draft_then_review"
	case classifyThenExplain = "classify_then_explain"
	case draftThenExplain = "draft_then_explain"
	case compareThenClassify = "compare_then_classify"
}

/// Coarse data-flow roles between steps (no payloads).
enum PlanDataRole: String, Hashable, Sendable, Codable, CaseIterable {
	case sourceContext = "source_context"
	case summary = "summary"
	case structuredOutline = "structured_outline"
	case classification = "classification"
	case extractedItems = "extracted_items"
	case checklistItems = "checklist_items"
	case comparison = "comparison"
	case reviewNotes = "review_notes"
	case explanation = "explanation"
	case draftText = "draft_text"
	case intermediate = "intermediate"
}

/// Result of plan validation / construction (in-memory only).
enum GeneratedActionPlanValidationResult: Equatable, Sendable {
	case accepted(GeneratedActionPlan)
	case rejected(reasonCodes: [String])
	case skipped(reason: String)
}

/// One ordered step in a non-executable composition (metadata only).
struct GeneratedActionPlanStep: Equatable, Sendable, Identifiable {
	let stableId: UUID
	let stepIndex: Int
	let primitive: GeneratedActionPrimitive
	let purpose: String
	let inputRole: PlanDataRole
	let outputRole: PlanDataRole
	let dependsOnStepIndexes: [Int]
	let confidence: Double
	let safetyNotes: String

	var id: UUID { stableId }

	init(
		stableId: UUID = UUID(),
		stepIndex: Int,
		primitive: GeneratedActionPrimitive,
		purpose: String,
		inputRole: PlanDataRole,
		outputRole: PlanDataRole,
		dependsOnStepIndexes: [Int],
		confidence: Double,
		safetyNotes: String
	) {
		self.stableId = stableId
		self.stepIndex = stepIndex
		self.primitive = primitive
		self.purpose = purpose
		self.inputRole = inputRole
		self.outputRole = outputRole
		self.dependsOnStepIndexes = dependsOnStepIndexes
		self.confidence = min(1.0, max(0.0, confidence))
		self.safetyNotes = safetyNotes
	}
}

/// Bounded, non-executable composition over safe primitives (T15.5).
struct GeneratedActionPlan: Equatable, Sendable, Identifiable {
	let id: UUID
	let generatedActionId: UUID
	let intentType: SynthesizedIntentType
	let workflow: InferredWorkflow
	let steps: [GeneratedActionPlanStep]
	let confidence: Double
	let requiredContext: [GeneratedActionRequiredContext]
	let createdAt: Date
	let expiresAt: Date
	let isStale: Bool
	let sourceReasonCodes: [String]
	let safetyProfile: GeneratedActionSafetyProfile
	let explanation: String
	/// Always false in this phase — plans are data-only.
	let isExecutable: Bool
	let compositionRule: PrimitiveCompositionRule
}
