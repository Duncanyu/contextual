import Foundation

/// Filters synthesized intents before generated actions / downstream ranking (metadata-only).
final class DynamicIntentSuppressionEngine {
	static let shared = DynamicIntentSuppressionEngine()

	private let lock = NSLock()
	private var ring: [(fingerprint: String, at: Date)] = []
	private var profile = IntentSuppressionProfile()
	private var lastAllowedLogSig: String?
	private var lastAllowedLogAt: Date?

	private init() {}

	func reset() {
		lock.lock()
		ring.removeAll(keepingCapacity: false)
		lastAllowedLogSig = nil
		lastAllowedLogAt = nil
		lock.unlock()
	}

	func setProfileForSelfTest(_ p: IntentSuppressionProfile) {
		lock.lock()
		profile = p
		lock.unlock()
	}

	func restoreDefaultProfileForSelfTest() {
		lock.lock()
		profile = IntentSuppressionProfile()
		lock.unlock()
	}

	/// Deterministic pass over `rawIntents` (order preserved for allowed).
	func evaluate(
		rawIntents: [SynthesizedIntent],
		request: IntentSynthesisRequest,
		referenceTime: Date
	) -> IntentSuppressionDecision {
		let manual = request.triggerType == .manualInvocation
		let fused = request.fused
		let wfInf = request.workflowInference
		let sessionCont = request.sessionState.map { min(1.0, max(0.0, $0.continuityConfidence)) } ?? 0.0
		let fusionConf = min(1.0, max(0.0, fused?.confidence ?? 0.5))
		let conflict = min(1.0, max(0.0, fused?.conflictScore ?? 0.35))
		let fusionFresh = min(1.0, max(0.0, fused?.freshnessScore ?? 0.5))
		let wfType = wfInf?.workflow ?? .unknown
		let browsingWeak = wfType == .browsing
			&& fusionConf < profile.browsingFusionMax
			&& fusionFresh < profile.browsingFreshnessMax + 0.02
		let weakMultimodal = fusionConf < profile.weakMultimodalFusionMax && conflict > profile.weakMultimodalConflictMin
		let interactionBurst = Self.isInteractionBurst(fused: fused)
		let staleWorkflow = wfInf?.isStale == true
		let canonicalStale = CanonicalContextState.shared.current()?.isStale == true

		let minConf = manual ? profile.minConfidenceManual : profile.minConfidenceAuto
		let minConfStaleWf = manual ? profile.minConfidenceStaleWorkflowManual : profile.minConfidenceStaleWorkflowAuto
		let minConfMultimodal = manual ? profile.weakMultimodalMinConfidenceManual : profile.weakMultimodalMinConfidenceAuto
		let burstMin = manual ? profile.interactionBurstMinConfidenceManual : profile.interactionBurstMinConfidence
		let repeatWindow = manual ? profile.repeatWindowManual : profile.repeatWindowAuto

		var allowed: [SynthesizedIntent] = []
		var suppressed: [IntentSuppressionEntry] = []
		var reasonSet = Set<IntentSuppressionReason>()
		var strongWorkflowSignal = false

		let latestGA = GeneratedActionEngine.shared.latestActions()

		for intent in rawIntents {
			if intent.isStale {
				logSuppressed(type: intent.type, reason: .staleIntent)
				suppressed.append(IntentSuppressionEntry(intentType: intent.type, reason: .staleIntent))
				reasonSet.insert(.staleIntent)
				appendRingFingerprintIfNeeded(intent: intent, request: request, referenceTime: referenceTime, suppressed: true)
				continue
			}

			if intent.confidence < minConf {
				logSuppressed(type: intent.type, reason: .lowConfidence)
				suppressed.append(IntentSuppressionEntry(intentType: intent.type, reason: .lowConfidence))
				reasonSet.insert(.lowConfidence)
				appendRingFingerprintIfNeeded(intent: intent, request: request, referenceTime: referenceTime, suppressed: true)
				continue
			}

			if staleWorkflow || canonicalStale {
				let exemptStaleWf = intent.type == .explainLikelyError
					&& intent.workflow == .debugging
					&& intent.confidence >= 0.54
				if !exemptStaleWf, intent.confidence < minConfStaleWf {
					logSuppressed(type: intent.type, reason: .staleWorkflow)
					suppressed.append(IntentSuppressionEntry(intentType: intent.type, reason: .staleWorkflow))
					reasonSet.insert(.staleWorkflow)
					appendRingFingerprintIfNeeded(intent: intent, request: request, referenceTime: referenceTime, suppressed: true)
					continue
				}
			}

			if weakMultimodal, intent.confidence < minConfMultimodal {
				logSuppressed(type: intent.type, reason: .weakMultimodalAgreement)
				suppressed.append(IntentSuppressionEntry(intentType: intent.type, reason: .weakMultimodalAgreement))
				reasonSet.insert(.weakMultimodalAgreement)
				appendRingFingerprintIfNeeded(intent: intent, request: request, referenceTime: referenceTime, suppressed: true)
				continue
			}

			if browsingWeak {
				let summarizeOk = intent.type == .summarizeCurrentArticle && intent.confidence >= profile.browsingSummarizeMinConfidence
				if !summarizeOk, intent.confidence < profile.browsingMinConfidence {
					logSuppressed(type: intent.type, reason: .weakBrowsingContext)
					suppressed.append(IntentSuppressionEntry(intentType: intent.type, reason: .weakBrowsingContext))
					reasonSet.insert(.weakBrowsingContext)
					appendRingFingerprintIfNeeded(intent: intent, request: request, referenceTime: referenceTime, suppressed: true)
					continue
				}
			}

			if interactionBurst {
				let strongExplain = intent.workflow == .debugging
					&& intent.type == .explainLikelyError
					&& intent.confidence >= 0.52
					&& sessionCont >= 0.48
				let strongSummarize = (intent.workflow == .research || intent.workflow == .browsing)
					&& intent.type == .summarizeCurrentArticle
					&& intent.confidence >= 0.55
					&& sessionCont >= 0.45
				if strongExplain || strongSummarize {
					strongWorkflowSignal = true
				} else if intent.confidence < burstMin {
					logSuppressed(type: intent.type, reason: .activeInteractionBurst)
					suppressed.append(IntentSuppressionEntry(intentType: intent.type, reason: .activeInteractionBurst))
					reasonSet.insert(.activeInteractionBurst)
					appendRingFingerprintIfNeeded(intent: intent, request: request, referenceTime: referenceTime, suppressed: true)
					continue
				}
			}

			let fp = Self.fingerprint(intent: intent, request: request)
			if isRecentDuplicate(fingerprint: fp, before: referenceTime, window: repeatWindow) {
				logSuppressed(type: intent.type, reason: .repeatedIntent)
				suppressed.append(IntentSuppressionEntry(intentType: intent.type, reason: .repeatedIntent))
				reasonSet.insert(.repeatedIntent)
				appendRingFingerprintIfNeeded(intent: intent, request: request, referenceTime: referenceTime, suppressed: true)
				continue
			}

			if shouldSuppressNearDuplicateGA(intent: intent, latestGA: latestGA, manual: manual) {
				logSuppressed(type: intent.type, reason: .repeatedIntent)
				suppressed.append(IntentSuppressionEntry(intentType: intent.type, reason: .repeatedIntent))
				reasonSet.insert(.repeatedIntent)
				appendRingFingerprintIfNeeded(intent: intent, request: request, referenceTime: referenceTime, suppressed: true)
				continue
			}

			allowed.append(intent)
			recordFingerprint(fp, at: referenceTime)
		}

		let codes = IntentSuppressionReason.allCases.filter { reasonSet.contains($0) }
		logAllowedSummary(allowed: allowed, suppressedReasons: codes, referenceTime: referenceTime)
		if strongWorkflowSignal, !allowed.isEmpty {
			print("[IntentSuppression] kept reason=strong_workflow_signal")
		}

		return IntentSuppressionDecision(
			rawIntents: rawIntents,
			allowed: allowed,
			suppressed: suppressed,
			reasonCodes: codes
		)
	}

	private func shouldSuppressNearDuplicateGA(intent: SynthesizedIntent, latestGA: [GeneratedAction], manual: Bool) -> Bool {
		guard let top = latestGA.max(by: { $0.confidence < $1.confidence }) else { return false }
		guard top.intentType == intent.type else { return false }
		let margin = manual ? 0.06 : 0.10
		return top.confidence >= intent.confidence + margin
	}

	private func isRecentDuplicate(fingerprint: String, before: Date, window: TimeInterval) -> Bool {
		lock.lock()
		let dup = ring.contains { $0.fingerprint == fingerprint && before.timeIntervalSince($0.at) <= window }
		lock.unlock()
		return dup
	}

	private func appendRingFingerprintIfNeeded(intent: SynthesizedIntent, request: IntentSynthesisRequest, referenceTime: Date, suppressed: Bool) {
		if suppressed {
			recordFingerprint(Self.fingerprint(intent: intent, request: request), at: referenceTime)
		}
	}

	private func recordFingerprint(_ fp: String, at: Date) {
		lock.lock()
		ring.append((fp, at))
		if ring.count > profile.ringCapacity {
			ring.removeFirst(ring.count - profile.ringCapacity)
		}
		lock.unlock()
	}

	private func logSuppressed(type: SynthesizedIntentType, reason: IntentSuppressionReason) {
		print("[IntentSuppression] suppressed intent=\(type.rawValue) reason=\(reason.rawValue)")
	}

	private func logAllowedSummary(allowed: [SynthesizedIntent], suppressedReasons: [IntentSuppressionReason], referenceTime: Date) {
		let top = allowed.max(by: { $0.confidence < $1.confidence })?.type.rawValue ?? "none"
		let rs = suppressedReasons.map(\.rawValue).sorted().joined(separator: ",")
		let sig = "\(allowed.count)|\(top)|\(rs)"
		lock.lock()
		let skip: Bool
		if lastAllowedLogSig == sig, let t = lastAllowedLogAt, referenceTime.timeIntervalSince(t) < 2.1 {
			skip = true
		} else {
			skip = false
			lastAllowedLogSig = sig
			lastAllowedLogAt = referenceTime
		}
		lock.unlock()
		if skip { return }
		let reason = rs.isEmpty ? "none" : rs
		print("[IntentSuppression] allowed count=\(allowed.count) top=\(top) reason=\(reason)")
	}

	static func fingerprint(intent: SynthesizedIntent, request: IntentSynthesisRequest) -> String {
		let pk = request.fused?.primarySource.rawValue ?? "none"
		let kinds = (request.fused?.visualKinds ?? []).map(\.rawValue).sorted().joined(separator: ",")
		let textB = request.fused?.textAvailability == true ? "t" : "f"
		let trig = request.triggerType?.rawValue ?? "nil"
		let rc = intent.requiredContext.map(\.rawValue).sorted().joined(separator: ",")
		let codes = intent.sourceReasonCodes.sorted().joined(separator: ",")
		let wf = intent.workflow.rawValue
		return "\(intent.type.rawValue)|\(wf)|\(rc)|\(codes)|\(pk)|\(kinds)|\(textB)|\(trig)"
	}

	static func isInteractionBurst(fused: FusedContextPacket?) -> Bool {
		guard let f = fused else { return false }
		if f.typingState == .burst { return true }
		if f.pointerState == .burst { return true }
		return false
	}
}

// MARK: - DEBUG self-test

extension DynamicIntentSuppressionEngine {
	static func runSelfTest() -> Bool {
		print("[IntentSuppression] selftest starting")
		var failures: [String] = []
		let t0 = Date(timeIntervalSince1970: 2_040_000_000)
		let engine = DynamicIntentSuppressionEngine.shared
		engine.reset()
		engine.restoreDefaultProfileForSelfTest()

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func fusedStub(
			typing: TypingState?,
			pointer: PointerState?,
			conf: Double,
			conflict: Double,
			fresh: Double,
			kinds: [VisualUIKind],
			text: Bool
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: t0,
				primarySource: .selectedText,
				availableSources: [.activeApp, .visualDescriptor],
				staleSources: [],
				appName: "S",
				bundleIdentifier: "s.bundle",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: text,
				textLength: text ? 120 : 0,
				lineCount: text ? 8 : 0,
				hasSelectedText: text,
				hasClipboardText: false,
				hasOCRText: false,
				hasAXText: false,
				hasWindowSnapshot: true,
				hasVisualDescriptor: !kinds.isEmpty,
				hasTypingActivity: typing != nil,
				hasPointerActivity: (pointer ?? .idle) != .idle,
				visualKinds: kinds,
				uiStructureHints: [],
				typingState: typing,
				pointerState: pointer,
				confidence: conf,
				freshnessScore: fresh,
				conflictScore: conflict,
				isStale: false,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["intent_suppression_selftest"],
				debugSummaryMetadata: ["intentSuppressionSelfTest": "1"]
			)
		}

		func intent(
			_ type: SynthesizedIntentType,
			conf: Double,
			wf: InferredWorkflow,
			stale: Bool = false,
			codes: [String] = ["t"]
		) -> SynthesizedIntent {
			SynthesizedIntent(
				id: UUID(),
				type: type,
				title: "t",
				description: "d",
				confidence: conf,
				workflow: wf,
				requiredContext: [.textSnippet],
				supportingSignals: codes,
				interruptionCost: 0.4,
				freshness: 0.75,
				createdAt: t0,
				isStale: stale,
				sourceReasonCodes: codes
			)
		}

		func req(
			fused: FusedContextPacket?,
			wf: WorkflowInferenceResult?,
			session: ContextualSessionState?,
			manual: Bool
		) -> IntentSynthesisRequest {
			IntentSynthesisRequest(
				workflowInference: wf,
				sessionState: session,
				fused: fused,
				features: nil,
				candidateActionIds: [],
				triggerType: manual ? .manualInvocation : .selectedTextEligible,
				lastSourceTrigger: "selftest"
			)
		}

		// Low confidence (auto)
		let low = intent(.reviewSelectedText, conf: 0.46, wf: .writing)
		let fusedCalm = fusedStub(typing: .idle, pointer: .idle, conf: 0.70, conflict: 0.25, fresh: 0.76, kinds: [.article], text: true)
		let wfOk = WorkflowInferenceResult(workflow: .writing, confidence: 0.7, contributingSignals: ["s"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: fusedCalm.id)
		let dLow = engine.evaluate(rawIntents: [low], request: req(fused: fusedCalm, wf: wfOk, session: nil, manual: false), referenceTime: t0)
		assertCase("low_confidence_suppressed", dLow.allowed.isEmpty && dLow.suppressed.contains { $0.reason == .lowConfidence })

		// Stale intent
		let staleI = intent(.explainLikelyError, conf: 0.72, wf: .debugging, stale: true)
		let dStaleI = engine.evaluate(rawIntents: [staleI], request: req(fused: fusedCalm, wf: wfOk, session: nil, manual: false), referenceTime: t0)
		assertCase("stale_intent_suppressed", dStaleI.suppressed.contains { $0.reason == .staleIntent })

		// Stale workflow suppresses mediocre
		let med = intent(.extractActionItems, conf: 0.52, wf: .research)
		let wfStale = WorkflowInferenceResult(workflow: .research, confidence: 0.4, contributingSignals: ["s"], inferredAt: t0, isStale: true, summaryHint: nil, sourceFusedId: fusedCalm.id)
		let dStaleWf = engine.evaluate(rawIntents: [med], request: req(fused: fusedCalm, wf: wfStale, session: nil, manual: false), referenceTime: t0)
		assertCase("stale_workflow_suppresses", dStaleWf.allowed.isEmpty)

		// Repeated fingerprint
		engine.reset()
		let a1 = intent(.summarizeCurrentArticle, conf: 0.66, wf: .research, codes: ["c1"])
		let rRep = req(fused: fusedCalm, wf: wfOk, session: nil, manual: false)
		_ = engine.evaluate(rawIntents: [a1], request: rRep, referenceTime: t0)
		let dRep = engine.evaluate(rawIntents: [a1], request: rRep, referenceTime: t0.addingTimeInterval(2))
		assertCase("repeated_suppressed", dRep.suppressed.contains { $0.reason == .repeatedIntent })

		// Burst + weak vs strong debugging explain
		engine.reset()
		let fusedBurst = fusedStub(typing: .burst, pointer: .idle, conf: 0.72, conflict: 0.30, fresh: 0.78, kinds: [.terminal, .editor], text: true)
		let wfDbg = WorkflowInferenceResult(workflow: .debugging, confidence: 0.72, contributingSignals: ["d"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: fusedBurst.id)
		let sessStrong = ContextualSessionState(continuityScore: 0.55, continuityConfidence: 0.64, patternConfidence: 0.5, dominantWorkflow: .debugging, activeTrajectorySummary: "d", contributingSignals: [], updatedAt: t0, isStale: false)
		let weakReview = intent(.reviewSelectedText, conf: 0.58, wf: .writing)
		let dBurstWeak = engine.evaluate(rawIntents: [weakReview], request: req(fused: fusedBurst, wf: wfOk, session: sessStrong, manual: false), referenceTime: t0)
		assertCase("burst_suppresses_weak", dBurstWeak.suppressed.contains { $0.reason == .activeInteractionBurst })

		engine.reset()
		let strongExplain = intent(.explainLikelyError, conf: 0.68, wf: .debugging, codes: ["rule_debugging_base"])
		let dBurstStrong = engine.evaluate(rawIntents: [strongExplain], request: req(fused: fusedBurst, wf: wfDbg, session: sessStrong, manual: false), referenceTime: t0)
		assertCase("strong_debugging_survives_burst", dBurstStrong.allowed.contains { $0.type == .explainLikelyError })

		// Weak browsing context suppresses non-summarize mediocre intents
		engine.reset()
		let browseF = fusedStub(typing: .idle, pointer: .idle, conf: 0.44, conflict: 0.25, fresh: 0.34, kinds: [.browser], text: false)
		let wfBrowse = WorkflowInferenceResult(workflow: .browsing, confidence: 0.4, contributingSignals: ["b"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: browseF.id)
		let extractWeak = intent(.extractActionItems, conf: 0.55, wf: .browsing)
		let dBrowse = engine.evaluate(rawIntents: [extractWeak], request: req(fused: browseF, wf: wfBrowse, session: nil, manual: false), referenceTime: t0)
		assertCase("weak_browsing_suppressed", dBrowse.suppressed.contains { $0.reason == .weakBrowsingContext })

		// High conflict + low fused confidence
		engine.reset()
		let fusedBad = fusedStub(typing: .idle, pointer: .idle, conf: 0.42, conflict: 0.72, fresh: 0.50, kinds: [.browser], text: true)
		let mid = intent(.summarizeCurrentArticle, conf: 0.50, wf: .browsing)
		let dMM = engine.evaluate(rawIntents: [mid], request: req(fused: fusedBad, wf: wfOk, session: nil, manual: false), referenceTime: t0)
		assertCase("multimodal_suppresses", dMM.suppressed.contains { $0.reason == .weakMultimodalAgreement })

		// Strong research summarize (calm fusion)
		engine.reset()
		let fusedRead = fusedStub(typing: .idle, pointer: .idle, conf: 0.68, conflict: 0.22, fresh: 0.80, kinds: [.article, .browser], text: true)
		let wfRes = WorkflowInferenceResult(workflow: .research, confidence: 0.66, contributingSignals: ["r"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: fusedRead.id)
		let sum = intent(.summarizeCurrentArticle, conf: 0.64, wf: .research)
		let dRes = engine.evaluate(rawIntents: [sum], request: req(fused: fusedRead, wf: wfRes, session: sessStrong, manual: false), referenceTime: t0)
		assertCase("strong_research_summarize", dRes.allowed.contains { $0.type == .summarizeCurrentArticle })

		// Manual more permissive on confidence, still stale intent blocked
		engine.reset()
		let borderline = intent(.draftReply, conf: 0.44, wf: .writing)
		let dMan = engine.evaluate(rawIntents: [borderline], request: req(fused: fusedCalm, wf: wfOk, session: nil, manual: true), referenceTime: t0)
		assertCase("manual_permissive_conf", !dMan.allowed.isEmpty)

		engine.reset()
		let staleManual = intent(.summarizeCurrentArticle, conf: 0.70, wf: .research, stale: true)
		let dManStale = engine.evaluate(rawIntents: [staleManual], request: req(fused: fusedRead, wf: wfRes, session: nil, manual: true), referenceTime: t0)
		assertCase("manual_still_suppresses_stale", dManStale.allowed.isEmpty)

		// Ring bounded: fill with distinct fingerprints then one more should not crash
		engine.reset()
		var p = IntentSuppressionProfile()
		p.ringCapacity = 8
		engine.setProfileForSelfTest(p)
		for i in 0..<12 {
			let ii = intent(.unknown, conf: 0.90, wf: .unknown, codes: ["u\(i)"])
			_ = engine.evaluate(rawIntents: [ii], request: req(fused: fusedCalm, wf: wfOk, session: nil, manual: false), referenceTime: t0.addingTimeInterval(Double(i)))
		}
		engine.lockRingCountForSelfTest { c in
			assertCase("ring_bounded", c <= 8)
		}
		engine.restoreDefaultProfileForSelfTest()

		// reset clears history (repeat works again)
		engine.reset()
		let one = intent(.summarizeCurrentArticle, conf: 0.66, wf: .research, codes: ["x"])
		let rOne = req(fused: fusedRead, wf: wfRes, session: nil, manual: false)
		_ = engine.evaluate(rawIntents: [one], request: rOne, referenceTime: t0)
		engine.reset()
		let dAgain = engine.evaluate(rawIntents: [one], request: rOne, referenceTime: t0.addingTimeInterval(1))
		assertCase("reset_clears_repeat", !dAgain.suppressed.contains { $0.reason == .repeatedIntent })

		// GeneratedActionEngine only receives allowed via IntentSynthesisEngine.record
		IntentSynthesisEngine.shared.reset()
		GeneratedActionEngine.shared.reset()
		let synthReq = IntentSynthesisRequest(
			workflowInference: wfDbg,
			sessionState: sessStrong,
			fused: fusedBurst,
			features: ContextFeatures(
				textLength: 400,
				wordCount: 40,
				sentenceCount: 4,
				punctuationDensity: 0.05,
				hasQuestion: false,
				isLikelyCode: true,
				isLikelyLog: true,
				lineCount: 12,
				averageLineLength: 33,
				repetitionScore: 0.1
			),
			candidateActionIds: ["summarize_text"],
			triggerType: .selectedTextEligible,
			lastSourceTrigger: "selectedTextChanged"
		)
		IntentSynthesisEngine.shared.record(synthReq, referenceTime: t0)
		let postExplain = IntentSynthesisEngine.shared.latestResult()?.intents.contains { $0.type == .explainLikelyError } ?? false
		let postGA = GeneratedActionEngine.shared.latestActions().contains { $0.intentType == .explainLikelyError }
		assertCase("ga_receives_allowed_only", postExplain == postGA)

		let ok = failures.isEmpty
		print("[IntentSuppression] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}

	/// Test hook: ring size under lock.
	fileprivate func lockRingCountForSelfTest(_ body: (Int) -> Void) {
		lock.lock()
		let c = ring.count
		lock.unlock()
		body(c)
	}
}
