import Foundation

/// Lightweight, temporary workflow label inferred from fused + interaction metadata only.
enum InferredWorkflow: String, Hashable, Sendable, Codable, CaseIterable {
	case debugging
	case writing
	case research
	case browsing
	case editing
	case reviewing
	case unknown
}

/// Result of workflow inference (in-memory only; never persisted).
struct WorkflowInferenceResult: Equatable, Sendable {
	let workflow: InferredWorkflow
	/// 0...1 — conservative confidence after arbitration.
	let confidence: Double
	/// Short, metadata-only codes (no raw text, no OCR/AX payloads).
	let contributingSignals: [String]
	let inferredAt: Date
	/// True when fused context is missing, stale-on-packet, or evidence is too weak to trust.
	let isStale: Bool
	/// Optional metadata-safe hint for debug UI (never user content).
	let summaryHint: String?
	/// Fused packet id used for this inference (nil when fused was absent).
	let sourceFusedId: UUID?
}
