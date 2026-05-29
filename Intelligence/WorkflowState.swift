import Foundation

// MARK: - AmbientWorkflowType

/// Possible workflow labels Phase B is allowed to emit.
///
/// These are *labels* the inference layer can output. They are NOT hardcoded
/// app-to-label rules — the small local model picks one of these based on the
/// compressed temporal context packet. `unknown` is the conservative default
/// whenever evidence is weak.
public enum AmbientWorkflowType: String, Sendable, Codable, CaseIterable, Equatable {
    case unknown
    case idle
    case studying
    case gaming
    case coding
    case debugging
    case researching
    case writing
    case reading
    case watching
    case emailing
    case shopping
    case comparing
    case browsing
    case meeting

    /// Construct from a raw model string, falling back to `.unknown` on any mismatch.
    public init(rawString: String) {
        let normalized = rawString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self = AmbientWorkflowType(rawValue: normalized) ?? .unknown
    }
}

// MARK: - WorkflowState

/// Central, stable workflow snapshot produced by `WorkflowIntelligenceCoordinator`.
///
/// This is the answer to: "What has the user been doing recently?"
/// It is produced from temporal context → compressed packet → local model
/// inference → stabilizer. It is NOT produced by app-name lookups.
public struct WorkflowState: Sendable, Codable, Equatable {
    public let workflowType: AmbientWorkflowType
    public let confidence: Double
    public let evidence: [String]
    public let uncertainty: String
    public let startedAt: Date
    public let lastUpdatedAt: Date
    public let stabilityScore: Double
    public let dominantApps: [String]
    public let repeatedTerms: [String]
    public let recentTransitions: [String]
    public let suggestedIntentHints: [String]
    public let sourcePacketHash: String

    public var durationSeconds: TimeInterval {
        max(0, lastUpdatedAt.timeIntervalSince(startedAt))
    }

    public init(
        workflowType: AmbientWorkflowType,
        confidence: Double,
        evidence: [String],
        uncertainty: String,
        startedAt: Date,
        lastUpdatedAt: Date,
        stabilityScore: Double,
        dominantApps: [String],
        repeatedTerms: [String],
        recentTransitions: [String],
        suggestedIntentHints: [String],
        sourcePacketHash: String
    ) {
        self.workflowType = workflowType
        self.confidence = confidence
        self.evidence = evidence
        self.uncertainty = uncertainty
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.stabilityScore = stabilityScore
        self.dominantApps = dominantApps
        self.repeatedTerms = repeatedTerms
        self.recentTransitions = recentTransitions
        self.suggestedIntentHints = suggestedIntentHints
        self.sourcePacketHash = sourcePacketHash
    }

    /// Conservative default — the "no information" state.
    public static let empty = WorkflowState(
        workflowType: .unknown,
        confidence: 0.0,
        evidence: [],
        uncertainty: "no_data",
        startedAt: Date(timeIntervalSince1970: 0),
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        stabilityScore: 0.0,
        dominantApps: [],
        repeatedTerms: [],
        recentTransitions: [],
        suggestedIntentHints: [],
        sourcePacketHash: ""
    )

    /// Canonical Phase B log line.
    public func log() {
        let dur = Int(durationSeconds)
        print("[WorkflowState] type=\(workflowType.rawValue) confidence=\(String(format: "%.2f", confidence)) stability=\(String(format: "%.2f", stabilityScore)) duration_s=\(dur)")
    }
}
