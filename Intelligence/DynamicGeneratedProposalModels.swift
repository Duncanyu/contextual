import Foundation

// MARK: - History metadata

struct ProposalHistoryMetadata: Equatable, Sendable {
	let recentDismissedCandidateIds: Set<String>
	let recentSuppressedSignatures: Set<String>
	let recentProposalTitles: [String]
	let lastDismissedAt: Date?

	init(
		recentDismissedCandidateIds: Set<String> = [],
		recentSuppressedSignatures: Set<String> = [],
		recentProposalTitles: [String] = [],
		lastDismissedAt: Date? = nil
	) {
		self.recentDismissedCandidateIds = recentDismissedCandidateIds
		self.recentSuppressedSignatures = recentSuppressedSignatures
		self.recentProposalTitles = Array(recentProposalTitles.prefix(8))
		self.lastDismissedAt = lastDismissedAt
	}

	static func fromActivationHistory(_ history: GeneratedExecutionProposalActivationHistory) -> ProposalHistoryMetadata {
		ProposalHistoryMetadata(
			recentDismissedCandidateIds: history.recentlyDismissedCandidateIds,
			recentSuppressedSignatures: history.recentlySuppressedSignatures,
			lastDismissedAt: history.lastDismissedAt
		)
	}
}

// MARK: - LLM wire schema

struct DynamicGeneratedProposalLLMOutput: Codable, Equatable, Sendable {
	let shouldChimeIn: Bool
	let reason: String
	let workflowAssessment: String
	let proposalConfidence: Double
	let requiresVisualContext: Bool
	let proposals: [DynamicGeneratedProposalLLMItem]
}

struct DynamicGeneratedProposalLLMItem: Codable, Equatable, Sendable {
	let title: String
	let description: String
	let intentType: String
	let workflowType: String
	let expectedOutcome: String
	let requiredContextTypes: [String]
	let suggestedPrimitives: [String]
	let interruptionCost: Double
	let confidence: Double
}

// MARK: - Engine result

enum DynamicGeneratedProposalSynthesisStatus: String, Sendable, Equatable {
	case synthesized
	case quietByGate
	case modelUnavailable = "model_unavailable"
	case parseFailed = "parse_failed"
	case timeout
	case cancelled
}

/// Metadata-only LLM failure classification (T18.3.3B).
enum DynamicGeneratedProposalLLMDiagnosticCause: String, Sendable, Equatable {
	case modelUnavailable = "model_unavailable"
	case startupGrace = "startup_grace"
	case appTimeout = "app_timeout"
	case clientFailed = "client_failed"
	case malformedResponse = "malformed_response"
	case responseTooSlow = "response_too_slow"
	case contextCancelled = "context_cancelled"
}

struct DynamicGeneratedProposalResult: Equatable, Sendable {
	let status: DynamicGeneratedProposalSynthesisStatus
	let shouldChimeIn: Bool
	let reason: String
	let workflowAssessment: String
	let proposalConfidence: Double
	let requiresVisualContext: Bool
	let proposals: [ValidatedDynamicGeneratedProposal]
	let warnings: [String]
	let llmDiagnosticCause: DynamicGeneratedProposalLLMDiagnosticCause?
	let createdAt: Date

	static let quiet = DynamicGeneratedProposalResult(
		status: .quietByGate,
		shouldChimeIn: false,
		reason: "gated",
		workflowAssessment: "",
		proposalConfidence: 0,
		requiresVisualContext: false,
		proposals: [],
		warnings: [],
		llmDiagnosticCause: nil,
		createdAt: Date()
	)

	static func unavailable(
		reason: String,
		cause: DynamicGeneratedProposalLLMDiagnosticCause = .modelUnavailable
	) -> DynamicGeneratedProposalResult {
		DynamicGeneratedProposalResult(
			status: .modelUnavailable,
			shouldChimeIn: false,
			reason: reason,
			workflowAssessment: "",
			proposalConfidence: 0,
			requiresVisualContext: false,
			proposals: [],
			warnings: [cause.rawValue],
			llmDiagnosticCause: cause,
			createdAt: Date()
		)
	}
}

struct ValidatedDynamicGeneratedProposal: Equatable, Sendable, Identifiable {
	let id: String
	let title: String
	let description: String
	let workflowType: WorkflowType
	let intentType: IntentType
	let expectedOutcome: String
	let requiredContextTypes: [ContextRequirementType]
	let suggestedPrimitives: [ExecutionPrimitive]
	let interruptionCost: Double
	let confidence: Double
	let usefulnessHint: String
}
