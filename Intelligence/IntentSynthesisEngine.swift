import Foundation

/// Deterministic, weighted intent concepts from workflow, session, fused metadata, and coarse text signals.
/// Intelligence-only: non-executable, bounded, never persisted, no raw text logging.
final class IntentSynthesisEngine {
	static let shared = IntentSynthesisEngine()

	private let lock = NSLock()
	private var latest: IntentSynthesisResult?
	private var lastLogSignature: String?
	private var lastLogAt: Date?

	private let maxIntents = 3
	private static let scoreFloor: Double = 0.44

	private init() {}

	func reset() {
		lock.lock()
		latest = nil
		lastLogSignature = nil
		lastLogAt = nil
		lock.unlock()
		GeneratedActionEngine.shared.reset()
	}

	func latestResult() -> IntentSynthesisResult? {
		lock.lock()
		let v = latest
		lock.unlock()
		return v
	}

	/// Runs synthesis, stores latest result, and emits metadata-only logs.
	func record(_ request: IntentSynthesisRequest, referenceTime: Date = Date()) {
		let result = Self.synthesize(request, referenceTime: referenceTime)
		lock.lock()
		latest = result
		lock.unlock()
		logOutcome(result, inference: request.workflowInference)
		GeneratedActionEngine.shared.record(from: result.intents, referenceTime: referenceTime)
	}

	// MARK: - Core synthesis

	static func synthesize(_ req: IntentSynthesisRequest, referenceTime: Date) -> IntentSynthesisResult {
		if let fused = req.fused, fused.isStale {
			return IntentSynthesisResult(intents: [], suppressedReason: "stale_context", skippedReason: nil, synthesizedAt: referenceTime)
		}
		if req.fused == nil, let inf = req.workflowInference, inf.isStale {
			return IntentSynthesisResult(intents: [], suppressedReason: "stale_context", skippedReason: nil, synthesizedAt: referenceTime)
		}

		let wf = req.workflowInference?.workflow ?? .unknown
		let fused = req.fused
		let conflict = isClamp01(fused?.conflictScore ?? 0.35)
		let fusionConf = isClamp01(fused?.confidence ?? 0.5)
		let fusionFresh = isClamp01(fused?.freshnessScore ?? 0.5)
		let kinds = Set(fused?.visualKinds ?? [])
		let features = req.features
		let sessionBoost = req.sessionState.map { 0.88 + 0.12 * isClamp01($0.continuityConfidence) } ?? 0.94
		let typing = fused?.typingState
		let textAvail = fused?.textAvailability == true
		let lineCount = fused?.lineCount ?? 0

		// Very weak browsing: intentionally under-generate.
		if wf == .browsing, fusionConf < 0.46, fusionFresh < 0.42 {
			return IntentSynthesisResult(intents: [], suppressedReason: nil, skippedReason: "weak_evidence", synthesizedAt: referenceTime)
		}

		var scores: [(SynthesizedIntentType, Double, [String])] = []

		func add(_ t: SynthesizedIntentType, _ base: Double, _ codes: [String]) {
			guard base > 0.08 else { return }
			scores.append((t, base, codes))
		}

		let logLike = features?.isLikelyLog == true
		let codeLike = features?.isLikelyCode == true
		let hasQuestion = features?.hasQuestion == true
		let wordCount = features?.wordCount ?? 0

		// Debugging + error/code signals → explain likely error / bug source.
		if wf == .debugging || kinds.contains(.terminal) {
			var s = 0.28
			var c = ["rule_debugging_base"]
			if kinds.contains(.terminal) { s += 0.14; c.append("visual_terminal") }
			if kinds.contains(.editor) { s += 0.10; c.append("visual_editor") }
			if logLike { s += 0.22; c.append("feature_log_shape") }
			if codeLike { s += 0.14; c.append("feature_code_shape") }
			add(.explainLikelyError, s * sessionBoost, c)
			if codeLike {
				add(.identifyPossibleBugSource, 0.18 * sessionBoost + (logLike ? 0.08 : 0), ["rule_bug_hunt", "feature_code_shape"])
			}
		}

		// Research / reading-shaped UI.
		if wf == .research || wf == .browsing {
			var s = 0.22
			var c = ["rule_reading_base"]
			if kinds.contains(.article) { s += 0.26; c.append("visual_article") }
			if kinds.contains(.browser) { s += 0.12; c.append("visual_browser") }
			if textAvail, lineCount >= 8 { s += 0.12; c.append("text_shape_long") }
			if typing == .idle || typing == nil { s += 0.06; c.append("typing_idle_reading") }
			add(.summarizeCurrentArticle, s * sessionBoost, c)
			if wordCount > 80, lineCount > 6 {
				add(.extractActionItems, 0.16 * sessionBoost + (wf == .research ? 0.08 : 0), ["rule_action_items_shape", "text_density"])
			}
		}

		// Writing continuity.
		if wf == .writing {
			var r = 0.32
			var c = ["rule_writing_base"]
			if typing == .active || typing == .started || typing == .burst { r += 0.14; c.append("typing_active") }
			if textAvail { r += 0.10; c.append("text_available") }
			add(.reviewSelectedText, r * sessionBoost, c)
			if lineCount > 10 || wordCount > 120 {
				add(.turnNotesIntoChecklist, 0.22 * sessionBoost + 0.06, ["rule_notes_checklist_shape", "text_density"])
			}
			if hasQuestion {
				add(.draftReply, 0.18 * sessionBoost, ["rule_question_reply_shape"])
			}
		}

		// Reviewing / editing + code.
		if wf == .reviewing {
			var s = 0.30
			var c = ["rule_reviewing_base"]
			if codeLike { s += 0.18; c.append("feature_code_shape") }
			if kinds.contains(.editor) { s += 0.10; c.append("visual_editor") }
			add(.summarizeCodeChange, s * sessionBoost, c)
		}
		if wf == .editing, codeLike {
			add(.summarizeCodeChange, 0.26 * sessionBoost, ["rule_editing_code", "feature_code_shape"])
		}

		// API-ish reading + log-shaped text (conservative).
		if logLike, kinds.contains(.browser) || kinds.contains(.article) {
			add(.explainApiResponse, 0.20 * sessionBoost, ["rule_api_log_combo"])
		}

		// Multi-candidate selection context.
		if req.candidateActionIds.count >= 3, textAvail {
			add(.compareSelectedSnippets, 0.16 * sessionBoost, ["rule_multi_candidate"])
		}

		// Explicit analyze / screen path (metadata only).
		let manual = req.triggerType == .manualInvocation
		let wantsAnalyze = req.candidateActionIds.contains("analyze_screen")
		if manual, wantsAnalyze || fused?.hasOCRText == true {
			var s = 0.22
			var c = ["rule_screen_context"]
			if wantsAnalyze { s += 0.20; c.append("candidate_analyze_screen") }
			if fused?.hasOCRText == true { s += 0.12; c.append("has_ocr_metadata") }
			if fused?.hasWindowSnapshot == true { s += 0.06; c.append("has_window_snapshot_metadata") }
			add(.explainScreenContext, s * sessionBoost, c)
		}

		// Aggregate best score per type.
		var merged: [SynthesizedIntentType: (score: Double, codes: [String])] = [:]
		for (t, sc, codes) in scores {
			let adj = sc * (1.0 - 0.28 * conflict) * (0.82 + 0.18 * fusionFresh) * (0.85 + 0.15 * fusionConf)
			if let cur = merged[t] {
				if adj > cur.score {
					merged[t] = (adj, Array(Set(cur.codes + codes)).sorted())
				}
			} else {
				merged[t] = (adj, codes)
			}
		}

		let ranked = merged
			.map { key, val in (key, val.score, val.codes) }
			.filter { $0.1 >= Self.scoreFloor }
			.sorted { $0.1 > $1.1 }

		var intents: [SynthesizedIntent] = []
		for (type, rawScore, codes) in ranked.prefix(3) {
			let conf = isClamp01(rawScore)
			let tpl = Self.template(for: type)
			intents.append(
				SynthesizedIntent(
					id: UUID(),
					type: type,
					title: tpl.title,
					description: tpl.description,
					confidence: conf,
					workflow: wf,
					requiredContext: tpl.requiredContext,
					supportingSignals: codes,
					interruptionCost: tpl.interruptionCost,
					freshness: fusionFresh,
					createdAt: referenceTime,
					isStale: req.workflowInference?.isStale == true || fused?.isStale == true,
					sourceReasonCodes: codes
				)
			)
		}

		if intents.isEmpty {
			// Conflicting fusion: optional low-confidence unknown (still non-executable).
			if conflict > 0.62, wf != .unknown {
				let tpl = Self.template(for: .unknown)
				intents.append(
					SynthesizedIntent(
						id: UUID(),
						type: .unknown,
						title: tpl.title,
						description: tpl.description,
						confidence: isClamp01(0.28 * (1.0 - 0.35 * conflict)),
						workflow: wf,
						requiredContext: tpl.requiredContext,
						supportingSignals: ["rule_unknown_conflict"],
						interruptionCost: tpl.interruptionCost,
						freshness: fusionFresh,
						createdAt: referenceTime,
						isStale: false,
						sourceReasonCodes: ["conflict_dampen"]
					)
				)
				return IntentSynthesisResult(intents: intents, suppressedReason: nil, skippedReason: nil, synthesizedAt: referenceTime)
			}
			return IntentSynthesisResult(intents: [], suppressedReason: nil, skippedReason: "weak_evidence", synthesizedAt: referenceTime)
		}

		return IntentSynthesisResult(intents: intents, suppressedReason: nil, skippedReason: nil, synthesizedAt: referenceTime)
	}

	private struct Template {
		let title: String
		let description: String
		let requiredContext: [IntentRequiredContext]
		let interruptionCost: Double
	}

	private static func template(for type: SynthesizedIntentType) -> Template {
		switch type {
		case .explainLikelyError:
			return Template(
				title: "Explain likely error",
				description: "Summarize probable failure causes from the current technical context.",
				requiredContext: [.textSnippet, .fusedVisual],
				interruptionCost: 0.46
			)
		case .summarizeCurrentArticle:
			return Template(
				title: "Summarize current article",
				description: "Produce a concise overview of the reading in view.",
				requiredContext: [.textSnippet, .fusedVisual],
				interruptionCost: 0.28
			)
		case .extractActionItems:
			return Template(
				title: "Extract action items",
				description: "List concrete follow-ups implied by the visible material.",
				requiredContext: [.textSnippet],
				interruptionCost: 0.34
			)
		case .identifyPossibleBugSource:
			return Template(
				title: "Identify possible bug source",
				description: "Narrow where a defect might originate using structural signals.",
				requiredContext: [.textSnippet, .fusedVisual],
				interruptionCost: 0.50
			)
		case .summarizeCodeChange:
			return Template(
				title: "Summarize code change",
				description: "Describe what changed in the editor or review surface.",
				requiredContext: [.textSnippet, .fusedVisual],
				interruptionCost: 0.36
			)
		case .explainApiResponse:
			return Template(
				title: "Explain API response",
				description: "Interpret response-shaped or log-like content in context.",
				requiredContext: [.textSnippet, .fusedVisual],
				interruptionCost: 0.40
			)
		case .turnNotesIntoChecklist:
			return Template(
				title: "Turn notes into checklist",
				description: "Restructure visible notes into ordered checklist items.",
				requiredContext: [.textSnippet],
				interruptionCost: 0.44
			)
		case .compareSelectedSnippets:
			return Template(
				title: "Compare selected snippets",
				description: "Contrast multiple candidate snippets without executing tools.",
				requiredContext: [.textSnippet, .multiSource],
				interruptionCost: 0.38
			)
		case .draftReply:
			return Template(
				title: "Draft reply",
				description: "Outline a response to question-shaped content in view.",
				requiredContext: [.textSnippet],
				interruptionCost: 0.58
			)
		case .reviewSelectedText:
			return Template(
				title: "Review selected text",
				description: "Suggest improvements to prose in the active writing context.",
				requiredContext: [.textSnippet],
				interruptionCost: 0.42
			)
		case .explainScreenContext:
			return Template(
				title: "Explain screen context",
				description: "Describe what the captured screen region implies at a high level.",
				requiredContext: [.screenCapture, .fusedVisual],
				interruptionCost: 0.48
			)
		case .unknown:
			return Template(
				title: "Unknown assistance",
				description: "Signals conflict; defer specific intent until context stabilizes.",
				requiredContext: [.none],
				interruptionCost: 0.20
			)
		}
	}

	// MARK: - Logging (metadata-only)

	private func logOutcome(_ result: IntentSynthesisResult, inference: WorkflowInferenceResult?) {
		let wf = inference?.workflow.rawValue ?? "nil"
		if let s = result.suppressedReason {
			print("[IntentSynthesis] suppressed reason=\(s)")
			return
		}
		if let s = result.skippedReason {
			print("[IntentSynthesis] skipped reason=\(s)")
			return
		}
		let top = result.topIntentType?.rawValue ?? "none"
		let conf = String(format: "%.2f", result.topConfidence)
		let count = result.intents.count
		let sig = "\(count)|\(top)|\(conf)|\(wf)"
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

		print("[IntentSynthesis] generated count=\(count) top=\(top) confidence=\(conf) workflow=\(wf)")
		if !result.intents.isEmpty {
			print("[IntentSynthesis] kept reason=non_executable count=\(count)")
		}
	}

	// MARK: - DEBUG self-test

	static func runSelfTest() -> Bool {
		print("[IntentSynthesis] selftest starting")
		let engine = IntentSynthesisEngine.shared
		engine.reset()
		var failures: [String] = []
		let t0 = Date(timeIntervalSince1970: 2_020_000_000)

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let emptyFeatures = ContextFeatures(
			textLength: 0,
			wordCount: 0,
			sentenceCount: 0,
			punctuationDensity: 0,
			hasQuestion: false,
			isLikelyCode: false,
			isLikelyLog: false,
			lineCount: 0,
			averageLineLength: 0,
			repetitionScore: 0
		)

		func fused(
			at: Date,
			kinds: [VisualUIKind],
			typing: TypingState?,
			conf: Double,
			fresh: Double,
			conflict: Double,
			stale: Bool,
			text: Bool,
			lines: Int,
			hasOCR: Bool = false
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: at,
				primarySource: .selectedText,
				availableSources: [.activeApp, .visualDescriptor],
				staleSources: [],
				appName: "Synth",
				bundleIdentifier: "synth.bundle",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: text,
				textLength: text ? max(40, lines * 24) : 0,
				lineCount: lines,
				hasSelectedText: text,
				hasClipboardText: false,
				hasOCRText: hasOCR,
				hasAXText: false,
				hasWindowSnapshot: true,
				hasVisualDescriptor: !kinds.isEmpty,
				hasTypingActivity: typing != nil,
				hasPointerActivity: false,
				visualKinds: kinds,
				uiStructureHints: [],
				typingState: typing,
				pointerState: PointerState.idle,
				confidence: isClamp01(conf),
				freshnessScore: isClamp01(fresh),
				conflictScore: isClamp01(conflict),
				isStale: stale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["intent_selftest"],
				debugSummaryMetadata: ["intentSelfTest": "1"]
			)
		}

		// Debugging → explain_likely_error
		let dbgFused = fused(at: t0, kinds: [.terminal, .editor], typing: .burst, conf: 0.72, fresh: 0.78, conflict: 0.32, stale: false, text: true, lines: 14)
		let dbgFeatures = ContextFeatures(
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
		)
		let dbgReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .debugging, confidence: 0.7, contributingSignals: ["t"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: dbgFused.id),
			sessionState: ContextualSessionState(continuityScore: 0.5, continuityConfidence: 0.62, patternConfidence: 0.55, dominantWorkflow: .debugging, activeTrajectorySummary: "debugging>debugging", contributingSignals: [.workflowStreak], updatedAt: t0, isStale: false),
			fused: dbgFused,
			features: dbgFeatures,
			candidateActionIds: ["summarize_text"],
			triggerType: nil,
			lastSourceTrigger: "selectedTextChanged"
		)
		let dbgRes = Self.synthesize(dbgReq, referenceTime: t0)
		assertCase("debugging_explain_error", dbgRes.intents.contains { $0.type == .explainLikelyError })

		// Research / article → summarize article
		let resFused = fused(at: t0.addingTimeInterval(10), kinds: [.browser, .article], typing: .idle, conf: 0.68, fresh: 0.80, conflict: 0.22, stale: false, text: true, lines: 16)
		let resReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .research, confidence: 0.66, contributingSignals: ["r"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: resFused.id),
			sessionState: nil,
			fused: resFused,
			features: emptyFeatures,
			candidateActionIds: [],
			triggerType: nil,
			lastSourceTrigger: nil
		)
		let resRes = Self.synthesize(resReq, referenceTime: t0)
		assertCase("research_summarize_article", resRes.intents.contains { $0.type == .summarizeCurrentArticle })

		// Writing → review or checklist
		let writeFused = fused(at: t0.addingTimeInterval(20), kinds: [.article], typing: .active, conf: 0.70, fresh: 0.76, conflict: 0.24, stale: false, text: true, lines: 18)
		let writeFeat = ContextFeatures(
			textLength: 500,
			wordCount: 140,
			sentenceCount: 10,
			punctuationDensity: 0.04,
			hasQuestion: false,
			isLikelyCode: false,
			isLikelyLog: false,
			lineCount: 18,
			averageLineLength: 28,
			repetitionScore: 0.12
		)
		let writeReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .writing, confidence: 0.72, contributingSignals: ["w"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: writeFused.id),
			sessionState: ContextualSessionState(continuityScore: 0.55, continuityConfidence: 0.70, patternConfidence: 0.6, dominantWorkflow: .writing, activeTrajectorySummary: "writing", contributingSignals: [], updatedAt: t0, isStale: false),
			fused: writeFused,
			features: writeFeat,
			candidateActionIds: [],
			triggerType: nil,
			lastSourceTrigger: nil
		)
		let writeRes = Self.synthesize(writeReq, referenceTime: t0)
		assertCase(
			"writing_review_or_checklist",
			writeRes.intents.contains { $0.type == .reviewSelectedText } || writeRes.intents.contains { $0.type == .turnNotesIntoChecklist }
		)

		// Reviewing + code → summarize code change
		let revFused = fused(at: t0.addingTimeInterval(30), kinds: [.editor], typing: .idle, conf: 0.67, fresh: 0.74, conflict: 0.26, stale: false, text: true, lines: 20)
		let revFeat = ContextFeatures(
			textLength: 600,
			wordCount: 50,
			sentenceCount: 3,
			punctuationDensity: 0.02,
			hasQuestion: false,
			isLikelyCode: true,
			isLikelyLog: false,
			lineCount: 20,
			averageLineLength: 30,
			repetitionScore: 0.05
		)
		let revReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .reviewing, confidence: 0.65, contributingSignals: ["rv"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: revFused.id),
			sessionState: nil,
			fused: revFused,
			features: revFeat,
			candidateActionIds: [],
			triggerType: nil,
			lastSourceTrigger: nil
		)
		let revRes = Self.synthesize(revReq, referenceTime: t0)
		assertCase("reviewing_code_summarize_change", revRes.intents.contains { $0.type == .summarizeCodeChange })

		// Browsing weak → skip or empty
		let browseFused = fused(at: t0.addingTimeInterval(40), kinds: [.browser], typing: .idle, conf: 0.38, fresh: 0.36, conflict: 0.20, stale: false, text: false, lines: 0)
		let browseReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .browsing, confidence: 0.4, contributingSignals: ["b"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: browseFused.id),
			sessionState: nil,
			fused: browseFused,
			features: emptyFeatures,
			candidateActionIds: [],
			triggerType: nil,
			lastSourceTrigger: nil
		)
		let browseRes = Self.synthesize(browseReq, referenceTime: t0)
		assertCase(
			"browsing_weak_empty_or_unknown",
			(browseRes.intents.isEmpty && browseRes.skippedReason == "weak_evidence")
				|| browseRes.intents.contains { $0.type == .unknown }
		)

		// Stale fused → suppressed
		let staleFused = fused(at: t0.addingTimeInterval(50), kinds: [.browser], typing: .idle, conf: 0.7, fresh: 0.1, conflict: 0.2, stale: true, text: true, lines: 10)
		let staleReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .research, confidence: 0.5, contributingSignals: ["s"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: staleFused.id),
			sessionState: nil,
			fused: staleFused,
			features: emptyFeatures,
			candidateActionIds: [],
			triggerType: nil,
			lastSourceTrigger: nil
		)
		let staleRes = Self.synthesize(staleReq, referenceTime: t0)
		assertCase("stale_suppress", staleRes.suppressedReason == "stale_context" && staleRes.intents.isEmpty)

		// Conflicting lowers confidence vs calm
		let calmReq = dbgReq
		let calmRes = Self.synthesize(calmReq, referenceTime: t0)
		let hiConflictFused = fused(at: t0.addingTimeInterval(60), kinds: [.terminal, .editor], typing: .burst, conf: 0.72, fresh: 0.78, conflict: 0.88, stale: false, text: true, lines: 14)
		let hiReq = IntentSynthesisRequest(
			workflowInference: calmReq.workflowInference,
			sessionState: calmReq.sessionState,
			fused: hiConflictFused,
			features: dbgFeatures,
			candidateActionIds: calmReq.candidateActionIds,
			triggerType: nil,
			lastSourceTrigger: nil
		)
		let hiRes = Self.synthesize(hiReq, referenceTime: t0)
		let calmTop = calmRes.topConfidence
		let hiTop = hiRes.topConfidence
		assertCase("conflict_lowers_confidence", hiTop < calmTop - 1e-6)

		// Bounded
		let manyReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .debugging, confidence: 0.8, contributingSignals: [], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: dbgFused.id),
			sessionState: nil,
			fused: dbgFused,
			features: dbgFeatures,
			candidateActionIds: ["a", "b", "c", "d"],
			triggerType: .manualInvocation,
			lastSourceTrigger: nil
		)
		let manyRes = Self.synthesize(manyReq, referenceTime: t0)
		assertCase("bounded_three", manyRes.intents.count <= 3)

		// Reset clears stored latest
		engine.record(manyReq, referenceTime: t0)
		assertCase("prerecord_latest", engine.latestResult() != nil)
		engine.reset()
		assertCase("reset_clears_latest", engine.latestResult() == nil)

		let ok = failures.isEmpty
		print("[IntentSynthesis] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}

private func isClamp01(_ x: Double) -> Double {
	min(1.0, max(0.0, x))
}
