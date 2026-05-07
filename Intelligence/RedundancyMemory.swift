import Foundation

enum RedundancyEventType: String, Sendable {
	case shown
	case autoDismissed = "auto_dismissed"
	case manuallyDismissed = "manual_dismissed"
	case accepted
}

struct RedundancyMemoryAdjustment: Equatable, Sendable {
	let scoreDelta: Double
	let reason: String
}

/// Session-only, in-memory behavior tuning. Uses privacy-safe keys only.
@MainActor
final class RedundancyMemory {
	private struct Entry {
		var shown: [Date] = []
		var autoDismissed: [Date] = []
		var manuallyDismissed: [Date] = []
		var accepted: [Date] = []
		var lastTouched: Date = Date()
		let actionId: String
	}

	private var entries: [String: Entry] = [:]
	private let maxEntries = 220
	private let pruneAfter: TimeInterval = 12 * 60

	private var lastAdjustmentLogSig: String?
	private var lastAdjustmentLogAt: Date?

	func record(event: RedundancyEventType, key: String, actionId: String, now: Date = Date()) {
		var e = entries[key] ?? Entry(actionId: actionId)
		e.lastTouched = now

		switch event {
		case .shown:
			e.shown.append(now)
		case .autoDismissed:
			e.autoDismissed.append(now)
		case .manuallyDismissed:
			e.manuallyDismissed.append(now)
		case .accepted:
			e.accepted.append(now)
		}

		// Keep tiny bounded history per key.
		e.shown = Array(e.shown.suffix(6))
		e.autoDismissed = Array(e.autoDismissed.suffix(6))
		e.manuallyDismissed = Array(e.manuallyDismissed.suffix(6))
		e.accepted = Array(e.accepted.suffix(6))

		entries[key] = e
		pruneIfNeeded(now: now)

		print("[RedundancyMemory] event=\(event.rawValue) action=\(actionId)")
	}

	func adjustment(for key: String, actionId: String, now: Date = Date()) -> RedundancyMemoryAdjustment {
		guard let e = entries[key], e.actionId == actionId else {
			return RedundancyMemoryAdjustment(scoreDelta: 0, reason: "none")
		}

		// Windows
		let acceptWindow: TimeInterval = 5 * 60
		let autoWindow: TimeInterval = 2 * 60
		let manualWindow: TimeInterval = 10 * 60
		let shownNoAcceptWindow: TimeInterval = 2 * 60

		let acceptCount = e.accepted.filter { now.timeIntervalSince($0) < acceptWindow }.count
		let autoCount = e.autoDismissed.filter { now.timeIntervalSince($0) < autoWindow }.count
		let manualCount = e.manuallyDismissed.filter { now.timeIntervalSince($0) < manualWindow }.count
		let shownCount = e.shown.filter { now.timeIntervalSince($0) < shownNoAcceptWindow }.count
		let recentAccepted = acceptCount > 0

		var delta: Double = 0
		var reasonParts: [String] = []

		if recentAccepted {
			delta += min(0.10, 0.05 + 0.02 * Double(max(0, acceptCount - 1)))
			reasonParts.append("accepted")
		}

		if autoCount > 0 {
			delta -= 0.05
			reasonParts.append("auto")
		}

		if manualCount > 0 {
			if manualCount >= 2 {
				delta -= 0.25
				reasonParts.append("manual_x\(manualCount)")
			} else {
				delta -= 0.15
				reasonParts.append("manual")
			}
		}

		// Shown but not accepted recently implies “ignored”.
		if shownCount >= 2, !recentAccepted {
			delta -= 0.10
			reasonParts.append("ignored")
		}

		delta = min(0.10, max(-0.30, delta))
		let reason = reasonParts.isEmpty ? "none" : reasonParts.joined(separator: "+")

		logAdjustmentIfNeeded(actionId: actionId, delta: delta, reason: reason, now: now)
		return RedundancyMemoryAdjustment(scoreDelta: delta, reason: reason)
	}

	private func logAdjustmentIfNeeded(actionId: String, delta: Double, reason: String, now: Date) {
		let d = String(format: "%.2f", delta)
		let sig = "\(actionId)|\(d)|\(reason)"
		if let p = lastAdjustmentLogSig, p == sig, let t = lastAdjustmentLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastAdjustmentLogSig = sig
		lastAdjustmentLogAt = now
		print("[RedundancyMemory] adjustment action=\(actionId) delta=\(d) reason=\(reason)")
	}

	private func pruneIfNeeded(now: Date) {
		entries = entries.filter { _, e in
			now.timeIntervalSince(e.lastTouched) < pruneAfter
		}
		if entries.count <= maxEntries { return }

		// Drop oldest touched first.
		let sorted = entries.sorted { $0.value.lastTouched < $1.value.lastTouched }
		let dropCount = entries.count - maxEntries
		for i in 0..<dropCount {
			entries.removeValue(forKey: sorted[i].key)
		}
	}
}

