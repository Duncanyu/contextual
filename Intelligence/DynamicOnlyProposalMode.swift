import Foundation

/// T18.3.2 — generated proposals are the only live proactive proposal source.
enum DynamicOnlyProposalMode {
	static let isEnabled = true

	static let genericStaticActionIds: Set<String> = [
		SummarizeAction.summarizeTextId,
		ExplainAction.explainTextId,
		RewriteAction.rewriteTextId,
	]

	static func isGenericStaticAction(_ actionId: String) -> Bool {
		genericStaticActionIds.contains(actionId)
	}

	static func filterGenericStaticActions(_ actionIds: [String]) -> [String] {
		actionIds.filter { !isGenericStaticAction($0) }
	}
}

// MARK: - Debug status (metadata only)

struct GeneratedProposalDebugStatus: Equatable, Sendable {
	let attempted: Bool
	let llmOutcome: String
	let candidateCount: Int
	let visibleCount: Int
	let zeroVisibleReason: String?
	let contextSourceUsed: String
	let staticFallbackSuppressed: Bool
	let updatedAt: Date

	static let idle = GeneratedProposalDebugStatus(
		attempted: false,
		llmOutcome: "not_attempted",
		candidateCount: 0,
		visibleCount: 0,
		zeroVisibleReason: "not_attempted",
		contextSourceUsed: "none",
		staticFallbackSuppressed: true,
		updatedAt: Date()
	)

	var logLine: String {
		let reason = zeroVisibleReason ?? (visibleCount > 0 ? "visible" : "none")
		return """
		Generated proposal status: attempted=\(attempted ? "yes" : "no") LLM=\(llmOutcome) candidates=\(candidateCount) visible=\(visibleCount) top_reason_if_zero=\(reason) context_source=\(contextSourceUsed) static_fallback_suppressed=\(staticFallbackSuppressed ? "yes" : "no")
		"""
	}
}

enum GeneratedProposalDebugStatusBuilder {

	static func build(
		llmResult: DynamicGeneratedProposalResult,
		llmCandidates: [GeneratedExecutionProposalCandidate],
		activation: GeneratedExecutionProposalActivationResult,
		situational: SituationalContextSnapshot,
		referenceTime: Date = Date()
	) -> GeneratedProposalDebugStatus {
		let llmOutcome = llmOutcomeLabel(llmResult)
		let visible = activation.visibleProposals.count
		let zeroReason = visible == 0
			? resolveZeroReason(llmResult: llmResult, activation: activation, situational: situational)
			: nil

		return GeneratedProposalDebugStatus(
			attempted: true,
			llmOutcome: llmOutcome,
			candidateCount: llmCandidates.count,
			visibleCount: visible,
			zeroVisibleReason: zeroReason,
			contextSourceUsed: situational.primaryAvailableSource.rawValue,
			staticFallbackSuppressed: DynamicOnlyProposalMode.isEnabled,
			updatedAt: referenceTime
		)
	}

	private static func llmOutcomeLabel(_ result: DynamicGeneratedProposalResult) -> String {
		switch result.status {
		case .synthesized: result.shouldChimeIn ? "success" : "success_quiet"
		case .quietByGate: "gated"
		case .modelUnavailable: "unavailable"
		case .parseFailed: "parse_failed"
		case .timeout: "timeout"
		case .cancelled: "cancelled"
		}
	}

	private static func resolveZeroReason(
		llmResult: DynamicGeneratedProposalResult,
		activation: GeneratedExecutionProposalActivationResult,
		situational: SituationalContextSnapshot
	) -> String {
		switch llmResult.status {
		case .modelUnavailable:
			return "llm_unavailable"
		case .timeout:
			return "llm_timeout"
		case .parseFailed:
			return "parse_failed"
		case .cancelled:
			return "cancelled"
		case .quietByGate:
			if llmResult.warnings.contains("stale_context") { return "weak_context" }
			if llmResult.reason == "gated" { return "weak_context" }
			return llmResult.reason.isEmpty ? "weak_context" : llmResult.reason
		case .synthesized:
			break
		}

		if situational.clipboardSignal.availability == .suppressed {
			return "stale_clipboard_suppressed"
		}

		if situational.missingContextReasons.contains("no_fused_packet"),
		   situational.primaryAvailableSource == .metadataOnly
		{
			return "metadata_only_no_fused_packet"
		}

		if activation.suppressedGeneratedCount > 0, activation.visibleProposals.isEmpty {
			return "all_candidates_suppressed"
		}

		if !llmResult.shouldChimeIn {
			return llmResult.reason.isEmpty ? "llm_quiet" : llmResult.reason
		}

		return "all_candidates_suppressed"
	}

}
