import Foundation

public enum WorkingMemoryBuilder {
    public static func build(
        workflow: WorkflowState,
        behavior: BehavioralStateRecord,
        packet: CompressedTemporalPacket
    ) -> WorkingMemorySnapshot {
        // 1. Filter raw titles
        var dropped = 0
        var distinctTitles: [String] = []
        let noiseApps = ["Gmail", "Scratch", "Terminal", "Xcode", "Notes", "Mail", "Messages", "Slack"]
        
        for title in packet.recentTitles {
            if title.isEmpty { continue }
            
            // App noise filtering
            let lower = title.lowercased()
            let isNoiseApp = noiseApps.contains { lower.contains($0.lowercased()) }
            
            if workflow.workflowType == .shopping && isNoiseApp {
                dropped += 1
                continue
            }
            
            if !distinctTitles.contains(title) {
                distinctTitles.append(title)
            }
        }
        
        if dropped > 0 {
            print("[WorkingMemory] filtered_titles dropped=\(dropped) reason=non_product_app_noise")
        }

        let currentEntity = distinctTitles.first ?? "Unknown"
        let recentEntities = distinctTitles
        
        // 2. Filter repeated concepts
        let genericConcepts = ["bank", "with", "laptop", "power", "the", "and", "for", "phone"]
        let repeatedConcepts = packet.topicTerms.filter { !genericConcepts.contains($0.lowercased()) }
        
        let activityVerb: String
        if behavior.state == .unknown || behavior.state.rawValue == workflow.workflowType.rawValue {
            activityVerb = workflow.workflowType.rawValue
        } else {
            activityVerb = behavior.state.rawValue
        }
        
        let conceptsStr = repeatedConcepts.prefix(3).joined(separator: " ")
        let inferredActivity = conceptsStr.isEmpty ? activityVerb : "\(activityVerb) \(conceptsStr)"
        
        let comparisonCandidates: [String]
        if behavior.state == .comparing || (workflow.workflowType == .shopping && recentEntities.count > 1) {
            comparisonCandidates = Array(recentEntities.prefix(4))
        } else {
            comparisonCandidates = recentEntities.count == 1 ? Array(recentEntities.prefix(1)) : []
        }
        
        let snapshot = WorkingMemorySnapshot(
            currentEntity: currentEntity,
            recentEntities: recentEntities,
            repeatedConcepts: repeatedConcepts,
            inferredActivity: inferredActivity,
            comparisonCandidates: comparisonCandidates
        )
        
        print("[WorkingMemory] recent_entities=[\(recentEntities.joined(separator: ", "))]")
        print("[WorkingMemory] comparison_candidates=[\(comparisonCandidates.joined(separator: ", "))]")
        print("[WorkingMemory] entities=\(recentEntities.count) concepts=\(repeatedConcepts.count) comparisons=\(comparisonCandidates.count)")
        print("[WorkingMemory] summary=\"\(inferredActivity)\"")
        
        return snapshot
    }
}
