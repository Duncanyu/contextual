import Foundation

enum ContextCapabilityID: String, CaseIterable, Hashable, Sendable, Codable {
	case activeApp
	case windowTitle
	case selectedText
	case clipboardText
	case axWindowContent
	case activeWindowSnapshot
	case visualDescriptor
	case screenOCR
	case screenVision
	case typingActivity
	case cursorActivity
	case audioInput
}

enum ContextCollectionCost: String, Hashable, Sendable, Codable {
	case cheap
	case medium
	case expensive
}

enum ContextPrivacySensitivity: String, Hashable, Sendable, Codable {
	case low
	case moderate
	case high
}

enum ContextLatencyCategory: String, Hashable, Sendable, Codable {
	case instant
	case fast
	case slow
}

enum ContextPermissionState: String, Hashable, Sendable, Codable {
	case notRequired
	case unknown
	case granted
	case denied
	case unavailable
}

enum ContextCollectionMode: String, Hashable, Sendable, Codable {
	case automatic
	case manual
	case hybrid
}

struct ContextCapability: Identifiable, Hashable, Sendable, Codable {
	let id: ContextCapabilityID
	var displayName: String

	/// Whether the capability is usable in the current environment (does not imply content exists right now).
	var isAvailable: Bool
	/// Permission state for the underlying source; registry must never prompt for permissions.
	var permissionState: ContextPermissionState

	/// The intended "freshness" interval for future budgeting/decay systems.
	var freshnessInterval: TimeInterval?
	var collectionCost: ContextCollectionCost
	var privacySensitivity: ContextPrivacySensitivity
	var latencyCategory: ContextLatencyCategory
	var collectionMode: ContextCollectionMode

	/// Metadata-only stale marker; registry can invalidate without implementing decay.
	var isCurrentlyStale: Bool

	var supportsContinuousCollection: Bool
	var supportsManualInvocation: Bool
	var supportsBackgroundCollection: Bool

	var notes: String?
	var sourceVersion: String?
	var metadata: [String: String]?

	/// Internal bookkeeping to support staleness and future decay integration.
	var lastAvailabilityCheckedAt: Date?
	var lastUpdatedAt: Date?
	var lastInvalidatedAt: Date?
}

