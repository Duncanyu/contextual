import Foundation

/// Converts successful executions into reusable records (metadata-only).
enum GeneratedActionReuseConverter {

	static func upsertRecord(
		existing: ReusableGeneratedActionRecord?,
		action: GeneratedExecutionAction,
		result: ExecutionResult,
		policy: GeneratedActionPersistencePolicy,
		now: Date = Date()
	) -> ReusableGeneratedActionRecord {
		let signature = GeneratedActionPrimitiveSignature.from(action: action)
		let templateId = signature.signatureCode

		var record = existing ?? ReusableGeneratedActionRecord(
			actionTemplateId: templateId,
			title: action.title,
			description: action.description,
			workflowType: action.workflowType,
			intentType: action.intentType,
			primitiveSignature: signature.signatureCode,
			requiredContextTypes: action.requiredContextTypes,
			createdAt: now,
			lastUsedAt: now,
			expiresAt: now.addingTimeInterval(policy.expirationInterval),
			averageConfidence: result.confidence,
			metadata: ["generationSource": action.generationSource.rawValue]
		)

		record.lastUsedAt = now
		record.expiresAt = now.addingTimeInterval(policy.expirationInterval)

		let totalConfidence = record.averageConfidence * Double(max(0, record.executedCount - 1)) + result.confidence
		record.averageConfidence = totalConfidence / Double(max(1, record.executedCount))

		record.usefulnessScore = GeneratedActionPersistenceScoring.usefulnessScore(
			record: record,
			policy: policy,
			now: now
		)
		record.reuseEligibility = GeneratedActionPersistenceScoring.reuseEligibility(
			record: record,
			policy: policy,
			now: now
		)
		return record
	}

	static func isSuccessful(_ status: ExecutionResultStatus) -> Bool {
		status == .success || status == .partialSuccess
	}
}
