import Foundation

// MARK: - Factors

/// All inputs the chime-in policy uses to make a surface decision.
/// Deterministic and metadata-only — no raw context, no LLM calls.
struct ContextualChimeInFactors: Sendable {
	/// User explicitly invoked the assistant (highest priority bypass signal).
	let isManualInvocation: Bool
	let workflowType: WorkflowType
	let workflowConfidence: Double
	/// True when selected text or usable OCR excerpt is present (richer than metadata-only).
	let hasRichContext: Bool
	/// Total generated proposals the activation surface wants to show.
	let proposalCount: Int
	/// Highest ranking score from activated proposals (0–1).
	let topProposalScore: Double
	/// Highest interruption cost across visible proposals (0–1).
	let topInterruptionCost: Double
	/// Seconds since last explicit dismissal, or nil if no recent dismissal.
	let recentDismissalInSeconds: Double?
	/// Seconds since last accepted proposal, or nil if no recent accept.
	let recentAcceptInSeconds: Double?
	/// 0 = recently repeated proposal (suppress / lower score); 1 = fully novel.
	let noveltyScore: Double
	/// An action is currently executing — suppress new proposals.
	let isActionExecuting: Bool
	/// Context freshness is weak (stale clipboard-only or unknown workflow).
	let isContextStale: Bool
	/// Recently surfaced a visual-enriched proposal (allow with higher confidence).
	let visualContextWasRecentlyEnriched: Bool
}

// MARK: - Decision

/// Outcome of the chime-in policy evaluation.
struct ContextualChimeInDecision: Sendable {

	enum SurfaceMode: String, Sendable {
		/// Do not show anything.
		case suppress
		/// Show in the panel only (no floating suggestion).
		case panelOnly
		/// Allow floating suggestion plus panel.
		case floatingSuggestion
	}

	let mode: SurfaceMode
	/// True when proposals may be surfaced at all.
	var shouldSurface: Bool { mode != .suppress }
	/// Aggregate policy score (0–1); informational only.
	let score: Double
	/// Human-readable reason codes for logs / debug UI.
	let reasons: [String]
	/// Optional soft cooldown hint (UI may use to delay re-evaluation).
	let cooldownRecommendation: TimeInterval?
}

// MARK: - Policy

/// Deterministic, stateless chime-in policy (T18.5).
///
/// Decides when and how to surface generated proposals based on context richness,
/// workflow confidence, interruption cost, novelty, and user activity state.
///
/// Rules:
/// - Manual invocation → always allow panel; allow floating when score is decent.
/// - Already executing → suppress everything.
/// - Context stale + no rich context → suppress unless manual.
/// - Recent dismissal within 60s → suppress; 60-180s → panel only.
/// - Repeated proposal (novelty < 0.3) → suppress.
/// - Proposal score below 0.42 → suppress.
/// - Proposal score 0.42-0.52 → panel only.
/// - Proposal score ≥ 0.52, good confidence → floating eligible.
enum ContextualChimeInPolicy {

	// MARK: - Thresholds (named for legibility)

	private static var suppressScoreFloor: Double {
		AgenticPivot.useEarlierProposalSurfacing ? 0.35 : 0.40
	}
	private static var panelOnlyScoreFloor: Double {
		AgenticPivot.useEarlierProposalSurfacing ? 0.42 : 0.48
	}
	private static var noveltySuppress: Double {
		AgenticPivot.useEarlierProposalSurfacing ? 0.05 : 0.12
	}
	private static let noveltyPenaltyThreshold: Double = 0.55  // T18.6: loosened from 0.65
	private static var dismissalHardSuppress: TimeInterval {
		AgenticPivot.useEarlierProposalSurfacing ? 30 : 60
	}
	private static var dismissalSoftSuppress: TimeInterval {
		AgenticPivot.useEarlierProposalSurfacing ? 90 : 180
	}
	private static let acceptedBoost: Double = 0.06

	static func evaluate(factors: ContextualChimeInFactors) -> ContextualChimeInDecision {
		var reasons: [String] = []
		var score: Double = 0

		// --- Hard gates (immediate suppress) ---

		if factors.isActionExecuting {
			return suppress(reason: "action_executing", score: 0, cooldown: nil)
		}

		if factors.proposalCount == 0 {
			return suppress(reason: "no_proposals", score: 0, cooldown: nil)
		}

		// --- Manual invocation (strong bypass) ---

		if factors.isManualInvocation {
			reasons.append("manual_invocation")
			// Manual always surfaces panel; floating needs a decent score.
			let floatingEligible = factors.topProposalScore >= panelOnlyScoreFloor
			let mode: ContextualChimeInDecision.SurfaceMode = floatingEligible ? .floatingSuggestion : .panelOnly
			return ContextualChimeInDecision(
				mode: mode,
				score: max(0.65, factors.topProposalScore),
				reasons: reasons + ["manual_bypass"],
				cooldownRecommendation: nil
			)
		}

		// --- Novelty gate ---

		if factors.noveltyScore < noveltySuppress {
			return suppress(reason: "repeated_low_novelty", score: factors.noveltyScore, cooldown: 120)
		}

		let isLowNovelty = factors.noveltyScore < noveltyPenaltyThreshold

		// --- Recent dismissal gates ---

		if let dismissalAge = factors.recentDismissalInSeconds {
			if dismissalAge < dismissalHardSuppress {
				return suppress(reason: "recent_dismissal_hard", score: 0.1, cooldown: dismissalHardSuppress - dismissalAge)
			}
			if dismissalAge < dismissalSoftSuppress {
				reasons.append("recent_dismissal_soft")
				// Soft: allow panel only, reduced score.
				score -= 0.12
			}
		}

		// --- Stale context gate ---

		if factors.isContextStale && !factors.hasRichContext {
			// Stale AND no rich text → strongly prefer silence.
			reasons.append("stale_no_rich_context")
			score -= 0.18
		}

		// --- Base score from proposal ranking ---

		score += factors.topProposalScore

		// --- Workflow confidence adjustment ---

		if factors.workflowConfidence < 0.3 {
			reasons.append("low_workflow_confidence")
			score -= 0.08
		} else if factors.workflowConfidence >= 0.65 {
			reasons.append("good_workflow_confidence")
			score += 0.04
		}

		// --- Context richness boost ---

		if factors.hasRichContext {
			reasons.append("rich_context")
			score += 0.05
		}

		// --- Visual enrichment boost ---

		if factors.visualContextWasRecentlyEnriched {
			reasons.append("visual_enriched")
			score += 0.06
		}

		// --- Novelty adjustment ---

		if factors.noveltyScore < noveltyPenaltyThreshold {
			let penalty = (noveltyPenaltyThreshold - factors.noveltyScore) * 0.15
			reasons.append("novelty_penalty")
			score -= penalty
		}

		// --- Recent accept boost ---

		if let acceptAge = factors.recentAcceptInSeconds, acceptAge < 300 {
			reasons.append("recent_accept")
			score += acceptedBoost
		}

		// --- Interruption cost adjustment ---

		if factors.topInterruptionCost > 0.55 {
			reasons.append("high_interruption_cost")
			score -= 0.06
		}

		score = max(0, min(1, score))

		// --- Final mode decision ---

		if score < suppressScoreFloor {
			return suppress(reason: reasons.isEmpty ? "low_score" : reasons.joined(separator: ","), score: score, cooldown: 30)
		}

		let floatingEligible = score >= panelOnlyScoreFloor
			&& factors.topInterruptionCost < 0.5
			&& factors.workflowConfidence >= 0.28  // T18.6B: relaxed from 0.35 — browsing often has moderate confidence
			&& !factors.isContextStale
			&& !isLowNovelty

		reasons.append(floatingEligible ? "floating_eligible" : "panel_only")
		let mode: ContextualChimeInDecision.SurfaceMode = floatingEligible ? .floatingSuggestion : .panelOnly
		return ContextualChimeInDecision(mode: mode, score: score, reasons: reasons, cooldownRecommendation: nil)
	}

	// MARK: - Self-test (lightweight, no I/O)

	static func runSelfTest() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let baseFactors = ContextualChimeInFactors(
			isManualInvocation: false,
			workflowType: .browsing,
			workflowConfidence: 0.65,
			hasRichContext: true,
			proposalCount: 2,
			topProposalScore: 0.58,
			topInterruptionCost: 0.22,
			recentDismissalInSeconds: nil,
			recentAcceptInSeconds: nil,
			noveltyScore: 1.0,
			isActionExecuting: false,
			isContextStale: false,
			visualContextWasRecentlyEnriched: false
		)

		// Good context → should surface panel at minimum.
		let good = evaluate(factors: baseFactors)
		check("good_context_surfaces", good.shouldSurface)

		// Executing → suppress.
		var executing = baseFactors
		executing = ContextualChimeInFactors(
			isManualInvocation: false, workflowType: .browsing, workflowConfidence: 0.65,
			hasRichContext: true, proposalCount: 2, topProposalScore: 0.65,
			topInterruptionCost: 0.22, recentDismissalInSeconds: nil, recentAcceptInSeconds: nil,
			noveltyScore: 1.0, isActionExecuting: true, isContextStale: false,
			visualContextWasRecentlyEnriched: false
		)
		check("executing_suppresses", evaluate(factors: executing).mode == .suppress)

		// No proposals → suppress.
		let noProposals = ContextualChimeInFactors(
			isManualInvocation: false, workflowType: .browsing, workflowConfidence: 0.5,
			hasRichContext: false, proposalCount: 0, topProposalScore: 0,
			topInterruptionCost: 0, recentDismissalInSeconds: nil, recentAcceptInSeconds: nil,
			noveltyScore: 1.0, isActionExecuting: false, isContextStale: false,
			visualContextWasRecentlyEnriched: false
		)
		check("no_proposals_suppresses", evaluate(factors: noProposals).mode == .suppress)

		// Manual invocation → always surfaces.
		let manual = ContextualChimeInFactors(
			isManualInvocation: true, workflowType: .unknown, workflowConfidence: 0.1,
			hasRichContext: false, proposalCount: 1, topProposalScore: 0.3,
			topInterruptionCost: 0.8, recentDismissalInSeconds: 10, recentAcceptInSeconds: nil,
			noveltyScore: 0.1, isActionExecuting: false, isContextStale: true,
			visualContextWasRecentlyEnriched: false
		)
		check("manual_always_surfaces", evaluate(factors: manual).shouldSurface)

		// Very recent dismissal → suppress.
		let dismissed = ContextualChimeInFactors(
			isManualInvocation: false, workflowType: .browsing, workflowConfidence: 0.6,
			hasRichContext: true, proposalCount: 2, topProposalScore: 0.65,
			topInterruptionCost: 0.2, recentDismissalInSeconds: 15, recentAcceptInSeconds: nil,
			noveltyScore: 1.0, isActionExecuting: false, isContextStale: false,
			visualContextWasRecentlyEnriched: false
		)
		check("recent_dismissal_hard_suppresses", evaluate(factors: dismissed).mode == .suppress)

		// Near-zero novelty → suppress (T18.6: threshold is 0.12, so use 0.08).
		let repeated = ContextualChimeInFactors(
			isManualInvocation: false, workflowType: .browsing, workflowConfidence: 0.6,
			hasRichContext: true, proposalCount: 2, topProposalScore: 0.65,
			topInterruptionCost: 0.2, recentDismissalInSeconds: nil, recentAcceptInSeconds: nil,
			noveltyScore: 0.08, isActionExecuting: false, isContextStale: false,
			visualContextWasRecentlyEnriched: false
		)
		check("low_novelty_suppresses", evaluate(factors: repeated).mode == .suppress)

		// Low novelty (but not near-zero) → panel only (T18.6B).
		let lowNovelty = ContextualChimeInFactors(
			isManualInvocation: false, workflowType: .browsing, workflowConfidence: 0.6,
			hasRichContext: true, proposalCount: 2, topProposalScore: 0.65,
			topInterruptionCost: 0.2, recentDismissalInSeconds: nil, recentAcceptInSeconds: nil,
			noveltyScore: 0.35, isActionExecuting: false, isContextStale: false,
			visualContextWasRecentlyEnriched: false
		)
		let lnRes = evaluate(factors: lowNovelty)
		check("low_novelty_panel_only", lnRes.mode == .panelOnly && lnRes.shouldSurface)

		// High score + good context → floating eligible.
		let highScore = ContextualChimeInFactors(
			isManualInvocation: false, workflowType: .debugging, workflowConfidence: 0.75,
			hasRichContext: true, proposalCount: 3, topProposalScore: 0.72,
			topInterruptionCost: 0.2, recentDismissalInSeconds: nil, recentAcceptInSeconds: nil,
			noveltyScore: 1.0, isActionExecuting: false, isContextStale: false,
			visualContextWasRecentlyEnriched: true
		)
		check("high_score_floating", evaluate(factors: highScore).mode == .floatingSuggestion)

		if !failures.isEmpty {
			print("[ChimeInPolicy] self_test FAILED: \(failures.joined(separator: ", "))")
		}
		return failures.isEmpty
	}

	// MARK: - Private helpers

	private static func suppress(reason: String, score: Double, cooldown: TimeInterval?) -> ContextualChimeInDecision {
		ContextualChimeInDecision(mode: .suppress, score: score, reasons: [reason], cooldownRecommendation: cooldown)
	}
}

// Allow ContextualChimeInFactors mutation in tests via memberwise.
private extension ContextualChimeInFactors {
	init(copying other: ContextualChimeInFactors, isActionExecuting: Bool) {
		self.init(
			isManualInvocation: other.isManualInvocation,
			workflowType: other.workflowType,
			workflowConfidence: other.workflowConfidence,
			hasRichContext: other.hasRichContext,
			proposalCount: other.proposalCount,
			topProposalScore: other.topProposalScore,
			topInterruptionCost: other.topInterruptionCost,
			recentDismissalInSeconds: other.recentDismissalInSeconds,
			recentAcceptInSeconds: other.recentAcceptInSeconds,
			noveltyScore: other.noveltyScore,
			isActionExecuting: isActionExecuting,
			isContextStale: other.isContextStale,
			visualContextWasRecentlyEnriched: other.visualContextWasRecentlyEnriched
		)
	}
}
