import Foundation

/// Where the proposal decision came from (T18.3.4).
enum AgenticDecisionSource: String, Sendable {
	case heuristic
	case microModel = "micro_model"
	case inherited
}

/// What kind of richer context would improve the decision (T18.3.4).
enum AgenticContextKind: String, Sendable {
	case none
	case selectedText = "selected_text"
	case clipboard
	case visual
	case ocr
}

/// Fast decision: should the large model be invoked this cycle? (T18.3.4)
struct AgenticProposalDecision: Sendable {
	/// Large model should be called this cycle.
	let shouldThink: Bool
	/// Decision-layer heuristic chime estimate (advisory only — large model decides final chime).
	let shouldChimeIn: Bool
	/// More context is needed before calling the large model would be worthwhile.
	let needsMoreContext: Bool
	let recommendedContextKind: AgenticContextKind
	let workflowType: InferredWorkflow
	let intentType: SynthesizedIntentType?
	let confidence: Double
	let interruptionCost: Double
	let reason: String
	let decisionSource: AgenticDecisionSource

	static func quiet(reason: String, source: AgenticDecisionSource = .heuristic) -> AgenticProposalDecision {
		AgenticProposalDecision(
			shouldThink: false,
			shouldChimeIn: false,
			needsMoreContext: false,
			recommendedContextKind: .none,
			workflowType: .unknown,
			intentType: nil,
			confidence: 0,
			interruptionCost: 0,
			reason: reason,
			decisionSource: source
		)
	}

	static func needsContext(kind: AgenticContextKind, reason: String) -> AgenticProposalDecision {
		AgenticProposalDecision(
			shouldThink: false,
			shouldChimeIn: false,
			needsMoreContext: true,
			recommendedContextKind: kind,
			workflowType: .unknown,
			intentType: nil,
			confidence: 0,
			interruptionCost: 0.1,
			reason: reason,
			decisionSource: .heuristic
		)
	}
}

/// Injectable decision engine protocol for testing (T18.3.4A).
protocol AgenticProposalDeciding: Sendable {
	func decide(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) async -> AgenticProposalDecision
	func recordTimeout(fingerprint: String, at time: Date) async
}

extension AgenticProposalDecisionEngine: AgenticProposalDeciding {}
