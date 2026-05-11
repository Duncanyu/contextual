import Foundation

/// Phase 15 stabilization checks: conservative generated-intent pipeline, preview-only actions, metadata-only surfaces.
@MainActor
enum Phase15TuningSelfTest {
	static func run() -> Bool {
		print("[Phase15Tuning] selftest starting")
		print("[Phase15Tuning] tuned reason=workflow_thresholds")
		print("[Phase15Tuning] tuned reason=intent_suppression")
		print("[Phase15Tuning] tuned reason=generated_action_quality")
		print("[Phase15Tuning] tuned reason=preview_filtering")

		IntentSynthesisEngine.shared.reset()
		GeneratedActionEngine.shared.reset()
		DynamicIntentSuppressionEngine.shared.reset()
		DynamicIntentSuppressionEngine.shared.restoreDefaultProfileForSelfTest()

		var failures: [String] = []
		let t0 = Date(timeIntervalSince1970: 2_080_000_000)

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func fusedPacket(
			at: Date,
			kinds: [VisualUIKind],
			typing: TypingState?,
			conf: Double,
			fresh: Double,
			conflict: Double,
			stale: Bool,
			text: Bool,
			lines: Int,
			wordLen: Int = 22,
			hasOCR: Bool = false
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: at,
				primarySource: .selectedText,
				availableSources: [.activeApp, .visualDescriptor],
				staleSources: [],
				appName: "Phase15",
				bundleIdentifier: "phase15.selftest",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: text,
				textLength: text ? max(40, lines * wordLen) : 0,
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
				pointerState: .idle,
				confidence: min(1.0, max(0.0, conf)),
				freshnessScore: min(1.0, max(0.0, fresh)),
				conflictScore: min(1.0, max(0.0, conflict)),
				isStale: stale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["phase15_tuning_selftest"],
				debugSummaryMetadata: ["phase15TuningSelfTest": "1"]
			)
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

		// 1) Weak video-like browsing → no synthesized intents / no generated actions.
		let ytFused = fusedPacket(
			at: t0,
			kinds: [.browser, .media],
			typing: .idle,
			conf: 0.62,
			fresh: 0.58,
			conflict: 0.22,
			stale: false,
			text: true,
			lines: 3,
			wordLen: 6
		)
		let ytReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .browsing, confidence: 0.55, contributingSignals: ["b"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: ytFused.id),
			sessionState: nil,
			fused: ytFused,
			features: ContextFeatures(
				textLength: 40,
				wordCount: 8,
				sentenceCount: 2,
				punctuationDensity: 0.02,
				hasQuestion: false,
				isLikelyCode: false,
				isLikelyLog: false,
				lineCount: 3,
				averageLineLength: 12,
				repetitionScore: 0.1
			),
			candidateActionIds: [],
			triggerType: nil,
			lastSourceTrigger: nil
		)
		let ytSynth = IntentSynthesisEngine.synthesize(ytReq, referenceTime: t0)
		assertCase("weak_video_no_intents", ytSynth.intents.isEmpty)
		GeneratedActionEngine.shared.reset()
		GeneratedActionEngine.shared.record(from: ytSynth.intents, referenceTime: t0)
		assertCase("weak_video_no_ga", GeneratedActionEngine.shared.latestActions().isEmpty)

		// 2) Strong debugging → explain intent materializes + plan, preview-only.
		let dbgFused = fusedPacket(
			at: t0.addingTimeInterval(10),
			kinds: [.terminal, .editor],
			typing: .burst,
			conf: 0.72,
			fresh: 0.78,
			conflict: 0.32,
			stale: false,
			text: true,
			lines: 14
		)
		let dbgFeat = ContextFeatures(
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
			workflowInference: WorkflowInferenceResult(workflow: .debugging, confidence: 0.72, contributingSignals: ["d"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: dbgFused.id),
			sessionState: ContextualSessionState(continuityScore: 0.55, continuityConfidence: 0.64, patternConfidence: 0.55, dominantWorkflow: .debugging, activeTrajectorySummary: "d", contributingSignals: [.workflowStreak], updatedAt: t0, isStale: false),
			fused: dbgFused,
			features: dbgFeat,
			candidateActionIds: ["summarize_text"],
			triggerType: .selectedTextEligible,
			lastSourceTrigger: "selectedTextChanged"
		)
		IntentSynthesisEngine.shared.reset()
		IntentSynthesisEngine.shared.record(dbgReq, referenceTime: t0)
		let dbgIntents = IntentSynthesisEngine.shared.latestResult()?.intents ?? []
		assertCase("debugging_has_explain", dbgIntents.contains { $0.type == .explainLikelyError })
		let topExplain = dbgIntents.first { $0.type == .explainLikelyError }
		if let te = topExplain, case .produced(let ga) = GeneratedActionFactory.materialize(from: te, referenceTime: t0, source: .selfTest) {
			assertCase("debug_ga_quality", ga.confidence >= GeneratedActionFactory.minimumIntentConfidence)
			assertCase("debug_ga_safe", ga.safetyProfile.canRunAutomatically == false && !ga.safetyProfile.usesShell && !ga.safetyProfile.usesNetwork)
			if case .accepted(let plan) = GeneratedActionPlanBuilder.build(from: ga, referenceTime: t0) {
				assertCase("debug_plan_non_exec", plan.isExecutable == false && plan.steps.count <= 3)
			} else {
				assertCase("debug_plan_built", false)
			}
		} else {
			assertCase("debugging_materialize", false)
		}

		// 3) Research article → summarize path.
		let resFused = fusedPacket(
			at: t0.addingTimeInterval(20),
			kinds: [.browser, .article],
			typing: .idle,
			conf: 0.68,
			fresh: 0.80,
			conflict: 0.22,
			stale: false,
			text: true,
			lines: 16
		)
		let resReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .research, confidence: 0.66, contributingSignals: ["r"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: resFused.id),
			sessionState: nil,
			fused: resFused,
			features: emptyFeatures,
			candidateActionIds: [],
			triggerType: nil,
			lastSourceTrigger: nil
		)
		let resSynth = IntentSynthesisEngine.synthesize(resReq, referenceTime: t0)
		assertCase("research_summarize", resSynth.intents.contains { $0.type == .summarizeCurrentArticle })

		// 4) Writing + density → review or checklist.
		let writeFused = fusedPacket(
			at: t0.addingTimeInterval(30),
			kinds: [.article],
			typing: .active,
			conf: 0.70,
			fresh: 0.76,
			conflict: 0.24,
			stale: false,
			text: true,
			lines: 18
		)
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
			sessionState: ContextualSessionState(continuityScore: 0.55, continuityConfidence: 0.70, patternConfidence: 0.6, dominantWorkflow: .writing, activeTrajectorySummary: "w", contributingSignals: [], updatedAt: t0, isStale: false),
			fused: writeFused,
			features: writeFeat,
			candidateActionIds: [],
			triggerType: nil,
			lastSourceTrigger: nil
		)
		let writeSynth = IntentSynthesisEngine.synthesize(writeReq, referenceTime: t0)
		assertCase(
			"writing_review_style",
			writeSynth.intents.contains { $0.type == .reviewSelectedText } || writeSynth.intents.contains { $0.type == .turnNotesIntoChecklist }
		)

		// 5) Repeated intent suppressed.
		let supEngine = DynamicIntentSuppressionEngine.shared
		supEngine.reset()
		supEngine.restoreDefaultProfileForSelfTest()
		let fusedCalm = fusedPacket(at: t0.addingTimeInterval(40), kinds: [.article], typing: .idle, conf: 0.70, fresh: 0.76, conflict: 0.25, stale: false, text: true, lines: 10)
		let wfResearchCalm = WorkflowInferenceResult(workflow: .research, confidence: 0.66, contributingSignals: ["r"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: fusedCalm.id)
		let repIntent = SynthesizedIntent(
			id: UUID(),
			type: .summarizeCurrentArticle,
			title: "S",
			description: "D",
			confidence: 0.66,
			workflow: .research,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.3,
			freshness: 0.8,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["c1"]
		)
		let repReq = IntentSynthesisRequest(
			workflowInference: wfResearchCalm,
			sessionState: nil,
			fused: fusedCalm,
			features: nil,
			candidateActionIds: [],
			triggerType: .selectedTextEligible,
			lastSourceTrigger: "selftest"
		)
		_ = supEngine.evaluate(rawIntents: [repIntent], request: repReq, referenceTime: t0)
		let rep2 = supEngine.evaluate(rawIntents: [repIntent], request: repReq, referenceTime: t0.addingTimeInterval(2))
		assertCase("repeated_suppressed", rep2.suppressed.contains { $0.reason == IntentSuppressionReason.repeatedIntent })

		// 6) Stale workflow suppresses mediocre intents.
		let medIntent = SynthesizedIntent(
			id: UUID(),
			type: .extractActionItems,
			title: "E",
			description: "D",
			confidence: 0.52,
			workflow: .research,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.35,
			freshness: 0.75,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["x"]
		)
		let wfStale = WorkflowInferenceResult(workflow: .research, confidence: 0.4, contributingSignals: ["s"], inferredAt: t0, isStale: true, summaryHint: nil, sourceFusedId: fusedCalm.id)
		let staleWfDec = supEngine.evaluate(rawIntents: [medIntent], request: IntentSynthesisRequest(workflowInference: wfStale, sessionState: nil, fused: fusedCalm, features: nil, candidateActionIds: [], triggerType: .selectedTextEligible, lastSourceTrigger: "selftest"), referenceTime: t0)
		assertCase("stale_workflow_ga_path", staleWfDec.allowed.isEmpty)

		// 7) Conflicting fusion weakens vs calm (deterministic ordering).
		let calmSynth = IntentSynthesisEngine.synthesize(dbgReq, referenceTime: t0)
		let hiFused = fusedPacket(at: t0.addingTimeInterval(50), kinds: [.terminal, .editor], typing: .burst, conf: 0.72, fresh: 0.78, conflict: 0.88, stale: false, text: true, lines: 14)
		let hiReq = IntentSynthesisRequest(
			workflowInference: dbgReq.workflowInference,
			sessionState: dbgReq.sessionState,
			fused: hiFused,
			features: dbgFeat,
			candidateActionIds: dbgReq.candidateActionIds,
			triggerType: dbgReq.triggerType,
			lastSourceTrigger: nil
		)
		let hiSynth = IntentSynthesisEngine.synthesize(hiReq, referenceTime: t0)
		assertCase("conflict_weakens", hiSynth.topConfidence < calmSynth.topConfidence - 1e-6)

		// 8) Burst + weak intent suppressed.
		supEngine.reset()
		let fusedBurst = fusedPacket(at: t0.addingTimeInterval(60), kinds: [.terminal, .editor], typing: .burst, conf: 0.72, fresh: 0.78, conflict: 0.30, stale: false, text: true, lines: 10)
		let sessStrong = ContextualSessionState(continuityScore: 0.55, continuityConfidence: 0.64, patternConfidence: 0.5, dominantWorkflow: .debugging, activeTrajectorySummary: "d", contributingSignals: [], updatedAt: t0, isStale: false)
		let weakRev = SynthesizedIntent(
			id: UUID(),
			type: .reviewSelectedText,
			title: "R",
			description: "D",
			confidence: 0.58,
			workflow: .writing,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.4,
			freshness: 0.75,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["w"]
		)
		let burstWeak = supEngine.evaluate(
			rawIntents: [weakRev],
			request: IntentSynthesisRequest(workflowInference: wfResearchCalm, sessionState: sessStrong, fused: fusedBurst, features: nil, candidateActionIds: [], triggerType: .selectedTextEligible, lastSourceTrigger: "selftest"),
			referenceTime: t0
		)
		assertCase("burst_weak", burstWeak.suppressed.contains { $0.reason == IntentSuppressionReason.activeInteractionBurst })

		// 9) Manual invocation does not imply OCR; explicit OCR path still offers Analyze Screen.
		var manualCtx = ContextModel()
		manualCtx.lastSourceTrigger = .manualTriggerRequested
		let manualPacket = TriggerEngine().evaluate(manualCtx)
		assertCase("manual_has_analyze", manualPacket?.candidateActions.contains(ScreenAnalyzeAction.analyzeScreenId) == true)
		assertCase("manual_no_ocr_flag", !manualCtx.screenOCRAvailable)
		var ocrCtx = ContextModel()
		ocrCtx.lastSourceTrigger = .screenOCRCompleted
		ocrCtx.screenCaptureAvailable = true
		ocrCtx.screenOCRAvailable = true
		ocrCtx.screenOCRTextLength = 100
		let ocrPacket = TriggerEngine().evaluate(ocrCtx)
		assertCase("ocr_has_analyze", ocrPacket?.candidateActions.contains(ScreenAnalyzeAction.analyzeScreenId) == true)

		// 10) Manual without analyze_screen candidate → no explainScreenContext intent.
		let manualNoAnalyzeFused = fusedPacket(at: t0.addingTimeInterval(70), kinds: [.editor], typing: .idle, conf: 0.68, fresh: 0.74, conflict: 0.28, stale: false, text: true, lines: 8)
		let manualSynthReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceResult(workflow: .editing, confidence: 0.65, contributingSignals: ["e"], inferredAt: t0, isStale: false, summaryHint: nil, sourceFusedId: manualNoAnalyzeFused.id),
			sessionState: nil,
			fused: manualNoAnalyzeFused,
			features: dbgFeat,
			candidateActionIds: ["summarize_text"],
			triggerType: .manualInvocation,
			lastSourceTrigger: "manual"
		)
		let manualSynth = IntentSynthesisEngine.synthesize(manualSynthReq, referenceTime: t0)
		assertCase("manual_no_screen_intent", !manualSynth.intents.contains { $0.type == .explainScreenContext })

		// 11) Explicit analyze candidate may add screen intent (metadata-only).
		let analyzeSynthReq = IntentSynthesisRequest(
			workflowInference: manualSynthReq.workflowInference,
			sessionState: nil,
			fused: manualNoAnalyzeFused,
			features: dbgFeat,
			candidateActionIds: ["summarize_text", ScreenAnalyzeAction.analyzeScreenId],
			triggerType: .manualInvocation,
			lastSourceTrigger: "manual"
		)
		let analyzeSynth = IntentSynthesisEngine.synthesize(analyzeSynthReq, referenceTime: t0)
		assertCase("analyze_candidate_screen_intent", analyzeSynth.intents.contains { $0.type == .explainScreenContext })

		// 12) Blocked unsafe action hidden from preview rows.
		var badProf = GeneratedActionSafetyProfile.profile(for: [.explain])
		badProf.usesShell = true
		let blockedAct = GeneratedAction(
			id: UUID(),
			title: "Blocked",
			description: "Metadata-only blocked row.",
			intentType: .explainLikelyError,
			confidence: 0.7,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			primitives: [.explain],
			interruptionCost: 0.4,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["t"],
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: false,
			safetyProfile: badProf,
			explainabilitySummary: "intent_type=explain|primitives=explain",
			source: .selfTest,
			structuredExplainability: nil
		)
		let disp = DynamicActionDisplayBuilder.build(actions: [blockedAct], plans: [], workflow: nil, session: nil)
		assertCase("blocked_not_preview", !disp.previewItems.contains { $0.title == blockedAct.title })
		assertCase("blocked_debug_line", disp.blockedSkippedTotal >= 1)

		// 13) Workflow-aware ranking: strong selection still favors explain in debugging-shaped fused context.
		let rankT0 = t0.addingTimeInterval(120)
		let mem = RedundancyMemory()
		let lifecycle = FloatingSuggestionLifecycle()
		let profile = ContentSimilarityProfile.make(from: "phase15_rank_smoke")
		let rankPacket = TriggerPacket(
			triggerType: .selectedTextEligible,
			reason: "phase15_tuning",
			candidateActions: ["summarize_text", "explain_text", "rewrite_text"],
			createdAt: rankT0
		)
		let codeFeatures = ContextFeatures(
			textLength: 400, wordCount: 40, sentenceCount: 4, punctuationDensity: 0.05,
			hasQuestion: false, isLikelyCode: true, isLikelyLog: true, lineCount: 12,
			averageLineLength: 33, repetitionScore: 0.1
		)
		let fusedRank = fusedPacket(at: rankT0, kinds: [.terminal, .editor], typing: .burst, conf: 0.72, fresh: 0.78, conflict: 0.32, stale: false, text: true, lines: 12)
		CanonicalContextState.shared.clear()
		CanonicalContextState.shared.update(fusedRank)
		WorkflowInferenceEngine.shared.reset()
		WorkflowInferenceEngine.shared.recordAppBundle("com.phase15.ide", at: rankT0)
		WorkflowInferenceEngine.shared.evaluate(referenceTime: rankT0)
		ContextualSessionTracker.shared.reset()
		ContextualSessionTracker.shared.recordSample(
			inference: WorkflowInferenceEngine.shared.latestResult(),
			fused: CanonicalContextState.shared.current(),
			activeBundle: "com.phase15.ide",
			referenceTime: rankT0
		)
		let rankReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceEngine.shared.latestResult(),
			sessionState: ContextualSessionTracker.shared.currentState(),
			fused: CanonicalContextState.shared.current(),
			features: codeFeatures,
			candidateActionIds: rankPacket.candidateActions,
			triggerType: rankPacket.triggerType,
			lastSourceTrigger: "selectedTextChanged"
		)
		IntentSynthesisEngine.shared.reset()
		IntentSynthesisEngine.shared.record(rankReq, referenceTime: rankT0)
		GeneratedActionEngine.shared.reset()
		GeneratedActionEngine.shared.record(from: IntentSynthesisEngine.shared.latestResult()?.intents ?? [], referenceTime: rankT0)
		var rankCtx = ContextModel()
		rankCtx.selectedTextAvailable = true
		rankCtx.selectedTextLength = TriggerEngine.selectedTextMinCharacterCount + 20
		let dbgBaseRank = [
			ActionRelevanceScore(actionId: "summarize_text", score: 0.68, reason: "phase15"),
			ActionRelevanceScore(actionId: "explain_text", score: 0.66, reason: "phase15"),
			ActionRelevanceScore(actionId: "rewrite_text", score: 0.55, reason: "phase15")
		]
		let rankRes = WorkflowAwareProposalRanker.adjust(
			baseRelevance: dbgBaseRank,
			packet: rankPacket,
			context: rankCtx,
			contextType: .code,
			features: codeFeatures,
			profile: profile,
			redundancyMemory: mem,
			lifecycle: lifecycle,
			typing: nil,
			pointer: nil,
			reasoningPrimary: nil
		)
		let rankTop = ProposalRanker.rank(relevance: rankRes.adjustedScores, reasoningPrimary: nil)?.primaryActionId
		assertCase("rank_strong_sel_explain", rankTop == "explain_text")

		assertCase("dynamic_intent_debug_summary", DynamicIntentDebugSummaryBuilder.runSelfTest())

		let allPreview = DynamicActionDisplayBuilder.build(actions: GeneratedActionEngine.shared.latestActions(), plans: GeneratedActionEngine.shared.currentPlans(), workflow: nil, session: nil)
		assertCase("preview_non_exec", allPreview.previewItems.allSatisfy { !$0.isExecutable && $0.isPreviewOnly })

		print("[Phase15Tuning] checked reason=no_execution_paths")

		let ok = failures.isEmpty
		print("[Phase15Tuning] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}
