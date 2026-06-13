import Foundation

struct UnifiedActionDispatchOutcome: Equatable {
    let suggestionID: String
    let actionID: String
    let capabilityID: String
    let route: String
    let allowed: Bool
    let reason: String
    let payloadValid: Bool
    let entryPoint: String
}

struct ActionAliasResolution: Equatable {
    let visibleID: String
    let canonicalID: String
    let reason: String
    var changed: Bool { visibleID != canonicalID }
}

enum ActionAliasResolver {
    private static let aliases: [String: String] = [
        "arrange_current_and_reference": "arrange_side_by_side",
        "put_xcode_beside_logs": "arrange_side_by_side",
        "put_browser_beside_pdf": "arrange_side_by_side",
        "open_agreement_beside": "arrange_side_by_side",
        "capture_full_agreement": "capture_full_document",
        "capture_listing_pages": "capture_visible_page",
        "compare_by_features": "create_decision_table",
        "compare_agreement_to_listing": "compare_document_to_listing",
        "save_decision_table": "save_research_session",
        "select_a_clause": "select_text_hint",
        "ask_for_missing_info": "list_missing_form_info"
    ]

    static func resolve(_ visibleID: String) -> ActionAliasResolution {
        if let canonical = aliases[visibleID] {
            return ActionAliasResolution(visibleID: visibleID, canonicalID: canonical, reason: "canonical_alias")
        }
        return ActionAliasResolution(visibleID: visibleID, canonicalID: visibleID, reason: "already_canonical")
    }

    static func canonicalID(for visibleID: String) -> String {
        resolve(visibleID).canonicalID
    }

    @MainActor
    static func executorAvailable(
        visibleID: String,
        canonicalID: String,
        route: String
    ) -> Bool {
        if route == "composed_executor" {
            if visibleID.hasPrefix("composed_action:") || canonicalID.hasPrefix("composed_action:") {
                return true
            }
            return ComposedActionUIRegistry.resolve(visibleID) != nil || ComposedActionUIRegistry.resolve(canonicalID) != nil
        }
        if route == "followup_executor", ComposedActionUIRegistry.isComposedFollowUpID(visibleID) {
            return ComposedActionUIRegistry.resolveFollowUp(visibleID) != nil
        }
        return CognitiveCapabilityRegistry.shared.get(canonicalID) != nil
    }
}

@MainActor
enum UnifiedActionDispatcher {
    private static let windowLayoutCapabilities: Set<String> = [
        "arrange_side_by_side",
        "switch_to_paired_app",
        "split_research_setup"
    ]

    static func plan(
        suggestion: UnifiedSuggestion,
        sourceSurface: ActionSourceSurface,
        appState: AppState? = nil
    ) -> UnifiedActionDispatchOutcome {
        let actionID = suggestion.originalActionId ?? suggestion.id
        let resolution = appState?.resolveStoredAction(id: actionID, context: appState?.debugContext ?? ContextModel())
        let rawCapabilityID = resolution?.capabilityID
            ?? suggestion.debugMetadata?["capabilityId"]
            ?? inferredCapabilityID(for: suggestion, actionID: actionID)
        let alias = ActionAliasResolver.resolve(rawCapabilityID)
        let capabilityID = alias.canonicalID
        let route = routeName(for: suggestion, capabilityID: capabilityID)
        let payload = payloadSummary(
            suggestion: suggestion,
            actionID: actionID,
            capabilityID: capabilityID,
            route: route,
            resolution: resolution,
            context: appState?.debugContext ?? ContextModel()
        )
        let executorAvailable = ActionAliasResolver.executorAvailable(visibleID: actionID, canonicalID: capabilityID, route: route)
        let allowedReason: String
        let allowed: Bool
        if payload.valid && executorAvailable {
            allowed = true
            allowedReason = "payload_valid"
        } else if !executorAvailable {
            allowed = false
            allowedReason = "executor_missing"
        } else {
            allowed = false
            allowedReason = "payload_invalid"
        }
        return UnifiedActionDispatchOutcome(
            suggestionID: suggestion.id,
            actionID: actionID,
            capabilityID: capabilityID,
            route: route,
            allowed: allowed,
            reason: allowedReason,
            payloadValid: payload.valid,
            entryPoint: "UnifiedActionDispatcher"
        )
    }

    @discardableResult
    static func dispatch(
        suggestion: UnifiedSuggestion,
        sourceSurface: ActionSourceSurface,
        appState: AppState
    ) -> UnifiedActionDispatchOutcome {
        let actionID = suggestion.originalActionId ?? suggestion.id
        let resolution = appState.resolveStoredAction(id: actionID, context: appState.debugContext)
        let rawCapabilityID = resolution.capabilityID != actionID
            ? resolution.capabilityID
            : (suggestion.debugMetadata?["capabilityId"] ?? inferredCapabilityID(for: suggestion, actionID: actionID))
        let alias = ActionAliasResolver.resolve(rawCapabilityID)
        let capabilityID = alias.canonicalID
        let route = routeName(for: suggestion, capabilityID: capabilityID)
        let payload = payloadSummary(
            suggestion: suggestion,
            actionID: actionID,
            capabilityID: capabilityID,
            route: route,
            resolution: resolution,
            context: appState.debugContext
        )
        let executorAvailable = ActionAliasResolver.executorAvailable(visibleID: actionID, canonicalID: capabilityID, route: route)
        let allowed = payload.valid && executorAvailable
        let reason = allowed ? "payload_valid" : (!executorAvailable ? "executor_missing" : "payload_invalid")

        if alias.changed {
            print("[ActionAliasResolved] from=\(alias.visibleID) to=\(alias.canonicalID) reason=\(alias.reason)")
        }
        print("[ExecutorResolution] visible_id=\(suggestion.id) canonical_id=\(capabilityID) executor=\(route) available=\(executorAvailable ? "yes" : "no")")
        print("[UnifiedActionClicked] id=\(suggestion.id) kind=\(suggestion.kind.rawValue) surface=\(sourceSurface.rawValue)")
        print("[UnifiedActionPayload] id=\(suggestion.id) targets=\(payload.targets.joined(separator: ",")) urls=\(payload.urls.joined(separator: ",")) valid=\(payload.valid ? "yes" : "no")")
        print("[UnifiedActionDispatch] id=\(suggestion.id) route=\(route) allowed=\(allowed ? "yes" : "no") reason=\(reason)")
        if sourceSurface == .followup {
            print("[FollowupButtonClicked] id=\(suggestion.id) parent=\(suggestion.debugMetadata?["sourceActionID"] ?? "unknown")")
            print("[FollowupActionDispatch] id=\(suggestion.id) route=\(route) allowed=\(allowed ? "yes" : "no")")
        }
        if route == "composed_executor" || route == "followup_executor" {
            appState.recordSuggestionClickAttempt(id: suggestion.id, capabilityId: capabilityID)
        }

        let outcome = UnifiedActionDispatchOutcome(
            suggestionID: suggestion.id,
            actionID: actionID,
            capabilityID: capabilityID,
            route: route,
            allowed: allowed,
            reason: reason,
            payloadValid: payload.valid,
            entryPoint: "UnifiedActionDispatcher"
        )

        guard allowed else {
            print("[ExecutorMissingBlock] visible_id=\(suggestion.id) reason=\(reason) surfaced=no")
            let shown = appState.presentActionCompletionSurface(
                actionID: actionID,
                capabilityID: capabilityID,
                title: suggestion.title,
                status: .unavailable,
                reason: reason,
                outputText: nil,
                sourceSurface: sourceSurface,
                pendingPayload: nil
            )
            appState.logUnifiedActionResult(actionID: suggestion.id, status: .unavailable, cardShown: shown, reason: reason)
            if sourceSurface == .followup {
                print("[FollowupActionResult] id=\(suggestion.id) status=failed card=\(shown ? "shown" : "hidden")")
            }
            return outcome
        }

        switch route {
        case "composed_executor":
            Task { @MainActor in
                let result = await ComposedActionClickDispatcher.execute(uiID: actionID, sourceSurface: sourceSurface.rawValue)
                let shown = appState.presentActionCompletionSurface(
                    actionID: actionID,
                    capabilityID: actionID,
                    title: suggestion.title,
                    status: result.executionStatus,
                    reason: nil,
                    outputText: result.outputText,
                    sourceSurface: sourceSurface,
                    pendingPayload: CapabilityExecutor.shared.takePendingResultCard(for: actionID)
                )
                appState.logUnifiedActionResult(actionID: suggestion.id, status: result.executionStatus, cardShown: shown, reason: nil)
            }
        case "followup_executor" where ComposedActionUIRegistry.isComposedFollowUpID(actionID):
            Task { @MainActor in
                let result = await ComposedActionClickDispatcher.executeFollowUp(id: actionID, sourceSurface: sourceSurface.rawValue)
                let shown = appState.presentActionCompletionSurface(
                    actionID: actionID,
                    capabilityID: actionID,
                    title: suggestion.title,
                    status: result.executionStatus,
                    reason: nil,
                    outputText: result.outputText,
                    sourceSurface: sourceSurface,
                    pendingPayload: CapabilityExecutor.shared.takePendingResultCard(for: actionID)
                )
                appState.logUnifiedActionResult(actionID: suggestion.id, status: result.executionStatus, cardShown: shown, reason: nil)
                print("[FollowupActionResult] id=\(suggestion.id) status=\(followupStatusName(result.executionStatus)) card=\(shown ? "shown" : "hidden")")
            }
        default:
            if sourceSurface == .followup {
                executeFollowupCapability(
                    suggestion: suggestion,
                    actionID: actionID,
                    capabilityID: capabilityID,
                    route: route,
                    appState: appState,
                    sourceSurface: sourceSurface
                )
            } else {
                appState.invokeAction(id: actionID, sourceSurface: sourceSurface)
            }
        }

        return outcome
    }

    private static func executeFollowupCapability(
        suggestion: UnifiedSuggestion,
        actionID: String,
        capabilityID: String,
        route: String,
        appState: AppState,
        sourceSurface: ActionSourceSurface
    ) {
        let sourceActionID = suggestion.debugMetadata?["sourceActionID"]
        let captureApproval = capabilityID == "capture_full_document"
        let executionCapabilityID: String
        if captureApproval, let sourceActionID, CognitiveCapabilityRegistry.shared.get(sourceActionID) != nil {
            executionCapabilityID = sourceActionID
        } else {
            executionCapabilityID = capabilityID
        }
        guard let capability = CognitiveCapabilityRegistry.shared.get(executionCapabilityID) else {
            let shown = appState.presentActionCompletionSurface(
                actionID: actionID,
                capabilityID: capabilityID,
                title: suggestion.title,
                status: .unavailable,
                reason: "executor_missing",
                outputText: nil,
                sourceSurface: sourceSurface,
                pendingPayload: nil
            )
            print("[FollowupActionResult] id=\(suggestion.id) status=failed card=\(shown ? "shown" : "hidden")")
            return
        }
        Task { @MainActor in
            var context: [String: Any] = [
                "source_surface": sourceSurface.rawValue,
                "followup_id": suggestion.id,
                "source_action_id": sourceActionID as Any
            ]
            if captureApproval {
                context["allow_clipboard_capture"] = true
            }
            let status = await CapabilityExecutor.shared.execute(capability: capability, context: context)
            let pending = CapabilityExecutor.shared.takePendingResultCard(for: executionCapabilityID)
                ?? CapabilityExecutor.shared.takePendingResultCard(for: capabilityID)
            let shown = appState.presentActionCompletionSurface(
                actionID: actionID,
                capabilityID: executionCapabilityID,
                title: suggestion.title,
                status: status,
                reason: nil,
                outputText: nil,
                sourceSurface: sourceSurface,
                pendingPayload: pending
            )
            appState.logUnifiedActionResult(actionID: suggestion.id, status: status, cardShown: shown, reason: nil)
            print("[FollowupActionResult] id=\(suggestion.id) status=\(followupStatusName(status)) card=\(shown ? "shown" : "hidden")")
        }
    }

    static func routeName(for suggestion: UnifiedSuggestion, capabilityID: String) -> String {
        if suggestion.kind == .composedPlan || ComposedActionUIRegistry.isComposedPlanID(capabilityID) {
            return "composed_executor"
        }
        if ComposedActionUIRegistry.isComposedFollowUpID(capabilityID) || capabilityID.hasPrefix("followup:") {
            return "followup_executor"
        }
        if suggestion.kind == .setupAction && suggestion.acceptBehavior == .captureFirst {
            return "capture_executor"
        }
        if suggestion.kind == .setupAction {
            return "setup_executor"
        }
        if suggestion.kind == .mediaAction || ["play_focus_media", "pause_media", "resume_focus_media", "suggest_focus_playlist"].contains(capabilityID) {
            return "music_executor"
        }
        if windowLayoutCapabilities.contains(capabilityID) {
            return "window_layout_executor"
        }
        if suggestion.kind == .memoryAction || ["remember_workspace", "restore_workspace", "save_task_context", "recall_related_context", "save_research_session"].contains(capabilityID) {
            return "memory_executor"
        }
        if suggestion.executionPath == .localSystemExecutor {
            return "local_system_executor"
        }
        return "capability_executor"
    }

    private static func followupStatusName(_ status: CapabilityExecutionStatus?) -> String {
        switch status {
        case .success, .partial, .alreadySatisfied, .previewGenerated, .openedSearch:
            return "success"
        case .captureNeeded:
            return "needs_context"
        case .blocked, .unavailable:
            return "blocked"
        default:
            return "failed"
        }
    }

    private static func inferredCapabilityID(for suggestion: UnifiedSuggestion, actionID: String) -> String {
        suggestion.debugMetadata?["capabilityId"] ?? actionID
    }

    private static func payloadSummary(
        suggestion: UnifiedSuggestion,
        actionID: String,
        capabilityID: String,
        route: String,
        resolution: StoredActionResolution?,
        context: ContextModel
    ) -> (targets: [String], urls: [String], valid: Bool) {
        if route == "composed_executor" {
            return ([], [], ComposedActionUIRegistry.resolve(actionID) != nil)
        }
        if route == "followup_executor", ComposedActionUIRegistry.isComposedFollowUpID(actionID) {
            return ([], [], ComposedActionUIRegistry.resolveFollowUp(actionID) != nil)
        }
        if let action = resolution?.action as? DeterministicCapabilityPanelAction {
            return (
                action.involvedApps,
                action.involvedURLs,
                action.canExecute(context: context)
            )
        }
        if ["setup_executor", "capture_executor", "music_executor", "local_system_executor", "capability_executor", "memory_executor"].contains(route) {
            return ([], [], true)
        }
        if route == "window_layout_executor" {
            return ([], [], capabilityID == "arrange_side_by_side")
        }
        return ([], [], true)
    }
}
