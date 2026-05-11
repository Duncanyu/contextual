import Foundation

/// Safe, closed set of execution-shaped primitives (non-executable in T15.4 — data only).
enum GeneratedActionPrimitive: String, Hashable, Sendable, Codable, CaseIterable {
	case summarize
	case explain
	case rewrite
	case extract
	case compare
	case classify
	case structure
	case checklist
	case draft
	case review
}

/// Coarse prerequisites carried on generated actions (codes only).
enum GeneratedActionRequiredContext: String, Hashable, Sendable, Codable, CaseIterable {
	case textSnippet = "text_snippet"
	case fusedVisual = "fused_visual"
	case screenCapture = "screen_capture"
	case multiSource = "multi_source"
	case none = "none"

	static func fromIntentContexts(_ contexts: [IntentRequiredContext]) -> [GeneratedActionRequiredContext] {
		contexts.map {
			switch $0 {
			case .textSnippet: .textSnippet
			case .fusedVisual: .fusedVisual
			case .screenCapture: .screenCapture
			case .multiSource: .multiSource
			case .none: .none
			}
		}
	}
}

/// Conservative safety envelope (defaults are non-autonomous; no execution in this phase).
struct GeneratedActionSafetyProfile: Equatable, Sendable, Codable {
	var requiresUserApproval: Bool
	var canRunAutomatically: Bool
	var readsContextOnly: Bool
	var writesExternalState: Bool
	var executesCode: Bool
	var usesNetwork: Bool
	var usesShell: Bool
	/// Additional capability flags validated centrally by `GeneratedActionSafetyPolicy`.
	var usesBrowserAutomation: Bool
	var touchesFileSystem: Bool
	var requiresAppControl: Bool
	var requiresPrivilegedAction: Bool

	static let `default` = GeneratedActionSafetyProfile(
		requiresUserApproval: false,
		canRunAutomatically: false,
		readsContextOnly: true,
		writesExternalState: false,
		executesCode: false,
		usesNetwork: false,
		usesShell: false,
		usesBrowserAutomation: false,
		touchesFileSystem: false,
		requiresAppControl: false,
		requiresPrivilegedAction: false
	)

	/// Draft/rewrite-style primitives require explicit approval in later phases.
	static func profile(for primitives: Set<GeneratedActionPrimitive>) -> GeneratedActionSafetyProfile {
		let needsApproval = primitives.contains(.draft) || primitives.contains(.rewrite)
		return GeneratedActionSafetyProfile(
			requiresUserApproval: needsApproval,
			canRunAutomatically: false,
			readsContextOnly: true,
			writesExternalState: false,
			executesCode: false,
			usesNetwork: false,
			usesShell: false,
			usesBrowserAutomation: false,
			touchesFileSystem: false,
			requiresAppControl: false,
			requiresPrivilegedAction: false
		)
	}
}

enum GeneratedActionSource: String, Hashable, Sendable, Codable {
	case synthesizedIntent = "synthesized_intent"
	case selfTest = "self_test"
}

/// Discrete tags for template selection (no free-form reasoning).
enum GeneratedActionExplanationReason: String, Hashable, Sendable, Codable, CaseIterable {
	case intentMapped = "intent_mapped"
	case workflowSignal = "workflow_signal"
	case confidenceBand = "confidence_band"
	case safetyEnvelope = "safety_envelope"
	case reviewGate = "review_gate"
	case staleness = "staleness"
	case fusionQuality = "fusion_quality"
	case interactionLoad = "interaction_load"
	case sessionContinuity = "session_continuity"
	case suppressionHint = "suppression_hint"
	case primitiveComposition = "primitive_composition"
}

/// Bounded, privacy-safe influence codes (no payloads).
struct GeneratedActionInfluenceSummary: Equatable, Sendable, Codable {
	let workflowLabel: String
	let visualCategoryCodes: String
	let interactionStateCode: String
	let sessionContinuityBand: String
	let fusionFreshnessBand: String
	let multimodalAgreementBand: String
	let proposalContinuityBand: String
	let activeSurfaceCategory: String
	let intentTypeCode: String
	let primitiveCompositionCode: String
}

/// Short workflow rationale (template-derived only).
struct GeneratedActionWorkflowReasoning: Equatable, Sendable, Codable {
	let primaryCode: String
	let secondaryCodes: String
}

/// Structured explainability for generated actions and plans (metadata-only, deterministic).
struct GeneratedActionExplanation: Equatable, Sendable, Codable {
	let shortSummary: String
	let workflowSummary: String
	let confidenceSummary: String
	let influencingSignals: [String]
	let requiredContextSummary: String
	let interruptionSummary: String
	let freshnessSummary: String
	let safetySummary: String
	let sourceReasonCodes: [String]
	let generatedAt: Date
	let isStale: Bool
	let workflowReasoning: GeneratedActionWorkflowReasoning
	let influence: GeneratedActionInfluenceSummary
	let templateReasons: [GeneratedActionExplanationReason]
}

/// In-memory generated action concept (bounded, temporary, non-executable).
struct GeneratedAction: Equatable, Sendable, Identifiable {
	let id: UUID
	let title: String
	let description: String
	let intentType: SynthesizedIntentType
	let confidence: Double
	let workflow: InferredWorkflow
	let requiredContext: [GeneratedActionRequiredContext]
	let primitives: [GeneratedActionPrimitive]
	let interruptionCost: Double
	let workflowRelevance: Double
	let sourceIntentId: UUID
	let sourceReasonCodes: [String]
	let createdAt: Date
	let expiresAt: Date
	let isStale: Bool
	let safetyProfile: GeneratedActionSafetyProfile
	let explainabilitySummary: String
	let source: GeneratedActionSource
	/// Deterministic structured explainability (optional; built post–safety approval in normal pipeline).
	let structuredExplainability: GeneratedActionExplanation?
}

extension GeneratedAction {
	func withStructuredExplainability(_ explanation: GeneratedActionExplanation?) -> GeneratedAction {
		GeneratedAction(
			id: id,
			title: title,
			description: description,
			intentType: intentType,
			confidence: confidence,
			workflow: workflow,
			requiredContext: requiredContext,
			primitives: primitives,
			interruptionCost: interruptionCost,
			workflowRelevance: workflowRelevance,
			sourceIntentId: sourceIntentId,
			sourceReasonCodes: sourceReasonCodes,
			createdAt: createdAt,
			expiresAt: expiresAt,
			isStale: isStale,
			safetyProfile: safetyProfile,
			explainabilitySummary: explainabilitySummary,
			source: source,
			structuredExplainability: explanation
		)
	}
}

extension GeneratedActionPlan {
	func withStructuredExplainability(_ structured: GeneratedActionExplanation?) -> GeneratedActionPlan {
		GeneratedActionPlan(
			id: id,
			generatedActionId: generatedActionId,
			intentType: intentType,
			workflow: workflow,
			steps: steps,
			confidence: confidence,
			requiredContext: requiredContext,
			createdAt: createdAt,
			expiresAt: expiresAt,
			isStale: isStale,
			sourceReasonCodes: sourceReasonCodes,
			safetyProfile: safetyProfile,
			explanation: self.explanation,
			isExecutable: isExecutable,
			compositionRule: compositionRule,
			structuredExplainability: structured
		)
	}
}
