import Foundation

/// Active session tracking entry.
private struct ActiveSession {
    let workflowType: AmbientWorkflowType
    let startedAt: Date
    var confidences: [Double]
}

/// Transition entry for volatility tracking.
private struct TransitionEntry {
    let from: AmbientWorkflowType
    let to: AmbientWorkflowType
    let timestamp: Date
}

/// Main evaluation and validation engine for Phase B.2 Workflow Intelligence.
/// Thread-safe actor to handle diagnostic tracking across ticks.
public actor WorkflowEvaluation {

    // MARK: - State

    private var activeSession: ActiveSession?
    private var transitionEntries: [TransitionEntry] = []
    
    // Lifespan aggregates
    private var totalTicks: Int = 0
    private var ticksPerWorkflow: [AmbientWorkflowType: Int] = [:]
    private var totalCorrected: Int = 0
    private var totalUnknown: Int = 0
    private var completedSessionDurations: [TimeInterval] = []

    public init() {}

    // MARK: - Public Recording API

    /// Record one stabilized tick reading and process session metric transitions, volatility, and diagnostics.
    /// Returns the current dynamic volatility score.
    @discardableResult
    public func record(
        stabilized: WorkflowState,
        candidate: WorkflowState,
        now: Date = Date(),
        contextShiftDetected: Bool = false
    ) -> Double {
        totalTicks += 1
        
        let type = stabilized.workflowType
        ticksPerWorkflow[type, default: 0] += 1
        
        if type == .unknown {
            totalUnknown += 1
        }
        
        let isCorrected = stabilized.provenanceCorrected ?? false
        if isCorrected {
            totalCorrected += 1
        }
        
        // 1. Session tracking
        let prevWorkflow = activeSession?.workflowType
        if prevWorkflow != type {
            // End old session if active and not unknown
            if let active = activeSession, active.workflowType != .unknown {
                let duration = now.timeIntervalSince(active.startedAt)
                let avgConf = active.confidences.isEmpty ? 0.0 : active.confidences.reduce(0, +) / Double(active.confidences.count)
                
                completedSessionDurations.append(duration)
                
                print("[WorkflowEvaluation]")
                print("workflow=\(active.workflowType.rawValue)")
                print("duration_s=\(Int(duration))")
                print("confidence_avg=\(String(format: "%.2f", avgConf))")
            }
            
            // Start new session
            activeSession = ActiveSession(
                workflowType: type,
                startedAt: now,
                confidences: [stabilized.confidence]
            )
            
            // Track transition for volatility if this isn't the very first tick
            if totalTicks > 1, let prev = prevWorkflow {
                transitionEntries.append(TransitionEntry(from: prev, to: type, timestamp: now))
            }
        } else {
            // Continue same session
            activeSession?.confidences.append(stabilized.confidence)
        }
        
        // 2. Volatility tracking (10-minute window)
        let tenMinutesAgo = now.addingTimeInterval(-600)
        transitionEntries.removeAll { $0.timestamp < tenMinutesAgo }
        
        let changes = transitionEntries.count
        let volatilityDetected = changes >= 5
        let volatilityScore = min(Double(changes) / 10.0, 1.0)
        
        print("[WorkflowVolatility]")
        print("detected=\(volatilityDetected ? "yes" : "no")")
        print("changes=\(changes)")
        print("window=10m")
        
        // 3. Diagnostics output
        let unknownRate = totalTicks > 0 ? Double(totalUnknown) / Double(totalTicks) : 0.0
        let correctionRate = totalTicks > 0 ? Double(totalCorrected) / Double(totalTicks) : 0.0
        
        var topStr = ""
        let sortedWorkflows = ticksPerWorkflow
            .filter { $0.key != .unknown && $0.value > 0 }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key.rawValue < $1.key.rawValue) }
            .prefix(3)
        for w in sortedWorkflows {
            let pct = Int(round((Double(w.value) / Double(totalTicks)) * 100.0))
            topStr += "\n\(w.key.rawValue)=\(pct)%"
        }
        
        let unkPct = Int(round(unknownRate * 100.0))
        let corrPct = Int(round(correctionRate * 100.0))
        
        print("[WorkflowDiagnostics]")
        print("top_workflows=\(topStr)")
        print("")
        print("unknown_rate=\(unkPct)%")
        print("correction_rate=\(corrPct)%")
        print("volatility_score=\(String(format: "%.2f", volatilityScore))")
        
        return volatilityScore
    }

    // MARK: - Diagnostic Query API

    /// Generate an internal-only WorkflowConfidenceReport for the current state.
    public func generateReport(
        stabilized: WorkflowState,
        contextShiftDetected: Bool,
        trustScore: Double
    ) -> WorkflowConfidenceReport {
        return WorkflowConfidenceReport(
            currentWorkflow: stabilized.workflowType.rawValue,
            confidence: stabilized.confidence,
            stabilityScore: stabilized.stabilityScore,
            provenanceCorrected: stabilized.provenanceCorrected ?? false,
            contextShiftDetected: contextShiftDetected,
            evidenceSources: stabilized.evidence,
            trustScore: trustScore
        )
    }

    // MARK: - Testing Hooks

    public func getCompletedSessionDurations() -> [TimeInterval] {
        return completedSessionDurations
    }

    public func getVolatilityChangesCount() -> Int {
        return transitionEntries.count
    }

    public func getDiagnosticRates() -> (unknownRate: Double, correctionRate: Double) {
        let uRate = totalTicks > 0 ? Double(totalUnknown) / Double(totalTicks) : 0.0
        let cRate = totalTicks > 0 ? Double(totalCorrected) / Double(totalTicks) : 0.0
        return (uRate, cRate)
    }
}
