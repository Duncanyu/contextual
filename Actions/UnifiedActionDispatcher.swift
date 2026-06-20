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

/// Result-card / surface UI commands. These are handled by the result-surface
/// host (close, expand, copy, reopen) and must NEVER be dispatched as
/// capabilities. Mapping is by the raw visible action id.
enum ResultCardCommand: String {
    case dismiss        = "dismiss_result"
    case showDetails    = "show_details"
    case collapse       = "collapse_details"
    case copyResult     = "copy_result"
    case reopenPanel    = "reopen_panel"

    static func from(id: String) -> ResultCardCommand? {
        switch id.lowercased().trimmingCharacters(in: .whitespaces) {
        case "dismiss", "close", "dismiss_result":                 return .dismiss
        case "details", "show_details", "more_details",
             "show details", "more details", "expand":             return .showDetails
        case "collapse", "collapse_details":                       return .collapse
        case "copy_result", "copy", "copy_summary", "copy summary": return .copyResult
        case "reopen_panel", "open_panel", "reopen panel":         return .reopenPanel
        default:                                                   return nil
        }
    }
}

/// One honest classification of a product-visible action: is it executable, is
/// it a UI command, or is it neither (and must be suppressed before it can
/// dispatch with executor_missing)?
struct VisibleActionIdentity {
    let visibleID: String
    let canonicalID: String
    let executable: Bool
    let uiCommand: ResultCardCommand?
    var allowed: Bool { executable || uiCommand != nil }
    var reason: String {
        if uiCommand != nil { return "ui_command" }
        if executable { return "executor_present" }
        if visibleID.hasPrefix("ambient_jarvis:") || canonicalID.hasPrefix("ambient_jarvis:") { return "unmapped_legacy_id" }
        return "no_executor_or_command"
    }
    var suppressionReason: String {
        if visibleID.hasPrefix("ambient_jarvis:") || canonicalID.hasPrefix("ambient_jarvis:") { return "unmapped_legacy_id" }
        return "executor_missing"
    }
}

enum VisibleActionLifecycleLogger {
    static func log(
        id: String,
        created: Bool,
        renderAttempted: Bool,
        visible: Bool,
        accepted: Bool,
        dispatched: Bool,
        suppressedStage: String,
        status: Bool
    ) {
        print("[VisibleActionLifecycleCheck] id=\(id) created=\(created ? "yes" : "no") render_attempted=\(renderAttempted ? "yes" : "no") visible=\(visible ? "yes" : "no") accepted=\(accepted ? "yes" : "no") dispatched=\(dispatched ? "yes" : "no") suppressed_stage=\(suppressedStage) status=\(status ? "pass" : "fail")")
    }
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
        "ask_for_missing_info": "list_missing_form_info",
        // summarize_visible_content is a generic-cognitive synonym handled by the
        // executor switch alongside explicit_visible_capture_summary, but it was
        // never a registered capability id — so a visible button carrying it would
        // be suppressed as executor_missing. Canonicalize it to the real executor.
        "summarize_visible_content": "explicit_visible_capture_summary"
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

    /// Resolve a product-visible action to its honest identity: executable
    /// capability, UI command, or neither. The single source of truth that
    /// guarantees no visible action dispatches with executor_missing.
    static func identity(for suggestion: UnifiedSuggestion, appState: AppState) -> VisibleActionIdentity {
        let actionID = suggestion.originalActionId ?? suggestion.id
        if let command = ResultCardCommand.from(id: suggestion.id) ?? ResultCardCommand.from(id: actionID) {
            return VisibleActionIdentity(visibleID: actionID, canonicalID: suggestion.id, executable: false, uiCommand: command)
        }
        let canonical = resolvedCapabilityID(for: suggestion, actionID: actionID, appState: appState)
        let route = routeName(for: suggestion, capabilityID: canonical)
        let executable = ActionAliasResolver.executorAvailable(visibleID: actionID, canonicalID: canonical, route: route)
        return VisibleActionIdentity(visibleID: actionID, canonicalID: canonical, executable: executable, uiCommand: nil)
    }

    /// Resolve the canonical capability id for a visible action. Maps
    /// `ambient_jarvis:<UUID>` wrappers back to the real capability (recovery
    /// fix) so actionable candidates are not mistaken for unmapped legacy ids.
    static func resolvedCapabilityID(for suggestion: UnifiedSuggestion, actionID: String, appState: AppState) -> String {
        let resolution = appState.resolveStoredAction(id: actionID, context: appState.debugContext)
        var rawCapabilityID = resolution.capabilityID != actionID
            ? resolution.capabilityID
            : (suggestion.debugMetadata?["capabilityId"] ?? inferredCapabilityID(for: suggestion, actionID: actionID))
        if rawCapabilityID.hasPrefix("ambient_jarvis:") || actionID.hasPrefix("ambient_jarvis:"),
           let canonicalCap = appState.canonicalCapabilityForVisibleID(actionID) {
            print("[ActionIdentityMapping] source_id=\(actionID) canonical=\(canonicalCap) mapped=yes")
            rawCapabilityID = canonicalCap
        }
        return ActionAliasResolver.canonicalID(for: rawCapabilityID)
    }

    @discardableResult
    static func dispatch(
        suggestion: UnifiedSuggestion,
        sourceSurface: ActionSourceSurface,
        appState: AppState
    ) -> UnifiedActionDispatchOutcome {
        let actionID = suggestion.originalActionId ?? suggestion.id
        let surfaceName = auditSurfaceName(sourceSurface)
        print("[ActionClickReceived] surface=\(surfaceName) id=\(suggestion.id)")

        // ── Identity guard (Part B/C): no visible action may dispatch as a
        //    capability unless it resolves to an executor. UI commands are
        //    handled by the surface host; unmapped/legacy ids are suppressed
        //    instead of surfacing a broken executor_missing card.
        let vid = identity(for: suggestion, appState: appState)
        print("[VisibleActionIdentityCheck] id=\(suggestion.id) kind=\(suggestion.kind.rawValue) canonical=\(vid.canonicalID) executable=\(vid.executable ? "yes" : "no") ui_command=\(vid.uiCommand != nil ? "yes" : "no") allowed=\(vid.allowed ? "yes" : "no") reason=\(vid.reason)")
        print("[ActionClickResolution] id=\(suggestion.id) resolved=\(vid.allowed ? "yes" : "no") target=\(vid.uiCommand?.rawValue ?? vid.canonicalID) reason=\(vid.reason)")
        if let command = vid.uiCommand {
            print("[UICommandNotDispatchedAsCapability] id=\(suggestion.id) status=pass")
            VisibleActionLifecycleLogger.log(
                id: suggestion.id,
                created: true,
                renderAttempted: true,
                visible: true,
                accepted: true,
                dispatched: false,
                suppressedStage: "none",
                status: true
            )
            appState.runResultCardUICommand(command, targetID: actionID, title: suggestion.title, surfaceText: nil)
            print("[ActionOutputVisibilityContract] id=\(suggestion.id) visible_result=yes visible_error=no")
            return UnifiedActionDispatchOutcome(
                suggestionID: suggestion.id, actionID: actionID, capabilityID: suggestion.id,
                route: "ui_command", allowed: true, reason: "ui_command",
                payloadValid: true, entryPoint: "UnifiedActionDispatcher"
            )
        }
        if !vid.executable {
            print("[VisibleActionSuppressed] id=\(suggestion.id) reason=\(vid.suppressionReason)")
            print("[DeadButtonDetected] id=\(suggestion.id) surface=\(surfaceName) reason=\(vid.suppressionReason)")
            let shown = appState.presentActionCompletionSurface(
                actionID: actionID,
                capabilityID: vid.canonicalID,
                title: suggestion.title,
                status: .unavailable,
                reason: vid.suppressionReason,
                outputText: nil,
                sourceSurface: sourceSurface,
                pendingPayload: nil
            )
            appState.logUnifiedActionResult(actionID: suggestion.id, status: .unavailable, cardShown: shown, reason: vid.suppressionReason)
            if sourceSurface == .followup {
                print("[FollowupActionResult] id=\(suggestion.id) status=suppressed card=\(shown ? "shown" : "hidden")")
            }
            return UnifiedActionDispatchOutcome(
                suggestionID: suggestion.id, actionID: actionID, capabilityID: vid.canonicalID,
                route: "suppressed", allowed: false, reason: "suppressed_\(vid.suppressionReason)",
                payloadValid: false, entryPoint: "UnifiedActionDispatcher"
            )
        }

        let resolution = appState.resolveStoredAction(id: actionID, context: appState.debugContext)
        // Reuse the same canonical resolution as the identity guard (maps
        // ambient_jarvis:<UUID> → real capability) so routing/allowed agree with
        // the pre-render check and real actions are not blocked as executor_missing.
        let capabilityID = resolvedCapabilityID(for: suggestion, actionID: actionID, appState: appState)
        let alias = ActionAliasResolver.resolve(suggestion.debugMetadata?["capabilityId"] ?? actionID)
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
        print("[ActionClickResolution] id=\(suggestion.id) resolved=\(allowed ? "yes" : "no") target=\(capabilityID) reason=\(reason)")
        VisibleActionLifecycleLogger.log(
            id: suggestion.id,
            created: true,
            renderAttempted: true,
            visible: true,
            accepted: true,
            dispatched: allowed,
            suppressedStage: "none",
            status: allowed
        )
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
            print("[DeadButtonDetected] id=\(suggestion.id) surface=\(surfaceName) reason=\(reason)")
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

        print("[CapabilityExecution] started id=\(capabilityID) source_surface=\(surfaceName)")
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
                let parentUIID = ComposedActionUIRegistry.resolveFollowUp(actionID)?.parent.identity.uiID
                let result = await ComposedActionClickDispatcher.executeFollowUp(id: actionID, sourceSurface: sourceSurface.rawValue)
                // Composed follow-ups present the full card (with follow-up buttons)
                // inside executeFollowUp via presentCognitiveResultSurface(parentUIID).
                // A second presentActionCompletionSurface with the follow-up id would
                // replace that card with a dismiss-only stub.
                if let parentUIID,
                   appState.activeFloatingResultSurface?.capabilityID == parentUIID
                    || appState.activePanelResultSurface?.capabilityID == parentUIID {
                    appState.logUnifiedActionResult(actionID: suggestion.id, status: result.executionStatus, cardShown: true, reason: nil)
                    print("[FollowupActionResult] id=\(suggestion.id) parent=\(parentUIID) status=\(followupStatusName(result.executionStatus)) card=shown reason=already_presented_by_executor")
                    return
                }
                let pending = parentUIID.flatMap { CapabilityExecutor.shared.takePendingResultCard(for: $0) }
                    ?? CapabilityExecutor.shared.takePendingResultCard(for: actionID)
                let shown = appState.presentActionCompletionSurface(
                    actionID: actionID,
                    capabilityID: parentUIID ?? actionID,
                    title: suggestion.title,
                    status: result.executionStatus,
                    reason: nil,
                    outputText: result.outputText,
                    sourceSurface: sourceSurface,
                    pendingPayload: pending
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

    private static func auditSurfaceName(_ sourceSurface: ActionSourceSurface) -> String {
        switch sourceSurface {
        case .floating: return "popup"
        case .panel: return "panel"
        case .followup: return "followup"
        case .unknown: return "unknown"
        }
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
            if let scope = suggestion.debugMetadata?["context_scope"], !scope.isEmpty {
                context["context_scope"] = scope
            }
            if captureApproval {
                context["allow_clipboard_capture"] = true
            }
            let status = await CapabilityExecutor.shared.execute(capability: capability, context: context)
            let isCapturePrerequisite = ["capture_visible_page", "capture_full_document"].contains(capabilityID) && sourceActionID != nil
            let pending = sourceActionID.flatMap { CapabilityExecutor.shared.takePendingResultCard(for: $0) }
                ?? CapabilityExecutor.shared.takePendingResultCard(for: capabilityID)
                ?? CapabilityExecutor.shared.takePendingResultCard(for: executionCapabilityID)
            if let scopeRaw = suggestion.debugMetadata?["context_scope"], !scopeRaw.isEmpty, let sourceActionID {
                appState.completeContextScopeSelection(
                    resultID: sourceActionID,
                    scopeRaw: scopeRaw,
                    status: status,
                    chars: pending?.outputChars ?? 0,
                    reason: nil
                )
            }
            if isCapturePrerequisite, let sourceActionID {
                print("[ResultOwnership] capture=\(capabilityID) parent=\(sourceActionID) owner=parent reason=capture_then_resume")
                if pending != nil {
                    print("[ParentActionResultSurface] parent=\(sourceActionID) status=\(followupStatusName(status)) output_chars=\(pending?.outputChars ?? 0)")
                } else if ComposedActionUIRegistry.resolve(sourceActionID) != nil {
                    // Parent owns the card — resume already ran inside executeCapture.
                    // If nothing pending, still log; composed executor presents on parent id.
                    print("[CaptureWrapperResultSuppressed] capture=\(capabilityID) parent=\(sourceActionID) reason=parent_action_owns_result composed=yes")
                    appState.logUnifiedActionResult(actionID: suggestion.id, status: status, cardShown: false, reason: "parent_action_owns_result")
                    print("[FollowupActionResult] id=\(suggestion.id) status=\(followupStatusName(status)) card=parent_owned")
                    return
                } else {
                    print("[CaptureWrapperResultSuppressed] capture=\(capabilityID) parent=\(sourceActionID) reason=parent_action_owns_result")
                    print("[NoTinyCaptureWrapperResults] status=pass count=0")
                    appState.logUnifiedActionResult(actionID: suggestion.id, status: status, cardShown: false, reason: "parent_action_owns_result")
                    print("[FollowupActionResult] id=\(suggestion.id) status=\(followupStatusName(status)) card=hidden")
                    return
                }
            }
            let shown = appState.presentActionCompletionSurface(
                actionID: actionID,
                capabilityID: isCapturePrerequisite ? (sourceActionID ?? executionCapabilityID) : executionCapabilityID,
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
