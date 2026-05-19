import Foundation

/// Bounded prompt construction for LLM-first generated execution proposals (T18.3.1).
enum DynamicGeneratedProposalPromptBuilder {

	static let maxContextSummaryLength = 320
	static let maxSelectionHintLength = 160
	static let maxClipboardHintLength = 80
	static let maxOCRHintLength = 120

	static func build(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		existingStaticActions: [String],
		reusableCount: Int,
		history: ProposalHistoryMetadata?,
		budget: ExecutionBudget,
		situational: SituationalContextSnapshot? = nil
	) -> String {
		let primitives = ExecutionPrimitive.allCases.map(\.rawValue).joined(separator: ", ")
		let workflows = WorkflowType.allCases.map(\.rawValue).joined(separator: ", ")
		let intents = IntentType.allCases.map(\.rawValue).joined(separator: ", ")
		let contextTypes = ContextRequirementType.allCases
			.filter { $0 != .none }
			.map(\.rawValue)
			.joined(separator: ", ")

		let selectionHint = boundedHint(
			label: "selection_excerpt_chars",
			length: snapshot.selectedText?.count ?? 0
		)
		let clipboardHint = boundedHint(label: "clipboard_available", length: snapshot.clipboardText?.count ?? 0)
		let ocrHint = boundedHint(label: "ocr_excerpt_chars", length: snapshot.recentOCRExcerpt?.count ?? 0)

		let visual = snapshot.visualContextAvailability
		let visualLine = "visual_descriptor=\(visual.hasVisualDescriptor) window_snapshot=\(visual.hasWindowSnapshot) visual_fresh=\(visual.visualCapturedAt != nil)"

		let historyLine: String
		if let history, !history.recentDismissedCandidateIds.isEmpty {
			historyLine = "recent_dismissals=\(history.recentDismissedCandidateIds.count)"
		} else {
			historyLine = "recent_dismissals=0"
		}

		let staticLine = existingStaticActions.isEmpty
			? "static_fallback_actions=none"
			: "static_fallback_actions=\(existingStaticActions.joined(separator: ","))"

		let situationalBlock = situationalPromptBlock(situational)

		return """
		You are a calm macOS contextual assistant. Propose situational, executable cognitive operations — NOT renamed summarize/explain/rewrite buttons.

		Return STRICT JSON only with this schema:
		{
		  "shouldChimeIn": boolean,
		  "reason": string,
		  "workflowAssessment": string,
		  "proposalConfidence": number,
		  "requiresVisualContext": boolean,
		  "proposals": [
		    {
		      "title": string,
		      "description": string,
		      "intentType": string,
		      "workflowType": string,
		      "expectedOutcome": string,
		      "requiredContextTypes": [string],
		      "suggestedPrimitives": [string],
		      "interruptionCost": number,
		      "confidence": number
		    }
		  ]
		}

		Rules:
		- Max 3 proposals. Prefer 1 strong proposal over many weak ones.
		- Titles must be specific to the situation (verb + object), <= 72 chars.
		- Do NOT propose generic "Summarize selected text", "Explain this", "Rewrite clipboard", or "Structure notes".
		- suggestedPrimitives must use only: [\(primitives)]
		- workflowType must be one of: [\(workflows)]
		- intentType must be one of: [\(intents)]
		- requiredContextTypes subset of: [\(contextTypes)]
		- interruptionCost 0..1. confidence 0..1. proposalConfidence 0..1.
		- If context is weak/random, set shouldChimeIn=false and proposals=[].
		- requiresVisualContext is a recommendation only (no capture).
		- Budget: vision=\(budget.allowsVision) ocr=\(budget.allowsOCR) max_runtime=\(Int(budget.maxExecutionTime))s

		Philosophy examples:
		BAD: "Summarize debugging result"
		GOOD: "Trace which context source is dominating proposal generation"
		BAD: "Structure notes"
		GOOD: "Turn implementation discussion into executable stabilization tasks"

		Context packet (metadata + short hints only):
		app=\(snapshot.activeApp)
		window_title_len=\(snapshot.windowTitle.count)
		inferred_workflow=\(snapshot.inferredWorkflow.rawValue)
		workflow_confidence=\(String(format: "%.2f", snapshot.workflowConfidence))
		freshness=\(String(format: "%.2f", snapshot.freshnessScore))
		packet_stale=\(snapshot.packetIsStale)
		\(selectionHint)
		\(clipboardHint)
		\(ocrHint)
		\(visualLine)
		available_context_types=\(snapshot.availableContextTypes.map(\.rawValue).joined(separator: ","))
		context_summary=\(snapshot.contextSummary ?? "none")
		\(staticLine)
		reusable_templates=\(reusableCount)
		\(historyLine)
		continuity=\(String(format: "%.2f", snapshot.sourceMetadata.sessionContinuityScore))
		\(situationalBlock)
		"""
	}

	private static func situationalPromptBlock(_ situational: SituationalContextSnapshot?) -> String {
		guard let situational else {
			return "situational_context=not_provided"
		}
		let guidance = situational.assistantGuidance.prefix(6).joined(separator: " | ")
		let missing = situational.missingContextReasons.prefix(6).joined(separator: ",")
		let perceptionReasons = situational.perceptionReasons.map(\.rawValue).joined(separator: ",")
		return """
		situational_context=provided
		situational_summary=\(situational.situationalSummary)
		assistant_guidance=\(guidance.isEmpty ? "none" : guidance)
		situational_primary_source=\(situational.primaryAvailableSource.rawValue)
		situational_app_category=\(situational.appCategory.rawValue)
		situational_workflow=\(situational.inferredWorkflow.rawValue)
		situational_workflow_confidence=\(String(format: "%.2f", situational.workflowConfidence))
		situational_freshness=\(String(format: "%.2f", situational.contextFreshness))
		selected_signal=\(situational.selectedTextSignal.availability.rawValue)/\(situational.selectedTextSignal.lengthBucket.rawValue)/\(situational.selectedTextSignal.freshness.rawValue)
		clipboard_signal=\(situational.clipboardSignal.availability.rawValue)/\(situational.clipboardSignal.lengthBucket.rawValue)/\(situational.clipboardSignal.freshness.rawValue)
		visual_signal=\(situational.visualSignal.availability.rawValue)
		ocr_signal=\(situational.ocrSignal.availability.rawValue)/\(situational.ocrSignal.lengthBucket.rawValue)
		activity_signal=\(situational.activitySignal.availability.rawValue)
		interaction_signal=\(situational.interactionSignal.availability.rawValue)
		missing_context_reasons=\(missing.isEmpty ? "none" : missing)
		perception_recommendation=\(situational.perceptionRecommendation.rawValue)
		perception_reasons=\(perceptionReasons.isEmpty ? "none" : perceptionReasons)
		"""
	}

	private static func boundedHint(label: String, length: Int) -> String {
		"\(label)=\(length)"
	}
}
