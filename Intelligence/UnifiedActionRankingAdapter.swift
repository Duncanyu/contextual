import Foundation

/// Adapters from existing action models into `UnifiedRankableAction` (metadata-only).
enum UnifiedActionRankingAdapter {

	static let defaultStaticActionIds = [
		SummarizeAction.summarizeTextId,
		ExplainAction.explainTextId,
		RewriteAction.rewriteTextId,
		ScreenAnalyzeAction.analyzeScreenId,
	]

	static func rankableActions(
		staticActionIds: [String] = defaultStaticActionIds,
		staticScores: [ActionRelevanceScore] = [],
		generatedActions: [GeneratedAction] = [],
		plans: [GeneratedActionPlan] = [],
		executionActions: [GeneratedExecutionAction] = [],
		reusableRecords: [ReusableGeneratedActionRecord] = [],
		referenceTime: Date = Date()
	) -> [UnifiedRankableAction] {
		let scoreMap = Dictionary(uniqueKeysWithValues: staticScores.map { ($0.actionId, $0.score) })
		var out: [UnifiedRankableAction] = []
		out.reserveCapacity(
			staticActionIds.count + generatedActions.count + plans.count
				+ executionActions.count + reusableRecords.count
		)

		for actionId in staticActionIds {
			out.append(fromStatic(actionId: actionId, baseScore: scoreMap[actionId] ?? 0.55))
		}
		for action in generatedActions where !action.isStale {
			out.append(fromGenerated(action))
		}
		for plan in plans where !plan.isStale {
			out.append(fromPlan(plan))
		}
		for execution in executionActions where !execution.isExpired {
			out.append(fromExecution(execution))
		}
		for record in reusableRecords where record.reuseEligibility == .eligible && record.expiresAt > referenceTime {
			out.append(fromReusable(record, referenceTime: referenceTime))
		}
		return out
	}

	static func context(
		workflow: WorkflowInferenceResult?,
		session: ContextualSessionState?,
		fusedStale: Bool = false,
		referenceTime: Date = Date()
	) -> UnifiedActionRankingContext {
		let wfType = workflow.map { WorkflowExecutionMapper.workflowType(from: $0.workflow) } ?? .unknown
		let wfConf = workflow.map { min(1.0, max(0.0, $0.confidence)) } ?? 0
		let cont = session.map { min(1.0, max(0.0, $0.continuityConfidence)) } ?? 0
		let stale = (workflow?.isStale ?? true) || (session?.isStale ?? true) || fusedStale
		return UnifiedActionRankingContext(
			activeWorkflow: wfType,
			continuityScore: cont,
			workflowConfidence: wfConf,
			contextIsStale: stale,
			referenceTime: referenceTime
		)
	}

	/// One-shot debug ranking from pipeline inputs (no UI / no persistence side effects).
	/// Prefer `UnifiedActionRankingDebug.unifiedRankingLine` in debug UI to avoid repeated rank passes.
	static func buildDebugRanking(
		inputs: DynamicIntentDebugPipelineInputs,
		reusableRecords: [ReusableGeneratedActionRecord] = [],
		staticScores: [ActionRelevanceScore] = [],
		referenceTime: Date = Date(),
		emitRankingLog: Bool = true
	) -> UnifiedActionRankingResult {
		let actions = rankableActions(
			staticScores: staticScores,
			generatedActions: inputs.actions,
			plans: inputs.plans,
			reusableRecords: reusableRecords,
			referenceTime: referenceTime
		)
		let ctx = context(workflow: inputs.workflow, session: inputs.session, referenceTime: referenceTime)
		return UnifiedActionRanker.rank(actions: actions, context: ctx, emitLog: emitRankingLog)
	}

	// MARK: - Mappers

	static func fromStatic(actionId: String, baseScore: Double) -> UnifiedRankableAction {
		let (wf, intent, title, vision, ocr) = staticTraits(actionId)
		return UnifiedRankableAction(
			id: actionId,
			sourceType: .staticAction,
			title: title,
			description: "static_action",
			workflowType: wf,
			intentType: intent,
			confidence: min(1.0, max(0.35, baseScore)),
			usefulnessScore: 0.58,
			interruptionCost: actionId == ScreenAnalyzeAction.analyzeScreenId ? 0.42 : 0.18,
			executionComplexity: actionId == ScreenAnalyzeAction.analyzeScreenId ? 3 : 1,
			estimatedExecutionTime: actionId == ScreenAnalyzeAction.analyzeScreenId ? 28 : 10,
			requiresFreshContext: false,
			requiresVision: vision,
			requiresOCR: ocr,
			candidateActionType: .staticAction,
			metadata: ["stable": "1"]
		)
	}

	static func fromGenerated(_ action: GeneratedAction) -> UnifiedRankableAction {
		let wf = WorkflowExecutionMapper.workflowType(from: action.workflow)
		let intent = WorkflowExecutionMapper.intentType(from: action.intentType)
		let requiresVision = action.requiredContext.contains(.fusedVisual) || action.requiredContext.contains(.screenCapture)
		let requiresOCR = action.requiredContext.contains(.screenCapture)
		return UnifiedRankableAction(
			id: action.id.uuidString,
			sourceType: .generatedAction,
			title: action.title,
			description: action.description,
			workflowType: wf,
			intentType: intent,
			confidence: action.confidence,
			usefulnessScore: min(1.0, action.workflowRelevance * 0.35 + action.confidence * 0.4),
			interruptionCost: action.interruptionCost,
			executionComplexity: action.primitives.count,
			estimatedExecutionTime: TimeInterval(8 + action.primitives.count * 6),
			requiresFreshContext: true,
			requiresVision: requiresVision,
			requiresOCR: requiresOCR,
			candidateActionType: .generatedPreview,
			primitiveSignature: action.primitives.map(\.rawValue).joined(separator: ","),
			metadata: ["primitiveCount": String(action.primitives.count)]
		)
	}

	static func fromPlan(_ plan: GeneratedActionPlan) -> UnifiedRankableAction {
		let wf = WorkflowExecutionMapper.workflowType(from: plan.workflow)
		let intent = WorkflowExecutionMapper.intentType(from: plan.intentType)
		let requiresVision = plan.requiredContext.contains(.fusedVisual) || plan.requiredContext.contains(.screenCapture)
		return UnifiedRankableAction(
			id: plan.id.uuidString,
			sourceType: .executablePlan,
			title: "Plan · \(plan.compositionRule.rawValue)",
			description: plan.explanation,
			workflowType: wf,
			intentType: intent,
			confidence: plan.confidence,
			usefulnessScore: plan.confidence * 0.85,
			interruptionCost: 0.28,
			executionComplexity: plan.steps.count,
			estimatedExecutionTime: TimeInterval(10 + plan.steps.count * 8),
			requiresFreshContext: true,
			requiresVision: requiresVision,
			requiresOCR: plan.requiredContext.contains(.screenCapture),
			candidateActionType: .generatedPlan,
			primitiveSignature: plan.steps.map(\.primitive.rawValue).joined(separator: ">"),
			metadata: ["stepCount": String(plan.steps.count), "rule": plan.compositionRule.rawValue]
		)
	}

	static func fromExecution(_ action: GeneratedExecutionAction) -> UnifiedRankableAction {
		let signature = GeneratedActionPrimitiveSignature.from(action: action)
		return UnifiedRankableAction(
			id: action.id.uuidString,
			sourceType: .executableGenerated,
			title: action.title,
			description: action.description,
			workflowType: action.workflowType,
			intentType: action.intentType,
			confidence: action.confidence,
			usefulnessScore: action.reuseScore,
			interruptionCost: action.interruptionCost,
			executionComplexity: action.executionPlan.primitives.count,
			estimatedExecutionTime: action.executionPlan.estimatedRuntime,
			requiresFreshContext: true,
			requiresVision: action.executionPlan.requiresVision,
			requiresOCR: action.executionPlan.requiresOCR,
			isReusable: action.isReusable,
			reuseScore: action.reuseScore,
			candidateActionType: .executionAction,
			primitiveSignature: signature.signatureCode,
			metadata: [
				"planConfidence": String(format: "%.2f", action.executionPlan.planConfidence),
				"budgetPriority": action.executionPlan.executionBudget.budgetPriority.rawValue,
			]
		)
	}

	static func fromProposalCandidate(_ candidate: GeneratedExecutionProposalCandidate) -> UnifiedRankableAction {
		let sourceType: UnifiedActionSourceType = {
			switch candidate.source {
			case .staticAction: .staticAction
			case .generatedAction: .generatedAction
			case .generatedExecution: .executableGenerated
			case .reusableGenerated: .reusableGenerated
			}
		}()
		let candidateType: UnifiedCandidateActionType = {
			switch candidate.source {
			case .staticAction: .staticAction
			case .generatedAction: .generatedPreview
			case .generatedExecution: .executionAction
			case .reusableGenerated: .reusableTemplate
			}
		}()
		let requiresVision = candidate.requiredContextTypes.contains(.fusedVisual)
			|| candidate.requiredContextTypes.contains(.screenCapture)
		let requiresOCR = candidate.requiredContextTypes.contains(.screenCapture)
		return UnifiedRankableAction(
			id: candidate.id,
			sourceType: sourceType,
			title: candidate.title,
			description: candidate.description,
			workflowType: candidate.workflowType,
			intentType: candidate.intentType,
			confidence: candidate.confidence,
			usefulnessScore: candidate.isGeneratedFamily
				? min(1, candidate.confidence * 0.85 + 0.1)
				: 0.58,
			interruptionCost: candidate.interruptionCost,
			executionComplexity: candidate.executionAction?.executionPlan.primitives.count ?? 1,
			estimatedExecutionTime: candidate.executionAction?.executionPlan.estimatedRuntime ?? 12,
			requiresFreshContext: candidate.isGeneratedFamily,
			requiresVision: requiresVision,
			requiresOCR: requiresOCR,
			isReusable: candidate.source == .reusableGenerated,
			reuseScore: candidate.executionAction?.reuseScore ?? 0,
			candidateActionType: candidateType,
			primitiveSignature: candidate.primitiveSignature,
			metadata: [
				"proposalSource": candidate.source.rawValue,
				"executable": candidate.isExecutableGeneratedProposal ? "1" : "0",
			]
		)
	}

	static func fromReusable(
		_ record: ReusableGeneratedActionRecord,
		referenceTime: Date
	) -> UnifiedRankableAction {
		let executed = max(1, record.executedCount)
		let successRate = Double(record.successfulExecutionCount) / Double(executed)
		let daysSinceUse = referenceTime.timeIntervalSince(record.lastUsedAt) / 86_400
		let staleFactor = daysSinceUse > 7 ? max(0, 1.0 - (daysSinceUse - 7) * 0.05) : 1.0
		let usefulness = record.usefulnessScore * staleFactor
		return UnifiedRankableAction(
			id: "reuse:\(record.actionTemplateId)",
			sourceType: .reusableGenerated,
			title: record.title,
			description: record.description,
			workflowType: record.workflowType,
			intentType: record.intentType,
			confidence: record.averageConfidence,
			usefulnessScore: usefulness,
			interruptionCost: 0.22,
			executionComplexity: max(1, record.primitiveSignature.split(separator: ",").count),
			estimatedExecutionTime: 14,
			requiresFreshContext: false,
			isReusable: true,
			reuseScore: min(1.0, usefulness),
			recentSuccessRate: successRate,
			candidateActionType: .reusableTemplate,
			primitiveSignature: record.primitiveSignature,
			metadata: [
				"acceptedCount": String(record.acceptedCount),
				"executedCount": String(record.executedCount),
				"staleFactor": String(format: "%.2f", staleFactor),
			]
		)
	}

	private static func staticTraits(_ actionId: String) -> (WorkflowType, IntentType, String, Bool, Bool) {
		switch actionId {
		case ExplainAction.explainTextId:
			return (.debugging, .explain, "Explain", false, false)
		case SummarizeAction.summarizeTextId:
			return (.research, .summarize, "Summarize", false, false)
		case RewriteAction.rewriteTextId:
			return (.writing, .structure, "Rewrite", false, false)
		case ScreenAnalyzeAction.analyzeScreenId:
			return (.debugging, .explain, "Analyze screen", true, true)
		default:
			return (.unknown, .unknown, actionId, false, false)
		}
	}
}
