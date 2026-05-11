import Foundation

/// Metadata-only continuity contributors (no user content).
enum SessionContinuitySignal: String, Hashable, Sendable, Codable, CaseIterable {
	case workflowStreak
	case bundleLoop
	case multimodalStable
	case decayApplied
	case oscillationDampen
	case weakEvidenceDampen
	case trajectoryEcho
}

/// Bounded snapshot of inferred patterns over a short window.
struct SessionPatternSnapshot: Equatable, Sendable {
	let dominantWorkflow: InferredWorkflow
	/// Recent workflow labels only (e.g. `debugging>debugging>browsing`), bounded elsewhere.
	let trajectoryCodes: String
	let patternConfidence: Double
	let continuityScore: Double
	let capturedAt: Date
}

/// Current session continuity view (in-memory only).
struct ContextualSessionState: Equatable, Sendable {
	let continuityScore: Double
	let continuityConfidence: Double
	let patternConfidence: Double
	let dominantWorkflow: InferredWorkflow
	let activeTrajectorySummary: String
	let contributingSignals: [SessionContinuitySignal]
	let updatedAt: Date
	let isStale: Bool
}
