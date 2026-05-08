import Foundation

enum PointerState: String, Hashable, Sendable, Codable, CaseIterable {
	case idle
	case moving
	case clicking
	case interacting
	case burst
	case stopped
}

enum PointerBurstIntensity: String, Hashable, Sendable, Codable, CaseIterable {
	case none
	case low
	case medium
	case high
}

struct PointerActivityContext: Hashable, Sendable {
	let id: UUID
	let updatedAt: Date

	let appName: String?
	let bundleIdentifier: String?

	let isPointerActive: Bool
	let pointerState: PointerState

	let recentMoveEventCount: Int
	let recentClickEventCount: Int

	let movementBurstIntensity: PointerBurstIntensity
	let clickBurstIntensity: PointerBurstIntensity

	let sessionDuration: TimeInterval
	let idleDuration: TimeInterval

	/// 0...1: coarse estimate of user focus intensity from pointer activity only.
	let estimatedFocusIntensity: Double

	static let recommendedFreshnessSeconds: TimeInterval = 6
	var isStale: Bool { Date().timeIntervalSince(updatedAt) > Self.recommendedFreshnessSeconds }
}

