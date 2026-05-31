import Foundation

/// Orchestrates the Phase 18A Behavioral Context Layer.
/// Standalone actor sitting between Context and Suggestions layers.
public actor BehavioralIntelligenceCoordinator {

    private var stabilizer: BehavioralStabilizer
    private var workflowHistory: [String]
    private var workflowConfidenceHistory: [Double]
    private let maxHistoryLength = 10

    public init(initialRecord: BehavioralStateRecord = .empty) {
        self.stabilizer = BehavioralStabilizer(initial: initialRecord)
        self.workflowHistory = []
        self.workflowConfidenceHistory = []
    }

    /// Triggers a single behavioral inference tick.
    /// Distills the 5-minute shortWindow context, appends workflow history, calls the backend,
    /// feeds candidate to the stabilizer, and logs results in the required format.
    @discardableResult
    public func tick(
        workflowState: WorkflowState,
        shortWindow: TemporalContextWindow,
        now: Date = Date(),
        backend: BehavioralInferenceBackend = OllamaBehavioralInferenceBackend()
    ) async -> BehavioralStateRecord {
        
        // 1. Maintain workflow state history
        workflowHistory.append(workflowState.workflowType.rawValue)
        workflowConfidenceHistory.append(workflowState.confidence)
        if workflowHistory.count > maxHistoryLength {
            workflowHistory.removeFirst()
            workflowConfidenceHistory.removeFirst()
        }

        // 2. Build BehavioralContextPacket
        let continuity = min(1.0, max(0.0, workflowState.workflowTrustScore))
        let activity = max(shortWindow.typingScore, shortWindow.pointerScore)

        let packet = BehavioralContextPacket(
            dominantApps: shortWindow.dominantApps,
            appTransitions: shortWindow.appTransitions,
            titleTransitions: shortWindow.titleTransitions,
            repeatedTopics: shortWindow.repeatedTerms,
            workflowHistory: workflowHistory,
            workflowConfidenceHistory: workflowConfidenceHistory,
            contextContinuityMetrics: continuity,
            activityMetrics: activity,
            spanSeconds: shortWindow.durationSeconds
        )

        // 3. Call backend inference model
        let rawOpt = await backend.infer(packet: packet)
        let inferredRaw: BehavioralInference
        if let r = rawOpt {
            inferredRaw = r
        } else {
            // Phase 20B Deterministic Fallback
            if (workflowState.workflowType == .shopping || workflowState.workflowType == .comparing) && packet.titleTransitions >= 2 {
                print("[BehaviorFallback] applied behavior=comparing reason=model_failed_but_title_churn_related_entities")
                inferredRaw = BehavioralInference(
                    state: .comparing,
                    confidence: 0.65,
                    reasoning: "deterministic_temporal_fallback"
                )
            } else {
                inferredRaw = BehavioralInference(state: .unknown, confidence: 0.0, reasoning: "inference_failed")
            }
        }

        let inferred = BehaviorInferenceGuard.validate(
            inferred: inferredRaw,
            packet: packet,
            workflowState: workflowState
        )

        // 4. Log raw inference results exactly as required
        let confStr = String(format: "%.2f", inferred.confidence)
        print("\n[BehaviorInference]\nstate=\(inferred.state.rawValue)\nconfidence=\(confStr)\n")
        print("[BehaviorReasoning]\nreason=\(inferred.reasoning)\n")

        // 5. Build candidate record and ingest into stabilizer
        let candidate = BehavioralStateRecord(
            state: inferred.state,
            confidence: inferred.confidence,
            reasoning: inferred.reasoning,
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.0
        )

        let stabilized = stabilizer.ingest(candidate: candidate, now: now)

        // 6. Log stabilized committed state exactly as required
        let stabStr = String(format: "%.2f", stabilized.stabilityScore)
        print("[BehaviorState]\ncommitted=\(stabilized.state.rawValue)\nstability=\(stabStr)\n")

        return stabilized
    }

    /// Exposes the current stabilized state.
    public func getLatestStateRecord() -> BehavioralStateRecord {
        stabilizer.current
    }
}
