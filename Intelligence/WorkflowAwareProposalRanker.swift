import Foundation

enum WorkflowProposalReasonCode: String, Hashable, Sendable, CaseIterable {
	case noWorkflowSignal = "no_workflow_signal"
	case weakSessionFallback = "weak_session"
	case boostedExplainDebugging = "boosted_explain_debugging"
	case boostedSummarizeResearch = "boosted_summarize_research"
	case boostedRewriteWritingReview = "boosted_rewrite_writing_review"
	case boostedExplainWritingCode = "boosted_explain_writing_code"
	case interruptionDampen = "interruption_dampen"
	case recentRejectionDownrank = "recent_rejection_downrank"
	case manualPermissive = "manual_permissive"
	case generatedPrimitiveBoost = "generated_primitive_boost"
}

enum WorkflowPrimaryRecommendation: String, Equatable, Sendable, Codable {
	case staticAction = "static_action"
	case generatedAction = "generated_action"
	case none = "none"
}

struct WorkflowProposalAdjustment: Equatable, Sendable {
	let scoreDeltasByActionId: [String: Double]
	let reasonCodes: [WorkflowProposalReasonCode]
}

struct WorkflowAwareProposalRankingResult: Equatable, Sendable {
	let adjustedScores: [ActionRelevanceScore]
	let rankedGeneratedActionIds: [String]
	let primaryCategory: WorkflowPrimaryRecommendation
	let suggestedStaticPrimary: String?
	let confidence: Double
	let interruptionCost: Double
	let reasonCodes: [WorkflowProposalReasonCode]
	let adjustment: WorkflowProposalAdjustment
}

/// Conservative workflow/session/intent-aware adjustments on top of rich-adjusted relevance scores.
enum WorkflowAwareProposalRanker {
	private static let minGeneratedInfluenceConfidence: Double = 0.45
	private static let minSessionContinuity: Double = 0.38
	private static let logThrottleSeconds: TimeInterval = 2.3
	private static var lastLogSignature: String?
	private static var lastLogAt: Date?

	@MainActor
	static func adjust(
		baseRelevance: [ActionRelevanceScore],
		packet: TriggerPacket,
		context: ContextModel,
		contextType: ContextType,
		features: ContextFeatures,
		profile: ContentSimilarityProfile,
		redundancyMemory: RedundancyMemory,
		lifecycle: FloatingSuggestionLifecycle,
		typing: TypingActivityContext?,
		pointer: PointerActivityContext?,
		reasoningPrimary: String?
	) -> WorkflowAwareProposalRankingResult {
		if packet.triggerType == .manualInvocation {
			return manualPassthrough(base: baseRelevance)
		}

		let wf = WorkflowInferenceEngine.shared.latestResult()
		let session = ContextualSessionTracker.shared.currentState()
		let intentResult = IntentSynthesisEngine.shared.latestResult()
		let generatedActions = GeneratedActionEngine.shared.latestActions().filter {
			!$0.isStale && $0.confidence >= minGeneratedInfluenceConfidence
		}

		let strongSelected = context.selectedTextAvailable
			&& context.selectedTextLength >= TriggerEngine.selectedTextMinCharacterCount
			&& packet.triggerType == .selectedTextEligible

		let interruption = interruptionCost01(typing: typing, pointer: pointer)

		let wfType = wf?.workflow ?? .unknown
		let wfConf = wf.map { min(1.0, max(0.0, $0.confidence)) } ?? 0.0
		let sessionCont = session.map { min(1.0, max(0.0, $0.continuityConfidence)) } ?? 0.0
		if wfType == .unknown || (wfConf < 0.22 && sessionCont < minSessionContinuity) {
			return weakFallback(
				base: baseRelevance,
				interruption: interruption,
				generated: generatedActions,
				intentResult: intentResult,
				workflowLabel: wfType.rawValue,
				topIntentLabel: intentResult?.topIntentType?.rawValue ?? "none",
				packet: packet,
				profile: profile,
				redundancy: redundancyMemory,
				lifecycle: lifecycle,
				strongSelected: strongSelected
			)
		}

		var deltas: [String: Double] = [:]
		var codes: [WorkflowProposalReasonCode] = []

		let sessionBoost = 0.82 + 0.18 * sessionCont
		let wfBoost = 0.75 + 0.25 * wfConf

		let freshIntents = (intentResult?.intents ?? []).filter { !$0.isStale && $0.confidence >= 0.42 }
		let topIntent = freshIntents.max(by: { $0.confidence < $1.confidence })

		applyIntentWorkflowBoosts(
			wfType: wfType,
			topIntent: topIntent,
			contextType: contextType,
			sessionBoost: sessionBoost,
			wfBoost: wfBoost,
			deltas: &deltas,
			codes: &codes
		)

		applyGeneratedPrimitiveBoosts(actions: generatedActions, contextType: contextType, deltas: &deltas, codes: &codes)

		applyRedundancyDownrank(
			packet: packet,
			profile: profile,
			redundancy: redundancyMemory,
			lifecycle: lifecycle,
			deltas: &deltas,
			codes: &codes,
			strongSelected: strongSelected
		)

		var merged = applyDeltas(base: baseRelevance, deltas: deltas, strongSelected: strongSelected)
		let m = interruptionMultiplier(interruption: interruption)
		if m < 0.985 {
			merged = merged.map { ActionRelevanceScore(actionId: $0.actionId, score: min(1.0, max(0.0, $0.score * m)), reason: $0.reason) }
			codes.append(.interruptionDampen)
		}

		let rankedGen = rankGeneratedMetadata(generatedActions)
		let topStatic = merged.max(by: { $0.score < $1.score })
		let primaryCat = primaryCategory(
			generated: generatedActions,
			sessionCont: sessionCont,
			wfType: wfType
		)

		let result = WorkflowAwareProposalRankingResult(
			adjustedScores: merged,
			rankedGeneratedActionIds: rankedGen,
			primaryCategory: primaryCat,
			suggestedStaticPrimary: topStatic?.actionId,
			confidence: min(1.0, max(0.0, topStatic?.score ?? 0)),
			interruptionCost: interruption,
			reasonCodes: uniqueCodes(codes),
			adjustment: WorkflowProposalAdjustment(scoreDeltasByActionId: deltas, reasonCodes: uniqueCodes(codes))
		)
		logOutcome(result: result, workflow: wfType.rawValue, topIntent: topIntent?.type.rawValue)
		return result
	}

	// MARK: - Internals

	@MainActor
	private static func manualPassthrough(base: [ActionRelevanceScore]) -> WorkflowAwareProposalRankingResult {
		let top = base.max(by: { $0.score < $1.score })
		let r = WorkflowAwareProposalRankingResult(
			adjustedScores: base,
			rankedGeneratedActionIds: [],
			primaryCategory: .staticAction,
			suggestedStaticPrimary: top?.actionId,
			confidence: top?.score ?? 0,
			interruptionCost: 0,
			reasonCodes: [.manualPermissive],
			adjustment: WorkflowProposalAdjustment(scoreDeltasByActionId: [:], reasonCodes: [.manualPermissive])
		)
		logOutcome(result: r, workflow: "manual", topIntent: "n/a")
		return r
	}

	@MainActor
	private static func weakFallback(
		base: [ActionRelevanceScore],
		interruption: Double,
		generated: [GeneratedAction],
		intentResult: IntentSynthesisResult?,
		workflowLabel: String,
		topIntentLabel: String,
		packet: TriggerPacket,
		profile: ContentSimilarityProfile,
		redundancy: RedundancyMemory,
		lifecycle: FloatingSuggestionLifecycle,
		strongSelected: Bool
	) -> WorkflowAwareProposalRankingResult {
		var deltas: [String: Double] = [:]
		var c: [WorkflowProposalReasonCode] = [.noWorkflowSignal, .weakSessionFallback]
		applyRedundancyDownrank(
			packet: packet,
			profile: profile,
			redundancy: redundancy,
			lifecycle: lifecycle,
			deltas: &deltas,
			codes: &c,
			strongSelected: strongSelected
		)
		var merged = applyDeltas(base: base, deltas: deltas, strongSelected: strongSelected)
		let m = interruptionMultiplier(interruption: interruption)
		if m < 0.985 {
			merged = merged.map { ActionRelevanceScore(actionId: $0.actionId, score: min(1.0, max(0.0, $0.score * m)), reason: $0.reason) }
			c.append(.interruptionDampen)
		}
		let top = merged.max(by: { $0.score < $1.score })
		let r = WorkflowAwareProposalRankingResult(
			adjustedScores: merged,
			rankedGeneratedActionIds: rankGeneratedMetadata(generated),
			primaryCategory: .none,
			suggestedStaticPrimary: top?.actionId,
			confidence: top?.score ?? 0,
			interruptionCost: interruption,
			reasonCodes: uniqueCodes(c),
			adjustment: WorkflowProposalAdjustment(scoreDeltasByActionId: deltas, reasonCodes: uniqueCodes(c))
		)
		logOutcome(result: r, workflow: workflowLabel, topIntent: topIntentLabel)
		return r
	}

	private static func interruptionMultiplier(interruption: Double) -> Double {
		1.0 - min(0.18, 0.12 * max(0.0, min(1.0, interruption)))
	}

	private static func applyIntentWorkflowBoosts(
		wfType: InferredWorkflow,
		topIntent: SynthesizedIntent?,
		contextType: ContextType,
		sessionBoost: Double,
		wfBoost: Double,
		deltas: inout [String: Double],
		codes: inout [WorkflowProposalReasonCode]
	) {
		guard let intent = topIntent else { return }
		let ic = min(1.0, max(0.0, intent.confidence))

		switch (wfType, intent.type) {
		case (.debugging, .explainLikelyError), (.debugging, .identifyPossibleBugSource):
			addDelta(&deltas, "explain_text", 0.085 * ic * sessionBoost * wfBoost)
			codes.append(.boostedExplainDebugging)
		case (.research, .summarizeCurrentArticle), (.browsing, .summarizeCurrentArticle):
			// Keep margin above `ProposalRanker`’s 0.05 tie band vs typical explain_text bases.
			addDelta(&deltas, "summarize_text", 0.14 * ic * sessionBoost * wfBoost)
			codes.append(.boostedSummarizeResearch)
		case (.writing, .reviewSelectedText), (.writing, .turnNotesIntoChecklist):
			if contextType == .code || contextType == .errorLog {
				addDelta(&deltas, "explain_text", 0.035 * ic * sessionBoost * wfBoost)
				codes.append(.boostedExplainWritingCode)
			} else {
				addDelta(&deltas, "rewrite_text", 0.045 * ic * sessionBoost * wfBoost)
				codes.append(.boostedRewriteWritingReview)
			}
		default:
			break
		}
	}

	private static func applyGeneratedPrimitiveBoosts(
		actions: [GeneratedAction],
		contextType: ContextType,
		deltas: inout [String: Double],
		codes: inout [WorkflowProposalReasonCode]
	) {
		for a in actions {
			for p in a.primitives {
				guard let sid = mapPrimitiveToStaticId(p, contextType: contextType) else { continue }
				addDelta(&deltas, sid, 0.032 * a.confidence * (0.88 + 0.12 * a.workflowRelevance))
				codes.append(.generatedPrimitiveBoost)
			}
		}
	}

	/// Maps to nearest existing static action id, or `nil` when unsupported for static ranking (metadata-only path still lists GA ids).
	fileprivate static func mapPrimitiveToStaticId(_ p: GeneratedActionPrimitive, contextType: ContextType) -> String? {
		switch p {
		case .explain:
			return "explain_text"
		case .summarize:
			return "summarize_text"
		case .rewrite, .draft, .review, .checklist:
			if contextType == .code || contextType == .errorLog { return "explain_text" }
			return "rewrite_text"
		case .compare, .classify, .extract, .structure:
			return nil
		}
	}

	@MainActor
	private static func applyRedundancyDownrank(
		packet: TriggerPacket,
		profile: ContentSimilarityProfile,
		redundancy: RedundancyMemory,
		lifecycle: FloatingSuggestionLifecycle,
		deltas: inout [String: Double],
		codes: inout [WorkflowProposalReasonCode],
		strongSelected: Bool
	) {
		let summarizeKey = lifecycle.exactKey(
			triggerType: packet.triggerType,
			primaryActionId: "summarize_text",
			profile: profile
		)
		let sumAdj = redundancy.adjustment(for: summarizeKey, actionId: "summarize_text")
		if sumAdj.scoreDelta <= -0.14 {
			addDelta(&deltas, "summarize_text", strongSelected ? -0.03 : -0.07)
			addDelta(&deltas, "rewrite_text", -0.04)
			codes.append(.recentRejectionDownrank)
		}
	}

	private static func addDelta(_ deltas: inout [String: Double], _ id: String, _ d: Double) {
		deltas[id, default: 0] += d
	}

	fileprivate static func applyDeltas(base: [ActionRelevanceScore], deltas: [String: Double], strongSelected: Bool) -> [ActionRelevanceScore] {
		base.map { s in
			var v = s.score + (deltas[s.actionId] ?? 0)
			if strongSelected, (s.actionId == "explain_text" || s.actionId == "summarize_text") {
				v = max(v, s.score - 0.01)
			}
			v = min(1.0, max(0.0, v))
			let tag = (deltas[s.actionId] ?? 0) != 0 ? "\(s.reason)+wf" : s.reason
			return ActionRelevanceScore(actionId: s.actionId, score: v, reason: tag)
		}
	}

	private static func rankGeneratedMetadata(_ actions: [GeneratedAction]) -> [String] {
		actions
			.filter { !$0.isStale && $0.confidence >= minGeneratedInfluenceConfidence }
			.sorted { $0.confidence > $1.confidence }
			.map { "ga:\($0.id.uuidString)" }
	}

	private static func primaryCategory(
		generated: [GeneratedAction],
		sessionCont: Double,
		wfType: InferredWorkflow
	) -> WorkflowPrimaryRecommendation {
		let unsupportedLead = generated.contains { ga in
			ga.confidence >= 0.58 && sessionCont >= 0.55 && ga.primitives.allSatisfy { mapPrimitiveToStaticId($0, contextType: .random) == nil }
		}
		if unsupportedLead { return .generatedAction }
		if wfType != .unknown { return .staticAction }
		return .none
	}

	private static func interruptionCost01(typing: TypingActivityContext?, pointer: PointerActivityContext?) -> Double {
		let ts = typing?.typingState
		let ti = typing?.burstIntensity
		let ps = pointer?.pointerState
		let mi = pointer?.movementBurstIntensity
		let ci = pointer?.clickBurstIntensity
		var c = 0.0
		if ts == .burst || ti == .high { c += 0.42 }
		if ps == .burst || mi == .high || ci == .high { c += 0.38 }
		if typing?.isTypingActive == true, ts == .active || ts == .started { c += 0.12 }
		return min(1.0, c)
	}

	private static func uniqueCodes(_ c: [WorkflowProposalReasonCode]) -> [WorkflowProposalReasonCode] {
		var seen = Set<WorkflowProposalReasonCode>()
		var out: [WorkflowProposalReasonCode] = []
		for x in c where seen.insert(x).inserted {
			out.append(x)
		}
		return out
	}

	private static func logOutcome(result: WorkflowAwareProposalRankingResult, workflow: String, topIntent: String?) {
		let primary = result.suggestedStaticPrimary ?? "none"
		let ti = topIntent ?? "none"
		let conf = String(format: "%.2f", result.confidence)
		let sig = "\(primary)|\(workflow)|\(ti)|\(result.primaryCategory.rawValue)"
		let now = Date()
		if lastLogSignature == sig, let t = lastLogAt, now.timeIntervalSince(t) < logThrottleSeconds {
			return
		}
		lastLogSignature = sig
		lastLogAt = now

		if result.reasonCodes.contains(.manualPermissive) {
			print("[WorkflowProposalRank] kept reason=manual_permissive workflow=manual")
			return
		}
		if result.reasonCodes.contains(.recentRejectionDownrank) {
			print("[WorkflowProposalRank] downranked reason=recent_rejection workflow=\(workflow)")
		}
		if result.reasonCodes.contains(.weakSessionFallback) {
			print("[WorkflowProposalRank] fallback reason=weak_session workflow=\(workflow)")
		} else {
			print("[WorkflowProposalRank] adjusted primary=\(primary) workflow=\(workflow) reason=\(result.reasonCodes.map(\.rawValue).sorted().joined(separator: ","))")
		}

		if result.primaryCategory == .generatedAction, let firstGen = result.rankedGeneratedActionIds.first {
			print("[WorkflowProposalRank] generated_top intent=\(ti) confidence=\(conf) id=\(firstGen)")
		}
		print("[WorkflowProposalRank] kept reason=non_executable category=\(result.primaryCategory.rawValue)")
	}
}

// MARK: - DEBUG self-test

extension WorkflowAwareProposalRanker {
	@MainActor
	static func runSelfTest() -> Bool {
		print("[WorkflowProposalRank] selftest starting")
		var failures: [String] = []
		let t0 = Date(timeIntervalSince1970: 2_050_000_000)
		let mem = RedundancyMemory()
		let lifecycle = FloatingSuggestionLifecycle()
		let profile = ContentSimilarityProfile.make(from: "workflow_rank_selftest")

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func fusedDebug(at: Date) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: at,
				primarySource: .selectedText,
				availableSources: [.activeApp, .visualDescriptor],
				staleSources: [],
				appName: "T",
				bundleIdentifier: "t.bundle",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: true,
				textLength: 400,
				lineCount: 12,
				hasSelectedText: true,
				hasClipboardText: false,
				hasOCRText: false,
				hasAXText: false,
				hasWindowSnapshot: true,
				hasVisualDescriptor: true,
				hasTypingActivity: true,
				hasPointerActivity: false,
				visualKinds: [.terminal, .editor],
				uiStructureHints: [],
				typingState: .burst,
				pointerState: .idle,
				confidence: 0.72,
				freshnessScore: 0.78,
				conflictScore: 0.32,
				isStale: false,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["wf_rank_selftest"],
				debugSummaryMetadata: ["wfRankSelfTest": "1"]
			)
		}

		func fusedResearch(at: Date) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: at,
				primarySource: .selectedText,
				availableSources: [.activeApp, .visualDescriptor],
				staleSources: [],
				appName: "T",
				bundleIdentifier: "t.bundle",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: true,
				textLength: 500,
				lineCount: 16,
				hasSelectedText: true,
				hasClipboardText: false,
				hasOCRText: false,
				hasAXText: false,
				hasWindowSnapshot: true,
				hasVisualDescriptor: true,
				hasTypingActivity: true,
				hasPointerActivity: false,
				visualKinds: [.browser, .article],
				uiStructureHints: [],
				typingState: .idle,
				pointerState: .idle,
				confidence: 0.68,
				freshnessScore: 0.80,
				conflictScore: 0.22,
				isStale: false,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["wf_rank_selftest"],
				debugSummaryMetadata: ["wfRankSelfTest": "1"]
			)
		}

		let packet = TriggerPacket(
			triggerType: .selectedTextEligible,
			reason: "selftest",
			candidateActions: ["summarize_text", "explain_text", "rewrite_text"],
			createdAt: t0
		)

		let codeFeatures = ContextFeatures(
			textLength: 400, wordCount: 40, sentenceCount: 4, punctuationDensity: 0.05,
			hasQuestion: false, isLikelyCode: true, isLikelyLog: true, lineCount: 12,
			averageLineLength: 33, repetitionScore: 0.1
		)
		let articleFeatures = ContextFeatures(
			textLength: 500, wordCount: 90, sentenceCount: 8, punctuationDensity: 0.04,
			hasQuestion: false, isLikelyCode: false, isLikelyLog: false, lineCount: 14,
			averageLineLength: 36, repetitionScore: 0.08
		)
		let notesFeatures = ContextFeatures(
			textLength: 300, wordCount: 60, sentenceCount: 5, punctuationDensity: 0.03,
			hasQuestion: false, isLikelyCode: false, isLikelyLog: false, lineCount: 6,
			averageLineLength: 48, repetitionScore: 0.05
		)

		func runCase(
			fused: FusedContextPacket,
			features: ContextFeatures,
			ctxType: ContextType,
			base: [ActionRelevanceScore],
			ctx: ContextModel
		) -> WorkflowAwareProposalRankingResult {
			CanonicalContextState.shared.clear()
			CanonicalContextState.shared.update(fused)
			WorkflowInferenceEngine.shared.reset()
			WorkflowInferenceEngine.shared.recordAppBundle("com.selftest.ide", at: t0)
			WorkflowInferenceEngine.shared.evaluate(referenceTime: t0)
			ContextualSessionTracker.shared.reset()
			ContextualSessionTracker.shared.recordSample(
				inference: WorkflowInferenceEngine.shared.latestResult(),
				fused: CanonicalContextState.shared.current(),
				activeBundle: "com.selftest.ide",
				referenceTime: t0
			)
			let req = IntentSynthesisRequest(
				workflowInference: WorkflowInferenceEngine.shared.latestResult(),
				sessionState: ContextualSessionTracker.shared.currentState(),
				fused: CanonicalContextState.shared.current(),
				features: features,
				candidateActionIds: packet.candidateActions,
				triggerType: packet.triggerType,
				lastSourceTrigger: "selectedTextChanged"
			)
			IntentSynthesisEngine.shared.reset()
			IntentSynthesisEngine.shared.record(req, referenceTime: t0)
			GeneratedActionEngine.shared.reset()
			GeneratedActionEngine.shared.record(from: IntentSynthesisEngine.shared.latestResult()?.intents ?? [], referenceTime: t0)

			return WorkflowAwareProposalRanker.adjust(
				baseRelevance: base,
				packet: packet,
				context: ctx,
				contextType: ctxType,
				features: features,
				profile: profile,
				redundancyMemory: mem,
				lifecycle: lifecycle,
				typing: nil,
				pointer: nil,
				reasoningPrimary: nil
			)
		}

		var ctx = ContextModel()
		ctx.selectedTextAvailable = true
		ctx.selectedTextLength = TriggerEngine.selectedTextMinCharacterCount + 10

		// Debugging + explain intent → explain_text should win over slightly higher summarize base.
		let dbgBase = [
			ActionRelevanceScore(actionId: "summarize_text", score: 0.68, reason: "t"),
			ActionRelevanceScore(actionId: "explain_text", score: 0.66, reason: "t"),
			ActionRelevanceScore(actionId: "rewrite_text", score: 0.55, reason: "t")
		]
		let dbgRes = runCase(fused: fusedDebug(at: t0), features: codeFeatures, ctxType: .code, base: dbgBase, ctx: ctx)
		let dbgTop = ProposalRanker.rank(relevance: dbgRes.adjustedScores, reasoningPrimary: nil)?.primaryActionId
		assertCase("debugging_explain_first", dbgTop == "explain_text")

		// Research + summarize intent → summarize_text first
		let resBase = [
			ActionRelevanceScore(actionId: "explain_text", score: 0.67, reason: "t"),
			ActionRelevanceScore(actionId: "summarize_text", score: 0.64, reason: "t"),
			ActionRelevanceScore(actionId: "rewrite_text", score: 0.55, reason: "t")
		]
		let resRes = runCase(fused: fusedResearch(at: t0.addingTimeInterval(20)), features: articleFeatures, ctxType: .article, base: resBase, ctx: ctx)
		let resTop = ProposalRanker.rank(relevance: resRes.adjustedScores, reasoningPrimary: nil)?.primaryActionId
		assertCase("research_summarize_first", resTop == "summarize_text")

		// Writing + review intent: conservative rewrite boost (notes, not code)
		let writingFused = fusedResearch(at: t0.addingTimeInterval(40))
		let writingBase = [
			ActionRelevanceScore(actionId: "rewrite_text", score: 0.60, reason: "t"),
			ActionRelevanceScore(actionId: "explain_text", score: 0.62, reason: "t"),
			ActionRelevanceScore(actionId: "summarize_text", score: 0.58, reason: "t")
		]
		// Force writing workflow: article + active typing
		let wfWritingFused = FusedContextPacket(
			id: UUID(),
			createdAt: t0.addingTimeInterval(41),
			primarySource: .selectedText,
			availableSources: [.activeApp, .visualDescriptor],
			staleSources: [],
			appName: "T",
			bundleIdentifier: "t.bundle",
			windowTitleAvailable: false,
			primaryTextSource: .selectedText,
			textAvailability: true,
			textLength: 420,
			lineCount: 10,
			hasSelectedText: true,
			hasClipboardText: false,
			hasOCRText: false,
			hasAXText: false,
			hasWindowSnapshot: true,
			hasVisualDescriptor: true,
			hasTypingActivity: true,
			hasPointerActivity: false,
			visualKinds: [.article],
			uiStructureHints: [],
			typingState: .active,
			pointerState: .idle,
			confidence: 0.70,
			freshnessScore: 0.76,
			conflictScore: 0.24,
			isStale: false,
			suppressedSources: [],
			supportingSources: [],
			arbitrationReasons: ["wf_rank_selftest"],
			debugSummaryMetadata: ["wfRankSelfTest": "1"]
		)
		let writingReqFeatures = notesFeatures
		let writingRes = runCase(fused: wfWritingFused, features: writingReqFeatures, ctxType: .notes, base: writingBase, ctx: ctx)
		let wrRewrite = writingRes.adjustedScores.first(where: { $0.actionId == "rewrite_text" })?.score ?? 0
		assertCase("writing_review_conservative", wrRewrite > 0.60 + 0.005)

		// Unknown workflow: clear inference by stale empty context
		IntentSynthesisEngine.shared.reset()
		GeneratedActionEngine.shared.reset()
		WorkflowInferenceEngine.shared.reset()
		CanonicalContextState.shared.clear()
		let staleFused = FusedContextPacket(
			id: UUID(),
			createdAt: t0,
			primarySource: .selectedText,
			availableSources: [.activeApp],
			staleSources: [],
			appName: "T",
			bundleIdentifier: "t.bundle",
			windowTitleAvailable: false,
			primaryTextSource: .selectedText,
			textAvailability: false,
			textLength: 0,
			lineCount: 0,
			hasSelectedText: false,
			hasClipboardText: false,
			hasOCRText: false,
			hasAXText: false,
			hasWindowSnapshot: false,
			hasVisualDescriptor: false,
			hasTypingActivity: false,
			hasPointerActivity: false,
			visualKinds: [],
			uiStructureHints: [],
			typingState: nil,
			pointerState: nil,
			confidence: 0.3,
			freshnessScore: 0.1,
			conflictScore: 0.2,
			isStale: true,
			suppressedSources: [],
			supportingSources: [],
			arbitrationReasons: ["wf_rank_selftest"],
			debugSummaryMetadata: ["wfRankSelfTest": "1"]
		)
		CanonicalContextState.shared.update(staleFused)
		WorkflowInferenceEngine.shared.evaluate(referenceTime: t0)
		let unkBase = [
			ActionRelevanceScore(actionId: "summarize_text", score: 0.62, reason: "t"),
			ActionRelevanceScore(actionId: "explain_text", score: 0.61, reason: "t")
		]
		let unkReq = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceEngine.shared.latestResult(),
			sessionState: nil,
			fused: CanonicalContextState.shared.current(),
			features: articleFeatures,
			candidateActionIds: packet.candidateActions,
			triggerType: packet.triggerType,
			lastSourceTrigger: nil
		)
		IntentSynthesisEngine.shared.record(unkReq, referenceTime: t0)
		let unkRes = WorkflowAwareProposalRanker.adjust(
			baseRelevance: unkBase,
			packet: packet,
			context: ctx,
			contextType: .article,
			features: articleFeatures,
			profile: profile,
			redundancyMemory: mem,
			lifecycle: lifecycle,
			typing: nil,
			pointer: nil,
			reasoningPrimary: nil
		)
		let unkById = Dictionary(uniqueKeysWithValues: unkRes.adjustedScores.map { ($0.actionId, $0.score) })
		assertCase("unknown_weak_unchanged_order", unkBase.allSatisfy { abs((unkById[$0.actionId] ?? 0) - $0.score) < 0.02 })

		// Recent rejection downrank summarize family
		let keySum = lifecycle.exactKey(triggerType: packet.triggerType, primaryActionId: "summarize_text", profile: profile)
		mem.record(event: .manuallyDismissed, key: keySum, actionId: "summarize_text", now: t0)
		mem.record(event: .manuallyDismissed, key: keySum, actionId: "summarize_text", now: t0.addingTimeInterval(1))
		let downBase = [
			ActionRelevanceScore(actionId: "summarize_text", score: 0.72, reason: "t"),
			ActionRelevanceScore(actionId: "explain_text", score: 0.60, reason: "t")
		]
		// Without strong selection, redundancy delta is not clamped by the explain/summarize floor.
		var ctxWeakSel = ctx
		ctxWeakSel.selectedTextAvailable = false
		ctxWeakSel.selectedTextLength = 0
		let downRes = WorkflowAwareProposalRanker.adjust(
			baseRelevance: downBase,
			packet: packet,
			context: ctxWeakSel,
			contextType: .article,
			features: articleFeatures,
			profile: profile,
			redundancyMemory: mem,
			lifecycle: lifecycle,
			typing: nil,
			pointer: nil,
			reasoningPrimary: nil
		)
		let sumSc = downRes.adjustedScores.first(where: { $0.actionId == "summarize_text" })?.score ?? 0
		assertCase("rejection_downrank", sumSc < downBase[0].score - 0.02)
		assertCase("rejection_reason", downRes.reasonCodes.contains(.recentRejectionDownrank))

		// Manual invocation permissive
		let manPacket = TriggerPacket(
			triggerType: .manualInvocation,
			reason: "selftest",
			candidateActions: ["summarize_text", "explain_text"],
			createdAt: t0
		)
		let manRes = WorkflowAwareProposalRanker.adjust(
			baseRelevance: dbgBase,
			packet: manPacket,
			context: ctx,
			contextType: .article,
			features: articleFeatures,
			profile: profile,
			redundancyMemory: mem,
			lifecycle: lifecycle,
			typing: nil,
			pointer: nil,
			reasoningPrimary: nil
		)
		assertCase("manual_permissive", manRes.adjustedScores == dbgBase && manRes.reasonCodes.contains(.manualPermissive))

		// Unsupported primitive mapping
		assertCase("extract_maps_nil", mapPrimitiveToStaticId(.extract, contextType: .article) == nil)
		assertCase("explain_maps", mapPrimitiveToStaticId(.explain, contextType: .article) == "explain_text")

		// High interruption reduces scores but preserves ordering keys (unknown workflow path).
		WorkflowInferenceEngine.shared.reset()
		IntentSynthesisEngine.shared.reset()
		GeneratedActionEngine.shared.reset()
		CanonicalContextState.shared.clear()
		WorkflowInferenceEngine.shared.evaluate(referenceTime: t0)

		let burstTyping = TypingActivityContext(
			id: UUID(),
			updatedAt: t0,
			appName: nil,
			bundleIdentifier: nil,
			isTypingActive: true,
			typingState: .burst,
			recentEventCount: 6,
			burstIntensity: .high,
			sessionDuration: 12,
			idleDuration: 0,
			estimatedEditingActivity: 0.82
		)
		let hiRes = WorkflowAwareProposalRanker.adjust(
			baseRelevance: dbgBase,
			packet: packet,
			context: ctx,
			contextType: .code,
			features: codeFeatures,
			profile: profile,
			redundancyMemory: mem,
			lifecycle: lifecycle,
			typing: burstTyping,
			pointer: nil,
			reasoningPrimary: nil
		)
		assertCase("interruption_has_three", hiRes.adjustedScores.count == 3)
		assertCase("interruption_dampen_flag", hiRes.reasonCodes.contains(.interruptionDampen))

		CanonicalContextState.shared.clear()
		WorkflowInferenceEngine.shared.reset()
		IntentSynthesisEngine.shared.reset()
		GeneratedActionEngine.shared.reset()

		let ok = failures.isEmpty
		print("[WorkflowProposalRank] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}
