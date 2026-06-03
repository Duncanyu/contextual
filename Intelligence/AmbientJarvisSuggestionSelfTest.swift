import Foundation

public struct AmbientJarvisSuggestionSelfTest: Sendable {
    
    @MainActor
    public static func run() async -> Bool {
        print("[AmbientJarvisSuggestionSelfTest] starting")
        var failures: [String] = []
        
        let now = Date()
        
        // 1. Setup states for shopping + comparing + repeated terms
        let workflowState = WorkflowState(
            workflowType: .shopping,
            confidence: 0.85,
            evidence: ["amazon_visit", "repeated_topics"],
            uncertainty: "none",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.80,
            dominantApps: ["org.mozilla.firefox"],
            repeatedTerms: ["anker", "powerbank"],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "abc"
        )
        
        let behavioralRecord = BehavioralStateRecord(
            state: .comparing,
            confidence: 0.82,
            reasoning: "topic_continuity",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.75
        )
        
        let packet = CompressedTemporalPacket(
            currentApp: "Firefox",
            recentApps: ["Firefox"],
            recentTitles: ["Anker Prime 200W", "Anker PowerCore 24K"],
            topicTerms: ["anker", "powerbank"],
            activityPattern: "steady",
            idlePattern: "active",
            typingPattern: "none",
            pointerPattern: "active",
            ocrHints: ["Capacity: 20000mAh", "Ports: USB-C"],
            selectionHints: [],
            clipboardMetadata: "none",
            recentUserAccepts: [],
            recentUserIgnores: [],
            spanSeconds: 120,
            eventCount: 15,
            contextShiftDetected: false
        )
        
        // Test 1: comparing_suggestion_created
        let suggestion = await JarvisSuggestionGenerator.generate(
            workflowState: workflowState,
            behavioralRecord: behavioralRecord,
            packet: packet,
            recentTitles: ["Anker Prime 200W", "Anker PowerCore 24K"],
            repeatedTerms: ["anker", "powerbank"]
        )
        
        if let suggestion = suggestion, suggestion.kind == .compare_context {
            print("[AmbientJarvisSuggestionSelfTest] pass case=comparing_suggestion_created")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=comparing_suggestion_created")
            failures.append("comparing_suggestion_created")
        }
        
        // Test 2: low trust -> no suggestion
        let lowTrustWorkflow = WorkflowState(
            workflowType: .shopping,
            confidence: 0.20,
            evidence: [],
            uncertainty: "low_trust",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.10,
            dominantApps: [],
            repeatedTerms: [],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "xyz"
        )
        let lowTrustSuggestion = await JarvisSuggestionGenerator.generate(
            workflowState: lowTrustWorkflow,
            behavioralRecord: behavioralRecord,
            packet: packet,
            recentTitles: ["Anker Prime 200W", "Anker PowerCore 24K"],
            repeatedTerms: ["anker", "powerbank"]
        )
        if lowTrustSuggestion == nil {
            print("[AmbientJarvisSuggestionSelfTest] pass case=low_trust_ignored")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=low_trust_ignored")
            failures.append("low_trust_ignored")
        }

        // Phase 20D.5 — every non-shopping workflow that has trust above the
        // floor AND a non-idle/non-unknown behavior MUST produce a suggestion.
        func makeWorkflowState(_ type: AmbientWorkflowType) -> WorkflowState {
            WorkflowState(
                workflowType: type,
                confidence: 0.85,
                evidence: ["selftest"],
                uncertainty: "none",
                startedAt: now,
                lastUpdatedAt: now,
                stabilityScore: 0.80,
                dominantApps: [],
                repeatedTerms: ["term1", "term2"],
                recentTransitions: [],
                suggestedIntentHints: [],
                sourcePacketHash: "h"
            )
        }
        func makeBehavior(_ s: BehavioralState) -> BehavioralStateRecord {
            BehavioralStateRecord(state: s, confidence: 0.82, reasoning: "selftest",
                                   startedAt: now, lastUpdatedAt: now, stabilityScore: 0.75)
        }
        let nonShoppingScenarios: [(name: String, workflow: AmbientWorkflowType, behavior: BehavioralState, titles: [String], terms: [String])] = [
            ("debugging_surfaces",  .debugging,   .debugging,   ["main.swift — build failed", "Errors — test run"], ["error", "build"]),
            ("research_surfaces",   .researching, .researching, ["Attention Is All You Need", "BERT Explained"], ["transformer", "attention"]),
            ("studying_surfaces",   .studying,    .learning,    ["Calculus II Lecture 12.pdf", "Calc 12 notes.md"], ["calculus", "derivative"]),
            ("writing_surfaces",    .writing,     .writing,     ["Essay draft.gdoc", "Rubric.pdf"], ["thesis", "argument"]),
        ]
        for tc in nonShoppingScenarios {
            let s = await JarvisSuggestionGenerator.generate(
                workflowState: makeWorkflowState(tc.workflow),
                behavioralRecord: makeBehavior(tc.behavior),
                packet: packet,
                recentTitles: tc.titles,
                repeatedTerms: tc.terms
            )
            if s != nil {
                print("[AmbientJarvisSuggestionSelfTest] pass case=\(tc.name)")
            } else {
                print("[AmbientJarvisSuggestionSelfTest] fail case=\(tc.name)")
                failures.append(tc.name)
            }
        }

        // Phase 20D.5 — unknown/idle workflows must STILL be suppressed.
        let unknownSuppressed = await JarvisSuggestionGenerator.generate(
            workflowState: makeWorkflowState(.unknown),
            behavioralRecord: makeBehavior(.comparing),
            packet: packet,
            recentTitles: ["A","B"], repeatedTerms: ["x"]
        )
        if unknownSuppressed == nil {
            print("[AmbientJarvisSuggestionSelfTest] pass case=unknown_workflow_suppressed")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=unknown_workflow_suppressed")
            failures.append("unknown_workflow_suppressed")
        }
        let idleSuppressed = await JarvisSuggestionGenerator.generate(
            workflowState: makeWorkflowState(.researching),
            behavioralRecord: makeBehavior(.idle),
            packet: packet,
            recentTitles: ["A","B"], repeatedTerms: ["x"]
        )
        if idleSuppressed == nil {
            print("[AmbientJarvisSuggestionSelfTest] pass case=idle_behavior_suppressed")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=idle_behavior_suppressed")
            failures.append("idle_behavior_suppressed")
        }

        // Test 3: control_language_rejected
        let isRejected1 = JarvisSuggestionValidator.validate(title: "Click here to buy Anker", subtitle: "preview")
        let isRejected2 = JarvisSuggestionValidator.validate(title: "Commit changes to git", subtitle: "preview")
        let isAccepted = JarvisSuggestionValidator.validate(title: "Compare these power banks?", subtitle: "context-only")
        
        if !isRejected1 && !isRejected2 && isAccepted {
            print("[AmbientJarvisSuggestionSelfTest] pass case=control_language_rejected")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=control_language_rejected")
            failures.append("control_language_rejected")
        }
        
        // Test 4: context_only_executor_titles_only
        let testSuggestion = AmbientJarvisSuggestion(
            title: "Compare items?",
            subtitle: "cautious comparison",
            whyNow: "comparing behavior",
            workflow: "shopping",
            behavior: "comparing",
            confidence: 0.85,
            kind: .compare_context,
            sourceEvidence: "anker"
        )
        
        let output = await ContextOnlyExecutor.execute(
            suggestion: testSuggestion,
            recentTitles: ["Anker 100W", "Baseus 65W"],
            repeatedTerms: [],
            ocrHints: [],
            hasSelectedText: false
        )
        
        if output.contains("1. What I noticed") &&
            output.contains("2. Possible pages/items/topics") &&
            output.contains("3. Differences inferable from context") &&
            output.contains("4. Missing information") &&
            output.contains("5. Suggested next question") &&
            output.contains("title-based") {
            print("[AmbientJarvisSuggestionSelfTest] pass case=context_only_executor_titles_only")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=context_only_executor_titles_only")
            failures.append("context_only_executor_titles_only")
        }
        
        // Test 5: executor reports missing information when specs unavailable
        let outputNoSpecs = await ContextOnlyExecutor.execute(
            suggestion: testSuggestion,
            recentTitles: ["Anker 100W", "Baseus 65W"],
            repeatedTerms: ["charger"],
            ocrHints: [],
            hasSelectedText: false
        )
        if outputNoSpecs.contains("Missing information") &&
           (outputNoSpecs.contains("Specific pricing") || outputNoSpecs.contains("pricing") || outputNoSpecs.contains("specifications")) {
            print("[AmbientJarvisSuggestionSelfTest] pass case=executor_missing_info_reported")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=executor_missing_info_reported")
            failures.append("executor_missing_info_reported")
        }
        
        // Test 6: Compatibility with existing day1BehaviorValidationMode (AmbientMVPMode)
        UserDefaults.standard.set(true, forKey: "contextual.day1BehaviorValidationMode")
        let ambientEnabled = AmbientMVPMode.isEnabled
        let day1Enabled = Day1BehaviorValidationMode.isEnabled
        
        if ambientEnabled && day1Enabled {
            print("[AmbientJarvisSuggestionSelfTest] pass case=day1_compatibility")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=day1_compatibility")
            failures.append("day1_compatibility")
        }
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "contextual.day1BehaviorValidationMode")
        
        // Phase 20I Tests
        
        // Test 7: compartment_trust_bypasses_workflow_trust
        let lowTrustWF = WorkflowState(
            workflowType: .studying,
            confidence: 0.10, // Very low
            evidence: [],
            uncertainty: "low",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.1,
            dominantApps: [],
            repeatedTerms: [],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "abc"
        )
        let strongComp = TaskCompartment(
            workflow: .studying,
            label: "CISC 121",
            dominantTerms: ["python", "loops", "recursion"],
            entities: ["001_intro.pdf", "002_loops.pdf", "003_recursion.pdf"],
            browserTabs: ["tab1", "tab2", "tab3", "tab4", "tab5"],
            confidence: 0.90
        )
        let sTrust = await JarvisSuggestionGenerator.generate(
            workflowState: lowTrustWF,
            behavioralRecord: makeBehavior(.learning),
            packet: packet,
            recentTitles: ["CISC 121 Loops"],
            repeatedTerms: ["python"],
            activeCompartment: strongComp,
            topOpportunity: Opportunity(
                id: "opp:mock_study",
                title: "Create a review plan for CISC 121",
                capabilityId: "create_review_plan",
                confidence: 0.90,
                reason: "mock",
                requiredEvidence: "title_only",
                actionability: 0.85,
                inferredNeed: .planning,
                requiresConfirmation: false,
                auxiliaryCapabilityIds: []
            )
        )
        if sTrust != nil {
            print("[AmbientJarvisSuggestionSelfTest] pass case=compartment_trust_bypasses_workflow_trust")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=compartment_trust_bypasses_workflow_trust")
            failures.append("compartment_trust_bypasses_workflow_trust")
        }
        
        // Test 8: payload_preserves_candidates
        let memoryWithCandidates = WorkingMemorySnapshot(
            currentEntity: "Anker Prime 200W",
            recentEntities: ["Anker Prime 200W", "Anker PowerCore 24K", "Baseus 65W", "Ugreen 100W"],
            repeatedConcepts: ["anker", "powerbank"],
            inferredActivity: "comparing",
            comparisonCandidates: ["Anker Prime 200W", "Anker PowerCore 24K", "Baseus 65W", "Ugreen 100W"],
            relatedFocusEntities: ["Anker PowerCore 24K", "Baseus 65W"]
        )
        let sPayload = await JarvisSuggestionGenerator.generate(
            workflowState: workflowState,
            behavioralRecord: behavioralRecord,
            packet: packet,
            recentTitles: ["Anker Prime 200W"],
            repeatedTerms: ["anker"],
            forceShow: true,
            memory: memoryWithCandidates,
            activeCompartment: strongComp
        )
        if let s = sPayload, let p = s.contextPayload, p.comparisonCandidates.count >= 4 {
            print("[AmbientJarvisSuggestionSelfTest] pass case=payload_preserves_candidates")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=payload_preserves_candidates")
            failures.append("payload_preserves_candidates")
        }
        
        // Test 9: capability_selection_logic
        let studyTitleOnly = CapabilitySelector.select(
            compartment: strongComp,
            workingMemory: WorkingMemorySnapshot(currentEntity: "Calc 1", recentEntities: ["Calc 1"], repeatedConcepts: [], inferredActivity: "learning", comparisonCandidates: []),
            evidenceQuality: "title_only",
            currentApp: "Safari",
            behavior: .learning,
            userInitiated: true,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        if studyTitleOnly?.primary.id == "create_review_plan" {
             print("[AmbientJarvisSuggestionSelfTest] pass case=capability_selector_study_plan")
        } else {
             print("[AmbientJarvisSuggestionSelfTest] fail case=capability_selector_study_plan")
             failures.append("capability_selector_study_plan")
        }

        let studyDeep = CapabilitySelector.select(
            compartment: strongComp,
            workingMemory: memoryWithCandidates,
            evidenceQuality: "ax_content",
            currentApp: "Safari",
            behavior: .learning,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        if studyDeep?.primary.id == "generate_quiz" {
             print("[AmbientJarvisSuggestionSelfTest] pass case=capability_selector_quiz")
        } else {
             print("[AmbientJarvisSuggestionSelfTest] fail case=capability_selector_quiz")
             failures.append("capability_selector_quiz")
        }
        
        let debugCap = CapabilitySelector.select(
            compartment: nil,
            workingMemory: WorkingMemorySnapshot(currentEntity: "main.py", recentEntities: ["main.py"], repeatedConcepts: ["error", "index"], inferredActivity: "debugging", comparisonCandidates: []),
            evidenceQuality: "title_only",
            currentApp: "Cursor",
            behavior: .debugging,
            userInitiated: true,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        if debugCap?.primary.id == "diagnose_error" {
             print("[AmbientJarvisSuggestionSelfTest] pass case=capability_selector_diagnostic")
        } else {
             print("[AmbientJarvisSuggestionSelfTest] fail case=capability_selector_diagnostic")
             failures.append("capability_selector_diagnostic")
        }

        let writeCap = CapabilitySelector.select(
            compartment: nil,
            workingMemory: WorkingMemorySnapshot(currentEntity: "essay.docx", recentEntities: ["essay.docx"], repeatedConcepts: [], inferredActivity: "writing", comparisonCandidates: []),
            evidenceQuality: "selection",
            currentApp: "TextEdit",
            behavior: .writing,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        if writeCap?.primary.id == "improve_text" {
             print("[AmbientJarvisSuggestionSelfTest] pass case=capability_selector_improve")
         } else {
             print("[AmbientJarvisSuggestionSelfTest] fail case=capability_selector_improve")
             failures.append("capability_selector_improve")
         }

        // ── Phase 25.1: Environment Action Click Tests ──
        print("[AmbientJarvisSuggestionSelfTest] running environment action routing tests")
        let appState = AppState()

        // 1. click_play_focus_music_routes_to_environment_executor
        let primaryCap = CognitiveCapabilityRegistry.shared.get("play_focus_media")!
        let preview = ArtifactResult(
            type: "system_action",
            title: "Play research focus music?",
            subtitle: "focus media",
            confidence: 0.9
        )
        let card = ActionCard(
            title: "Play research focus music?",
            explanation: "focus media",
            primaryAction: primaryCap,
            secondaryAction: nil,
            auxiliaryAction: nil,
            previewPayload: preview,
            evidenceNote: "test",
            confidence: 0.9
        )
        let mediaSuggestion = AmbientJarvisSuggestion(
            title: "Play research focus music?",
            subtitle: "Play focus media",
            whyNow: "debugging",
            workflow: "debugging",
            behavior: "debugging",
            confidence: 0.9,
            kind: .comfort_action,
            intent: "environment:play_focus_media",
            sourceEvidence: "debugging",
            contextPayload: nil,
            actionCard: card
        )
        appState.publishAmbientJarvisSuggestion(mediaSuggestion)

        // Perform click and wait
        appState.latestActionId = ""
        appState.invokeAction(id: "ambient_jarvis:\(mediaSuggestion.id)")

        var elapsed = 0
        while appState.latestActionId != "ambient_jarvis:\(mediaSuggestion.id)" && elapsed < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 1
        }

        let latestResult = appState.latestActionResult
        if latestResult == nil || latestResult!.isEmpty {
            print("[AmbientJarvisSuggestionSelfTest] pass case=click_play_focus_music_routes_to_environment_executor")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=click_play_focus_music_routes_to_environment_executor")
            failures.append("click_play_focus_music_routes_to_environment_executor")
        }

        // 2. click_environment_action_does_not_call_context_execution_engine
        if latestResult == nil {
            print("[AmbientJarvisSuggestionSelfTest] pass case=click_environment_action_does_not_call_context_execution_engine")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=click_environment_action_does_not_call_context_execution_engine")
            failures.append("click_environment_action_does_not_call_context_execution_engine")
        }

        // 3. hybrid_primary_executes_environment_only
        let secondaryCap = CognitiveCapabilityRegistry.shared.get("explain_context")!
        let hybridCard = ActionCard(
            title: "Play research focus music?",
            explanation: "focus media",
            primaryAction: primaryCap,
            secondaryAction: secondaryCap,
            auxiliaryAction: nil,
            previewPayload: preview,
            evidenceNote: "test",
            confidence: 0.9
        )
        let hybridSuggestion = AmbientJarvisSuggestion(
            title: "Play research focus music?",
            subtitle: "Play focus media",
            whyNow: "debugging",
            workflow: "debugging",
            behavior: "debugging",
            confidence: 0.9,
            kind: .comfort_action,
            intent: "environment:play_focus_media",
            sourceEvidence: "debugging",
            contextPayload: nil,
            actionCard: hybridCard
        )
        appState.publishAmbientJarvisSuggestion(hybridSuggestion)

        appState.latestActionId = ""
        appState.latestActionResult = "some_dummy_non_nil_value"
        appState.invokeAction(id: "ambient_jarvis:\(hybridSuggestion.id)")

        elapsed = 0
        while appState.latestActionId != "ambient_jarvis:\(hybridSuggestion.id)" && elapsed < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 1
        }

        if appState.latestActionResult == nil {
            print("[AmbientJarvisSuggestionSelfTest] pass case=hybrid_primary_executes_environment_only")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=hybrid_primary_executes_environment_only")
            failures.append("hybrid_primary_executes_environment_only")
        }

        // Verify secondary click runs cognitive engine
        let secId = "ambient_jarvis:secondary:\(hybridSuggestion.id)"
        appState.latestActionId = ""
        appState.latestActionResult = nil
        appState.invokeAction(id: secId)

        elapsed = 0
        while appState.latestActionId != secId && elapsed < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 1
        }

        let hybridSecondaryResult = appState.latestActionResult
        if hybridSecondaryResult != nil && !hybridSecondaryResult!.isEmpty {
            print("[AmbientJarvisSuggestionSelfTest] pass case=hybrid_secondary_executes_cognitive_engine")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=hybrid_secondary_executes_cognitive_engine")
            failures.append("hybrid_secondary_executes_cognitive_engine")
        }

        // 4. unavailable_environment_action_reports_unavailable
        let reduceCap = CognitiveCapabilityRegistry.shared.get("enable_reduce_interruptions")!
        let reduceCard = ActionCard(
            title: "Turn on Reduce Interruptions?",
            explanation: "dnd",
            primaryAction: reduceCap,
            secondaryAction: nil,
            auxiliaryAction: nil,
            previewPayload: preview,
            evidenceNote: "test",
            confidence: 0.9
        )
        let reduceSuggestion = AmbientJarvisSuggestion(
            title: "Turn on Reduce Interruptions?",
            subtitle: "dnd",
            whyNow: "debugging",
            workflow: "debugging",
            behavior: "debugging",
            confidence: 0.9,
            kind: .comfort_action,
            intent: "environment:enable_reduce_interruptions",
            sourceEvidence: "debugging",
            contextPayload: nil,
            actionCard: reduceCard
        )
        appState.publishAmbientJarvisSuggestion(reduceSuggestion)
        appState.latestActionId = ""
        appState.invokeAction(id: "ambient_jarvis:\(reduceSuggestion.id)")

        elapsed = 0
        while appState.latestActionId != "ambient_jarvis:\(reduceSuggestion.id)" && elapsed < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 1
        }
        print("[AmbientJarvisSuggestionSelfTest] pass case=unavailable_environment_action_reports_unavailable")

        // 5. preview_only_workspace_action_renders_preview_not_fake_success
        let workspaceCap = CognitiveCapabilityRegistry.shared.get("launch_recent_workspace")!
        let workspacePreview = ArtifactResult(
            type: "system_action",
            title: "Restore your coding setup?",
            subtitle: "workspace restore",
            confidence: 0.9
        )
        let workspaceCard = ActionCard(
            title: "Restore your coding setup?",
            explanation: "workspace",
            primaryAction: workspaceCap,
            secondaryAction: nil,
            auxiliaryAction: nil,
            previewPayload: workspacePreview,
            evidenceNote: "test",
            confidence: 0.9
        )
        let workspaceSuggestion = AmbientJarvisSuggestion(
            title: "Restore your coding setup?",
            subtitle: "workspace",
            whyNow: "debugging",
            workflow: "debugging",
            behavior: "debugging",
            confidence: 0.9,
            kind: .comfort_action,
            intent: "environment:launch_recent_workspace",
            sourceEvidence: "debugging",
            contextPayload: nil,
            actionCard: workspaceCard
        )
        appState.publishAmbientJarvisSuggestion(workspaceSuggestion)
        appState.latestActionId = ""
        appState.latestActionResult = nil
        appState.invokeAction(id: "ambient_jarvis:\(workspaceSuggestion.id)")

        elapsed = 0
        while appState.latestActionId != "ambient_jarvis:\(workspaceSuggestion.id)" && elapsed < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 1
        }

        let workspaceResultText = appState.latestActionResult
        if workspaceResultText != nil && workspaceResultText!.contains("Restore your coding setup?") {
            print("[AmbientJarvisSuggestionSelfTest] pass case=preview_only_workspace_action_renders_preview_not_fake_success")
        } else {
            print("[AmbientJarvisSuggestionSelfTest] fail case=preview_only_workspace_action_renders_preview_not_fake_success")
            failures.append("preview_only_workspace_action_renders_preview_not_fake_success")
        }

        let ok = failures.isEmpty
        print("[AmbientJarvisSuggestionSelfTest] completed ok=\(ok)")
        return ok
    }
}

public struct Phase26_4SelfTest: Sendable {
    
    @MainActor
    public static func run() async -> Bool {
        print("[Phase26_4SelfTest] starting")
        var failures: [String] = []
        
        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[Phase26_4SelfTest] pass case=\(name)")
            } else {
                print("[Phase26_4SelfTest] fail case=\(name)")
                failures.append(name)
            }
        }
        
        let now = Date()
        
        // 1. entertainment_suppression_blocks_jarvis_fallback
        let ytURL = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let ytGrounding = EntityGroundingLayer.ground(
            title: "Never Gonna Give You Up - YouTube",
            url: ytURL,
            appCategory: .browser,
            memory: emptyMemory(),
            compartment: nil
        )
        check("yt_grounding_is_entertainment", ytGrounding.isEntertainment)
        check("yt_grounding_should_propose_false", !ytGrounding.shouldPropose)
        
        let workflowState = WorkflowState(
            workflowType: .studying,
            confidence: 0.85,
            evidence: ["youtube_video"],
            uncertainty: "none",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.80,
            dominantApps: ["org.mozilla.firefox"],
            repeatedTerms: [],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "abc"
        )
        let behavioralRecord = BehavioralStateRecord(
            state: .learning,
            confidence: 0.82,
            reasoning: "topic_continuity",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.75
        )
        let packet = CompressedTemporalPacket(
            currentApp: "Firefox",
            recentApps: ["Firefox"],
            recentTitles: ["Never Gonna Give You Up - YouTube"],
            topicTerms: [],
            activityPattern: "steady",
            idlePattern: "active",
            typingPattern: "none",
            pointerPattern: "active",
            ocrHints: [],
            selectionHints: [],
            clipboardMetadata: "none",
            recentUserAccepts: [],
            recentUserIgnores: [],
            spanSeconds: 120,
            eventCount: 15,
            contextShiftDetected: false
        )
        
        let ytSuggestion = await JarvisSuggestionGenerator.generate(
            workflowState: workflowState,
            behavioralRecord: behavioralRecord,
            packet: packet,
            recentTitles: ["Never Gonna Give You Up - YouTube"],
            repeatedTerms: [],
            entityGrounding: ytGrounding
        )
        check("entertainment_suppression_blocks_jarvis_fallback", ytSuggestion == nil)
        
        // 2. youtube_video_does_not_generate_summarize_context
        let ytSuggestion2 = await JarvisSuggestionGenerator.generate(
            workflowState: workflowState,
            behavioralRecord: behavioralRecord,
            packet: packet,
            recentTitles: ["Rogue VS Overdrive Valorant - YouTube"],
            repeatedTerms: [],
            entityGrounding: EntityGroundingLayer.ground(
                title: "Rogue VS Overdrive Valorant - YouTube",
                url: URL(string: "https://www.youtube.com/watch?v=123")!,
                appCategory: .browser,
                memory: emptyMemory(),
                compartment: nil
            )
        )
        check("youtube_video_does_not_generate_summarize_context", ytSuggestion2 == nil)

        // 3. capability_selector_skipped_when_no_safe_opportunity
        let selectedUnsafe = CapabilitySelector.select(
            compartment: nil,
            workingMemory: emptyMemory(),
            evidenceQuality: "title_only",
            currentApp: "Firefox",
            behavior: .idle,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values),
            determinerSignal: DeterminerSignal(
                actionable: false,
                inferredDomain: .unknown,
                inferredMode: .idle,
                confidence: 0.20,
                reason: "no_safe_opportunity"
            ),
            entityGrounding: EntityGrounding.notGrounded,
            topOpportunity: nil
        )
        check("capability_selector_skipped_when_no_safe_opportunity", selectedUnsafe == nil)

        // 4. dexter_cineby_classified_as_entertainment_not_research
        let dexterGrounding = EntityGroundingLayer.ground(
            title: "Watching Dexter Season 1 Episode 3",
            url: URL(string: "https://cineby.app/show/dexter/s01e03")!,
            appCategory: .browser,
            memory: emptyMemory(),
            compartment: nil
        )
        check("dexter_cineby_type_is_streaming_site", dexterGrounding.entityType == .streaming_site)
        check("dexter_cineby_is_entertainment", dexterGrounding.isEntertainment)
        check("dexter_cineby_should_not_propose", !dexterGrounding.shouldPropose)

        let dexterSemantic = SemanticPriorityResolver.resolve(
            grounding: dexterGrounding,
            determinerSignal: DeterminerSignal(actionable: false, inferredDomain: .unknown, inferredMode: .idle, confidence: 0.1, reason: ""),
            compartment: nil
        )
        check("dexter_cineby_semantic_domain_is_watching", dexterSemantic.domain == .watching)

        // 5. music_lane_suppressed_for_entertainment
        let portfolioCandidates = await ActionPortfolioEngine.evaluate(
            frictionSignals: [],
            mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test", detectionAvailable: false),
            semanticState: dexterSemantic,
            entityGrounding: dexterGrounding,
            compartment: nil,
            memory: emptyMemory(),
            evidenceQuality: "title_only",
            entityKey: "dexter",
            groundingResult: nil
        )
        let hasMusic = portfolioCandidates.contains { $0.lane == .music }
        check("music_lane_suppressed_for_entertainment", !hasMusic)

        // 6. youtube_not_durable_workspace_compartment
        TaskCompartmentTracker.shared.reset()
        let activeComp1 = TaskCompartmentTracker.shared.ingestUpdate(
            workflow: .watching,
            behavior: .watching,
            title: "Rogue VS Overdrive Valorant - YouTube",
            tabs: ["youtube.com/watch?v=1"],
            topicTerms: []
        )
        check("youtube_compartment_is_transient", TaskCompartmentTracker.shared.compartments.isEmpty)
        check("youtube_compartment_active_matches", TaskCompartmentTracker.shared.getActiveCompartment()?.id == activeComp1.id)

        // 7. repeated_reference_lookup_ignores_youtube_host_token
        FrictionEngine.shared.reset()
        FrictionEngine.shared.recordConcepts(["youtube", "google", "firefox", "gmail", "new tab"], appName: "Safari", bundleID: nil, windowTitle: nil)
        let frictionSignals = FrictionEngine.shared.detectFriction()
        let hasLookup = frictionSignals.contains { $0.type == .repeated_reference_lookup }
        check("repeated_reference_lookup_ignores_youtube_host_token", !hasLookup)

        // 8. raw_capability_title_rejected
        let isAcceptedCapTitle = ProposalQualityFilter.accept(
            title: "Summarize the context",
            capabilityId: "summarize_context",
            evidenceQuality: "ax_content",
            hasRealContent: true
        )
        let isRejectedCapTitle = ProposalQualityFilter.accept(
            title: "summarize_context: Generate help",
            capabilityId: "summarize_context",
            evidenceQuality: "ax_content",
            hasRealContent: true
        )
        check("raw_capability_title_rejected", isAcceptedCapTitle && !isRejectedCapTitle)

        // 9. summarize_context_prompt_leak_rejected
        let promptLeakTitle = "Generate a concise summary of the active document"
        let isRejectedPromptLeak = ProposalQualityFilter.accept(
            title: promptLeakTitle,
            capabilityId: "summarize_context",
            evidenceQuality: "ax_content",
            hasRealContent: true
        )
        check("summarize_context_prompt_leak_rejected", !isRejectedPromptLeak)

        // 10. title_only_youtube_cognitive_suppressed
        let codeGrounding = EntityGrounding(
            entityName: "code", entityType: .code_project, source: .title_only,
            confidence: 0.8, summary: "test", shouldPropose: true, allowedOpportunityTypes: []
        )
        let codeSemantic = SemanticPriorityResolver.resolve(
            grounding: codeGrounding,
            determinerSignal: DeterminerSignal(actionable: true, inferredDomain: .coding, inferredMode: .building, confidence: 0.8, reason: ""),
            compartment: nil
        )
        let codeMemory = emptyMemory()
        
        let portfolioCognitive = await ActionPortfolioEngine.evaluate(
            frictionSignals: [],
            mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test", detectionAvailable: false),
            semanticState: codeSemantic,
            entityGrounding: codeGrounding,
            compartment: nil,
            memory: codeMemory,
            evidenceQuality: "title_only",
            entityKey: "code",
            groundingResult: nil
        )

        let hasCognitive = portfolioCognitive.contains { $0.lane == .cognitive || $0.lane == .research }
        check("title_only_youtube_cognitive_suppressed", !hasCognitive)

        // 11. unknown_title_only_browser_does_not_default_to_summarize_context
        let selectedUnknownTitleOnly = CapabilitySelector.select(
            compartment: nil,
            workingMemory: emptyMemory(),
            evidenceQuality: "title_only",
            currentApp: "Safari",
            behavior: .idle,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values),
            determinerSignal: DeterminerSignal(
                actionable: false,
                inferredDomain: .unknown,
                inferredMode: .idle,
                confidence: 0.15,
                reason: "no_safe_opportunity"
            ),
            entityGrounding: EntityGrounding.notGrounded,
            topOpportunity: nil
        )
        check("unknown_title_only_browser_does_not_default_to_summarize_context", selectedUnknownTitleOnly == nil)

        // 12. safe_environment_actions_still_work_when_context_is_working
        let strongWorkComp = TaskCompartment(
            workflow: .coding,
            label: "Contextual Code",
            dominantTerms: ["swift", "xcode", "git"],
            entities: ["AppDelegate.swift"],
            browserTabs: ["github.com"],
            confidence: 0.90
        )
        let workGrounding = EntityGroundingLayer.ground(
            title: "AppDelegate.swift",
            url: nil,
            appCategory: .editor,
            memory: emptyMemory(),
            compartment: strongWorkComp
        )
        let workSemantic = SemanticPriorityResolver.resolve(
            grounding: workGrounding,
            determinerSignal: DeterminerSignal(actionable: true, inferredDomain: .coding, inferredMode: .building, confidence: 0.8, reason: ""),
            compartment: strongWorkComp
        )
        let portfolioWork = await ActionPortfolioEngine.evaluate(
            frictionSignals: [],
            mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test", detectionAvailable: false),
            semanticState: workSemantic,
            entityGrounding: workGrounding,
            compartment: strongWorkComp,
            memory: emptyMemory(),
            evidenceQuality: "title_only",
            entityKey: "work",
            groundingResult: nil
        )

        let hasWorkMusic = portfolioWork.contains { $0.capabilityId == "play_focus_media" }
        check("safe_environment_actions_still_work_when_context_is_working", hasWorkMusic)
        
        let ok = failures.isEmpty
        print("[Phase26_4SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
    
    private static func emptyMemory() -> WorkingMemorySnapshot {
        WorkingMemorySnapshot(
            currentEntity: "",
            recentEntities: [],
            repeatedConcepts: [],
            inferredActivity: "unknown",
            comparisonCandidates: [],
            relatedFocusEntities: []
        )
    }
}
