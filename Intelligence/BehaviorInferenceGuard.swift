import Foundation

public struct BehaviorInferenceGuard: Sendable {
    
    public static func validate(
        inferred: BehavioralInference,
        packet: BehavioralContextPacket,
        workflowState: WorkflowState
    ) -> BehavioralInference {
        
        var state = inferred.state
        var confidence = inferred.confidence
        var reasoning = inferred.reasoning
        
        // TASK 1 — Reject idle when:
        // - workflowState.type != idle/unknown
        // - titleTransitions >= 3
        // - repeatedTerms non-empty (packet.repeatedTopics)
        // - workflowTrustScore >= 0.5
        if state == .idle {
            let isWorkflowActive = workflowState.workflowType != .idle && workflowState.workflowType != .unknown
            let hasTransitions = packet.titleTransitions >= 3
            let hasTopics = !packet.repeatedTopics.isEmpty
            let trustScore = workflowState.workflowTrustScore
            
            if isWorkflowActive && hasTransitions && hasTopics && trustScore >= 0.5 {
                let termsStr = packet.repeatedTopics.joined(separator: ",")
                print("[BehaviorInferenceGuard] rejected=idle reason=active_workflow_context workflow=\(workflowState.workflowType.rawValue) title_transitions=\(packet.titleTransitions) repeated_terms=\(termsStr)")
                
                // Correction:
                let oldState = state
                if workflowState.workflowType == .shopping && !packet.repeatedTopics.isEmpty {
                    state = .comparing
                } else if workflowState.workflowType == .researching {
                    state = .researching
                } else if workflowState.workflowType == .debugging {
                    state = .debugging
                } else {
                    state = .unknown
                }
                
                print("[BehaviorInferenceGuard] corrected from=\(oldState.rawValue) to=\(state.rawValue) reason=workflow_supported_temporal_evidence")
                confidence = 0.82
                reasoning = "workflow_supported_temporal_evidence"
                
                return BehavioralInference(state: state, confidence: confidence, reasoning: reasoning)
            }
        }
        
        // TASK 2 — Add zero-support high-confidence behavior rejection
        // If behavior confidence >= 0.80 and behavior has no evidence match in packet, reject.
        if confidence >= 0.80 {
            if !hasEvidenceMatch(state: state, packet: packet) {
                let confStr = String(format: "%.2f", confidence)
                print("[BehaviorInferenceGuard] rejected=\(state.rawValue) reason=zero_provenance_high_confidence confidence=\(confStr)")
                
                state = .unknown
                confidence = 0.0
                reasoning = "zero_provenance_high_confidence"
            }
        }
        
        return BehavioralInference(state: state, confidence: confidence, reasoning: reasoning)
    }
    
    private static func hasEvidenceMatch(state: BehavioralState, packet: BehavioralContextPacket) -> Bool {
        switch state {
        case .idle:
            // Idle has no evidence if activity is high
            let active = packet.activityMetrics >= 0.3 || (packet.appTransitions + packet.titleTransitions >= 3)
            return !active
        case .coding:
            let appMatch = packet.dominantApps.contains { app in
                let lower = app.lowercased()
                return lower.contains("xcode") || lower.contains("code") || lower.contains("editor") || lower.contains("terminal")
            }
            let topicMatch = packet.repeatedTopics.contains { term in
                let lower = term.lowercased()
                return lower.contains("func") || lower.contains("class") || lower.contains("struct") || lower.contains("code") || lower.contains("swift")
            }
            let wfMatch = packet.workflowHistory.contains("coding")
            return appMatch || topicMatch || wfMatch
        case .debugging:
            let appMatch = packet.dominantApps.contains { app in
                let lower = app.lowercased()
                return lower.contains("xcode") || lower.contains("terminal") || lower.contains("console")
            }
            let wfMatch = packet.workflowHistory.contains("debugging")
            return appMatch || wfMatch
        case .shopping:
            let appMatch = packet.dominantApps.contains { app in
                let lower = app.lowercased()
                return lower.contains("browser") || lower.contains("safari") || lower.contains("chrome") || lower.contains("firefox")
            }
            let topicMatch = packet.repeatedTopics.contains { term in
                let lower = term.lowercased()
                return lower.contains("amazon") || lower.contains("price") || lower.contains("shop") || lower.contains("buy") || lower.contains("cart")
            }
            let wfMatch = packet.workflowHistory.contains("shopping")
            return appMatch || topicMatch || wfMatch
        case .comparing:
            let appMatch = packet.dominantApps.contains { app in
                let lower = app.lowercased()
                return lower.contains("browser") || lower.contains("safari") || lower.contains("chrome") || lower.contains("firefox")
            }
            let topicMatch = packet.repeatedTopics.contains { term in
                let lower = term.lowercased()
                return lower.contains("price") || lower.contains("compare") || lower.contains("specs") || lower.contains("vs") || lower.contains("review")
            }
            let wfMatch = packet.workflowHistory.contains("comparing")
            return appMatch || topicMatch || wfMatch
        case .researching:
            let appMatch = packet.dominantApps.contains { app in
                let lower = app.lowercased()
                return lower.contains("browser") || lower.contains("safari") || lower.contains("chrome") || lower.contains("firefox")
            }
            let wfMatch = packet.workflowHistory.contains("researching") || packet.workflowHistory.contains("studying")
            return appMatch || wfMatch || !packet.repeatedTopics.isEmpty
        default:
            return true
        }
    }
}
