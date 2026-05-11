import Foundation

/// Metadata-only inputs for adaptive rich-context sampling (no raw user content).
struct AdaptiveSamplingRequest: Sendable {
	let trigger: RichContextRefreshTrigger
	let requestedSources: Set<ContextCapabilityID>
	let currentCanonicalContext: FusedContextPacket?
	let typingActivity: TypingActivityContext?
	let pointerActivity: PointerActivityContext?
	let isActionExecuting: Bool
	let currentConfidence: Double?
	let workflowKey: String?
	let reason: String?
	let allowExpensiveSources: Bool
}

struct AdaptiveSamplingDecision: Sendable {
	let allowedSources: Set<ContextCapabilityID>
	let deferredSources: Set<ContextCapabilityID>
	let deniedSources: Set<ContextCapabilityID>
	let reuseExistingSources: Set<ContextCapabilityID>
	let reasonCodes: [ContextCapabilityID: String]
	let samplingScore: Double
}

/// Context-layer adaptive planner: pre-filters expensive collection before `ContextBudgetManager`.
/// Deterministic given inputs and `referenceTime`; metadata-only logging.
final class AdaptiveContextSampler {
	static let shared = AdaptiveContextSampler()

	private let lock = NSLock()
	private var recentRecords: [SamplingRecord] = []
	/// Latest adaptive decision (metadata only) for debug UI.
	private var lastSamplingDecision: AdaptiveSamplingDecision?

	private struct SamplingRecord: Sendable {
		let at: Date
		let workflowKey: String
		let sources: Set<ContextCapabilityID>
	}

	private init() {}

	func reset() {
		lock.lock()
		recentRecords.removeAll()
		lastSamplingDecision = nil
		lock.unlock()
	}

	/// Metadata-only snapshot of the most recent `evaluate` decision (for debug UI).
	func lastSamplingDecisionSnapshot() -> AdaptiveSamplingDecision? {
		lock.lock()
		let d = lastSamplingDecision
		lock.unlock()
		return d
	}

	func recordSampling(_ sources: Set<ContextCapabilityID>, workflowKey: String?, recordedAt: Date = Date()) {
		let expensive = sources.intersection(Self.expensiveCapabilities)
		guard !expensive.isEmpty else { return }
		let key = workflowKey ?? "unknown"
		lock.lock()
		recentRecords.append(SamplingRecord(at: recordedAt, workflowKey: key, sources: expensive))
		pruneLocked(referenceTime: recordedAt)
		lock.unlock()
		let label = expensive.map(\.rawValue).sorted().joined(separator: ",")
		print("[AdaptiveSampling] recorded sources=\(label)")
		ContextDebugLogger.shared.log(stage: .adaptive, event: .recorded, source: label, reason: "history_update", meta: ["workflowKey": key])
	}

	func evaluate(_ request: AdaptiveSamplingRequest, referenceTime: Date = Date()) -> AdaptiveSamplingDecision {
		pruneLockedPublic(referenceTime: referenceTime)

		var allowed = Set<ContextCapabilityID>()
		var deferred = Set<ContextCapabilityID>()
		var denied = Set<ContextCapabilityID>()
		var reuse = Set<ContextCapabilityID>()
		var reasonCodes = [ContextCapabilityID: String]()
		var scores: [Double] = []

		let isManual = request.trigger == .manual
		let isExplicitAnalyzeRefresh = (request.reason == "analyze_screen")
		let pkt = request.currentCanonicalContext
		let canonicalFresh = Self.canonicalIsFreshEnough(pkt)
		let weakContext = Self.isWeakContext(packet: pkt, currentConfidence: request.currentConfidence)
		let activeEditing = Self.isActiveEditing(typing: request.typingActivity, pointer: request.pointerActivity)
		let idleOrLight = Self.isIdleOrLight(typing: request.typingActivity, pointer: request.pointerActivity, activeEditing: activeEditing)

		for cap in request.requestedSources.sorted(by: { $0.rawValue < $1.rawValue }) {
			if Self.cheapCapabilities.contains(cap) {
				allowed.insert(cap)
				reasonCodes[cap] = "cheap_metadata"
				scores.append(0.95)
				continue
			}

			guard Self.expensiveCapabilities.contains(cap) else {
				allowed.insert(cap)
				reasonCodes[cap] = "unclassified_allow"
				scores.append(0.70)
				continue
			}

			if cap == .visualDescriptor, deferred.contains(.activeWindowSnapshot) || denied.contains(.activeWindowSnapshot) {
				deferred.insert(cap)
				reasonCodes[cap] = "adaptive_visual_needs_snapshot"
				logLine(outcome: "defer", cap: cap, reason: reasonCodes[cap]!, score: 0.41)
				scores.append(0.41)
				continue
			}

			if !request.allowExpensiveSources {
				denied.insert(cap)
				reasonCodes[cap] = "expensive_not_allowed"
				logLine(outcome: "deny", cap: cap, reason: reasonCodes[cap]!, score: 0.15)
				scores.append(0.15)
				continue
			}

			if request.isActionExecuting {
				denied.insert(cap)
				reasonCodes[cap] = "action_executing_deny_expensive"
				logLine(outcome: "deny", cap: cap, reason: reasonCodes[cap]!, score: 0.10)
				scores.append(0.10)
				continue
			}

			// Reuse: fresh canonical already has this modality.
			if Self.canonicalReusesCapability(pkt, capability: cap, canonicalFresh: canonicalFresh) {
				reuse.insert(cap)
				reasonCodes[cap] = "reuse_fresh_workflow_context"
				logLine(outcome: "reuse", cap: cap, reason: reasonCodes[cap]!, score: nil)
				scores.append(0.88)
				continue
			}

			// Recent identical workflow sampling (short window).
			if let wk = request.workflowKey,
			   historyContainsRecentLocked(workflowKey: wk, capability: cap, referenceTime: referenceTime)
			{
				reuse.insert(cap)
				reasonCodes[cap] = "sampling_history_reuse"
				logLine(outcome: "reuse", cap: cap, reason: reasonCodes[cap]!, score: nil)
				scores.append(0.86)
				continue
			}

			// Visual depends on snapshot: if snapshot is reuse-only and canonical lacks visual, defer visual.
			if cap == .visualDescriptor {
				let snapReuse = reuse.contains(.activeWindowSnapshot) || Self.canonicalReusesCapability(pkt, capability: .activeWindowSnapshot, canonicalFresh: canonicalFresh)
				let hasCanonVisual = (pkt?.hasVisualDescriptor == true) && canonicalFresh
				if snapReuse, !hasCanonVisual {
					deferred.insert(cap)
					reasonCodes[cap] = "adaptive_visual_needs_snapshot"
					logLine(outcome: "defer", cap: cap, reason: reasonCodes[cap]!, score: 0.40)
					scores.append(0.40)
					continue
				}
			}

			if isManual, isExplicitAnalyzeRefresh {
				allowed.insert(cap)
				reasonCodes[cap] = "manual_explicit_analyze_allow"
				let s = activeEditing ? 0.62 : (weakContext ? 0.78 : 0.70)
				logLine(outcome: "allow", cap: cap, reason: reasonCodes[cap]!, score: s)
				scores.append(s)
				continue
			}

			if weakContext, activeEditing {
				deferred.insert(cap)
				reasonCodes[cap] = "low_confidence_defer_active"
				logLine(outcome: "defer", cap: cap, reason: reasonCodes[cap]!, score: 0.38)
				scores.append(0.38)
				continue
			}

			if activeEditing {
				deferred.insert(cap)
				reasonCodes[cap] = "active_editing_reduce_sampling"
				logLine(outcome: "defer", cap: cap, reason: reasonCodes[cap]!, score: 0.42)
				scores.append(0.42)
				continue
			}

			if weakContext, idleOrLight {
				allowed.insert(cap)
				reasonCodes[cap] = "idle_weak_context_allow_rich"
				let s = 0.78
				logLine(outcome: "allow", cap: cap, reason: reasonCodes[cap]!, score: s)
				scores.append(s)
				continue
			}

			if weakContext {
				allowed.insert(cap)
				reasonCodes[cap] = "low_confidence_allow_rich"
				logLine(outcome: "allow", cap: cap, reason: reasonCodes[cap]!, score: 0.72)
				scores.append(0.72)
				continue
			}

			allowed.insert(cap)
			reasonCodes[cap] = "default_allow"
			logLine(outcome: "allow", cap: cap, reason: reasonCodes[cap]!, score: 0.65)
			scores.append(0.65)
		}

		let aggregate: Double
		if scores.isEmpty {
			aggregate = 0.0
		} else {
			aggregate = scores.reduce(0, +) / Double(scores.count)
		}

		let decision = AdaptiveSamplingDecision(
			allowedSources: allowed,
			deferredSources: deferred,
			deniedSources: denied,
			reuseExistingSources: reuse,
			reasonCodes: reasonCodes,
			samplingScore: max(0.0, min(1.0, aggregate))
		)
		lock.lock()
		lastSamplingDecision = decision
		lock.unlock()
		return decision
	}

	// MARK: - Self-test (synthetic metadata only)

	static func runSelfTest() -> Bool {
		print("[AdaptiveSampling] selftest starting")
		let sampler = AdaptiveContextSampler.shared
		sampler.reset()

		let t0 = Date(timeIntervalSince1970: 2_000_000_000)
		var failures: [String] = []

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let typingBurst = Self.makeTyping(state: .burst, intensity: .high, active: true)
		let typingIdle = Self.makeTyping(state: .idle, intensity: .none, active: false)
		let pointerBurst = Self.makePointer(state: .burst, move: .high, click: .high, active: true)
		let pointerIdle = Self.makePointer(state: .idle, move: .none, click: .none, active: false)

		let expensiveRequested: Set<ContextCapabilityID> = [.axWindowContent, .activeWindowSnapshot, .visualDescriptor, .typingActivity]

		// 1) Active typing defers expensive
		var r = sampler.evaluate(Self.makeRequest(
			trigger: .appChanged,
			requested: expensiveRequested,
			typing: typingBurst,
			pointer: pointerIdle,
			confidence: 0.80,
			allowExpensive: true,
			actionExec: false,
			canonical: nil,
			workflowKey: "wf-a",
			t: t0
		), referenceTime: t0)
		assertCase("typing_defers", [.axWindowContent, .activeWindowSnapshot, .visualDescriptor].allSatisfy { r.deferredSources.contains($0) } && r.allowedSources.contains(.typingActivity))

		// 2) Pointer burst defers expensive
		r = sampler.evaluate(Self.makeRequest(
			trigger: .selectionChanged,
			requested: expensiveRequested,
			typing: typingIdle,
			pointer: pointerBurst,
			confidence: 0.80,
			allowExpensive: true,
			actionExec: false,
			canonical: nil,
			workflowKey: "wf-b",
			t: t0
		), referenceTime: t0)
		assertCase("pointer_defers", [.axWindowContent, .activeWindowSnapshot].allSatisfy { r.deferredSources.contains($0) })

		// 3) Idle + weak confidence allows rich
		r = sampler.evaluate(Self.makeRequest(
			trigger: .clipboardChanged,
			requested: expensiveRequested,
			typing: typingIdle,
			pointer: pointerIdle,
			confidence: 0.20,
			allowExpensive: true,
			actionExec: false,
			canonical: nil,
			workflowKey: "wf-c",
			t: t0
		), referenceTime: t0)
		assertCase("idle_weak_allows", r.allowedSources.contains(.axWindowContent) && r.allowedSources.contains(.activeWindowSnapshot))

		// 4) Fresh canonical reuses
		let freshCanon = Self.makePacket(confidence: 0.75, freshness: 0.85, conflict: 0.1, stale: false, available: [.axWindowContent, .activeWindowSnapshot, .visualDescriptor])
		r = sampler.evaluate(Self.makeRequest(
			trigger: .appChanged,
			requested: [.axWindowContent, .activeWindowSnapshot, .visualDescriptor],
			typing: typingIdle,
			pointer: pointerIdle,
			confidence: 0.80,
			allowExpensive: true,
			actionExec: false,
			canonical: freshCanon,
			workflowKey: "wf-d",
			t: t0
		), referenceTime: t0)
		assertCase("canonical_reuse", r.reuseExistingSources == [.axWindowContent, .activeWindowSnapshot, .visualDescriptor])

		// 5) Low confidence + idle allows richer sampling
		r = sampler.evaluate(Self.makeRequest(
			trigger: .screenOCRCompleted,
			requested: [.axWindowContent, .activeWindowSnapshot],
			typing: typingIdle,
			pointer: pointerIdle,
			confidence: 0.30,
			allowExpensive: true,
			actionExec: false,
			canonical: Self.makePacket(confidence: 0.30, freshness: 0.25, conflict: 0.1, stale: false, available: [.activeApp]),
			workflowKey: "wf-e",
			t: t0
		), referenceTime: t0)
		assertCase("low_conf_idle", r.allowedSources.contains(.axWindowContent) && r.allowedSources.contains(.activeWindowSnapshot))

		// 6) Low confidence + active editing defers
		r = sampler.evaluate(Self.makeRequest(
			trigger: .appChanged,
			requested: [.axWindowContent, .visualDescriptor],
			typing: typingBurst,
			pointer: pointerIdle,
			confidence: 0.25,
			allowExpensive: true,
			actionExec: false,
			canonical: nil,
			workflowKey: "wf-f",
			t: t0
		), referenceTime: t0)
		assertCase("low_conf_active_defers", r.deferredSources.contains(.axWindowContent))

		// 7) Action executing denies expensive
		r = sampler.evaluate(Self.makeRequest(
			trigger: .manual,
			requested: [.axWindowContent],
			typing: typingIdle,
			pointer: pointerIdle,
			confidence: 0.20,
			allowExpensive: true,
			actionExec: true,
			canonical: nil,
			workflowKey: "wf-g",
			t: t0
		), referenceTime: t0)
		assertCase("action_exec_denies", r.deniedSources.contains(.axWindowContent))

		// 8) Manual allows during active editing (but not when action executing — covered above); compare automatic vs manual
		let rAuto = sampler.evaluate(Self.makeRequest(
			trigger: .appChanged,
			requested: [.axWindowContent],
			typing: typingBurst,
			pointer: pointerIdle,
			confidence: 0.80,
			allowExpensive: true,
			actionExec: false,
			canonical: nil,
			workflowKey: "wf-h1",
			t: t0
		), referenceTime: t0)
		let rMan = sampler.evaluate(Self.makeRequest(
			trigger: .manual,
			requested: [.axWindowContent],
			typing: typingBurst,
			pointer: pointerIdle,
			confidence: 0.80,
			allowExpensive: true,
			actionExec: false,
			canonical: nil,
			workflowKey: "wf-h2",
			t: t0,
			reason: "analyze_screen"
		), referenceTime: t0)
		assertCase("manual_vs_auto_editing", rAuto.deferredSources.contains(.axWindowContent) && rMan.allowedSources.contains(.axWindowContent))

		let rManualNonAnalyze = sampler.evaluate(Self.makeRequest(
			trigger: .manual,
			requested: [.axWindowContent],
			typing: typingBurst,
			pointer: pointerIdle,
			confidence: 0.80,
			allowExpensive: true,
			actionExec: false,
			canonical: nil,
			workflowKey: "wf-h3",
			t: t0,
			reason: "selftest"
		), referenceTime: t0)
		assertCase("manual_non_analyze_defers_under_burst", rManualNonAnalyze.deferredSources.contains(.axWindowContent))

		// 9) Sampling history reduces repeat collection
		sampler.reset()
		let wfHist = "hist-key"
		let reqHist = Self.makeRequest(
			trigger: .clipboardChanged,
			requested: [.axWindowContent, .typingActivity],
			typing: typingIdle,
			pointer: pointerIdle,
			confidence: 0.55,
			allowExpensive: true,
			actionExec: false,
			canonical: nil,
			workflowKey: wfHist,
			t: t0
		)
		let first = sampler.evaluate(reqHist, referenceTime: t0)
		assertCase("hist_first_allows_ax", first.allowedSources.contains(.axWindowContent))
		sampler.recordSampling([.axWindowContent], workflowKey: wfHist, recordedAt: t0)
		let second = sampler.evaluate(reqHist, referenceTime: t0.addingTimeInterval(4))
		assertCase("hist_second_reuses_ax", second.reuseExistingSources.contains(.axWindowContent) && second.reasonCodes[.axWindowContent] == "sampling_history_reuse")

		// 10) No forbidden substrings in reason codes (sanity)
		let joined = second.reasonCodes.values.joined()
		let forbidden = ["http", "password", "selected", "clipboard", "title"]
		for f in forbidden {
			if joined.localizedCaseInsensitiveContains(f) {
				failures.append("forbidden_token:\(f)")
			}
		}

		let ok = failures.isEmpty
		print("[AdaptiveSampling] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		print("[AdaptiveSampling] selftest finished ok=\(ok)")
		return ok
	}

	// MARK: - Rules

	private static let cheapCapabilities: Set<ContextCapabilityID> = [
		.typingActivity, .cursorActivity, .activeApp, .windowTitle, .selectedText, .clipboardText
	]

	private static let expensiveCapabilities: Set<ContextCapabilityID> = [
		.axWindowContent, .activeWindowSnapshot, .visualDescriptor, .screenOCR, .screenVision
	]

	private static func canonicalIsFreshEnough(_ packet: FusedContextPacket?) -> Bool {
		guard let p = packet else { return false }
		return !p.isStale && p.freshnessScore >= 0.60
	}

	private static func canonicalReusesCapability(_ packet: FusedContextPacket?, capability: ContextCapabilityID, canonicalFresh: Bool) -> Bool {
		guard canonicalFresh, let p = packet else { return false }
		return p.availableSources.contains(capability)
	}

	private static func isWeakContext(packet: FusedContextPacket?, currentConfidence: Double?) -> Bool {
		let confFromPacket = packet?.confidence
		let effective = currentConfidence ?? confFromPacket ?? 0.0
		let confWeak = effective < 0.45
		let conflictHigh = (packet?.conflictScore ?? 0) > 0.35
		return confWeak || conflictHigh
	}

	private static func isActiveEditing(typing: TypingActivityContext?, pointer: PointerActivityContext?) -> Bool {
		var typingHeavy = false
		if let t = typing, t.isTypingActive {
			if t.typingState == .burst || t.typingState == .active { typingHeavy = true }
			if t.burstIntensity == .high || t.burstIntensity == .medium { typingHeavy = true }
		}
		var pointerHeavy = false
		if let p = pointer, p.isPointerActive {
			if p.pointerState == .burst || p.pointerState == .interacting { pointerHeavy = true }
			if p.movementBurstIntensity == .high || p.movementBurstIntensity == .medium { pointerHeavy = true }
			if p.clickBurstIntensity == .high || p.clickBurstIntensity == .medium { pointerHeavy = true }
		}
		return typingHeavy || pointerHeavy
	}

	private static func isIdleOrLight(typing: TypingActivityContext?, pointer: PointerActivityContext?, activeEditing: Bool) -> Bool {
		if activeEditing { return false }
		let ts = typing?.typingState ?? .idle
		let ps = pointer?.pointerState ?? .idle
		if ts == .burst || ps == .burst { return false }
		return true
	}

	private func historyContainsRecentLocked(workflowKey: String, capability: ContextCapabilityID, referenceTime: Date) -> Bool {
		let window: TimeInterval = 22
		let cutoff = referenceTime.addingTimeInterval(-window)
		return recentRecords.contains { rec in
			rec.workflowKey == workflowKey && rec.at >= cutoff && rec.sources.contains(capability)
		}
	}

	private func pruneLocked(referenceTime: Date) {
		let cutoff = referenceTime.addingTimeInterval(-120)
		recentRecords.removeAll { $0.at < cutoff }
	}

	private func pruneLockedPublic(referenceTime: Date) {
		lock.lock()
		pruneLocked(referenceTime: referenceTime)
		lock.unlock()
	}

	private func logLine(outcome: String, cap: ContextCapabilityID, reason: String, score: Double?) {
		if let score {
			print("[AdaptiveSampling] \(outcome) source=\(cap.rawValue) reason=\(reason) score=\(String(format: "%.2f", score))")
		} else {
			print("[AdaptiveSampling] \(outcome) source=\(cap.rawValue) reason=\(reason)")
		}
		let ev: ContextDebugEvent
		switch outcome {
		case "allow": ev = .allowed
		case "defer": ev = .deferred
		case "deny": ev = .denied
		case "reuse": ev = .skipped
		default: ev = .selftest
		}
		ContextDebugLogger.shared.log(stage: .adaptive, event: ev, source: cap.rawValue, reason: reason, score: score)
	}

	// MARK: - Self-test fixtures

	private static func makeRequest(
		trigger: RichContextRefreshTrigger,
		requested: Set<ContextCapabilityID>,
		typing: TypingActivityContext?,
		pointer: PointerActivityContext?,
		confidence: Double,
		allowExpensive: Bool,
		actionExec: Bool,
		canonical: FusedContextPacket?,
		workflowKey: String,
		t: Date,
		reason: String = "selftest"
	) -> AdaptiveSamplingRequest {
		AdaptiveSamplingRequest(
			trigger: trigger,
			requestedSources: requested,
			currentCanonicalContext: canonical,
			typingActivity: typing,
			pointerActivity: pointer,
			isActionExecuting: actionExec,
			currentConfidence: confidence,
			workflowKey: workflowKey,
			reason: reason,
			allowExpensiveSources: allowExpensive
		)
	}

	private static func makeTyping(state: TypingState, intensity: TypingBurstIntensity, active: Bool) -> TypingActivityContext {
		TypingActivityContext(
			id: UUID(),
			updatedAt: Date(),
			appName: nil,
			bundleIdentifier: "com.selftest",
			isTypingActive: active,
			typingState: state,
			recentEventCount: active ? 12 : 0,
			burstIntensity: intensity,
			sessionDuration: 2,
			idleDuration: active ? 0 : 30,
			estimatedEditingActivity: active ? 0.85 : 0.05
		)
	}

	private static func makePointer(state: PointerState, move: PointerBurstIntensity, click: PointerBurstIntensity, active: Bool) -> PointerActivityContext {
		PointerActivityContext(
			id: UUID(),
			updatedAt: Date(),
			appName: nil,
			bundleIdentifier: "com.selftest",
			isPointerActive: active,
			pointerState: state,
			recentMoveEventCount: active ? 40 : 0,
			recentClickEventCount: active ? 2 : 0,
			movementBurstIntensity: move,
			clickBurstIntensity: click,
			sessionDuration: 2,
			idleDuration: active ? 0 : 40,
			estimatedFocusIntensity: active ? 0.8 : 0.05
		)
	}

	private static func makePacket(
		confidence: Double,
		freshness: Double,
		conflict: Double,
		stale: Bool,
		available: [ContextCapabilityID]
	) -> FusedContextPacket {
		FusedContextPacket(
			id: UUID(),
			createdAt: Date(),
			primarySource: .selectedText,
			availableSources: available,
			staleSources: stale ? [.screenOCR] : [],
			appName: nil,
			bundleIdentifier: "com.selftest.bundle",
			windowTitleAvailable: false,
			primaryTextSource: .selectedText,
			textAvailability: true,
			textLength: 40,
			lineCount: 2,
			hasSelectedText: true,
			hasClipboardText: false,
			hasOCRText: false,
			hasAXText: available.contains(.axWindowContent),
			hasWindowSnapshot: available.contains(.activeWindowSnapshot),
			hasVisualDescriptor: available.contains(.visualDescriptor),
			hasTypingActivity: false,
			hasPointerActivity: false,
			visualKinds: [.browser],
			uiStructureHints: [],
			typingState: nil,
			pointerState: nil,
			confidence: confidence,
			freshnessScore: freshness,
			conflictScore: conflict,
			isStale: stale,
			suppressedSources: [],
			supportingSources: [],
			arbitrationReasons: ["selftest"],
			debugSummaryMetadata: ["selftest": "1"]
		)
	}
}
