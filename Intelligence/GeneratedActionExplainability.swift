import Foundation

// MARK: - Builder

enum GeneratedActionExplanationBuilder {
	private static let maxShortSummary = 118
	private static let maxLine = 88
	private static let maxSignals = 14

	/// Builds from existing metadata only. Overrides are for tests; otherwise uses canonical/session/suppression singletons.
	static func buildForAction(
		action: GeneratedAction,
		safety: GeneratedActionSafetyDecision,
		referenceTime: Date,
		fusedOverride: FusedContextPacket? = nil,
		sessionOverride: ContextualSessionState? = nil,
		suppressionOverride: IntentSuppressionDecision? = nil,
		intentFreshnessOverride: Double? = nil
	) -> GeneratedActionExplanation {
		let fused = fusedOverride ?? CanonicalContextState.shared.current()
		let session = sessionOverride ?? ContextualSessionTracker.shared.currentState()
		let suppression = suppressionOverride ?? IntentSynthesisEngine.shared.latestResult()?.suppression
		let infl = influenceSummary(action: action, fused: fused, session: session)
		let wfReason = workflowReasoning(intent: action.intentType, workflow: action.workflow)
		let conf = confidenceSummary(confidence: action.confidence, safety: safety)
		let wfSum = workflowSummaryLine(workflow: action.workflow, intent: action.intentType)
		let reqCtx = requiredContextLine(action.requiredContext)
		let intr = interruptionLine(action.interruptionCost, fused: fused)
		let fresh = freshnessLine(fused: fused, intentFreshness: intentFreshnessOverride)
		let safe = safetyLine(safety: safety, profile: action.safetyProfile)
		let signals = buildSignals(
			action: action,
			infl: infl,
			fused: fused,
			session: session,
			suppression: suppression,
			safety: safety
		)
		let short = clamp(
			"\(intentShortLabel(action.intentType))|wf=\(action.workflow.rawValue)|\(confBand(action.confidence))|\(safety.safetyLevel.rawValue)",
			maxShortSummary
		)
		let stale = action.isStale || (fused?.isStale ?? false)
		let reasons = templateReasons(safety: safety, stale: stale)

		return GeneratedActionExplanation(
			shortSummary: short,
			workflowSummary: clamp(wfSum, maxLine),
			confidenceSummary: clamp(conf, maxLine),
			influencingSignals: signals,
			requiredContextSummary: clamp(reqCtx, maxLine),
			interruptionSummary: clamp(intr, maxLine),
			freshnessSummary: clamp(fresh, maxLine),
			safetySummary: clamp(safe, maxLine),
			sourceReasonCodes: Array(action.sourceReasonCodes.prefix(24)),
			generatedAt: referenceTime,
			isStale: stale,
			workflowReasoning: wfReason,
			influence: infl,
			templateReasons: reasons
		)
	}

	static func buildForPlan(
		plan: GeneratedActionPlan,
		planSafety: GeneratedActionSafetyDecision,
		actionSafety: GeneratedActionSafetyDecision,
		referenceTime: Date,
		fusedOverride: FusedContextPacket? = nil,
		sessionOverride: ContextualSessionState? = nil,
		suppressionOverride: IntentSuppressionDecision? = nil
	) -> GeneratedActionExplanation {
		let pseudoAction = GeneratedAction(
			id: plan.generatedActionId,
			title: "plan",
			description: "plan",
			intentType: plan.intentType,
			confidence: plan.confidence,
			workflow: plan.workflow,
			requiredContext: plan.requiredContext,
			primitives: plan.steps.map(\.primitive),
			interruptionCost: 0.35,
			workflowRelevance: 0.5,
			sourceIntentId: plan.generatedActionId,
			sourceReasonCodes: plan.sourceReasonCodes,
			createdAt: plan.createdAt,
			expiresAt: plan.expiresAt,
			isStale: plan.isStale,
			safetyProfile: plan.safetyProfile,
			explainabilitySummary: plan.explanation,
			source: .selfTest,
			structuredExplainability: nil
		)
		let merged = mergeSafety(action: actionSafety, plan: planSafety)
		let base = buildForAction(
			action: pseudoAction,
			safety: merged,
			referenceTime: referenceTime,
			fusedOverride: fusedOverride,
			sessionOverride: sessionOverride,
			suppressionOverride: suppressionOverride,
			intentFreshnessOverride: nil
		)
		let extra = "composition:\(plan.compositionRule.rawValue)"
		let mergedSignals = (base.influencingSignals + [extra]).prefix(maxSignals).map { String($0) }
		var tpl = Set(base.templateReasons)
		tpl.formUnion([.primitiveComposition, .workflowSignal])
		let planTpl = tpl.sorted { $0.rawValue < $1.rawValue }
		let planShort = clamp(
			"plan|\(plan.compositionRule.rawValue)|steps=\(plan.steps.count)|\(base.shortSummary)",
			maxShortSummary
		)
		return GeneratedActionExplanation(
			shortSummary: planShort,
			workflowSummary: base.workflowSummary,
			confidenceSummary: base.confidenceSummary,
			influencingSignals: mergedSignals,
			requiredContextSummary: base.requiredContextSummary,
			interruptionSummary: base.interruptionSummary,
			freshnessSummary: base.freshnessSummary,
			safetySummary: clamp(base.safetySummary + "|plan_safety=\(planSafety.safetyLevel.rawValue)", maxLine),
			sourceReasonCodes: base.sourceReasonCodes,
			generatedAt: referenceTime,
			isStale: plan.isStale || base.isStale,
			workflowReasoning: base.workflowReasoning,
			influence: base.influence,
			templateReasons: planTpl
		)
	}

	// MARK: - Logging (metadata-only)

	private static var lastLogSig: String?
	private static var lastLogAt: Date?

	static func logBuilt(actionId: UUID, confidence: Double, review: Bool, stale: Bool) {
		let sig = "\(actionId)|\(String(format: "%.2f", confidence))|\(review)|\(stale)"
		let now = Date()
		if lastLogSig == sig, let t = lastLogAt, now.timeIntervalSince(t) < 2.0 { return }
		lastLogSig = sig
		lastLogAt = now
		if stale {
			print("[GeneratedActionExplainability] stale action=\(actionId.uuidString)")
			return
		}
		if review {
			print("[GeneratedActionExplainability] review_required action=\(actionId.uuidString)")
			return
		}
		print("[GeneratedActionExplainability] built action=\(actionId.uuidString) confidence=\(String(format: "%.2f", confidence))")
	}

	// MARK: - Internals

	private static func mergeSafety(action: GeneratedActionSafetyDecision, plan: GeneratedActionSafetyDecision) -> GeneratedActionSafetyDecision {
		if plan.safetyLevel == .blocked || !plan.allowed { return plan }
		if action.safetyLevel == .blocked || !action.allowed { return action }
		if plan.safetyLevel == .reviewRequired || action.safetyLevel == .reviewRequired {
			let codes = Array(Set(action.reasonCodes + plan.reasonCodes)).sorted { $0.rawValue < $1.rawValue }
			return GeneratedActionSafetyDecision(
				allowed: true,
				safetyLevel: .reviewRequired,
				requiresUserReview: true,
				requiresExplicitApproval: action.requiresExplicitApproval || plan.requiresExplicitApproval,
				reasonCodes: codes,
				blockedCapabilities: [],
				reviewNotes: "plan_review_merge",
				canExecuteAutomatically: false
			)
		}
		return action
	}

	private static func influenceSummary(
		action: GeneratedAction,
		fused: FusedContextPacket?,
		session: ContextualSessionState?
	) -> GeneratedActionInfluenceSummary {
		let kinds = (fused?.visualKinds ?? []).map(\.rawValue).sorted().prefix(6).joined(separator: ",")
		let typing = fused?.typingState?.rawValue ?? "na"
		let pointing = fused?.pointerState?.rawValue ?? "na"
		let interaction = "typing=\(typing)|pointer=\(pointing)"
		let cont = session.map { bandContinuity($0.continuityConfidence) } ?? "session_na"
		let freshB = fused.map { bandFreshness($0.freshnessScore) } ?? "fusion_na"
		let mm = fused.map { bandConflict($0.conflictScore) } ?? "fusion_na"
		let surface = surfaceCategory(workflow: action.workflow, fused: fused)
		let prim = action.primitives.map(\.rawValue).sorted().joined(separator: "+")
		return GeneratedActionInfluenceSummary(
			workflowLabel: action.workflow.rawValue,
			visualCategoryCodes: clamp(kinds.isEmpty ? "visual_none" : kinds, 72),
			interactionStateCode: clamp(interaction, 64),
			sessionContinuityBand: cont,
			fusionFreshnessBand: freshB,
			multimodalAgreementBand: mm,
			proposalContinuityBand: "proposal_na",
			activeSurfaceCategory: surface,
			intentTypeCode: action.intentType.rawValue,
			primitiveCompositionCode: clamp(prim, 64)
		)
	}

	private static func workflowReasoning(intent: SynthesizedIntentType, workflow: InferredWorkflow) -> GeneratedActionWorkflowReasoning {
		let p: String
		switch (workflow, intent) {
		case (.debugging, .explainLikelyError), (.editing, .explainLikelyError):
			p = "wf_debug_explain"
		case (.research, .summarizeCurrentArticle), (.browsing, .summarizeCurrentArticle):
			p = "wf_read_summarize"
		case (.writing, .reviewSelectedText), (.writing, .draftReply):
			p = "wf_write_review"
		default:
			p = "wf_generic_intent"
		}
		let sec = "wf=\(workflow.rawValue)|intent=\(intent.rawValue)"
		return GeneratedActionWorkflowReasoning(primaryCode: p, secondaryCodes: clamp(sec, 96))
	}

	private static func workflowSummaryLine(workflow: InferredWorkflow, intent: SynthesizedIntentType) -> String {
		"workflow=\(workflow.rawValue);intent=\(intent.rawValue);non_executable"
	}

	private static func confidenceSummary(confidence: Double, safety: GeneratedActionSafetyDecision) -> String {
		let b = confBand(confidence)
		let edge = confidence < 0.52 ? "uncertainty_elevated" : "confidence_ok"
		return "confidence_band=\(b);safety=\(safety.safetyLevel.rawValue);\(edge)"
	}

	private static func requiredContextLine(_ ctx: [GeneratedActionRequiredContext]) -> String {
		let c = ctx.map(\.rawValue).sorted().prefix(6).joined(separator: ",")
		return "required_context=\(c.isEmpty ? "none" : c);metadata_only"
	}

	private static func interruptionLine(_ cost: Double, fused: FusedContextPacket?) -> String {
		let burst = (fused?.typingState == .burst) || (fused?.pointerState == .burst)
		let calm = cost < 0.38 && !burst
		if calm { return "interruption=low;defer_not_required" }
		if burst { return "interruption=elevated_burst;defer_friendly" }
		if cost >= 0.55 { return "interruption=high;calm_surfacing" }
		return "interruption=moderate;bounded"
	}

	private static func freshnessLine(fused: FusedContextPacket?, intentFreshness: Double?) -> String {
		if let f = fused {
			let b = bandFreshness(f.freshnessScore)
			let c = bandConflict(f.conflictScore)
			return "fusion_fresh=\(b);multimodal_agreement=\(c)"
		}
		if let i = intentFreshness {
			return "intent_freshness=\(bandFreshness(i))"
		}
		return "freshness=unknown;fusion_unavailable"
	}

	private static func safetyLine(safety: GeneratedActionSafetyDecision, profile: GeneratedActionSafetyProfile) -> String {
		let codes = safety.reasonCodes.map(\.rawValue).sorted().prefix(8).joined(separator: ",")
		let caps = safety.blockedCapabilities.map(\.rawValue).sorted().prefix(6).joined(separator: ",")
		let review = safety.requiresUserReview ? "review=yes" : "review=no"
		let auto = "auto_exec=false"
		let appr = profile.requiresUserApproval ? "approval=required" : "approval=optional"
		return "safety_level=\(safety.safetyLevel.rawValue);\(review);\(auto);\(appr);codes=\(codes.isEmpty ? "none" : codes);blocked_caps=\(caps.isEmpty ? "none" : caps)"
	}

	private static func buildSignals(
		action: GeneratedAction,
		infl: GeneratedActionInfluenceSummary,
		fused: FusedContextPacket?,
		session: ContextualSessionState?,
		suppression: IntentSuppressionDecision?,
		safety: GeneratedActionSafetyDecision
	) -> [String] {
		var s: [String] = [
			"workflow:\(infl.workflowLabel)",
			"visual:\(infl.visualCategoryCodes)",
			"interaction:\(infl.interactionStateCode)",
			"continuity:\(infl.sessionContinuityBand)",
			"fusion_fresh:\(infl.fusionFreshnessBand)",
			"multimodal:\(infl.multimodalAgreementBand)",
			"surface:\(infl.activeSurfaceCategory)",
			"intent:\(infl.intentTypeCode)",
			"primitives:\(infl.primitiveCompositionCode)",
			"safety:\(safety.safetyLevel.rawValue)"
		]
		if let sup = suppression, !sup.suppressed.isEmpty {
			let codes = sup.suppressed.prefix(3).map { "\($0.intentType.rawValue):\($0.reason.rawValue)" }.joined(separator: ";")
			s.append("suppression_nearby:\(clamp(codes, 80))")
		}
		return Array(s.prefix(maxSignals)).map { clamp($0, maxLine) }
	}

	private static func templateReasons(safety: GeneratedActionSafetyDecision, stale: Bool) -> [GeneratedActionExplanationReason] {
		var r: Set<GeneratedActionExplanationReason> = [.intentMapped, .workflowSignal, .confidenceBand, .primitiveComposition, .safetyEnvelope, .fusionQuality, .interactionLoad, .sessionContinuity]
		if stale { r.insert(.staleness) }
		if safety.requiresUserReview || safety.safetyLevel == .reviewRequired { r.insert(.reviewGate) }
		if safety.safetyLevel == .blocked { r.insert(.safetyEnvelope) }
		return r.sorted { $0.rawValue < $1.rawValue }
	}

	private static func intentShortLabel(_ t: SynthesizedIntentType) -> String {
		switch t {
		case .explainLikelyError: return "explain_error"
		case .summarizeCurrentArticle: return "summarize_article"
		case .draftReply: return "draft_reply"
		default: return t.rawValue
		}
	}

	private static func confBand(_ c: Double) -> String {
		if c >= 0.68 { return "high" }
		if c >= 0.52 { return "medium" }
		return "low"
	}

	private static func bandContinuity(_ c: Double) -> String {
		if c >= 0.62 { return "continuity_strong" }
		if c >= 0.42 { return "continuity_moderate" }
		return "continuity_weak"
	}

	private static func bandFreshness(_ f: Double) -> String {
		if f >= 0.72 { return "fresh_strong" }
		if f >= 0.45 { return "fresh_moderate" }
		return "fresh_low"
	}

	private static func bandConflict(_ c: Double) -> String {
		if c <= 0.30 { return "agreement_high" }
		if c <= 0.55 { return "agreement_moderate" }
		return "agreement_low"
	}

	private static func surfaceCategory(workflow: InferredWorkflow, fused: FusedContextPacket?) -> String {
		if let k = fused?.visualKinds, k.contains(.terminal) { return "surface_terminal" }
		if let k = fused?.visualKinds, k.contains(.browser) { return "surface_browser" }
		switch workflow {
		case .debugging, .editing: return "surface_dev"
		case .research, .browsing: return "surface_reading"
		case .writing: return "surface_writing"
		default: return "surface_general"
		}
	}

	private static func clamp(_ s: String, _ max: Int) -> String {
		guard s.count > max else { return s }
		return String(s.prefix(max))
	}
}

// MARK: - DEBUG self-test

extension GeneratedActionExplanationBuilder {
	static func runSelfTest() -> Bool {
		print("[GeneratedActionExplainability] selftest starting")
		var failures: [String] = []
		let t0 = Date(timeIntervalSince1970: 2_060_000_000)

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func fused(
			kinds: [VisualUIKind],
			typing: TypingState?,
			pointer: PointerState?,
			conf: Double,
			fresh: Double,
			conflict: Double,
			stale: Bool
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: t0,
				primarySource: .selectedText,
				availableSources: [.activeApp, .visualDescriptor],
				staleSources: [],
				appName: nil,
				bundleIdentifier: nil,
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: true,
				textLength: 80,
				lineCount: 6,
				hasSelectedText: true,
				hasClipboardText: false,
				hasOCRText: false,
				hasAXText: false,
				hasWindowSnapshot: true,
				hasVisualDescriptor: !kinds.isEmpty,
				hasTypingActivity: typing != nil,
				hasPointerActivity: pointer != nil,
				visualKinds: kinds,
				uiStructureHints: [],
				typingState: typing,
				pointerState: pointer,
				confidence: conf,
				freshnessScore: fresh,
				conflictScore: conflict,
				isStale: stale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["explainability_selftest"],
				debugSummaryMetadata: ["explainabilitySelfTest": "1"]
			)
		}

		func intent(
			_ type: SynthesizedIntentType,
			_ wf: InferredWorkflow,
			conf: Double,
			stale: Bool,
			interruption: Double = 0.42
		) -> SynthesizedIntent {
			SynthesizedIntent(
				id: UUID(),
				type: type,
				title: "T",
				description: "D",
				confidence: conf,
				workflow: wf,
				requiredContext: [.textSnippet, .fusedVisual],
				supportingSignals: ["st"],
				interruptionCost: interruption,
				freshness: 0.75,
				createdAt: t0,
				isStale: stale,
				sourceReasonCodes: ["rule_debugging_base"]
			)
		}

		let dbgFused = fused(kinds: [.terminal, .editor], typing: .idle, pointer: .idle, conf: 0.72, fresh: 0.78, conflict: 0.28, stale: false)
		let dbgIntent = intent(.explainLikelyError, .debugging, conf: 0.71, stale: false)
		var dbgAct: GeneratedAction?
		if case .produced(let a) = GeneratedActionFactory.materialize(from: dbgIntent, referenceTime: t0, source: .selfTest) {
			dbgAct = a
		} else {
			assertCase("dbg_materialize", false)
		}
		if let dbgAct {
			let dbgSafety = GeneratedActionSafetyPolicy.evaluate(action: dbgAct)
			let dbgExpl = buildForAction(action: dbgAct, safety: dbgSafety, referenceTime: t0, fusedOverride: dbgFused, sessionOverride: nil)
			assertCase("debugging_workflow_code", dbgExpl.workflowReasoning.primaryCode == "wf_debug_explain")
			assertCase("debugging_signals", dbgExpl.influence.visualCategoryCodes.contains("terminal") || dbgExpl.influence.visualCategoryCodes.contains("editor"))
		}

		let resFused = fused(kinds: [.article, .browser], typing: .idle, pointer: .idle, conf: 0.66, fresh: 0.8, conflict: 0.22, stale: false)
		let resIntent = intent(.summarizeCurrentArticle, .research, conf: 0.64, stale: false)
		var resAct: GeneratedAction?
		if case .produced(let a) = GeneratedActionFactory.materialize(from: resIntent, referenceTime: t0, source: .selfTest) {
			resAct = a
		} else {
			assertCase("res_materialize", false)
		}
		var resSafety: GeneratedActionSafetyDecision?
		var resExpl: GeneratedActionExplanation?
		if let resAct {
			let rs = GeneratedActionSafetyPolicy.evaluate(action: resAct)
			resSafety = rs
			let re = buildForAction(action: resAct, safety: rs, referenceTime: t0, fusedOverride: resFused)
			resExpl = re
			assertCase("summarize_reasoning", re.workflowReasoning.primaryCode == "wf_read_summarize")
		}

		let lowIntent = intent(.explainApiResponse, .research, conf: 0.46, stale: false)
		if case .produced(let lowAct) = GeneratedActionFactory.materialize(from: lowIntent, referenceTime: t0, source: .selfTest) {
			let lowSafety = GeneratedActionSafetyPolicy.evaluate(action: lowAct)
			let lowExpl = buildForAction(action: lowAct, safety: lowSafety, referenceTime: t0, fusedOverride: resFused)
			assertCase("low_conf_uncertainty", lowExpl.confidenceSummary.contains("low") || lowExpl.confidenceSummary.contains("uncertainty_elevated"))
		} else {
			assertCase("low_materialize", false)
		}

		let staleIntent = intent(.explainLikelyError, .debugging, conf: 0.8, stale: true)
		assertCase("stale_skip_no_action", GeneratedActionFactory.materialize(from: staleIntent, referenceTime: t0) == .skippedStale)

		if let dbgAct {
			let staleMarked = GeneratedAction(
				id: dbgAct.id,
				title: dbgAct.title,
				description: dbgAct.description,
				intentType: dbgAct.intentType,
				confidence: dbgAct.confidence,
				workflow: dbgAct.workflow,
				requiredContext: dbgAct.requiredContext,
				primitives: dbgAct.primitives,
				interruptionCost: dbgAct.interruptionCost,
				workflowRelevance: dbgAct.workflowRelevance,
				sourceIntentId: dbgAct.sourceIntentId,
				sourceReasonCodes: dbgAct.sourceReasonCodes,
				createdAt: dbgAct.createdAt,
				expiresAt: dbgAct.expiresAt,
				isStale: true,
				safetyProfile: dbgAct.safetyProfile,
				explainabilitySummary: dbgAct.explainabilitySummary,
				source: dbgAct.source,
				structuredExplainability: nil
			)
			let stSafe = GeneratedActionSafetyPolicy.evaluate(action: staleMarked)
			let stExpl = buildForAction(action: staleMarked, safety: stSafe, referenceTime: t0, fusedOverride: dbgFused)
			assertCase("stale_explain_flag", stExpl.isStale && stExpl.templateReasons.contains(.staleness))
		}

		let draftIntent = intent(.draftReply, .writing, conf: 0.72, stale: false, interruption: 0.5)
		if case .produced(let drAct) = GeneratedActionFactory.materialize(from: draftIntent, referenceTime: t0, source: .selfTest) {
			let drSafety = GeneratedActionSafetyPolicy.evaluate(action: drAct)
			let drExpl = buildForAction(action: drAct, safety: drSafety, referenceTime: t0, fusedOverride: dbgFused)
			assertCase("draft_review_expl", drExpl.safetySummary.contains("review=yes") || drSafety.requiresUserReview)
		} else {
			assertCase("draft_materialize", false)
		}

		var badProf = GeneratedActionSafetyProfile.profile(for: [.explain])
		badProf.usesShell = true
		let blockedAct = GeneratedAction(
			id: UUID(),
			title: "T",
			description: "D",
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
			explainabilitySummary: "intent_type=explain_likely_error|primitives=explain",
			source: .selfTest,
			structuredExplainability: nil
		)
		let blockedSafety = GeneratedActionSafetyPolicy.evaluate(action: blockedAct)
		let blockedExpl = buildForAction(action: blockedAct, safety: blockedSafety, referenceTime: t0, fusedOverride: dbgFused)
		assertCase("blocked_bounded", blockedExpl.shortSummary.count <= 200 && !blockedExpl.safetySummary.isEmpty)

		let hiConflictFused = fused(kinds: [.browser], typing: .idle, pointer: .idle, conf: 0.5, fresh: 0.55, conflict: 0.82, stale: false)
		if let dbgAct {
			let dbgSafety = GeneratedActionSafetyPolicy.evaluate(action: dbgAct)
			let mmExpl = buildForAction(action: dbgAct, safety: dbgSafety, referenceTime: t0, fusedOverride: hiConflictFused)
			assertCase("multimodal_influence", mmExpl.freshnessSummary.contains("agreement_low"))

			let burstFused = fused(kinds: [.editor], typing: .burst, pointer: .idle, conf: 0.7, fresh: 0.76, conflict: 0.3, stale: false)
			let intrExpl = buildForAction(action: dbgAct, safety: dbgSafety, referenceTime: t0, fusedOverride: burstFused)
			assertCase("interruption_burst", intrExpl.interruptionSummary.contains("burst") || intrExpl.interruptionSummary.contains("elevated"))

			let dbgExpl2 = buildForAction(action: dbgAct, safety: dbgSafety, referenceTime: t0, fusedOverride: dbgFused)
			assertCase("short_summary_bounded", dbgExpl2.shortSummary.count <= 200)
			let joined = dbgExpl2.influencingSignals.joined() + dbgExpl2.workflowSummary
			assertCase("no_raw_leak", !joined.contains("://") && !joined.contains("/Users"))
		}

		if let resAct, let resSafety, let resExpl {
			assertCase("required_ctx_meta_only", !resExpl.requiredContextSummary.lowercased().contains("http"))
			let safeLine = buildForAction(action: resAct, safety: resSafety, referenceTime: t0, fusedOverride: resFused).safetySummary
			assertCase("safety_reflects_policy", safeLine.contains(resSafety.safetyLevel.rawValue))
		}

		let seAct = GeneratedAction(
			id: UUID(),
			title: "T",
			description: "D",
			intentType: .summarizeCurrentArticle,
			confidence: 0.7,
			workflow: .research,
			requiredContext: [.textSnippet],
			primitives: [.summarize, .extract],
			interruptionCost: 0.4,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["st"],
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: false,
			safetyProfile: .profile(for: [.summarize, .extract]),
			explainabilitySummary: "selftest",
			source: .selfTest,
			structuredExplainability: nil
		)
		if case .accepted(let pl) = GeneratedActionPlanBuilder.build(from: seAct, referenceTime: t0) {
			let ps = GeneratedActionSafetyPolicy.evaluate(plan: pl)
			let asafe = GeneratedActionSafetyPolicy.evaluate(action: seAct)
			let pex = buildForPlan(plan: pl, planSafety: ps, actionSafety: asafe, referenceTime: t0, fusedOverride: resFused)
			assertCase("plan_has_explain", pex.shortSummary.hasPrefix("plan|"))
		} else {
			assertCase("plan_has_explain", false)
		}

		if let resAct, let resSafety {
			let nilExpl = buildForAction(action: resAct, safety: resSafety, referenceTime: t0, fusedOverride: nil, sessionOverride: nil)
			assertCase("missing_fusion_safe", !nilExpl.freshnessSummary.isEmpty)
		}

		let ok = failures.isEmpty
		print("[GeneratedActionExplainability] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}
