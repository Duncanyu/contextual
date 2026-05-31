import Foundation

public struct ValidationConfiguration: Sendable {
    
    public static var day1BehaviorValidationEnabled: Bool {
        // 1. Env override for dogfood: `CONTEXTUAL_AMBIENT_MVP=1`.
        if let env = ProcessInfo.processInfo.environment["CONTEXTUAL_AMBIENT_MVP"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if env == "1" || env == "yes" || env == "true" { return true }
            if env == "0" || env == "no" || env == "false" { return false }
        }
        // 2. Explicit UserDefaults value wins over the Debug default.
        if UserDefaults.standard.object(forKey: "contextual.day1BehaviorValidationMode") != nil {
            return UserDefaults.standard.bool(forKey: "contextual.day1BehaviorValidationMode")
        }
        // 3. Debug builds default to ON; Release builds default to OFF.
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
    public static var phaseBValidationModeEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "contextual.phaseBValidationMode")
    }
    
    public static var workflowIntelligenceEnabled: Bool {
        if UserDefaults.standard.object(forKey: "contextual.workflowIntelligence") != nil {
            return UserDefaults.standard.bool(forKey: "contextual.workflowIntelligence")
        }
        return true
    }
    
    public static var proposalGenerationEnabled: Bool {
        if UserDefaults.standard.object(forKey: "contextual.proposalGeneration") != nil {
            return UserDefaults.standard.bool(forKey: "contextual.proposalGeneration")
        }
        return true
    }
    
    public static func logStatus() {
        print("[ValidationConfig] day1_behavior_validation=\(day1BehaviorValidationEnabled)")
        print("[ValidationConfig] phase_b_validation=\(phaseBValidationModeEnabled)")
        print("[ValidationConfig] workflow_intelligence=\(workflowIntelligenceEnabled)")
        print("[ValidationConfig] proposal_generation=\(proposalGenerationEnabled)")
    }
}
