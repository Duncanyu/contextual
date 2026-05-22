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

// MARK: - LLM wire schema (legacy strict form; kept for backward compat with existing self-tests)

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

// MARK: - Tolerant compact wire schema (T18.3.3C)
// All fields optional to survive partial/alias LLM output; resolved via computed properties.

struct DynamicGeneratedProposalTolerantOutput: Decodable, Sendable {
	// Top-level chime signal — both compact ("chime") and legacy ("shouldChimeIn") accepted.
	let chime: Bool?
	let shouldChimeIn: Bool?
	let reason: String?
	let workflowAssessment: String?
	let proposalConfidence: Double?
	let requiresVisualContext: Bool?
	// Proposal payload — both singular ("proposal") and array ("proposals") accepted.
	let proposal: DynamicGeneratedProposalTolerantItem?
	let proposals: [DynamicGeneratedProposalTolerantItem]?

	var resolvedChimeIn: Bool { chime ?? shouldChimeIn ?? false }
	var resolvedProposalConfidence: Double { proposalConfidence ?? 0.6 }
	var resolvedItems: [DynamicGeneratedProposalTolerantItem] {
		if let arr = proposals, !arr.isEmpty { return arr }
		if let single = proposal { return [single] }
		return []
	}
}

struct DynamicGeneratedProposalTolerantItem: Decodable, Sendable {
	let title: String?
	let description: String?
	// Workflow aliases: compact "workflow" or legacy "workflowType"
	let workflow: String?
	let workflowType: String?
	// Intent aliases: compact "intent" or legacy "intentType"
	let intent: String?
	let intentType: String?
	// Outcome aliases: compact "outcome" or legacy "expectedOutcome"
	let outcome: String?
	let expectedOutcome: String?
	// Primitive aliases: compact "primitives" or legacy "suggestedPrimitives"
	let primitives: [String]?
	let suggestedPrimitives: [String]?
	// Confidence: may be string "0.72" or double 0.72
	let confidence: DynamicProposalFlexDouble?
	let interruptionCost: Double?
	let requiredContextTypes: [String]?

	var resolvedWorkflow: String { workflow ?? workflowType ?? "" }
	var resolvedIntent: String { intent ?? intentType ?? "" }
	var resolvedOutcome: String { outcome ?? expectedOutcome ?? "" }
	var resolvedPrimitives: [String] { primitives ?? suggestedPrimitives ?? [] }
	var resolvedConfidence: Double { confidence?.value ?? 0.6 }
}

/// Decodes confidence that local LLMs sometimes emit as a string rather than a number.
struct DynamicProposalFlexDouble: Decodable, Sendable {
	let value: Double

	init(from decoder: Decoder) throws {
		let c = try decoder.singleValueContainer()
		if let d = try? c.decode(Double.self) {
			value = d
		} else if let s = try? c.decode(String.self), let d = Double(s) {
			value = d
		} else {
			value = 0.6
		}
	}
}

// MARK: - Parser diagnostics (T18.3.3C)

struct DynamicGeneratedProposalParserDiagnostics: Sendable {
	/// Size bucket of the raw response (bytes): "0-100", "100-500", "500-2000", "2000+"
	let rawByteBucket: String
	let extractionSucceeded: Bool
	/// Name of the first required key that was missing or empty, if any.
	let missingRequiredKey: String?
	/// How many primitive strings the LLM returned that didn't map to a known ExecutionPrimitive.
	let unknownPrimitiveCount: Int
	let confidenceIssue: Bool
	/// True when at least one key alias (compact vs legacy) or camelCase primitive was resolved.
	let aliasNormalizationUsed: Bool
	let repairAttempted: Bool
	let repairSucceeded: Bool

	static func byteBucket(_ count: Int) -> String {
		switch count {
		case 0 ..< 100: return "0-100"
		case 100 ..< 500: return "100-500"
		case 500 ..< 2000: return "500-2000"
		default: return "2000+"
		}
	}
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
	/// Reusable templates returned from the library (T18.3.5).
	/// Non-empty only when the live path found a library hit — no LLM was called.
	/// Pass directly to GeneratedExecutionProposalActivationInput.reusableRecords.
	let libraryRecords: [ReusableGeneratedActionRecord]
	/// Hook-composed dynamic action contracts (T18.4+).
	/// Non-empty only when the task-inference → hook-composition fast path synthesized a contract.
	/// Cached in AppState and executed via the quarantined hook runtime (not templates / not LLM).
	let hookContracts: [DynamicGeneratedActionContract]

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
		createdAt: Date(),
		libraryRecords: [],
		hookContracts: []
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
			createdAt: Date(),
			libraryRecords: [],
			hookContracts: []
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
