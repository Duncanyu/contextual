import Foundation

/// Internal-only structural report summarizing workflow inference confidence,
/// stability, and validation metrics. No UI displays this.
public struct WorkflowConfidenceReport: Sendable, Codable, Equatable {
    public let currentWorkflow: String
    public let confidence: Double
    public let stabilityScore: Double
    public let provenanceCorrected: Bool
    public let contextShiftDetected: Bool
    public let evidenceSources: [String]
    public let trustScore: Double

    public init(
        currentWorkflow: String,
        confidence: Double,
        stabilityScore: Double,
        provenanceCorrected: Bool,
        contextShiftDetected: Bool,
        evidenceSources: [String],
        trustScore: Double
    ) {
        self.currentWorkflow = currentWorkflow
        self.confidence = confidence
        self.stabilityScore = stabilityScore
        self.provenanceCorrected = provenanceCorrected
        self.contextShiftDetected = contextShiftDetected
        self.evidenceSources = evidenceSources
        self.trustScore = trustScore
    }
}
