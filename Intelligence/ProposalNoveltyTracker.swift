import Foundation

/// Lightweight in-memory tracker for proposal novelty / repetition (T18.5 + T18.6A).
///
/// Keys include a context fingerprint (bundle + window title prefix + workflow + OCR/text flags)
/// so the same template on a different page is treated as a distinct entry with fresh novelty.
///
/// T18.6A: No raw content stored. Hard zero floor removed — replaced with a soft residual so
/// the quality-based score calculation still has a chance to surface useful proposals even when
/// the same page/proposal has been shown multiple times.
///
/// Entries older than `retentionWindow` are pruned automatically.
@MainActor
final class ProposalNoveltyTracker {

	static let shared = ProposalNoveltyTracker()

	// MARK: - Configuration

	/// Seconds after which an entry is considered stale and ignored.
	let retentionWindow: TimeInterval = 600 // 10 minutes
	/// Count threshold above which novelty is at its residual floor within the suppression window.
	private let suppressionCount = 3
	/// Window in which repeated surfacing rapidly lowers novelty.
	private let suppressionWindow: TimeInterval = 45 // 45 seconds
	/// Minimum novelty returned when shown once within the suppression window.
	private let singleShownNovelty: Double = 0.80
	/// Novelty returned when shown twice within the suppression window.
	private let doubleShownNovelty: Double = 0.50
	/// T18.6A: Soft residual instead of hard 0.0 — allows quality scoring to still pass mediocre novelty.
	/// Above noveltySuppress threshold (0.12) so it's not force-blocked; penalty still applied.
	let suppressionResidual: Double = 0.18

	// MARK: - Storage

	private struct Entry {
		var shownCount: Int
		var firstShownAt: Date
		var lastShownAt: Date
	}

	private var entries: [String: Entry] = [:]

	// MARK: - API

	/// Novelty score for this signature (0 = fully repeated; 1 = never seen).
	func noveltyScore(for signature: String, referenceTime: Date = Date()) -> Double {
		pruneStale(referenceTime: referenceTime)
		guard let entry = entries[signature] else { return 1.0 }

		let age = referenceTime.timeIntervalSince(entry.lastShownAt)
		if age >= retentionWindow { return 1.0 }

		// Within the suppression window — apply count-based decay.
		// T18.6A: no hard zero; suppressed proposals get suppressionResidual so quality scoring
		// can still surface them as panel-only if the proposal score is high enough.
		if age < suppressionWindow {
			if entry.shownCount >= suppressionCount { return suppressionResidual }
			if entry.shownCount == 2 { return doubleShownNovelty }
			if entry.shownCount == 1 { return singleShownNovelty }
		}

		// Outside suppression window but within retention — partial novelty.
		let staleness = age / retentionWindow
		return min(1.0, 0.6 + staleness * 0.4)
	}

	/// Record that this signature was surfaced to the user.
	func record(signature: String, at time: Date = Date()) {
		if var existing = entries[signature] {
			existing.shownCount += 1
			existing.lastShownAt = time
			entries[signature] = existing
		} else {
			entries[signature] = Entry(shownCount: 1, firstShownAt: time, lastShownAt: time)
		}
		print("[ChimeInPolicy] novelty signature=\(signature.prefix(40)) shown=\(entries[signature]?.shownCount ?? 0)")
	}

	/// Remove entries older than `retentionWindow`.
	func pruneStale(referenceTime: Date = Date()) {
		entries = entries.filter { _, entry in
			referenceTime.timeIntervalSince(entry.lastShownAt) < retentionWindow
		}
	}

	/// Best-effort signature for a panel item (workflow + primitive signature, no raw text).
	static func signature(
		workflowType: WorkflowType,
		primitiveSignature: String?,
		intentType: IntentType
	) -> String {
		let primitive = primitiveSignature ?? intentType.rawValue
		return "\(workflowType.rawValue)|\(primitive)"
	}

	// MARK: - Self-test

	static func runSelfTest() -> Bool {
		let tracker = ProposalNoveltyTracker()
		let sig = "browsing|organizeInformation"
		let now = Date()

		// Never seen → fully novel.
		guard tracker.noveltyScore(for: sig, referenceTime: now) == 1.0 else { return false }

		// Seen once → singleShownNovelty.
		tracker.record(signature: sig, at: now)
		guard tracker.noveltyScore(for: sig, referenceTime: now) == tracker.singleShownNovelty else { return false }

		// Seen twice → doubleShownNovelty.
		tracker.record(signature: sig, at: now)
		guard tracker.noveltyScore(for: sig, referenceTime: now) == tracker.doubleShownNovelty else { return false }

		// Seen 3 times → suppressionResidual (soft floor, not hard zero — T18.6A).
		tracker.record(signature: sig, at: now)
		guard tracker.noveltyScore(for: sig, referenceTime: now) == tracker.suppressionResidual else { return false }

		// Outside suppression window → partial novelty.
		let oldTime = now.addingTimeInterval(-(tracker.suppressionWindow + 10))
		tracker.entries["old_sig"] = ProposalNoveltyTracker.Entry(
			shownCount: 2, firstShownAt: oldTime, lastShownAt: oldTime
		)
		let oldNovelty = tracker.noveltyScore(for: "old_sig", referenceTime: now)
		guard oldNovelty > 0.6 && oldNovelty <= 1.0 else { return false }

		return true
	}
}
