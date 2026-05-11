import Foundation

/// Short-lived session continuity: decaying, bounded, metadata-only. No persistence.
final class ContextualSessionTracker {
	static let shared = ContextualSessionTracker()

	private let lock = NSLock()

	private struct Sample: Sendable {
		let workflow: InferredWorkflow
		let fusedId: UUID?
		let bundle: String?
		let freshness: Double
		let conflict: Double
		let primarySource: String
		let at: Date
	}

	private var samples: [Sample] = []
	private var smoothedContinuity: Double = 0.0
	private var lastDominant: InferredWorkflow = .unknown
	private var lastState: ContextualSessionState?
	private var lastLogSignature: String?
	private var lastLogAt: Date?

	private let maxSamples = 16
	private let sampleHorizonSeconds: TimeInterval = 140
	private let decayTauSeconds: TimeInterval = 44
	private let smoothingAlpha: Double = 0.38

	private init() {}

	func reset() {
		lock.lock()
		samples.removeAll()
		smoothedContinuity = 0
		lastDominant = .unknown
		lastState = nil
		lastLogSignature = nil
		lastLogAt = nil
		lock.unlock()
	}

	func currentState() -> ContextualSessionState? {
		lock.lock()
		let s = lastState
		lock.unlock()
		return s
	}

	func latestPatternSnapshot() -> SessionPatternSnapshot? {
		lock.lock()
		defer { lock.unlock() }
		guard let st = lastState else { return nil }
		return SessionPatternSnapshot(
			dominantWorkflow: st.dominantWorkflow,
			trajectoryCodes: st.activeTrajectorySummary,
			patternConfidence: st.patternConfidence,
			continuityScore: st.continuityScore,
			capturedAt: st.updatedAt
		)
	}

	/// Records one pipeline tick. Must be called after `WorkflowInferenceEngine.evaluate` for coherent reads.
	func recordSample(
		inference: WorkflowInferenceResult?,
		fused: FusedContextPacket?,
		activeBundle: String?,
		referenceTime: Date = Date()
	) {
		let wf = inference?.workflow ?? .unknown
		let fusedId = fused?.id ?? inference?.sourceFusedId
		let fresh = fused.map { stClamp01($0.freshnessScore) } ?? (inference?.isStale == true ? 0.12 : 0.35)
		let conflict = fused.map { stClamp01($0.conflictScore) } ?? 0.25
		let primary = fused?.primarySource.rawValue ?? "none"

		let sample = Sample(
			workflow: wf,
			fusedId: fusedId,
			bundle: trimmedBundle(activeBundle),
			freshness: fresh,
			conflict: conflict,
			primarySource: primary,
			at: referenceTime
		)

		lock.lock()
		pruneLocked(referenceTime: referenceTime)
		samples.append(sample)
		if samples.count > maxSamples {
			samples.removeFirst(samples.count - maxSamples)
		}

		let decayFactor = decayMultiplier(since: samples.first?.at ?? referenceTime, now: referenceTime)
		smoothedContinuity *= decayFactor

		let dominant = dominantWorkflowLocked(referenceTime: referenceTime)
		let streak = streakSupport(for: dominant, referenceTime: referenceTime)
		let bundleLoop = bundleLoopScore(referenceTime: referenceTime)
		let oscillation = oscillationDampening(referenceTime: referenceTime)

		var signals: [SessionContinuitySignal] = []
		if streak > 0.18 { signals.append(.workflowStreak) }
		if bundleLoop > 0.22 { signals.append(.bundleLoop) }
		if multimodalStableLocked() { signals.append(.multimodalStable) }
		if decayFactor < 0.98 { signals.append(.decayApplied) }
		if oscillation < 0.99 { signals.append(.oscillationDampen) }
		if (inference?.isStale == true) || fresh < 0.32 || conflict > 0.62 {
			signals.append(.weakEvidenceDampen)
		}
		if trajectoryEchoLocked(dominant: dominant) { signals.append(.trajectoryEcho) }

		let patternConf = patternConfidenceLocked(dominant: dominant, referenceTime: referenceTime)
		let target = continuityTarget(
			dominant: dominant,
			previous: lastDominant,
			streak: streak,
			bundleLoop: bundleLoop,
			freshness: fresh,
			conflict: conflict,
			oscillation: oscillation
		)
		smoothedContinuity = stClamp01(smoothingAlpha * target + (1.0 - smoothingAlpha) * smoothedContinuity)
		lastDominant = dominant

		let trajectory = trajectoryStringLocked(limit: 8)
		let continuityConf = stClamp01(0.55 * smoothedContinuity + 0.35 * patternConf + 0.10 * (1.0 - conflict))

		let staleSession = fresh < 0.22 && (inference?.isStale == true || samples.count < 2)
		let state = ContextualSessionState(
			continuityScore: smoothedContinuity,
			continuityConfidence: continuityConf,
			patternConfidence: patternConf,
			dominantWorkflow: dominant,
			activeTrajectorySummary: trajectory,
			contributingSignals: uniqueSignals(signals),
			updatedAt: referenceTime,
			isStale: staleSession
		)
		lastState = state
		lock.unlock()

		logIfNeeded(state)
	}

	// MARK: - Internals

	private func pruneLocked(referenceTime: Date) {
		let cutoff = referenceTime.addingTimeInterval(-sampleHorizonSeconds)
		samples.removeAll { $0.at < cutoff }
	}

	private func decayMultiplier(since firstAt: Date, now: Date) -> Double {
		let dt = max(0, now.timeIntervalSince(firstAt))
		return exp(-dt / decayTauSeconds)
	}

	private func dominantWorkflowLocked(referenceTime: Date) -> InferredWorkflow {
		guard !samples.isEmpty else { return .unknown }
		let cutoff = referenceTime.addingTimeInterval(-95)
		var weighted: [InferredWorkflow: Double] = [:]
		for s in samples where s.at >= cutoff {
			let age = referenceTime.timeIntervalSince(s.at)
			let w = exp(-age / 55.0) * (0.45 + 0.55 * s.freshness) * (1.0 - 0.35 * s.conflict)
			weighted[s.workflow, default: 0] += w
		}
		return weighted.max(by: { $0.value < $1.value })?.key ?? .unknown
	}

	private func streakSupport(for dominant: InferredWorkflow, referenceTime: Date) -> Double {
		guard dominant != .unknown else { return 0 }
		let cutoff = referenceTime.addingTimeInterval(-72)
		var c = 0
		for s in samples.reversed() where s.at >= cutoff {
			if compatible(s.workflow, dominant) { c += 1 } else { break }
		}
		return min(1.0, Double(c) / 6.0)
	}

	private func bundleLoopScore(referenceTime: Date) -> Double {
		let cutoff = referenceTime.addingTimeInterval(-120)
		let bundles = samples.filter { $0.at >= cutoff }.compactMap(\.bundle)
		guard bundles.count >= 4 else { return 0 }
		var transitions = 0
		var repeats = 0
		for i in 1..<bundles.count {
			if bundles[i] != bundles[i - 1] { transitions += 1 }
			if i >= 2, bundles[i] == bundles[i - 2] { repeats += 1 }
		}
		let score = min(1.0, 0.12 * Double(repeats) + 0.06 * Double(transitions))
		return score
	}

	private func oscillationDampening(referenceTime: Date) -> Double {
		let cutoff = referenceTime.addingTimeInterval(-28)
		let recent = samples.filter { $0.at >= cutoff }.map(\.workflow)
		guard recent.count >= 4 else { return 1.0 }
		let tail = Array(recent.suffix(4))
		let a = tail[0], b = tail[1], c = tail[2], d = tail[3]
		if a != b, a == c, b == d { return 0.72 }
		return 1.0
	}

	private func multimodalStableLocked() -> Bool {
		let primaries = Set(samples.suffix(6).map(\.primarySource))
		return primaries.count >= 2 && primaries.count <= 4
	}

	private func trajectoryEchoLocked(dominant: InferredWorkflow) -> Bool {
		guard dominant != .unknown else { return false }
		let tail = samples.suffix(5).map(\.workflow)
		let hits = tail.filter { compatible($0, dominant) }.count
		return hits >= 4
	}

	private func patternConfidenceLocked(dominant: InferredWorkflow, referenceTime: Date) -> Double {
		guard dominant != .unknown else { return 0.2 }
		let cutoff = referenceTime.addingTimeInterval(-90)
		var num = 0.0
		var den = 0.0
		for s in samples where s.at >= cutoff {
			let w = 0.35 + 0.65 * s.freshness
			den += w
			if compatible(s.workflow, dominant) { num += w }
		}
		guard den > 0 else { return 0.2 }
		return stClamp01(num / den)
	}

	private func continuityTarget(
		dominant: InferredWorkflow,
		previous: InferredWorkflow,
		streak: Double,
		bundleLoop: Double,
		freshness: Double,
		conflict: Double,
		oscillation: Double
	) -> Double {
		var t = 0.35
		t += 0.40 * streak
		t += 0.12 * bundleLoop
		if compatible(dominant, previous) { t += 0.10 }
		t *= (0.55 + 0.45 * freshness)
		t *= (1.0 - 0.35 * conflict)
		t *= oscillation
		return stClamp01(t)
	}

	private func trajectoryStringLocked(limit: Int) -> String {
		let codes = samples.suffix(limit).map(\.workflow.rawValue)
		return codes.joined(separator: ">")
	}

	private func logIfNeeded(_ state: ContextualSessionState) {
		let sig = "\(state.dominantWorkflow.rawValue)|\(String(format: "%.2f", state.continuityScore))|\(state.contributingSignals.map(\.rawValue).sorted().joined(separator: ";"))"
		let now = state.updatedAt
		lock.lock()
		let shouldSkip: Bool
		if lastLogSignature == sig, let t = lastLogAt, now.timeIntervalSince(t) < 2.2 {
			shouldSkip = true
		} else {
			shouldSkip = false
			lastLogSignature = sig
			lastLogAt = now
		}
		lock.unlock()
		if shouldSkip { return }

		let patterns = state.contributingSignals.map(\.rawValue).sorted().joined(separator: ",")
		print(
			"[SessionTracking] continuity=\(String(format: "%.2f", state.continuityScore)) confidence=\(String(format: "%.2f", state.continuityConfidence)) workflow=\(state.dominantWorkflow.rawValue) patterns=\(patterns)"
		)
	}

	private func trimmedBundle(_ s: String?) -> String? {
		guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
		return t
	}

	private func uniqueSignals(_ s: [SessionContinuitySignal]) -> [SessionContinuitySignal] {
		var seen = Set<SessionContinuitySignal>()
		var out: [SessionContinuitySignal] = []
		for x in s where seen.insert(x).inserted {
			out.append(x)
		}
		return out
	}

	private func compatible(_ a: InferredWorkflow, _ b: InferredWorkflow) -> Bool {
		if a == b { return true }
		let pair = Set([a, b])
		if pair == Set([.editing, .reviewing]) { return true }
		if pair == Set([.research, .browsing]) { return true }
		if pair == Set([.debugging, .editing]) { return true }
		if pair == Set([.writing, .research]) { return true }
		return false
	}

	// MARK: - DEBUG self-test

	static func runSelfTest() -> Bool {
		print("[SessionTracking] selftest starting")
		let tracker = ContextualSessionTracker.shared
		let engine = WorkflowInferenceEngine.shared
		tracker.reset()
		engine.reset()
		CanonicalContextState.shared.clear()

		let t0 = Date(timeIntervalSince1970: 2_010_000_000)
		var failures: [String] = []

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func fusedPacket(
			at: Date,
			visualKinds: [VisualUIKind],
			typing: TypingState?,
			pointer: PointerState?,
			confidence: Double,
			freshness: Double,
			conflict: Double,
			isStale: Bool,
			textAvailability: Bool,
			lineCount: Int
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: at,
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
				hasWindowSnapshot: true,
				hasVisualDescriptor: !visualKinds.isEmpty,
				hasTypingActivity: typing != nil,
				hasPointerActivity: pointer != nil,
				visualKinds: visualKinds,
				uiStructureHints: [],
				typingState: typing,
				pointerState: pointer,
				confidence: stClamp01(confidence),
				freshnessScore: stClamp01(freshness),
				conflictScore: stClamp01(conflict),
				isStale: isStale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["session_selftest"],
				debugSummaryMetadata: ["sessionSelfTest": "1"]
			)
		}

		// Sustained debugging continuity
		for i in 0..<5 {
			let tick = t0.addingTimeInterval(Double(i) * 3)
			let p = fusedPacket(
				at: tick,
				visualKinds: [.terminal, .editor],
				typing: .burst,
				pointer: .idle,
				confidence: 0.70,
				freshness: 0.78,
				conflict: 0.35,
				isStale: false,
				textAvailability: true,
				lineCount: 10
			)
			CanonicalContextState.shared.update(p)
			engine.recordAppBundle("com.selftest.ide", at: tick)
			engine.recordAppBundle("com.selftest.term", at: tick.addingTimeInterval(1))
			engine.evaluate(referenceTime: tick)
			tracker.recordSample(
				inference: engine.latestResult(),
				fused: CanonicalContextState.shared.current(),
				activeBundle: "com.selftest.ide",
				referenceTime: tick
			)
		}
		let dbgState = tracker.currentState()
		assertCase("sustained_debugging", dbgState?.dominantWorkflow == .debugging && (dbgState?.continuityScore ?? 0) > 0.35)

		// Writing with idle gaps (still compatible streak)
		tracker.reset()
		engine.reset()
		CanonicalContextState.shared.clear()
		var tickW = t0.addingTimeInterval(200)
		for i in 0..<4 {
			let p = fusedPacket(
				at: tickW,
				visualKinds: [.article],
				typing: i % 2 == 0 ? .active : .idle,
				pointer: .idle,
				confidence: 0.68,
				freshness: 0.74,
				conflict: 0.22,
				isStale: false,
				textAvailability: true,
				lineCount: 8
			)
			CanonicalContextState.shared.update(p)
			engine.evaluate(referenceTime: tickW)
			tracker.recordSample(inference: engine.latestResult(), fused: CanonicalContextState.shared.current(), activeBundle: "com.selftest.notes", referenceTime: tickW)
			tickW = tickW.addingTimeInterval(22)
		}
		let writeState = tracker.currentState()
		assertCase("writing_idle_gaps", writeState?.dominantWorkflow == .writing || writeState?.dominantWorkflow == .research)

		// Repeated research trajectory
		tracker.reset()
		engine.reset()
		CanonicalContextState.shared.clear()
		for i in 0..<5 {
			let tick = t0.addingTimeInterval(400 + Double(i) * 4)
			let p = fusedPacket(
				at: tick,
				visualKinds: [.browser, .article],
				typing: .idle,
				pointer: .idle,
				confidence: 0.72,
				freshness: 0.80,
				conflict: 0.20,
				isStale: false,
				textAvailability: true,
				lineCount: 14
			)
			CanonicalContextState.shared.update(p)
			engine.evaluate(referenceTime: tick)
			tracker.recordSample(inference: engine.latestResult(), fused: CanonicalContextState.shared.current(), activeBundle: "com.selftest.browser", referenceTime: tick)
		}
		let resState = tracker.currentState()
		assertCase("research_trajectory", resState?.dominantWorkflow == .research || resState?.dominantWorkflow == .browsing)

		// Conflicting weak transitions
		tracker.reset()
		engine.reset()
		CanonicalContextState.shared.clear()
		for i in 0..<4 {
			let tick = t0.addingTimeInterval(600 + Double(i) * 2)
			let p = fusedPacket(
				at: tick,
				visualKinds: [.browser, .editor, .terminal],
				typing: .idle,
				pointer: .idle,
				confidence: 0.32,
				freshness: 0.36,
				conflict: 0.88,
				isStale: false,
				textAvailability: true,
				lineCount: 3
			)
			CanonicalContextState.shared.update(p)
			engine.evaluate(referenceTime: tick)
			tracker.recordSample(inference: engine.latestResult(), fused: CanonicalContextState.shared.current(), activeBundle: "com.selftest.mixed", referenceTime: tick)
		}
		let weakState = tracker.currentState()
		assertCase("conflicting_weakens", (weakState?.continuityScore ?? 1) < 0.72 || weakState?.dominantWorkflow == .unknown)

		// Stale session decay
		tracker.reset()
		engine.reset()
		CanonicalContextState.shared.clear()
		let staleP = fusedPacket(
			at: t0.addingTimeInterval(800),
			visualKinds: [.browser],
			typing: .idle,
			pointer: .idle,
			confidence: 0.70,
			freshness: 0.08,
			conflict: 0.15,
			isStale: true,
			textAvailability: false,
			lineCount: 0
		)
		CanonicalContextState.shared.update(staleP)
		engine.evaluate(referenceTime: t0.addingTimeInterval(800))
		tracker.recordSample(inference: engine.latestResult(), fused: CanonicalContextState.shared.current(), activeBundle: "com.selftest.browser", referenceTime: t0.addingTimeInterval(800))
		let staleState = tracker.currentState()
		assertCase("stale_decay", staleState?.isStale == true || (staleState?.continuityScore ?? 1) < 0.5)

		// Rapid oscillation then stabilization
		tracker.reset()
		engine.reset()
		CanonicalContextState.shared.clear()
		let patterns: [(InferredWorkflow, [VisualUIKind], TypingState?)] = [
			(.browsing, [.browser], .idle),
			(.debugging, [.terminal], .burst),
			(.browsing, [.browser], .idle),
			(.debugging, [.terminal], .burst),
			(.debugging, [.terminal, .editor], .burst),
			(.debugging, [.terminal, .editor], .burst),
			(.debugging, [.terminal, .editor], .burst)
		]
		var tickO = t0.addingTimeInterval(900)
		for item in patterns {
			let p = fusedPacket(
				at: tickO,
				visualKinds: item.1,
				typing: item.2,
				pointer: .idle,
				confidence: 0.66,
				freshness: 0.76,
				conflict: 0.38,
				isStale: false,
				textAvailability: true,
				lineCount: 9
			)
			CanonicalContextState.shared.update(p)
			if item.1.contains(.terminal), item.1.contains(.editor) {
				engine.recordAppBundle("com.selftest.ide", at: tickO)
				engine.recordAppBundle("com.selftest.term", at: tickO.addingTimeInterval(0.4))
			}
			engine.evaluate(referenceTime: tickO)
			tracker.recordSample(inference: engine.latestResult(), fused: CanonicalContextState.shared.current(), activeBundle: "com.selftest.osc", referenceTime: tickO)
			// Canonical arbitration needs materially newer timestamps to accept changing visual profiles.
			tickO = tickO.addingTimeInterval(11)
		}
		let oscState = tracker.currentState()
		assertCase("oscillation_stabilizes_debugging", oscState?.dominantWorkflow == .debugging)

		// Session reset
		tracker.reset()
		assertCase("reset_nil", tracker.currentState() == nil)

		let ok = failures.isEmpty
		print("[SessionTracking] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		CanonicalContextState.shared.clear()
		engine.reset()
		return ok
	}
}

private func stClamp01(_ x: Double) -> Double {
	min(1.0, max(0.0, x))
}
