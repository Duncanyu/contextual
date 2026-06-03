import Foundation

/// Phase 22.2 — Dynamic opportunity scoring (Task B).
///
/// Replaces the hardcoded domain→need→capability pipeline with a competitive
/// multi-factor scorer:
///
///   situation (entity + domain + mode + evidence + signals)
///     → score all registered capabilities
///     → multiply by novelty factor from OpportunityNoveltyTracker
///     → filter by threshold
///     → rank and return
///
/// No capability wins because of its domain alone. Multiple capabilities
/// compete: the one that best matches the combination of entity type, domain,
/// activity signals, and novelty wins.
///
/// create_next_steps has a deliberately low score cap (0.25) so it only appears
/// when no other specific capability qualifies.
///
/// Required logs: [OpportunityReasoner]
enum OpportunityReasoner {

    // MARK: - Candidate type

    struct Candidate {
        let capabilityId: String
        let need: Need
        let usefulnessScore: Double    // entity + domain + signal relevance
        let evidenceScore: Double      // how well evidence supports execution
        let noveltyScore: Double       // from OpportunityNoveltyTracker
        let actionabilityScore: Double // can we meaningfully execute now?
        let reason: String

        /// Composite rank score — novelty is weighted strongly to prevent repetition.
        var finalScore: Double {
            let usefulness = min(usefulnessScore, 1.0)
            let evidence   = min(evidenceScore,   1.0)
            let novelty    = min(noveltyScore,     1.0)
            let action     = min(actionabilityScore, 1.0)
            // Novelty acts as a multiplicative gate — a stale suggestion is strongly penalised
            return (usefulness * 0.45 + evidence * 0.25 + action * 0.15) * novelty + action * 0.15
        }
    }

    // MARK: - Situation context

    struct Situation {
        let entityType: EntityGrounding.EntityType
        let entityConfidence: Double
        let domain: DeterminerSignal.Domain
        let mode: DeterminerSignal.Mode
        let evidenceQuality: String    // "title_only" | "browser_context" | "ax_content"
        let hasErrorTerms: Bool
        let hasMultipleSources: Bool
        let hasComparisonCandidates: Bool
        let isActivelyEditing: Bool    // typing mode
        let compartmentDwellSeconds: TimeInterval
        let entityKey: String          // cache key for novelty tracker
    }

    // MARK: - Minimum threshold for a candidate to survive

    private static let minimumFinalScore: Double = 0.18

    // MARK: - Entry point

    /// Score all capabilities against the situation and return ranked, novelty-filtered candidates.
    static func reason(
        situation: Situation,
        noveltyTracker: OpportunityNoveltyTracker
    ) -> [Candidate] {

        var candidates: [Candidate] = []
        // Track the capability with highest raw usefulness score (pre-novelty, pre-threshold)
        // so we can detect when it was suppressed by novelty in favour of a fresher capability.
        var preNoveltyBestId: String? = nil
        var preNoveltyBestRaw: Double = 0.0

        for capId in allCapabilityIds {
            var raw = rawScore(capId, situation: situation)

            // create_next_steps is strictly capped — never beats a specific capability
            if capId == "create_next_steps" {
                raw = min(raw, 0.25)
            }

            guard raw > 0.02 else { continue }  // skip irrelevant capabilities early

            // Track pre-novelty best (before novelty/threshold filtering)
            if raw > preNoveltyBestRaw {
                preNoveltyBestRaw = raw
                preNoveltyBestId  = capId
            }

            let novelty = noveltyTracker.noveltyScore(
                capabilityId: capId,
                entityKey: situation.entityKey
            )
            let evidence = evidenceScore(capId, situation: situation)
            let action   = actionabilityScore(capId, situation: situation)

            let candidate = Candidate(
                capabilityId: capId,
                need: needForCapability(capId),
                usefulnessScore: raw,
                evidenceScore: evidence,
                noveltyScore: novelty,
                actionabilityScore: action,
                reason: reasonString(capId, situation: situation)
            )

            if candidate.finalScore >= minimumFinalScore {
                candidates.append(candidate)
            } else {
                print("[OpportunityReasoner] rejected capability=\(capId)"
                    + " reason=below_threshold"
                    + " final_score=\(String(format: "%.3f", candidate.finalScore))"
                    + " novelty=\(String(format: "%.2f", novelty))")
            }
        }

        let sorted = candidates.sorted { $0.finalScore > $1.finalScore }
        let finalWinner = sorted.first

        // Detect novelty-driven suppression:
        // If the pre-novelty best capability is NOT the final winner, novelty redirected the top slot.
        if let preId = preNoveltyBestId, let fin = finalWinner, preId != fin.capabilityId {
            let preNovelty = noveltyTracker.noveltyScore(capabilityId: preId, entityKey: situation.entityKey)
            print("[OpportunityNovelty] suppressed_duplicate=yes"
                + " capability=\(preId)"
                + " novelty_score=\(String(format: "%.2f", preNovelty))")
            print("[OpportunityNovelty] alternative_selected=\(fin.capabilityId)"
                + " final_score=\(String(format: "%.3f", fin.finalScore))")
        } else if let preId = preNoveltyBestId, finalWinner == nil {
            // All candidates suppressed below threshold — no opportunity this tick
            let preNovelty = noveltyTracker.noveltyScore(capabilityId: preId, entityKey: situation.entityKey)
            if preNovelty < 0.20 {
                print("[OpportunityNovelty] suppressed_duplicate=yes"
                    + " capability=\(preId)"
                    + " novelty_score=\(String(format: "%.2f", preNovelty))")
                print("[OpportunityNovelty] no_alternative_available")
            }
        } else if let fin = finalWinner, fin.noveltyScore < 0.20 {
            // Same cap wins but with very low novelty
            print("[OpportunityNovelty] suppressed_duplicate=yes"
                + " capability=\(fin.capabilityId)"
                + " novelty_score=\(String(format: "%.2f", fin.noveltyScore))")
            print("[OpportunityNovelty] no_alternative_available")
        }

        // Log top candidates
        let topThree = sorted.prefix(3)
        let candStr = topThree.map {
            "\($0.capabilityId):\(String(format: "%.3f", $0.finalScore))"
        }.joined(separator: ",")
        print("[OpportunityReasoner] candidates=[\(candStr)]")

        for c in sorted {
            print("[OpportunityReasoner] selected capability=\(c.capabilityId)"
                + " reason=\(c.reason)"
                + " usefulness=\(String(format: "%.2f", c.usefulnessScore))"
                + " novelty=\(String(format: "%.2f", c.noveltyScore))"
                + " final=\(String(format: "%.3f", c.finalScore))")
            break  // only log the winner
        }

        // Log recently-shown for novelty transparency
        let recent = noveltyTracker.recentlyShown(entityKey: situation.entityKey)
        if !recent.isEmpty {
            print("[OpportunityNovelty] recent=[\(recent.joined(separator: ","))]")
        }

        return sorted
    }

    // MARK: - Raw usefulness score per capability

    /// Returns 0..1 raw usefulness before evidence and novelty modulation.
    /// This is the "how relevant is this capability given this situation" score.
    /// IMPORTANT: this is NOT a direct domain→capability map.
    /// Multiple capabilities are scored simultaneously and compete.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func rawScore(_ capId: String, situation s: Situation) -> Double {
        let e = s.entityType
        let d = s.domain

        switch capId {

        // ── Study / recall capabilities ───────────────────────────────────────

        case "generate_quiz":
            var v = entityScore(e, primary: [.course_material], secondary: [.document], primaryW: 0.72, secondaryW: 0.40)
            v += domainScore(d, primary: [.studying], secondary: [.researching], primaryW: 0.22, secondaryW: 0.10)
            if s.evidenceQuality == "ax_content" { v += 0.08 }
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .product]) ? 0 : v

        case "create_review_plan":
            var v = entityScore(e, primary: [.course_material], secondary: [.document], primaryW: 0.60, secondaryW: 0.35)
            v += domainScore(d, primary: [.studying], secondary: [.researching], primaryW: 0.20, secondaryW: 0.08)
            return blocked(e, [.tv_show, .youtube_video, .email_thread]) ? 0 : v

        case "create_flashcards":
            var v = entityScore(e, primary: [.course_material], secondary: [.document], primaryW: 0.68, secondaryW: 0.35)
            v += domainScore(d, primary: [.studying], primaryW: 0.20)
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .product]) ? 0 : v

        case "extract_key_terms":
            var v = entityScore(e, primary: [.course_material, .document], secondary: [.website], primaryW: 0.55, secondaryW: 0.30)
            v += domainScore(d, primary: [.studying, .researching], primaryW: 0.15)
            return blocked(e, [.tv_show, .youtube_video]) ? 0 : v

        case "make_study_schedule":
            var v = entityScore(e, primary: [.course_material], primaryW: 0.65)
            v += domainScore(d, primary: [.studying], primaryW: 0.18)
            return blocked(e, [.tv_show, .youtube_video, .code_project]) ? 0 : v

        case "explain_topic":
            var v = entityScore(e, primary: [.course_material, .document], secondary: [.code_project, .website], primaryW: 0.52, secondaryW: 0.28)
            v += domainScore(d, primary: [.studying, .researching, .coding], primaryW: 0.12)
            return blocked(e, [.tv_show, .youtube_video]) ? 0 : v

        case "create_study_outline":
            var v = entityScore(e, primary: [.course_material], secondary: [.document], primaryW: 0.62, secondaryW: 0.32)
            v += domainScore(d, primary: [.studying], primaryW: 0.18)
            return blocked(e, [.tv_show, .youtube_video, .email_thread]) ? 0 : v

        // ── Game / creative coding capabilities ───────────────────────────────

        case "generate_test_checklist":
            var v = entityScore(e, primary: [.code_project], primaryW: 0.72)
            v += domainScore(d, primary: [.creative_coding, .coding], primaryW: 0.20)
            if s.mode == .building { v += 0.08 }
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .product, .course_material]) ? 0 : v

        case "create_game_design_checklist":
            var v = entityScore(e, primary: [.code_project], primaryW: 0.68)
            v += domainScore(d, primary: [.creative_coding], secondary: [.coding], primaryW: 0.22, secondaryW: 0.08)
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .course_material]) ? 0 : v

        case "create_controls_polish_checklist":
            var v = entityScore(e, primary: [.code_project], primaryW: 0.62)
            v += domainScore(d, primary: [.creative_coding], secondary: [.coding], primaryW: 0.20, secondaryW: 0.06)
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .course_material]) ? 0 : v

        case "create_asset_sound_checklist":
            var v = entityScore(e, primary: [.code_project], primaryW: 0.58)
            v += domainScore(d, primary: [.creative_coding], secondary: [.coding], primaryW: 0.18, secondaryW: 0.05)
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .course_material]) ? 0 : v

        case "create_bug_reproduction_plan":
            var v = entityScore(e, primary: [.code_project], primaryW: 0.62)
            v += domainScore(d, primary: [.coding, .creative_coding], primaryW: 0.18)
            if s.hasErrorTerms { v += 0.18 }
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .course_material]) ? 0 : v

        case "suggest_next_feature":
            var v = entityScore(e, primary: [.code_project], primaryW: 0.55)
            v += domainScore(d, primary: [.creative_coding, .coding], primaryW: 0.15)
            if s.compartmentDwellSeconds > 300 { v += 0.10 } // established session
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .course_material]) ? 0 : v

        // ── Coding / debugging capabilities ──────────────────────────────────

        case "diagnose_error":
            var v = entityScore(e, primary: [.code_project], primaryW: 0.62)
            v += domainScore(d, primary: [.coding, .creative_coding], primaryW: 0.15)
            if s.hasErrorTerms { v += 0.25 }  // error terms strongly boost this
            return blocked(e, [.tv_show, .youtube_video, .email_thread]) ? 0 : v

        case "debug_performance":
            var v = entityScore(e, primary: [.code_project], primaryW: 0.58)
            v += domainScore(d, primary: [.coding, .creative_coding], primaryW: 0.15)
            return blocked(e, [.tv_show, .youtube_video, .email_thread]) ? 0 : v

        case "explain_code_context":
            var v = entityScore(e, primary: [.code_project], secondary: [.document], primaryW: 0.55, secondaryW: 0.22)
            v += domainScore(d, primary: [.coding, .creative_coding], primaryW: 0.15)
            return blocked(e, [.tv_show, .youtube_video, .email_thread]) ? 0 : v

        case "suggest_refactor_plan":
            var v = entityScore(e, primary: [.code_project], primaryW: 0.52)
            v += domainScore(d, primary: [.coding, .creative_coding], primaryW: 0.12)
            if s.compartmentDwellSeconds > 600 { v += 0.08 } // refactoring is for settled sessions
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .course_material]) ? 0 : v

        // ── Research / synthesis capabilities ─────────────────────────────────

        case "synthesize_sources":
            var v = entityScore(e, primary: [.document], secondary: [.course_material, .website], primaryW: 0.55, secondaryW: 0.38)
            v += domainScore(d, primary: [.researching], secondary: [.studying, .browsing], primaryW: 0.22, secondaryW: 0.08)
            if s.hasMultipleSources { v += 0.20 }
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .product]) ? 0 : v

        case "extract_open_questions":
            var v = entityScore(e, primary: [.document, .course_material], secondary: [.website], primaryW: 0.52, secondaryW: 0.28)
            v += domainScore(d, primary: [.researching, .studying], primaryW: 0.18)
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .product]) ? 0 : v

        case "create_research_outline":
            var v = entityScore(e, primary: [.document], secondary: [.course_material, .website], primaryW: 0.50, secondaryW: 0.30)
            v += domainScore(d, primary: [.researching], secondary: [.studying], primaryW: 0.20, secondaryW: 0.08)
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .product, .code_project]) ? 0 : v

        case "summarize_reference":
            var v = entityScore(e, primary: [.document], secondary: [.course_material, .website], primaryW: 0.68, secondaryW: 0.38)
            v += domainScore(d, primary: [.researching, .studying, .browsing], primaryW: 0.15)
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .product]) ? 0 : v

        // ── Shopping / comparison capabilities ────────────────────────────────

        case "compare_options":
            var v = entityScore(e, primary: [.product], secondary: [.website], primaryW: 0.70, secondaryW: 0.30)
            v += domainScore(d, primary: [.shopping], secondary: [.researching], primaryW: 0.22, secondaryW: 0.08)
            if s.hasComparisonCandidates { v += 0.20 }
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .code_project, .course_material]) ? 0 : v

        case "decision_matrix":
            var v = entityScore(e, primary: [.product], primaryW: 0.62)
            v += domainScore(d, primary: [.shopping], primaryW: 0.20)
            if s.hasComparisonCandidates { v += 0.15 }
            return blocked(e, [.tv_show, .youtube_video, .email_thread, .code_project, .course_material]) ? 0 : v

        case "summarize_context":
            var v = entityScore(e, primary: [.product, .website], secondary: [.document], primaryW: 0.40, secondaryW: 0.28)
            v += domainScore(d, primary: [.shopping, .browsing], primaryW: 0.12)
            return blocked(e, [.tv_show, .youtube_video, .email_thread]) ? 0 : v

        // ── Communication capabilities ────────────────────────────────────────

        case "draft_reply":
            var v = entityScore(e, primary: [.email_thread], primaryW: 0.78)
            v += domainScore(d, primary: [.communicating], primaryW: 0.20)
            if s.isActivelyEditing { v += 0.08 }
            return blocked(e, [.tv_show, .youtube_video, .code_project, .course_material, .product]) ? 0 : v

        case "extract_action_items":
            var v = entityScore(e, primary: [.email_thread], secondary: [.document], primaryW: 0.68, secondaryW: 0.38)
            v += domainScore(d, primary: [.communicating], secondary: [.researching], primaryW: 0.18, secondaryW: 0.08)
            return blocked(e, [.tv_show, .youtube_video, .code_project, .product]) ? 0 : v

        // ── Generic fallback — severely capped ───────────────────────────────
        // create_next_steps is the last resort. It NEVER beats any specific capability.
        // Its raw score is artificially capped at 0.25 in reason().

        case "create_next_steps":
            // Only relevant when there's an active, productive context
            var v: Double = 0.0
            if [.coding, .creative_coding, .studying, .working, .researching].contains(d) { v += 0.18 }
            if [.code_project, .course_material, .document].contains(e) { v += 0.10 }
            if s.compartmentDwellSeconds > 120 { v += 0.05 }  // some context established
            // Blocked entirely for entertainment and unknown contexts
            if blocked(e, [.tv_show, .youtube_video, .unknown, .website]) { return 0 }
            if d == .unknown || d == .browsing || d == .watching { return 0 }
            if s.evidenceQuality == "title_only" { v *= 0.4 }  // weak evidence → further dampen
            return v  // will be capped to 0.25 in reason()

        default:
            return 0.0
        }
    }

    // MARK: - Evidence score

    private static func evidenceScore(_ capId: String, situation s: Situation) -> Double {
        let eq = s.evidenceQuality
        switch capId {
        case "synthesize_sources", "compare_options", "decision_matrix":
            // Need multiple sources to do a good job
            if s.hasMultipleSources || s.hasComparisonCandidates { return 0.92 }
            if eq == "browser_context" { return 0.65 }
            return 0.30
        case "diagnose_error":
            if s.hasErrorTerms { return 0.95 }
            return 0.40
        case "generate_quiz", "create_flashcards":
            if eq == "ax_content" { return 0.92 }
            if eq == "browser_context" { return 0.70 }
            return 0.50
        case "draft_reply", "extract_action_items":
            // Need to see the actual content
            if eq == "ax_content" { return 0.90 }
            if eq == "browser_context" { return 0.68 }
            return 0.35
        case "summarize_reference", "extract_key_terms":
            if eq == "ax_content" { return 0.90 }
            if eq == "browser_context" { return 0.72 }
            return 0.60
        default:
            // Most capabilities work reasonably well from title/URL alone
            if eq == "ax_content" { return 0.90 }
            if eq == "browser_context" { return 0.78 }
            return 0.65
        }
    }

    // MARK: - Actionability score

    private static func actionabilityScore(_ capId: String, situation s: Situation) -> Double {
        switch capId {
        case "diagnose_error" where s.hasErrorTerms: return 0.95
        case "compare_options" where s.hasComparisonCandidates: return 0.92
        case "synthesize_sources" where s.hasMultipleSources: return 0.90
        case "draft_reply": return 0.65   // requires confirmation
        case "generate_test_checklist",
             "create_game_design_checklist",
             "create_controls_polish_checklist",
             "create_asset_sound_checklist",
             "create_bug_reproduction_plan",
             "suggest_next_feature":
            return s.entityType == .code_project ? 0.88 : 0.55
        case "generate_quiz", "create_flashcards", "create_review_plan":
            return s.entityType == .course_material ? 0.87 : 0.60
        case "create_next_steps": return 0.70
        default: return 0.75
        }
    }

    // MARK: - Helpers

    private static func entityScore(
        _ entity: EntityGrounding.EntityType,
        primary: [EntityGrounding.EntityType],
        secondary: [EntityGrounding.EntityType] = [],
        primaryW: Double,
        secondaryW: Double = 0.0
    ) -> Double {
        if primary.contains(entity) { return primaryW }
        if secondary.contains(entity) { return secondaryW }
        return 0.0
    }

    private static func domainScore(
        _ domain: DeterminerSignal.Domain,
        primary: [DeterminerSignal.Domain],
        secondary: [DeterminerSignal.Domain] = [],
        primaryW: Double,
        secondaryW: Double = 0.0
    ) -> Double {
        if primary.contains(domain) { return primaryW }
        if secondary.contains(domain) { return secondaryW }
        return 0.0
    }

    private static func blocked(
        _ entity: EntityGrounding.EntityType,
        _ blocklist: [EntityGrounding.EntityType]
    ) -> Bool {
        blocklist.contains(entity)
    }

    private static func reasonString(_ capId: String, situation s: Situation) -> String {
        if s.hasErrorTerms && ["diagnose_error", "create_bug_reproduction_plan"].contains(capId) {
            return "error_terms_present"
        }
        if s.hasMultipleSources && ["synthesize_sources", "compare_options"].contains(capId) {
            return "multiple_sources"
        }
        return "\(s.entityType.rawValue)+\(s.domain.rawValue)"
    }

    private static func needForCapability(_ capId: String) -> Need {
        switch capId {
        case "generate_quiz", "create_flashcards": return .recall
        case "create_review_plan", "make_study_schedule", "create_study_outline": return .organization
        case "extract_key_terms", "explain_topic", "explain_code_context": return .explanation
        case "diagnose_error", "create_bug_reproduction_plan", "debug_performance": return .debugging
        case "generate_test_checklist", "create_game_design_checklist",
             "create_controls_polish_checklist", "create_asset_sound_checklist": return .testing
        case "suggest_next_feature", "create_next_steps", "suggest_refactor_plan": return .planning
        case "compare_options", "decision_matrix": return .comparison
        case "synthesize_sources", "extract_open_questions", "create_research_outline": return .synthesis
        case "summarize_reference", "summarize_context": return .summarization
        case "draft_reply", "extract_action_items": return .drafting
        default: return .nextSteps
        }
    }

    // MARK: - Capability registry

    static let allCapabilityIds: [String] = [
        // Study
        "generate_quiz", "create_review_plan", "create_flashcards",
        "extract_key_terms", "make_study_schedule", "explain_topic", "create_study_outline",
        // Game / creative code
        "generate_test_checklist", "create_game_design_checklist",
        "create_controls_polish_checklist", "create_asset_sound_checklist",
        "create_bug_reproduction_plan", "suggest_next_feature",
        // Code / debug
        "diagnose_error", "debug_performance", "explain_code_context", "suggest_refactor_plan",
        // Research
        "synthesize_sources", "extract_open_questions", "create_research_outline", "summarize_reference",
        // Shopping
        "compare_options", "decision_matrix", "summarize_context",
        // Communication
        "draft_reply", "extract_action_items",
        // Fallback (capped)
        "create_next_steps",
    ]
}
