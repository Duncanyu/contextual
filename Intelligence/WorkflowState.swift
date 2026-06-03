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
    case designing
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
    public let provenanceCorrected: Bool?
    public let correctionStrength: String?
    public let volatilityScore: Double?

    public var durationSeconds: TimeInterval {
        max(0, lastUpdatedAt.timeIntervalSince(startedAt))
    }

    public var workflowTrustScore: Double {
        guard workflowType != .unknown else { return 0.0 }
        
        let confWeight = 0.4
        let stabWeight = 0.4
        let evidenceWeight = 0.2
        
        let confPart = confidence * confWeight
        let stabPart = stabilityScore * stabWeight
        let evidencePart = evidence.isEmpty ? 0.0 : evidenceWeight
        
        var base = confPart + stabPart + evidencePart
        
        // Volatility penalty: subtract up to 0.3
        base -= (volatilityScore ?? 0.0) * 0.3
        
        // Correction influence: if provenance corrected, add a small 0.05 bonus
        if provenanceCorrected == true {
            base += 0.05
        }
        
        return min(max(base, 0.0), 1.0)
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
        sourcePacketHash: String,
        provenanceCorrected: Bool? = false,
        correctionStrength: String? = "none",
        volatilityScore: Double? = 0.0
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
        self.provenanceCorrected = provenanceCorrected
        self.correctionStrength = correctionStrength
        self.volatilityScore = volatilityScore
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
        sourcePacketHash: "",
        provenanceCorrected: false,
        correctionStrength: "none",
        volatilityScore: 0.0
    )

    /// Canonical Phase B log line.
    public func log() {
        let dur = Int(durationSeconds)
        let trust = String(format: "%.2f", workflowTrustScore)
        print("[WorkflowState] type=\(workflowType.rawValue) confidence=\(String(format: "%.2f", confidence)) stability=\(String(format: "%.2f", stabilityScore)) duration_s=\(dur) trust=\(trust)")
    }
}
