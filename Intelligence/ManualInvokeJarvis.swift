import AppKit
import Foundation

/// Phase 20F — manual "invoke assistant" routes through the same Ambient
/// Jarvis pipeline as passive ambient suggestions, but with two key
/// differences:
///   1. Confidence + context-sufficiency gates are bypassed (the user is
///      explicitly asking *now*, so a stable workflow guess is enough).
///   2. The visual-descriptor / Moondream / `analyze_screen` path is used
///      ONLY when there is no usable browser/AX/title/selection context.
///
/// **No AgenticPlan. No HookCompositionPipeline. No DirectAgentLoop. No
/// browser control.** This is still bounded context intelligence.
enum ManualInvokeJarvis {

    /// Outcome the test surface can assert on, separate from the side-effect
    /// of publishing to AppState.
    struct Result: Sendable, Equatable {
        let workflow: String
        let behavior: String
        let intent: String
        let evidenceQuality: String
        let usedVisualFallback: Bool
        let visualFallbackReason: String
        let suggestionProduced: Bool
        let suggestionId: String?

        init(workflow: String, behavior: String, intent: String, evidenceQuality: String, usedVisualFallback: Bool, visualFallbackReason: String, suggestionProduced: Bool, suggestionId: String?) {
            self.workflow = workflow; self.behavior = behavior; self.intent = intent
            self.evidenceQuality = evidenceQuality
            self.usedVisualFallback = usedVisualFallback
            self.visualFallbackReason = visualFallbackReason
            self.suggestionProduced = suggestionProduced
            self.suggestionId = suggestionId
        }
    }

    // MARK: - Production entry point

    /// Called from AppDelegate's manual-trigger handler.
    @MainActor
    static func invoke(
        source: String,
        producer: ContextEventProducer,
        coordinator: WorkflowIntelligenceCoordinator,
        behavioral: BehavioralIntelligenceCoordinator,
        currentSnapshot: CanonicalGeneratedExecutionContextSnapshot?,
        publishSuggestion: @MainActor @Sendable (AmbientJarvisSuggestion?) -> Void
    ) async -> Result {
        print("[ManualInvokeJarvis] started source=\(source)")

        // Step 1: capture fresh frontmost app + title.
        print("[ManualInvokeJarvis] context_refresh_started")
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? (currentSnapshot?.activeApp ?? "Unknown")
        let bundleID = frontApp?.bundleIdentifier ?? currentSnapshot?.bundleIdentifier
        let pid = frontApp?.processIdentifier

        // Step 2: best-effort browser/AX context.
        let browser = BrowserContextExtractor.extract(appName: appName, activeAppPID: pid)
        let browserURL = browser?.currentURL
        let tabTitles = browser?.recentTabTitles ?? []

        // Step 3: derive a window title preferring fresh selectedTitle from AX
        let windowTitle: String = {
            if let t = browser?.selectedTitle, !t.isEmpty { return t }
            if let t = currentSnapshot?.windowTitle, !t.isEmpty { return t }
            return browser?.recentTabTitles.first ?? ""
        }()
        let selectedText = currentSnapshot?.selectedText ?? ""
        let hasSelection = !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBrowserContext = browserURL != nil || !tabTitles.isEmpty
        let hasAnyTitle = !windowTitle.isEmpty
        let hasNonVisualContext = hasBrowserContext || hasSelection || hasAnyTitle

        let evidenceQuality: String = {
            if hasBrowserContext { return "browser_context" }
            if hasSelection { return "selection" }
            if hasAnyTitle { return "title_only" }
            return "none"
        }()
        print("[ManualInvokeJarvis] context_refresh_completed evidence_quality=\(evidenceQuality)")

        // Step 4: visual fallback only when no other context exists.
        let useVisual = !hasNonVisualContext
        let visualReason = useVisual ? "no_other_context_available" : "browser_or_ax_or_title_available"
        print("[ManualInvokeJarvis] visual_fallback_used=\(useVisual ? "yes" : "no") reason=\(visualReason)")

        // Step 5: ingest a fresh snapshot through the producer (updates dedup state)
        let synthesized = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: appName,
            windowTitle: windowTitle,
            bundleIdentifier: bundleID,
            selectedText: selectedText.isEmpty ? nil : selectedText,
            recentOCRExcerpt: currentSnapshot?.recentOCRExcerpt
        )
        await producer.ingest(snapshot: synthesized)

        // Step 6: force a tick now — bypass debounce/quiet.
        let state = await coordinator.tick(now: Date(), oldInferenceLabel: nil)
        print("[ManualInvokeJarvis] workflow=\(state.workflowType.rawValue)")

        let events = await coordinator.getEventStreamSnapshot()
        let buffer = TemporalContextBuffer.build(from: events, now: Date())
        let stabilized = await behavioral.tick(workflowState: state, shortWindow: buffer.short, now: Date())
        print("[ManualInvokeJarvis] behavior=\(stabilized.state.rawValue)")

        let packet = TemporalContextCompressor.compress(buffer: buffer)
        let memory = WorkingMemoryBuilder.build(workflow: state, behavior: stabilized, packet: packet)
        print("[ManualInvokeJarvis] working_memory entities=\(memory.recentEntities.count)")

        // Step 7: judgment summary (light — JudgmentLayer is run inside the
        // engine on accept. Here we just log so dogfooders can see what the
        // judgment WOULD see.)
        let judgmentEntities = memory.comparisonCandidates.isEmpty ? memory.recentEntities : memory.comparisonCandidates
        print("[ManualInvokeJarvis] judgment=entities_pending count=\(judgmentEntities.count)")

        // Step 8: force the suggestion to surface even if passive ambient would wait.
        let suggestion = await JarvisSuggestionGenerator.generate(
            workflowState: state,
            behavioralRecord: stabilized,
            packet: packet,
            recentTitles: buffer.short.recentTitles,
            repeatedTerms: buffer.short.repeatedTerms,
            forceShow: true
        )

        if let suggestion {
            print("[ManualInvokeJarvis] suggestion_created id=\(suggestion.id)")
            print("[ManualInvokeJarvis] artifact_ready=yes reason=suggestion_generated")
            publishSuggestion(suggestion)
            await ActiveContextRefresh.shared.noteSuggestion()
            return Result(
                workflow: state.workflowType.rawValue,
                behavior: stabilized.state.rawValue,
                intent: suggestion.intent,
                evidenceQuality: evidenceQuality,
                usedVisualFallback: useVisual,
                visualFallbackReason: visualReason,
                suggestionProduced: true,
                suggestionId: suggestion.id
            )
        } else {
            // Even forceShow returned nil — that means workflow/behavior are
            // both unknown/idle OR the safety validator rejected the wording.
            print("[ManualInvokeJarvis] suggestion_created id=none")
            print("[ManualInvokeJarvis] artifact_ready=no reason=suggestion_suppressed_unknown_or_idle")
            return Result(
                workflow: state.workflowType.rawValue,
                behavior: stabilized.state.rawValue,
                intent: "none",
                evidenceQuality: evidenceQuality,
                usedVisualFallback: useVisual,
                visualFallbackReason: visualReason,
                suggestionProduced: false,
                suggestionId: nil
            )
        }
    }

    // MARK: - Testable helper

    /// Same logic as `invoke(...)` but takes a pre-built snapshot for
    /// determinism. Tests use this so they don't depend on `NSWorkspace`.
    /// Optional `overrideWorkflow` / `overrideBehavior` let a test inject a
    /// deterministic workflow/behavior pair, bypassing the model-backed
    /// coordinator (which is intentionally a no-op stub under self-test).
    static func runPipeline(
        source: String,
        synthesizedSnapshot: CanonicalGeneratedExecutionContextSnapshot,
        hasBrowserContext: Bool,
        producer: ContextEventProducer,
        coordinator: WorkflowIntelligenceCoordinator,
        behavioral: BehavioralIntelligenceCoordinator,
        overrideWorkflow: WorkflowState? = nil,
        overrideBehavior: BehavioralStateRecord? = nil
    ) async -> Result {
        print("[ManualInvokeJarvis] started source=\(source)")
        print("[ManualInvokeJarvis] context_refresh_started")

        let hasSelection = !(synthesizedSnapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTitle = !synthesizedSnapshot.windowTitle.isEmpty
        let hasNonVisualContext = hasBrowserContext || hasSelection || hasTitle

        let evidenceQuality: String = {
            if hasBrowserContext { return "browser_context" }
            if hasSelection { return "selection" }
            if hasTitle { return "title_only" }
            return "none"
        }()
        print("[ManualInvokeJarvis] context_refresh_completed evidence_quality=\(evidenceQuality)")

        let useVisual = !hasNonVisualContext
        let visualReason = useVisual ? "no_other_context_available" : "browser_or_ax_or_title_available"
        print("[ManualInvokeJarvis] visual_fallback_used=\(useVisual ? "yes" : "no") reason=\(visualReason)")

        await producer.ingest(snapshot: synthesizedSnapshot)
        let state: WorkflowState
        if let o = overrideWorkflow { state = o }
        else { state = await coordinator.tick(now: Date(), oldInferenceLabel: nil) }
        let events = await coordinator.getEventStreamSnapshot()
        let buffer = TemporalContextBuffer.build(from: events, now: Date())
        let stabilized: BehavioralStateRecord
        if let o = overrideBehavior { stabilized = o }
        else { stabilized = await behavioral.tick(workflowState: state, shortWindow: buffer.short, now: Date()) }
        let packet = TemporalContextCompressor.compress(buffer: buffer)
        let suggestion = await JarvisSuggestionGenerator.generate(
            workflowState: state,
            behavioralRecord: stabilized,
            packet: packet,
            recentTitles: buffer.short.recentTitles,
            repeatedTerms: buffer.short.repeatedTerms,
            forceShow: true
        )
        return Result(
            workflow: state.workflowType.rawValue,
            behavior: stabilized.state.rawValue,
            intent: suggestion?.intent ?? "none",
            evidenceQuality: evidenceQuality,
            usedVisualFallback: useVisual,
            visualFallbackReason: visualReason,
            suggestionProduced: suggestion != nil,
            suggestionId: suggestion?.id
        )
    }
}
