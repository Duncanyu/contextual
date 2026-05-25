import Foundation

/// Floating-only lifecycle (T10.4). Does not affect available actions or in-panel suggestions.
@MainActor
final class FloatingSuggestionLifecycle {
	enum RecordedState: String {
		case shown
		case autoDismissed = "auto_dismissed"
		case manuallyDismissed = "manually_dismissed"
		case accepted
	}

	struct SuppressionCheck: Equatable {
		let suppressed: Bool
		let reason: String?
		let safeKey: String
	}

	private struct Entry {
		var lastShown: Date?
		var lastAutoDismissed: Date?
		var lastManuallyDismissed: Date?
		var lastAccepted: Date?
		let primaryActionId: String
		let profile: ContentSimilarityProfile
	}

	private var entries: [String: Entry] = [:]

	private var shownWindow: TimeInterval { AgenticPivot.usePersistentProposals ? 10 : 30 }
	private var autoDismissWindow: TimeInterval { AgenticPivot.usePersistentProposals ? 10 : 30 }
	private var acceptedWindow: TimeInterval { AgenticPivot.usePersistentProposals ? 30 : 60 }
	private var manualWindow: TimeInterval { AgenticPivot.usePersistentProposals ? 90 : 180 }
	private let pruneAge: TimeInterval = 12 * 60

	/// Clears floating suppression state when leaving screen-OCR input channel (T12.10).
	func clearAllForInputChannelReset() {
		let n = entries.count
		entries.removeAll()
		if n > 0 {
			print("[FloatingLifecycle] channel_reset cleared=\(n)")
		}
	}

	private var lastSuppressLogSignature: String?
	private var lastSuppressLogAt: Date?

	// MARK: - Public

	func exactKey(
		triggerType: TriggerType,
		primaryActionId: String,
		profile: ContentSimilarityProfile
	) -> String {
		let basis = "\(triggerType.rawValue)|\(primaryActionId)|\(profile.lengthBucket)|\(profile.prefixHash)|\(profile.suffixHash)"
		return String(Self.fnv1a64(basis), radix: 16)
	}

	func safeLogKey(
		triggerType: TriggerType,
		primaryActionId: String,
		profile: ContentSimilarityProfile
	) -> String {
		let ph = String(profile.prefixHash, radix: 16)
		let sh = String(profile.suffixHash, radix: 16)
		return "trig=\(triggerType.rawValue)|primary=\(primaryActionId)|bucket=\(profile.lengthBucket)|ph=\(ph)|sh=\(sh)"
	}

	func shouldSuppressNewFloating(
		triggerType: TriggerType,
		primaryActionId: String,
		profile: ContentSimilarityProfile,
		now: Date = Date()
	) -> SuppressionCheck {
		pruneStale(now: now)
		let key = exactKey(triggerType: triggerType, primaryActionId: primaryActionId, profile: profile)
		let safeKey = safeLogKey(triggerType: triggerType, primaryActionId: primaryActionId, profile: profile)

		if let reason = activeSuppressionReason(exactKey: key, now: now) {
			return SuppressionCheck(suppressed: true, reason: reason, safeKey: safeKey)
		}

		for (_, entry) in entries {
			guard entry.primaryActionId == primaryActionId else { continue }
			guard ContentSimilarityProfile.isSimilar(entry.profile, profile) else { continue }
			if let reason = suppressionReason(for: entry, now: now) {
				return SuppressionCheck(suppressed: true, reason: reason, safeKey: safeKey)
			}
		}

		return SuppressionCheck(suppressed: false, reason: nil, safeKey: safeKey)
	}

	func record(_ state: RecordedState, exactKey: String, primaryActionId: String, profile: ContentSimilarityProfile, now: Date = Date()) {
		var entry = entries[exactKey] ?? Entry(
			lastShown: nil,
			lastAutoDismissed: nil,
			lastManuallyDismissed: nil,
			lastAccepted: nil,
			primaryActionId: primaryActionId,
			profile: profile
		)
		switch state {
		case .shown:
			entry.lastShown = now
		case .autoDismissed:
			entry.lastAutoDismissed = now
		case .manuallyDismissed:
			entry.lastManuallyDismissed = now
		case .accepted:
			entry.lastAccepted = now
		}
		entries[exactKey] = entry
	}

	func logRecorded(state: RecordedState, safeKey: String) {
		print("[FloatingLifecycle] recorded state=\(state.rawValue) key=\(safeKey)")
	}

	func logSuppressedIfNeeded(state: String, safeKey: String) {
		let sig = "\(state)|\(safeKey)"
		let t = Date()
		if let prev = lastSuppressLogSignature, prev == sig, let u = lastSuppressLogAt, t.timeIntervalSince(u) < 2.0 {
			return
		}
		lastSuppressLogSignature = sig
		lastSuppressLogAt = t
		print("[FloatingLifecycle] suppressed state=\(state) key=\(safeKey)")
	}

	// MARK: - Internals

	private func activeSuppressionReason(exactKey: String, now: Date) -> String? {
		if let e = entries[exactKey] {
			return suppressionReason(for: e, now: now)
		}
		return nil
	}

	private func suppressionReason(for entry: Entry, now: Date) -> String? {
		if let t = entry.lastManuallyDismissed, now.timeIntervalSince(t) < manualWindow {
			return "manual_dismiss"
		}
		if let t = entry.lastAccepted, now.timeIntervalSince(t) < acceptedWindow {
			return "accepted"
		}
		if let t = entry.lastShown, now.timeIntervalSince(t) < shownWindow {
			return "recently_shown"
		}
		if let t = entry.lastAutoDismissed, now.timeIntervalSince(t) < autoDismissWindow {
			return "auto_dismissed"
		}
		return nil
	}

	private func pruneStale(now: Date) {
		entries = entries.filter { _, e in
			let candidates = [e.lastShown, e.lastAutoDismissed, e.lastManuallyDismissed, e.lastAccepted].compactMap { $0 }
			guard let latest = candidates.max() else { return false }
			return now.timeIntervalSince(latest) < pruneAge
		}
	}

	private static func fnv1a64(_ text: String) -> UInt64 {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for b in text.utf8 {
			hash ^= UInt64(b)
			hash &*= 1_099_511_628_211
		}
		return hash
	}
}
