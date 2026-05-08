import Foundation

enum VisualUIKind: String, Hashable, Sendable, Codable, CaseIterable {
	case editor
	case terminal
	case browser
	case article
	case chart
	case media
	case dialog
	case form
	case unknown
}

enum VisualDominantLayoutStyle: String, Hashable, Sendable, Codable {
	case grid
	case columns
	case singlePane
	case multiPane
	case unknown
}

struct VisualContextDescriptor: Hashable, Sendable, Codable {
	let generatedAt: Date
	let sourceSnapshotID: UUID

	/// Overall confidence for the visible UI kind list (0...1).
	let confidence: Double
	let visibleUIKinds: [VisualUIKind]

	/// 0...1 — rough proxy for edges and high-frequency detail.
	let estimatedTextDensity: Double
	/// 0...1 — rough proxy for large smooth regions / imagery.
	let estimatedVisualDensity: Double

	let estimatedPanelCount: Int
	let likelyScrollable: Bool
	let dominantLayoutStyle: VisualDominantLayoutStyle

	let containsLargeMonospaceRegion: Bool
	let containsLargeImageRegion: Bool
	let containsDialogLikeRegion: Bool
	let containsToolbarLikeRegion: Bool

	let isStale: Bool

	let metadata: [String: String]?
	let sourceAppHints: [String: String]?

	static let recommendedFreshnessSeconds: TimeInterval = 15
}

