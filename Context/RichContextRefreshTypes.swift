import Foundation

enum RichContextRefreshTrigger: String, Hashable, Sendable, Codable {
	case manual
	case appChanged
	case selectionChanged
	case clipboardChanged
	case screenOCRCompleted
	case debugSelfTest
}

struct RichContextRefreshRequest: Sendable {
	let trigger: RichContextRefreshTrigger
	let reason: String

	let includeWindowSnapshot: Bool
	let includeVisualDescriptor: Bool
	let includeAXContent: Bool
	let includeTypingActivity: Bool
	let includePointerActivity: Bool

	/// If false, the pipeline should avoid medium/expensive collection (still may read cheap metadata).
	let allowExpensiveSources: Bool

	let currentContextModel: ContextModel
	let isActionExecuting: Bool
	let currentIntelligenceConfidence: Double?
}

struct RichContextRefreshResult: Hashable, Sendable {
	let id: UUID
	let startedAt: Date
	let finishedAt: Date
	let wasCancelled: Bool

	let collectedSources: [FusedContextSource]
	let skippedSources: [FusedContextSource: String]

	let fusedPacket: FusedContextPacket?
	let updatedCanonicalState: Bool

	/// Metadata-only summary (never raw content).
	let debugSummaryMetadata: [String: String]
}

