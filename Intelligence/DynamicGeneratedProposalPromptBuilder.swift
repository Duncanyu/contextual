import Foundation

/// Bounded prompt construction for LLM-first generated execution proposals (T18.3.1+).
enum DynamicGeneratedProposalPromptBuilder {

	static let compactPromptByteBudget = 2200
	static let maxProposalsInPrompt = 1

	static func build(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		existingStaticActions: [String],
		reusableCount: Int,
		history: ProposalHistoryMetadata?,
		budget: ExecutionBudget,
		situational: SituationalContextSnapshot? = nil
	) -> String {
		if let situational {
			return buildCompact(
				snapshot: snapshot,
				situational: situational,
				budget: budget,
				history: history
			)
		}
		return buildLegacy(
			snapshot: snapshot,
			existingStaticActions: existingStaticActions,
			reusableCount: reusableCount,
			history: history,
			budget: budget
		)
	}

	// MARK: - Compact (T18.3.3B)

	private static func buildCompact(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		budget: ExecutionBudget,
		history: ProposalHistoryMetadata?
	) -> String {
		let primitives = "answer_from_context,classify_workflow,extract_action_items,compare_contexts"
		let guidance = situational.assistantGuidance.prefix(3).joined(separator: "; ")
		let missing = situational.missingContextReasons.prefix(4).joined(separator: ",")
		let dismissals = history?.recentDismissedCandidateIds.count ?? 0
		let clip = situational.clipboardSignal

		return """
		Calm macOS assistant. Return ONLY compact JSON. Max \(maxProposalsInPrompt) proposal.
		Schema: {"shouldChimeIn":bool,"reason":str,"workflowAssessment":str,"proposalConfidence":0-1,"requiresVisualContext":bool,"proposals":[{"title":str,"description":str,"intentType":str,"workflowType":str,"expectedOutcome":str,"requiredContextTypes":[str],"suggestedPrimitives":[str],"interruptionCost":0-1,"confidence":0-1}]}
		Rules: specific situational titles only; NO summarize/explain/rewrite; weak context => shouldChimeIn=false proposals=[]; primitives in [\(primitives)]; requiresVisualContext is recommendation only.
		Situation: \(truncate(situational.situationalSummary, max: 220))
		Guidance: \(guidance.isEmpty ? "stay quiet if unsure" : guidance)
		App=\(snapshot.activeApp) workflow=\(situational.inferredWorkflow.rawValue) primary=\(situational.primaryAvailableSource.rawValue) fused=\(situational.metadata["fused_packet"] ?? "no")
		Clipboard: suppressed=\(clip.availability == .suppressed ? "yes" : "no") relevance=\(clip.relevance.rawValue) reason=\(clip.reasonCodes.first ?? "none")
		Missing: \(missing.isEmpty ? "none" : missing) perception=\(situational.perceptionRecommendation.rawValue)
		Window_title_len=\(snapshot.windowTitle.count) dismissals=\(dismissals) budget_vision=\(budget.allowsVision)
		"""
	}

	// MARK: - Legacy full prompt

	private static func buildLegacy(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		existingStaticActions: [String],
		reusableCount: Int,
		history: ProposalHistoryMetadata?,
		budget: ExecutionBudget
	) -> String {
		let primitives = ExecutionPrimitive.allCases.map(\.rawValue).joined(separator: ", ")
		let workflows = WorkflowType.allCases.map(\.rawValue).joined(separator: ", ")
		let intents = IntentType.allCases.map(\.rawValue).joined(separator: ", ")

		let historyLine: String
		if let history, !history.recentDismissedCandidateIds.isEmpty {
			historyLine = "recent_dismissals=\(history.recentDismissedCandidateIds.count)"
		} else {
			historyLine = "recent_dismissals=0"
		}

		return """
		You are a calm macOS contextual assistant. Propose situational, executable cognitive operations — NOT renamed summarize/explain/rewrite buttons.
		Return STRICT JSON only. Max \(maxProposalsInPrompt) proposal.
		suggestedPrimitives: [\(primitives)] workflowType: [\(workflows)] intentType: [\(intents)]
		app=\(snapshot.activeApp) workflow=\(snapshot.inferredWorkflow.rawValue) freshness=\(String(format: "%.2f", snapshot.freshnessScore))
		\(historyLine) budget_vision=\(budget.allowsVision)
		"""
	}

	private static func truncate(_ value: String, max: Int) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.count <= max { return trimmed }
		return String(trimmed.prefix(max))
	}
}
