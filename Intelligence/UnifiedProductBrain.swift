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

enum UnifiedProductBrain {

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

        var pool = UnifiedCandidatePool()
        pool.addAll(panelBridgeSuggestions, from: "panel_bridge")
        pool.addAll(composedPlanSuggestions, from: "composed_planner")
        pool.addAll(floatingCandidates, from: "floating_lane")
        pool.addAll(followupSuggestions, from: "result_followups")

        for candidate in pool.candidates {
            print("[UnifiedCandidate] id=\(candidate.id) kind=\(candidate.kind.rawValue) source=\(candidate.source.rawValue) target=\(candidate.target.rawValue) title=\"\(candidate.title)\" evidence=\(candidate.evidenceLevel ?? "none")")
            focus.logUsage(suggestionId: candidate.id, source: candidate.source.rawValue)
        }

        func count(_ kinds: Set<SuggestionKind>) -> Int {
            pool.candidates.filter { kinds.contains($0.kind) }.count
        }
        print("[CandidateSourceCoverage] liquid=\(pool.sourceCounts[.liquidRouter] ?? 0) composed=\(pool.sourceCounts[.composedPlanner] ?? 0) hooks=\(count([.localSystemAction])) followups=\(pool.sourceCounts[.resultFollowup] ?? 0) friction=\(count([.frictionAction])) music=\(count([.mediaAction])) setup=\(count([.setupAction])) memory=\(count([.memoryAction])) technical=\(pool.candidates.filter { $0.debugMetadata?["technical"] == "yes" }.count)")

        // ── Floating policy (Part J): the brain picks at most one winner. ───
        // Cooldowns penalize individual candidates, never whole categories.
        var floatingWinner: UnifiedSuggestion? = nil
        let floatingEligible = pool.candidates
            .filter { $0.surfacePolicy.eligibleForFloating && !$0.surfacePolicy.hidden && !$0.surfacePolicy.debugOnly }
            .filter { candidate in
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
        for candidate in pool.candidates {
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
        let specific = pool.candidates.filter { $0.kind == .composedPlan || $0.kind == .legacyCapability }.count
        let generic = pool.candidates.filter { $0.id == "focus_current_task" }.count
        print("[PanelSpecificityCheck] specific=\(specific) generic=\(generic) passed=\(specific > 0 || generic <= 1 ? "yes" : "no")")

        let panelTotal = sections.values.map(\.count).reduce(0, +)
        let panelNotEmpty = panelTotal > 0 || pool.candidates.isEmpty
        print("[PanelNotEmptyCheck] context=\(focus.currentContentType ?? "unknown") passed=\(panelNotEmpty ? "yes" : "no") reason=\(panelTotal > 0 ? "sections_populated" : pool.candidates.isEmpty ? "no_candidates_exist" : "candidates_all_hidden")")

        let setupNeeded = pool.candidates.contains { $0.kind == .setupAction }
        let surface = UnifiedSurfaceDecision(floating: floatingWinner, panelSections: sections)

        print("[UnifiedProductBrain] tick=\(Int(Date().timeIntervalSince1970)) current=\(focus.selectedBrowserTabTitle ?? focus.activeWindowTitle ?? "unknown") inputs=\(pool.sourceCounts.count) candidates=\(pool.candidates.count) panel=\(panelTotal) floating=\(floatingWinner?.id ?? "none")")
        print("[UnifiedProductDecision] floating=\(floatingWinner?.id ?? "none") panel=\(panelTotal) hidden=\(hidden) setup_needed=\(setupNeeded ? "yes" : "no") reason=single_brain_arbitration")
        print("[ProductDecisionTrace] app=\(focus.activeApp ?? "unknown") selected_tab=\(focus.selectedBrowserTabTitle ?? "none") content_type=\(focus.currentContentType ?? "unknown") domain=\(focus.semanticDomain ?? "unknown") panel=\(sections.map { "\($0.key.rawValue):\($0.value.count)" }.sorted().joined(separator: ",")) floating=\(floatingWinner?.id ?? "none") hidden=\(hidden)")
        print("[SuggestionVisibilityRestore] context=\(focus.currentContentType ?? "unknown") panel=\(panelTotal) floating=\(floatingWinner?.id ?? "none") reason=all_sources_pooled")
        print("[UnifiedPanelRender] sections=\(sections.filter { !$0.value.isEmpty }.count) total=\(panelTotal) debug_mode=\(DebugMode.isEnabled ? "on" : "off")")

        return UnifiedProductDecision(
            focus: focus,
            surface: surface,
            hiddenCount: hidden,
            setupNeeded: setupNeeded,
            reason: "single_brain_arbitration"
        )
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

    // MARK: - Candidate builders

    /// Composed plans for the current context (Phase 62 planner) — this is
    /// what restores content/capture-first/technical suggestions.
    @MainActor
    static func composedPlanCandidates(signals: WorkflowSignals) -> [UnifiedSuggestion] {
        let content = ContentTypeClassifier.classify(signals)
        let cluster = ComparableCandidateDetector.detect(signals: signals, content: content)
        let evidence = EvidenceSnapshot.evaluate(signals: signals, content: content, cluster: cluster)
        let activity = BrowserActivityClassifier.classify(signals: signals, content: content, cluster: cluster)
        let plans = ComposedActionPlanner.plansFor(signals: signals, content: content, activity: activity, cluster: cluster, evidence: evidence)

        let technicalContext = content.type == .codeOrLog
        if technicalContext {
            print("[TechnicalContextDetected] app=\(signals.activeApp) source=content_type_classifier confidence=\(String(format: "%.2f", content.confidence))")
        }

        return plans.map { plan in
            let identity = ComposedActionUIRegistry.register(plan: plan, signals: signals, surface: "panel")
            let isCaptureFirst = plan.executionMode == .captureFirst
            if isCaptureFirst {
                print("[CaptureFirstSuggestion] original=\(plan.id) capture=\(plan.steps.first?.primitiveID ?? "none") followup=\(plan.steps.dropFirst().first?.primitiveID ?? "none") title=\"\(plan.userVisibleTitle)\"")
                print("[MissingContextToAction] missing=\(plan.missingInputs.joined(separator: ",")) suggestion=\(plan.id)")
                print("[CaptureFollowupRoute] capture=\(plan.steps.first?.primitiveID ?? "none") followup=\(plan.id) status=wired")
            }
            if technicalContext {
                print("[TechnicalCandidateAdded] id=\(identity.uiID) title=\"\(plan.userVisibleTitle)\" source=composed_planner")
            }
            return UnifiedSuggestion(
                id: identity.uiID,
                kind: .composedPlan,
                title: plan.userVisibleTitle,
                subtitle: plan.contextSummary,
                whyNow: plan.reason,
                source: .composedPlanner,
                target: .currentFocus,
                surfacePolicy: UnifiedSuggestionSurfacePolicy(
                    eligibleForFloating: plan.executionMode != .panelOnly,
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
                debugMetadata: technicalContext ? ["technical": "yes"] : nil,
                originalActionId: identity.uiID
            )
        }
    }

    /// Normalize the panel bridge's ActionProtocol list (liquid + cheap +
    /// music + friction + setup + memory + technical mega-actions).
    @MainActor
    static func panelBridgeCandidates(actions: [any ActionProtocol]) -> [UnifiedSuggestion] {
        actions.map { action in
            let kind = kindForLegacy(action.id)
            print("[LegacySystemDemotion] system=panel_bridge:\(action.id) old_role=final_panel_row new_role=candidate_producer")
            return UnifiedSuggestionAdapters.from(legacyAction: action, source: sourceForLegacy(action.id), kind: kind)
        }
    }

    private static func kindForLegacy(_ id: String) -> SuggestionKind {
        if ["play_focus_media", "pause_media", "resume_focus_media", "suggest_focus_playlist"].contains(id) { return .mediaAction }
        if ["arrange_side_by_side", "switch_to_paired_app", "split_research_setup", "arrange_current_and_reference", "focus_current_task"].contains(id) { return .frictionAction }
        if ["capture_visible_page", "capture_full_document", "enable_browser_bridge", "select_text_hint"].contains(id) { return .setupAction }
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
