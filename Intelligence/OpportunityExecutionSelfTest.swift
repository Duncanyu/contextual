import Foundation

/// Phase 22 — OpportunityExecution self test.
///
/// Verifies the full click path: opportunity → AmbientJarvisSuggestion →
/// ContextExecutionEngine → ContextExecutionResult with correct artifact type,
/// section structure, and honest missing-info notes.
///
/// Also verifies that CapabilityExecutor is honest about unavailable capabilities
/// (start_focus_timer must return .unavailable, not .success).
///
/// Trigger:
///   CONTEXTUAL_RUN_OPPORTUNITY_EXECUTION_SELFTEST=1
enum OpportunityExecutionSelfTest {

    static func run() async -> Bool {
        print("[OpportunityExecutionSelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok { print("[OpportunityExecutionSelfTest] pass case=\(name)") }
            else  { print("[OpportunityExecutionSelfTest] fail case=\(name)"); failures.append(name) }
        }

        // Helper — build a suggestion that carries a specific opportunity.
        // intent is always the opportunity's capabilityId so the execution
        // engine routes to the correct fallback artifact branch.
        func suggestion(
            intent: String,
            entity: String,
            terms: [String],
            opportunity: Opportunity?
        ) -> AmbientJarvisSuggestion {
            AmbientJarvisSuggestion(
                title: OpportunityEngine.title(forCapabilityId: intent, entity: entity),
                subtitle: "test — selftest scenario",
                whyNow: "selftest",
                workflow: "creative_coding",
                behavior: "building",
                confidence: 0.80,
                kind: .cognitive_action,
                intent: intent,
                intentGoal: "Selftest for \(intent)",
                targetEntity: entity,
                sourceEvidence: terms.joined(separator: ","),
                topOpportunity: opportunity
            )
        }

        // Helper — build a minimal Opportunity for a given capabilityId.
        func opp(
            capId: String,
            need: Need,
            entity: String,
            confidence: Double = 0.85,
            confirmation: Bool = false
        ) -> Opportunity {
            Opportunity(
                id: "selftest:\(need.rawValue):\(capId)",
                title: OpportunityEngine.title(forCapabilityId: capId, entity: entity),
                capabilityId: capId,
                confidence: confidence,
                reason: need.rawValue,
                requiredEvidence: "title_only",
                actionability: 0.85,
                inferredNeed: need,
                requiresConfirmation: confirmation,
                auxiliaryCapabilityIds: []
            )
        }

        // ── Case 1: Scratch/TurboWarp → generate_test_checklist ──────────
        print("[OpportunityExecutionSelfTest] case=scratch_game_testing")
        let scratchOpp = opp(capId: "generate_test_checklist", need: .testing,
                             entity: "Realistic Tank Shooter Demo - TurboWarp")
        let scratchSugg = suggestion(
            intent: "generate_test_checklist",
            entity: "Realistic Tank Shooter Demo - TurboWarp",
            terms: ["scratch", "tank", "shooter", "sprite", "demo"],
            opportunity: scratchOpp
        )
        let scratchResult = await ContextExecutionEngine.execute(suggestion: scratchSugg, snapshot: nil)
        let scratchArtifact = scratchResult.cognitiveArtifact
        check("scratch_artifact_type_checklist", scratchArtifact.type == "checklist")
        check("scratch_has_sections", !scratchArtifact.sections.isEmpty)
        check("scratch_has_controls_section",
              scratchArtifact.sections.contains { $0.header.contains("Controls") })
        check("scratch_has_collision_section",
              scratchArtifact.sections.contains { $0.header.contains("Collision") })
        check("scratch_has_game_state_section",
              scratchArtifact.sections.contains { $0.header.contains("Game State") || $0.header.contains("State") })
        check("scratch_missing_info_mentions_sprites",
              scratchArtifact.missingInfo.contains { $0.lowercased().contains("sprite") || $0.lowercased().contains("screen") })
        // Title in the artifact must be entity-anchored
        check("scratch_title_contains_entity",
              scratchArtifact.title.contains("TurboWarp") || scratchArtifact.title.contains("Tank") || scratchArtifact.title.contains("Testing"))
        // Source must be fallback (no model in test)
        check("scratch_source_fallback", scratchResult.source == "fallback")

        // ── Case 2: Studying → generate_quiz ────────────────────────────
        print("[OpportunityExecutionSelfTest] case=studying_quiz")
        let studyOpp = opp(capId: "generate_quiz", need: .recall, entity: "CISC 121 Lecture 5")
        let studySugg = suggestion(
            intent: "generate_quiz",
            entity: "CISC 121 Lecture 5",
            terms: ["lecture", "recursion", "arrays", "cisc"],
            opportunity: studyOpp
        )
        let studyResult = await ContextExecutionEngine.execute(suggestion: studySugg, snapshot: nil)
        let studyArtifact = studyResult.cognitiveArtifact
        check("study_quiz_artifact_type", studyArtifact.type == "quiz")
        check("study_quiz_has_questions",
              studyArtifact.sections.contains { $0.header.contains("Question") || $0.header.contains("Practice") })
        check("study_quiz_has_note_on_evidence",
              studyArtifact.sections.contains { $0.header.contains("Note") || $0.header.contains("Evidence") || $0.items.joined().lowercased().contains("ax") })
        check("study_quiz_missing_info_mentions_content",
              studyArtifact.missingInfo.contains { $0.lowercased().contains("content") || $0.lowercased().contains("ax") || $0.lowercased().contains("note") })

        // ── Case 3: Studying → create_review_plan ───────────────────────
        print("[OpportunityExecutionSelfTest] case=studying_review_plan")
        let reviewSugg = suggestion(
            intent: "create_review_plan",
            entity: "CISC 340 Midterm Review",
            terms: ["midterm", "review", "lecture"],
            opportunity: nil  // test works without opportunity (intent-only routing)
        )
        let reviewResult = await ContextExecutionEngine.execute(suggestion: reviewSugg, snapshot: nil)
        let reviewArtifact = reviewResult.cognitiveArtifact
        check("review_plan_artifact_type", reviewArtifact.type == "checklist")
        check("review_plan_has_order_section",
              reviewArtifact.sections.contains { $0.header.contains("Order") || $0.header.contains("Review") || $0.header.contains("Suggested") })
        check("review_plan_has_checklist_section",
              reviewArtifact.sections.contains { $0.header.contains("Checklist") || $0.header.contains("Check") })

        // ── Case 4: Coding/debugging → diagnose_error ───────────────────
        print("[OpportunityExecutionSelfTest] case=debugging_error")
        let debugOpp = opp(capId: "diagnose_error", need: .debugging, entity: "AppDelegate.swift")
        let debugSugg = suggestion(
            intent: "diagnose_error",
            entity: "AppDelegate.swift",
            terms: ["error", "exception", "swift", "crash"],
            opportunity: debugOpp
        )
        let debugResult = await ContextExecutionEngine.execute(suggestion: debugSugg, snapshot: nil)
        let debugArtifact = debugResult.cognitiveArtifact
        check("debug_artifact_type_diagnostic", debugArtifact.type == "diagnostic")
        check("debug_has_investigation_steps",
              debugArtifact.sections.contains { $0.header.contains("Step") || $0.header.contains("Investigation") })
        check("debug_has_error_signals_section",
              debugArtifact.sections.contains { $0.header.contains("Error") || $0.header.contains("Signal") || $0.header.contains("Detected") })
        check("debug_missing_info_mentions_ax",
              debugArtifact.missingInfo.contains { $0.lowercased().contains("ax") || $0.lowercased().contains("error text") || $0.lowercased().contains("screen") })

        // ── Case 5: Communication → draft_reply (confirmation required) ──
        print("[OpportunityExecutionSelfTest] case=communication_draft")
        let commOpp = opp(capId: "draft_reply", need: .drafting, entity: "Inbox — Gmail", confirmation: true)
        let commSugg = suggestion(
            intent: "draft_reply",
            entity: "Inbox — Gmail",
            terms: ["email", "reply", "thread", "inbox"],
            opportunity: commOpp
        )
        let commResult = await ContextExecutionEngine.execute(suggestion: commSugg, snapshot: nil)
        let commArtifact = commResult.cognitiveArtifact
        check("draft_artifact_type_draft", commArtifact.type == "draft")
        check("draft_has_confirmation_section",
              commArtifact.sections.contains { $0.header.contains("Confirm") || $0.items.joined().lowercased().contains("send") })
        check("draft_has_structure_section",
              commArtifact.sections.contains { $0.header.contains("Structure") || $0.header.contains("Reply") })
        check("draft_missing_info_mentions_body",
              commArtifact.missingInfo.contains { $0.lowercased().contains("body") || $0.lowercased().contains("text") || $0.lowercased().contains("content") })

        // ── Case 6: Research → synthesize_sources ───────────────────────
        print("[OpportunityExecutionSelfTest] case=research_synthesis")
        let researchOpp = opp(capId: "synthesize_sources", need: .synthesis,
                              entity: "Attention Is All You Need")
        let researchSugg = suggestion(
            intent: "synthesize_sources",
            entity: "Attention Is All You Need",
            terms: ["paper", "transformer", "attention", "bert"],
            opportunity: researchOpp
        )
        let researchResult = await ContextExecutionEngine.execute(suggestion: researchSugg, snapshot: nil)
        let researchArtifact = researchResult.cognitiveArtifact
        check("synthesis_artifact_type", researchArtifact.type == "synthesis")
        check("synthesis_has_sources_section",
              researchArtifact.sections.contains { $0.header.contains("Source") })
        check("synthesis_has_structure_section",
              researchArtifact.sections.contains { $0.header.contains("Structure") || $0.header.contains("Concept") || $0.header.contains("Shared") })
        check("synthesis_missing_info_mentions_text",
              researchArtifact.missingInfo.contains { $0.lowercased().contains("text") || $0.lowercased().contains("content") || $0.lowercased().contains("title") })

        // ── Case 7: start_focus_timer returns .unavailable (not fake .success) ──
        print("[OpportunityExecutionSelfTest] case=focus_timer_honest")
        let timerCap = CognitiveCapabilityRegistry.shared.get("start_focus_timer")!
        let timerStatus = await CapabilityExecutor.shared.execute(capability: timerCap, context: [:])
        check("focus_timer_unavailable", timerStatus == .unavailable)
        check("focus_timer_not_fake_success", timerStatus != .success)

        // ── Case 8: copy_result_to_clipboard returns .success when text provided ──
        print("[OpportunityExecutionSelfTest] case=clipboard_copy")
        let clipCap = CognitiveCapabilityRegistry.shared.get("copy_result_to_clipboard")!
        let clipStatus = await CapabilityExecutor.shared.execute(
            capability: clipCap,
            context: ["text": "Selftest clipboard content"]
        )
        check("clipboard_copy_success", clipStatus == .success)

        // ── Case 9: Opportunity stored on suggestion carries through ─────
        let opp9 = opp(capId: "generate_test_checklist", need: .testing, entity: "Mario Clone")
        let sugg9 = suggestion(
            intent: "generate_test_checklist",
            entity: "Mario Clone",
            terms: ["jump", "platform", "sprite"],
            opportunity: opp9
        )
        check("opportunity_stored_on_suggestion", sugg9.topOpportunity != nil)
        check("opportunity_capabilityId_matches",
              sugg9.topOpportunity?.capabilityId == "generate_test_checklist")
        check("suggestion_intent_matches_opportunity",
              sugg9.intent == "generate_test_checklist")

        // ── Case 10: Opportunity title passes OpportunityValidator ───────
        for capId in ["generate_test_checklist", "generate_quiz", "diagnose_error", "draft_reply",
                      "synthesize_sources", "create_review_plan", "compare_options", "create_next_steps"] {
            let t = OpportunityEngine.title(forCapabilityId: capId, entity: "Test Entity")
            check("title_passes_validator_\(capId)", OpportunityValidator.validate(t))
        }

        let ok = failures.isEmpty
        print("[OpportunityExecutionSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
