import Foundation

enum AXUIKind: String, Hashable, Sendable, Codable, CaseIterable {
	case button
	case textField
	case staticText
	case table
	case row
	case list
	case outline
	case scrollArea
	case group
	case toolbar
	case editor
	case dialog
	case unknown
}

struct AXWindowContentContext: Hashable, Sendable {
	let id: UUID
	let extractedAt: Date
	let appName: String?
	let bundleIdentifier: String?
	let sourceWindowTitleAvailable: Bool

	/// Lightweight visible fragments only; bounded and in-memory only.
	let visibleTextFragments: [String]
	let visibleControlKinds: [AXUIKind]

	let estimatedVisibleTextLength: Int
	let estimatedInteractiveElementCount: Int

	let containsScrollableRegion: Bool
	let containsEditorLikeRegion: Bool
	let containsFormLikeRegion: Bool
	let containsTableLikeRegion: Bool

	let hierarchyDepthEstimate: Int
	let extractionConfidence: Double

	static let recommendedFreshnessSeconds: TimeInterval = 15
	var isStale: Bool { Date().timeIntervalSince(extractedAt) > Self.recommendedFreshnessSeconds }
}

