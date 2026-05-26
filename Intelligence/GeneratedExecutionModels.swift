import Foundation

// MARK: - Execution budget

/// Bounded runtime/resource envelope for a single execution (adaptive tuning in T17.4+).
struct ExecutionBudget: Equatable, Sendable, Codable {
	var maxCPUPercent: Double
	var maxConcurrentTasks: Int
	var maxExecutionTime: TimeInterval
	var allowsVision: Bool
	var allowsOCR: Bool
	var allowsLLM: Bool
	var allowsBackgroundWork: Bool
	var thermalStateSensitivity: Double
	var budgetPriority: BudgetPriority

	init(
		maxCPUPercent: Double = 35,
		maxConcurrentTasks: Int = 1,
		maxExecutionTime: TimeInterval = 45,
		allowsVision: Bool = false,
		allowsOCR: Bool = false,
		allowsLLM: Bool = true,
		allowsBackgroundWork: Bool = false,
		thermalStateSensitivity: Double = 0.5,
		budgetPriority: BudgetPriority = .normal
	) {
		self.maxCPUPercent = min(100, max(1, maxCPUPercent))
		self.maxConcurrentTasks = min(2, max(1, maxConcurrentTasks))
		self.maxExecutionTime = min(120, max(5, maxExecutionTime))
		self.allowsVision = allowsVision
		self.allowsOCR = allowsOCR
		self.allowsLLM = allowsLLM
		self.allowsBackgroundWork = allowsBackgroundWork
		self.thermalStateSensitivity = min(1.0, max(0.0, thermalStateSensitivity))
		self.budgetPriority = budgetPriority
	}

	/// Conservative defaults: single task, no vision/OCR/background, review-friendly.
	static let conservative = ExecutionBudget()
}

// MARK: - Execution plan

/// Bounded structured flow compiled from safe primitives (non-recursive; no nested plans).
struct ExecutionPlan: Equatable, Sendable, Codable, Identifiable {
	let id: UUID
	let primitives: [ExecutionPrimitive]
	let estimatedCost: Double
	let estimatedRuntime: TimeInterval
	let requiresVision: Bool
	let requiresOCR: Bool
	let requiresUserIntent: Bool
	let requiredPermissions: [PermissionRequirement]
	let fallbackBehavior: ExecutionFallbackBehavior
	let executionBudget: ExecutionBudget
	let planConfidence: Double

	init(
		id: UUID = UUID(),
		primitives: [ExecutionPrimitive],
		estimatedCost: Double,
		estimatedRuntime: TimeInterval,
		requiresVision: Bool,
		requiresOCR: Bool,
		requiresUserIntent: Bool,
		requiredPermissions: [PermissionRequirement],
		fallbackBehavior: ExecutionFallbackBehavior,
		executionBudget: ExecutionBudget,
		planConfidence: Double
	) {
		let capped = Array(primitives.prefix(GeneratedExecutionBounds.maxPrimitivesPerPlan))
		self.id = id
		self.primitives = capped
		self.estimatedCost = min(1.0, max(0.0, estimatedCost))
		self.estimatedRuntime = max(0, estimatedRuntime)
		self.requiresVision = requiresVision
		self.requiresOCR = requiresOCR
		self.requiresUserIntent = requiresUserIntent
		self.requiredPermissions = requiredPermissions
		self.fallbackBehavior = fallbackBehavior
		self.executionBudget = executionBudget
		self.planConfidence = min(1.0, max(0.0, planConfidence))
	}

	var isWithinBounds: Bool {
		!primitives.isEmpty && primitives.count <= GeneratedExecutionBounds.maxPrimitivesPerPlan
	}
}

// MARK: - Generated execution action

/// Synthesized executable contextual action concept (in-memory; not executed in T17.1).
struct GeneratedExecutionAction: Equatable, Sendable, Codable, Identifiable {
	let id: UUID
	let title: String
	let description: String
	let workflowType: WorkflowType
	let intentType: IntentType
	let confidence: Double
	let interruptionCost: Double
	let requiredContextTypes: [ContextRequirementType]
	let executionPlan: ExecutionPlan
	let explainabilitySummary: String
	let generationSource: GenerationSource
	/// Proposal-time execution anchor for correcting foreground-app drift during execution (Phase 4J).
	let targetAnchor: TargetWindowAnchor?
	let createdAt: Date
	let expirationDate: Date
	let isReusable: Bool
	let reuseScore: Double

	init(
		id: UUID = UUID(),
		title: String,
		description: String,
		workflowType: WorkflowType,
		intentType: IntentType,
		confidence: Double,
		interruptionCost: Double,
		requiredContextTypes: [ContextRequirementType],
		executionPlan: ExecutionPlan,
		explainabilitySummary: String,
		generationSource: GenerationSource,
		targetAnchor: TargetWindowAnchor? = nil,
		createdAt: Date,
		expirationDate: Date,
		isReusable: Bool,
		reuseScore: Double
	) {
		self.id = id
		self.title = title
		self.description = description
		self.workflowType = workflowType
		self.intentType = intentType
		self.confidence = min(1.0, max(0.0, confidence))
		self.interruptionCost = min(1.0, max(0.0, interruptionCost))
		self.requiredContextTypes = Array(
			requiredContextTypes.prefix(GeneratedExecutionBounds.maxRequiredContextTypes)
		)
		self.executionPlan = executionPlan
		self.explainabilitySummary = explainabilitySummary
		self.generationSource = generationSource
		self.targetAnchor = targetAnchor
		self.createdAt = createdAt
		self.expirationDate = expirationDate
		self.isReusable = isReusable
		self.reuseScore = min(1.0, max(0.0, reuseScore))
	}

	var isExpired: Bool {
		Date() >= expirationDate
	}
}

// MARK: - Execution result

/// One labeled section within a structured execution output (no raw source payloads).
struct ExecutionResultSection: Equatable, Sendable, Codable, Identifiable {
	let id: UUID
	let title: String
	let body: String
	let order: Int

	init(id: UUID = UUID(), title: String, body: String, order: Int) {
		self.id = id
		self.title = title
		self.body = body
		self.order = order
	}
}

/// Output record from a completed or failed execution (populated by future runtime).
struct ExecutionResult: Equatable, Sendable, Codable, Identifiable {
	let id: UUID
	let actionId: UUID
	let status: ExecutionResultStatus
	let startedAt: Date?
	let completedAt: Date?
	let generatedContent: String?
	let generatedSections: [ExecutionResultSection]
	let warnings: [String]
	let executionMetadata: [String: String]
	let confidence: Double
	let followUpSuggestions: [String]

	init(
		id: UUID = UUID(),
		actionId: UUID,
		status: ExecutionResultStatus,
		startedAt: Date?,
		completedAt: Date?,
		generatedContent: String?,
		generatedSections: [ExecutionResultSection],
		warnings: [String],
		executionMetadata: [String: String],
		confidence: Double,
		followUpSuggestions: [String]
	) {
		self.id = id
		self.actionId = actionId
		self.status = status
		self.startedAt = startedAt
		self.completedAt = completedAt
		self.generatedContent = generatedContent
		self.generatedSections = generatedSections
		self.warnings = warnings
		self.executionMetadata = executionMetadata
		self.confidence = min(1.0, max(0.0, confidence))
		self.followUpSuggestions = Array(
			followUpSuggestions.prefix(GeneratedExecutionBounds.maxFollowUpSuggestions)
		)
	}
}
