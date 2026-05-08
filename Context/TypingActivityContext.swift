import Foundation

enum TypingState: String, Hashable, Sendable, Codable, CaseIterable {
	case idle
	case started
	case active
	case burst
	case stopped
}

enum TypingBurstIntensity: String, Hashable, Sendable, Codable, CaseIterable {
	case none
	case low
	case medium
	case high
}

struct TypingActivityContext: Hashable, Sendable {
	let id: UUID
	let updatedAt: Date

	let appName: String?
	let bundleIdentifier: String?

	let isTypingActive: Bool
	let typingState: TypingState
	let recentEventCount: Int
	let burstIntensity: TypingBurstIntensity

	let sessionDuration: TimeInterval
	let idleDuration: TimeInterval

	/// 0...1: coarse estimate of editing activity intensity.
	let estimatedEditingActivity: Double

	static let recommendedFreshnessSeconds: TimeInterval = 6
	var isStale: Bool { Date().timeIntervalSince(updatedAt) > Self.recommendedFreshnessSeconds }
}

