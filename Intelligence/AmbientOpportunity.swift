import Foundation

// MARK: - Types

public enum AmbientOpportunityType: String, Sendable, Codable, CaseIterable {
    case offer_music
    case offer_focus_mode
    case offer_summary
    case offer_quiz
    case offer_notes
    case offer_break
    case offer_debug_help
    case offer_compare
    case offer_draft_reply
    case offer_cleanup_tabs
}

/// An internal opportunity signal. **Not a user-facing suggestion.**
/// Phase B logs these so we can evaluate before any UI ever surfaces them.
public struct AmbientOpportunity: Sendable, Codable, Equatable {
    public let opportunityType: AmbientOpportunityType
    public let workflowType: AmbientWorkflowType
    public let confidence: Double
    public let whyNow: String
    public let requiredCapabilities: [String]
    public let suggestedActionFamily: String
    public let interruptiveness: Double   // 0..1, higher = more disruptive
    public let cooldownKey: String
}

// MARK: - Detector

/// Maps `WorkflowState` + temporal signals to internal opportunities.
///
/// **Important:** rules here are signal-driven (duration, stability, repeated
/// topic counts, transition counts), NOT app-name driven. The workflow label
/// itself is the only structural prior — and that label was inferred by the
/// model, not by string-matching app names.
public enum AmbientOpportunityDetector {

    /// Default cooldown — opportunities of the same kind are suppressed for
    /// this many seconds after the last one was emitted (logged-only).
    public static let cooldownSeconds: TimeInterval = 600

    public static func detect(
        state: WorkflowState,
        packet: CompressedTemporalPacket,
        cooldowns: [String: Date],
        now: Date = Date()
    ) -> [AmbientOpportunity] {

        // Universal gates: only consider opportunities for stable, established
        // workflows. This is signal-based, NOT app-based.
        guard state.workflowType != .unknown else { return [] }
        let stableSession = state.stabilityScore >= 0.4 && state.durationSeconds >= 240

        var candidates: [AmbientOpportunity] = []

        switch state.workflowType {

        case .studying:
            // Stable + repeated topic terms over time → study aids.
            if stableSession && state.repeatedTerms.count >= 2 {
                candidates.append(make(
                    .offer_quiz, state,
                    confidence: blend(state.confidence, base: 0.5, weight: 0.3, cap: 0.9),
                    whyNow: "stable_studying_session_repeated_topics",
                    caps: ["summarize", "question_generation"],
                    family: "extract",
                    interruptiveness: 0.3
                ))
                candidates.append(make(
                    .offer_notes, state,
                    confidence: blend(state.confidence, base: 0.5, weight: 0.3, cap: 0.9),
                    whyNow: "stable_studying_session_repeated_topics",
                    caps: ["summarize"],
                    family: "summarize",
                    interruptiveness: 0.3
                ))
            }

        case .gaming:
            // Long stable session AND no media-app signal in the temporal packet.
            let hasMedia = packet.recentApps.contains { isMediaApp($0) }
            if stableSession && !hasMedia {
                candidates.append(make(
                    .offer_music, state,
                    confidence: blend(state.confidence, base: 0.5, weight: 0.3, cap: 0.85),
                    whyNow: "no_audio_long_session",
                    caps: ["media_metadata"],
                    family: "recommend",
                    interruptiveness: 0.2
                ))
            }

        case .debugging:
            // Look for sustained error-signal terms across the long window.
            let errorish = packet.topicTerms.filter {
                let t = $0.lowercased()
                return ["error", "build", "failed", "test", "exception", "stack", "trace", "crash"].contains(t)
            }
            if errorish.count >= 2 {
                candidates.append(make(
                    .offer_debug_help, state,
                    confidence: min(0.6 + Double(errorish.count) * 0.05, 0.9),
                    whyNow: "repeated_error_signals=\(errorish.count)",
                    caps: ["error_lookup", "summarize"],
                    family: "explain",
                    interruptiveness: 0.4
                ))
            }

        case .researching:
            // Many distinct titles + sustained topic terms.
            if state.recentTransitions.count >= 5 && state.repeatedTerms.count >= 2 {
                candidates.append(make(
                    .offer_summary, state,
                    confidence: blend(state.confidence, base: 0.5, weight: 0.3, cap: 0.85),
                    whyNow: "many_related_pages_repeated_topics",
                    caps: ["summarize"],
                    family: "summarize",
                    interruptiveness: 0.3
                ))
                if state.recentTransitions.count >= 8 {
                    candidates.append(make(
                        .offer_cleanup_tabs, state,
                        confidence: 0.55,
                        whyNow: "high_title_transition_count",
                        caps: ["tab_metadata"],
                        family: "cleanup",
                        interruptiveness: 0.2
                    ))
                }
            }

        case .shopping, .comparing:
            // Multiple related product-like contexts with shared terms.
            if state.repeatedTerms.count >= 2 && state.recentTransitions.count >= 3 {
                candidates.append(make(
                    .offer_compare, state,
                    confidence: blend(state.confidence, base: 0.55, weight: 0.3, cap: 0.85),
                    whyNow: "multiple_related_contexts_repeated_entities",
                    caps: ["compare", "summarize"],
                    family: "compare",
                    interruptiveness: 0.3
                ))
            }

        case .emailing:
            if stableSession {
                candidates.append(make(
                    .offer_draft_reply, state,
                    confidence: 0.6,
                    whyNow: "stable_email_session",
                    caps: ["draft", "summarize"],
                    family: "draft",
                    interruptiveness: 0.4
                ))
            }

        case .coding, .writing:
            // Very long, stable focused session — consider a break nudge.
            if state.durationSeconds >= 3600 && state.stabilityScore >= 0.6 {
                candidates.append(make(
                    .offer_break, state,
                    confidence: 0.55,
                    whyNow: "long_focused_session",
                    caps: [],
                    family: "nudge",
                    interruptiveness: 0.5
                ))
            }

        default:
            break
        }

        // Apply cooldowns. Always log emission AND the instrumentation-only block.
        var emitted: [AmbientOpportunity] = []
        for opp in candidates {
            if let last = cooldowns[opp.cooldownKey],
               now.timeIntervalSince(last) < cooldownSeconds {
                print("[AmbientOpportunity] suppressed reason=cooldown type=\(opp.opportunityType.rawValue)")
                continue
            }
            let confStr = String(format: "%.2f", opp.confidence)
            print("[AmbientOpportunity] type=\(opp.opportunityType.rawValue) workflow=\(opp.workflowType.rawValue) confidence=\(confStr) why_now=\(opp.whyNow)")
            print("[AmbientSuggestion] suppressed reason=phase_b_instrumentation_only")
            emitted.append(opp)
        }
        return emitted
    }

    // MARK: - Helpers

    private static func make(
        _ type: AmbientOpportunityType,
        _ state: WorkflowState,
        confidence: Double,
        whyNow: String,
        caps: [String],
        family: String,
        interruptiveness: Double
    ) -> AmbientOpportunity {
        AmbientOpportunity(
            opportunityType: type,
            workflowType: state.workflowType,
            confidence: confidence,
            whyNow: whyNow,
            requiredCapabilities: caps,
            suggestedActionFamily: family,
            interruptiveness: interruptiveness,
            cooldownKey: type.rawValue
        )
    }

    private static func blend(_ x: Double, base: Double, weight: Double, cap: Double) -> Double {
        min(base + x * weight, cap)
    }

    /// Conservative media-app heuristic — used only as a NEGATIVE signal for
    /// `offer_music` (we suppress the offer when audio is already playing).
    /// This is NOT a workflow classifier.
    private static func isMediaApp(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("music") || n.contains("spotify") ||
               n.contains("podcast") || n.contains("youtube")
    }
}
