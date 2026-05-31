import Foundation

public struct AmbientJarvisSuggestionSelfTest: Sendable {
    
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
        
        let ok = failures.isEmpty
        print("[AmbientJarvisSuggestionSelfTest] completed ok=\(ok)")
        return ok
    }
}
