import Foundation

/// Stage-1 output from the `ContextExecutionEngine`.
///
/// The local model produces this from temporal context signals. It is
/// intentionally *not* an executable action — it is a free-form intent that
/// the engine's second stage interprets against the same context to produce a
/// structured briefing. There is no action registry; the engine never selects
/// a code path based on this string.
public struct InferredIntent: Sendable, Codable, Equatable {
    /// Free-form verb phrase (e.g. "understand_differences", "identify_key_points").
    public let intent: String
    /// Natural language subject the intent applies to (e.g. "recently viewed products").
    public let subject: String
    /// Brief sentence stating what would satisfy the user.
    public let goal: String
    /// 0..1.
    public let confidence: Double
    /// `model` when the local model produced it, `fallback` when synthesized
    /// from context signals deterministically.
    public let source: String

    public init(intent: String, subject: String, goal: String, confidence: Double, source: String) {
        self.intent = intent
        self.subject = subject
        self.goal = goal
        self.confidence = max(0.0, min(confidence, 1.0))
        self.source = source
    }

    public static let empty = InferredIntent(
        intent: "unknown",
        subject: "the user's recent activity",
        goal: "Make sense of what the user has been doing.",
        confidence: 0.0,
        source: "fallback"
    )
}
