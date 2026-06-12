import Foundation

enum UnifiedSuggestionAdapters {
    private static let setupActionIds: Set<String> = [
        "capture_visible_page",
        "capture_full_document",
        "enable_browser_bridge",
        "select_text_hint"
    ]

    private static let frictionActionIds: Set<String> = [
        "arrange_side_by_side",
        "switch_to_paired_app",
        "split_research_setup"
    ]

    private static let mediaActionIds: Set<String> = [
        "play_focus_media",
        "pause_media",
        "resume_focus_media",
        "suggest_focus_playlist"
    ]
    
    /// Converts a Liquid or standard ActionProposal into a UnifiedSuggestion.
    static func from(liquidProposal: ActionProposal, isFloatingEligible: Bool = true) -> UnifiedSuggestion {
        let classified = classify(capabilityId: liquidProposal.primaryActionId, fallbackSource: .liquidRouter)
        let policy = UnifiedSuggestionSurfacePolicy(
            eligibleForFloating: isFloatingEligible,
            panelOnly: !isFloatingEligible,
            debugOnly: false,
            hidden: false
        )
        
        return UnifiedSuggestion(
            id: liquidProposal.primaryActionId,
            kind: classified.kind,
            title: liquidProposal.title,
            subtitle: liquidProposal.sourceCaption,
            whyNow: liquidProposal.reason,
            source: classified.source,
            target: classified.target,
            surfacePolicy: policy,
            acceptBehavior: classified.acceptBehavior,
            executionPath: classified.executionPath,
            priority: 50,
            confidence: liquidProposal.confidence,
            usefulness: liquidProposal.confidence,
            interruptionCost: 0.5,
            originalActionId: liquidProposal.primaryActionId
        )
    }
    
    /// Converts a static or legacy action (like Friction, Memory, Setup) into a UnifiedSuggestion.
    static func from(legacyAction: any ActionProtocol, source: SuggestionSource, kind: SuggestionKind, isDebug: Bool = false) -> UnifiedSuggestion {
        let classified = classify(capabilityId: legacyAction.id, fallbackSource: source)
        let policy = UnifiedSuggestionSurfacePolicy(
            eligibleForFloating: false,
            panelOnly: true,
            debugOnly: isDebug,
            hidden: false
        )
        
        return UnifiedSuggestion(
            id: legacyAction.id,
            kind: isDebug ? .debugAction : (kind == .legacyCapability ? classified.kind : kind),
            title: legacyAction.name,
            source: source,
            target: classified.target,
            surfacePolicy: policy,
            acceptBehavior: classified.acceptBehavior,
            executionPath: classified.executionPath,
            priority: 10,
            originalActionId: legacyAction.id
        )
    }
    
    /// Converts a music/media action into a UnifiedSuggestion.
    static func from(musicAction: any ActionProtocol, floatingEligible: Bool) -> UnifiedSuggestion {
        let policy = UnifiedSuggestionSurfacePolicy(
            eligibleForFloating: floatingEligible,
            panelOnly: !floatingEligible,
            debugOnly: false,
            hidden: false
        )
        
        return UnifiedSuggestion(
            id: musicAction.id,
            kind: .mediaAction,
            title: musicAction.name,
            source: .musicSystem,
            target: .backgroundWorkspace,
            surfacePolicy: policy,
            acceptBehavior: .executeDirect,
            executionPath: .localSystemExecutor,
            priority: 40,
            originalActionId: musicAction.id
        )
    }
    
    /// Converts a ComposedPlan into a UnifiedSuggestion.
    static func from(composedPlanTitle: String, planId: String, confidence: Double, isFloatingEligible: Bool) -> UnifiedSuggestion {
        let policy = UnifiedSuggestionSurfacePolicy(
            eligibleForFloating: isFloatingEligible,
            panelOnly: !isFloatingEligible,
            debugOnly: false,
            hidden: false
        )
        
        return UnifiedSuggestion(
            id: planId,
            kind: .composedPlan,
            title: composedPlanTitle,
            source: .composedPlanner,
            target: .currentFocus,
            surfacePolicy: policy,
            acceptBehavior: .executeDirect,
            executionPath: .composedExecutor,
            priority: 80,
            confidence: confidence,
            usefulness: confidence,
            originalActionId: planId
        )
    }

    /// Converts a CheapAlwaysOnPortfolio / Liquid portfolio candidate before UI routing.
    static func from(portfolioCandidate candidate: PortfolioCandidate, floatingEligible: Bool) -> UnifiedSuggestion {
        let classified = classify(capabilityId: candidate.capabilityId, fallbackSource: candidate.sourcePath == "liquid_router" ? .liquidRouter : .cheapPortfolio)
        let policy = UnifiedSuggestionSurfacePolicy(
            eligibleForFloating: floatingEligible,
            panelOnly: !floatingEligible,
            debugOnly: false,
            hidden: false
        )

        return UnifiedSuggestion(
            id: candidate.capabilityId,
            kind: classified.kind,
            title: candidate.title,
            subtitle: candidate.reason,
            whyNow: candidate.reason,
            source: classified.source,
            target: classified.target,
            surfacePolicy: policy,
            acceptBehavior: classified.acceptBehavior,
            executionPath: classified.executionPath,
            priority: Int((candidate.score * 100).rounded()),
            confidence: candidate.confidence,
            usefulness: candidate.usefulness,
            interruptionCost: 1.0 - candidate.executability,
            evidenceLevel: candidate.requiredEvidence,
            requiresConfirmation: candidate.requiresConfirmation,
            originalActionId: candidate.capabilityId
        )
    }

    static func from(capabilityId: String, title: String, source: SuggestionSource, confidence: Double, floatingEligible: Bool) -> UnifiedSuggestion {
        let classified = classify(capabilityId: capabilityId, fallbackSource: source)
        return UnifiedSuggestion(
            id: capabilityId,
            kind: classified.kind,
            title: title,
            source: classified.source,
            target: classified.target,
            surfacePolicy: UnifiedSuggestionSurfacePolicy(
                eligibleForFloating: floatingEligible,
                panelOnly: !floatingEligible,
                debugOnly: false,
                hidden: false
            ),
            acceptBehavior: classified.acceptBehavior,
            executionPath: classified.executionPath,
            priority: classified.priority,
            confidence: confidence,
            usefulness: confidence,
            originalActionId: capabilityId
        )
    }

    private static func classify(
        capabilityId: String,
        fallbackSource: SuggestionSource
    ) -> (kind: SuggestionKind, source: SuggestionSource, target: SuggestionTarget, acceptBehavior: SuggestionAcceptBehavior, executionPath: SuggestionExecutionPath, priority: Int) {
        if capabilityId.hasPrefix("composed_action:") || ComposedActionUIRegistry.isComposedPlanID(capabilityId) {
            return (.composedPlan, .composedPlanner, .currentFocus, .executeDirect, .composedExecutor, 80)
        }
        if setupActionIds.contains(capabilityId) {
            let accept: SuggestionAcceptBehavior = capabilityId == "capture_visible_page" || capabilityId == "capture_full_document" ? .captureFirst : .setupFirst
            return (.setupAction, .setupAcquisition, .system, accept, .setupExecutor, 35)
        }
        if mediaActionIds.contains(capabilityId) {
            return (.mediaAction, fallbackSource == .liquidRouter ? .liquidRouter : .musicSystem, .backgroundWorkspace, .executeDirect, .localSystemExecutor, 40)
        }
        if frictionActionIds.contains(capabilityId) {
            return (.frictionAction, .frictionEngine, .backgroundWorkspace, .executeDirect, .localSystemExecutor, 55)
        }
        if capabilityId.hasPrefix("followup:") {
            return (.followupAction, .resultFollowup, .currentFocus, .executeDirect, .followupExecutor, 60)
        }
        // Phase 64 — memory/workspace actions are their own kind, not legacy.
        if ["remember_workspace", "restore_workspace", "save_task_context", "recall_related_context", "save_research_session", "update_project_status_note", "suggest_next_step_from_memory"].contains(capabilityId) {
            return (.memoryAction, .memorySystem, .backgroundWorkspace, .executeDirect, .capabilityExecutor, 30)
        }
        return (.legacyCapability, fallbackSource, .currentFocus, .executeDirect, .capabilityExecutor, 50)
    }

    static func from(ambientSuggestion: AmbientJarvisSuggestion) -> UnifiedSuggestion {
        let policy = UnifiedSuggestionSurfacePolicy(
            eligibleForFloating: true,
            panelOnly: false,
            debugOnly: false,
            hidden: false
        )
        return UnifiedSuggestion(
            id: ambientSuggestion.id,
            kind: .legacyCapability,
            title: ambientSuggestion.title,
            subtitle: ambientSuggestion.subtitle,
            whyNow: ambientSuggestion.whyNow,
            source: .liquidRouter,
            target: .currentFocus,
            surfacePolicy: policy,
            acceptBehavior: .executeDirect,
            executionPath: .capabilityExecutor,
            priority: 70,
            confidence: ambientSuggestion.confidence,
            usefulness: ambientSuggestion.confidence,
            originalActionId: "ambient_jarvis:\(ambientSuggestion.id)"
        )
    }
}
