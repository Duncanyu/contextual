import Foundation

/// Deterministic unified ranking across static, generated, reusable, and executable actions (T17.9).
enum UnifiedActionRanker {

	private static let snapshotLock = NSLock()
	private static var latestSnapshot: UnifiedActionRankingResult?

	/// Latest one-shot ranking snapshot (in-memory only; not streamed).
	static func latestRankingSnapshot() -> UnifiedActionRankingResult? {
		snapshotLock.lock()
		let value = latestSnapshot
		snapshotLock.unlock()
		return value
	}

	static func rank(
		actions: [UnifiedRankableAction],
		context: UnifiedActionRankingContext
	) -> UnifiedActionRankingResult {
		let started = Date()
		guard !actions.isEmpty else {
			let empty = UnifiedActionRankingResult.empty
			publishSnapshot(empty)
			return empty
		}

		var suppressedCount = 0
		var scored: [(RankedUnifiedAction, Bool)] = []
		scored.reserveCapacity(actions.count)

		for action in actions {
			let (components, explanations, suppressed) = score(action: action, context: context)
			if suppressed { suppressedCount += 1 }
			scored.append((
				RankedUnifiedAction(
					action: action,
					components: components,
					rankingExplanationCodes: explanations,
					rankIndex: 0
				),
				suppressed
			))
		}

		scored.sort { lhs, rhs in
			if lhs.0.components.finalScore != rhs.0.components.finalScore {
				return lhs.0.components.finalScore > rhs.0.components.finalScore
			}
			if lhs.0.action.sourceType != rhs.0.action.sourceType {
				return lhs.0.action.sourceType == .staticAction
			}
			return lhs.0.id < rhs.0.id
		}

		var ranked = scored.map(\.0)
		ranked = applyGeneratedCap(ranked, context: context)
		ranked = ranked.enumerated().map { index, item in
			RankedUnifiedAction(
				action: item.action,
				components: item.components,
				rankingExplanationCodes: item.rankingExplanationCodes,
				rankIndex: index
			)
		}

		let generatedCount = actions.filter(\.isGeneratedFamily).count
		let reusableCount = actions.filter { $0.sourceType == .reusableGenerated }.count
		let staticCount = actions.filter { $0.sourceType == .staticAction }.count
		let topConf = ranked.first?.action.confidence ?? 0
		let durationMs = Int(Date().timeIntervalSince(started) * 1000)

		let result = UnifiedActionRankingResult(
			rankedActions: ranked,
			rankingReasonSummary: summary(for: ranked, suppressed: suppressedCount),
			workflowSummary: "\(context.activeWorkflow.rawValue) cont=\(bucket(context.continuityScore))",
			topActionConfidence: topConf,
			generatedActionCount: generatedCount,
			reusableActionCount: reusableCount,
			staticActionCount: staticCount,
			warnings: buildWarnings(suppressed: suppressedCount, ranked: ranked),
			createdAt: context.referenceTime,
			consideredCount: actions.count,
			suppressedCount: suppressedCount,
			rankingDurationMs: durationMs
		)

		logRanking(result: result, context: context)
		return publishSnapshot(result)
	}

	// MARK: - Scoring

	private static func score(
		action: UnifiedRankableAction,
		context: UnifiedActionRankingContext
	) -> (UnifiedActionScoreComponents, [String], Bool) {
		var explanations: [String] = []

		let confidenceScore = action.confidence
		let usefulnessScore = action.usefulnessScore

		var workflowContinuityScore = 0.0
		if context.activeWorkflow != .unknown, action.workflowType == context.activeWorkflow {
			workflowContinuityScore += min(0.14, context.continuityScore * 0.2 * context.workflowConfidence)
			explanations.append("boosted_workflow_continuity")
		}
		workflowContinuityScore += workflowIntentBoost(action: action, context: context, explanations: &explanations)

		let interruptionPenalty = action.interruptionCost * 0.14
		if interruptionPenalty >= 0.05 {
			explanations.append("penalized_interruption_cost")
		}

		var executionComplexityPenalty = min(
			0.22,
			Double(action.executionComplexity) * 0.035 + action.estimatedExecutionTime / 100.0 * 0.06
		)
		if action.requiresVision || action.requiresOCR {
			executionComplexityPenalty += 0.05
		}
		if executionComplexityPenalty >= 0.08 {
			explanations.append("penalized_execution_complexity")
		}

		var reuseBoost = 0.0
		if action.isReusable || action.sourceType == .reusableGenerated {
			reuseBoost = min(0.14, action.reuseScore * 0.16)
			if action.recentSuccessRate >= 0.55 {
				explanations.append("boosted_reuse_success")
			}
			if let stale = action.metadata["staleFactor"], let factor = Double(stale), factor < 0.75 {
				reuseBoost *= factor
				explanations.append("stale_reusable_decay")
			}
		}

		let recentSuccessBoost = min(0.08, action.recentSuccessRate * 0.1)

		let freshnessPenalty = (action.requiresFreshContext && context.contextIsStale) ? 0.07 : 0.0
		if freshnessPenalty > 0 { explanations.append("penalized_stale_context") }

		let warningCount = Double(action.metadata["warningCount"] ?? "0") ?? 0
		let warningPenalty = min(0.1, warningCount * 0.02)

		let staticCompetitivenessBoost = action.sourceType == .staticAction
			? context.staticCompetitivenessBoost
			: 0

		var suppressed = false
		if action.isGeneratedFamily,
		   action.confidence < context.lowConfidenceGeneratedThreshold,
		   action.sourceType != .reusableGenerated
		{
			suppressed = true
			explanations.append("suppressed_low_confidence")
		}

		if action.sourceType == .reusableGenerated,
		   action.usefulnessScore < 0.38
		{
			suppressed = true
			explanations.append("suppressed_low_usefulness")
		}

		var raw = confidenceScore * 0.36
			+ usefulnessScore * 0.24
			+ workflowContinuityScore
			+ reuseBoost
			+ recentSuccessBoost
			+ staticCompetitivenessBoost
			- interruptionPenalty
			- executionComplexityPenalty
			- freshnessPenalty
			- warningPenalty

		if suppressed { raw *= 0.32 }

		let finalScore = min(1.0, max(0.0, raw))
		let components = UnifiedActionScoreComponents(
			confidenceScore: confidenceScore,
			usefulnessScore: usefulnessScore,
			workflowContinuityScore: workflowContinuityScore,
			interruptionPenalty: interruptionPenalty,
			executionComplexityPenalty: executionComplexityPenalty,
			reuseBoost: reuseBoost,
			recentSuccessBoost: recentSuccessBoost,
			freshnessPenalty: freshnessPenalty,
			warningPenalty: warningPenalty,
			staticCompetitivenessBoost: staticCompetitivenessBoost,
			finalScore: finalScore
		)
		return (components, explanations, suppressed)
	}

	private static func workflowIntentBoost(
		action: UnifiedRankableAction,
		context: UnifiedActionRankingContext,
		explanations: inout [String]
	) -> Double {
		guard context.activeWorkflow != .unknown else { return 0 }
		var boost = 0.0
		switch context.activeWorkflow {
		case .debugging:
			if action.workflowType == .debugging || action.intentType == .explain {
				boost += 0.06
				explanations.append("boosted_debug_workflow")
			}
		case .research:
			if action.workflowType == .research || action.intentType == .compare || action.intentType == .summarize {
				boost += 0.06
				explanations.append("boosted_research_workflow")
			}
		case .writing:
			if action.workflowType == .writing || action.intentType == .structure || action.intentType == .synthesize {
				boost += 0.06
				explanations.append("boosted_writing_workflow")
			}
		default:
			break
		}
		return boost
	}

	private static func applyGeneratedCap(
		_ ranked: [RankedUnifiedAction],
		context: UnifiedActionRankingContext
	) -> [RankedUnifiedAction] {
		let window = min(context.topWindowSize, ranked.count)
		guard window > 0 else { return ranked }

		let maxGenerated = Int(floor(Double(window) * context.maxGeneratedRatioInTopWindow))
		var top = Array(ranked.prefix(window))
		let tail = Array(ranked.dropFirst(window))

		var generatedInTop = top.filter { $0.action.isGeneratedFamily }.count
		if generatedInTop <= maxGenerated { return ranked }

		var demoted: [RankedUnifiedAction] = []
		var kept: [RankedUnifiedAction] = []
		kept.reserveCapacity(window)

		for item in top {
			if item.action.isGeneratedFamily, generatedInTop > maxGenerated {
				var codes = item.rankingExplanationCodes
				if !codes.contains("capped_generated_ratio") { codes.append("capped_generated_ratio") }
				demoted.append(
					RankedUnifiedAction(
						action: item.action,
						components: item.components,
						rankingExplanationCodes: codes,
						rankIndex: item.rankIndex
					)
				)
				generatedInTop -= 1
			} else {
				kept.append(item)
			}
		}

		return kept + demoted.sorted { $0.components.finalScore > $1.components.finalScore } + tail
	}

	private static func summary(for ranked: [RankedUnifiedAction], suppressed: Int) -> String {
		guard let top = ranked.first else { return "empty" }
		return "top=\(top.action.sourceType.rawValue) score=\(String(format: "%.2f", top.components.finalScore)) suppressed=\(suppressed)"
	}

	private static func buildWarnings(suppressed: Int, ranked: [RankedUnifiedAction]) -> [String] {
		var warnings: [String] = []
		if suppressed > 0 { warnings.append("suppressed_\(suppressed)") }
		let topGen = ranked.prefix(5).filter { $0.action.isGeneratedFamily }.count
		if topGen >= 4 { warnings.append("generated_heavy_top") }
		return warnings
	}

	private static func bucket(_ value: Double) -> String {
		if value >= 0.65 { return "high" }
		if value >= 0.45 { return "med" }
		return "low"
	}

	private static func publishSnapshot(_ result: UnifiedActionRankingResult) -> UnifiedActionRankingResult {
		snapshotLock.lock()
		latestSnapshot = result
		snapshotLock.unlock()
		return result
	}

	private static func logRanking(result: UnifiedActionRankingResult, context: UnifiedActionRankingContext) {
		let topSource = result.rankedActions.first?.action.sourceType.rawValue ?? "none"
		let genTop = result.rankedActions.prefix(context.topWindowSize).filter { $0.action.isGeneratedFamily }.count
		var meta = IntelligenceDebugMeta(
			reason: result.rankingReasonSummary,
			layer: "unified_action_ranking",
			type: topSource,
			actions: result.consideredCount,
			lenBucket: result.suppressedCount,
			lineBucket: genTop,
			detail: "wf_\(context.activeWorkflow.rawValue)"
		)
		meta.score = String(result.rankingDurationMs)
		IntelligenceDebugLogger.log(stage: .execution, event: "unified_ranking_completed", meta: meta)
	}

	// MARK: - Self-test

	static func runSelfTest() -> Bool {
		let ctx = UnifiedActionRankingContext(
			activeWorkflow: .debugging,
			continuityScore: 0.72,
			workflowConfidence: 0.7
		)

		let staticExplain = UnifiedActionRankingAdapter.fromStatic(actionId: ExplainAction.explainTextId, baseScore: 0.62)
		let staticSummarize = UnifiedActionRankingAdapter.fromStatic(actionId: SummarizeAction.summarizeTextId, baseScore: 0.58)
		let weakGenerated = UnifiedRankableAction(
			id: UUID().uuidString,
			sourceType: .generatedAction,
			title: "Weak",
			description: "weak",
			workflowType: .unknown,
			intentType: .unknown,
			confidence: 0.32,
			usefulnessScore: 0.3,
			interruptionCost: 0.2,
			candidateActionType: .generatedPreview
		)
		let strongReusable = UnifiedRankableAction(
			id: "reuse:debug",
			sourceType: .reusableGenerated,
			title: "Reuse debug",
			description: "reuse",
			workflowType: .debugging,
			intentType: .explain,
			confidence: 0.78,
			usefulnessScore: 0.82,
			interruptionCost: 0.18,
			isReusable: true,
			reuseScore: 0.8,
			recentSuccessRate: 0.85,
			candidateActionType: .reusableTemplate,
			primitiveSignature: "debug|explain"
		)
		let heavyPlan = UnifiedRankableAction(
			id: UUID().uuidString,
			sourceType: .executablePlan,
			title: "Heavy",
			description: "heavy",
			workflowType: .research,
			intentType: .compare,
			confidence: 0.7,
			usefulnessScore: 0.65,
			interruptionCost: 0.35,
			executionComplexity: 6,
			estimatedExecutionTime: 80,
			requiresVision: true,
			candidateActionType: .generatedPlan
		)

		let result1 = rank(
			actions: [weakGenerated, staticExplain, staticSummarize, strongReusable, heavyPlan],
			context: ctx
		)
		guard let top = result1.rankedActions.first else { return false }
		guard top.action.sourceType == .staticAction || top.action.sourceType == .reusableGenerated else { return false }
		guard result1.staticActionCount >= 2 else { return false }

		let weakRank = result1.rankedActions.firstIndex(where: { $0.action.id == weakGenerated.id })
		let strongRank = result1.rankedActions.firstIndex(where: { $0.action.id == strongReusable.id })
		guard let weakRank, let strongRank, strongRank < weakRank else { return false }
		guard weakGenerated.id == result1.rankedActions[weakRank].action.id else { return false }
		guard result1.rankedActions[weakRank].rankingExplanationCodes.contains("suppressed_low_confidence") else {
			return false
		}

		let highInterrupt = UnifiedRankableAction(
			id: "interrupt",
			sourceType: .generatedAction,
			title: "Interrupt",
			description: "x",
			workflowType: .debugging,
			intentType: .explain,
			confidence: 0.72,
			interruptionCost: 0.92,
			candidateActionType: .generatedPreview
		)
		let lowInterrupt = UnifiedRankableAction(
			id: "calm",
			sourceType: .generatedAction,
			title: "Calm",
			description: "x",
			workflowType: .debugging,
			intentType: .explain,
			confidence: 0.72,
			interruptionCost: 0.12,
			candidateActionType: .generatedPreview
		)
		let interruptResult = rank(actions: [highInterrupt, lowInterrupt], context: ctx)
		guard interruptResult.rankedActions.first?.action.id == lowInterrupt.id else { return false }

		let staleReuse = UnifiedRankableAction(
			id: "reuse:stale",
			sourceType: .reusableGenerated,
			title: "Stale",
			description: "stale",
			workflowType: .debugging,
			intentType: .explain,
			confidence: 0.7,
			usefulnessScore: 0.35,
			isReusable: true,
			reuseScore: 0.35,
			candidateActionType: .reusableTemplate,
			metadata: ["staleFactor": "0.50"]
		)
		let freshReuse = strongReusable
		let staleResult = rank(actions: [staleReuse, freshReuse], context: ctx)
		guard staleResult.rankedActions.first?.action.id == freshReuse.id else { return false }

		let manyGenerated = (0..<6).map { i in
			UnifiedRankableAction(
				id: "gen\(i)",
				sourceType: .generatedAction,
				title: "G\(i)",
				description: "g",
				workflowType: .debugging,
				intentType: .explain,
				confidence: 0.8 - Double(i) * 0.02,
				usefulnessScore: 0.7,
				candidateActionType: .generatedPreview
			)
		}
		let capResult = rank(actions: manyGenerated + [staticExplain], context: ctx)
		let topWindowGen = capResult.rankedActions.prefix(5).filter { $0.action.isGeneratedFamily }.count
		guard topWindowGen <= 3 else { return false }

		let result2 = rank(actions: [staticExplain, staticSummarize], context: ctx)
		let result3 = rank(actions: [staticExplain, staticSummarize], context: ctx)
		guard result2.rankedActions.map(\.id) == result3.rankedActions.map(\.id) else { return false }
		guard result2.rankedActions.allSatisfy({ !$0.rankingExplanationCodes.isEmpty || $0.action.sourceType == .staticAction }) else {
			return false
		}

		_ = latestRankingSnapshot()
		return true
	}
}
