import Foundation

struct IntelligenceBudgetDecision: Sendable, Equatable {
	let allowed: Bool
	let reason: String
	let score: Double
}

/// Session-only budget gate for whether local intelligence may run (T12.4). No AI calls.
@MainActor
final class IntelligenceBudgetManager {
	private struct Recent {
		let fingerprint: String
		let at: Date
	}

	private var recentAttempts: [Recent] = []
	private let maxRecent: Int = 80
	private let pruneAfterSeconds: TimeInterval = 10 * 60
	private let similarDenyWindowSeconds: TimeInterval = 25

	private var lastLogSig: String?
	private var lastLogAt: Date?

	func evaluate(
		request: IntelligenceDecisionRequest,
		suggestionStrength: SuggestionStrength?,
		isActionExecuting: Bool,
		isModelAvailable: Bool,
		contextFingerprint: String?
	) -> IntelligenceBudgetDecision {
		let now = Date()
		prune(now: now)

		if isActionExecuting {
			return deny("executing_action", score: 0, now: now)
		}
		if !isModelAvailable {
			return deny("model_unavailable", score: 0, now: now)
		}

		let ct = request.compressedText.trimmingCharacters(in: .whitespacesAndNewlines)
		if ct.isEmpty {
			return deny("empty_compressed_text", score: 0, now: now)
		}
		if request.availableActions.isEmpty {
			return deny("no_actions", score: 0, now: now)
		}
		if request.textLength < 30 {
			return deny("too_short", score: 0, now: now)
		}
		let st = request.sourceType.trimmingCharacters(in: .whitespacesAndNewlines)
		if st.isEmpty || st == "unknown" {
			return deny("sourceType", score: 0, now: now)
		}
		if let strength = suggestionStrength, strength != .medium && strength != .strong {
			return deny("strength_not_allowed", score: 0, now: now)
		}
		if request.contextType == .random {
			return deny("random", score: 0.05, now: now)
		}

		let fp = (contextFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
			?? fallbackFingerprint(for: request)

		if isSimilarRecentlyEvaluated(fingerprint: fp, now: now) {
			return deny("similar_recent", score: 0.10, now: now)
		}

		// Score: “worth spending budget on?” (not a strict cooldown).
		var score = baseScore(request: request, strength: suggestionStrength)
		score = min(1.0, max(0.0, score))

		// Allow only when score clears a modest threshold.
		let allowed = score >= 0.55
		if allowed {
			recordAttempt(fingerprint: fp, at: now)
			return allow("ok", score: score, now: now)
		}
		return deny("low_score", score: score, now: now)
	}

	// MARK: - Internals

	private func baseScore(request: IntelligenceDecisionRequest, strength: SuggestionStrength?) -> Double {
		var score: Double = 0.25

		switch strength {
		case .strong:
			score += 0.45
		case .medium:
			score += 0.25
		case .weak:
			score += 0.0
		case nil:
			score += 0.10
		}

		let f = request.features
		if f.isLikelyLog || f.isLikelyCode || f.hasQuestion {
			score += 0.15
		}
		if f.textLength >= 200 { score += 0.10 }
		if f.lineCount >= 4 { score += 0.05 }
		if request.availableActions.count >= 3 { score += 0.05 }

		return score
	}

	private func isSimilarRecentlyEvaluated(fingerprint: String, now: Date) -> Bool {
		for r in recentAttempts.reversed() {
			if r.fingerprint == fingerprint, now.timeIntervalSince(r.at) < similarDenyWindowSeconds {
				return true
			}
		}
		return false
	}

	private func recordAttempt(fingerprint: String, at: Date) {
		recentAttempts.append(Recent(fingerprint: fingerprint, at: at))
		if recentAttempts.count > maxRecent {
			recentAttempts.removeFirst(recentAttempts.count - maxRecent)
		}
	}

	private func prune(now: Date) {
		recentAttempts = recentAttempts.filter { now.timeIntervalSince($0.at) < pruneAfterSeconds }
	}

	private func fallbackFingerprint(for request: IntelligenceDecisionRequest) -> String {
		// Metadata-only, deterministic (no raw text). Useful when the caller doesn’t provide a fingerprint.
		let actions = request.availableActions.sorted().joined(separator: ",")
		let basis = [
			request.contextType.rawValue,
			request.sourceType,
			"len=\(request.textLength / 25)",
			"lines=\(request.lineCount)",
			"actions=\(actions)"
		].joined(separator: "|")
		return String(fnv1a64(basis), radix: 16)
	}

	private func allow(_ reason: String, score: Double, now: Date) -> IntelligenceBudgetDecision {
		logIfNeeded(allowed: true, reason: reason, score: score, now: now)
		return IntelligenceBudgetDecision(allowed: true, reason: reason, score: score)
	}

	private func deny(_ reason: String, score: Double, now: Date) -> IntelligenceBudgetDecision {
		logIfNeeded(allowed: false, reason: reason, score: score, now: now)
		return IntelligenceBudgetDecision(allowed: false, reason: reason, score: score)
	}

	private func logIfNeeded(allowed: Bool, reason: String, score: Double, now: Date) {
		let s = String(format: "%.2f", score)
		let sig = "\(allowed)|\(reason)|\(s)"
		if let p = lastLogSig, p == sig, let t = lastLogAt, now.timeIntervalSince(t) < 2.0 { return }
		lastLogSig = sig
		lastLogAt = now
		print("[IntelligenceBudget] \(allowed ? "allowed" : "denied") reason=\(reason) score=\(s)")
		IntelligenceDebugLogger.log(
			stage: .budget,
			event: allowed ? "allowed" : "denied",
			meta: IntelligenceDebugMeta(reason: reason, score: s),
			throttleKey: sig
		)
	}

	private func fnv1a64(_ text: String) -> UInt64 {
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
		let mgr = IntelligenceBudgetManager()
		let f = ContextFeatures(
			textLength: 150,
			wordCount: 25,
			sentenceCount: 3,
			punctuationDensity: 0.03,
			hasQuestion: true,
			isLikelyCode: false,
			isLikelyLog: false,
			lineCount: 3,
			averageLineLength: 50,
			repetitionScore: 0.0
		)
		let req = IntelligenceDecisionRequest(
			contextType: .question,
			features: f,
			availableActions: ["explain_text", "summarize_text"],
			sourceType: "selected_text",
			appName: "X",
			windowTitle: "Y",
			textLength: 150,
			lineCount: 3,
			compressedText: "What is recursion?"
		)

		if mgr.evaluate(request: req, suggestionStrength: .medium, isActionExecuting: true, isModelAvailable: true, contextFingerprint: "a").allowed { return false }
		if mgr.evaluate(request: req, suggestionStrength: .medium, isActionExecuting: false, isModelAvailable: false, contextFingerprint: "a").allowed { return false }

		let emptyTextReq = IntelligenceDecisionRequest(
			contextType: .question,
			features: f,
			availableActions: ["explain_text"],
			sourceType: "selected_text",
			appName: nil,
			windowTitle: nil,
			textLength: 150,
			lineCount: 1,
			compressedText: ""
		)
		if mgr.evaluate(request: emptyTextReq, suggestionStrength: .medium, isActionExecuting: false, isModelAvailable: true, contextFingerprint: "b").allowed { return false }

		let noActionsReq = IntelligenceDecisionRequest(
			contextType: .question,
			features: f,
			availableActions: [],
			sourceType: "selected_text",
			appName: nil,
			windowTitle: nil,
			textLength: 150,
			lineCount: 1,
			compressedText: "hi"
		)
		if mgr.evaluate(request: noActionsReq, suggestionStrength: .medium, isActionExecuting: false, isModelAvailable: true, contextFingerprint: "c").allowed { return false }

		if mgr.evaluate(request: req, suggestionStrength: .weak, isActionExecuting: false, isModelAvailable: true, contextFingerprint: "d").allowed { return false }

		let first = mgr.evaluate(request: req, suggestionStrength: .strong, isActionExecuting: false, isModelAvailable: true, contextFingerprint: "same")
		if !first.allowed { return false }
		let second = mgr.evaluate(request: req, suggestionStrength: .strong, isActionExecuting: false, isModelAvailable: true, contextFingerprint: "same")
		if second.allowed { return false }

		return true
	}
	#endif
}

