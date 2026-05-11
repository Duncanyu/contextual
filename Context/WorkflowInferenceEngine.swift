import Foundation

/// Bounded, weighted workflow inference from canonical fused context + coarse interaction metadata.
/// Context-layer only: no persistence, no proposals, no actions, no raw text logging.
final class WorkflowInferenceEngine {
	static let shared = WorkflowInferenceEngine()

	private let lock = NSLock()
	private var bundleRing: [(bundle: String, at: Date)] = []
	private var latest: WorkflowInferenceResult?
	private var lastLogSignature: String?
	private var lastLogAt: Date?

	private init() {}

	/// Clears continuity memory and last inference (e.g. DEBUG self-test or session reset).
	func reset() {
		lock.lock()
		bundleRing.removeAll()
		latest = nil
		lastLogSignature = nil
		lastLogAt = nil
		lock.unlock()
	}

	func latestResult() -> WorkflowInferenceResult? {
		lock.lock()
		let v = latest
		lock.unlock()
		return v
	}

	/// Records active app bundle id for continuity heuristics (bundle id only).
	func recordAppBundle(_ bundleIdentifier: String?, at time: Date = Date()) {
		guard let b = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return }
		lock.lock()
		defer { lock.unlock() }
		if bundleRing.last?.bundle == b { return }
		bundleRing.append((b, time))
		if bundleRing.count > 8 {
			bundleRing.removeFirst(bundleRing.count - 8)
		}
	}

	/// Runs inference from `CanonicalContextState` and stores/logs a metadata-only result.
	func evaluate(referenceTime: Date = Date()) {
		let fused = CanonicalContextState.shared.current()
		let ring = copyRingLocked()
		let result = Self.compute(fused: fused, bundleRing: ring, referenceTime: referenceTime)
		lock.lock()
		latest = result
		lock.unlock()
		logIfNeeded(result)
	}

	private func copyRingLocked() -> [(bundle: String, at: Date)] {
		lock.lock()
		let r = bundleRing
		lock.unlock()
		return r
	}

	private func logIfNeeded(_ result: WorkflowInferenceResult) {
		let sig = "\(result.workflow.rawValue)|\(String(format: "%.2f", result.confidence))|\(result.contributingSignals.joined(separator: ";"))"
		let now = Date()
		lock.lock()
		let shouldSkip: Bool
		if lastLogSignature == sig, let t = lastLogAt, now.timeIntervalSince(t) < 2.4 {
			shouldSkip = true
		} else {
			shouldSkip = false
			lastLogSignature = sig
			lastLogAt = now
		}
		lock.unlock()
		if shouldSkip { return }

		let signals = result.contributingSignals.joined(separator: ",")
		print("[WorkflowInference] inferred workflow=\(result.workflow.rawValue) confidence=\(String(format: "%.2f", result.confidence)) signals=\(signals)")
	}

	// MARK: - Core heuristics

	private static func compute(
		fused: FusedContextPacket?,
		bundleRing: [(bundle: String, at: Date)],
		referenceTime: Date
	) -> WorkflowInferenceResult {
		guard let fused else {
			return WorkflowInferenceResult(
				workflow: .unknown,
				confidence: 0.62,
				contributingSignals: ["no_fused_packet"],
				inferredAt: referenceTime,
				isStale: true,
				summaryHint: "no_context",
				sourceFusedId: nil
			)
		}

		if fused.isStale || fused.freshnessScore < 0.22 {
			return WorkflowInferenceResult(
				workflow: .unknown,
				confidence: 0.68,
				contributingSignals: ["stale_fused", "freshness_low"],
				inferredAt: referenceTime,
				isStale: true,
				summaryHint: "stale_context",
				sourceFusedId: fused.id
			)
		}

		let kinds = Set(fused.visualKinds)
		let hints = Set(fused.uiStructureHints)
		let typing = fused.typingState
		let pointer = fused.pointerState

		let conflict = wfClamp01(fused.conflictScore)
		let confidence = wfClamp01(fused.confidence)
		let freshness = wfClamp01(fused.freshnessScore)

		var scores: [InferredWorkflow: Double] = [:]
		var signals: [String] = []

		let conflictingEvidence = conflict > 0.58 && confidence < 0.55
		let weakFusion = confidence < 0.38 && freshness < 0.42

		// Continuity: multiple app hops recently + editor/terminal co-signal → debugging-ish tooling use.
		let recentDistinctBundles = distinctBundles(in: bundleRing, withinSeconds: 110, referenceTime: referenceTime)
		let multiAppContinuity = recentDistinctBundles >= 2

		// --- Weighted contributions (bounded) ---
		if kinds.contains(.browser) {
			let idleLike = isIdleTyping(typing) && isIdlePointer(pointer)
			if idleLike, conflict < 0.48 {
				scores[.browsing, default: 0] += 0.34 + freshness * 0.08
				signals.append("visual_browser_idle")
			}
		}

		if kinds.contains(.browser) || kinds.contains(.article) {
			if fused.textAvailability, fused.lineCount >= 8, isIdleTyping(typing), conflict < 0.52 {
				scores[.research, default: 0] += 0.36 + min(0.14, Double(fused.lineCount) / 220.0)
				signals.append("long_text_reading_shape")
			}
		}

		if let typing, typing == .active || typing == .started, kinds.contains(.article) || kinds.contains(.form) || kinds.contains(.dialog) {
			scores[.writing, default: 0] += 0.28 + (typing == .active ? 0.06 : 0.0)
			signals.append("steady_typing_docs")
		}

		if kinds.contains(.editor) || hints.contains("ax_editor_like") || hints.contains("visual_monospace_region") {
			if typing == .burst || typing == .active {
				scores[.editing, default: 0] += 0.30
				signals.append("editor_typing")
			} else if isIdlePointer(pointer), isIdleTyping(typing), fused.hasWindowSnapshot {
				scores[.reviewing, default: 0] += 0.24 + min(0.08, Double(fused.lineCount) / 260.0)
				signals.append("editor_idle_review_shape")
			} else {
				scores[.editing, default: 0] += 0.18
				signals.append("editor_context")
			}
		}

		if kinds.contains(.terminal) {
			if typing == .burst || conflict > 0.42 {
				scores[.debugging, default: 0] += 0.28
				signals.append("terminal_burst_or_conflict")
			} else {
				scores[.debugging, default: 0] += 0.16
				signals.append("terminal_present")
			}
		}

		if kinds.contains(.editor), kinds.contains(.terminal), multiAppContinuity {
			scores[.debugging, default: 0] += 0.14
			signals.append("continuity_multi_app_editor_terminal")
		}

		// --- Arbitration ---
		if conflictingEvidence || weakFusion {
			scores[.unknown, default: 0] += 0.55
			signals.append("conflicting_or_weak_evidence")
		}

		// Visual kind disagreement dampening (browser + terminal + editor without strong confidence).
		let noisyVisualSet = kinds.intersection([.browser, .terminal, .editor])
		if noisyVisualSet.count >= 2, confidence < 0.62 {
			scores[.unknown, default: 0] += 0.22
			signals.append("visual_set_conflict_dampen")
		}

		// Pick dominant
		let best = scores.max(by: { $0.value < $1.value })
		guard let top = best, top.value >= 0.24 else {
			return WorkflowInferenceResult(
				workflow: .unknown,
				confidence: 0.55,
				contributingSignals: uniqueSignals(signals + ["no_clear_winner"]),
				inferredAt: referenceTime,
				isStale: false,
				summaryHint: "ambiguous",
				sourceFusedId: fused.id
			)
		}

		let sum = scores.values.reduce(0, +)
		let rawConfidence = wfClamp01(top.value / max(0.35, sum))
		let penalty = 0.55 * conflict + (conflictingEvidence ? 0.12 : 0.0)
		let finalConfidence = max(0.08, wfClamp01(rawConfidence * (0.55 + 0.45 * confidence) - penalty))

		let summaryHint = "\(top.key.rawValue)_like"

		return WorkflowInferenceResult(
			workflow: top.key,
			confidence: finalConfidence,
			contributingSignals: uniqueSignals(signals),
			inferredAt: referenceTime,
			isStale: false,
			summaryHint: summaryHint,
			sourceFusedId: fused.id
		)
	}

	private static func distinctBundles(in ring: [(bundle: String, at: Date)], withinSeconds: TimeInterval, referenceTime: Date) -> Int {
		let cutoff = referenceTime.addingTimeInterval(-withinSeconds)
		let recent = ring.filter { $0.at >= cutoff }
		return Set(recent.map(\.bundle)).count
	}

	private static func isIdleTyping(_ typing: TypingState?) -> Bool {
		guard let typing else { return true }
		return typing == .idle || typing == .stopped
	}

	private static func isIdlePointer(_ pointer: PointerState?) -> Bool {
		guard let pointer else { return true }
		return pointer == .idle || pointer == .stopped
	}

	private static func wfClamp01(_ x: Double) -> Double {
		min(1.0, max(0.0, x))
	}

	private static func uniqueSignals(_ signals: [String]) -> [String] {
		var seen = Set<String>()
		var out: [String] = []
		for s in signals where seen.insert(s).inserted {
			out.append(s)
		}
		return out
	}

	// MARK: - DEBUG self-test

	static func runSelfTest() -> Bool {
		print("[WorkflowInference] selftest starting")
		let engine = WorkflowInferenceEngine.shared
		engine.reset()
		CanonicalContextState.shared.clear()

		let now = Date()
		var failures: [String] = []

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func basePacket(
			visualKinds: [VisualUIKind],
			hints: [String] = [],
			typing: TypingState?,
			pointer: PointerState?,
			confidence: Double,
			freshness: Double,
			conflict: Double,
			isStale: Bool,
			textAvailability: Bool,
			lineCount: Int,
			hasWindowSnapshot: Bool
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: now,
				primarySource: .selectedText,
				availableSources: [.activeApp, .visualDescriptor],
				staleSources: [],
				appName: "TestApp",
				bundleIdentifier: "test.bundle",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: textAvailability,
				textLength: textAvailability ? max(40, lineCount * 22) : 0,
				lineCount: lineCount,
				hasSelectedText: textAvailability,
				hasClipboardText: false,
				hasOCRText: false,
				hasAXText: false,
				hasWindowSnapshot: hasWindowSnapshot,
				hasVisualDescriptor: !visualKinds.isEmpty,
				hasTypingActivity: typing != nil,
				hasPointerActivity: pointer != nil,
				visualKinds: visualKinds,
				uiStructureHints: hints,
				typingState: typing,
				pointerState: pointer,
				confidence: wfClamp01(confidence),
				freshnessScore: wfClamp01(freshness),
				conflictScore: wfClamp01(conflict),
				isStale: isStale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["workflow_selftest"],
				debugSummaryMetadata: ["workflowSelfTest": "1"]
			)
		}

		// browsing
		let browse = basePacket(
			visualKinds: [.browser],
			typing: .idle,
			pointer: .idle,
			confidence: 0.72,
			freshness: 0.78,
			conflict: 0.18,
			isStale: false,
			textAvailability: false,
			lineCount: 0,
			hasWindowSnapshot: false
		)
		CanonicalContextState.shared.update(browse)
		engine.recordAppBundle("com.example.browser", at: now)
		engine.evaluate(referenceTime: now)
		let rBrowse = engine.latestResult()
		assertCase("browsing", rBrowse?.workflow == .browsing)

		// research
		engine.reset()
		CanonicalContextState.shared.clear()
		let research = basePacket(
			visualKinds: [.browser, .article],
			typing: .idle,
			pointer: .idle,
			confidence: 0.70,
			freshness: 0.80,
			conflict: 0.22,
			isStale: false,
			textAvailability: true,
			lineCount: 14,
			hasWindowSnapshot: false
		)
		CanonicalContextState.shared.update(research)
		engine.evaluate(referenceTime: now)
		assertCase("research", engine.latestResult()?.workflow == .research)

		// editing
		engine.reset()
		CanonicalContextState.shared.clear()
		let editingPkt = basePacket(
			visualKinds: [.editor],
			hints: ["ax_editor_like"],
			typing: .burst,
			pointer: .idle,
			confidence: 0.70,
			freshness: 0.78,
			conflict: 0.26,
			isStale: false,
			textAvailability: true,
			lineCount: 8,
			hasWindowSnapshot: false
		)
		CanonicalContextState.shared.update(editingPkt)
		engine.evaluate(referenceTime: now)
		assertCase("editing", engine.latestResult()?.workflow == .editing)

		// reviewing
		engine.reset()
		CanonicalContextState.shared.clear()
		let reviewPkt = basePacket(
			visualKinds: [.editor],
			hints: [],
			typing: .idle,
			pointer: .idle,
			confidence: 0.72,
			freshness: 0.80,
			conflict: 0.20,
			isStale: false,
			textAvailability: true,
			lineCount: 12,
			hasWindowSnapshot: true
		)
		CanonicalContextState.shared.update(reviewPkt)
		engine.evaluate(referenceTime: now)
		assertCase("reviewing", engine.latestResult()?.workflow == .reviewing)

		// writing
		engine.reset()
		CanonicalContextState.shared.clear()
		let writing = basePacket(
			visualKinds: [.article],
			typing: .active,
			pointer: .idle,
			confidence: 0.68,
			freshness: 0.76,
			conflict: 0.20,
			isStale: false,
			textAvailability: true,
			lineCount: 6,
			hasWindowSnapshot: false
		)
		CanonicalContextState.shared.update(writing)
		engine.evaluate(referenceTime: now)
		assertCase("writing", engine.latestResult()?.workflow == .writing)

		// debugging (terminal + burst + multi-app continuity)
		engine.reset()
		CanonicalContextState.shared.clear()
		let debug = basePacket(
			visualKinds: [.terminal, .editor],
			hints: [],
			typing: .burst,
			pointer: .interacting,
			confidence: 0.66,
			freshness: 0.74,
			conflict: 0.48,
			isStale: false,
			textAvailability: true,
			lineCount: 10,
			hasWindowSnapshot: true
		)
		CanonicalContextState.shared.update(debug)
		engine.recordAppBundle("com.example.ide", at: now.addingTimeInterval(-40))
		engine.recordAppBundle("com.example.term", at: now.addingTimeInterval(-20))
		engine.recordAppBundle("com.example.ide", at: now.addingTimeInterval(-5))
		engine.evaluate(referenceTime: now)
		assertCase("debugging", engine.latestResult()?.workflow == .debugging)

		// conflicting weak evidence → unknown
		engine.reset()
		CanonicalContextState.shared.clear()
		let conflict = basePacket(
			visualKinds: [.browser, .editor, .terminal],
			typing: .idle,
			pointer: .idle,
			confidence: 0.35,
			freshness: 0.40,
			conflict: 0.86,
			isStale: false,
			textAvailability: true,
			lineCount: 4,
			hasWindowSnapshot: false
		)
		CanonicalContextState.shared.update(conflict)
		engine.evaluate(referenceTime: now)
		assertCase("conflicting_unknown", engine.latestResult()?.workflow == .unknown)

		// stale fused packet path
		engine.reset()
		CanonicalContextState.shared.clear()
		let stale = basePacket(
			visualKinds: [.browser],
			typing: .idle,
			pointer: .idle,
			confidence: 0.80,
			freshness: 0.10,
			conflict: 0.10,
			isStale: true,
			textAvailability: false,
			lineCount: 0,
			hasWindowSnapshot: false
		)
		CanonicalContextState.shared.update(stale)
		engine.evaluate(referenceTime: now)
		assertCase("stale_unknown", engine.latestResult()?.workflow == .unknown && engine.latestResult()?.isStale == true)

		let ok = failures.isEmpty
		print("[WorkflowInference] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")

		engine.reset()
		CanonicalContextState.shared.clear()
		return ok
	}
}
