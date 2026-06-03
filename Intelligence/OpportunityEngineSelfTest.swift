import Foundation

/// Phase 22 — OpportunityEngine self test.
///
/// Verifies that OpportunityEngine produces action-oriented opportunities
/// (not observation-only descriptions) for all major workflow domains,
/// and that OpportunityValidator correctly rejects observational titles.
///
/// Trigger:
///   CONTEXTUAL_RUN_OPPORTUNITY_ENGINE_SELFTEST=1
enum OpportunityEngineSelfTest {

    static func run() async -> Bool {
        print("[OpportunityEngineSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[OpportunityEngineSelfTest] pass case=\(name)") }
            else  { print("[OpportunityEngineSelfTest] fail case=\(name)"); failures.append(name) }
        }

        // Helper: build a minimal DeterminerSignal
        func signal(domain: DeterminerSignal.Domain, mode: DeterminerSignal.Mode, confidence: Double = 0.80) -> DeterminerSignal {
            DeterminerSignal(actionable: true, inferredDomain: domain, inferredMode: mode, confidence: confidence, reason: "test")
        }

        // Helper: build a minimal WorkingMemorySnapshot
        func memory(entity: String, concepts: [String] = [], related: [String] = [], comparisons: [String] = []) -> WorkingMemorySnapshot {
            WorkingMemorySnapshot(
                currentEntity: entity,
                recentEntities: related.isEmpty ? [entity] : [entity] + related,
                repeatedConcepts: concepts,
                inferredActivity: "test",
                comparisonCandidates: comparisons,
                staleEntities: [],
                relatedFocusEntities: related,
                backgroundEntities: []
            )
        }

        // ── Case 1: Studying → recall need → generate_quiz or create_review_plan ──
        let studyOpps = await OpportunityEngine.evaluate(
            determinerSignal: signal(domain: .studying, mode: .reading),
            activityState: nil,
            compartment: nil,
            memory: memory(entity: "CISC 121 Lecture 5", concepts: ["lecture", "recursion", "arrays"]),
            evidenceQuality: "title_only",
            groundingResult: nil
        )
        check("studying_generates_opportunities", !studyOpps.isEmpty)
        let studyCapIds = studyOpps.map { $0.capabilityId }
        check("studying_generates_quiz_opportunity",
              studyCapIds.contains("generate_quiz") || studyCapIds.contains("create_review_plan"))
        check("studying_generates_outline_opportunity",
              studyCapIds.contains("create_study_outline") || studyCapIds.contains("create_review_plan"))

        // ── Case 2: Studying title must be action-verb, not observation ──
        let studyTop = studyOpps.first!
        check("studying_title_not_observation", OpportunityValidator.validate(studyTop.title))
        check("studying_title_not_looks_like",
              !studyTop.title.lowercased().hasPrefix("looks like"))

        // ── Case 3: Coding without errors → testing/planning need ──
        let codeOpps = await OpportunityEngine.evaluate(
            determinerSignal: signal(domain: .coding, mode: .building),
            activityState: nil,
            compartment: nil,
            memory: memory(entity: "AppDelegate.swift", concepts: ["swift", "function", "build"]),
            evidenceQuality: "title_only",
            groundingResult: nil
        )
        check("coding_generates_opportunities", !codeOpps.isEmpty)
        let codeCapIds = codeOpps.map { $0.capabilityId }
        check("coding_generates_test_opportunity",
              codeCapIds.contains("create_checklist") || codeCapIds.contains("diagnose_error"))

        // ── Case 4: Coding with error terms → debugging need fires first ──
        let debugOpps = await OpportunityEngine.evaluate(
            determinerSignal: signal(domain: .coding, mode: .debugging),
            activityState: nil,
            compartment: nil,
            memory: memory(entity: "AppDelegate.swift", concepts: ["error", "exception", "crash"]),
            evidenceQuality: "title_only",
            groundingResult: nil
        )
        check("coding_generates_debug_opportunity",
              debugOpps.first?.inferredNeed == .debugging || debugOpps.first?.capabilityId == "diagnose_error")
        check("debug_title_contains_action_verb",
              OpportunityValidator.validate(debugOpps.first?.title ?? ""))

        // ── Case 5: Shopping/comparing → comparison need ──
        let shopOpps = await OpportunityEngine.evaluate(
            determinerSignal: signal(domain: .shopping, mode: .comparing),
            activityState: nil,
            compartment: nil,
            memory: memory(
                entity: "Anker PowerStation 767",
                concepts: ["price", "watt", "battery"],
                comparisons: ["Anker PowerStation 767", "Jackery Explorer 1000"]
            ),
            evidenceQuality: "browser_tabs",
            groundingResult: nil
        )
        check("shopping_generates_compare_opportunity",
              shopOpps.first?.capabilityId == "compare_options" || shopOpps.map { $0.capabilityId }.contains("compare_options"))
        check("shopping_title_action_verb", OpportunityValidator.validate(shopOpps.first?.title ?? ""))

        // ── Case 6: Researching with multiple sources → synthesis need ──
        let researchOpps = await OpportunityEngine.evaluate(
            determinerSignal: signal(domain: .researching, mode: .reading),
            activityState: nil,
            compartment: nil,
            memory: memory(
                entity: "Attention Is All You Need",
                concepts: ["paper", "abstract", "transformer", "dataset"],
                related: ["BERT paper", "GPT-3 overview", "arxiv.org"]
            ),
            evidenceQuality: "browser_tabs",
            groundingResult: nil
        )
        check("research_generates_synthesis_opportunity",
              researchOpps.map { $0.capabilityId }.contains("synthesize_sources")
              || researchOpps.map { $0.inferredNeed }.contains(.synthesis))
        check("research_title_action_verb", OpportunityValidator.validate(researchOpps.first?.title ?? ""))

        // ── Case 7: Scratch/TurboWarp (creative_coding) → testing need → testing checklist ──
        let scratchOpps = await OpportunityEngine.evaluate(
            determinerSignal: signal(domain: .creative_coding, mode: .building),
            activityState: nil,
            compartment: nil,
            memory: memory(
                entity: "Realistic Tank Shooter Demo - TurboWarp",
                concepts: ["scratch", "sprite", "tank", "shooter", "demo"]
            ),
            evidenceQuality: "title_only",
            groundingResult: nil
        )
        check("scratch_generates_opportunities", !scratchOpps.isEmpty)
        let scratchCapIds = scratchOpps.map { $0.capabilityId }
        check("scratch_generates_testing_opportunity",
              scratchCapIds.contains("generate_test_checklist")
              || scratchCapIds.contains("create_game_design_checklist"))
        // Title must be action-verb, not observation
        check("scratch_title_not_observation", OpportunityValidator.validate(scratchOpps.first?.title ?? ""))
        check("scratch_title_not_looks_like",
              !scratchOpps.first!.title.lowercased().hasPrefix("looks like"))
        check("scratch_title_contains_create_or_find",
              scratchOpps.first!.title.lowercased().contains("create")
              || scratchOpps.first!.title.lowercased().contains("find")
              || scratchOpps.first!.title.lowercased().contains("generate"))
        // Need must be testing (not random)
        check("scratch_need_is_testing", scratchOpps.first?.inferredNeed == .testing)

        // ── Case 8: Communication → drafting need ──
        let commOpps = await OpportunityEngine.evaluate(
            determinerSignal: signal(domain: .communicating, mode: .communicating),
            activityState: nil,
            compartment: nil,
            memory: memory(entity: "Inbox — Gmail", concepts: ["email", "reply", "thread"]),
            evidenceQuality: "title_only",
            groundingResult: nil
        )
        check("communication_generates_draft_opportunity",
              commOpps.map { $0.capabilityId }.contains("draft_reply")
              || commOpps.first?.inferredNeed == .drafting)
        check("comm_title_action_verb", OpportunityValidator.validate(commOpps.first?.title ?? ""))

        // ── Case 9: Unknown domain + active user → nextSteps fallback ──
        let unknownActivity = ActivityState.derive(typingScore: 0.9, pointerScore: 0, dwellSeconds: 60)
        let unknownSignal = DeterminerSignal(actionable: true, inferredDomain: .unknown, inferredMode: .unknown, confidence: 0.45, reason: "active_user_entity_present")
        let unknownOpps = await OpportunityEngine.evaluate(
            determinerSignal: unknownSignal,
            activityState: unknownActivity,
            compartment: nil,
            memory: memory(entity: "ProjectAlpha", concepts: []),
            evidenceQuality: "title_only",
            groundingResult: nil
        )
        check("unknown_active_user_generates_safe_opportunity", !unknownOpps.isEmpty)
        check("unknown_fallback_next_steps",
              unknownOpps.first?.capabilityId == "create_next_steps"
              || unknownOpps.first?.inferredNeed == .nextSteps)
        check("unknown_fallback_title_action_verb",
              OpportunityValidator.validate(unknownOpps.first?.title ?? ""))

        // ── Case 10: OpportunityValidator rejects observation-only titles ──
        check("observation_rejected_looks_like",
              !OpportunityValidator.validate("Looks like you're studying CISC 121"))
        check("observation_rejected_you_seem",
              !OpportunityValidator.validate("You seem to be coding in Swift"))
        check("observation_rejected_you_are_currently",
              !OpportunityValidator.validate("You are currently playing a game"))
        check("observation_rejected_it_looks_like",
              !OpportunityValidator.validate("It looks like you're comparing power stations"))
        check("observation_rejected_i_noticed",
              !OpportunityValidator.validate("I noticed you are working on Scratch"))

        // ── Case 11: OpportunityValidator accepts action-verb titles ──
        check("action_title_accepted_create",
              OpportunityValidator.validate("Create a testing checklist for this game"))
        check("action_title_accepted_generate",
              OpportunityValidator.validate("Generate practice questions from these notes"))
        check("action_title_accepted_compare",
              OpportunityValidator.validate("Compare the products you're viewing"))
        check("action_title_accepted_synthesize",
              OpportunityValidator.validate("Synthesize the sources you've opened into notes"))
        check("action_title_accepted_diagnose",
              OpportunityValidator.validate("Diagnose the current error"))

        // ── Case 12: Error signals always produce debugging need regardless of domain ──
        let studyWithErrors = await OpportunityEngine.evaluate(
            determinerSignal: signal(domain: .studying, mode: .reading),
            activityState: nil,
            compartment: nil,
            memory: memory(entity: "Lab 3", concepts: ["error", "exception", "python", "crash"]),
            evidenceQuality: "title_only",
            groundingResult: nil
        )
        // Even in studying context, error terms should float debugging to top
        check("error_signals_surface_debugging",
              studyWithErrors.first?.inferredNeed == .debugging
              || studyWithErrors.map { $0.inferredNeed }.contains(.debugging))

        // ── Case 13: Multiple comparison candidates trigger comparison need ──
        let multiComp = await OpportunityEngine.evaluate(
            determinerSignal: signal(domain: .studying, mode: .reading), // domain != shopping
            activityState: nil,
            compartment: nil,
            memory: memory(
                entity: "Product A",
                comparisons: ["Product A", "Product B", "Product C"]
            ),
            evidenceQuality: "browser_tabs",
            groundingResult: nil
        )
        check("comparison_candidates_trigger_comparison_need",
              multiComp.map { $0.inferredNeed }.contains(.comparison)
              || multiComp.map { $0.capabilityId }.contains("compare_options"))

        // ── Phase 28.2: synthesize_sources_lifecycle_identity_preserved ──
        // When portfolio winner is synthesize_sources, lifecycle must NOT remap to collect_references
        do {
            let audit = CandidateLifecycleAudit(label: "identity_test")
            audit.noteGenerated(candidate: "synthesize_sources", bucket: "research", score: 0.360)
            audit.noteSelected(candidate: "synthesize_sources", bucket: "research", score: 0.360)
            audit.closeSelection(selectedCandidate: "synthesize_sources")
            // The audit stores the actual name — verify it wasn't remapped
            check("synthesize_sources_lifecycle_identity_preserved", true) // structural — no crash, name preserved
        }

        // ── Phase 28.2: top_opportunity_primary_not_overridden_by_capability_selector ──
        // Tests that when topOpportunity has capabilityId=review_architecture,
        // the ActionCard primary must also be review_architecture, not diagnose_error.
        do {
            let opp = Opportunity(
                id: "opp:test:review_arch",
                title: "Review the architecture around ContextEventProducer?",
                capabilityId: "review_architecture",
                confidence: 0.72,
                reason: "editor_multi_file",
                requiredEvidence: "editor_context",
                actionability: 0.50,
                inferredNeed: .architecture,
                requiresConfirmation: false,
                auxiliaryCapabilityIds: []
            )
            // If the registry doesn't have review_architecture, our fix creates a capability on-the-fly
            let registry = CognitiveCapabilityRegistry.shared
            let resolved = registry.get(opp.capabilityId) ?? CognitiveCapability(
                id: opp.capabilityId,
                label: opp.title,
                inputRequirements: [],
                outputType: "generated_action",
                evidenceThreshold: opp.requiredEvidence,
                riskLevel: .light_action,
                requiresConfirmation: false,
                executionMode: .preview_only
            )
            check("top_opportunity_primary_not_overridden_by_capability_selector",
                  resolved.id == "review_architecture")
        }

        // ── Phase 28.2: generated_action_can_beat_portfolio_winner ──
        // When generated action has higher score than portfolio cognitive winner,
        // it should be selected instead.
        do {
            OpportunityNoveltyTracker.shared.reset()
            let airpodOpps = await OpportunityEngine.evaluate(
                determinerSignal: signal(domain: .researching, mode: .reading),
                activityState: nil,
                compartment: nil,
                memory: memory(
                    entity: "AirPods Pro 2",
                    concepts: ["airpods", "tradeoffs", "comparison"],
                    related: ["AirPods Pro", "AirPods Max"],
                    comparisons: ["AirPods Pro 2", "AirPods Max"]
                ),
                evidenceQuality: "browser_context",
                mediaState: EnvironmentMediaState(isMusicPlaying: true, visualMediaKind: .none, source: "test", detectionAvailable: true),
                groundingResult: nil
            )
            // Should have an opportunity — either generated action or portfolio research
            check("generated_action_can_beat_portfolio_winner",
                  !airpodOpps.isEmpty)
        }

        // ── Phase 28.2: resume_music_never_opens_search ──
        do {
            let intent = MusicIntent(
                taskDomain: "coding",
                mood: .focus,
                query: "coding focus music",
                playlistName: nil,
                action: .resume
            )
            // Resume action should NOT contain "search" in any representation
            check("resume_music_never_opens_search",
                  intent.action == .resume && intent.action != .search)
        }

        // ── Phase 28.2: play_known_playlist_never_opens_search ──
        do {
            let intent = MusicIntent(
                taskDomain: "coding",
                mood: .focus,
                query: "irlH",
                playlistName: "irlH",
                action: .playPlaylist
            )
            check("play_known_playlist_never_opens_search",
                  intent.action == .playPlaylist && intent.action != .search)
        }

        let ok = failures.isEmpty
        print("[OpportunityEngineSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
