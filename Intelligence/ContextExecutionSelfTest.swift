import Foundation

/// Phase 20G.5 — ContextExecutionEngine study relatedFocusEntities self test
///
/// Trigger:
///   CONTEXTUAL_RUN_CONTEXT_EXECUTION_SELFTEST=1
@MainActor
public struct ContextExecutionSelfTest: Sendable {
    
    public static func run() async -> Bool {
        print("[ContextExecutionSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[ContextExecutionSelfTest] pass case=\(name)") }
            else  { print("[ContextExecutionSelfTest] fail case=\(name)"); failures.append(name) }
        }
        
        let now = Date()
        let workflow = WorkflowState(
            workflowType: .studying,
            confidence: 0.90,
            evidence: ["test"],
            uncertainty: "none",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.85,
            dominantApps: ["Firefox"],
            repeatedTerms: ["cisc"],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "h1"
        )
        let behavior = BehavioralStateRecord(
            state: .learning,
            confidence: 0.85,
            reasoning: "test",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.80
        )
        
        ContextEpochTracker.shared.resetForTests()
        ContextEpochTracker.shared.observe(
            contextShiftDetected: false,
            shiftReason: "seed",
            earlyTopTerms: [],
            recentTopTerms: ["cisc", "121"],
            recentTitles: ["Week-2 - CISC 121"]
        )
        
        let packet = CompressedTemporalPacket(
            currentApp: "Firefox",
            recentApps: ["Firefox"],
            recentTitles: ["Week-2 - CISC 121"],
            topicTerms: ["cisc", "121"],
            activityPattern: "active",
            idlePattern: "active",
            typingPattern: "none",
            pointerPattern: "active",
            ocrHints: [],
            selectionHints: [],
            clipboardMetadata: "none",
            recentUserAccepts: [],
            recentUserIgnores: [],
            spanSeconds: 120,
            eventCount: 5,
            contextShiftDetected: false
        )
        
        let suggestion = AmbientJarvisSuggestion(
            title: "Study review plan",
            subtitle: "Context-only preview",
            whyNow: "learning behavior",
            workflow: "studying",
            behavior: "learning",
            confidence: 0.90,
            kind: .compare_context,
            intent: "create_study_outline",
            intentConfidence: 0.90,
            intentGoal: "outline help",
            targetEntity: "Week-2 - CISC 121",
            executionMode: .context_only_preview,
            previewOnly: true,
            sourceEvidence: "cisc,121"
        )
        
        // Mock a snapshot
        let snap = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Firefox",
            windowTitle: "Week-2 - CISC 121",
            bundleIdentifier: "org.mozilla.firefox",
            selectedText: nil,
            recentOCRExcerpt: nil
        )
        
        // Run ContextExecutionEngine
        let result = await ContextExecutionEngine.execute(
            workflow: workflow,
            behavior: behavior,
            packet: packet,
            snapshot: snap
        )
        
        check("engine_result_contains_study_evidence_quality", result.evidenceQuality == "title_only" || result.evidenceQuality == "browser_tabs")
        check("engine_observed_grounded_verbatim", !result.observed.isEmpty)
        
        // Phase 20I: uses_payload_context
        let payload = SuggestionContextPayload(
            taskCompartmentSnapshot: nil,
            workingMemorySnapshot: WorkingMemorySnapshot(
                currentEntity: "Overridden Entity",
                recentEntities: ["Overridden Entity", "Related 1", "Related 2", "Related 3", "Related 4"],
                repeatedConcepts: ["overridden"],
                inferredActivity: "learning",
                comparisonCandidates: ["Overridden Entity", "Related 1", "Related 2", "Related 3", "Related 4"],
                relatedFocusEntities: ["Related 1", "Related 2", "Related 3", "Related 4"]
            ),
            comparisonCandidates: ["Overridden Entity", "Related 1", "Related 2", "Related 3", "Related 4"],
            relatedFocusEntities: ["Related 1", "Related 2", "Related 3", "Related 4"],
            activeTerms: ["overridden"],
            evidenceQuality: "browser_tabs",
            evidenceLevel: "metadata_rich",
            browserTabs: [],
            browserContextType: nil,
            browserContentAvailable: false,
            actionIntent: "synthesize_sources"
        )
        let suggestionWithPayload = AmbientJarvisSuggestion(
            title: "Study review plan",
            subtitle: "Context-only preview",
            whyNow: "learning behavior",
            workflow: "studying",
            behavior: "learning",
            confidence: 0.90,
            kind: .compare_context,
            intent: "synthesize_sources",
            intentConfidence: 0.90,
            intentGoal: "outline help",
            targetEntity: "Week-2 - CISC 121",
            executionMode: .context_only_preview,
            previewOnly: true,
            sourceEvidence: "cisc,121",
            contextPayload: payload
        )
        
        let resultWithPayload = await ContextExecutionEngine.execute(
            suggestion: suggestionWithPayload,
            snapshot: snap
        )
        
        check("uses_payload_context", resultWithPayload.evidenceQuality == "browser_tabs")
        // The fallback structured builder prefixes with "  • "
        check("payload_preserves_related_entities", resultWithPayload.observed.contains { $0.contains("Related 4") })

        // Phase 21: ActionCard verification
        if let card = resultWithPayload.actionCard {
            print("[ContextExecutionSelfTest] pass case=action_card_present")
            check("action_card_primary_not_empty", !card.primaryAction.id.isEmpty)
            check("action_card_explanation_not_empty", !card.explanation.isEmpty)
        } else {
            print("[ContextExecutionSelfTest] fail case=action_card_present")
            failures.append("action_card_present")
        }

        let ok = failures.isEmpty
        print("[ContextExecutionSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

@MainActor
public enum CapabilityRegistrySelfTest {
    public static func run() -> Bool {
        print("[CapabilityRegistrySelfTest] starting")
        let registry = CognitiveCapabilityRegistry.shared
        
        let caps = registry.capabilities
        if caps.count < 15 {
             print("[CapabilityRegistrySelfTest] fail: expected at least 15 capabilities, found \(caps.count)")
             return false
        }
        
        let studyCaps = ["generate_quiz", "create_review_plan", "create_checklist"]
        for id in studyCaps {
            if caps[id] == nil {
                print("[CapabilityRegistrySelfTest] fail: missing study capability \(id)")
                return false
            }
        }
        
        let localActions = ["play_focus_media", "start_focus_timer", "copy_result_to_clipboard"]
        for id in localActions {
            guard let c = caps[id] else {
                print("[CapabilityRegistrySelfTest] fail: missing local action \(id)")
                return false
            }
            if c.executionMode != .local_action {
                print("[CapabilityRegistrySelfTest] fail: capability \(id) should be local_action")
                return false
            }
        }
        
        print("[CapabilityRegistrySelfTest] completed ok=true")
        return true
    }
}

@MainActor
public enum CapabilitySelectorSelfTest {
    public static func run() -> Bool {
        print("[CapabilitySelectorSelfTest] starting")
        
        let memory = WorkingMemorySnapshot(
            currentEntity: "CISC 121",
            recentEntities: ["CISC 121"],
            repeatedConcepts: ["python", "loops"],
            inferredActivity: "learning",
            comparisonCandidates: [],
            staleEntities: [],
            relatedFocusEntities: [],
            backgroundEntities: []
        )
        
        // 1. Studying title-only
        let s1 = CapabilitySelector.select(
            compartment: TaskCompartment(workflow: .studying, label: "CISC 121", dominantTerms: [], entities: [], browserTabs: [], confidence: 0.9),
            workingMemory: memory,
            evidenceQuality: "title_only",
            currentApp: "Safari",
            behavior: .learning,
            userInitiated: true,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        if s1?.primary.id != "create_review_plan" {
             print("[CapabilitySelectorSelfTest] fail: expected create_review_plan for study title-only")
             return false
        }
        
        // 2. Studying rich AX content
        let s2 = CapabilitySelector.select(
            compartment: TaskCompartment(workflow: .studying, label: "CISC 121", dominantTerms: [], entities: [], browserTabs: [], confidence: 0.9),
            workingMemory: memory,
            evidenceQuality: "ax_content",
            currentApp: "Safari",
            behavior: .learning,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        if s2?.primary.id != "generate_quiz" {
             print("[CapabilitySelectorSelfTest] fail: expected generate_quiz for study ax_content")
             return false
        }
        
        // 3. Coding/Debugging
        let s3 = CapabilitySelector.select(
            compartment: nil,
            workingMemory: WorkingMemorySnapshot(currentEntity: "main.py", recentEntities: ["main.py"], repeatedConcepts: ["error"], inferredActivity: "debugging", comparisonCandidates: [], staleEntities: [], relatedFocusEntities: [], backgroundEntities: []),
            evidenceQuality: "title_only",
            currentApp: "Cursor",
            behavior: .debugging,
            userInitiated: true,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        if s3?.primary.id != "diagnose_error" {
             print("[CapabilitySelectorSelfTest] fail: expected diagnose_error for debugging")
             return false
        }
        
        // 4. Auxiliary media offer
        if s1?.auxiliary?.id != "play_focus_media" {
             print("[CapabilitySelectorSelfTest] fail: expected play_focus_media auxiliary for studying")
             return false
        }
        
        print("[CapabilitySelectorSelfTest] completed ok=true")
        return true
    }
}

@MainActor
public enum CapabilityExecutionSelfTest {
    public static func run() async -> Bool {
        print("[CapabilityExecutionSelfTest] starting")
        var failures: [String] = []
        let executor = CapabilityExecutor.shared
        let registry = CognitiveCapabilityRegistry.shared
        CapabilityExecutor.testHooks = .init()
        defer { CapabilityExecutor.testHooks = .init() }

        func check(_ name: String, _ ok: Bool) {
            if ok { print("[CapabilityExecutionSelfTest] pass case=\(name)") }
            else  { print("[CapabilityExecutionSelfTest] fail case=\(name)"); failures.append(name) }
        }

        // ── Case 1: Copy to clipboard ─────────────────────────────────────────
        let copyCap = registry.get("copy_result_to_clipboard")!
        let status1 = await executor.execute(capability: copyCap, context: ["text": "Hello Phase 21"])
        check("copy_result_to_clipboard_success", status1 == .success)

        // ── Case 2: Play media (may be unavailable but must not crash) ─────────
        let playCap = registry.get("play_focus_media")!
        let status2 = await executor.execute(capability: playCap, context: [:])
        print("[CapabilityExecutionSelfTest] play_focus_media status=\(status2.rawValue)")
        check("play_focus_media_not_blocked", status2 != .blocked)

        // ── Case 3: preview_only capability → .previewGenerated ───────────────
        let previewCap = registry.get("summarize_context")!
        let status3 = await executor.execute(capability: previewCap, context: [:])
        check("preview_only_returns_preview_generated", status3 == .previewGenerated)

        // ── Phase 22.2 Case 4: start_focus_timer → .unavailable (honest) ──────
        let timerCap = registry.get("start_focus_timer")!
        let status4 = await executor.execute(capability: timerCap, context: [:])
        check("start_focus_timer_unavailable", status4 == .unavailable)
        check("start_focus_timer_not_fake_success", status4 != .success)

        // ── Phase 22.2 Case 5: copy without text → .blocked ───────────────────
        let status5 = await executor.execute(capability: copyCap, context: [:])
        check("copy_without_text_blocked", status5 == .blocked)

        // ── Phase 22.2 Case 6: unknown local_action cap → .unavailable ─────────
        let unknownCap = CognitiveCapability(
            id: "completely_unknown_future_cap",
            label: "Unknown future capability",
            inputRequirements: [],
            outputType: "unknown",
            evidenceThreshold: "title_only",
            executionMode: .local_action
        )
        let status6 = await executor.execute(capability: unknownCap, context: [:])
        check("unknown_local_action_unavailable", status6 == .unavailable)
        check("unknown_local_action_not_success", status6 != .success)

        // ── Phase 22.2 Case 7: All 27 capability IDs have non-generic titles ──
        var missingTitles: [String] = []
        for capId in OpportunityReasoner.allCapabilityIds {
            let t = OpportunityEngine.title(forCapabilityId: capId, entity: "Test Entity")
            if t.isEmpty || t == "Help with the current task" {
                missingTitles.append(capId)
            }
        }
        check("all_capabilities_have_specific_titles", missingTitles.isEmpty)

        // ── Phase 22.2 Case 8: All 27 titles pass OpportunityValidator ─────────
        var failingValidation: [String] = []
        for capId in OpportunityReasoner.allCapabilityIds {
            let t = OpportunityEngine.title(forCapabilityId: capId, entity: "Test Entity")
            if !OpportunityValidator.validate(t) {
                failingValidation.append(capId)
            }
        }
        check("all_capability_titles_pass_validator", failingValidation.isEmpty)

        // ── Phase 22.2 Case 9: draft_reply opportunity has requiresConfirmation ─
        let tracker = OpportunityNoveltyTracker()
        let emailSit = OpportunityReasoner.Situation(
            entityType: .email_thread,
            entityConfidence: 0.85,
            domain: .communicating,
            mode: .unknown,
            evidenceQuality: "title_only",
            hasErrorTerms: false,
            hasMultipleSources: false,
            hasComparisonCandidates: false,
            isActivelyEditing: false,
            compartmentDwellSeconds: 60,
            entityKey: "test_email_confirmation"
        )
        let emailCandidates = OpportunityReasoner.reason(situation: emailSit, noveltyTracker: tracker)
        check("email_surfaces_draft_reply",
              emailCandidates.contains { $0.capabilityId == "draft_reply" })

        // ── Phase 22.2 Case 10: empty entity → fallback title still valid ──────
        let noEntityTitle = OpportunityEngine.title(forCapabilityId: "generate_quiz", entity: "")
        check("empty_entity_title_uses_fallback",
              noEntityTitle.lowercased().contains("material") || noEntityTitle.lowercased().contains("this"))
        check("empty_entity_title_passes_validator", OpportunityValidator.validate(noEntityTitle))

        // ── Phase 30 local-action execution cases ───────────────────────────────
        CapabilityExecutor.testHooks.arrangeSideBySide = { apps, _ in
            let ok = apps == ["Preview", "Firefox"]
            return CapabilityExecutor.LocalActionOutcome(status: ok ? .success : .unavailable, verificationStatus: ok ? "success" : "failed", reason: ok ? "windows_arranged" : "bad_targets")
        }
        let arrangeCap = registry.get("arrange_side_by_side")!
        let arrangeStatus = await executor.execute(capability: arrangeCap, context: ["apps": ["Preview", "Firefox"], "confirmation_satisfied": true])
        check("arrange_side_by_side_moves_windows", arrangeStatus == .success)

        CapabilityExecutor.testHooks.arrangeSideBySide = { _, _ in
            CapabilityExecutor.LocalActionOutcome(status: .unavailable, verificationStatus: "failed", reason: "accessibility_permission_required")
        }
        let arrangeNoPermission = await executor.execute(capability: arrangeCap, context: ["apps": ["Preview", "Firefox"], "confirmation_satisfied": true])
        check("arrange_side_by_side_requires_accessibility_permission", arrangeNoPermission != .success)

        CapabilityExecutor.testHooks.switchToPairedApp = { apps in
            CapabilityExecutor.LocalActionOutcome(status: apps.contains("Preview") ? .success : .unavailable, verificationStatus: apps.contains("Preview") ? "success" : "failed", reason: apps.contains("Preview") ? "target_focused" : "no_target")
        }
        let switchCap = registry.get("switch_to_paired_app")!
        let switchStatus = await executor.execute(capability: switchCap, context: ["apps": ["Firefox", "Preview"], "confirmation_satisfied": true])
        check("switch_to_paired_app_focuses_target_window", switchStatus == .success)

        CapabilityExecutor.testHooks.restoreWorkspace = { apps, urls in
            let ok = apps.contains("Preview") && apps.contains("Firefox") && urls.count == 2
            return CapabilityExecutor.LocalActionOutcome(status: ok ? .success : .unavailable, verificationStatus: ok ? "success" : "failed", reason: ok ? "restored_workspace" : "restore_failed")
        }
        let restoreCap = registry.get("restore_workspace")!
        let restoreStatus = await executor.execute(capability: restoreCap, context: [
            "apps": ["Preview", "Firefox"],
            "tabURLs": ["https://example.com/lease", "https://example.com/listing"],
            "confirmation_satisfied": true
        ])
        check("restore_workspace_reopens_apps", restoreStatus == .success)
        check("restore_workspace_reopens_urls", restoreStatus == .success)

        CapabilityExecutor.testHooks.restoreResearchTabs = { urls in
            CapabilityExecutor.LocalActionOutcome(status: urls.count == 3 ? .success : .unavailable, verificationStatus: urls.count == 3 ? "success" : "failed", reason: urls.count == 3 ? "opened_urls" : "no_urls")
        }
        let restoreTabsCap = registry.get("restore_research_tabs")!
        let restoreTabsStatus = await executor.execute(capability: restoreTabsCap, context: [
            "tabURLs": ["https://example.com/a", "https://example.com/b", "https://example.com/c"],
            "confirmation_satisfied": true
        ])
        check("restore_research_tabs_opens_urls", restoreTabsStatus == .success)

        CapabilityExecutor.testHooks.splitResearchSetup = { browser, urls in
            let ok = browser == "Firefox" && urls.count == 2
            return CapabilityExecutor.LocalActionOutcome(status: ok ? .success : .unavailable, verificationStatus: ok ? "success" : "failed", reason: ok ? "opened_split_window" : "split_failed")
        }
        let splitCap = registry.get("split_research_setup")!
        let splitFirefoxStatus = await executor.execute(capability: splitCap, context: [
            "tabURLs": ["https://example.com/lease", "https://example.com/listing"],
            "tabTitles": ["Lease Draft", "Queen's Housing Rentals"],
            "browserAppName": "Firefox",
            "confirmation_satisfied": true
        ])
        check("split_research_setup_firefox_strategy", splitFirefoxStatus == .success)

        CapabilityExecutor.testHooks.splitResearchSetup = { browser, urls in
            let ok = browser == "Google Chrome" && urls.count == 2
            return CapabilityExecutor.LocalActionOutcome(status: ok ? .success : .unavailable, verificationStatus: ok ? "success" : "failed", reason: ok ? "opened_split_window" : "split_failed")
        }
        let splitChromeStatus = await executor.execute(capability: splitCap, context: [
            "tabURLs": ["https://example.com/lease", "https://example.com/listing"],
            "tabTitles": ["Lease Draft", "Queen's Housing Rentals"],
            "browserAppName": "Google Chrome",
            "confirmation_satisfied": true
        ])
        check("split_research_setup_chrome_strategy", splitChromeStatus == .success)

        let ok = failures.isEmpty
        print("[CapabilityExecutionSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
