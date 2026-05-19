import Foundation

extension GeneratedExecutionAction {
	/// Returns a copy with an updated plan and optional confidence (workflow shaping only).
	func replacing(plan: ExecutionPlan, confidence: Double? = nil) -> GeneratedExecutionAction {
		GeneratedExecutionAction(
			id: id,
			title: title,
			description: description,
			workflowType: workflowType,
			intentType: intentType,
			confidence: confidence ?? self.confidence,
			interruptionCost: interruptionCost,
			requiredContextTypes: requiredContextTypes,
			executionPlan: plan,
			explainabilitySummary: explainabilitySummary,
			generationSource: generationSource,
			createdAt: createdAt,
			expirationDate: expirationDate,
			isReusable: isReusable,
			reuseScore: reuseScore
		)
	}
}
