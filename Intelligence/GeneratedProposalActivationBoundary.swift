import Foundation

/// T18.3.4 — live proposal boundary: canonical snapshot + situational synthesis (metadata-only).
enum GeneratedProposalActivationBoundary {

	struct Prepared: Equatable, Sendable {
		let snapshot: CanonicalGeneratedExecutionContextSnapshot
		let situational: SituationalContextSnapshot
	}

	/// Builds situational context and emits `[SituationalContext]` exactly once per call.
	static func prepare(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date = Date()
	) -> Prepared {
		let situational = SituationalContextSynthesizer.synthesize(
			from: snapshot,
			referenceTime: referenceTime
		)
		SituationalContextDiagnostics.log(situational)
		return Prepared(snapshot: snapshot, situational: situational)
	}
}

/// Metadata-only skip/attempt diagnostics for generated proposal activation (T18.3.4).
enum GeneratedProposalActivationDiagnostics {

	static func logAttemptStarted(triggerType: String, fusedPacket: Bool) {
		print(
			"[GeneratedProposal] attempt_started trigger=\(triggerType) fused_packet=\(fusedPacket ? "yes" : "no")"
		)
	}

	static func logSkip(phase: String, detail: String) {
		let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty {
			print("[GeneratedProposal] activation_skipped phase=\(phase)")
		} else {
			print("[GeneratedProposal] activation_skipped phase=\(phase) detail=\(trimmed)")
		}
	}

	static func logOutcome(
		llmResult: DynamicGeneratedProposalResult,
		candidateCount: Int,
		visibleCount: Int,
		situational: SituationalContextSnapshot
	) {
		if visibleCount > 0 {
			print(
				"[GeneratedProposal] activation_complete llm=\(llmResult.status.rawValue) candidates=\(candidateCount) visible=\(visibleCount) primary=\(situational.primaryAvailableSource.rawValue)"
			)
			return
		}
		let phase = skipPhase(llmResult: llmResult, candidateCount: candidateCount, visibleCount: visibleCount)
		logSkip(phase: phase, detail: "llm=\(llmResult.status.rawValue) candidates=\(candidateCount)")
	}

	private static func skipPhase(
		llmResult: DynamicGeneratedProposalResult,
		candidateCount: Int,
		visibleCount: Int
	) -> String {
		if let cause = llmResult.llmDiagnosticCause {
			return cause.rawValue
		}
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
			return candidateCount == 0 ? "skipped_after_situational_synthesis" : "candidates_suppressed"
		case .synthesized:
			if candidateCount == 0 { return "no_candidates" }
			if visibleCount == 0 { return "candidates_suppressed" }
			return "no_visible_proposals"
		}
	}
}
