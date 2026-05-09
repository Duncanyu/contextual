import Foundation

enum FusedPrimarySource: String, Hashable, Sendable, Codable {
	case none
	case selectedText
	case axText
	case screenOCR
	case clipboardText
}

enum FusedTextSource: String, Hashable, Sendable, Codable {
	case none
	case selectedText
	case axText
	case screenOCR
	case clipboardText
}

struct FusedContextPacket: Hashable, Sendable {
	let id: UUID
	let createdAt: Date

	let primarySource: FusedPrimarySource
	let availableSources: [ContextCapabilityID]
	let staleSources: [ContextCapabilityID]

	let appName: String?
	let bundleIdentifier: String?
	let windowTitleAvailable: Bool

	let primaryTextSource: FusedTextSource
	let textAvailability: Bool
	let textLength: Int
	let lineCount: Int

	let hasSelectedText: Bool
	let hasClipboardText: Bool
	let hasOCRText: Bool
	let hasAXText: Bool
	let hasWindowSnapshot: Bool
	let hasVisualDescriptor: Bool
	let hasTypingActivity: Bool
	let hasPointerActivity: Bool

	let visualKinds: [VisualUIKind]
	let uiStructureHints: [String]
	let typingState: TypingState?
	let pointerState: PointerState?

	/// 0...1 overall confidence in chosen primary text + supporting modalities.
	let confidence: Double
	/// 0...1 "how fresh" this fused packet is.
	let freshnessScore: Double
	/// 0...1 conflict level between competing signals.
	let conflictScore: Double
	let isStale: Bool

	/// Arbitration output (metadata-only; no raw content).
	let suppressedSources: [FusedContextSource]
	let supportingSources: [FusedContextSource]
	let arbitrationReasons: [String]

	/// Metadata-only summary for debugging/instrumentation (never raw content).
	let debugSummaryMetadata: [String: String]
}

