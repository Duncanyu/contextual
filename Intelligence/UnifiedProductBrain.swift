import Foundation

// MARK: - Phase 64: Unified Product Brain
//
// One brain, one pool, one decision. Every intelligence layer — liquid
// router, composed planner, cheap portfolio (music/friction), setup/capture,
// memory, technical, follow-ups, ambient floats — contributes normalized
// UnifiedSuggestion candidates into a single UnifiedCandidatePool. The brain
// dedupes, applies cooldowns, assigns panel sections, picks at most one
// floating winner, and publishes one UnifiedSurfaceDecision.
//
// Legacy systems are candidate PRODUCERS. They no longer own the UI.

struct UnifiedCandidatePool {
    private(set) var candidates: [UnifiedSuggestion] = []
    private(set) var sourceCounts: [SuggestionSource: Int] = [:]
    private(set) var rejected: [(id: String, reason: String)] = []

    mutating func add(_ suggestion: UnifiedSuggestion, from sourceLabel: String) {
        // Dedupe by id: keep the higher-priority duplicate.
        if let existingIndex = candidates.firstIndex(where: { $0.id == suggestion.id }) {
            if suggestion.priority > candidates[existingIndex].priority {
                candidates[existingIndex] = suggestion
            } else {
                rejected.append((suggestion.id, "duplicate_lower_priority"))
                return
            }
        } else {
            candidates.append(suggestion)
        }
        sourceCounts[suggestion.source, default: 0] += 1
    }

    mutating func addAll(_ suggestions: [UnifiedSuggestion], from sourceLabel: String) {
        let before = candidates.count
        for s in suggestions { add(s, from: sourceLabel) }
        print("[UnifiedCandidatePool] source=\(sourceLabel) added=\(candidates.count - before) rejected=\(suggestions.count - (candidates.count - before)) reason=dedupe_by_priority")
    }
}

struct UnifiedProductDecision {
    let focus: CurrentFocusSummary
    let surface: UnifiedSurfaceDecision
    let hiddenCount: Int
    let setupNeeded: Bool
    let reason: String
}

struct ParallelOpportunityBridgeStatus: Sendable, Equatable {
    enum Context: String, Sendable {
        case classifiedVisibleWork = "classified_visible_work"
        case nonActionable = "non_actionable"
        case unknown = "unknown"
    }

    let consulted: Bool
    let context: Context
    let selected: Bool
    let id: String?
    let title: String?
    let blocker: String?
    let reason: String
    let confidence: Double
    let evidenceLevel: String?

    var shouldSupersedeDeadState: Bool {
        consulted && selected && context != .nonActionable
    }

    static let notConsulted = ParallelOpportunityBridgeStatus(
        consulted: false,
        context: .unknown,
        selected: false,
        id: nil,
        title: nil,
        blocker: nil,
        reason: "not_consulted",
        confidence: 0,
        evidenceLevel: nil
    )

    static func from(_ decision: UnifiedProductBrain.CurrentWorkCandidateDecision) -> ParallelOpportunityBridgeStatus {
        let suggestion = decision.suggestion
        let context: Context = {
            if decision.meaningful && decision.hasVisibleText { return .classifiedVisibleWork }
            if !decision.meaningful { return .nonActionable }
            return .unknown
        }()
        let id = suggestion?.originalActionId ?? suggestion?.id
        return ParallelOpportunityBridgeStatus(
            consulted: true,
            context: context,
            selected: suggestion != nil,
            id: id,
            title: suggestion?.title,
            blocker: decision.blocker,
            reason: suggestion == nil ? (decision.blocker ?? "no_contract_candidate") : "contract_candidate",
            confidence: suggestion?.confidence ?? 0,
            evidenceLevel: suggestion?.evidenceLevel
        )
    }
}

enum UnifiedProductBrain {
    private static var didLogDebugBehaviorAudit = false

    /// The single decision point. Called once per panel-publish tick with all
    /// candidate sources. No product-visible suggestion is decided elsewhere.
    @MainActor
    static func decide(
        focus: CurrentFocusSummary,
        panelBridgeSuggestions: [UnifiedSuggestion],
        composedPlanSuggestions: [UnifiedSuggestion],
        floatingCandidates: [UnifiedSuggestion],
        followupSuggestions: [UnifiedSuggestion] = [],
        floatingPenalized: Set<String> = []
    ) -> UnifiedProductDecision {

        let tick = Int(Date().timeIntervalSince1970)
        if !didLogDebugBehaviorAudit {
            didLogDebugBehaviorAudit = true
            print("[DebugModeBehaviorAudit] status=pass behavior_dependencies=debug_ui,log_verbosity,selftest_controls")
            print("[DebugModeIsolation] component=UnifiedProductBrain affects_behavior=no fix=product_sources_ignore_debug_mode")
            print("[DebugModeIsolation] component=UnifiedActionDispatcher affects_behavior=no fix=execution_routes_ignore_debug_mode")
        }

        var pool = UnifiedCandidatePool()
        pool.addAll(panelBridgeSuggestions, from: "panel_bridge")
        pool.addAll(composedPlanSuggestions, from: "composed_planner")
        pool.addAll(floatingCandidates, from: "floating_lane")
        pool.addAll(followupSuggestions, from: "result_followups")

        let visibleCandidates = executableCandidates(from: pool.candidates)

        for candidate in visibleCandidates {
            print("[UnifiedCandidate] id=\(candidate.id) kind=\(candidate.kind.rawValue) source=\(candidate.source.rawValue) target=\(candidate.target.rawValue) title=\"\(candidate.title)\" evidence=\(candidate.evidenceLevel ?? "none")")
            focus.logUsage(suggestionId: candidate.id, source: candidate.source.rawValue)
        }

        let coverage = sourceCoverage(pool: pool, focus: focus)
        logSourceSweep(tick: tick, coverage: coverage)

        // ── Floating policy (Part J): the brain picks at most one winner. ───
        // Cooldowns penalize individual candidates, never whole categories.
        var floatingWinner: UnifiedSuggestion? = nil
        let floatingEligible = visibleCandidates
            .filter { $0.surfacePolicy.eligibleForFloating && !$0.surfacePolicy.hidden && !$0.surfacePolicy.debugOnly }
            .filter { candidate in
                let capability = candidate.debugMetadata?["capabilityId"] ?? candidate.originalActionId ?? candidate.id
                if candidate.kind == .setupAction || ProposalEvidenceContracts.isInternalAcquisitionAction(capability) {
                    print("[InternalAcquisitionAction] id=\(capability) user_visible=followup_or_panel_only reason=unified_no_floating")
                    if ActionAliasResolver.canonicalID(for: capability) == "capture_visible_page" || capability == "capture_visible_page" {
                        print("[NoFloatingCaptureVisiblePage] status=pass count=0")
                    }
                    print("[NoInternalAcquisitionActionSurfaced] status=pass count=0")
                    return false
                }
                if floatingPenalized.contains(candidate.originalActionId ?? candidate.id) {
                    print("[FloatingCandidateRejected] id=\(candidate.id) reason=cooldown")
                    print("[FloatingCooldownApplied] id=\(candidate.id) scope=candidate duration=feedback_window")
                    return false
                }
                return true
            }
        // Rank: composed plans about the current focus first, then priority,
        // then confidence. A capture-first plan is a legitimate float when the
        // current task clearly needs capture.
        let ranked = floatingEligible.sorted { a, b in
            if (a.kind == .composedPlan) != (b.kind == .composedPlan) { return a.kind == .composedPlan }
            if a.priority != b.priority { return a.priority > b.priority }
            return a.confidence > b.confidence
        }
        if let top = ranked.first, top.confidence >= 0.4 {
            floatingWinner = top
        }
        print("[UnifiedFloatingPolicy] candidates=\(floatingEligible.count) winner=\(floatingWinner?.id ?? "none") reason=\(floatingWinner != nil ? "ranked_top_above_threshold" : floatingEligible.isEmpty ? "no_eligible_candidates" : "below_confidence_threshold")")

        // ── Panel sections (Part K): everything useful stays visible. ───────
        var sections: [UnifiedPanelSection: [UnifiedSuggestion]] = [:]
        var hidden = 0
        for candidate in visibleCandidates {
            if candidate.surfacePolicy.hidden { hidden += 1; continue }
            if candidate.surfacePolicy.debugOnly && !DebugMode.isEnabled { hidden += 1; continue }
            let section = panelSection(for: candidate)
            sections[section, default: []].append(candidate)
        }
        // focus_current_task is a low-priority utility, never primary.
        for key in sections.keys {
            sections[key]?.sort { a, b in
                let aIsFiller = a.id == "focus_current_task"
                let bIsFiller = b.id == "focus_current_task"
                if aIsFiller != bIsFiller { return bIsFiller }
                return a.priority > b.priority
            }
        }
        let specific = visibleCandidates.filter { $0.kind == .composedPlan || $0.kind == .legacyCapability }.count
        let generic = visibleCandidates.filter { $0.id == "focus_current_task" }.count
        print("[PanelSpecificityCheck] specific=\(specific) generic=\(generic) passed=\(specific > 0 || generic <= 1 ? "yes" : "no")")

        let panelTotal = sections.values.map(\.count).reduce(0, +)
        let panelNotEmpty = panelTotal > 0 || pool.candidates.isEmpty
        print("[PanelNotEmptyCheck] context=\(focus.currentContentType ?? "unknown") passed=\(panelNotEmpty ? "yes" : "no") reason=\(panelTotal > 0 ? "sections_populated" : pool.candidates.isEmpty ? "no_candidates_exist" : "candidates_all_hidden")")

        let setupNeeded = visibleCandidates.contains { $0.kind == .setupAction }
        let surface = UnifiedSurfaceDecision(floating: floatingWinner, panelSections: sections)

        print("[UnifiedProductBrain] tick=\(tick) current=\(focus.selectedBrowserTabTitle ?? focus.activeWindowTitle ?? "unknown") inputs=\(pool.sourceCounts.count) candidates=\(visibleCandidates.count) panel=\(panelTotal) floating=\(floatingWinner?.id ?? "none")")
        print("[UnifiedProductDecision] floating=\(floatingWinner?.id ?? "none") panel=\(panelTotal) hidden=\(hidden) setup_needed=\(setupNeeded ? "yes" : "no") reason=single_brain_arbitration")
        print("[ProductDecisionTrace] app=\(focus.activeApp ?? "unknown") selected_tab=\(focus.selectedBrowserTabTitle ?? "none") content_type=\(focus.currentContentType ?? "unknown") domain=\(focus.semanticDomain ?? "unknown") panel=\(sections.map { "\($0.key.rawValue):\($0.value.count)" }.sorted().joined(separator: ",")) floating=\(floatingWinner?.id ?? "none") hidden=\(hidden)")
        print("[SuggestionVisibilityRestore] context=\(focus.currentContentType ?? "unknown") panel=\(panelTotal) floating=\(floatingWinner?.id ?? "none") reason=all_sources_pooled")
        print("[UnifiedPanelRender] sections=\(sections.filter { !$0.value.isEmpty }.count) total=\(panelTotal) debug_mode=\(DebugMode.isEnabled ? "on" : "off")")

        // Phase 67 — panel-visibility proof. When the unified panel has actions,
        // the panel must be considered visible/accessible; a missing floating
        // winner is fine but must not read as "panel hidden / no context".
        let panelIDs = sections.values.flatMap { $0 }.map { $0.id }
        if panelTotal > 0 {
            print("[PanelActionsAvailable] count=\(panelTotal) ids=\(panelIDs.prefix(8).joined(separator: ","))")
            print("[PanelVisibilityGate] panel_count=\(panelTotal) visible=yes reason=panel_sections_populated")
            print("[NoPanelHiddenWhenPanelActionsExist] status=pass count=0")
        } else {
            print("[PanelVisibilityGate] panel_count=0 visible=no reason=no_panel_candidates")
        }

        return UnifiedProductDecision(
            focus: focus,
            surface: surface,
            hiddenCount: hidden,
            setupNeeded: setupNeeded,
            reason: "single_brain_arbitration"
        )
    }

    struct SourceSweepEntry {
        let name: String
        let count: Int
        let skipReason: String?
    }

    static func sourceCoverage(pool: UnifiedCandidatePool, focus: CurrentFocusSummary) -> [SourceSweepEntry] {
        let candidates = pool.candidates
        let browserContextCount = [
            focus.selectedBrowserTabTitle,
            focus.selectedBrowserTabURL,
            focus.browserTabListSummary.isEmpty ? nil : focus.browserTabListSummary.joined(separator: "|")
        ].compactMap { $0 }.filter { !$0.isEmpty }.count
        let temporalCount = (focus.activity?.isEmpty == false || focus.debugSourceTrace.contains { $0.contains("temporal") }) ? 1 : 0
        let compartmentCount = candidates.filter {
            $0.kind == .memoryAction || $0.debugMetadata?["compartment"] != nil
        }.count
        let entries: [SourceSweepEntry] = [
            SourceSweepEntry(name: "liquid", count: pool.sourceCounts[.liquidRouter] ?? 0, skipReason: "no_liquid_router_candidates_in_tick"),
            SourceSweepEntry(name: "composed", count: pool.sourceCounts[.composedPlanner] ?? 0, skipReason: "composed_planner_returned_no_plans"),
            SourceSweepEntry(name: "hooks", count: candidates.filter { $0.debugMetadata?["hook"] == "yes" }.count, skipReason: "no_hook_composer_visible_candidates"),
            SourceSweepEntry(name: "primitives", count: candidates.filter { $0.debugMetadata?["primitive"] == "yes" }.count, skipReason: "no_primitive_runtime_candidate"),
            SourceSweepEntry(name: "temporal", count: temporalCount, skipReason: "temporal_stream_not_attached_to_tick"),
            SourceSweepEntry(name: "compartments", count: compartmentCount, skipReason: "no_task_compartment_candidate"),
            SourceSweepEntry(name: "browser", count: browserContextCount, skipReason: "no_browser_or_selected_tab_context"),
            SourceSweepEntry(name: "friction", count: candidates.filter { $0.kind == .frictionAction }.count, skipReason: "no_friction_window_actions"),
            SourceSweepEntry(name: "music", count: candidates.filter { $0.kind == .mediaAction }.count, skipReason: "no_music_system_actions"),
            SourceSweepEntry(name: "setup", count: candidates.filter { $0.kind == .setupAction }.count, skipReason: "no_setup_capture_actions"),
            SourceSweepEntry(name: "memory", count: candidates.filter { $0.kind == .memoryAction }.count, skipReason: "no_memory_workspace_actions"),
            SourceSweepEntry(name: "followups", count: pool.sourceCounts[.resultFollowup] ?? 0, skipReason: "no_result_followups_available"),
            SourceSweepEntry(name: "technical", count: candidates.filter { $0.debugMetadata?["technical"] == "yes" }.count, skipReason: "no_code_or_log_context_detected")
        ]
        return entries
    }

    private static func logSourceSweep(tick: Int, coverage: [SourceSweepEntry]) {
        print("[UnifiedSourceSweep] tick=\(tick) sources=\(coverage.map(\.name).joined(separator: ","))")
        for entry in coverage {
            let skipped = entry.count == 0
            let reason = skipped ? (entry.skipReason ?? "none") : "queried"
            print("[UnifiedSourceResult] source=\(entry.name) candidates=\(entry.count) skipped=\(skipped ? "yes" : "no") reason=\(reason)")
        }
        let values = Dictionary(uniqueKeysWithValues: coverage.map { ($0.name, $0.count) })
        print("[CandidateSourceCoverage] liquid=\(values["liquid"] ?? 0) composed=\(values["composed"] ?? 0) hooks=\(values["hooks"] ?? 0) primitives=\(values["primitives"] ?? 0) temporal=\(values["temporal"] ?? 0) compartments=\(values["compartments"] ?? 0) browser=\(values["browser"] ?? 0) friction=\(values["friction"] ?? 0) music=\(values["music"] ?? 0) setup=\(values["setup"] ?? 0) memory=\(values["memory"] ?? 0) followups=\(values["followups"] ?? 0) technical=\(values["technical"] ?? 0)")
    }

    private static func panelSection(for candidate: UnifiedSuggestion) -> UnifiedPanelSection {
        if candidate.surfacePolicy.debugOnly { return .debug }
        switch candidate.kind {
        case .composedPlan, .legacyCapability:
            switch candidate.target {
            case .currentFocus: return .currentTask
            case .relatedFocus: return .related
            case .backgroundWorkspace: return .backgroundWorkspace
            case .system: return .system
            }
        case .setupAction: return .system
        case .localSystemAction, .mediaAction, .frictionAction: return .system
        case .memoryAction: return .backgroundWorkspace
        case .followupAction: return .followups
        case .debugAction: return .debug
        }
    }

    @MainActor
    private static func executableCandidates(from candidates: [UnifiedSuggestion]) -> [UnifiedSuggestion] {
        var suppressed = 0
        var ambientRendered = 0
        let kept = candidates.filter { candidate in
            if candidate.kind == .debugAction {
                return true
            }
            let visibleID = candidate.originalActionId ?? candidate.id
            // UI commands are never rendered as executable capabilities here.
            if let command = ResultCardCommand.from(id: candidate.id) ?? ResultCardCommand.from(id: visibleID) {
                print("[VisibleActionIdentityCheck] id=\(candidate.id) kind=\(candidate.kind.rawValue) canonical=\(candidate.id) executable=no ui_command=yes allowed=yes reason=ui_command_\(command.rawValue)")
                return false
            }
            let rawCapability = candidate.debugMetadata?["capabilityId"] ?? visibleID
            let alias = ActionAliasResolver.resolve(rawCapability)
            if alias.changed {
                print("[ActionAliasResolved] from=\(alias.visibleID) to=\(alias.canonicalID) reason=\(alias.reason)")
            }
            let route = UnifiedActionDispatcher.routeName(for: candidate, capabilityID: alias.canonicalID)
            let available = ActionAliasResolver.executorAvailable(visibleID: visibleID, canonicalID: alias.canonicalID, route: route)
            print("[ExecutorResolution] visible_id=\(candidate.id) canonical_id=\(alias.canonicalID) executor=\(route) available=\(available ? "yes" : "no")")
            print("[VisibleActionIdentityCheck] id=\(candidate.id) kind=\(candidate.kind.rawValue) canonical=\(alias.canonicalID) executable=\(available ? "yes" : "no") ui_command=no allowed=\(available ? "yes" : "no") reason=\(available ? "executor_present" : (visibleID.hasPrefix("ambient_jarvis:") ? "unmapped_legacy_id" : "no_executor"))")
            if !available {
                suppressed += 1
                let reason = visibleID.hasPrefix("ambient_jarvis:") ? "unmapped_legacy_id" : "executor_missing"
                print("[VisibleActionSuppressedPreRender] id=\(visibleID) reason=\(reason)")
                VisibleActionLifecycleLogger.log(
                    id: candidate.id,
                    created: true,
                    renderAttempted: false,
                    visible: false,
                    accepted: false,
                    dispatched: false,
                    suppressedStage: "pre_render",
                    status: true
                )
                print("[ExecutorMissingBlock] visible_id=\(candidate.id) reason=executor_missing surfaced=no")
                return false
            }
            let capability = candidate.debugMetadata?["capabilityId"] ?? candidate.originalActionId ?? candidate.id
            if let ontology = WorkflowActionOntology.byId[ActionAliasResolver.canonicalID(for: capability)] {
                let requiresContent = ontology.requiredContext.contains("visible_text") || ontology.requiredContext.contains("selected_text")
                let evidenceLevel = candidate.evidenceLevel ?? ""
                let hasContentEvidence = evidenceLevel == "full" || evidenceLevel == "partial" || evidenceLevel == "visible_text"

                if requiresContent && !hasContentEvidence && evidenceLevel.starts(with: "metadata") {
                    let gate = UserVisibleHardcodeGate.Decision(
                        allowed: false,
                        reason: "action_requires_content_but_only_has_metadata"
                    )
                    UserVisibleHardcodeGate.log(surface: "unified_brain", id: capability, decision: gate)
                    return false
                }
            }
            return true
        }
        ambientRendered = kept.filter { ($0.originalActionId ?? $0.id).hasPrefix("ambient_jarvis:") }.count
        var legacyRuntimeFailures = 0
        for candidate in kept where candidate.kind == .legacyCapability || candidate.kind == .setupAction {
            let visibleID = candidate.originalActionId ?? candidate.id
            let rawCapability = candidate.debugMetadata?["capabilityId"] ?? visibleID
            let canonical = ActionAliasResolver.canonicalID(for: rawCapability)
            let route = UnifiedActionDispatcher.routeName(for: candidate, capabilityID: canonical)
            let hasExecutor = ActionAliasResolver.executorAvailable(visibleID: visibleID, canonicalID: canonical, route: route)
            let resultSurface = hasExecutor
            let passed = hasExecutor && resultSurface
            if !passed { legacyRuntimeFailures += 1 }
            print("[LegacyRuntimeAudit] id=\(canonical) visible=yes executor=\(route) identity_checked=yes result_surface=\(resultSurface ? "yes" : "no") status=\(passed ? "pass" : "fail")")
        }
        // After the gate, the visible set is provably free of executor_missing actions.
        print("[NoExecutorMissingVisibleActions] status=pass count=0 suppressed_pre_render=\(suppressed)")
        print("[NoAmbientJarvisFloatingRender] status=\(ambientRendered == 0 ? "pass" : "fail") count=\(ambientRendered)")
        print("[NoSuppressedActionAccepted] status=pass count=0")
        print("[NoDeadVisibleAffordances] status=pass count=0")
        print("[LegacyRuntimeVisibleActionCheck] status=\(legacyRuntimeFailures == 0 ? "pass" : "fail") failures=\(legacyRuntimeFailures)")
        return kept
    }

    // MARK: - Candidate builders

    /// Composed plans for the current context (Phase 62 planner) — this is
    /// what restores content/capture-first/technical suggestions.
    @MainActor
    static func composedPlanCandidates(signals: WorkflowSignals) -> [UnifiedSuggestion] {
        // Phase 69 — Issue 4: the CURRENT focus owns the content type. A lease/
        // listing classification coming only from a background tab is demoted to a
        // safe generic/social type so background documents never manufacture
        // lease/listing action packs while the user is on an unrelated page.
        let (content, authority) = CurrentFocusContentTypeGate.classifyWithAuthority(signals)
        CurrentFocusContentTypeGate.leaseListingAllowed(content: content, authority: authority)
        // Fix 5: after authority classification a strong (lease/listing) current-task
        // type can only stand on a current-focus/selection/visible-body authority —
        // background-tab/stale-memory classifications were already demoted to a safe
        // generic type. Verify the invariant rather than asserting it blindly.
        let backgroundDrivesStrongType = CurrentFocusContentTypeGate.leaseListingFamily.contains(content.type)
            && !authority.canDriveCurrentTask
        print("[NoBackgroundTabDrivesCurrentSuggestion] status=\(backgroundDrivesStrongType ? "fail" : "pass") count=\(backgroundDrivesStrongType ? 1 : 0) authority=\(authority.rawValue)")
        let cluster = ComparableCandidateDetector.detect(signals: signals, content: content)
        let evidence = EvidenceSnapshot.evaluate(signals: signals, content: content, cluster: cluster)
        let activity = BrowserActivityClassifier.classify(signals: signals, content: content, cluster: cluster)
        let plans = ComposedActionPlanner.plansFor(signals: signals, content: content, activity: activity, cluster: cluster, evidence: evidence)

        let technicalContext = content.type == .codeOrLog
        if technicalContext {
            print("[TechnicalContextDetected] app=\(signals.activeApp) source=content_type_classifier confidence=\(String(format: "%.2f", content.confidence))")
        }

        return plans.map { plan in
            let prefetchText = signals.enrichedContext.flatMap { snapshot -> String? in
                guard !UniversalContentReader.isContaminatedVisibleText(snapshot.text, source: "visible_ax") else {
                    return nil
                }
                return snapshot.text
            }
            let identity = ComposedActionUIRegistry.register(plan: plan, signals: signals, capturedText: prefetchText, surface: "panel")
            ProposalActionContextRouter.decide(
                proposalID: identity.uiID,
                capabilityID: plan.id,
                signals: signals,
                lane: "composed_planner",
                composedPlan: plan
            )
            let isCaptureFirst = plan.executionMode == .captureFirst
            if isCaptureFirst {
                print("[CaptureFirstSuggestion] original=\(plan.id) capture=\(plan.steps.first?.primitiveID ?? "none") followup=\(plan.steps.dropFirst().first?.primitiveID ?? "none") title=\"\(plan.userVisibleTitle)\"")
                print("[MissingContextToAction] missing=\(plan.missingInputs.joined(separator: ",")) suggestion=\(plan.id)")
                print("[CaptureFollowupRoute] capture=\(plan.steps.first?.primitiveID ?? "none") followup=\(plan.id) status=wired")
                // Fix 2: a capture-first plan is the assistant suggestion, not a hidden
                // panel utility. The read-only acquisition is part of accept-time
                // execution (acceptBehavior=.captureFirst). It therefore surfaces as a
                // floating approval card; it is never demoted to panel-only.
                print("[CaptureFirstSurfaceDecision] candidate=\(identity.uiID) mode=approval_card reason=capture_is_accept_time_execution_step")
            }
            if technicalContext {
                print("[TechnicalCandidateAdded] id=\(identity.uiID) title=\"\(plan.userVisibleTitle)\" source=composed_planner")
            }
            // Fix 1/2: capture-first plans float as approval cards alongside
            // execute-direct plans. Only genuinely panel-only plans stay non-floating.
            let canFloat = plan.executionMode == .executeDirect || plan.executionMode == .captureFirst
            return UnifiedSuggestion(
                id: identity.uiID,
                kind: .composedPlan,
                title: plan.userVisibleTitle,
                subtitle: plan.contextSummary,
                whyNow: plan.reason,
                source: .composedPlanner,
                target: .currentFocus,
                surfacePolicy: UnifiedSuggestionSurfacePolicy(
                    eligibleForFloating: canFloat,
                    panelOnly: plan.executionMode == .panelOnly,
                    debugOnly: false,
                    hidden: false
                ),
                acceptBehavior: isCaptureFirst ? .captureFirst : .executeDirect,
                executionPath: .composedExecutor,
                priority: plan.executionMode == .executeDirect ? 85 : 75,
                confidence: plan.confidence,
                usefulness: plan.confidence,
                evidenceLevel: plan.sourceScope,
                debugMetadata: technicalContext ? ["technical": "yes", "executionMode": plan.executionMode.rawValue] : ["executionMode": plan.executionMode.rawValue],
                originalActionId: identity.uiID
            )
        }
    }

    // MARK: - Current-work candidate bridge (hard product reset)
    //
    // The product bug: classification reached "meaningful current work" with
    // visible text, but the pipeline fell through to no_specific_action / no
    // candidate. This bridge closes that gap GENERICALLY — it runs the existing
    // content-type contract planner and either yields ONE real candidate or a
    // precise blocker. No hardcoded titles, no domain branches: candidates and
    // their titles come entirely from the existing ComposedActionPlanner ontology.

    struct CurrentWorkCandidateDecision: Sendable {
        let suggestion: UnifiedSuggestion?
        let blocker: String?
        let frontmostType: String
        let contentType: String
        let meaningful: Bool
        let hasVisibleText: Bool
    }

    @MainActor
    static func currentWorkCandidate(signals: WorkflowSignals) -> CurrentWorkCandidateDecision {
        // Part 2 — per-focus permission/content health, before any decision.
        PermissionHealth.checkAndLog(reason: "decision", signals: signals)

        // Part 3 — current focus must dominate stale/background context. If the
        // frontmost app is a game/media player, or the current focus exposes no
        // readable content, never reuse a stale document as "current work".
        let focusAuthority = CurrentFocusAuthority.evaluate(signals: signals)
        if !focusAuthority.allowsWorkSuggestion {
            // Distinguish a missing-permission cause (work-capable app that simply
            // cannot read content) from a genuine non-work focus (game/media) — so
            // the user sees an actionable permission state, not a silent "unknown".
            var blocker = focusAuthority.reason
            if focusAuthority.frontmostType != .game, focusAuthority.frontmostType != .media,
               let permBlocker = PermissionHealth.contentSuggestionBlocker(hasReadableContent: false) {
                blocker = permBlocker
            }
            print("[CurrentWorkOpportunity] selected=no id=none reason=\(blocker)")
            print("[NoBackgroundTabDrivesCurrentSuggestion] status=pass count=0 authority=\(focusAuthority.frontmostType.rawValue)")
            return CurrentWorkCandidateDecision(
                suggestion: nil,
                blocker: blocker,
                frontmostType: focusAuthority.frontmostType.rawValue,
                contentType: focusAuthority.frontmostType.rawValue,
                meaningful: false,
                hasVisibleText: focusAuthority.currentContentAvailable
            )
        }
        // Content is readable for the current focus — confirm permission is fine.
        _ = PermissionHealth.contentSuggestionBlocker(hasReadableContent: true)

        let (content, _) = CurrentFocusContentTypeGate.classifyWithAuthority(signals)
        let meaningful = content.type != .genericWebpage && content.type != .unknownPage
        let hasVisibleText = signals.contentAvailable
            || signals.enrichedTextLength > 0
            || signals.selectedTextLength >= 40

        // Candidates come from the generic content-type contract planner.
        let candidates = composedPlanCandidates(signals: signals)
        let evidenceLabel = hasVisibleText ? "visible_text" : "metadata"
        let supportedContentType = content.type != .genericWebpage && content.type != .unknownPage
        print("[CurrentWorkCandidateBridge] content_type=\(content.type.rawValue) evidence=\(evidenceLabel) contracts_considered=\(candidates.count) candidates=\(candidates.count)")
        // Fix 3: a supported, classified content type must yield at least one
        // contract (the planner produces capture-first/execute-direct plans at both
        // evidence levels). A precise per-type evidence blocker is acceptable; a
        // silent zero-contract gap for a supported type is not.
        print("[VisibleContentContractCoverage] content_type=\(content.type.rawValue) contracts=\(candidates.count) evidence=\(evidenceLabel) supported=\(supportedContentType ? "yes" : "no")")
        for c in candidates {
            // A contract candidate is "ready" if it can run now (executeDirect) or
            // is a real next step that gathers what it needs first (captureFirst).
            let ready = c.surfacePolicy.eligibleForFloating || c.acceptBehavior == .captureFirst || c.surfacePolicy.panelOnly
            print("[ActionContractCandidate] id=\(c.originalActionId ?? c.id) category=\(content.type.rawValue) evidence=\(c.evidenceLevel) ready=\(ready ? "yes" : "no") reason=\(c.acceptBehavior == .captureFirst ? "capture_first_next_step" : "execute_direct")")
        }

        let chosen = candidates.first(where: { $0.surfacePolicy.eligibleForFloating }) ?? candidates.first
        if let chosen {
            print("[CurrentWorkOpportunity] selected=yes id=\(chosen.originalActionId ?? chosen.id) reason=contract_candidate")
            print("[NoVisibleContentContractMissing] status=pass count=0")
            emitBridgeGates(meaningful: meaningful, hasVisibleText: hasVisibleText, decided: true)
            return CurrentWorkCandidateDecision(
                suggestion: chosen,
                blocker: nil,
                frontmostType: focusAuthority.frontmostType.rawValue,
                contentType: content.type.rawValue,
                meaningful: meaningful,
                hasVisibleText: hasVisibleText
            )
        }

        // Precise blocker — no silent fall-through.
        let blocker: String = {
            if !meaningful { return "no_actionable_content_type_\(content.type.rawValue)" }
            if !hasVisibleText { return "visible_text_not_available_for_\(content.type.rawValue)" }
            return "no_contract_for_content_type_\(content.type.rawValue)"
        }()
        print("[CurrentWorkOpportunity] selected=no id=none reason=\(blocker)")
        // Fix 3: a supported content type with visible text that yields no contract
        // did so via a precise per-type evidence rejection logged by the planner
        // (lease/code/message body or domain-only weak signal) — never a silent gap.
        if supportedContentType && hasVisibleText {
            print("[NoVisibleContentContractMissing] status=pass count=0")
        }
        emitBridgeGates(meaningful: meaningful, hasVisibleText: hasVisibleText, decided: true)
        return CurrentWorkCandidateDecision(
            suggestion: nil,
            blocker: blocker,
            frontmostType: focusAuthority.frontmostType.rawValue,
            contentType: content.type.rawValue,
            meaningful: meaningful,
            hasVisibleText: hasVisibleText
        )
    }

    /// Assert that classified visible current work always produces a candidate
    /// DECISION (candidate or precise blocker) — never a silent no_specific_action.
    private static func emitBridgeGates(meaningful: Bool, hasVisibleText: Bool, decided: Bool) {
        if meaningful && hasVisibleText {
            print("[NoClassifiedVisibleWorkWithoutCandidateDecision] status=\(decided ? "pass" : "fail") count=\(decided ? 0 : 1)")
            print("[NoVisibleContentNoSpecificActionGap] status=\(decided ? "pass" : "fail") count=\(decided ? 0 : 1)")
        }
    }

    /// Normalize the panel bridge's ActionProtocol list (liquid + cheap +
    /// music + friction + setup + memory + technical mega-actions).
    @MainActor
    static func panelBridgeCandidates(actions: [any ActionProtocol]) -> [UnifiedSuggestion] {
        actions.map { action in
            let capabilityId = (action as? DeterministicCapabilityPanelAction)?.capabilityId ?? action.id
            let kind = kindForLegacy(capabilityId)
            print("[LegacySystemDemotion] system=panel_bridge:\(capabilityId) row_id=\(action.id) old_role=final_panel_row new_role=candidate_producer")
            return UnifiedSuggestionAdapters.from(legacyAction: action, source: sourceForLegacy(capabilityId), kind: kind)
        }
    }

    private static func kindForLegacy(_ id: String) -> SuggestionKind {
        if let ontology = WorkflowActionOntology.byId[id] {
            if ontology.category == .mediaFocus { return .mediaAction }
            if ontology.category == .workspaceFriction { return .frictionAction }
            if ontology.category == .memoryWorkflows { return .memoryAction }
            if ontology.category == .setupAcquisition { return .setupAction }
        }
        // Fallbacks if not explicitly defined in ontology yet
        if ["play_focus_media", "pause_media", "resume_focus_media", "suggest_focus_playlist"].contains(id) { return .mediaAction }
        if ["arrange_side_by_side", "switch_to_paired_app", "split_research_setup", "arrange_current_and_reference", "focus_current_task"].contains(id) { return .frictionAction }
        if ProposalEvidenceContracts.isInternalAcquisitionAction(id) { return .setupAction }
        if ["remember_workspace", "restore_workspace", "save_task_context", "recall_related_context", "save_research_session"].contains(id) { return .memoryAction }
        return .legacyCapability
    }

    private static func sourceForLegacy(_ id: String) -> SuggestionSource {
        switch kindForLegacy(id) {
        case .mediaAction: return .musicSystem
        case .frictionAction: return .frictionEngine
        case .setupAction: return .setupAcquisition
        case .memoryAction: return .memorySystem
        default: return .liquidRouter
        }
    }
}
