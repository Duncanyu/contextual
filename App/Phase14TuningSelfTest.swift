import Foundation

/// DEBUG-only Phase 14 tuning regression checks (metadata-only; no capture, no AI).
enum Phase14TuningSelfTest {
	static func run() -> Bool {
		print("[Phase14Tuning] selftest starting")
		var failures: [String] = []

		// 1) Manual invocation packet offers Analyze Screen without relying on OCR in the model.
		var manualCtx = ContextModel()
		manualCtx.lastSourceTrigger = .manualTriggerRequested
		let manualPacket = TriggerEngine().evaluate(manualCtx)
		if manualPacket?.candidateActions.contains(ScreenAnalyzeAction.analyzeScreenId) != true {
			failures.append("manual_missing_analyze_screen")
		}
		if manualCtx.screenOCRAvailable {
			failures.append("manual_should_not_imply_ocr")
		}

		// 2) Post-OCR trigger still surfaces analyze_screen.
		var ocrCtx = ContextModel()
		ocrCtx.lastSourceTrigger = .screenOCRCompleted
		ocrCtx.screenCaptureAvailable = true
		ocrCtx.screenOCRAvailable = true
		ocrCtx.screenOCRTextLength = 120
		let ocrPacket = TriggerEngine().evaluate(ocrCtx)
		if ocrPacket?.candidateActions.contains(ScreenAnalyzeAction.analyzeScreenId) != true {
			failures.append("ocr_ready_missing_analyze_screen")
		}

		// 3) Eligibility: manual assistant keeps analyze_screen.
		let manualEligible = ContextAwareActionEligibility.evaluate(
			currentCandidateActionIds: ["summarize_text", "explain_text", "rewrite_text", ScreenAnalyzeAction.analyzeScreenId],
			triggerType: .manualInvocation,
			context: manualCtx,
			contextType: .code,
			features: FeatureExtractor.extract(from: "func example() -> Int { 42 }"),
			fused: nil
		)
		if !manualEligible.eligibleActionIds.contains(ScreenAnalyzeAction.analyzeScreenId) {
			failures.append("eligibility_dropped_manual_analyze")
		}

		// 4) Stale OCR must not keep analyze_screen eligible after unrelated context triggers.
		var staleCtx = ContextModel()
		staleCtx.lastSourceTrigger = .activeAppChanged
		staleCtx.screenCaptureAvailable = true
		staleCtx.screenOCRAvailable = true
		staleCtx.screenOCRTextLength = 400
		let staleEligible = ContextAwareActionEligibility.evaluate(
			currentCandidateActionIds: ["summarize_text", ScreenAnalyzeAction.analyzeScreenId],
			triggerType: .manualInvocation,
			context: staleCtx,
			contextType: .code,
			features: FeatureExtractor.extract(from: "x"),
			fused: nil
		)
		if staleEligible.eligibleActionIds.contains(ScreenAnalyzeAction.analyzeScreenId) {
			failures.append("eligibility_stale_ocr_leaked_analyze")
		}

		// 5) Fresh selection should not lose explain entirely under article-like fused tilt.
		let baseScores: [ActionRelevanceScore] = [
			ActionRelevanceScore(actionId: "summarize_text", score: 0.70, reason: "base"),
			ActionRelevanceScore(actionId: "explain_text", score: 0.70, reason: "base"),
			ActionRelevanceScore(actionId: "rewrite_text", score: 0.70, reason: "base")
		]
		var selCtx = ContextModel()
		selCtx.selectedTextAvailable = true
		selCtx.selectedTextLength = 120
		let fusedArticle = fusedPacketStub(kinds: [.article, .browser])
		let articleAdj = RichContextProposalAdjuster.adjust(
			relevance: baseScores,
			context: selCtx,
			fused: fusedArticle,
			contextType: .article,
			features: FeatureExtractor.extract(from: String(repeating: "word ", count: 80)),
			isManualInvocation: false
		)
		if !articleAdj.adjustedScores.contains(where: { $0.actionId == "explain_text" && $0.score >= 0.68 }) {
			failures.append("adjuster_strong_sel_lost_explain")
		}

		// 6) Analyze Screen model instructions (anti-speculation).
		let preamble = IntelligenceActionRunner.analyzeScreenSafetyPreamble
		if !preamble.localizedCaseInsensitiveContains("verbatim")
			|| !preamble.localizedCaseInsensitiveContains("metadata-only")
			|| !preamble.localizedCaseInsensitiveContains("Never mention workflow hints") {
			failures.append("analyze_prompt_preamble_weak")
		}

		let built = RichAnalyzeScreenPromptBuilder.build(
			context: ContextModel(),
			ocrText: "Visible line one\nVisible line two\n",
			ocrLineCount: 2,
			fused: fusedArticle,
			refreshMeta: ["axFragments": "3", "axTextLen": "40", "visualKinds": "article"]
		)
		if !built.input.contains("Evidence contract") {
			failures.append("builder_missing_evidence_contract")
		}

		// 6.5) Conflicting visual hints + weak OCR: prompt must not contain workflow claims.
		let weakBuilt = RichAnalyzeScreenPromptBuilder.build(
			context: ContextModel(),
			ocrText: "YouTube\nSkip ads\n",
			ocrLineCount: 2,
			fused: fusedArticle,
			refreshMeta: ["axFragments": "0", "axTextLen": "0", "visualKinds": "browser,editor,terminal,dialog"]
		)
		if !weakBuilt.input.contains("uncertaintyMode: on")
			|| !weakBuilt.input.contains("visualKindsArbitrated: browser")
			|| weakBuilt.input.contains("likelyWorkflow=terminal_debugging")
			|| weakBuilt.input.contains("likelyWorkflow=code_editing")
		{
			failures.append("builder_conflict_should_not_infer_workflow")
		}

		// 7) Adaptive sampling: explicit Analyze Screen refresh still allows expensive work under typing burst;
		// generic manual reason follows automatic throttling.
		let sampler = AdaptiveContextSampler.shared
		sampler.reset()
		let typingBurst = Self.makeTypingBurst()
		let pointerIdle = Self.makePointerIdle()
		let t0 = Date(timeIntervalSince1970: 2_000_000_000)
		let explicitManual = sampler.evaluate(
			AdaptiveSamplingRequest(
				trigger: .manual,
				requestedSources: [.axWindowContent],
				currentCanonicalContext: nil,
				typingActivity: typingBurst,
				pointerActivity: pointerIdle,
				isActionExecuting: false,
				currentConfidence: 0.80,
				workflowKey: "phase14-explicit",
				reason: "analyze_screen",
				allowExpensiveSources: true
			),
			referenceTime: t0
		)
		if !explicitManual.allowedSources.contains(.axWindowContent) {
			failures.append("adaptive_explicit_analyze_blocked")
		}
		let genericManual = sampler.evaluate(
			AdaptiveSamplingRequest(
				trigger: .manual,
				requestedSources: [.axWindowContent],
				currentCanonicalContext: nil,
				typingActivity: typingBurst,
				pointerActivity: pointerIdle,
				isActionExecuting: false,
				currentConfidence: 0.80,
				workflowKey: "phase14-generic",
				reason: "selftest",
				allowExpensiveSources: true
			),
			referenceTime: t0
		)
		if !genericManual.deferredSources.contains(.axWindowContent) {
			failures.append("adaptive_generic_manual_should_defer")
		}

		let ok = failures.isEmpty
		print("[Phase14Tuning] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		if ok {
			print("[Phase14Tuning] tuned reason=phase14_tuning_selftest_pass")
		}
		return ok
	}

	private static func fusedPacketStub(kinds: [VisualUIKind]) -> FusedContextPacket {
		FusedContextPacket(
			id: UUID(),
			createdAt: Date(),
			primarySource: .selectedText,
			availableSources: [.activeApp, .selectedText, .visualDescriptor],
			staleSources: [],
			appName: "TestApp",
			bundleIdentifier: "test.bundle",
			windowTitleAvailable: false,
			primaryTextSource: .selectedText,
			textAvailability: true,
			textLength: 120,
			lineCount: 6,
			hasSelectedText: true,
			hasClipboardText: false,
			hasOCRText: false,
			hasAXText: false,
			hasWindowSnapshot: false,
			hasVisualDescriptor: true,
			hasTypingActivity: false,
			hasPointerActivity: false,
			visualKinds: kinds,
			uiStructureHints: [],
			typingState: nil,
			pointerState: nil,
			confidence: 0.78,
			freshnessScore: 0.80,
			conflictScore: 0.08,
			isStale: false,
			suppressedSources: [],
			supportingSources: [],
			arbitrationReasons: ["phase14_tuning_selftest"],
			debugSummaryMetadata: ["phase14": "1"]
		)
	}

	private static func makeTypingBurst() -> TypingActivityContext {
		TypingActivityContext(
			id: UUID(),
			updatedAt: Date(),
			appName: "TestApp",
			bundleIdentifier: "com.selftest",
			isTypingActive: true,
			typingState: .burst,
			recentEventCount: 20,
			burstIntensity: .high,
			sessionDuration: 3,
			idleDuration: 0.05,
			estimatedEditingActivity: 0.9
		)
	}

	private static func makePointerIdle() -> PointerActivityContext {
		PointerActivityContext(
			id: UUID(),
			updatedAt: Date(),
			appName: "TestApp",
			bundleIdentifier: "com.selftest",
			isPointerActive: false,
			pointerState: .idle,
			recentMoveEventCount: 0,
			recentClickEventCount: 0,
			movementBurstIntensity: .none,
			clickBurstIntensity: .none,
			sessionDuration: 1,
			idleDuration: 5,
			estimatedFocusIntensity: 0.0
		)
	}
}
