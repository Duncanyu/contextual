import Foundation

/// Deterministic workflow execution profiles (static; no live context).
enum WorkflowExecutionProfileProvider {

	static func profile(for workflowType: WorkflowType) -> WorkflowExecutionProfile {
		switch workflowType {
		case .debugging:
			return WorkflowExecutionProfile(
				workflowType: .debugging,
				preferredIntentTypes: [.explain, .answer],
				preferredPrimitives: [.explainError, .answerFromContext, .generateChecklist, .summarizeContext],
				avoidedPrimitives: [.generateStudyNotes, .synthesizeResearchSummary],
				resultCompositionStyle: .debuggingReport,
				confidenceMultiplier: 1.05,
				interruptionCostAdjustment: 0.05,
				defaultBudgetPriority: .high,
				requiresFreshContext: true,
				allowsContextExpansion: false,
				explanationStyle: .diagnostic
			)
		case .research:
			return WorkflowExecutionProfile(
				workflowType: .research,
				preferredIntentTypes: [.summarize, .compare, .extract],
				preferredPrimitives: [
					.summarizeContext, .extractActionItems, .answerFromContext,
					.compareContexts, .synthesizeResearchSummary,
				],
				avoidedPrimitives: [.explainError],
				resultCompositionStyle: .researchBrief,
				confidenceMultiplier: 1.02,
				interruptionCostAdjustment: 0,
				defaultBudgetPriority: .normal,
				requiresFreshContext: false,
				allowsContextExpansion: true,
				explanationStyle: .analytical
			)
		case .writing:
			return WorkflowExecutionProfile(
				workflowType: .writing,
				preferredIntentTypes: [.structure, .summarize, .extract],
				preferredPrimitives: [.structureNotes, .generateChecklist, .summarizeContext, .extractActionItems],
				avoidedPrimitives: [.explainError],
				resultCompositionStyle: .writingOutline,
				confidenceMultiplier: 1.0,
				interruptionCostAdjustment: -0.02,
				defaultBudgetPriority: .normal,
				requiresFreshContext: false,
				allowsContextExpansion: false,
				explanationStyle: .instructional
			)
		case .studying, .browsing:
			return WorkflowExecutionProfile(
				workflowType: workflowType == .studying ? .studying : .browsing,
				preferredIntentTypes: [.summarize, .answer, .structure],
				preferredPrimitives: [
					.summarizeContext, .answerFromContext, .generateStudyNotes,
					.structureNotes, .generateChecklist,
				],
				avoidedPrimitives: [.explainError],
				resultCompositionStyle: .studyNotes,
				confidenceMultiplier: 1.0,
				interruptionCostAdjustment: 0,
				defaultBudgetPriority: .normal,
				requiresFreshContext: false,
				allowsContextExpansion: false,
				explanationStyle: .instructional
			)
		case .reviewing, .comparing:
			return WorkflowExecutionProfile(
				workflowType: workflowType,
				preferredIntentTypes: [.compare, .review, .extract],
				preferredPrimitives: [
					.extractActionItems, .summarizeContext, .compareContexts,
					.organizeInformation,
				],
				avoidedPrimitives: [.explainError],
				resultCompositionStyle: .reviewSummary,
				confidenceMultiplier: 1.0,
				interruptionCostAdjustment: 0,
				defaultBudgetPriority: .normal,
				requiresFreshContext: false,
				allowsContextExpansion: false,
				explanationStyle: .analytical
			)
		case .organizing:
			return WorkflowExecutionProfile(
				workflowType: .organizing,
				preferredIntentTypes: [.organize, .extract, .structure],
				preferredPrimitives: [.organizeInformation, .extractActionItems, .structureNotes, .generateChecklist],
				avoidedPrimitives: [.explainError],
				resultCompositionStyle: .writingOutline,
				confidenceMultiplier: 0.98,
				interruptionCostAdjustment: 0,
				defaultBudgetPriority: .normal,
				requiresFreshContext: false,
				allowsContextExpansion: false,
				explanationStyle: .concise
			)
		case .editing:
			return WorkflowExecutionProfile(
				workflowType: .editing,
				preferredIntentTypes: [.review, .structure, .summarize],
				preferredPrimitives: [.structureNotes, .summarizeContext, .extractActionItems],
				avoidedPrimitives: [.explainError],
				resultCompositionStyle: .writingOutline,
				confidenceMultiplier: 1.0,
				interruptionCostAdjustment: 0,
				defaultBudgetPriority: .normal,
				requiresFreshContext: false,
				allowsContextExpansion: false,
				explanationStyle: .concise
			)
		case .unknown:
			return WorkflowExecutionProfile(
				workflowType: .unknown,
				preferredIntentTypes: [.summarize, .unknown],
				preferredPrimitives: [.summarizeContext, .answerFromContext],
				avoidedPrimitives: [],
				resultCompositionStyle: .linear,
				confidenceMultiplier: 0.95,
				interruptionCostAdjustment: 0,
				defaultBudgetPriority: .normal,
				requiresFreshContext: false,
				allowsContextExpansion: false,
				explanationStyle: .concise
			)
		}
	}
}
