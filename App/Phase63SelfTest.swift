import Foundation

@MainActor
struct Phase63SelfTest {
    private struct CaseRunner {
        var passed = 0
        var failed = 0

        mutating func check(_ name: String, _ condition: Bool, detail: String) {
            if condition {
                passed += 1
                print("[Phase63SelfTestCase] name=\(name) status=pass detail=\(detail)")
            } else {
                failed += 1
                print("[Phase63SelfTestCase] name=\(name) status=fail detail=\(detail)")
            }
        }
    }

    static func run() async -> Bool {
        print("[Phase63SelfTest] starting")
        var t = CaseRunner()

        testMusicAdapter(&t)
        testLiquidAdapter(&t)
        testComposedPlanAdapter(&t)
        testSetupAdapter(&t)
        testFrictionAdapter(&t)
        testFollowupAdapter(&t)
        testMixedArbiter(&t)
        testFloatingPath(&t)
        testCurrentFocusFixture(&t)
        testDebugMode(&t)
        testLegacyCompatibility(&t)

        let total = t.passed + t.failed
        let ok = t.failed == 0
        print("[Phase63SelfTest] status=\(ok ? "pass" : "fail") cases=\(total) passed=\(t.passed) failed=\(t.failed)")
        return ok
    }

    private static func testMusicAdapter(_ t: inout CaseRunner) {
        let s = UnifiedSuggestionAdapters.from(
            capabilityId: "play_focus_media",
            title: "Play focus music",
            source: .cheapPortfolio,
            confidence: 0.72,
            floatingEligible: true
        )
        t.check("music_adapter_kind", s.kind == .mediaAction || s.kind == .localSystemAction, detail: "kind=\(s.kind.rawValue)")
        t.check("music_adapter_source", s.source == .musicSystem || s.source == .cheapPortfolio, detail: "source=\(s.source.rawValue)")
        t.check("music_adapter_target", s.target == .backgroundWorkspace || s.target == .system, detail: "target=\(s.target.rawValue)")
        t.check("music_adapter_surface", s.surfacePolicy.eligibleForFloating && !s.surfacePolicy.panelOnly, detail: "floating=\(s.surfacePolicy.eligibleForFloating)")
        t.check("music_adapter_execution", s.executionPath == .localSystemExecutor, detail: "path=\(s.executionPath.rawValue)")
    }

    private static func testLiquidAdapter(_ t: inout CaseRunner) {
        let proposal = ActionProposal(
            title: "Extract key claims",
            sourceCaption: "Technical Minecraft",
            primaryActionId: "extract_key_claims",
            secondaryActionIds: [],
            confidence: 0.82,
            reason: "liquid_router"
        )
        let s = UnifiedSuggestionAdapters.from(liquidProposal: proposal, isFloatingEligible: true)
        let focus = focusFixture()
        let decision = UnifiedSurfaceArbiter.arbitrate(candidates: [s], focus: focus)
        t.check("liquid_adapter_exists", s.originalActionId == "extract_key_claims", detail: "original=\(s.originalActionId ?? "nil")")
        t.check("liquid_adapter_source", s.source == .liquidRouter, detail: "source=\(s.source.rawValue)")
        t.check("liquid_adapter_target", s.target == .currentFocus, detail: "target=\(s.target.rawValue)")
        t.check("liquid_panel_current_task", decision.panelSections[.currentTask]?.contains(s) == true, detail: "current_task_count=\(decision.panelSections[.currentTask]?.count ?? 0)")
    }

    private static func testComposedPlanAdapter(_ t: inout CaseRunner) {
        let s = UnifiedSuggestionAdapters.from(
            composedPlanTitle: "Summarize advice from this thread",
            planId: "composed_action:thread_summary",
            confidence: 0.91,
            isFloatingEligible: true
        )
        t.check("composed_adapter_kind", s.kind == .composedPlan, detail: "kind=\(s.kind.rawValue)")
        t.check("composed_adapter_execution", s.executionPath == .composedExecutor, detail: "path=\(s.executionPath.rawValue)")
        t.check("composed_adapter_title_human", !s.title.contains("_") && s.title.contains("Summarize"), detail: "title=\(s.title)")
    }

    private static func testSetupAdapter(_ t: inout CaseRunner) {
        for id in ["capture_visible_page", "enable_browser_bridge", "select_text_hint"] {
            let s = UnifiedSuggestionAdapters.from(
                capabilityId: id,
                title: id.replacingOccurrences(of: "_", with: " "),
                source: .liquidRouter,
                confidence: 0.66,
                floatingEligible: false
            )
            let acceptOK = s.acceptBehavior == .captureFirst || s.acceptBehavior == .setupFirst
            t.check("setup_adapter_\(id)", s.kind == .setupAction && acceptOK && s.source == .setupAcquisition, detail: "kind=\(s.kind.rawValue) accept=\(s.acceptBehavior.rawValue)")
        }
    }

    private static func testFrictionAdapter(_ t: inout CaseRunner) {
        let s = UnifiedSuggestionAdapters.from(
            capabilityId: "arrange_side_by_side",
            title: "Put current page beside reference",
            source: .cheapPortfolio,
            confidence: 0.78,
            floatingEligible: true
        )
        t.check("friction_adapter_kind", s.kind == .frictionAction, detail: "kind=\(s.kind.rawValue)")
        t.check("friction_adapter_surface", s.surfacePolicy.eligibleForFloating && s.target == .backgroundWorkspace, detail: "target=\(s.target.rawValue)")
    }

    private static func testFollowupAdapter(_ t: inout CaseRunner) {
        let s = UnifiedSuggestionAdapters.from(
            capabilityId: "followup:copy_summary",
            title: "Copy summary",
            source: .resultFollowup,
            confidence: 1.0,
            floatingEligible: false
        )
        t.check("followup_adapter_kind", s.kind == .followupAction, detail: "kind=\(s.kind.rawValue)")
        t.check("followup_adapter_execution", s.executionPath == .followupExecutor, detail: "path=\(s.executionPath.rawValue)")
    }

    private static func testMixedArbiter(_ t: inout CaseRunner) {
        let media = UnifiedSuggestionAdapters.from(capabilityId: "play_focus_media", title: "Play focus music", source: .cheapPortfolio, confidence: 0.62, floatingEligible: true)
        let liquid = UnifiedSuggestionAdapters.from(liquidProposal: ActionProposal(title: "Extract key claims", sourceCaption: "", primaryActionId: "extract_key_claims", secondaryActionIds: [], confidence: 0.77, reason: "liquid"), isFloatingEligible: true)
        let composed = UnifiedSuggestionAdapters.from(composedPlanTitle: "Summarize advice from this thread", planId: "composed_action:thread_summary", confidence: 0.90, isFloatingEligible: true)
        let setup = UnifiedSuggestionAdapters.from(capabilityId: "capture_visible_page", title: "Capture visible page", source: .setupAcquisition, confidence: 0.55, floatingEligible: false)
        let candidates = [media, liquid, composed, setup]
        let decision = UnifiedSurfaceArbiter.arbitrate(candidates: candidates, focus: focusFixture())
        let panelCount = decision.panelSections.values.reduce(0) { $0 + $1.count }
        t.check("arbiter_one_floating", decision.floating?.id == composed.id, detail: "floating=\(decision.floating?.id ?? "none")")
        t.check("arbiter_all_panel_sectioned", panelCount == candidates.count, detail: "panel_count=\(panelCount)")
    }

    private static func testFloatingPath(_ t: inout CaseRunner) {
        let appState = AppState()
        let s = UnifiedSuggestionAdapters.from(liquidProposal: ActionProposal(title: "Extract key claims", sourceCaption: "", primaryActionId: "extract_key_claims", secondaryActionIds: [], confidence: 0.83, reason: "floating_path"), isFloatingEligible: true)
        appState.showUnifiedFloatingSuggestion(s)
        t.check("floating_path_appstate_unified", appState.unifiedSurfaceDecision?.floating?.id == "extract_key_claims", detail: "floating=\(appState.unifiedSurfaceDecision?.floating?.id ?? "none")")
        t.check("floating_path_visible", appState.isFloatingSuggestionVisible, detail: "visible=\(appState.isFloatingSuggestionVisible)")
        appState.dismissFloatingSuggestion(reason: .manual)
        t.check("floating_path_dismiss_clears_unified", appState.unifiedSurfaceDecision == nil && !appState.isFloatingSuggestionVisible, detail: "visible=\(appState.isFloatingSuggestionVisible)")
    }

    private static func testCurrentFocusFixture(_ t: inout CaseRunner) {
        let focus = focusFixture()
        focus.logUsage(suggestionId: "extract_key_claims", source: "liquid_router")
        let hasListingBackground = focus.backgroundEntities.contains { $0.type == "listing" }
        let currentIsListing = focus.currentContentType == "listing" || focus.semanticDomain == "rental"
        t.check("focus_selected_tab", focus.selectedBrowserTabTitle == "Technical Minecraft", detail: "selected=\(focus.selectedBrowserTabTitle ?? "none")")
        t.check("focus_selected_url", focus.selectedBrowserTabURL?.contains("reddit.com/r/technicalminecraft") == true, detail: "url=\(focus.selectedBrowserTabURL ?? "none")")
        t.check("focus_content_type", focus.currentContentType == "reddit/forum" || focus.currentContentType == "forum_or_social_group", detail: "content_type=\(focus.currentContentType ?? "none")")
        t.check("focus_background_listing", hasListingBackground && !currentIsListing, detail: "background_listing=\(hasListingBackground) current_listing=\(currentIsListing)")
    }

    private static func testDebugMode(_ t: inout CaseRunner) {
        let old = UserDefaults.standard.object(forKey: "contextual_debug_mode_enabled")
        UserDefaults.standard.removeObject(forKey: "contextual_debug_mode_enabled")
        DebugMode.initialize()
        t.check("debug_default_off", DebugMode.isEnabled == false, detail: "enabled=\(DebugMode.isEnabled)")
        DebugMode.isEnabled = true
        t.check("debug_persist_on", DebugMode.isEnabled == true, detail: "enabled=\(DebugMode.isEnabled)")
        DebugMode.logUIVisibility(component: "Phase63SelfTestDebugPanel", visible: DebugMode.isEnabled)
        DebugMode.isEnabled = false
        t.check("debug_suppresses_noisy_logs", DebugMode.shouldSuppressNoisyLogs, detail: "suppress=\(DebugMode.shouldSuppressNoisyLogs)")
        if let oldBool = old as? Bool {
            DebugMode.isEnabled = oldBool
        } else {
            UserDefaults.standard.removeObject(forKey: "contextual_debug_mode_enabled")
        }
    }

    private static func testLegacyCompatibility(_ t: inout CaseRunner) {
        let legacy = UnifiedSuggestionAdapters.from(liquidProposal: ActionProposal(title: "Open task panel", sourceCaption: "", primaryActionId: "open_current_task_panel", secondaryActionIds: [], confidence: 0.70, reason: "legacy"), isFloatingEligible: false)
        let composed = UnifiedSuggestionAdapters.from(composedPlanTitle: "Summarize advice from this thread", planId: "composed_action:thread_summary", confidence: 0.90, isFloatingEligible: true)
        let music = UnifiedSuggestionAdapters.from(capabilityId: "play_focus_media", title: "Play focus music", source: .cheapPortfolio, confidence: 0.7, floatingEligible: true)
        t.check("legacy_wrapper_executes", legacy.originalActionId == "open_current_task_panel" && legacy.executionPath == .capabilityExecutor, detail: "path=\(legacy.executionPath.rawValue)")
        t.check("composed_wrapper_executes", composed.originalActionId == composed.id && composed.executionPath == .composedExecutor, detail: "path=\(composed.executionPath.rawValue)")
        t.check("music_wrapper_executes", music.originalActionId == "play_focus_media" && music.executionPath == .localSystemExecutor, detail: "path=\(music.executionPath.rawValue)")
    }

    private static func focusFixture() -> CurrentFocusSummary {
        CurrentFocusSummary(
            activeApp: "Firefox",
            activeWindowTitle: "Technical Minecraft",
            selectedBrowserTabTitle: "Technical Minecraft",
            selectedBrowserTabURL: "https://www.reddit.com/r/technicalminecraft/",
            browserTabListSummary: [
                "Technical Minecraft",
                "182 Montreal St - OCCUPANCY AGREEMENT - Google Docs",
                "My Messages | Kijiji",
                "Facebook",
                "Contacts | Accommodation Listing Service"
            ],
            currentContentType: "reddit/forum",
            semanticDomain: "forum_or_social_group",
            activity: "reading_forum",
            evidenceLevel: "selected_browser_tab",
            availableContentSources: ContentSourceAvailability(
                metadata: true,
                url: true,
                axText: false,
                ocr: false,
                selectedText: false,
                clipboard: false,
                browserBridge: true
            ),
            missingContentSources: ["axText", "ocr", "selectedText"],
            relatedFocusEntities: [
                FocusEntity(id: "reddit_technicalminecraft", name: "Technical Minecraft", type: "forum", relevanceScore: 1.0)
            ],
            backgroundEntities: [
                FocusEntity(id: "lease_doc", name: "182 Montreal St - OCCUPANCY AGREEMENT", type: "listing", relevanceScore: 0.35),
                FocusEntity(id: "kijiji_messages", name: "My Messages | Kijiji", type: "listing", relevanceScore: 0.30),
                FocusEntity(id: "accommodation_service", name: "Contacts | Accommodation Listing Service", type: "listing", relevanceScore: 0.25)
            ],
            staleEntities: [
                FocusEntity(id: "facebook", name: "Facebook", type: "social", relevanceScore: 0.10)
            ],
            debugSourceTrace: [
                "browser_tabs.selected",
                "browser_url.selected",
                "background_tabs.demoted"
            ]
        )
    }
}
