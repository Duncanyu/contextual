import Foundation

/// Central, in-memory registry describing context source capabilities.
/// Infrastructure only: metadata, availability, and invalidation hooks (no collection, no permissions prompts).
final class ContextCapabilityRegistry {
	static let shared = ContextCapabilityRegistry()

	private let lock = NSLock()
	private var capabilitiesById: [ContextCapabilityID: ContextCapability] = [:]
	private var lastAvailabilityRefreshAt: Date?

	private init() {
		seedInitialCapabilities()
		refreshAvailabilityIfNeeded(force: true)
	}

	func allCapabilities() -> [ContextCapability] {
		lock.lock()
		defer { lock.unlock() }
		return ContextCapabilityID.allCases.compactMap { capabilitiesById[$0] }
	}

	func capability(for id: ContextCapabilityID) -> ContextCapability? {
		lock.lock()
		defer { lock.unlock() }
		return capabilitiesById[id]
	}

	func refreshAvailabilityIfNeeded() {
		refreshAvailabilityIfNeeded(force: false)
	}

	func updateCapability(_ capability: ContextCapability) {
		lock.lock()
		let exists = (capabilitiesById[capability.id] != nil)
		capabilitiesById[capability.id] = capability
		lock.unlock()

		print("[ContextCapability] updated id=\(capability.id.rawValue) availability=\(capability.isAvailable)")
		if !exists {
			print("[ContextCapability] registered id=\(capability.id.rawValue)")
		}
	}

	func updateCapability(id: ContextCapabilityID, mutate: (inout ContextCapability) -> Void) {
		lock.lock()
		guard var existing = capabilitiesById[id] else {
			lock.unlock()
			return
		}
		mutate(&existing)
		capabilitiesById[id] = existing
		lock.unlock()

		print("[ContextCapability] updated id=\(id.rawValue) availability=\(existing.isAvailable)")
	}

	func invalidateCapability(_ id: ContextCapabilityID) {
		lock.lock()
		guard var existing = capabilitiesById[id] else {
			lock.unlock()
			return
		}
		existing.isCurrentlyStale = true
		existing.lastInvalidatedAt = Date()
		capabilitiesById[id] = existing
		lock.unlock()

		print("[ContextCapability] invalidated id=\(id.rawValue)")
	}

	// MARK: - Private

	private func refreshAvailabilityIfNeeded(force: Bool) {
		let now = Date()
		if !force, let lastAvailabilityRefreshAt, now.timeIntervalSince(lastAvailabilityRefreshAt) < 2.0 {
			return
		}

		// Evaluate permission/availability via SystemSources boundary helpers (no prompts).
		let axTrusted = SelectionSource.isAccessibilityTrusted()
		let screenAuthorized = ScreenCaptureSource.isScreenRecordingAuthorized()

		lock.lock()
		lastAvailabilityRefreshAt = now

		updateAvailabilityLocked(
			id: .windowTitle,
			isAvailable: axTrusted,
			permissionState: axTrusted ? .granted : .denied,
			checkedAt: now
		)
		updateAvailabilityLocked(
			id: .selectedText,
			isAvailable: axTrusted,
			permissionState: axTrusted ? .granted : .denied,
			checkedAt: now
		)

		// Screen OCR depends on manual capture pipeline; treat permission as screen recording.
		updateAvailabilityLocked(
			id: .screenOCR,
			isAvailable: screenAuthorized,
			permissionState: screenAuthorized ? .granted : .denied,
			checkedAt: now
		)

		updateAvailabilityLocked(
			id: .activeWindowSnapshot,
			isAvailable: screenAuthorized,
			permissionState: screenAuthorized ? .granted : .denied,
			checkedAt: now
		)

		lock.unlock()
	}

	private func updateAvailabilityLocked(
		id: ContextCapabilityID,
		isAvailable: Bool,
		permissionState: ContextPermissionState,
		checkedAt: Date
	) {
		guard var cap = capabilitiesById[id] else { return }
		let changed = (cap.isAvailable != isAvailable) || (cap.permissionState != permissionState)
		cap.isAvailable = isAvailable
		cap.permissionState = permissionState
		cap.lastAvailabilityCheckedAt = checkedAt
		capabilitiesById[id] = cap

		if changed {
			print("[ContextCapability] updated id=\(id.rawValue) availability=\(isAvailable)")
		}
	}

	private func register(_ capability: ContextCapability) {
		lock.lock()
		let exists = (capabilitiesById[capability.id] != nil)
		capabilitiesById[capability.id] = capability
		lock.unlock()

		if !exists {
			print("[ContextCapability] registered id=\(capability.id.rawValue)")
		}
	}

	private func seedInitialCapabilities() {
		// Metadata-only; no new collection is introduced here.
		register(
			ContextCapability(
				id: .activeApp,
				displayName: "Active App",
				isAvailable: true,
				permissionState: .notRequired,
				freshnessInterval: 1.0,
				collectionCost: .cheap,
				privacySensitivity: .low,
				latencyCategory: .instant,
				collectionMode: .automatic,
				isCurrentlyStale: false,
				supportsContinuousCollection: true,
				supportsManualInvocation: false,
				supportsBackgroundCollection: true,
				notes: nil,
				sourceVersion: nil,
				metadata: nil,
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)

		register(
			ContextCapability(
				id: .windowTitle,
				displayName: "Window Title",
				isAvailable: true,
				permissionState: .unknown,
				freshnessInterval: 1.0,
				collectionCost: .cheap,
				privacySensitivity: .moderate,
				latencyCategory: .instant,
				collectionMode: .automatic,
				isCurrentlyStale: false,
				supportsContinuousCollection: true,
				supportsManualInvocation: false,
				supportsBackgroundCollection: true,
				notes: "Availability depends on Accessibility permission.",
				sourceVersion: nil,
				metadata: nil,
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)

		register(
			ContextCapability(
				id: .selectedText,
				displayName: "Selected Text",
				isAvailable: true,
				permissionState: .unknown,
				freshnessInterval: 1.0,
				collectionCost: .cheap,
				privacySensitivity: .high,
				latencyCategory: .fast,
				collectionMode: .automatic,
				isCurrentlyStale: false,
				supportsContinuousCollection: true,
				supportsManualInvocation: true,
				supportsBackgroundCollection: true,
				notes: "Accessibility-dependent selection capture.",
				sourceVersion: nil,
				metadata: nil,
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)

		register(
			ContextCapability(
				id: .clipboardText,
				displayName: "Clipboard Text",
				isAvailable: true,
				permissionState: .notRequired,
				freshnessInterval: 2.0,
				collectionCost: .cheap,
				privacySensitivity: .moderate,
				latencyCategory: .instant,
				collectionMode: .automatic,
				isCurrentlyStale: false,
				supportsContinuousCollection: true,
				supportsManualInvocation: false,
				supportsBackgroundCollection: true,
				notes: nil,
				sourceVersion: nil,
				metadata: nil,
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)

		register(
			ContextCapability(
				id: .activeWindowSnapshot,
				displayName: "Active Window Snapshot",
				isAvailable: true,
				permissionState: .unknown,
				freshnessInterval: 20.0,
				collectionCost: .medium,
				privacySensitivity: .high,
				latencyCategory: .fast,
				collectionMode: .manual,
				isCurrentlyStale: true,
				supportsContinuousCollection: false,
				supportsManualInvocation: true,
				supportsBackgroundCollection: false,
				notes: "Captures frontmost window only; depends on Screen Recording permission.",
				sourceVersion: nil,
				metadata: nil,
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)

		register(
			ContextCapability(
				id: .screenOCR,
				displayName: "Screen OCR",
				isAvailable: true,
				permissionState: .unknown,
				freshnessInterval: 60.0,
				collectionCost: .expensive,
				privacySensitivity: .high,
				latencyCategory: .slow,
				collectionMode: .hybrid,
				isCurrentlyStale: true,
				supportsContinuousCollection: false,
				supportsManualInvocation: true,
				supportsBackgroundCollection: false,
				notes: "Manual/hybrid: depends on explicit capture + OCR pipeline.",
				sourceVersion: nil,
				metadata: nil,
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)

		register(
			ContextCapability(
				id: .screenVision,
				displayName: "Screen Vision",
				isAvailable: false,
				permissionState: .unavailable,
				freshnessInterval: nil,
				collectionCost: .expensive,
				privacySensitivity: .high,
				latencyCategory: .slow,
				collectionMode: .manual,
				isCurrentlyStale: true,
				supportsContinuousCollection: false,
				supportsManualInvocation: true,
				supportsBackgroundCollection: false,
				notes: "Unavailable placeholder (no implementation yet).",
				sourceVersion: nil,
				metadata: ["status": "placeholder"],
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)

		register(
			ContextCapability(
				id: .typingActivity,
				displayName: "Typing Activity",
				isAvailable: false,
				permissionState: .unavailable,
				freshnessInterval: 1.0,
				collectionCost: .cheap,
				privacySensitivity: .high,
				latencyCategory: .instant,
				collectionMode: .automatic,
				isCurrentlyStale: true,
				supportsContinuousCollection: true,
				supportsManualInvocation: false,
				supportsBackgroundCollection: true,
				notes: "Unavailable placeholder (no implementation yet).",
				sourceVersion: nil,
				metadata: ["status": "placeholder"],
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)

		register(
			ContextCapability(
				id: .cursorActivity,
				displayName: "Cursor Activity",
				isAvailable: false,
				permissionState: .unavailable,
				freshnessInterval: 1.0,
				collectionCost: .cheap,
				privacySensitivity: .moderate,
				latencyCategory: .instant,
				collectionMode: .automatic,
				isCurrentlyStale: true,
				supportsContinuousCollection: true,
				supportsManualInvocation: false,
				supportsBackgroundCollection: true,
				notes: "Unavailable placeholder (no implementation yet).",
				sourceVersion: nil,
				metadata: ["status": "placeholder"],
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)

		register(
			ContextCapability(
				id: .audioInput,
				displayName: "Audio Input",
				isAvailable: false,
				permissionState: .unavailable,
				freshnessInterval: nil,
				collectionCost: .expensive,
				privacySensitivity: .high,
				latencyCategory: .slow,
				collectionMode: .manual,
				isCurrentlyStale: true,
				supportsContinuousCollection: false,
				supportsManualInvocation: true,
				supportsBackgroundCollection: false,
				notes: "Unavailable placeholder (no implementation yet).",
				sourceVersion: nil,
				metadata: ["status": "placeholder"],
				lastAvailabilityCheckedAt: nil,
				lastUpdatedAt: nil,
				lastInvalidatedAt: nil
			)
		)
	}
}

