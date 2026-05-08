import Foundation

/// In-memory, privacy-safe cache for local intelligence decisions (T12.5).
/// Stores responses keyed by fingerprints only (no raw text, no compressed text, no prompts).
@MainActor
final class IntelligenceDecisionCache {
	private struct Entry {
		let decision: IntelligenceDecisionResponse
		let storedAt: Date
		let fingerprint: String
	}

	private var entries: [String: Entry] = [:]
	private var order: [String] = []

	private let maxEntries: Int = 80
	private let expirySeconds: TimeInterval = 10 * 60

	private var lastLogSig: String?
	private var lastLogAt: Date?

	func lookup(
		fingerprint: String,
		request: IntelligenceDecisionRequest,
		now: Date = Date()
	) -> IntelligenceDecisionResponse? {
		prune(now: now)
		guard let e = entries[fingerprint] else {
			logIfNeeded("miss", fp: fingerprint, now: now)
			return nil
		}

		let age = now.timeIntervalSince(e.storedAt)
		if age >= expirySeconds {
			remove(fingerprint: fingerprint)
			logIfNeeded("expired", fp: fingerprint, now: now)
			return nil
		}

		// Must remain valid for this request.
		guard e.decision.isValid(for: request) else {
			remove(fingerprint: fingerprint)
			logIfNeeded("rejected_invalid", fp: fingerprint, now: now)
			return nil
		}

		if let id = e.decision.bestActionId, !request.availableActions.contains(id) {
			logIfNeeded("rejected_action_missing", fp: fingerprint, now: now)
			return nil
		}

		// Confidence decay: reduce slightly as the entry ages.
		// If confidence becomes too low, treat as miss.
		let decayed = decayedConfidence(original: e.decision.confidence, age: age)
		if decayed < 0.35 {
			logIfNeeded("rejected_decayed", fp: fingerprint, now: now)
			return nil
		}

		logIfNeeded("hit", fp: fingerprint, now: now)
		return IntelligenceDecisionResponse(
			shouldSuggest: e.decision.shouldSuggest,
			bestActionId: e.decision.bestActionId,
			confidence: min(1.0, max(0.0, decayed)),
			reason: e.decision.reason,
			suggestedTitle: e.decision.suggestedTitle
		)
	}

	func store(
		decision: IntelligenceDecisionResponse,
		fingerprint: String,
		request: IntelligenceDecisionRequest,
		now: Date = Date()
	) {
		prune(now: now)

		guard decision.isValid(for: request) else {
			logIfNeeded("store_rejected_invalid", fp: fingerprint, now: now)
			return
		}
		if decision.shouldSuggest, decision.bestActionId == nil {
			logIfNeeded("store_rejected_missing_action", fp: fingerprint, now: now)
			return
		}
		if let id = decision.bestActionId, !request.availableActions.contains(id) {
			logIfNeeded("store_rejected_bad_action", fp: fingerprint, now: now)
			return
		}

		let entry = Entry(decision: decision, storedAt: now, fingerprint: fingerprint)
		if entries[fingerprint] == nil {
			order.append(fingerprint)
		}
		entries[fingerprint] = entry
		enforceCap()
		logIfNeeded("store", fp: fingerprint, now: now)
	}

	func clear() {
		entries.removeAll()
		order.removeAll()
	}

	/// Metadata-only helper when the caller doesn't have a content fingerprint.
	static func deriveFingerprint(for request: IntelligenceDecisionRequest) -> String {
		let actions = request.availableActions.sorted().joined(separator: ",")
		let f = request.features
		let basis = [
			"type=\(request.contextType.rawValue)",
			"source=\(request.sourceType)",
			"lenBucket=\(request.textLength / 25)",
			"lineBucket=\(request.lineCount / 2)",
			"actions=\(actions)",
			"q=\(f.hasQuestion)",
			"code=\(f.isLikelyCode)",
			"log=\(f.isLikelyLog)"
		].joined(separator: "|")
		return String(fnv1a64(basis), radix: 16)
	}

	// MARK: - Internals

	private func decayedConfidence(original: Double, age: TimeInterval) -> Double {
		// Linear decay down to 70% at expiry.
		let t = min(1.0, max(0.0, age / expirySeconds))
		let factor = 1.0 - 0.30 * t
		return original * factor
	}

	private func prune(now: Date) {
		for fp in order {
			if let e = entries[fp], now.timeIntervalSince(e.storedAt) >= expirySeconds {
				entries.removeValue(forKey: fp)
			}
		}
		order.removeAll { entries[$0] == nil }
	}

	private func enforceCap() {
		if order.count <= maxEntries { return }
		let drop = order.count - maxEntries
		for _ in 0..<drop {
			let fp = order.removeFirst()
			entries.removeValue(forKey: fp)
		}
	}

	private func remove(fingerprint: String) {
		entries.removeValue(forKey: fingerprint)
		order.removeAll { $0 == fingerprint }
	}

	private func logIfNeeded(_ event: String, fp: String, now: Date) {
		let sig = "\(event)|\(fp)"
		if let p = lastLogSig, p == sig, let t = lastLogAt, now.timeIntervalSince(t) < 2.0 { return }
		lastLogSig = sig
		lastLogAt = now
		print("[IntelligenceDecisionCache] \(event) fp=\(fp)")

		let (debugEvent, reason): (String, String?)
		switch event {
		case "miss":
			debugEvent = "miss"
			reason = "cache_miss"
		case "hit":
			debugEvent = "hit"
			reason = "cache_hit"
		case "expired":
			debugEvent = "expired"
			reason = nil
		case "rejected_invalid":
			debugEvent = "rejected"
			reason = "invalid_output"
		case "rejected_action_missing", "store_rejected_bad_action":
			debugEvent = "rejected"
			reason = "invalid_action"
		case "rejected_decayed":
			debugEvent = "rejected"
			reason = "low_conf"
		case "store":
			debugEvent = "store"
			reason = nil
		case "store_rejected_invalid":
			debugEvent = "rejected"
			reason = "invalid_output"
		case "store_rejected_missing_action":
			debugEvent = "rejected"
			reason = "invalid_action"
		default:
			debugEvent = event
			reason = nil
		}
		IntelligenceDebugLogger.log(
			stage: .cache,
			event: debugEvent,
			meta: IntelligenceDebugMeta(reason: reason, fp: fp),
			throttleKey: sig
		)
	}

	private static func fnv1a64(_ text: String) -> UInt64 {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for b in text.utf8 {
			hash ^= UInt64(b)
			hash &*= 1_099_511_628_211
		}
		return hash
	}

	#if DEBUG
	/// Debug-only verification helper (not called from runtime).
	static func _selfTest() -> Bool {
		let cache = IntelligenceDecisionCache()
		let f = ContextFeatures(
			textLength: 150,
			wordCount: 25,
			sentenceCount: 3,
			punctuationDensity: 0.03,
			hasQuestion: false,
			isLikelyCode: false,
			isLikelyLog: true,
			lineCount: 5,
			averageLineLength: 30,
			repetitionScore: 0.0
		)
		let req = IntelligenceDecisionRequest(
			contextType: .errorLog,
			features: f,
			availableActions: ["explain_text", "summarize_text"],
			sourceType: "clipboard",
			appName: "X",
			windowTitle: "Y",
			textLength: 150,
			lineCount: 5,
			compressedText: ""
		)
		let fp = deriveFingerprint(for: req)

		guard cache.lookup(fingerprint: fp, request: req) == nil else { return false }

		let ok = IntelligenceDecisionResponse(shouldSuggest: true, bestActionId: "explain_text", confidence: 0.9, reason: "ok", suggestedTitle: "Want me to explain this?")
		cache.store(decision: ok, fingerprint: fp, request: req, now: Date())
		guard cache.lookup(fingerprint: fp, request: req, now: Date()) != nil else { return false }

		let badAction = IntelligenceDecisionResponse(shouldSuggest: true, bestActionId: "nope", confidence: 0.9, reason: "bad", suggestedTitle: nil)
		cache.store(decision: badAction, fingerprint: fp + "x", request: req, now: Date())
		guard cache.lookup(fingerprint: fp + "x", request: req, now: Date()) == nil else { return false }

		let old = Date().addingTimeInterval(-(11 * 60))
		cache.store(decision: ok, fingerprint: fp + "old", request: req, now: old)
		guard cache.lookup(fingerprint: fp + "old", request: req, now: Date()) == nil else { return false }

		cache.clear()
		guard cache.lookup(fingerprint: fp, request: req, now: Date()) == nil else { return false }
		return true
	}
	#endif
}

