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

// MARK: - Failure reason enum (T18.3.3D)

enum GeneratedProposalFailureReason: String, Sendable, CaseIterable {
	case modelUnavailable
	case modelStartupGrace
	case modelTimeout
	case modelClientFailed
	case parseNoJSONObject
	case parseMalformedJSON
	case parseMissingRequiredKey
	case parseUnknownPrimitivesOnly
	case parseConfidenceTooLow
	case parseGenericRejected
	case modelChoseNoChime
	case insufficientContext
	case visualContextRecommended
	case allCandidatesSuppressed
	case rankingSuppressed
	case contextChanged
	case staleGeneration
	case noTemplateInLibrary

	var userFacingLabel: String {
		switch self {
		case .modelUnavailable:           return "model not available"
		case .modelStartupGrace:          return "model starting up — try again shortly"
		case .modelTimeout:               return "LLM timed out — need a faster model"
		case .modelClientFailed:          return "LLM request failed"
		case .parseNoJSONObject:          return "LLM returned non-JSON output"
		case .parseMalformedJSON:         return "LLM returned malformed JSON"
		case .parseMissingRequiredKey:    return "missing required key in proposal"
		case .parseUnknownPrimitivesOnly: return "unknown primitives only"
		case .parseConfidenceTooLow:      return "confidence too low"
		case .parseGenericRejected:       return "generic proposal rejected"
		case .modelChoseNoChime:          return "model chose not to chime in"
		case .insufficientContext:        return "insufficient context"
		case .visualContextRecommended:   return "visual context recommended"
		case .allCandidatesSuppressed:    return "generated candidate suppressed"
		case .rankingSuppressed:          return "proposal suppressed by ranking"
		case .contextChanged:             return "large model cooling down after timeout"
		case .staleGeneration:            return "stale generation"
		case .noTemplateInLibrary:        return "no action template in library — prewarm queued"
		}
	}
}

// MARK: - Debug status (metadata only)

struct GeneratedProposalDebugStatus: Equatable, Sendable {
	let attempted: Bool
	let llmOutcome: String
	let candidateCount: Int
	let visibleCount: Int
	let zeroVisibleReason: String?
	let failureReason: GeneratedProposalFailureReason?
	let failureDetail: String?
	let contextSourceUsed: String
	let staticFallbackSuppressed: Bool
	let updatedAt: Date

	static let idle = GeneratedProposalDebugStatus(
		attempted: false,
		llmOutcome: "not_attempted",
		candidateCount: 0,
		visibleCount: 0,
		zeroVisibleReason: "not_attempted",
		failureReason: nil,
		failureDetail: nil,
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

	var pipelineStatusLine: String {
		var parts = [
			"attempted=\(attempted ? "yes" : "no")",
			"LLM=\(llmOutcome)",
			"candidates=\(candidateCount)",
			"visible=\(visibleCount)",
		]
		if let fr = failureReason {
			parts.append("failure=\(fr.rawValue)")
			if let detail = failureDetail { parts.append("detail=\(detail)") }
		} else if visibleCount > 0 {
			parts.append("failure=none")
		}
		return "[GeneratedProposalStatus] \(parts.joined(separator: " "))"
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
		let (failureReason, failureDetail) = visible == 0
			? resolveFailureReason(llmResult: llmResult, activation: activation, situational: situational)
			: (nil, nil)

		return GeneratedProposalDebugStatus(
			attempted: true,
			llmOutcome: llmOutcome,
			candidateCount: llmCandidates.count,
			visibleCount: visible,
			zeroVisibleReason: zeroReason,
			failureReason: failureReason,
			failureDetail: failureDetail,
			contextSourceUsed: situational.primaryAvailableSource.rawValue,
			staticFallbackSuppressed: DynamicOnlyProposalMode.isEnabled,
			updatedAt: referenceTime
		)
	}

	private static func llmOutcomeLabel(_ result: DynamicGeneratedProposalResult) -> String {
		if let cause = result.llmDiagnosticCause {
			return cause.rawValue
		}
		switch result.status {
		case .synthesized: return result.shouldChimeIn ? "success" : "success_quiet"
		case .quietByGate: return "gated"
		case .modelUnavailable: return "unavailable"
		case .parseFailed: return "parse_failed"
		case .timeout: return "timeout"
		case .cancelled: return "cancelled"
		}
	}

	private static func resolveZeroReason(
		llmResult: DynamicGeneratedProposalResult,
		activation: GeneratedExecutionProposalActivationResult,
		situational: SituationalContextSnapshot
	) -> String {
		switch llmResult.status {
		case .modelUnavailable:
			if let cause = llmResult.llmDiagnosticCause, cause == .startupGrace { return "model_startup_grace" }
			return "llm_unavailable"
		case .timeout:
			return "llm_timeout"
		case .parseFailed:
			// Prefer exact diag tag if engine stamped one.
			if let tag = llmResult.warnings.first(where: { $0.hasPrefix("diag:") }) {
				return tag
			}
			return "parse_failed"
		case .cancelled:
			return "cancelled"
		case .quietByGate:
			// Check for precise diag tags from decision stage or parser.
			if let tag = llmResult.warnings.first(where: { $0.hasPrefix("diag:") }) {
				return tag
			}
			if llmResult.warnings.contains("stale_context") { return "weak_context" }
			if llmResult.reason == "gated" { return "weak_context" }
			return llmResult.reason.isEmpty ? "weak_context" : llmResult.reason
		case .synthesized:
			break
		}

		// Check for soft parse diag tags embedded in synthesized result warnings.
		if let tag = llmResult.warnings.first(where: { $0.hasPrefix("diag:") }) {
			return tag
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

	// MARK: - Exact failure reason resolution (T18.3.3D)

	private static func resolveFailureReason(
		llmResult: DynamicGeneratedProposalResult,
		activation: GeneratedExecutionProposalActivationResult,
		situational: SituationalContextSnapshot
	) -> (GeneratedProposalFailureReason?, String?) {
		// Engine-stamped diag tags take priority (most precise).
		let diagTag = llmResult.warnings.first(where: { $0.hasPrefix("diag:") })
		if let tag = diagTag {
			return (failureReasonFromDiagTag(tag), detailFromDiagTag(tag))
		}

		switch llmResult.status {
		case .modelUnavailable:
			if let cause = llmResult.llmDiagnosticCause {
				switch cause {
				case .startupGrace:     return (.modelStartupGrace, nil)
				case .appTimeout:       return (.modelTimeout, nil)
				case .clientFailed:     return (.modelClientFailed, nil)
				default:                return (.modelUnavailable, cause.rawValue)
				}
			}
			return (.modelUnavailable, nil)
		case .timeout:
			return (.modelTimeout, nil)
		case .parseFailed:
			return (.parseMalformedJSON, nil)
		case .cancelled:
			return (nil, nil)
		case .quietByGate:
			if llmResult.warnings.contains("stale_context") || llmResult.warnings.contains("no_fused_context") {
				return (.insufficientContext, nil)
			}
			return (.insufficientContext, llmResult.reason.isEmpty ? nil : llmResult.reason)
		case .synthesized:
			break
		}

		if activation.suppressedGeneratedCount > 0, activation.visibleProposals.isEmpty {
			return (.allCandidatesSuppressed, nil)
		}

		if !llmResult.shouldChimeIn {
			return (.modelChoseNoChime, nil)
		}

		return (.allCandidatesSuppressed, nil)
	}

	private static func failureReasonFromDiagTag(_ tag: String) -> GeneratedProposalFailureReason? {
		let body = tag.hasPrefix("diag:") ? String(tag.dropFirst(5)) : tag
		// Strip any ":detail" suffix for matching.
		let base = body.components(separatedBy: ":").first ?? body
		switch base {
		// Parser-stage tags
		case "parse_no_json":          return .parseNoJSONObject
		case "parse_decode_failed":    return .parseMalformedJSON
		case "parse_missing_key":      return .parseMissingRequiredKey
		case "parse_unknown_primitives": return .parseUnknownPrimitivesOnly
		case "parse_confidence_too_low": return .parseConfidenceTooLow
		case "parse_generic_rejected": return .parseGenericRejected
		case "parse_no_chime":         return .modelChoseNoChime
		case "parse_visual_recommended": return .visualContextRecommended
		// Decision-stage tags (T18.3.4)
		case "decision_needs_more_context":
			// detail segment distinguishes visual vs generic context need
			let detail = body.components(separatedBy: ":").dropFirst().first ?? ""
			return detail == "visual" ? .visualContextRecommended : .insufficientContext
		case "decision_timeout_cooldown": return .contextChanged
		case "decision_quiet":         return .modelChoseNoChime
		// Library-layer tags (T18.3.5)
		case "no_template_in_library": return .noTemplateInLibrary
		default:                       return nil
		}
	}

	private static func detailFromDiagTag(_ tag: String) -> String? {
		// Tags like "diag:parse_missing_key:title" carry an extra detail segment.
		let parts = tag.components(separatedBy: ":")
		guard parts.count >= 3 else { return nil }
		return parts[2]
	}

	// MARK: - Test-only helpers (expose private mapping for self-test verification)

	static func failureReasonForTag_testOnly(_ tag: String) -> GeneratedProposalFailureReason? {
		failureReasonFromDiagTag(tag)
	}

	static func failureReasonAndDetailForTag_testOnly(_ tag: String) -> (GeneratedProposalFailureReason?, String?) {
		(failureReasonFromDiagTag(tag), detailFromDiagTag(tag))
	}

}

/// Central configuration for the Phase 4A Agentic Runtime Pivot.
/// These flags control the shift from fixed hook-chain planning to bounded agentic workflows.
enum AgenticPivot {
    
    // MARK: - Part 1: Transient Context Suppression
    
    /// Disables the influence of clipboard text on proposal generation and ranking.
    static let isClipboardInfluenceEnabled = false
    
    /// Disables the influence of selected text on proposal generation and ranking.
    static let isSelectedTextInfluenceEnabled = false
    
    // MARK: - Part 2 & 3: Planning Pivot
    
    /// Whether the planner should prioritize high-level intent over detailed hook chains.
    static let useIntentFirstPlanning = true
    
    /// Whether all proposals should be routed through the unified bounded agentic runtime.
    static let useUnifiedAgenticRuntime = true
    
    // MARK: - Part 4: Surfacing & Persistence
    
    /// Whether proposals should surface earlier (e.g., bypassing some heuristic stability gates).
    static let useEarlierProposalSurfacing = true
    
    /// Whether proposals should remain visible longer (e.g., briefly surviving tab switches).
    static let usePersistentProposals = true
    
    // MARK: - Helpers
    
    static func logPivotState() {
        print("[AgenticPivot] state: clipboard_influence=\(isClipboardInfluenceEnabled) selected_text_influence=\(isSelectedTextInfluenceEnabled) intent_first=\(useIntentFirstPlanning) unified_runtime=\(useUnifiedAgenticRuntime) early_surfacing=\(useEarlierProposalSurfacing) persistence=\(usePersistentProposals)")
    }
}
