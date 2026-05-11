import Foundation

/// Canonical in-memory state for the latest fused context packet.
/// Infrastructure-only: thread-safe, metadata-only logging, no persistence.
final class CanonicalContextState {
	static let shared = CanonicalContextState()

	private let lock = NSLock()
	private var packet: FusedContextPacket?

	private var updateCount: UInt64 = 0
	private var lastDecisionSignature: String?
	private var lastDecisionAt: Date?

	private init() {}

	func current() -> FusedContextPacket? {
		lock.lock()
		defer { lock.unlock() }
		return packet
	}

	func currentConfidence() -> Double {
		lock.lock()
		defer { lock.unlock() }
		return packet?.confidence ?? 0.0
	}

	func isCurrentContextFresh() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard let p = packet else { return false }
		return !p.isStale && p.freshnessScore >= 0.30
	}

	func clear() {
		lock.lock()
		packet = nil
		updateCount = 0
		lastDecisionSignature = nil
		lastDecisionAt = nil
		lock.unlock()
		print("[CanonicalContext] cleared")
		Self.notifyCanonicalContextUpdatedOnMain()
	}

	func update(_ newPacket: FusedContextPacket) {
		lock.lock()
		let decision = decideReplacementLocked(current: packet, candidate: newPacket)
		switch decision {
		case .accept(let reason):
			packet = newPacket
			updateCount &+= 1
			lock.unlock()
			logDecision(reason: reason, packet: newPacket)
			Self.notifyCanonicalContextUpdatedOnMain()
		case .reject(let reason):
			lock.unlock()
			logDecision(reason: reason, packet: newPacket)
		case .unchanged(let reason):
			lock.unlock()
			logDecision(reason: reason, packet: newPacket)
		}
	}

	// MARK: - Arbitration

	private enum ReplacementDecision {
		case accept(reason: String)
		case reject(reason: String)
		case unchanged(reason: String)
	}

	private func decideReplacementLocked(current: FusedContextPacket?, candidate: FusedContextPacket) -> ReplacementDecision {
		guard let cur = current else {
			return .accept(reason: "first_packet")
		}

		// Churn reduction: treat near-identical metadata packets as unchanged.
		if isEquivalent(cur, candidate) {
			return .unchanged(reason: "equivalent_context")
		}

		let curFresh = cur.freshnessScore
		let newFresh = candidate.freshnessScore
		let curConf = cur.confidence
		let newConf = candidate.confidence

		let curIsFresh = (!cur.isStale && curFresh >= 0.30)
		let newIsFresh = (!candidate.isStale && newFresh >= 0.30)

		// Never allow a stale packet to overwrite a fresh one.
		if curIsFresh && !newIsFresh {
			return .reject(reason: "stale_rejected")
		}

		// Prefer materially fresher packets.
		if (newFresh - curFresh) > 0.08 {
			return .accept(reason: "fresher_packet")
		}

		// Reject clearly older packets unless they are significantly better and not stale.
		if candidate.createdAt <= cur.createdAt, !newIsFresh {
			return .reject(reason: "older_packet")
		}

		let curScore = compositeScore(packet: cur)
		let newScore = compositeScore(packet: candidate)

		// Prefer higher-score packets when freshness is comparable.
		if (newScore - curScore) > 0.10, newFresh >= (curFresh - 0.05) {
			return .accept(reason: "higher_quality_packet")
		}

		// Allow a meaningful confidence upgrade even if slightly less fresh (both must be fresh).
		// This prevents the canonical state from getting stuck on "very fresh but mediocre" packets.
		if curIsFresh, newIsFresh, (newConf - curConf) > 0.10, newFresh >= (curFresh - 0.10) {
			return .accept(reason: "confidence_upgrade")
		}

		// Avoid overwriting a much stronger fresh packet with a slightly newer weak one.
		if curIsFresh, newIsFresh, (curScore - newScore) > 0.15, candidate.createdAt.timeIntervalSince(cur.createdAt) < 8.0 {
			return .reject(reason: "lower_confidence")
		}

		// If it's newer enough and not stale, allow refresh even if slightly weaker.
		if newIsFresh, candidate.createdAt.timeIntervalSince(cur.createdAt) >= 10.0 {
			return .accept(reason: "newer_refresh")
		}

		// Default: keep current.
		return .reject(reason: "not_better")
	}

	private func compositeScore(packet: FusedContextPacket) -> Double {
		// Deterministic, metadata-only: freshness dominates, then confidence, then conflict penalty.
		let freshness = clamp01(packet.freshnessScore)
		let confidence = clamp01(packet.confidence)
		let conflict = clamp01(packet.conflictScore)
		return clamp01((freshness * 0.62) + (confidence * 0.38) - (conflict * 0.20))
	}

	private func isEquivalent(_ a: FusedContextPacket, _ b: FusedContextPacket) -> Bool {
		if a.primarySource != b.primarySource { return false }
		if a.primaryTextSource != b.primaryTextSource { return false }
		if a.bundleIdentifier != b.bundleIdentifier { return false }
		if a.textLength != b.textLength { return false }
		if a.lineCount != b.lineCount { return false }
		if a.hasVisualDescriptor != b.hasVisualDescriptor { return false }
		if a.hasTypingActivity != b.hasTypingActivity { return false }
		if a.hasPointerActivity != b.hasPointerActivity { return false }
		if a.typingState != b.typingState { return false }
		if a.pointerState != b.pointerState { return false }

		let aAvail = a.availableSources.map(\.rawValue).sorted()
		let bAvail = b.availableSources.map(\.rawValue).sorted()
		if aAvail != bAvail { return false }

		let aStale = a.staleSources.map(\.rawValue).sorted()
		let bStale = b.staleSources.map(\.rawValue).sorted()
		if aStale != bStale { return false }

		let aKinds = a.visualKinds.map(\.rawValue).sorted()
		let bKinds = b.visualKinds.map(\.rawValue).sorted()
		if aKinds != bKinds { return false }

		// Treat small numeric deltas as equivalent to avoid churn.
		if abs(a.freshnessScore - b.freshnessScore) > 0.02 { return false }
		if abs(a.confidence - b.confidence) > 0.02 { return false }
		if abs(a.conflictScore - b.conflictScore) > 0.02 { return false }

		return true
	}

	// MARK: - Logging

	private static func notifyCanonicalContextUpdatedOnMain() {
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: .contextualCanonicalContextUpdated, object: nil)
		}
	}

	private func logDecision(reason: String, packet: FusedContextPacket) {
		// Throttle identical decisions to reduce log spam.
		let now = Date()
		let sig = decisionSignature(reason: reason, packet: packet)

		lock.lock()
		let shouldSuppress: Bool
		if sig == lastDecisionSignature, let lastDecisionAt, now.timeIntervalSince(lastDecisionAt) < 1.5 {
			shouldSuppress = true
		} else {
			shouldSuppress = false
			lastDecisionSignature = sig
			lastDecisionAt = now
		}
		lock.unlock()

		if shouldSuppress { return }

		let fresh = String(format: "%.2f", packet.freshnessScore)
		let conf = String(format: "%.2f", packet.confidence)
		let primary = packet.primarySource.rawValue

		switch reason {
		case "equivalent_context":
			print("[CanonicalContext] unchanged reason=equivalent_context freshness=\(fresh) confidence=\(conf) primary=\(primary)")
		case "first_packet", "fresher_packet", "higher_quality_packet", "confidence_upgrade", "newer_refresh":
			print("[CanonicalContext] updated freshness=\(fresh) confidence=\(conf) primary=\(primary) reason=\(reason)")
		default:
			print("[CanonicalContext] rejected reason=\(reason) freshness=\(fresh) confidence=\(conf) primary=\(primary)")
		}
	}

	private func decisionSignature(reason: String, packet: FusedContextPacket) -> String {
		[
			reason,
			packet.primarySource.rawValue,
			packet.primaryTextSource.rawValue,
			packet.bundleIdentifier ?? "nil",
			packet.availableSources.map(\.rawValue).sorted().joined(separator: ","),
			packet.staleSources.map(\.rawValue).sorted().joined(separator: ","),
			String(format: "%.2f", packet.freshnessScore),
			String(format: "%.2f", packet.confidence),
			String(format: "%.2f", packet.conflictScore)
		].joined(separator: "|")
	}

	// MARK: - DEBUG self-test

	func selfTest() -> Bool {
		print("[CanonicalContext] selftest starting")
		clear()

		let now = Date()

		func pkt(
			createdAt: Date,
			primary: FusedPrimarySource,
			freshness: Double,
			confidence: Double,
			conflict: Double = 0.0,
			isStale: Bool = false
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: createdAt,
				primarySource: primary,
				availableSources: [.activeApp],
				staleSources: isStale ? [.screenOCR] : [],
				appName: "TestApp",
				bundleIdentifier: "test.bundle",
				windowTitleAvailable: false,
				primaryTextSource: primary == .none ? .none : FusedTextSource(rawValue: primary.rawValue) ?? .none,
				textAvailability: primary != .none,
				textLength: primary == .none ? 0 : 120,
				lineCount: primary == .none ? 0 : 3,
				hasSelectedText: primary == .selectedText,
				hasClipboardText: primary == .clipboardText,
				hasOCRText: primary == .screenOCR,
				hasAXText: primary == .axText,
				hasWindowSnapshot: false,
				hasVisualDescriptor: false,
				hasTypingActivity: false,
				hasPointerActivity: false,
				visualKinds: [],
				uiStructureHints: [],
				typingState: nil,
				pointerState: nil,
				confidence: clamp01(confidence),
				freshnessScore: clamp01(freshness),
				conflictScore: clamp01(conflict),
				isStale: isStale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["selftest"],
				debugSummaryMetadata: ["selftest": "1"]
			)
		}

		let stale = pkt(createdAt: now.addingTimeInterval(-20), primary: .screenOCR, freshness: 0.10, confidence: 0.70, isStale: true)
		let fresh = pkt(createdAt: now, primary: .selectedText, freshness: 0.95, confidence: 0.80, isStale: false)
		let weakFresh = pkt(createdAt: now.addingTimeInterval(1), primary: .clipboardText, freshness: 0.90, confidence: 0.30, isStale: false)
		let strongFresh = pkt(createdAt: now.addingTimeInterval(2), primary: .axText, freshness: 0.90, confidence: 0.92, isStale: false)

		update(stale)
		if current()?.primarySource != .screenOCR {
			print("[CanonicalContext] selftest failed case=first_packet")
			return false
		}

		update(fresh)
		if current()?.primarySource != .selectedText {
			print("[CanonicalContext] selftest failed case=fresh_replaces_stale")
			return false
		}

		update(stale)
		if current()?.primarySource != .selectedText {
			print("[CanonicalContext] selftest failed case=stale_rejected")
			return false
		}

		update(weakFresh)
		if current()?.primarySource != .selectedText {
			print("[CanonicalContext] selftest failed case=weak_does_not_overwrite_strong")
			return false
		}

		update(strongFresh)
		if current()?.primarySource != .axText {
			print("[CanonicalContext] selftest failed case=high_confidence_wins")
			return false
		}

		// Equivalent packet ignored.
		let equiv = pkt(createdAt: now.addingTimeInterval(2.1), primary: .axText, freshness: 0.91, confidence: 0.91, isStale: false)
		update(equiv)
		if current()?.primarySource != .axText {
			print("[CanonicalContext] selftest failed case=equivalent_ignored")
			return false
		}

		clear()
		if current() != nil {
			print("[CanonicalContext] selftest failed case=clear")
			return false
		}

		print("[CanonicalContext] selftest finished ok=true")
		return true
	}
}

private func clamp01(_ x: Double) -> Double {
	min(1.0, max(0.0, x))
}

