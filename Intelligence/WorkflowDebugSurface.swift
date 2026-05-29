import Foundation

/// Log-only debug surface for Phase B. **No UI** — we explicitly avoid risky
/// SwiftUI integration until Phase C. Anyone tailing the logs can read the
/// current workflow, confidence, stability, evidence, and active opportunities.
public enum WorkflowDebugSurface {

    public static func log(
        state: WorkflowState,
        packet: CompressedTemporalPacket?,
        opportunities: [AmbientOpportunity]
    ) {
        let confStr = String(format: "%.2f", state.confidence)
        let stabStr = String(format: "%.2f", state.stabilityScore)
        let dur = Int(state.durationSeconds)
        let oppList = opportunities.map(\.opportunityType.rawValue).joined(separator: ",")
        let evidence = state.evidence.prefix(3).joined(separator: " | ")
        let topApps = state.dominantApps.prefix(3).joined(separator: ",")
        let topTerms = state.repeatedTerms.prefix(5).joined(separator: ",")
        let topTransitions = state.recentTransitions.suffix(4).joined(separator: ",")

        print("[WorkflowDebug]")
        print("[WorkflowDebug] workflow=\(state.workflowType.rawValue)")
        print("[WorkflowDebug] confidence=\(confStr)")
        print("[WorkflowDebug] stability=\(stabStr)")
        print("[WorkflowDebug] duration_s=\(dur)")
        print("[WorkflowDebug] evidence=\(evidence.isEmpty ? "none" : evidence)")
        print("[WorkflowDebug] uncertainty=\(state.uncertainty)")
        print("[WorkflowDebug] dominant_apps=\(topApps.isEmpty ? "none" : topApps)")
        print("[WorkflowDebug] repeated_terms=\(topTerms.isEmpty ? "none" : topTerms)")
        print("[WorkflowDebug] recent_transitions=\(topTransitions.isEmpty ? "none" : topTransitions)")

        if let p = packet {
            print("[WorkflowDebug] activity=\(p.activityPattern) idle=\(p.idlePattern) typing=\(p.typingPattern) pointer=\(p.pointerPattern)")
            print("[WorkflowDebug] span_s=\(p.spanSeconds) events_used=\(p.eventCount)")
        }
        print("[WorkflowDebug] opportunities=\(oppList.isEmpty ? "none" : oppList)")
    }
}
