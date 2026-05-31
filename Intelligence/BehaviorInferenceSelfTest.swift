import Foundation

public enum BehaviorInferenceSelfTest {

    public static func run() async -> Bool {
        print("[BehaviorInferenceSelfTest] starting")
        var failures: [String] = []
        
        let now = Date()
        
        // 1) Test 1: long_research_session
        let researchWindow = TemporalContextWindow(
            durationSeconds: 300,
            eventCount: 15,
            dominantApps: ["Browser"],
            titleTransitions: 5,
            appTransitions: 0,
            repeatedTerms: ["quantum", "algorithm"],
            activityBursts: 2,
            idleSeconds: 0,
            typingScore: 0.2,
            pointerScore: 0.4,
            recentTitles: [],
            transitions: [],
            termFirstSeen: [:],
            termLastSeen: [:],
            titleFirstSeen: [:],
            titleLastSeen: [:],
            eventCountsByType: [:],
            droppedOutsideWindow: 0,
            termWeightedScores: [:],
            termRawCounts: [:],
            ocrEventTerms: [],
            ocrEventTermScores: [:],
            contextShift: .noShift
        )
        let researchWorkflow = WorkflowState(
            workflowType: .researching,
            confidence: 0.8,
            evidence: ["quantum"],
            uncertainty: "",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.8,
            dominantApps: ["Browser"],
            repeatedTerms: ["quantum"],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "hash"
        )
        
        let coordinator = BehavioralIntelligenceCoordinator()
        let result1 = await coordinator.tick(
            workflowState: researchWorkflow,
            shortWindow: researchWindow,
            now: now,
            backend: SignalDrivenStubBehavioralBackend()
        )
        
        if result1.state == .researching && result1.confidence == 0.81 && result1.stabilityScore == 0.5 {
            print("[BehaviorInferenceSelfTest] pass case=long_research_session")
        } else {
            print("[BehaviorInferenceSelfTest] fail case=long_research_session got=\(result1.state.rawValue) conf=\(result1.confidence) stability=\(result1.stabilityScore)")
            failures.append("long_research_session")
        }
        
        // 2) Test 2: product_comparison_session
        let comparisonWindow = TemporalContextWindow(
            durationSeconds: 300,
            eventCount: 12,
            dominantApps: ["Browser"],
            titleTransitions: 4,
            appTransitions: 1,
            repeatedTerms: ["price", "hub"],
            activityBursts: 1,
            idleSeconds: 0,
            typingScore: 0.1,
            pointerScore: 0.3,
            recentTitles: [],
            transitions: [],
            termFirstSeen: [:],
            termLastSeen: [:],
            titleFirstSeen: [:],
            titleLastSeen: [:],
            eventCountsByType: [:],
            droppedOutsideWindow: 0,
            termWeightedScores: [:],
            termRawCounts: [:],
            ocrEventTerms: [],
            ocrEventTermScores: [:],
            contextShift: .noShift
        )
        let result2 = await coordinator.tick(
            workflowState: researchWorkflow,
            shortWindow: comparisonWindow,
            now: now.addingTimeInterval(10),
            backend: SignalDrivenStubBehavioralBackend()
        )
        
        if result2.state == .comparing && result2.confidence == 0.82 {
            print("[BehaviorInferenceSelfTest] pass case=product_comparison_session")
        } else {
            print("[BehaviorInferenceSelfTest] fail case=product_comparison_session got=\(result2.state.rawValue)")
            failures.append("product_comparison_session")
        }
        
        // 3) Test 3: coding_session
        let codingWindow = TemporalContextWindow(
            durationSeconds: 300,
            eventCount: 20,
            dominantApps: ["Editor"],
            titleTransitions: 1,
            appTransitions: 0,
            repeatedTerms: ["func", "class"],
            activityBursts: 5,
            idleSeconds: 0,
            typingScore: 0.8,
            pointerScore: 0.2,
            recentTitles: [],
            transitions: [],
            termFirstSeen: [:],
            termLastSeen: [:],
            titleFirstSeen: [:],
            titleLastSeen: [:],
            eventCountsByType: [:],
            droppedOutsideWindow: 0,
            termWeightedScores: [:],
            termRawCounts: [:],
            ocrEventTerms: [],
            ocrEventTermScores: [:],
            contextShift: .noShift
        )
        let codingWorkflow = WorkflowState(
            workflowType: .coding,
            confidence: 0.85,
            evidence: ["func"],
            uncertainty: "",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.8,
            dominantApps: ["Editor"],
            repeatedTerms: ["func"],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "hash"
        )
        let result3 = await coordinator.tick(
            workflowState: codingWorkflow,
            shortWindow: codingWindow,
            now: now.addingTimeInterval(20),
            backend: SignalDrivenStubBehavioralBackend()
        )
        if result3.state == .coding && result3.confidence == 0.88 {
            print("[BehaviorInferenceSelfTest] pass case=coding_session")
        } else {
            print("[BehaviorInferenceSelfTest] fail case=coding_session got=\(result3.state.rawValue)")
            failures.append("coding_session")
        }
        
        // 4) Test 4: stabilization (requires multiple confirmations for medium-confidence shift)
        struct MediumBackend: BehavioralInferenceBackend {
            func infer(packet: BehavioralContextPacket) async -> BehavioralInference? {
                BehavioralInference(state: .comparing, confidence: 0.65, reasoning: "medium_comparison")
            }
        }
        let result4a = await coordinator.tick(
            workflowState: codingWorkflow,
            shortWindow: comparisonWindow,
            now: now.addingTimeInterval(30),
            backend: MediumBackend()
        )
        if result4a.state == .coding {
            print("[BehaviorInferenceSelfTest] pass case=stabilization_retains_coding")
        } else {
            print("[BehaviorInferenceSelfTest] fail case=stabilization_retains_coding got=\(result4a.state.rawValue)")
            failures.append("stabilization_retains_coding")
        }
        
        let result4b = await coordinator.tick(
            workflowState: codingWorkflow,
            shortWindow: comparisonWindow,
            now: now.addingTimeInterval(40),
            backend: MediumBackend()
        )
        if result4b.state == .comparing {
            print("[BehaviorInferenceSelfTest] pass case=stabilization_commits_after_confirmations")
        } else {
            print("[BehaviorInferenceSelfTest] fail case=stabilization_commits_after_confirmations got=\(result4b.state.rawValue)")
            failures.append("stabilization_commits_after_confirmations")
        }
        
        // 5) Test 5: decay (5 minutes of silence back to .unknown)
        let result5 = await coordinator.tick(
            workflowState: codingWorkflow,
            shortWindow: comparisonWindow,
            now: now.addingTimeInterval(350), // 310 seconds later (> 300 decay)
            backend: MediumBackend()
        )
        if result5.state == .unknown {
            print("[BehaviorInferenceSelfTest] pass case=decay_to_unknown")
        } else {
            print("[BehaviorInferenceSelfTest] fail case=decay_to_unknown got=\(result5.state.rawValue)")
            failures.append("decay_to_unknown")
        }
        
        // 6) Test 6: regression test for BehaviorInferenceGuard (Task 3)
        struct IdleOneBackend: BehavioralInferenceBackend {
            func infer(packet: BehavioralContextPacket) async -> BehavioralInference? {
                BehavioralInference(state: .idle, confidence: 1.00, reasoning: "model_hallucinated_idle")
            }
        }
        let shoppingWorkflow = WorkflowState(
            workflowType: .shopping,
            confidence: 0.8,
            evidence: ["anker"],
            uncertainty: "",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.8,
            dominantApps: ["Browser"],
            repeatedTerms: ["anker"],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "hash"
        )
        let shoppingWindow = TemporalContextWindow(
            durationSeconds: 300,
            eventCount: 20,
            dominantApps: ["Browser"],
            titleTransitions: 13,
            appTransitions: 1,
            repeatedTerms: ["anker", "power", "bank"],
            activityBursts: 3,
            idleSeconds: 0,
            typingScore: 0.2,
            pointerScore: 0.5,
            recentTitles: [],
            transitions: [],
            termFirstSeen: [:],
            termLastSeen: [:],
            titleFirstSeen: [:],
            titleLastSeen: [:],
            eventCountsByType: [:],
            droppedOutsideWindow: 0,
            termWeightedScores: [:],
            termRawCounts: [:],
            ocrEventTerms: [],
            ocrEventTermScores: [:],
            contextShift: .noShift
        )
        
        let coordinator6 = BehavioralIntelligenceCoordinator()
        let result6 = await coordinator6.tick(
            workflowState: shoppingWorkflow,
            shortWindow: shoppingWindow,
            now: now,
            backend: IdleOneBackend()
        )
        if result6.state != .idle && (result6.state == .comparing || result6.state == .shopping) {
            print("[BehaviorInferenceSelfTest] pass case=behavior_inference_guard_rejection")
        } else {
            print("[BehaviorInferenceSelfTest] fail case=behavior_inference_guard_rejection got=\(result6.state.rawValue)")
            failures.append("behavior_inference_guard_rejection")
        }
        
        // 7) Test 7: zero-support high-confidence behavior rejection (Task 2)
        let activeUnknownWindow = TemporalContextWindow(
            durationSeconds: 300,
            eventCount: 20,
            dominantApps: ["Browser"],
            titleTransitions: 5,
            appTransitions: 1,
            repeatedTerms: [],
            activityBursts: 3,
            idleSeconds: 0,
            typingScore: 0.6,
            pointerScore: 0.5,
            recentTitles: [],
            transitions: [],
            termFirstSeen: [:],
            termLastSeen: [:],
            titleFirstSeen: [:],
            titleLastSeen: [:],
            eventCountsByType: [:],
            droppedOutsideWindow: 0,
            termWeightedScores: [:],
            termRawCounts: [:],
            ocrEventTerms: [],
            ocrEventTermScores: [:],
            contextShift: .noShift
        )
        let unknownWorkflow = WorkflowState.empty
        
        let coordinator7 = BehavioralIntelligenceCoordinator()
        let result7 = await coordinator7.tick(
            workflowState: unknownWorkflow,
            shortWindow: activeUnknownWindow,
            now: now,
            backend: IdleOneBackend()
        )
        if result7.state == .unknown {
            print("[BehaviorInferenceSelfTest] pass case=zero_provenance_high_confidence")
        } else {
            print("[BehaviorInferenceSelfTest] fail case=zero_provenance_high_confidence got=\(result7.state.rawValue)")
            failures.append("zero_provenance_high_confidence")
        }

        // Phase 20B: Deterministic Fallback on Model Failure
        struct TimeoutBehavioralBackend: BehavioralInferenceBackend {
            func infer(packet: BehavioralContextPacket) async -> BehavioralInference? {
                return nil
            }
        }
        let fallbackShoppingWorkflow = WorkflowState(workflowType: .shopping, confidence: 0.8, evidence: [], uncertainty: "", startedAt: now, lastUpdatedAt: now, stabilityScore: 0.5, dominantApps: ["Firefox"], repeatedTerms: ["anker", "amazon"], recentTransitions: [], suggestedIntentHints: [], sourcePacketHash: "0")
        let coordinator8 = BehavioralIntelligenceCoordinator()
        let result8 = await coordinator8.tick(
            workflowState: fallbackShoppingWorkflow,
            shortWindow: activeUnknownWindow, // Has active title transitions
            now: now,
            backend: TimeoutBehavioralBackend()
        )
        if result8.state.rawValue == "comparing" {
            print("[BehaviorInferenceSelfTest] pass case=phase20b_model_timeout_triggers_deterministic_fallback")
        } else {
            print("[BehaviorInferenceSelfTest] fail case=phase20b_model_timeout_triggers_deterministic_fallback got=\(result8.state.rawValue)")
            failures.append("phase20b_behavior_fallback")
        }
        
        let ok = failures.isEmpty
        print("[BehaviorInferenceSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

// MARK: - Signal-driven Stub Backend

private struct SignalDrivenStubBehavioralBackend: BehavioralInferenceBackend {
    func infer(packet: BehavioralContextPacket) async -> BehavioralInference? {
        if packet.activityMetrics == 0.0 && packet.appTransitions == 0 && packet.titleTransitions == 0 {
            return result(.idle, 0.90, "stable_no_activity")
        }
        if packet.activityMetrics >= 0.5 && packet.workflowHistory.contains("coding") && packet.dominantApps.contains("Editor") {
            return result(.coding, 0.88, "sustained_editor_coding_pattern")
        }
        if packet.workflowHistory.contains("debugging") && packet.dominantApps.contains("Terminal") {
            return result(.debugging, 0.85, "repeated_terminal_debugging_pattern")
        }
        if packet.titleTransitions >= 3 && packet.repeatedTopics.contains("price") {
            return result(.comparing, 0.82, "shopping_page_comparison_pattern")
        }
        if packet.titleTransitions >= 4 && packet.repeatedTopics.contains("quantum") {
            return result(.researching, 0.81, "stable_topic_continuity")
        }
        if packet.dominantApps.contains("Browser") && packet.repeatedTopics.contains("amazon") {
            return result(.shopping, 0.80, "shopping_platform_active")
        }
        
        return result(.unknown, 0.3, "insufficient_behavioral_signals")
    }
    
    private func result(_ state: BehavioralState, _ confidence: Double, _ reasoning: String) -> BehavioralInference {
        BehavioralInference(state: state, confidence: confidence, reasoning: reasoning)
    }
}
