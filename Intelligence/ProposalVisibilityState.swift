import Foundation

/// Lightweight snapshot of the proposal pipeline outcome (T18.6).
///
/// Populated after each proposal publication cycle.
/// Purely metadata — no raw context, no proposal text.
/// Used by debug UI and the resurfacing guarantee.
struct ProposalVisibilityState: Equatable, Sendable {

	/// Total generated proposals that entered the chime-in policy evaluation.
	let generatedCount: Int

	/// Proposals that made it to the panel after chime-in filtering.
	let visibleCount: Int

	/// Proposals blocked by chime-in policy or novelty gating.
	let suppressedCount: Int

	/// Human-readable reason codes from the policy decision (for debug footer).
	let suppressionReasons: [String]

	/// Raw mode string from the last chime-in decision ("suppress", "panelOnly", "floatingSuggestion").
	let lastDecision: String?

	/// Novelty score of the top proposal at decision time (0–1).
	let lastNoveltyScore: Double?

	/// When this state was last updated.
	let updatedAt: Date

	/// No proposals have been generated or evaluated yet.
	static let empty = ProposalVisibilityState(
		generatedCount: 0,
		visibleCount: 0,
		suppressedCount: 0,
		suppressionReasons: [],
		lastDecision: nil,
		lastNoveltyScore: nil,
		updatedAt: .distantPast
	)

	// MARK: - Convenience

	/// True when the pipeline generated candidates but all were filtered.
	var isFullySuppressed: Bool { visibleCount == 0 && generatedCount > 0 }

	/// True when nothing was generated at all (not a suppression — just nothing to show).
	var isIdle: Bool { generatedCount == 0 }

	/// One-line string for the panel debug footer.
	var debugFooterLine: String {
		guard !isIdle else { return "Pipeline: idle (no candidates)" }
		let decisionTag = lastDecision.map { " [\($0)]" } ?? ""
		let noveltyTag = lastNoveltyScore.map { " novelty=\(String(format: "%.2f", $0))" } ?? ""
		if isFullySuppressed {
			let reason = suppressionReasons.first ?? "policy"
			return "Pipeline: generated=\(generatedCount) visible=0 suppressed — \(reason)\(noveltyTag)"
		}
		return "Pipeline: generated=\(generatedCount) visible=\(visibleCount)\(decisionTag)\(noveltyTag)"
	}

	/// Structured log string for [ProposalPipeline] entries.
	var pipelineLogLine: String {
		var parts = [
			"generated=\(generatedCount)",
			"visible=\(visibleCount)",
			"suppressed=\(suppressedCount)",
		]
		if let decision = lastDecision { parts.append("decision=\(decision)") }
		if let novelty = lastNoveltyScore { parts.append("novelty=\(String(format: "%.2f", novelty))") }
		if let reason = suppressionReasons.first { parts.append("reason=\(reason)") }
		return parts.joined(separator: " ")
	}
}
