import Foundation

/// Coarse quality grade for the evidence underlying a single execution.
/// The engine uses this to gate how confident its output can be:
/// `title_only` → conservative, no comparison claims.
/// `partial_signal` → cautious, can describe what's visible.
/// `product_metadata` → can compare specific facts the page exposed.
public enum ContextEvidenceQuality: String, Sendable, Codable, Equatable {
    case title_only
    case partial_signal
    case product_metadata
}

/// Roll-up of all evidence the engine has at a given moment. The fields are
/// derived from the envelope; they DO NOT introduce any new branching on
/// workflow or app — they describe the *evidence*, not the activity.
public struct ContextEvidence: Sendable, Codable, Equatable {
    public let quality: ContextEvidenceQuality
    public let groundedFactsCount: Int
    public let hasURL: Bool
    public let hasOCR: Bool
    public let hasSelection: Bool
    public let hasPageMetadata: Bool
    public let hasProductFacts: Bool

    public init(
        quality: ContextEvidenceQuality,
        groundedFactsCount: Int,
        hasURL: Bool,
        hasOCR: Bool,
        hasSelection: Bool,
        hasPageMetadata: Bool,
        hasProductFacts: Bool
    ) {
        self.quality = quality
        self.groundedFactsCount = groundedFactsCount
        self.hasURL = hasURL
        self.hasOCR = hasOCR
        self.hasSelection = hasSelection
        self.hasPageMetadata = hasPageMetadata
        self.hasProductFacts = hasProductFacts
    }

    public static let titleOnly = ContextEvidence(
        quality: .title_only,
        groundedFactsCount: 0,
        hasURL: false,
        hasOCR: false,
        hasSelection: false,
        hasPageMetadata: false,
        hasProductFacts: false
    )
}
