import Foundation

/// Maps validated LLM proposals into execution proposal candidates (T18.3.1).
enum DynamicGeneratedProposalCandidateMapper {

	static func candidates(
		from result: DynamicGeneratedProposalResult,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		budget: ExecutionBudget,
		referenceTime: Date = Date()
	) -> [GeneratedExecutionProposalCandidate] {
		guard result.shouldChimeIn else { return [] }

		return result.proposals.compactMap { proposal in
			mapCandidate(
				proposal: proposal,
				snapshot: snapshot,
				budget: budget,
				requiresVisual: result.requiresVisualContext,
				referenceTime: referenceTime
			)
		}
	}

	private static func mapCandidate(
		proposal: ValidatedDynamicGeneratedProposal,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		budget: ExecutionBudget,
		requiresVisual: Bool,
		referenceTime: Date
	) -> GeneratedExecutionProposalCandidate? {
		let primitives = proposal.suggestedPrimitives
		guard !primitives.isEmpty else { return nil }

		let requiresVision = requiresVisual
			|| proposal.requiredContextTypes.contains(.fusedVisual)
			|| proposal.requiredContextTypes.contains(.screenCapture)
		let requiresOCR = proposal.requiredContextTypes.contains(.screenCapture)

		let plan = ExecutionPlan(
			primitives: primitives,
			estimatedCost: 0.28 + Double(primitives.count) * 0.07,
			estimatedRuntime: TimeInterval(10 + primitives.count * 7),
			requiresVision: requiresVision,
			requiresOCR: requiresOCR,
			requiresUserIntent: true,
			requiredPermissions: requiresVision || requiresOCR ? [.screenRecording] : [.none],
			fallbackBehavior: .degradeToSummary,
			executionBudget: budget,
			planConfidence: proposal.confidence
		)

		let explainability = "llm_dynamic|\(proposal.usefulnessHint)|primitives=\(primitives.map(\.rawValue).joined(separator: ","))"

		let execution = GeneratedExecutionAction(
			title: proposal.title,
			description: proposal.description,
			workflowType: proposal.workflowType,
			intentType: proposal.intentType,
			confidence: proposal.confidence,
			interruptionCost: proposal.interruptionCost,
			requiredContextTypes: proposal.requiredContextTypes,
			executionPlan: plan,
			explainabilitySummary: explainability,
			generationSource: .generatedAction,
			createdAt: referenceTime,
			expirationDate: referenceTime.addingTimeInterval(180),
			isReusable: false,
			reuseScore: snapshot.workflowConfidence
		)

		return GeneratedExecutionProposalCandidate(
			id: proposal.id,
			title: proposal.title,
			description: proposal.description,
			source: .generatedExecution,
			workflowType: proposal.workflowType,
			intentType: proposal.intentType,
			confidence: proposal.confidence,
			interruptionCost: proposal.interruptionCost,
			explainabilitySummary: explainability,
			expectedOutputSummary: proposal.expectedOutcome,
			requiredContextTypes: proposal.requiredContextTypes,
			executionAction: execution,
			generatedActionId: nil,
			primitiveSignature: primitives.map(\.rawValue).joined(separator: ","),
			isExecutableGeneratedProposal: true
		)
	}
}
