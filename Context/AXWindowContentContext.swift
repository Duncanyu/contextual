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

	/// Conservative visibility accounting from SystemSources. Text must be
	/// plausibly inside the focused window/visible region before it can be used as
	/// primary result context.
	let visibleNodeCount: Int
	let hiddenNodeCount: Int
	let offscreenNodeCount: Int
	let acceptedVisibleChars: Int
	let rejectedInvisibleChars: Int
	let userVisibleConfidence: Double

	static let recommendedFreshnessSeconds: TimeInterval = 15
	var isStale: Bool { Date().timeIntervalSince(extractedAt) > Self.recommendedFreshnessSeconds }

	init(
		id: UUID,
		extractedAt: Date,
		appName: String?,
		bundleIdentifier: String?,
		sourceWindowTitleAvailable: Bool,
		visibleTextFragments: [String],
		visibleControlKinds: [AXUIKind],
		estimatedVisibleTextLength: Int,
		estimatedInteractiveElementCount: Int,
		containsScrollableRegion: Bool,
		containsEditorLikeRegion: Bool,
		containsFormLikeRegion: Bool,
		containsTableLikeRegion: Bool,
		hierarchyDepthEstimate: Int,
		extractionConfidence: Double,
		visibleNodeCount: Int = 0,
		hiddenNodeCount: Int = 0,
		offscreenNodeCount: Int = 0,
		acceptedVisibleChars: Int = 0,
		rejectedInvisibleChars: Int = 0,
		userVisibleConfidence: Double = 0.0
	) {
		self.id = id
		self.extractedAt = extractedAt
		self.appName = appName
		self.bundleIdentifier = bundleIdentifier
		self.sourceWindowTitleAvailable = sourceWindowTitleAvailable
		self.visibleTextFragments = visibleTextFragments
		self.visibleControlKinds = visibleControlKinds
		self.estimatedVisibleTextLength = estimatedVisibleTextLength
		self.estimatedInteractiveElementCount = estimatedInteractiveElementCount
		self.containsScrollableRegion = containsScrollableRegion
		self.containsEditorLikeRegion = containsEditorLikeRegion
		self.containsFormLikeRegion = containsFormLikeRegion
		self.containsTableLikeRegion = containsTableLikeRegion
		self.hierarchyDepthEstimate = hierarchyDepthEstimate
		self.extractionConfidence = extractionConfidence
		self.visibleNodeCount = visibleNodeCount
		self.hiddenNodeCount = hiddenNodeCount
		self.offscreenNodeCount = offscreenNodeCount
		self.acceptedVisibleChars = acceptedVisibleChars
		self.rejectedInvisibleChars = rejectedInvisibleChars
		self.userVisibleConfidence = userVisibleConfidence
	}
}
