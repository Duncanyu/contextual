import Foundation

struct RichContextProposalAdjustment: Equatable, Sendable {
	let adjustedScores: [ActionRelevanceScore]
	let adjustedPrimaryActionId: String?
	let shouldSuppressAutomaticProposal: Bool
	let reasonCodes: [String]
}

/// Applies conservative, deterministic score adjustments using the canonical fused context packet when available.
/// Does not trigger any new collection. Metadata-only.
enum RichContextProposalAdjuster {
	static func adjust(
		relevance: [ActionRelevanceScore],
		context: ContextModel,
		fused: FusedContextPacket?,
		contextType: ContextType,
		features: ContextFeatures,
		isManualInvocation: Bool
	) -> RichContextProposalAdjustment {
		guard !relevance.isEmpty else {
			return RichContextProposalAdjustment(adjustedScores: relevance, adjustedPrimaryActionId: nil, shouldSuppressAutomaticProposal: false, reasonCodes: ["no_candidates"])
		}

		guard let fused else {
			return RichContextProposalAdjustment(adjustedScores: relevance, adjustedPrimaryActionId: nil, shouldSuppressAutomaticProposal: false, reasonCodes: ["no_rich_context"])
		}

		// Ignore stale/low-confidence rich context: do not override heuristic ranking based on weak fused state.
		if fused.isStale || fused.freshnessScore < 0.30 || fused.confidence < 0.45 {
			return RichContextProposalAdjustment(adjustedScores: relevance, adjustedPrimaryActionId: nil, shouldSuppressAutomaticProposal: false, reasonCodes: ["rich_context_ignored_stale"])
		}

		// Interaction awareness (light touch): be more conservative when user is actively interacting.
		let isInteracting = (fused.typingState == .burst || fused.typingState == .active)
			|| (fused.pointerState == .burst || fused.pointerState == .interacting || fused.pointerState == .clicking)

		var deltas: [String: Double] = [:]
		var reasons: [String] = []

		let kinds = Set(fused.visualKinds)
		let hints = Set(fused.uiStructureHints)

		let isEditorLike = kinds.contains(.editor) || hints.contains("ax_editor_like") || hints.contains("visual_monospace_region") || contextType == .code
		let isTerminalLike = kinds.contains(.terminal) || features.isLikelyLog || contextType == .errorLog
		let isDialogLike = kinds.contains(.dialog) || hints.contains("visual_dialog_like")
		let isArticleLike = kinds.contains(.article) || kinds.contains(.browser) || contextType == .article || contextType == .notes
		let isFormLike = kinds.contains(.form) || hints.contains("ax_form_like")

		// Editor/code context: explain is preferred; rewrite is not boosted.
		if isEditorLike {
			deltas["explain_text", default: 0] += 0.10
			deltas["summarize_text", default: 0] += 0.02
			deltas["rewrite_text", default: 0] -= 0.04
			reasons.append("editor_context_explain")
		}

		// Terminal/error/dialog context: strongly prefer explain, suppress rewrite.
		if isTerminalLike || isDialogLike {
			deltas["explain_text", default: 0] += 0.14
			deltas["rewrite_text", default: 0] -= 0.12
			reasons.append(isTerminalLike ? "error_or_terminal_explain" : "dialog_explain")
		}

		// Article/notes/reading: boost summarize, reduce rewrite for long prose.
		if isArticleLike {
			deltas["summarize_text", default: 0] += 0.10
			if features.textLength >= 220 {
				deltas["rewrite_text", default: 0] -= 0.06
			}
			reasons.append("article_or_notes_summarize")
		}

		// Form-heavy: suppress automatic floating proposal unless selection is strong and user is idle/light.
		var suppressAutomatic = false
		if isFormLike, !isManualInvocation {
			let strongSelection = context.selectedTextAvailable && context.selectedTextLength >= 60
			if !strongSelection && isInteracting {
				suppressAutomatic = true
				reasons.append("form_context_suppress")
			}
		}

		// If rich context is conflicting heavily and we don't have selection, be conservative.
		if fused.conflictScore >= 0.75, !context.selectedTextAvailable, !isManualInvocation {
			// Do not hard suppress; just avoid strong overrides.
			reasons.append("rich_context_conflict_high")
			deltas.removeAll()
		}

		// If user is actively interacting, reduce adjustment magnitude to avoid jerkiness.
		let scale: Double = isInteracting ? 0.60 : 1.0

		let adjusted = relevance.map { r -> ActionRelevanceScore in
			let delta = (deltas[r.actionId] ?? 0) * scale
			if delta == 0 {
				return r
			}
			let s = clamp01(r.score + delta)
			let reason = "\(r.reason)+rich(\(reasons.first ?? "adjust"))"
			return ActionRelevanceScore(actionId: r.actionId, score: s, reason: reason)
		}
		.sorted { a, b in
			if a.score != b.score { return a.score > b.score }
			return a.actionId < b.actionId
		}

		let primary = adjusted.first?.actionId
		return RichContextProposalAdjustment(
			adjustedScores: adjusted,
			adjustedPrimaryActionId: primary,
			shouldSuppressAutomaticProposal: suppressAutomatic,
			reasonCodes: reasons.isEmpty ? ["no_rich_adjustment"] : reasons
		)
	}
}

private func clamp01(_ x: Double) -> Double {
	min(1.0, max(0.0, x))
}

