import Foundation

/// Inputs for one debug snapshot (tests may inject; production uses `captureFromSharedEngines()`).
struct DynamicIntentDebugPipelineInputs: Equatable, Sendable {
	let workflow: WorkflowInferenceResult?
	let session: ContextualSessionState?
	let synthesis: IntentSynthesisResult?
	let actions: [GeneratedAction]
	let plans: [GeneratedActionPlan]
	let ranking: WorkflowAwareProposalRankingResult?
	let suppressionOverride: IntentSuppressionDecision?

	init(
		workflow: WorkflowInferenceResult? = nil,
		session: ContextualSessionState? = nil,
		synthesis: IntentSynthesisResult? = nil,
		actions: [GeneratedAction] = [],
		plans: [GeneratedActionPlan] = [],
		ranking: WorkflowAwareProposalRankingResult? = nil,
		suppressionOverride: IntentSuppressionDecision? = nil
	) {
		self.workflow = workflow
		self.session = session
		self.synthesis = synthesis
		self.actions = actions
		self.plans = plans
		self.ranking = ranking
		self.suppressionOverride = suppressionOverride
	}

	static func captureFromSharedEngines() -> DynamicIntentDebugPipelineInputs {
		DynamicIntentDebugPipelineInputs(
			workflow: WorkflowInferenceEngine.shared.latestResult(),
			session: ContextualSessionTracker.shared.currentState(),
			synthesis: IntentSynthesisEngine.shared.latestResult(),
			actions: GeneratedActionEngine.shared.latestActions(),
			plans: GeneratedActionEngine.shared.currentPlans(),
			ranking: WorkflowAwareProposalRanker.latestRankingSnapshot(),
			suppressionOverride: nil
		)
	}
}

/// Metadata-only snapshot for internal dynamic-intent debug UI (no raw user content).
struct DynamicIntentDebugSummary: Equatable, Sendable {
	var workflowLine: String
	var sessionLine: String
	var intentLines: [String]
	var synthesisMetaLines: [String]
	var suppressionLines: [String]
	var actionLines: [String]
	var planLines: [String]
	var safetyLines: [String]
	var explainLines: [String]
	var rankingLine: String
	/// Metadata-only assistance category counts (non-blocked generated actions/plans only).
	var assistanceCategorySummaryLine: String
	/// Session-local generated preview interaction stats (T16.9); no raw content.
	var interactionSummaryLine: String
	/// Unified rich assistance ranking (T16.10); metadata-only; filled after preview rank pass.
	var richAssistanceRankLine: String
	/// Unified action ranking snapshot (T17.9); metadata-only; one-shot debug line.
	var unifiedRankingLine: String

	static let empty = DynamicIntentDebugSummary(
		workflowLine: "",
		sessionLine: "",
		intentLines: [],
		synthesisMetaLines: [],
		suppressionLines: [],
		actionLines: [],
		planLines: [],
		safetyLines: [],
		explainLines: [],
		rankingLine: "",
		assistanceCategorySummaryLine: "",
		interactionSummaryLine: "",
		richAssistanceRankLine: "",
		unifiedRankingLine: ""
	)

	var showsDynamicDebug: Bool {
		if !workflowLine.isEmpty { return true }
		if !sessionLine.isEmpty { return true }
		if !intentLines.isEmpty { return true }
		if !synthesisMetaLines.isEmpty { return true }
		if !suppressionLines.isEmpty { return true }
		if !actionLines.isEmpty { return true }
		if !planLines.isEmpty { return true }
		if !safetyLines.isEmpty { return true }
		if !explainLines.isEmpty { return true }
		if !rankingLine.isEmpty { return true }
		if !assistanceCategorySummaryLine.isEmpty { return true }
		if !interactionSummaryLine.isEmpty { return true }
		if !richAssistanceRankLine.isEmpty { return true }
		if !unifiedRankingLine.isEmpty { return true }
		return false
	}
}

extension DynamicIntentDebugSummary {
	func withRichAssistanceRankLine(_ line: String) -> DynamicIntentDebugSummary {
		var c = self
		c.richAssistanceRankLine = line
		return c
	}
}

enum DynamicIntentDebugSummaryBuilder {
	private static let maxIntentLines = 4
	private static let maxSuppressLines = 6
	private static let maxActionLines = 4
	private static let maxPlanLines = 3
	private static let maxSafetyLines = 8
	private static let maxExplainLines = 5
	private static let maxReasonCodes = 5

	static func build() -> DynamicIntentDebugSummary {
		build(inputs: .captureFromSharedEngines())
	}

	static func build(inputs: DynamicIntentDebugPipelineInputs) -> DynamicIntentDebugSummary {
		let wfLine: String
		if let w = inputs.workflow {
			var parts = ["Workflow: \(w.workflow.rawValue)", "conf \(confidenceBucket(w.confidence))"]
			if w.isStale { parts.append("inference_stale") }
			wfLine = parts.joined(separator: " · ")
		} else {
			wfLine = ""
		}

		let sesLine: String
		if let s = inputs.session {
			let stab = s.isStale ? "stale" : "stable"
			let cont = continuityBucket(s.continuityConfidence)
			sesLine = "Session: \(stab) · continuity \(cont) · dominant \(s.dominantWorkflow.rawValue)"
		} else {
			sesLine = ""
		}

		var intents: [String] = []
		if let syn = inputs.synthesis {
			for i in syn.intents.prefix(maxIntentLines) {
				let ic = confidenceBucket(i.confidence)
				let st = i.isStale ? "stale" : "fresh"
				intents.append("Intent: \(i.type.rawValue) · \(ic) · wf \(i.workflow.rawValue) · \(st)")
			}
		}

		var meta: [String] = []
		if let syn = inputs.synthesis {
			if let sr = syn.suppressedReason, !sr.isEmpty {
				meta.append("synthesis_gate=\(clamp(sr, 48))")
			}
			if let sk = syn.skippedReason, !sk.isEmpty {
				meta.append("synthesis_skip=\(clamp(sk, 48))")
			}
		}

		let sup = inputs.suppressionOverride ?? inputs.synthesis?.suppression ?? DynamicIntentSuppressionEngine.shared.latestDecisionSnapshot()
		var supLines: [String] = []
		if let s = sup {
			for e in s.suppressed.prefix(maxSuppressLines) {
				supLines.append("Suppressed: \(e.intentType.rawValue) · \(e.reason.rawValue)")
			}
			if !s.reasonCodes.isEmpty {
				let codes = s.reasonCodes.map(\.rawValue).sorted().prefix(maxReasonCodes).joined(separator: ",")
				supLines.append("Suppression codes: \(codes)")
			}
		}

		var actLines: [String] = []
		for a in inputs.actions.prefix(maxActionLines) {
			let sid = String(a.id.uuidString.prefix(8))
			let prim = a.primitives.map(\.rawValue).joined(separator: "+")
			let d = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(a)
			actLines.append(
				"GA \(sid) intent=\(a.intentType.rawValue) prim=\(clamp(prim, 40)) safety=\(safetyLabel(d.safetyLevel)) review=\(d.requiresUserReview ? "y" : "n") stale=\(a.isStale ? "y" : "n")"
			)
		}

		var plLines: [String] = []
		for p in inputs.plans.prefix(maxPlanLines) {
			let pid = String(p.id.uuidString.prefix(8))
			let steps = p.steps.map(\.primitive.rawValue).joined(separator: ">")
			let pd = GeneratedActionSafetyPolicy.evaluatePlanSnapshotForDebug(p)
			plLines.append(
				"Plan \(pid) rule=\(p.compositionRule.rawValue) steps=\(clamp(steps, 48)) safety=\(safetyLabel(pd.safetyLevel)) review=\(pd.requiresUserReview ? "y" : "n")"
			)
		}

		var safetyAgg: [String: Int] = [:]
		for a in inputs.actions.prefix(maxActionLines) {
			let d = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(a)
			let k = "action:" + safetyLabel(d.safetyLevel)
			safetyAgg[k, default: 0] += 1
		}
		for p in inputs.plans.prefix(maxPlanLines) {
			let d = GeneratedActionSafetyPolicy.evaluatePlanSnapshotForDebug(p)
			let k = "plan:" + safetyLabel(d.safetyLevel)
			safetyAgg[k, default: 0] += 1
		}
		var safeLines: [String] = []
		for (k, v) in safetyAgg.sorted(by: { $0.key < $1.key }).prefix(maxSafetyLines) {
			safeLines.append("\(k)=\(v)")
		}

		var expl: [String] = []
		for a in inputs.actions.prefix(2) {
			if let e = a.structuredExplainability {
				let s = clamp(e.shortSummary, 72)
				if !s.isEmpty {
					expl.append("Explain GA \(String(a.id.uuidString.prefix(8))): \(s)")
				}
			}
		}
		for p in inputs.plans.prefix(1) {
			if let e = p.structuredExplainability {
				let s = clamp(e.shortSummary, 72)
				if !s.isEmpty {
					expl.append("Explain plan \(String(p.id.uuidString.prefix(8))): \(s)")
				}
			}
		}
		if expl.count > maxExplainLines {
			expl = Array(expl.prefix(maxExplainLines))
		}

		var rankStr = ""
		if let r = inputs.ranking {
			let codes = r.reasonCodes.map(\.rawValue).sorted().prefix(maxReasonCodes).joined(separator: ",")
			let intr = interruptionBucket(r.interruptionCost)
			rankStr = "Ranking: primary=\(r.primaryCategory.rawValue) topStatic=\(r.suggestedStaticPrimary ?? "nil") intr=\(intr) codes=\(codes)"
			if !r.rankedGeneratedActionIds.isEmpty {
				let ids = r.rankedGeneratedActionIds.prefix(3).map { String($0.prefix(12)) }.joined(separator: ",")
				rankStr += " genIds=\(clamp(ids, 64))"
			}
		}

		let catSum = GeneratedAssistanceCategoryMapper.summaryForDebug(actions: inputs.actions, plans: inputs.plans)
		let assistLine: String
		if catSum.counts.isEmpty {
			assistLine = ""
		} else {
			assistLine = "Assistance categories top=\(catSum.topCategoryRaw ?? "none") \(catSum.formattedCounts)"
		}

		let interactionLine = GeneratedActionInteractionTracker.shared.debugSummaryLine()

		let unifiedLine: String = {
			let ranking = UnifiedActionRankingAdapter.buildDebugRanking(inputs: inputs)
			guard let top = ranking.rankedActions.first else { return "" }
			let src = top.action.sourceType.rawValue
			let score = String(format: "%.2f", top.components.finalScore)
			return "Unified rank: top=\(src) score=\(score) static=\(ranking.staticActionCount) gen=\(ranking.generatedActionCount) reuse=\(ranking.reusableActionCount) \(ranking.rankingReasonSummary)"
		}()

		return DynamicIntentDebugSummary(
			workflowLine: wfLine,
			sessionLine: sesLine,
			intentLines: intents,
			synthesisMetaLines: meta,
			suppressionLines: supLines,
			actionLines: actLines,
			planLines: plLines,
			safetyLines: safeLines,
			explainLines: expl,
			rankingLine: rankStr,
			assistanceCategorySummaryLine: assistLine,
			interactionSummaryLine: interactionLine,
			richAssistanceRankLine: "",
			unifiedRankingLine: unifiedLine
		)
	}

	private static func clamp(_ s: String, _ n: Int) -> String {
		guard s.count > n else { return s }
		return String(s.prefix(n))
	}

	private static func confidenceBucket(_ c: Double) -> String {
		if c >= 0.68 { return "high" }
		if c >= 0.52 { return "medium" }
		if c > 0 { return "low" }
		return "unknown"
	}

	private static func continuityBucket(_ c: Double) -> String {
		if c >= 0.62 { return "strong" }
		if c >= 0.42 { return "medium" }
		if c > 0 { return "weak" }
		return "unknown"
	}

	private static func interruptionBucket(_ c: Double) -> String {
		if c < 0.35 { return "low" }
		if c < 0.58 { return "medium" }
		return "high"
	}

	private static func safetyLabel(_ s: GeneratedActionSafetyLevel) -> String {
		switch s {
		case .safeReadOnly: return "safeReadOnly"
		case .reviewRequired: return "reviewRequired"
		case .blocked: return "blocked"
		}
	}
}

// MARK: - DEBUG self-test

extension DynamicIntentDebugSummaryBuilder {
	static func runSelfTest() -> Bool {
		print("[DynamicIntentDebugUI] selftest starting")
		var failures: [String] = []
		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let t0 = Date(timeIntervalSince1970: 2_050_000_000)
		let wf = WorkflowInferenceResult(
			workflow: .debugging,
			confidence: 0.81,
			contributingSignals: ["terminal_editor"],
			inferredAt: t0,
			isStale: false,
			summaryHint: nil,
			sourceFusedId: nil
		)
		let session = ContextualSessionState(
			continuityScore: 0.55,
			continuityConfidence: 0.5,
			patternConfidence: 0.62,
			dominantWorkflow: .debugging,
			activeTrajectorySummary: "debugging>debugging",
			contributingSignals: [.workflowStreak],
			updatedAt: t0,
			isStale: false
		)
		let intent = SynthesizedIntent(
			id: UUID(),
			type: .explainLikelyError,
			title: "Explain",
			description: "Desc",
			confidence: 0.82,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			supportingSignals: ["t"],
			interruptionCost: 0.3,
			freshness: 0.9,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["rule"]
		)
		let suppressedIntent = SynthesizedIntent(
			id: UUID(),
			type: .summarizeCurrentArticle,
			title: "Sum",
			description: "D",
			confidence: 0.71,
			workflow: .research,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.4,
			freshness: 0.8,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["r"]
		)
		let sup = IntentSuppressionDecision(
			rawIntents: [intent, suppressedIntent],
			allowed: [intent],
			suppressed: [IntentSuppressionEntry(intentType: .summarizeCurrentArticle, reason: .repeatedIntent)],
			reasonCodes: [.repeatedIntent]
		)
		let syn = IntentSynthesisResult(
			intents: [intent],
			suppressedReason: nil,
			skippedReason: "weak_evidence",
			synthesizedAt: t0,
			suppression: sup
		)

		guard case .produced(let ga) = GeneratedActionFactory.materialize(from: intent, referenceTime: t0, source: .selfTest) else {
			assertCase("materialize", false)
			let ok0 = failures.isEmpty
			print("[DynamicIntentDebugUI] selftest summary ok=\(ok0) detail=\(failures.joined(separator: ";"))")
			return ok0
		}
		let safeSnap = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(ga)
		let explain = GeneratedActionExplanationBuilder.buildForAction(action: ga, safety: safeSnap, referenceTime: t0, fusedOverride: nil)
		let gaWith = ga.withStructuredExplainability(explain)

		let step = GeneratedActionPlanStep(
			stepIndex: 0,
			primitive: .explain,
			purpose: "explain",
			inputRole: .sourceContext,
			outputRole: .explanation,
			dependsOnStepIndexes: [],
			confidence: 0.7,
			safetyNotes: "notes"
		)
		let plan = GeneratedActionPlan(
			id: UUID(),
			generatedActionId: gaWith.id,
			intentType: .explainLikelyError,
			workflow: .debugging,
			steps: [step],
			confidence: 0.7,
			requiredContext: [.textSnippet],
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: false,
			sourceReasonCodes: ["st"],
			safetyProfile: gaWith.safetyProfile,
			explanation: "meta",
			isExecutable: false,
			compositionRule: .singlePrimitive,
			structuredExplainability: explain
		)

		let ranking = WorkflowAwareProposalRankingResult(
			adjustedScores: [ActionRelevanceScore(actionId: "explain_text", score: 0.77, reason: "wf")],
			rankedGeneratedActionIds: [gaWith.id.uuidString],
			primaryCategory: .staticAction,
			suggestedStaticPrimary: "explain_text",
			confidence: 0.77,
			interruptionCost: 0.31,
			reasonCodes: [.boostedExplainDebugging, .generatedPrimitiveBoost],
			adjustment: WorkflowProposalAdjustment(scoreDeltasByActionId: ["explain_text": 0.05], reasonCodes: [.boostedExplainDebugging])
		)

		let full = build(inputs: DynamicIntentDebugPipelineInputs(
			workflow: wf,
			session: session,
			synthesis: syn,
			actions: [gaWith],
			plans: [plan],
			ranking: ranking,
			suppressionOverride: nil
		))

		assertCase("workflow", full.workflowLine.contains("debugging") && full.workflowLine.contains("high"))
		assertCase("session", full.sessionLine.contains("medium") && full.sessionLine.contains("stable"))
		assertCase("intents", full.intentLines.contains(where: { $0.contains("explain_likely_error") }))
		assertCase("suppressed_reason", full.suppressionLines.contains(where: { $0.contains("repeated_intent") || $0.contains("summarize_current_article") }))
		assertCase("actions", full.actionLines.contains(where: { $0.contains("GA ") && $0.contains("explain_likely_error") }))
		assertCase("plans", full.planLines.contains(where: { $0.contains("single_primitive") }))
		assertCase("safety_agg", !full.safetyLines.isEmpty)
		assertCase("explain", !full.explainLines.isEmpty)
		assertCase("ranking", full.rankingLine.contains("boosted_explain_debugging") || full.rankingLine.contains("generated_primitive_boost"))
		assertCase("unified_ranking", full.unifiedRankingLine.contains("Unified rank:"))
		assertCase("shows", full.showsDynamicDebug)
		assertCase("synthesis_meta", full.synthesisMetaLines.contains(where: { $0.contains("synthesis_skip") }))

		assertCase("assist_cat_line", !full.assistanceCategorySummaryLine.isEmpty)
		assertCase("interaction_line_safe", !full.interactionSummaryLine.contains("://"))
		let joined = full.workflowLine + full.sessionLine + full.intentLines.joined() + full.suppressionLines.joined() + full.actionLines.joined() + full.planLines.joined() + full.explainLines.joined() + full.rankingLine + full.assistanceCategorySummaryLine + full.interactionSummaryLine
		assertCase("no_url", !joined.contains("://"))
		assertCase("bounded_intents", full.intentLines.count <= 4)

		DynamicIntentSuppressionEngine.shared.reset()
		GeneratedActionInteractionTracker.shared.reset()
		let empty = build(inputs: DynamicIntentDebugPipelineInputs(
			workflow: nil,
			session: nil,
			synthesis: nil,
			actions: [],
			plans: [],
			ranking: nil,
			suppressionOverride: nil
		))
		assertCase("empty_hides", !empty.showsDynamicDebug)

		let ok = failures.isEmpty
		print("[DynamicIntentDebugUI] selftest summary ok=\(ok) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}
