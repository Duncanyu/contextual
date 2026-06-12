import Foundation

enum UnifiedPanelSection: String, Codable, CaseIterable {
    case currentTask = "current_task"
    case related = "related"
    case backgroundWorkspace = "background_workspace"
    case system = "system"
    case followups = "followups"
    case debug = "debug"
}

struct UnifiedSurfaceDecision {
    let floating: UnifiedSuggestion?
    let panelSections: [UnifiedPanelSection: [UnifiedSuggestion]]
}

/// The single authority that decides which suggestions appear as popups vs panel rows.
enum UnifiedSurfaceArbiter {
    
    static func arbitrate(candidates: [UnifiedSuggestion], focus: CurrentFocusSummary) -> UnifiedSurfaceDecision {
        print("[UnifiedSurfaceArbiter] candidates=\(candidates.count) floating=evaluating panel=evaluating hidden=0 reason=evaluating_all")
        
        var floatingWinner: UnifiedSuggestion? = nil
        var panelSections: [UnifiedPanelSection: [UnifiedSuggestion]] = [
            .currentTask: [],
            .related: [],
            .backgroundWorkspace: [],
            .system: [],
            .followups: [],
            .debug: []
        ]
        
        // Find best floating candidate
        let eligibleForFloating = candidates.filter { $0.surfacePolicy.eligibleForFloating && !$0.surfacePolicy.hidden }
        
        // Active Task Dominance rules:
        // 1. Composed Plans always dominate floating
        // 2. High confidence current focus actions dominate
        // 3. Media/Friction actions can float if the current focus is weak
        
        if let plan = eligibleForFloating.first(where: { $0.kind == .composedPlan }) {
            floatingWinner = plan
            print("[UnifiedFloatingDecision] id=\(plan.id) allowed=yes reason=composed_plan_dominance")
        } else if let topCurrent = eligibleForFloating.filter({ $0.target == .currentFocus }).max(by: { $0.confidence < $1.confidence }), topCurrent.confidence >= 0.4 {
            floatingWinner = topCurrent
            print("[UnifiedFloatingDecision] id=\(topCurrent.id) allowed=yes reason=current_task_dominance confidence=\(topCurrent.confidence)")
        } else if let topBackground = eligibleForFloating.filter({ $0.target == .backgroundWorkspace }).max(by: { $0.confidence < $1.confidence }) {
            floatingWinner = topBackground
            print("[UnifiedFloatingDecision] id=\(topBackground.id) allowed=yes reason=background_workspace_idle")
        } else {
            print("[UnifiedSilenceDecision] allowed=yes reason=no_eligible_floating_candidates")
        }
        
        // Group others into panel sections
        for candidate in candidates {
            if candidate.surfacePolicy.hidden { continue }
            if candidate.surfacePolicy.debugOnly && !DebugMode.isEnabled { continue }
            
            let section = determinePanelSection(for: candidate)
            panelSections[section, default: []].append(candidate)
            print("[UnifiedPanelDecision] id=\(candidate.id) section=\(section.rawValue) reason=kind_\(candidate.kind.rawValue)")
        }
        
        // Sort sections by priority
        for key in panelSections.keys {
            panelSections[key]?.sort(by: { $0.priority > $1.priority })
        }
        
        return UnifiedSurfaceDecision(floating: floatingWinner, panelSections: panelSections)
    }
    
    private static func determinePanelSection(for suggestion: UnifiedSuggestion) -> UnifiedPanelSection {
        if suggestion.surfacePolicy.debugOnly {
            return .debug
        }
        
        switch suggestion.kind {
        case .composedPlan, .legacyCapability:
            switch suggestion.target {
            case .currentFocus: return .currentTask
            case .relatedFocus: return .related
            default: return .currentTask
            }
            
        case .mediaAction:
            return .backgroundWorkspace
            
        case .memoryAction, .frictionAction:
            return .backgroundWorkspace
            
        case .setupAction, .localSystemAction:
            return .system
            
        case .followupAction:
            return .followups
            
        case .debugAction:
            return .debug
        }
    }
}
