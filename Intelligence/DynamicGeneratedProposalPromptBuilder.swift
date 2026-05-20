import Foundation

/// Bounded prompt construction for LLM-first generated execution proposals (T18.3.3C: compact schema).
enum DynamicGeneratedProposalPromptBuilder {

	static let maxProposalsInPrompt = 1
	/// Byte ceiling used by self-tests that verify prompt size (T18.3.3C target: < 1500 bytes).
	static let compactPromptByteBudget = 1500

	// Allowed primitives listed explicitly so small LLMs can copy-paste.
	static let allowedPrimitives =
		"answer_from_context, classify_workflow, extract_action_items, compare_contexts, " +
		"summarize_context, generate_checklist, structure_notes, explain_error, " +
		"organize_information, generate_study_notes, synthesize_research_summary"

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
		return buildFallback(snapshot: snapshot, budget: budget)
	}

	// MARK: - Compact situational prompt (T18.3.3C)
	// Target: < 1500 bytes. No examples, no prose allowed in response.

	private static func buildCompact(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		budget: ExecutionBudget,
		history: ProposalHistoryMetadata?
	) -> String {
		let guidance = situational.assistantGuidance.prefix(2).joined(separator: "; ")
		let clip = situational.clipboardSignal
		let dismissals = history?.recentDismissedCandidateIds.count ?? 0

		// Required schema comment is embedded so the model sees the exact structure it must output.
		return """
		Respond with ONLY a JSON object. No markdown. No prose. No explanation.
		Schema (use exactly these key names):
		{"chime":bool,"reason":"short","proposal":{"title":"short action","description":"short","workflow":"browsing","intent":"research","outcome":"what this produces","primitives":["answer_from_context"],"confidence":0.72}}
		Rules:
		- chime=false and omit proposal if context is weak or unclear.
		- title and description must be specific to situation, NOT generic (no "summarize this", "explain selected text", "rewrite text").
		- primitives must be chosen from: \(allowedPrimitives)
		- confidence is a float 0-1; use 0 if unsure.
		- Max 1 proposal.
		Situation: \(truncate(situational.situationalSummary, max: 200))
		\(guidance.isEmpty ? "" : "Guidance: \(guidance)")
		App=\(snapshot.activeApp) workflow=\(situational.inferredWorkflow.rawValue) source=\(situational.primaryAvailableSource.rawValue)
		Clipboard=\(clip.availability == .suppressed ? "suppressed" : clip.relevance.rawValue) dismissals=\(dismissals)
		"""
	}

	// MARK: - Minimal fallback (no situational context available)

	private static func buildFallback(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		budget: ExecutionBudget
	) -> String {
		return """
		Respond with ONLY a JSON object. No markdown. No prose.
		Schema: {"chime":bool,"reason":"short","proposal":{"title":"short","description":"short","workflow":"browsing","intent":"answer","outcome":"what this produces","primitives":["answer_from_context"],"confidence":0.6}}
		Rules: chime=false unless strong situational context. Primitives: \(allowedPrimitives)
		App=\(snapshot.activeApp) workflow=\(snapshot.inferredWorkflow.rawValue) vision=\(budget.allowsVision)
		"""
	}

	private static func truncate(_ value: String, max: Int) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.count <= max { return trimmed }
		return String(trimmed.prefix(max))
	}
}
