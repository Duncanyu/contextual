import Foundation

/// Phase 22.2 — OpportunityReasoner self-test (Task I).
///
/// Verifies that the dynamic scorer selects appropriate capabilities for each
/// entity type and does not blindly follow the old hardcoded domain→action maps.
///
/// Trigger: CONTEXTUAL_RUN_OPPORTUNITY_REASONER_SELFTEST=1
enum OpportunityReasonerSelfTest {

    static func run() -> Bool {
        print("[OpportunityReasonerSelfTest] starting")
        var failures: [String] = []
        let tracker = OpportunityNoveltyTracker()  // fresh tracker for tests

        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[OpportunityReasonerSelfTest] pass case=\(name)")
            } else {
                print("[OpportunityReasonerSelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        // ── Case 1: course_material + studying → recall capabilities win ──────
        let studySituation = makeSituation(.course_material, domain: .studying)
        let studyCandidates = OpportunityReasoner.reason(situation: studySituation, noveltyTracker: tracker)
        let studyTopId = studyCandidates.first?.capabilityId
        check("course_material_studying_recalls_top_capability",
              ["generate_quiz", "create_flashcards", "create_review_plan",
               "extract_key_terms", "create_study_outline", "make_study_schedule"]
               .contains(studyTopId ?? ""))
        check("course_material_does_not_use_create_next_steps_as_top",
              studyTopId != "create_next_steps")

        // ── Case 2: code_project + creative_coding → testing/game capabilities ─
        let codeSituation = makeSituation(.code_project, domain: .creative_coding)
        let codeCandidates = OpportunityReasoner.reason(situation: codeSituation, noveltyTracker: tracker)
        let codeTopId = codeCandidates.first?.capabilityId
        check("code_project_creative_coding_top_is_game_capability",
              ["generate_test_checklist", "create_game_design_checklist",
               "create_controls_polish_checklist", "create_asset_sound_checklist",
               "create_bug_reproduction_plan", "suggest_next_feature"]
               .contains(codeTopId ?? ""))
        check("code_project_does_not_use_create_next_steps_as_top",
              codeTopId != "create_next_steps")

        // ── Case 3: Error terms → diagnose_error scored highly ─────────────────
        let errorSituation = makeSituation(.code_project, domain: .coding, hasErrors: true)
        let errorCandidates = OpportunityReasoner.reason(situation: errorSituation, noveltyTracker: tracker)
        let hasErrorCapability = errorCandidates.contains {
            ["diagnose_error", "create_bug_reproduction_plan"].contains($0.capabilityId)
        }
        check("error_terms_surface_debug_capability", hasErrorCapability)

        // ── Case 4: Multiple sources → synthesize_sources scored ─────────────
        let multiSrcSituation = makeSituation(.document, domain: .researching, hasMultipleSources: true)
        let multiCandidates = OpportunityReasoner.reason(situation: multiSrcSituation, noveltyTracker: tracker)
        check("multiple_sources_scores_synthesize",
              multiCandidates.contains { $0.capabilityId == "synthesize_sources" })

        // ── Case 5: tv_show / entertainment → no candidates ───────────────────
        let tvSituation = makeSituation(.tv_show, domain: .watching)
        let tvCandidates = OpportunityReasoner.reason(situation: tvSituation, noveltyTracker: tracker)
        check("tv_show_produces_no_candidates", tvCandidates.isEmpty)

        // ── Case 6: youtube_video → no candidates ────────────────────────────
        let ytSituation = makeSituation(.youtube_video, domain: .watching)
        let ytCandidates = OpportunityReasoner.reason(situation: ytSituation, noveltyTracker: tracker)
        check("youtube_video_produces_no_candidates", ytCandidates.isEmpty)

        // ── Case 7: create_next_steps never beats specific capability ─────────
        // In any productive context, specific capabilities should outscore it
        let codeNextSteps = codeCandidates.first { $0.capabilityId == "create_next_steps" }
        let codeTop = codeCandidates.first
        if let topScore = codeTop?.finalScore, let nextStepsScore = codeNextSteps?.finalScore {
            check("create_next_steps_score_below_specific_capability",
                  nextStepsScore < topScore)
        } else {
            // If create_next_steps doesn't even appear → even better
            check("create_next_steps_not_top_or_absent",
                  codeNextSteps == nil || codeNextSteps!.capabilityId != codeTopId)
        }

        // ── Case 8: email_thread → communication capabilities ─────────────────
        let emailSituation = makeSituation(.email_thread, domain: .communicating)
        let emailCandidates = OpportunityReasoner.reason(situation: emailSituation, noveltyTracker: tracker)
        check("email_thread_scores_draft_reply_or_action_items",
              emailCandidates.contains { ["draft_reply", "extract_action_items"].contains($0.capabilityId) })

        // ── Case 9: Workflow says studying, entity is code_project → game wins ─
        // SemanticPriorityResolver normally handles this, but raw reasoning should still
        // prefer code capabilities when entity type is code_project regardless of domain
        let conflictSituation = makeSituation(.code_project, domain: .studying)  // conflict
        let conflictCandidates = OpportunityReasoner.reason(situation: conflictSituation, noveltyTracker: tracker)
        let conflictTop = conflictCandidates.first?.capabilityId ?? ""
        // code_project entity should still produce code-related capabilities
        check("code_project_entity_beats_studying_domain",
              ["generate_test_checklist", "create_game_design_checklist",
               "create_controls_polish_checklist", "create_bug_reproduction_plan",
               "suggest_next_feature", "diagnose_error", "debug_performance",
               "explain_code_context", "suggest_refactor_plan"]
               .contains(conflictTop))

        // ── Case 10: create_next_steps blocked for unknown + browsing ─────────
        let unknownBrowseSituation = makeSituation(.unknown, domain: .unknown)
        let unknownCandidates = OpportunityReasoner.reason(situation: unknownBrowseSituation, noveltyTracker: tracker)
        check("unknown_entity_no_create_next_steps",
              !unknownCandidates.contains { $0.capabilityId == "create_next_steps" })

        let ok = failures.isEmpty
        print("[OpportunityReasonerSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }

    // MARK: - Helpers

    private static func makeSituation(
        _ entityType: EntityGrounding.EntityType,
        domain: DeterminerSignal.Domain,
        hasErrors: Bool = false,
        hasMultipleSources: Bool = false,
        hasComparisons: Bool = false
    ) -> OpportunityReasoner.Situation {
        OpportunityReasoner.Situation(
            entityType: entityType,
            entityConfidence: 0.85,
            domain: domain,
            mode: .unknown,
            evidenceQuality: "title_only",
            hasErrorTerms: hasErrors,
            hasMultipleSources: hasMultipleSources,
            hasComparisonCandidates: hasComparisons,
            isActivelyEditing: false,
            compartmentDwellSeconds: 180,
            entityKey: "test_\(entityType.rawValue)_\(domain.rawValue)"
        )
    }
}
