import Foundation

enum ReuseEligibility: String, Hashable, Sendable, Codable, CaseIterable {
	case notEligible = "not_eligible"
	case eligible = "eligible"
	case suppressed = "suppressed"
}

enum GeneratedActionPersistenceEventKind: String, Hashable, Sendable, Codable, CaseIterable {
	case proposed
	case accepted
	case dismissed
	case executed
	case executionSucceeded = "execution_succeeded"
	case executionFailed = "execution_failed"
	case reused
	case expired
	case suppressed
}

/// Metadata-only persistence event (no raw context or generated bodies).
struct GeneratedActionPersistenceEvent: Equatable, Sendable, Codable {
	let kind: GeneratedActionPersistenceEventKind
	let actionId: UUID?
	let actionTemplateId: String
	let workflowType: WorkflowType
	let intentType: IntentType
	let primitiveSignature: String
	let timestamp: Date
	let resultStatus: ExecutionResultStatus?
	let metadata: [String: String]

	init(
		kind: GeneratedActionPersistenceEventKind,
		actionId: UUID? = nil,
		actionTemplateId: String,
		workflowType: WorkflowType,
		intentType: IntentType,
		primitiveSignature: String,
		timestamp: Date = Date(),
		resultStatus: ExecutionResultStatus? = nil,
		metadata: [String: String] = [:]
	) {
		self.kind = kind
		self.actionId = actionId
		self.actionTemplateId = actionTemplateId
		self.workflowType = workflowType
		self.intentType = intentType
		self.primitiveSignature = primitiveSignature
		self.timestamp = timestamp
		self.resultStatus = resultStatus
		self.metadata = GeneratedActionPersistenceMetadata.sanitize(metadata)
	}

	static func from(
		kind: GeneratedActionPersistenceEventKind,
		action: GeneratedExecutionAction,
		resultStatus: ExecutionResultStatus? = nil,
		metadata: [String: String] = [:]
	) -> GeneratedActionPersistenceEvent {
		let signature = GeneratedActionPrimitiveSignature.from(action: action)
		return GeneratedActionPersistenceEvent(
			kind: kind,
			actionId: action.id,
			actionTemplateId: signature.signatureCode,
			workflowType: action.workflowType,
			intentType: action.intentType,
			primitiveSignature: signature.signatureCode,
			resultStatus: resultStatus,
			metadata: metadata
		)
	}
}

/// Bounded local record for reusable generated execution templates (metadata-only).
struct ReusableGeneratedActionRecord: Equatable, Sendable, Codable, Identifiable {
	let id: UUID
	let actionTemplateId: String
	let title: String
	let description: String
	let workflowType: WorkflowType
	let intentType: IntentType
	let primitiveSignature: String
	let requiredContextTypes: [ContextRequirementType]
	let createdAt: Date
	var lastUsedAt: Date
	var expiresAt: Date
	var acceptedCount: Int
	var dismissedCount: Int
	var executedCount: Int
	var successfulExecutionCount: Int
	var failedExecutionCount: Int
	var repeatedUseCount: Int
	var usefulnessScore: Double
	var averageConfidence: Double
	var reuseEligibility: ReuseEligibility
	let safetyVersion: Int
	var metadata: [String: String]

	init(
		id: UUID = UUID(),
		actionTemplateId: String,
		title: String,
		description: String,
		workflowType: WorkflowType,
		intentType: IntentType,
		primitiveSignature: String,
		requiredContextTypes: [ContextRequirementType],
		createdAt: Date,
		lastUsedAt: Date,
		expiresAt: Date,
		acceptedCount: Int = 0,
		dismissedCount: Int = 0,
		executedCount: Int = 0,
		successfulExecutionCount: Int = 0,
		failedExecutionCount: Int = 0,
		repeatedUseCount: Int = 0,
		usefulnessScore: Double = 0,
		averageConfidence: Double = 0,
		reuseEligibility: ReuseEligibility = .notEligible,
		safetyVersion: Int = GeneratedActionPrimitiveSignature.currentSafetyVersion,
		metadata: [String: String] = [:]
	) {
		self.id = id
		self.actionTemplateId = actionTemplateId
		self.title = String(title.prefix(120))
		self.description = String(description.prefix(200))
		self.workflowType = workflowType
		self.intentType = intentType
		self.primitiveSignature = primitiveSignature
		self.requiredContextTypes = requiredContextTypes
		self.createdAt = createdAt
		self.lastUsedAt = lastUsedAt
		self.expiresAt = expiresAt
		self.acceptedCount = max(0, acceptedCount)
		self.dismissedCount = max(0, dismissedCount)
		self.executedCount = max(0, executedCount)
		self.successfulExecutionCount = max(0, successfulExecutionCount)
		self.failedExecutionCount = max(0, failedExecutionCount)
		self.repeatedUseCount = max(0, repeatedUseCount)
		self.usefulnessScore = min(1.0, max(0.0, usefulnessScore))
		self.averageConfidence = min(1.0, max(0.0, averageConfidence))
		self.reuseEligibility = reuseEligibility
		self.safetyVersion = safetyVersion
		self.metadata = GeneratedActionPersistenceMetadata.sanitize(metadata)
	}

	var isExpired: Bool {
		Date() >= expiresAt
	}

	var executionSuccessRate: Double {
		guard executedCount > 0 else { return 0 }
		return Double(successfulExecutionCount) / Double(executedCount)
	}
}
