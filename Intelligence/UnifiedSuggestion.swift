import Foundation

/// Defines the kind of suggestion this is. Used for routing and display style.
enum SuggestionKind: String, Codable, Equatable {
    case composedPlan = "composed_plan"
    case legacyCapability = "legacy_capability"
    case localSystemAction = "local_system_action"
    case setupAction = "setup_action"
    case memoryAction = "memory_action"
    case frictionAction = "friction_action"
    case mediaAction = "media_action"
    case followupAction = "followup_action"
    case debugAction = "debug_action"
}

enum SuggestionSource: String, Codable, Equatable {
    case liquidRouter = "liquid_router"
    case composedPlanner = "composed_planner"
    case cheapPortfolio = "cheap_portfolio"
    case musicSystem = "music_system"
    case frictionEngine = "friction_engine"
    case setupAcquisition = "setup_acquisition"
    case memorySystem = "memory_system"
    case resultFollowup = "result_followup"
    case debug = "debug"
}

enum SuggestionTarget: String, Codable, Equatable {
    case currentFocus = "current_focus"
    case relatedFocus = "related_focus"
    case backgroundWorkspace = "background_workspace"
    case system = "system"
}

struct UnifiedSuggestionSurfacePolicy: Codable, Equatable {
    var eligibleForFloating: Bool
    var panelOnly: Bool
    var debugOnly: Bool
    var hidden: Bool
}

enum SuggestionAcceptBehavior: String, Codable, Equatable {
    case executeDirect = "execute_direct"
    case askFirst = "ask_first"
    case captureFirst = "capture_first"
    case openPanel = "open_panel"
    case setupFirst = "setup_first"
}

enum SuggestionExecutionPath: String, Codable, Equatable {
    case composedExecutor = "composed_executor"
    case capabilityExecutor = "capability_executor"
    case localSystemExecutor = "local_system_executor"
    case setupExecutor = "setup_executor"
    case followupExecutor = "followup_executor"
}

/// The unified model for all suggestions across the entire app surface.
struct UnifiedSuggestion: Identifiable, Equatable {
    let id: String
    let kind: SuggestionKind
    let title: String
    let subtitle: String?
    let whyNow: String?
    let source: SuggestionSource
    let target: SuggestionTarget
    let surfacePolicy: UnifiedSuggestionSurfacePolicy
    let acceptBehavior: SuggestionAcceptBehavior
    let executionPath: SuggestionExecutionPath
    
    // Scoring & Ranking
    let priority: Int
    let confidence: Double
    let usefulness: Double
    let interruptionCost: Double
    let evidenceLevel: String?
    let sourceScope: String?
    
    // Execution Control
    let requiresConfirmation: Bool
    let cooldownKey: String?
    let debugMetadata: [String: String]?
    
    // Original Action/Proposal Reference (for execution)
    let originalActionId: String?
    
    init(
        id: String,
        kind: SuggestionKind,
        title: String,
        subtitle: String? = nil,
        whyNow: String? = nil,
        source: SuggestionSource,
        target: SuggestionTarget,
        surfacePolicy: UnifiedSuggestionSurfacePolicy,
        acceptBehavior: SuggestionAcceptBehavior,
        executionPath: SuggestionExecutionPath,
        priority: Int = 0,
        confidence: Double = 0.5,
        usefulness: Double = 0.5,
        interruptionCost: Double = 0.5,
        evidenceLevel: String? = nil,
        sourceScope: String? = nil,
        requiresConfirmation: Bool = false,
        cooldownKey: String? = nil,
        debugMetadata: [String: String]? = nil,
        originalActionId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.whyNow = whyNow
        self.source = source
        self.target = target
        self.surfacePolicy = surfacePolicy
        self.acceptBehavior = acceptBehavior
        self.executionPath = executionPath
        self.priority = priority
        self.confidence = confidence
        self.usefulness = usefulness
        self.interruptionCost = interruptionCost
        self.evidenceLevel = evidenceLevel
        self.sourceScope = sourceScope
        self.requiresConfirmation = requiresConfirmation
        self.cooldownKey = cooldownKey
        self.debugMetadata = debugMetadata
        self.originalActionId = originalActionId
        
        let valid = validate()
        print("[UnifiedSuggestionCreated] id=\(id) kind=\(kind.rawValue) source=\(source.rawValue) title=\"\(title)\" target=\(target.rawValue) surface=eligible_for_floating:\(surfacePolicy.eligibleForFloating)")
        if !valid {
            print("[UnifiedSuggestionValidation] id=\(id) valid=no reason=invalid_surface_policy")
        }
    }
    
    private func validate() -> Bool {
        if surfacePolicy.hidden && surfacePolicy.eligibleForFloating {
            return false
        }
        if surfacePolicy.debugOnly && surfacePolicy.eligibleForFloating {
            return false
        }
        return true
    }
}
