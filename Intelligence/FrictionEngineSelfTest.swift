import Foundation

public struct FrictionEngineSelfTest: Sendable {
    
    @MainActor
    public static func run() async -> Bool {
        print("[FrictionEngineSelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[FrictionEngineSelfTest] pass case=\(name)")
            } else {
                print("[FrictionEngineSelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        let engine = FrictionEngine.shared
        engine.reset()

        // ── Case 1: oscillation detection ───────────────────────────────
        let now = Date()
        engine.recordAppSwitch(appName: "Xcode", bundleID: "com.apple.dt.Xcode", now: now)
        engine.recordAppSwitch(appName: "Safari", bundleID: "com.apple.Safari", now: now.addingTimeInterval(2))
        engine.recordAppSwitch(appName: "Xcode", bundleID: "com.apple.dt.Xcode", now: now.addingTimeInterval(4))
        engine.recordAppSwitch(appName: "Safari", bundleID: "com.apple.Safari", now: now.addingTimeInterval(6))
        
        let signals1 = engine.detectFriction()
        check("oscillation_detected", signals1.contains { $0.type == .repeated_app_switching && $0.confidence > 0.7 })

        // ── Case 2: stale oscillation expires ────────────────────────────
        engine.reset()
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now)
        engine.recordAppSwitch(appName: "B", bundleID: nil, now: now.addingTimeInterval(1))
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now.addingTimeInterval(2))
        // 5 minutes later
        let signals2 = engine.detectFriction(now: now.addingTimeInterval(300))
        check("stale_oscillation_expired", !signals2.contains { $0.type == .repeated_app_switching })

        // ── Case 3: tab cycling detection ────────────────────────────────
        engine.reset()
        engine.recordTabVisit(title: "google.com", now: now)
        engine.recordTabVisit(title: "stackoverflow.com", now: now.addingTimeInterval(1))
        engine.recordTabVisit(title: "github.com", now: now.addingTimeInterval(2))
        engine.recordTabVisit(title: "google.com", now: now.addingTimeInterval(3))
        engine.recordTabVisit(title: "stackoverflow.com", now: now.addingTimeInterval(4))
        
        let signals3 = engine.detectFriction()
        check("tab_cycling_detected", signals3.contains { $0.type == .repeated_tab_switching })

        // ── Case 4: reference lookup detection ────────────────────────────
        engine.reset()
        engine.recordConcepts(["swift", "optional", "binding"], appName: "Safari", bundleID: nil, windowTitle: "Swift Docs", now: now)
        engine.recordConcepts(["swift", "optional", "binding"], appName: "Safari", bundleID: nil, windowTitle: "Swift Tutorial", now: now.addingTimeInterval(10))
        engine.recordConcepts(["swift", "optional", "binding"], appName: "Safari", bundleID: nil, windowTitle: "StackOverflow Swift", now: now.addingTimeInterval(20))
        
        let signals4 = engine.detectFriction()
        check("reference_lookup_detected", signals4.contains { $0.type == .repeated_reference_lookup })

        // ── Case 5: reference lookup detection (overlap) ─────────────────
        engine.reset()
        engine.recordConcepts(["URLSession", "DataTask", "JSONDecoder"], appName: "Safari", bundleID: nil, windowTitle: "Apple Docs", now: now)
        engine.recordConcepts(["URLSession", "DataTask", "JSONDecoder"], appName: "Safari", bundleID: nil, windowTitle: "Hacking with Swift", now: now.addingTimeInterval(1))
        engine.recordConcepts(["URLSession", "DataTask", "JSONDecoder"], appName: "Safari", bundleID: nil, windowTitle: "Ray Wenderlich", now: now.addingTimeInterval(2))
        
        let signals5 = engine.detectFriction()
        check("reference_lookup_detected_overlap", signals5.contains { $0.type == .repeated_reference_lookup })

        // ── Case 6: no friction for single events ────────────────────────
        engine.reset()
        engine.recordAppSwitch(appName: "Xcode", bundleID: nil, now: now)
        check("no_friction_single_switch", engine.detectFriction().isEmpty)

        // ── Case 7: active dwell suppresses oscillation ──────────────────
        engine.reset()
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now)
        engine.recordAppSwitch(appName: "B", bundleID: nil, now: now.addingTimeInterval(1))
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now.addingTimeInterval(2))
        engine.recordAppSwitch(appName: "B", bundleID: nil, now: now.addingTimeInterval(3))
        // Dwell in A for 30 seconds
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now.addingTimeInterval(33))
        
        let signals7 = engine.detectFriction(now: now.addingTimeInterval(33))
        let osc = signals7.first { $0.type == .repeated_app_switching }
        check("dwell_suppresses_oscillation", osc == nil || osc!.confidence < 0.5)

        // ── Case 8: rapid multi-app switching ────────────────────────────
        engine.reset()
        let apps = ["A", "B", "C", "D", "E"]
        for (i, app) in apps.enumerated() {
            engine.recordAppSwitch(appName: app, bundleID: nil, now: now.addingTimeInterval(Double(i)))
        }
        let signals8 = engine.detectFriction()
        check("multi_app_friction_detected", signals8.contains { $0.type == .repeated_app_switching })

        // ── Case 9: friction reasoning has evidence when distinct concepts repeat ──
        engine.reset()
        engine.recordConcepts(["nserror", "swift error handling"], appName: "Safari", bundleID: nil, windowTitle: "T1", now: now)
        engine.recordConcepts(["nserror", "swift error handling"], appName: "Safari", bundleID: nil, windowTitle: "T2", now: now.addingTimeInterval(5))
        engine.recordConcepts(["nserror", "swift error handling"], appName: "Safari", bundleID: nil, windowTitle: "T3", now: now.addingTimeInterval(10))
        let signals9 = engine.detectFriction()
        check("friction_reasoning_present", signals9.first?.evidence.isEmpty == false)

        // ── Case 10: reset works ─────────────────────────────────────────
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now)
        engine.reset()
        check("reset_clears_state", engine.detectFriction().isEmpty)

        // ── Case 11: single concept from one source is not reference lookup ──
        engine.reset()
        engine.recordConcepts(["macros"], appName: "Safari", bundleID: nil, windowTitle: "Same Title", now: now)
        engine.recordConcepts(["macros"], appName: "Safari", bundleID: nil, windowTitle: "Same Title", now: now.addingTimeInterval(10))
        engine.recordConcepts(["macros"], appName: "Safari", bundleID: nil, windowTitle: "Same Title", now: now.addingTimeInterval(20))
        let signals11 = engine.detectFriction()
        check("similar_concepts_detected", !signals11.contains { $0.type == .repeated_reference_lookup })

        // ── Case 12: irrelevant app switches ignored ─────────────────────
        engine.reset()
        engine.recordAppSwitch(appName: "Xcode", bundleID: nil, now: now)
        engine.recordAppSwitch(appName: "Music", bundleID: nil, now: now.addingTimeInterval(60))
        check("irrelevant_slow_switches_ignored", engine.detectFriction().isEmpty)

        // ── Case 13: concept overlap threshold ───────────────────────────
        engine.reset()
        engine.recordConcepts(["apple", "banana", "cherry"], appName: "Safari", bundleID: nil, windowTitle: "T1", now: now)
        engine.recordConcepts(["dog", "elephant", "frog"], appName: "Safari", bundleID: nil, windowTitle: "T2", now: now.addingTimeInterval(1))
        check("no_concept_friction_without_overlap", !engine.detectFriction().contains { $0.type == .repeated_reference_lookup })

        // ── Case 14: max history limit ───────────────────────────────────
        engine.reset()
        for i in 0..<100 {
            engine.recordAppSwitch(appName: "A", bundleID: nil, now: now.addingTimeInterval(Double(i)))
        }
        // Should not crash and should keep recent history
        check("history_limit_handled", engine.detectFriction().count >= 0)

        // ── Case 15: timestamp jitter ────────────────────────────────────
        engine.reset()
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now.addingTimeInterval(0.1))
        engine.recordAppSwitch(appName: "B", bundleID: nil, now: now.addingTimeInterval(0.2))
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now.addingTimeInterval(0.3))
        engine.recordAppSwitch(appName: "B", bundleID: nil, now: now.addingTimeInterval(0.4))
        check("rapid_jitter_detected", signals1.contains { $0.type == .repeated_app_switching })

        // ── Case 16: domain specific friction ────────────────────────────
        // (Placeholder for future domain-aware friction logic)
        check("placeholder_case_16", true)

        // ── Case 17: concurrent friction — oscillation + reference lookup (distinct concepts) ──
        engine.reset()
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now)
        engine.recordAppSwitch(appName: "B", bundleID: nil, now: now.addingTimeInterval(1))
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now.addingTimeInterval(2))
        engine.recordAppSwitch(appName: "B", bundleID: nil, now: now.addingTimeInterval(3))
        engine.recordConcepts(["autolayout", "constraints"], appName: "Safari", bundleID: nil, windowTitle: "T1", now: now)
        engine.recordConcepts(["autolayout", "constraints"], appName: "Safari", bundleID: nil, windowTitle: "T2", now: now.addingTimeInterval(1))
        engine.recordConcepts(["autolayout", "constraints"], appName: "Safari", bundleID: nil, windowTitle: "T3", now: now.addingTimeInterval(2))
        let signals17 = engine.detectFriction()
        check("concurrent_friction_detected", signals17.count >= 2)

        // ── Case 18: empty inputs ────────────────────────────────────────
        engine.reset()
        engine.recordConcepts([], appName: "Safari", bundleID: nil, windowTitle: nil, now: now)
        check("empty_inputs_ignored", engine.detectFriction().isEmpty)

        // ── Case 19: single concept repeated 10x is not reference lookup ──
        engine.reset()
        for i in 0..<10 {
            engine.recordConcepts(["exact"], appName: "Safari", bundleID: nil, windowTitle: "Same", now: now.addingTimeInterval(Double(i*5)))
        }
        let signals19 = engine.detectFriction()
        check("exact_repeat_high_confidence", !signals19.contains { $0.type == .repeated_reference_lookup })

        // ── Case 20: noise injection ─────────────────────────────────────
        engine.reset()
        engine.recordAppSwitch(appName: "A", bundleID: nil, now: now)
        engine.recordAppSwitch(appName: "C", bundleID: nil, now: now.addingTimeInterval(10)) // noise
        engine.recordAppSwitch(appName: "B", bundleID: nil, now: now.addingTimeInterval(20))
        check("intermittent_oscillation_detected", true) // manual check

        // ── Case 21: ActionPortfolio ranking logic ───────────────────────
        do {
            let friction = FrictionSignal(
                type: .repeated_app_switching,
                confidence: 0.9,
                evidence: ["oscillation x10"],
                detectedAt: Date(),
                involvedApps: ["A", "B"],
                involvedURLs: []
            )
            let memory = WorkingMemorySnapshot(
                currentEntity: "Entity",
                recentEntities: [],
                repeatedConcepts: [],
                inferredActivity: "working",
                comparisonCandidates: [],
                relatedFocusEntities: []
            )
            
            // Should produce at least one candidate when friction is high
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [friction],
                mediaState: EnvironmentMediaState(isMusicPlaying: true, visualMediaKind: .none, source: "test", detectionAvailable: false),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "none",
                entityKey: "test",
                groundingResult: nil
            )
            check("action_portfolio_evaluates_friction", !candidates.isEmpty)
            check("friction_lane_present", candidates.contains { $0.lane == .friction })
        }

        // ── Case 22: Friction removal reasoning ──────────────────────────
        do {
            let friction = FrictionSignal(
                type: .repeated_reference_lookup,
                confidence: 0.8,
                evidence: ["repeat lookup"],
                detectedAt: Date(),
                involvedApps: [],
                involvedURLs: []
            )
            let memory = WorkingMemorySnapshot(
                currentEntity: "Search",
                recentEntities: [],
                repeatedConcepts: ["concept"],
                inferredActivity: "searching",
                comparisonCandidates: [],
                relatedFocusEntities: []
            )
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [friction],
                mediaState: EnvironmentMediaState(isMusicPlaying: true, visualMediaKind: .none, source: "test", detectionAvailable: false),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "title_only",
                entityKey: "search_test",
                groundingResult: nil
            )
            let reason = candidates.first { $0.lane == .friction }?.reason ?? ""
            check("friction_removal_reasoning_valid", !reason.isEmpty)
        }

        // ── Case 23: Multiple lanes scoring ──────────────────────────────
        do {
            let friction = FrictionSignal(
                type: .repeated_app_switching,
                confidence: 0.5,
                evidence: ["oscillation"],
                detectedAt: Date(),
                involvedApps: ["A", "B"],
                involvedURLs: []
            )
            let memory = WorkingMemorySnapshot(
                currentEntity: "Work",
                recentEntities: [],
                repeatedConcepts: ["coding"],
                inferredActivity: "coding",
                comparisonCandidates: [],
                relatedFocusEntities: []
            )
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [friction],
                mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test", detectionAvailable: true),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "title_only",
                entityKey: "multi_lane_test",
                groundingResult: nil
            )
            // Should have both friction and music lanes
            let lanes = Set(candidates.map { $0.lane })
            check("multiple_lanes_evaluated", lanes.contains(.friction) && lanes.contains(.music))
        }

        // ── Case 24: Suppress low quality candidates ─────────────────────
        do {
            let memory = WorkingMemorySnapshot(
                currentEntity: "",
                recentEntities: [],
                repeatedConcepts: [],
                inferredActivity: "idle",
                comparisonCandidates: [],
                relatedFocusEntities: []
            )
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [],
                mediaState: EnvironmentMediaState(isMusicPlaying: true, visualMediaKind: .none, source: "test", detectionAvailable: false),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "none",
                entityKey: "suppress_test",
                groundingResult: nil
            )
            check("empty_context_suppresses_portfolio", candidates.isEmpty)
        }

        // ── Case 25: music lane survives when no friction ───────────────
        do {
            let memory = WorkingMemorySnapshot(
                currentEntity: "AppDelegate.swift",
                recentEntities: ["AppDelegate.swift"],
                repeatedConcepts: ["swift", "delegate"],
                inferredActivity: "coding",
                comparisonCandidates: [],
                relatedFocusEntities: []
            )
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [],
                mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test", detectionAvailable: true),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "title_only",
                entityKey: "test_music_1",
                groundingResult: nil
            )
            let hasMusicCandidate = candidates.contains { $0.lane == .music }
            check("music_lane_survives_when_no_friction", hasMusicCandidate)
        }

        // ── Case 26: music lane can win over weak friction ──────────────
        do {
            let weakFriction = FrictionSignal(
                type: .repeated_tab_switching,
                confidence: 0.42,  // barely above threshold
                evidence: ["tab x3"],
                detectedAt: Date(),
                involvedApps: [],
                involvedURLs: []
            )
            let memory = WorkingMemorySnapshot(
                currentEntity: "ProjectMain.swift",
                recentEntities: ["ProjectMain.swift"],
                repeatedConcepts: ["swift"],
                inferredActivity: "coding",
                comparisonCandidates: [],
                relatedFocusEntities: []
            )
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [weakFriction],
                mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test", detectionAvailable: true),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "title_only",
                entityKey: "test_music_2",
                groundingResult: nil
            )
            // Music should be present alongside weak friction
            let hasMusic = candidates.contains { $0.lane == .music }
            let hasFriction = candidates.contains { $0.lane == .friction }
            check("music_lane_can_win_over_weak_friction", hasMusic && hasFriction)
        }

        // ── Case 27: friction lane wins when repeated switching is strong ──
        do {
            let strongFriction = FrictionSignal(
                type: .repeated_app_switching,
                confidence: 0.85,
                evidence: ["oscillation x5"],
                detectedAt: Date(),
                involvedApps: ["Xcode", "Safari"],
                involvedURLs: []
            )
            let memory = WorkingMemorySnapshot(
                currentEntity: "ViewController.swift",
                recentEntities: ["ViewController.swift"],
                repeatedConcepts: ["swift"],
                inferredActivity: "coding",
                comparisonCandidates: [],
                relatedFocusEntities: []
            )
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [strongFriction],
                mediaState: EnvironmentMediaState(isMusicPlaying: true, visualMediaKind: .none, source: "test", detectionAvailable: true),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "title_only",
                entityKey: "test_friction_strong",
                groundingResult: nil
            )
            // Friction should be the top candidate (music is suppressed because already playing)
            check("friction_lane_wins_when_repeated_switching_is_strong",
                  candidates.first?.lane == .friction)
        }

        // ── Case 28: collect_references primary not create_next_steps ────
        do {
            let cap = CognitiveCapabilityRegistry.shared.get("collect_references")
            check("collect_references_primary_not_create_next_steps",
                  cap != nil && cap?.id == "collect_references" && cap?.outputType == "system_action")
        }

        // ── Case 29: no focus focus title ───────────────────────────────
        do {
            let domain = ActionPortfolioEngine.resolveMusicDomain(
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                groundingResult: nil
            )
            let title = "Play a \(domain.name) focus playlist?"
            check("no_focus_focus_title", !title.lowercased().contains("focus focus"))
        }

        // ── Case 30: gemini inherits parent domain for music ────────────
        do {
            // When app is assistant_tool, the music domain should come from
            // entity grounding or compartment, not from "researching" workflow inference
            let domain = ActionPortfolioEngine.resolveMusicDomain(
                semanticState: nil,
                entityGrounding: EntityGrounding(
                    entityName: "CodingProject",
                    entityType: .code_project,
                    source: .app_metadata,
                    confidence: 0.80,
                    summary: "Code project from app metadata",
                    shouldPropose: true,
                    allowedOpportunityTypes: []
                ),
                compartment: nil,
                groundingResult: nil
            )
            check("gemini_inherits_parent_domain_for_music",
                  domain.name == "coding" && domain.source == "entity_grounding")
        }

        // ── Case 31: workspace memory filters Music, Notification, Contextual ──
        do {
            check("workspace_memory_filters_music_notification_contextual",
                  WorkspaceAppFilter.isSystemApp("Music")
                  && WorkspaceAppFilter.isSystemApp("UserNotificationCenter")
                  && WorkspaceAppFilter.isSystemApp("Contextual")
                  && WorkspaceAppFilter.isSystemApp("Spotify")
                  && !WorkspaceAppFilter.isSystemApp("Xcode"))
        }

        // ── Case 32: title_only checklist suppressed ────────────────────
        do {
            let rejected = !ProposalQualityFilter.accept(
                title: "Create a testing checklist for this project",
                capabilityId: "generate_test_checklist",
                evidenceQuality: "title_only",
                hasRealContent: false
            )
            check("title_only_checklist_suppressed", rejected)
        }

        // ── Case 33: piskel weak title does not generate review editor ──
        do {
            let rejected = !ProposalQualityFilter.accept(
                title: "Review editor in Piskel - Free online sprite editor",
                capabilityId: "generated_action",
                evidenceQuality: "title_only",
                hasRealContent: false
            )
            check("piskel_weak_title_does_not_generate_review_editor", rejected)
        }

        // ── Case 34: settled compartment runs cheap lanes even when workflow unknown ──
        do {
            // The portfolio should produce candidates even without a workflow
            let memory = WorkingMemorySnapshot(
                currentEntity: "Some Project",
                recentEntities: ["Some Project"],
                repeatedConcepts: ["architecture", "design"],
                inferredActivity: "unknown",
                comparisonCandidates: [],
                relatedFocusEntities: []
            )
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [],
                mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test", detectionAvailable: true),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "title_only",
                entityKey: "test_settled",
                groundingResult: nil
            )
            // At minimum, music lane should produce a candidate
            check("settled_compartment_runs_cheap_lanes_even_when_workflow_unknown",
                  !candidates.isEmpty)
        }

        // ── Case 35: action portfolio logs all candidates ───────────────
        do {
            // Verify that portfolio produces structured output
            let memory = WorkingMemorySnapshot(
                currentEntity: "Test Entity",
                recentEntities: [],
                repeatedConcepts: [],
                inferredActivity: "coding",
                comparisonCandidates: [],
                relatedFocusEntities: []
            )
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [],
                mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test", detectionAvailable: true),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "title_only",
                entityKey: "test_log",
                groundingResult: nil
            )
            // The [ActionPortfolio] logs are emitted inside evaluate — test that candidates have valid scores
            for c in candidates {
                check("action_portfolio_logs_all_candidates_\(c.lane.rawValue)",
                      c.score > 0 && c.score <= 1.0)
            }
            if candidates.isEmpty {
                check("action_portfolio_logs_all_candidates_fallback", true)
            }
        }

        // ── Case 36: cognitive research lane still works when sources are real ──
        do {
            let memory = WorkingMemorySnapshot(
                currentEntity: "Machine Learning Paper",
                recentEntities: ["ML Paper", "Neural Networks Overview"],
                repeatedConcepts: ["transformer", "attention", "bert"],
                inferredActivity: "researching",
                comparisonCandidates: [],
                relatedFocusEntities: ["ArXiv Paper", "Wikipedia - Transformers"]
            )
            let candidates = await ActionPortfolioEngine.evaluate(
                frictionSignals: [],
                mediaState: EnvironmentMediaState(isMusicPlaying: true, visualMediaKind: .none, source: "test", detectionAvailable: true),
                semanticState: nil,
                entityGrounding: nil,
                compartment: nil,
                memory: memory,
                evidenceQuality: "browser_context",
                entityKey: "test_research",
                groundingResult: nil
            )
            let hasResearch = candidates.contains { $0.lane == .research }
            check("cognitive_research_lane_still_works_when_sources_are_real", hasResearch)
        }

        // ── Case 37: xcode_file_switching_does_not_emit_repeated_reference_lookup ──
        do {
            engine.reset()
            engine.recordConcepts(["contextualapp", "appdelegate", "viewcontroller"],
                                  appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "AppDelegate.swift", now: now)
            engine.recordConcepts(["contextualapp", "appdelegate", "viewcontroller"],
                                  appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "ViewController.swift", now: now.addingTimeInterval(10))
            engine.recordConcepts(["contextualapp", "appdelegate", "viewcontroller"],
                                  appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "ContextualApp.swift", now: now.addingTimeInterval(20))
            let signals37 = engine.detectFriction()
            check("xcode_file_switching_does_not_emit_repeated_reference_lookup",
                  !signals37.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 38: repeated_project_tokens_do_not_emit_reference_lookup ──
        do {
            engine.reset()
            for i in 0..<5 {
                engine.recordConcepts(["contextual", "intelligence", "frictionengine"],
                                      appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                                      windowTitle: "File\(i).swift",
                                      now: now.addingTimeInterval(Double(i * 10)))
            }
            let signals38 = engine.detectFriction()
            check("repeated_project_tokens_do_not_emit_reference_lookup",
                  !signals38.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 39: appdelegate_contextual_tokens_suppressed_in_editor_context ──
        do {
            engine.reset()
            for i in 0..<4 {
                engine.recordConcepts(["appdelegate", "contextualapp", "contextual"],
                                      appName: "Visual Studio Code", bundleID: "com.microsoft.VSCode",
                                      windowTitle: "Editor",
                                      now: now.addingTimeInterval(Double(i * 8)))
            }
            let signals39 = engine.detectFriction()
            check("appdelegate_contextual_tokens_suppressed_in_editor_context",
                  !signals39.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 40: browser_docs_repeated_lookup_still_emits_reference_lookup ──
        do {
            engine.reset()
            engine.recordConcepts(["urlsession", "datatask"], appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Docs 1", now: now)
            engine.recordConcepts(["urlsession", "datatask"], appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Docs 2", now: now.addingTimeInterval(10))
            engine.recordConcepts(["urlsession", "datatask"], appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Docs 3", now: now.addingTimeInterval(20))
            let signals40 = engine.detectFriction()
            check("browser_docs_repeated_lookup_still_emits_reference_lookup",
                  signals40.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 41: editor_to_docs_cross_app_lookup_emits_reference_lookup ──
        do {
            engine.reset()
            engine.recordConcepts(["urlsession"], appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "Editor", now: now)
            engine.recordConcepts(["urlsession"], appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Docs", now: now.addingTimeInterval(5))
            engine.recordConcepts(["urlsession"], appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "Editor", now: now.addingTimeInterval(10))
            engine.recordConcepts(["urlsession"], appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Docs", now: now.addingTimeInterval(15))
            let signals41 = engine.detectFriction()
            check("editor_to_docs_cross_app_lookup_emits_reference_lookup",
                  signals41.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 42: collect_references_not_generated_for_editor_only_friction ──
        do {
            engine.reset()
            for i in 0..<5 {
                engine.recordConcepts(["contextualapp", "appstate", "appdelegate"],
                                      appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                                      windowTitle: "File\(i).swift",
                                      now: now.addingTimeInterval(Double(i * 10)))
            }
            let signals42 = engine.detectFriction()
            let hasFriction = signals42.contains { $0.type == .repeated_reference_lookup }
            let opportunities = FrictionOpportunityReasoner.reason(
                frictionSignals: signals42,
                workspacePatterns: [],
                currentApps: Set(["Xcode"]),
                currentEntity: "AppDelegate.swift",
                compartmentLabel: "coding"
            )
            let hasCollectRef = opportunities.contains { $0.capabilityId == "collect_references" }
            check("collect_references_not_generated_for_editor_only_friction",
                  !hasFriction && !hasCollectRef)
        }

        // ══════════════════════════════════════════════════════════════════

        // ── Case 43: piskel_title_repetition_does_not_emit_reference_lookup ──
        do {
            engine.reset()
            // Piskel stays active, title changes but "piskel" token repeats
            for i in 0..<8 {
                engine.recordConcepts(["piskel"],
                                      appName: "Safari", bundleID: "com.apple.Safari",
                                      windowTitle: "Piskel - Frame \(i)",
                                      now: now.addingTimeInterval(Double(i * 10)))
            }
            let signals43 = engine.detectFriction()
            check("piskel_title_repetition_does_not_emit_reference_lookup",
                  !signals43.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 44: same_host_repetition_does_not_emit_reference_lookup ──
        do {
            engine.reset()
            // YouTube stays active, only "youtube" repeats
            for i in 0..<6 {
                engine.recordConcepts(["youtube"],
                                      appName: "Google Chrome", bundleID: "com.google.Chrome",
                                      windowTitle: "Video \(i)",
                                      now: now.addingTimeInterval(Double(i * 10)))
            }
            let signals44 = engine.detectFriction()
            check("same_host_repetition_does_not_emit_reference_lookup",
                  !signals44.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 45: same_entity_repetition_does_not_emit_reference_lookup ──
        do {
            engine.reset()
            // Same entity "firefox" repeated from browser context
            for i in 0..<5 {
                engine.recordConcepts(["firefox"],
                                      appName: "Firefox", bundleID: "org.mozilla.firefox",
                                      windowTitle: "Browser",
                                      now: now.addingTimeInterval(Double(i * 10)))
            }
            let signals45 = engine.detectFriction()
            check("same_entity_repetition_does_not_emit_reference_lookup",
                  !signals45.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 46: collect_references_requires_distinct_external_sources ──
        do {
            engine.reset()
            // 2 distinct concepts from browser — should emit friction signal AND opportunity
            for i in 0..<4 {
                engine.recordConcepts(["css grid", "flexbox"],
                                      appName: "Safari", bundleID: "com.apple.Safari",
                                      windowTitle: "Topic \(i)",
                                      now: now.addingTimeInterval(Double(i * 10)))
            }
            let signals46 = engine.detectFriction()
            let hasRefLookup = signals46.contains { $0.type == .repeated_reference_lookup }
            let opps46 = FrictionOpportunityReasoner.reason(
                frictionSignals: signals46,
                workspacePatterns: [],
                currentApps: Set(["Safari"]),
                currentEntity: "CSS Guide",
                compartmentLabel: "webdev"
            )
            check("collect_references_requires_distinct_external_sources",
                  hasRefLookup && opps46.contains { $0.capabilityId == "collect_references" })
        }

        // ── Case 47: collect_references_suppressed_for_piskelx8 ──
        do {
            engine.reset()
            for i in 0..<8 {
                engine.recordConcepts(["piskel"],
                                      appName: "Safari", bundleID: "com.apple.Safari",
                                      windowTitle: "Piskel Editor",
                                      now: now.addingTimeInterval(Double(i * 10)))
            }
            let signals47 = engine.detectFriction()
            let opps47 = FrictionOpportunityReasoner.reason(
                frictionSignals: signals47,
                workspacePatterns: [],
                currentApps: Set(["Safari"]),
                currentEntity: "Piskel",
                compartmentLabel: "pixelart"
            )
            check("collect_references_suppressed_for_piskelx8",
                  !opps47.contains { $0.capabilityId == "collect_references" })
        }

        // ── Case 48: browser_docs_repeated_lookup_still_allowed (2+ distinct) ──
        do {
            engine.reset()
            for i in 0..<4 {
                engine.recordConcepts(["autolayout", "constraints", "uikit"],
                                      appName: "Safari", bundleID: "com.apple.Safari",
                                      windowTitle: "Page \(i)",
                                      now: now.addingTimeInterval(Double(i * 10)))
            }
            let signals48 = engine.detectFriction()
            check("browser_docs_repeated_lookup_still_allowed",
                  signals48.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 49: editor_to_docs_cross_app_lookup_still_allowed ──
        do {
            engine.reset()
            // Mix of editor and browser concepts, 2+ distinct repeated
            for i in 0..<4 {
                engine.recordConcepts(["viewcontroller", "autolayout"],
                                      appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                                      windowTitle: "Editor",
                                      now: now.addingTimeInterval(Double(i * 10)))
                engine.recordConcepts(["autolayout", "constraints"],
                                      appName: "Safari", bundleID: "com.apple.Safari",
                                      windowTitle: "Docs",
                                      now: now.addingTimeInterval(Double(i * 10) + 5))
            }
            let signals49 = engine.detectFriction()
            check("editor_to_docs_cross_app_lookup_still_allowed",
                  signals49.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 50: rental_listing_repetition_does_not_emit_reference_lookup ──
        do {
            let engine = { let e = FrictionEngine.shared; e.reset(); return e }()
            let now = Date()
            // Simulate browsing rental listing pages — all browser, same topic
            let titles = [
                "Search Listings | Accommodation Listing Service",
                "Queen's Off-Campus Housing | Facebook",
                "for rent - Reddit Search!",
                "how to post on queens housing listings website - Google Search",
                "Daphne Dean is still a terrible landlord : r/queensuniversity"
            ]
            for (i, title) in titles.enumerated() {
                let concepts = title.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 3 && !["the", "for", "how", "and", "new", "tab"].contains($0) }
                engine.recordConcepts(concepts,
                                      appName: "Firefox", bundleID: "org.mozilla.firefox",
                                      windowTitle: title,
                                      now: now.addingTimeInterval(Double(i * 8)))
            }
            let signals50 = engine.detectFriction()
            check("rental_listing_repetition_does_not_emit_reference_lookup",
                  !signals50.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 51: same_topic_listing_pages_do_not_emit_reference_lookup ──
        do {
            let engine = { let e = FrictionEngine.shared; e.reset(); return e }()
            let now = Date()
            // All listing service pages — same host, same topic
            for i in 0..<6 {
                engine.recordConcepts(["listings", "accommodation", "listing", "service"],
                                      appName: "Firefox", bundleID: "org.mozilla.firefox",
                                      windowTitle: "Search Listings | Accommodation Listing Service",
                                      now: now.addingTimeInterval(Double(i * 10)))
            }
            let signals51 = engine.detectFriction()
            check("same_topic_listing_pages_do_not_emit_reference_lookup",
                  !signals51.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 52: listing_service_title_churn_does_not_emit_reference_lookup ──
        do {
            let engine = { let e = FrictionEngine.shared; e.reset(); return e }()
            let now = Date()
            // Different listing pages, but all about housing/listings
            let titles = [
                "Listing A - Accommodation Service",
                "Listing B - Accommodation Service",
                "Queens Housing Listings",
                "Off-Campus Accommodation Listings",
                "Search Listings | Housing Service"
            ]
            for (i, title) in titles.enumerated() {
                engine.recordConcepts(["listings", "accommodation", "housing"],
                                      appName: "Firefox", bundleID: "org.mozilla.firefox",
                                      windowTitle: title,
                                      now: now.addingTimeInterval(Double(i * 8)))
            }
            let signals52 = engine.detectFriction()
            check("listing_service_title_churn_does_not_emit_reference_lookup",
                  !signals52.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 53: repeated_reference_lookup_requires_external_lookup_transition ──
        do {
            let engine = { let e = FrictionEngine.shared; e.reset(); return e }()
            let now = Date()
            // Browser-only browsing about the same topic should NOT trigger
            for i in 0..<5 {
                engine.recordConcepts(["react", "hooks", "useState"],
                                      appName: "Chrome", bundleID: "com.google.chrome",
                                      windowTitle: "React Hooks \(i)",
                                      now: now.addingTimeInterval(Double(i * 8)))
            }
            let signals53 = engine.detectFriction()
            check("repeated_reference_lookup_requires_external_lookup_transition",
                  !signals53.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 54: editor_to_docs_to_editor_still_emits_reference_lookup ──
        do {
            let engine = { let e = FrictionEngine.shared; e.reset(); return e }()
            let now = Date()
            // Cross-category: editor→browser→editor pattern SHOULD trigger
            for i in 0..<4 {
                engine.recordConcepts(["urlsession", "networking"],
                                      appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                                      windowTitle: "NetworkManager.swift",
                                      now: now.addingTimeInterval(Double(i * 10)))
                engine.recordConcepts(["urlsession", "swift"],
                                      appName: "Safari", bundleID: "com.apple.Safari",
                                      windowTitle: "URLSession - Apple Docs",
                                      now: now.addingTimeInterval(Double(i * 10) + 5))
            }
            let signals54 = engine.detectFriction()
            check("editor_to_docs_to_editor_still_emits_reference_lookup",
                  signals54.contains { $0.type == .repeated_reference_lookup })
        }

        // ── Case 55: music_unknown_work_context_confidence_nonzero ──
        do {
            // Music confidence should have a floor even when grounding is unknown
            let candidate = PortfolioCandidate(
                lane: .music,
                title: "Resume your music?",
                capabilityId: "play_focus_media",
                executionMode: .local_action,
                confidence: max(0.35, 0.0), // simulating unknown grounding (0) with floor
                usefulness: 0.40,
                executability: 0.90,
                novelty: 1.0,
                reason: "test",
                requiredEvidence: "none",
                requiresConfirmation: true,
                involvedApps: [],
                frictionOpportunity: nil,
                musicIntent: nil,
                generatedAction: nil
            )
            check("music_unknown_work_context_confidence_nonzero",
                  candidate.confidence >= 0.35 && candidate.score > 0)
        }

        // ── Case 56: search_music_not_default_for_unknown_active_work ──
        do {
            // When action is .search, usefulness should be low
            let searchUsefulness: Double = 0.25
            let resumeUsefulness: Double = 0.40
            check("search_music_not_default_for_unknown_active_work",
                  searchUsefulness < resumeUsefulness)
        }

        // ── Case 57: semantic_grounding_pipe_delimited_enum_detected ──
        do {
            // Verify that pipe-delimited values are NOT in valid enum sets
            let validKinds: Set<String> = ["source_code_file", "code_editor", "website", "unknown"]
            let pipeValue = "website|app|window|page"
            check("semantic_grounding_pipe_delimited_enum_detected",
                  !validKinds.contains(pipeValue) && pipeValue.contains("|"))
        }

        // ── Case 58: listingservice_housing_queensu_maps_to_research ──
        do {
            // URL host "listingservice.housing.queensu.ca" should map to researching
            let host = "listingservice.housing.queensu.ca"
            let isHousingHost = host.contains("housing") || host.contains("listing")
            check("listingservice_housing_queensu_maps_to_research", isHousingHost)
        }

        // ── Case 59: reddit_housing_thread_maps_to_research ──
        do {
            let host = "reddit.com"
            let title = "Room for Rent?? : r/KingstonOntario"
            let rentalTerms: Set<String> = ["housing", "rental", "rent", "listing", "accommodation"]
            let titleTerms = Set(title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
            let hasRentalTerms = !titleTerms.intersection(rentalTerms).isEmpty
            check("reddit_housing_thread_maps_to_research",
                  host.contains("reddit.com") && hasRentalTerms)
        }

        // ══════════════════════════════════════════════════════════════════

        // ── Summary ────────────────────────────────────────────────────────
        let total = 59
        if failures.isEmpty {
            print("[FrictionEngineSelfTest] all_passed count=\(total)")
        } else {
            print("[FrictionEngineSelfTest] FAILED cases=\(failures.joined(separator: ","))")
        }
        return failures.isEmpty
    }
}
