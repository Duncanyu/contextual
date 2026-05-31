import Foundation

public enum AmbientSuggestionKind: String, Sendable, Codable {
    case compare_context = "compare_context"
    case summarize_context = "summarize_context"
    case explain_context = "explain_context"
    case unknown = "unknown"
}

public enum AmbientExecutionMode: String, Sendable, Codable {
    case context_only_preview = "context_only_preview"
    case unavailable = "unavailable"
    case blocked_requires_control = "blocked_requires_control"
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

    public let executionMode: AmbientExecutionMode
    public let previewOnly: Bool
    public let sourceEvidence: String
    public let createdAt: Date
    
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
        executionMode: AmbientExecutionMode = .context_only_preview,
        previewOnly: Bool = true,
        sourceEvidence: String,
        createdAt: Date = Date()
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
        self.executionMode = executionMode
        self.previewOnly = previewOnly
        self.sourceEvidence = sourceEvidence
        self.createdAt = createdAt
        
        let confStr = String(format: "%.2f", confidence)
        print("[AmbientJarvisSuggestion] created kind=\(kind.rawValue) confidence=\(confStr)")
		print("[AmbientIntent] generated intent=\(intent) confidence=\(String(format: "%.2f", intentConfidence)) goal=\"\(intentGoal)\"")
    }
}
