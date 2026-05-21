import Foundation

/// Fast deterministic dynamic action contract (no live large-model proposal generation).
///
/// This is produced by a composer (typically model-driven task inference + hook mapping) and then
/// converted into a `ValidatedDynamicGeneratedProposal` for the existing proposal activation pipeline.
struct DynamicGeneratedActionContract: Sendable, Equatable {
	let id: String
	let title: String
	let userFacingQuestion: String
	let inferredUserGoal: String
	let situationSummary: String
	let whyNow: String
	let hookPlanIds: [String]
	let requiredContext: [ContextRequirementType]
	let confidence: Double
	let createdAt: Date
	let expiresAt: Date
	let cacheEligibility: Bool
	let cacheKey: String
}

struct HookComposedProposal: Sendable, Equatable {
	let contract: DynamicGeneratedActionContract
	let proposal: ValidatedDynamicGeneratedProposal
}

