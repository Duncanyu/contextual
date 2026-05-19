import Foundation

// MARK: - Source kinds

enum UnifiedActionSourceType: String, Hashable, Sendable, Codable, CaseIterable {
	case staticAction = "static_action"
	case generatedAction = "generated_action"
	case reusableGenerated = "reusable_generated"
	case executablePlan = "executable_plan"
	case executableGenerated = "executable_generated"
}

enum UnifiedCandidateActionType: String, Hashable, Sendable, Codable, CaseIterable {
	case staticAction = "static_action"
	case generatedPreview = "generated_preview"
	case generatedPlan = "generated_plan"
	case reusableTemplate = "reusable_template"
	case executionAction = "execution_action"
}

// MARK: - Rankable action

/// Normalized, metadata-only action candidate for unified ranking (T17.9).
struct UnifiedRankableAction: Equatable, Sendable, Identifiable {
	let id: String
	let sourceType: UnifiedActionSourceType
	let title: String
	let description: String
	let workflowType: WorkflowType
	let intentType: IntentType
	let confidence: Double
	let usefulnessScore: Double
	let interruptionCost: Double
	let executionComplexity: Int
	let estimatedExecutionTime: TimeInterval
	let requiresFreshContext: Bool
	let requiresVision: Bool
	let requiresOCR: Bool
	let isReusable: Bool
	let reuseScore: Double
	let workflowContinuityScore: Double
	let recentSuccessRate: Double
	let candidateActionType: UnifiedCandidateActionType
	let primitiveSignature: String?
	let metadata: [String: String]

	init(
		id: String,
		sourceType: UnifiedActionSourceType,
		title: String,
		description: String,
		workflowType: WorkflowType,
		intentType: IntentType,
		confidence: Double,
		usefulnessScore: Double = 0.5,
		interruptionCost: Double = 0.2,
		executionComplexity: Int = 1,
		estimatedExecutionTime: TimeInterval = 12,
		requiresFreshContext: Bool = false,
		requiresVision: Bool = false,
		requiresOCR: Bool = false,
		isReusable: Bool = false,
		reuseScore: Double = 0,
		workflowContinuityScore: Double = 0,
		recentSuccessRate: Double = 0,
		candidateActionType: UnifiedCandidateActionType,
		primitiveSignature: String? = nil,
		metadata: [String: String] = [:]
	) {
		self.id = id
		self.sourceType = sourceType
		self.title = Self.cap(title, max: 80)
		self.description = Self.cap(description, max: 160)
		self.workflowType = workflowType
		self.intentType = intentType
		self.confidence = min(1.0, max(0.0, confidence))
		self.usefulnessScore = min(1.0, max(0.0, usefulnessScore))
		self.interruptionCost = min(1.0, max(0.0, interruptionCost))
		self.executionComplexity = min(8, max(0, executionComplexity))
		self.estimatedExecutionTime = min(120, max(0, estimatedExecutionTime))
		self.requiresFreshContext = requiresFreshContext
		self.requiresVision = requiresVision
		self.requiresOCR = requiresOCR
		self.isReusable = isReusable
		self.reuseScore = min(1.0, max(0.0, reuseScore))
		self.workflowContinuityScore = min(1.0, max(0.0, workflowContinuityScore))
		self.recentSuccessRate = min(1.0, max(0.0, recentSuccessRate))
		self.candidateActionType = candidateActionType
		self.primitiveSignature = primitiveSignature.map { Self.cap($0, max: 120) }
		self.metadata = Self.sanitizeMetadata(metadata)
	}

	var isGeneratedFamily: Bool {
		switch sourceType {
		case .staticAction: false
		default: true
		}
	}

	private static func cap(_ text: String, max: Int) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count > max else { return trimmed }
		return String(trimmed.prefix(max))
	}

	private static func sanitizeMetadata(_ metadata: [String: String]) -> [String: String] {
		metadata.mapValues { cap($0, max: 64) }
	}
}

// MARK: - Score components

struct UnifiedActionScoreComponents: Equatable, Sendable {
	let confidenceScore: Double
	let usefulnessScore: Double
	let workflowContinuityScore: Double
	let interruptionPenalty: Double
	let executionComplexityPenalty: Double
	let reuseBoost: Double
	let recentSuccessBoost: Double
	let freshnessPenalty: Double
	let warningPenalty: Double
	let staticCompetitivenessBoost: Double
	let finalScore: Double

	static let zero = UnifiedActionScoreComponents(
		confidenceScore: 0,
		usefulnessScore: 0,
		workflowContinuityScore: 0,
		interruptionPenalty: 0,
		executionComplexityPenalty: 0,
		reuseBoost: 0,
		recentSuccessBoost: 0,
		freshnessPenalty: 0,
		warningPenalty: 0,
		staticCompetitivenessBoost: 0,
		finalScore: 0
	)
}

struct RankedUnifiedAction: Equatable, Sendable, Identifiable {
	let action: UnifiedRankableAction
	let components: UnifiedActionScoreComponents
	let rankingExplanationCodes: [String]
	let rankIndex: Int

	var id: String { action.id }
}

// MARK: - Context

struct UnifiedActionRankingContext: Equatable, Sendable {
	let activeWorkflow: WorkflowType
	let continuityScore: Double
	let workflowConfidence: Double
	let contextIsStale: Bool
	let referenceTime: Date
	let lowConfidenceGeneratedThreshold: Double
	let maxGeneratedRatioInTopWindow: Double
	let topWindowSize: Int
	let staticCompetitivenessBoost: Double

	init(
		activeWorkflow: WorkflowType = .unknown,
		continuityScore: Double = 0,
		workflowConfidence: Double = 0,
		contextIsStale: Bool = false,
		referenceTime: Date = Date(),
		lowConfidenceGeneratedThreshold: Double = 0.45,
		maxGeneratedRatioInTopWindow: Double = 0.6,
		topWindowSize: Int = 5,
		staticCompetitivenessBoost: Double = 0.05
	) {
		self.activeWorkflow = activeWorkflow
		self.continuityScore = min(1.0, max(0.0, continuityScore))
		self.workflowConfidence = min(1.0, max(0.0, workflowConfidence))
		self.contextIsStale = contextIsStale
		self.referenceTime = referenceTime
		self.lowConfidenceGeneratedThreshold = min(0.9, max(0.2, lowConfidenceGeneratedThreshold))
		self.maxGeneratedRatioInTopWindow = min(1.0, max(0.2, maxGeneratedRatioInTopWindow))
		self.topWindowSize = min(10, max(3, topWindowSize))
		self.staticCompetitivenessBoost = min(0.15, max(0, staticCompetitivenessBoost))
	}
}

// MARK: - Result

struct UnifiedActionRankingResult: Equatable, Sendable {
	let rankedActions: [RankedUnifiedAction]
	let rankingReasonSummary: String
	let workflowSummary: String
	let topActionConfidence: Double
	let generatedActionCount: Int
	let reusableActionCount: Int
	let staticActionCount: Int
	let warnings: [String]
	let createdAt: Date
	let consideredCount: Int
	let suppressedCount: Int
	let rankingDurationMs: Int

	static let empty = UnifiedActionRankingResult(
		rankedActions: [],
		rankingReasonSummary: "no_actions",
		workflowSummary: "unknown",
		topActionConfidence: 0,
		generatedActionCount: 0,
		reusableActionCount: 0,
		staticActionCount: 0,
		warnings: [],
		createdAt: Date(),
		consideredCount: 0,
		suppressedCount: 0,
		rankingDurationMs: 0
	)
}
