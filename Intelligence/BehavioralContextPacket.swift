import Foundation

// MARK: - Enums

public enum BehavioralState: String, CaseIterable, Codable, Sendable {
    case researching
    case comparing
    case learning
    case debugging
    case coding
    case reading
    case writing
    case shopping
    case gaming
    case watching
    case idle
    case unknown
}

// MARK: - Packet

public struct BehavioralContextPacket: Codable, Sendable {
    public let dominantApps: [String]
    public let appTransitions: Int
    public let titleTransitions: Int
    public let repeatedTopics: [String]
    public let workflowHistory: [String]
    public let workflowConfidenceHistory: [Double]
    public let contextContinuityMetrics: Double
    public let activityMetrics: Double
    public let spanSeconds: TimeInterval

    public init(
        dominantApps: [String],
        appTransitions: Int,
        titleTransitions: Int,
        repeatedTopics: [String],
        workflowHistory: [String],
        workflowConfidenceHistory: [Double],
        contextContinuityMetrics: Double,
        activityMetrics: Double,
        spanSeconds: TimeInterval
    ) {
        self.dominantApps = dominantApps
        self.appTransitions = appTransitions
        self.titleTransitions = titleTransitions
        self.repeatedTopics = repeatedTopics
        self.workflowHistory = workflowHistory
        self.workflowConfidenceHistory = workflowConfidenceHistory
        self.contextContinuityMetrics = contextContinuityMetrics
        self.activityMetrics = activityMetrics
        self.spanSeconds = spanSeconds
    }
}

// MARK: - Raw Inference

public struct BehavioralInference: Codable, Sendable, Equatable {
    public let state: BehavioralState
    public let confidence: Double
    public let reasoning: String

    public init(state: BehavioralState, confidence: Double, reasoning: String) {
        self.state = state
        self.confidence = confidence
        self.reasoning = reasoning
    }
}

// MARK: - Stabilized Record

public struct BehavioralStateRecord: Codable, Sendable, Equatable {
    public let state: BehavioralState
    public let confidence: Double
    public let reasoning: String
    public let startedAt: Date
    public let lastUpdatedAt: Date
    public let stabilityScore: Double

    public init(
        state: BehavioralState,
        confidence: Double,
        reasoning: String,
        startedAt: Date,
        lastUpdatedAt: Date,
        stabilityScore: Double
    ) {
        self.state = state
        self.confidence = confidence
        self.reasoning = reasoning
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.stabilityScore = stabilityScore
    }

    public static let empty = BehavioralStateRecord(
        state: .unknown,
        confidence: 0.0,
        reasoning: "empty",
        startedAt: Date(timeIntervalSince1970: 0),
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        stabilityScore: 0.0
    )
}
