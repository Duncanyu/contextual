import Foundation

// MARK: - Source

enum GeneratedExecutionProposalSource: String, Hashable, Sendable, Codable, CaseIterable {
	case staticAction = "static_action"
	case generatedAction = "generated_action"
	case generatedExecution = "generated_execution"
	case reusableGenerated = "reusable_generated"
	/// Proposal composed by ModelDrivenHookComposer from task inference + hook capability registry.
	/// Uses lenient context validation — composer already minimized requirements, execution handles rest.
	case hookComposer = "hook_composer"
}

// MARK: - Candidate

/// Lightweight generated execution proposal candidate (metadata only — no raw context).
struct GeneratedExecutionProposalCandidate: Equatable, Sendable, Identifiable {
	let id: String
	let title: String
	let description: String
	let source: GeneratedExecutionProposalSource
	let workflowType: WorkflowType
	let intentType: IntentType
	let confidence: Double
	let interruptionCost: Double
	let explainabilitySummary: String
	let expectedOutputSummary: String
	let requiredContextTypes: [ContextRequirementType]
	let executionAction: GeneratedExecutionAction?
	let generatedActionId: UUID?
	let primitiveSignature: String?
	let isExecutableGeneratedProposal: Bool
	/// Execution mode inferred from the hook contract at candidate-build time.
	/// Defaults to .one_shot for non-hook-composer candidates; explicitly set for hook contracts.
	var executionMode: HookExecutionMode = .one_shot

	var isGeneratedFamily: Bool {
		switch source {
		case .staticAction: false
		default: true
		}
	}
}

// MARK: - Panel item

struct GeneratedExecutionProposalPanelItem: Equatable, Sendable, Identifiable {
	let id: String
	let title: String
	let subtitle: String
	let explainabilitySummary: String
	let expectedOutputSummary: String
	let source: GeneratedExecutionProposalSource
	let confidence: Double
	let rankScore: Double
	let isExecutableGeneratedProposal: Bool
	/// Execution mode propagated from the hook contract at candidate-build time.
	let executionMode: HookExecutionMode
	/// Carried for T18.4; not executed in T18.3.
	let executionActionId: UUID?

	init(from candidate: GeneratedExecutionProposalCandidate, rankScore: Double) {
		self.id = candidate.id
		self.title = candidate.title
		self.subtitle = candidate.description
		self.explainabilitySummary = candidate.explainabilitySummary
		self.expectedOutputSummary = candidate.expectedOutputSummary
		self.source = candidate.source
		self.confidence = candidate.confidence
		self.rankScore = rankScore
		self.isExecutableGeneratedProposal = candidate.isExecutableGeneratedProposal
		self.executionMode = candidate.executionMode
		self.executionActionId = candidate.executionAction?.id
	}
}

// MARK: - History

struct GeneratedExecutionProposalActivationHistory: Equatable, Sendable {
	var recentlyDismissedCandidateIds: Set<String>
	var recentlySuppressedSignatures: Set<String>
	var lastDismissedAt: Date?

	init(
		recentlyDismissedCandidateIds: Set<String> = [],
		recentlySuppressedSignatures: Set<String> = [],
		lastDismissedAt: Date? = nil
	) {
		self.recentlyDismissedCandidateIds = recentlyDismissedCandidateIds
		self.recentlySuppressedSignatures = recentlySuppressedSignatures
		self.lastDismissedAt = lastDismissedAt
	}

	static func fromAppState(
		lastDismissedProposalActionId: String?,
		lastDismissedProposalAt: Date?,
		dynamicDisplayDismissedIds: Set<UUID> = []
	) -> GeneratedExecutionProposalActivationHistory {
		var dismissed: Set<String> = []
		if let id = lastDismissedProposalActionId {
			dismissed.insert(id)
		}
		for uuid in dynamicDisplayDismissedIds {
			dismissed.insert(uuid.uuidString)
			dismissed.insert(GeneratedExecutionProposalActivator.generatedProposalActionId(for: uuid.uuidString))
		}
		return GeneratedExecutionProposalActivationHistory(
			recentlyDismissedCandidateIds: dismissed,
			lastDismissedAt: lastDismissedProposalAt
		)
	}
}

// MARK: - Timing

enum GeneratedProposalTimingOutcome: String, Hashable, Sendable, Codable {
	case allowPanel = "allow_panel"
	case allowFloating = "allow_floating"
	case deferProposal = "defer_proposal"
	case suppressAll = "suppress_all"
}

struct GeneratedExecutionProposalTimingDecision: Equatable, Sendable {
	let outcome: GeneratedProposalTimingOutcome
	let reason: String
	let allowsFloatingGenerated: Bool
	let allowsPanelGenerated: Bool

	static let suppressAll = GeneratedExecutionProposalTimingDecision(
		outcome: .suppressAll,
		reason: "suppressed",
		allowsFloatingGenerated: false,
		allowsPanelGenerated: false
	)
}

// MARK: - Activation result

struct GeneratedExecutionProposalActivationResult: Equatable, Sendable {
	let visibleProposals: [GeneratedExecutionProposalPanelItem]
	let visibleStaticActionIds: [String]
	let suppressedGeneratedCount: Int
	let suppressedStaticCount: Int
	let topSourceType: UnifiedActionSourceType?
	let rankingSummary: String
	let timingDecision: GeneratedExecutionProposalTimingDecision
	let warnings: [String]
	let createdAt: Date
	/// When set, floating UI may reference this synthetic action id (`generated_exec:…`).
	let floatingGeneratedProposalId: String?
	/// T18.6B — True when candidates exist but chime-in policy suppressed everything (floating AND panel).
	let isPolicySuppressed: Bool

	static let empty = GeneratedExecutionProposalActivationResult(
		visibleProposals: [],
		visibleStaticActionIds: [],
		suppressedGeneratedCount: 0,
		suppressedStaticCount: 0,
		topSourceType: nil,
		rankingSummary: "empty",
		timingDecision: .suppressAll,
		warnings: [],
		createdAt: Date(),
		floatingGeneratedProposalId: nil,
		isPolicySuppressed: false
	)
}

// MARK: - Input

struct GeneratedExecutionProposalActivationInput: Sendable {
	let staticActionIds: [String]
	let staticRelevanceScores: [ActionRelevanceScore]
	let generatedActions: [GeneratedAction]
	let generatedExecutionCandidates: [GeneratedExecutionProposalCandidate]
	let reusableRecords: [ReusableGeneratedActionRecord]
	let snapshot: CanonicalGeneratedExecutionContextSnapshot
	let history: GeneratedExecutionProposalActivationHistory
	let workflow: WorkflowInferenceResult?
	let session: ContextualSessionState?
	let isManualInvocation: Bool
	let isActionExecuting: Bool
	let referenceTime: Date
	/// When true, only `generatedExecutionCandidates` are used for generated family (LLM-first T18.3.1).
	let useLLMGeneratedCandidatesOnly: Bool
	/// When true, static actions are never surfaced as panel/floating fallbacks (T18.3.2).
	let suppressStaticProposalFallback: Bool

	init(
		staticActionIds: [String],
		staticRelevanceScores: [ActionRelevanceScore] = [],
		generatedActions: [GeneratedAction] = [],
		generatedExecutionCandidates: [GeneratedExecutionProposalCandidate] = [],
		reusableRecords: [ReusableGeneratedActionRecord] = [],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		history: GeneratedExecutionProposalActivationHistory = .init(),
		workflow: WorkflowInferenceResult? = nil,
		session: ContextualSessionState? = nil,
		isManualInvocation: Bool = false,
		isActionExecuting: Bool = false,
		referenceTime: Date = Date(),
		useLLMGeneratedCandidatesOnly: Bool = false,
		suppressStaticProposalFallback: Bool = false
	) {
		self.staticActionIds = staticActionIds
		self.staticRelevanceScores = staticRelevanceScores
		self.generatedActions = generatedActions
		self.generatedExecutionCandidates = generatedExecutionCandidates
		self.reusableRecords = reusableRecords
		self.snapshot = snapshot
		self.history = history
		self.workflow = workflow
		self.session = session
		self.isManualInvocation = isManualInvocation
		self.isActionExecuting = isActionExecuting
		self.referenceTime = referenceTime
		self.useLLMGeneratedCandidatesOnly = useLLMGeneratedCandidatesOnly
		self.suppressStaticProposalFallback = suppressStaticProposalFallback
	}
}
