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
            browserTabs: [],
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
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        if s1.primary.id != "create_review_plan" {
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
        if s2.primary.id != "generate_quiz" {
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
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        if s3.primary.id != "diagnose_error" {
             print("[CapabilitySelectorSelfTest] fail: expected diagnose_error for debugging")
             return false
        }
        
        // 4. Auxiliary media offer
        if s1.auxiliary?.id != "play_focus_media" {
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
        let executor = CapabilityExecutor.shared
        let registry = CognitiveCapabilityRegistry.shared
        
        // 1. Copy to clipboard
        let copyCap = registry.get("copy_result_to_clipboard")!
        let status1 = await executor.execute(capability: copyCap, context: ["text": "Hello Phase 21"])
        if status1 != .success {
            print("[CapabilityExecutionSelfTest] fail: copy_result_to_clipboard failed")
            return false
        }
        
        // 2. Play media (might return unavailable if Music not configured, but should not crash)
        let playCap = registry.get("play_focus_media")!
        let status2 = await executor.execute(capability: playCap, context: [:])
        print("[CapabilityExecutionSelfTest] play_focus_media status=\(status2.rawValue)")
        
        // 3. Preview only
        let previewCap = registry.get("summarize_context")!
        let status3 = await executor.execute(capability: previewCap, context: [:])
        if status3 != .success {
             print("[CapabilityExecutionSelfTest] fail: preview_only capability should return success")
             return false
        }
        
        print("[CapabilityExecutionSelfTest] completed ok=true")
        return true
    }
}
