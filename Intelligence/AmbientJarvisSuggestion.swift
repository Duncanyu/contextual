import Foundation

public enum AmbientSuggestionKind: String, Sendable, Codable {
    /// Phase 22 — Standard action opportunity (driven by OpportunityEngine).
    case cognitive_action = "cognitive_action"
    /// Comfort/local action (play music, start timer, open app).
    case comfort_action = "comfort_action"
    /// Manually triggered by the user.
    case user_initiated = "user_initiated"
    /// No useful opportunity found — suppressed.
    case suppressed = "suppressed"
    // Legacy — kept for Codable backward compatibility only. Not used in new paths.
    case compare_context = "compare_context"
    case summarize_context = "summarize_context"
    case explain_context = "explain_context"
    case unknown = "unknown"
}

public enum AmbientExecutionMode: String, Sendable, Codable {
    case context_only_preview = "context_only_preview"
    case local_action = "local_action"
    case unavailable = "unavailable"
    case blocked_requires_control = "blocked_requires_control"
}

public struct SuggestionContextPayload: Sendable, Codable, Equatable {
    public let taskCompartmentSnapshot: TaskCompartment?
    public let workingMemorySnapshot: WorkingMemorySnapshot
    public let comparisonCandidates: [String]
    public let relatedFocusEntities: [String]
    public let activeTerms: [String]
    public let evidenceQuality: String
    public let evidenceLevel: String
    public let browserTabs: [String]
    public let browserContextType: String?
    public let browserContentAvailable: Bool
    public let actionIntent: String
}

public struct AmbientJarvisSuggestion: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let whyNow: String
    public let workflow: String
    public let behavior: String
    public let confidence: Double
    public let kind: AmbientSuggestionKind
	
	// Phase 18C: Intent-driven fields
	public let intent: String
	public let intentConfidence: Double
	public let intentGoal: String
	// Phase 20G.2: current-focus target entity (from WorkingMemory)
	public let targetEntity: String

    public let executionMode: AmbientExecutionMode
    public let previewOnly: Bool
    public let sourceEvidence: String
    public let createdAt: Date
    
    // Phase 20I: Context Handoff
    public let contextPayload: SuggestionContextPayload?

    // Phase 21.2: Non-text ActionCard with primary/secondary/auxiliary actions.
    public let actionCard: ActionCard?

    // Phase 22 — Opportunity that drove this suggestion. Preserved so
    // ContextExecutionEngine can log [OpportunityExecution] and generate
    // domain-specific artifacts on acceptance. Nil for legacy/pre-22 paths.
    public let topOpportunity: Opportunity?

    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String,
        whyNow: String,
        workflow: String,
        behavior: String,
        confidence: Double,
        kind: AmbientSuggestionKind,
		intent: String = "understand_context",
		intentConfidence: Double = 0.5,
		intentGoal: String = "",
		targetEntity: String = "",
        executionMode: AmbientExecutionMode = .context_only_preview,
        previewOnly: Bool = true,
        sourceEvidence: String,
        createdAt: Date = Date(),
        contextPayload: SuggestionContextPayload? = nil,
        actionCard: ActionCard? = nil,
        topOpportunity: Opportunity? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.whyNow = whyNow
        self.workflow = workflow
        self.behavior = behavior
        self.confidence = confidence
        self.kind = kind
		self.intent = intent
		self.intentConfidence = intentConfidence
		self.intentGoal = intentGoal
		self.targetEntity = targetEntity
        self.executionMode = executionMode
        self.previewOnly = previewOnly
        self.sourceEvidence = sourceEvidence
        self.createdAt = createdAt
        self.contextPayload = contextPayload
        self.actionCard = actionCard
        self.topOpportunity = topOpportunity

        let confStr = String(format: "%.2f", confidence)
        print("[AmbientJarvisSuggestion] created kind=\(kind.rawValue) confidence=\(confStr)")
		print("[AmbientIntent] generated intent=\(intent) confidence=\(String(format: "%.2f", intentConfidence)) goal=\"\(intentGoal)\"")
        
        if let payload = contextPayload {
            print("[SuggestionContextPayload] attached=yes entities=\(payload.workingMemorySnapshot.recentEntities.count) comparisons=\(payload.comparisonCandidates.count)")
        }
    }
}
