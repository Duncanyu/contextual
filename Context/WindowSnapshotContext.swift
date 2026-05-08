import CoreGraphics
import Foundation

struct WindowSnapshotContext: Hashable, Sendable {
	enum SnapshotSource: String, Hashable, Sendable {
		case activeWindow
	}

	let id: UUID
	let capturedAt: Date

	let appName: String?
	let bundleIdentifier: String?

	/// Whether a window title existed at capture time (title should not be logged).
	let windowTitleAvailable: Bool

	let imageWidth: Int
	let imageHeight: Int
	let source: SnapshotSource

	/// In-memory only; never persisted.
	let image: CGImage

	/// Recommended freshness window (future budgeting/decay hook).
	static let recommendedFreshnessSeconds: TimeInterval = 20

	var ageSeconds: TimeInterval { Date().timeIntervalSince(capturedAt) }
	var isStale: Bool { ageSeconds > Self.recommendedFreshnessSeconds }
}

