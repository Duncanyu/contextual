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
        let currentEntity: String
        let relatedEntities: [String]
        let suggestionProduced: Bool
        let suggestionId: String?

        init(workflow: String, behavior: String, intent: String, evidenceQuality: String, usedVisualFallback: Bool, visualFallbackReason: String, currentEntity: String, relatedEntities: [String], suggestionProduced: Bool, suggestionId: String?) {
            self.workflow = workflow; self.behavior = behavior; self.intent = intent
            self.evidenceQuality = evidenceQuality
            self.usedVisualFallback = usedVisualFallback
            self.visualFallbackReason = visualFallbackReason
            self.currentEntity = currentEntity
            self.relatedEntities = relatedEntities
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
        print("[ManualInvokeJarvis] current_context_priority=yes")
        print("[ManualInvokeJarvis] current_title=\"\(windowTitle.prefix(120))\"")
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

        // Step 4b: Phase 21.2 — Editor context fallback for coding apps.
        // When AX selection is unavailable in an editor, use title / AX window /
        // surgical OCR (manual-only) to recover context instead of returning nothing.
        var editorContextNote: String? = nil
        if EditorContextFallback.isEditorApp(appName) || EditorContextFallback.isEditorTitle(windowTitle) {
            let editorResult = EditorContextFallback.extractManual(
                appName: appName,
                windowTitle: windowTitle,
                ocrFallback: currentSnapshot?.recentOCRExcerpt
            )
            if editorResult.available {
                editorContextNote = editorResult.contextText
                print("[ManualInvokeJarvis] visual_fallback_used=\(editorResult.source == "manual_ocr" ? "yes" : "no") reason=editor_no_ax_context")
            }
        }

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
        print("[ManualInvokeJarvis] stale_cluster_suppressed=\(packet.contextShiftDetected ? "yes" : "no")")
        let focusObs: FocusEpochTracker.Observation? = {
            guard let selected = browser?.selectedTitle, !selected.isEmpty else { return nil }
            return FocusEpochTracker.shared.observeSelectedTab(
                title: selected,
                workflowLabel: state.workflowType.rawValue
            )
        }()
        let effective: FocusOverride.Decision = {
            guard let obs = focusObs else {
                return FocusOverride.Decision(
                    applied: false,
                    effectiveWorkflow: state,
                    effectiveBehavior: stabilized,
                    reason: "no_focus_observation"
                )
            }
            return FocusOverride.applyIfNeeded(
                workflowState: state,
                behavioralRecord: stabilized,
                focusObservation: obs,
                recentTabTitles: tabTitles
            )
        }()
        if effective.applied {
            print("[ManualInvokeJarvis] focus_override_applied=yes old_workflow=\(state.workflowType.rawValue) new_workflow=\(effective.effectiveWorkflow.workflowType.rawValue)")
            print("[ManualInvokeJarvis] focus_override_behavior=yes old_behavior=\(stabilized.state.rawValue) new_behavior=\(effective.effectiveBehavior.state.rawValue)")
            print("[FocusOverride] applied=yes old_workflow=\(state.workflowType.rawValue) new_workflow=\(effective.effectiveWorkflow.workflowType.rawValue) reason=\(effective.reason)")
            print("[FocusOverride] old_behavior=\(stabilized.state.rawValue) new_behavior=\(effective.effectiveBehavior.state.rawValue) reason=\(effective.reason)")
        }

        let activeComp = await TaskCompartmentTracker.shared.getActiveCompartment()
        let allComps = await TaskCompartmentTracker.shared.compartments
        
        if let active = activeComp {
            print("[ManualInvokeJarvis] active_compartment=\"\(active.label)\"")
            let bgNames = allComps.filter { $0.id != active.id }.map { "\($0.label)" }
            print("[ManualInvokeJarvis] background_compartments=[\(bgNames.joined(separator: ", "))]")
            
            // Extract terms
            let activeTerms = active.dominantTerms.sorted()
            print("[ManualInvokeJarvis] terms_used=\(activeTerms.joined(separator: ","))")
            
            let bgTerms = allComps.filter { $0.id != active.id }.flatMap { $0.dominantTerms }.sorted()
            let excluded = bgTerms.filter { !active.dominantTerms.contains($0) }
            print("[ManualInvokeJarvis] terms_excluded=\(excluded.joined(separator: ","))")
        }

        let memory = WorkingMemoryBuilder.build(
            workflow: effective.effectiveWorkflow,
            behavior: effective.effectiveBehavior,
            packet: packet,
            browserTabTitles: tabTitles,
            selectedBrowserTabTitle: browser?.selectedTitle,
            activeCompartment: activeComp,
            allCompartments: allComps
        )
        let related = memory.recentEntities.filter { $0 != memory.currentEntity }
        print("[ManualInvokeJarvis] current_focus_priority=yes")
        print("[ManualInvokeJarvis] current_entity=\"\(memory.currentEntity.prefix(120))\"")
        print("[ManualInvokeJarvis] related_entities=[\(related.prefix(6).joined(separator: ", "))]")
        print("[ManualInvokeJarvis] working_memory entities=\(memory.recentEntities.count)")

        // Step 7: judgment summary
        let judgmentEntities = memory.comparisonCandidates.isEmpty ? memory.recentEntities : memory.comparisonCandidates
        print("[ManualInvokeJarvis] judgment=entities_pending count=\(judgmentEntities.count)")

        // Failure 4 Content Probe
        let isStudy = effective.effectiveWorkflow.workflowType == .studying || effective.effectiveBehavior.state == .learning
        var selectedTextAvailable = "no"
        var axContentAvailable = "no"
        var axChars = 0
        var probedQuality = hasNonVisualContext ? (hasBrowserContext ? "browser_tabs" : "title_only") : "none"
        if hasSelection { probedQuality = "selection" }

        if isStudy {
            print("[ManualInvokeJarvis] study_content_probe started")
            
            // 1. Probe selected text
            let hasSel = !selectedText.isEmpty
            selectedTextAvailable = hasSel ? "yes" : "no"
            
            // 2. Probe AX page content
            var axText = ""
            if let axCtx = AXWindowContentSource.shared.extractActiveWindowContent() {
                axText = axCtx.visibleTextFragments.joined(separator: " ")
                axChars = axText.count
                if axChars > 0 {
                    axContentAvailable = "yes"
                }
            }
            
            // 3. Fallbacks
            if hasSel {
                probedQuality = "selection"
            } else if axChars > 100 {
                probedQuality = "ax_content"
            } else if hasBrowserContext {
                probedQuality = "browser_tabs"
            } else {
                let ocr = (currentSnapshot?.recentOCRExcerpt ?? "")
                if !ocr.isEmpty {
                    probedQuality = "ax_content" // fallback to surgical OCR if AX content is insufficient
                } else {
                    probedQuality = "title_only"
                }
            }
            
            print("[ManualInvokeJarvis] selected_text_available=\(selectedTextAvailable)")
            print("[ManualInvokeJarvis] ax_content_available=\(axContentAvailable) chars=\(axChars)")
            print("[ManualInvokeJarvis] evidence_quality=\(probedQuality)")
        }

        let finalEvidenceQuality = isStudy ? probedQuality : evidenceQuality

        // Step 8: force the suggestion to surface
        let errorTerms = ["error", "exception", "stack", "trace", "failed", "fatal", "panic", "traceback"]
        let lowerTitle = windowTitle.lowercased()
        let lowerSel = selectedText.lowercased()
        let hasErrorTerms = errorTerms.contains { lowerTitle.contains($0) || lowerSel.contains($0) }
        
        let suggestion = await JarvisSuggestionGenerator.generate(
            workflowState: effective.effectiveWorkflow,
            behavioralRecord: effective.effectiveBehavior,
            packet: packet,
            recentTitles: buffer.short.recentTitles,
            repeatedTerms: buffer.short.repeatedTerms,
            forceShow: true,
            memory: memory,
            judgmentDecisionType: nil,
            hasSelection: hasSelection,
            hasAXContent: axContentAvailable == "yes" || probedQuality == "ax_content",
            hasErrorTerms: hasErrorTerms
        )

        // Required log
        let finalIntent = suggestion?.intent ?? (isStudy ? (probedQuality == "title_only" ? "organize_study_plan" : "generate_quiz") : "none")
        print("[ManualInvokeJarvis] action_intent=\(finalIntent)")

        if let suggestion {
            print("[ManualInvokeJarvis] suggestion_created id=\(suggestion.id)")
            print("[ManualInvokeJarvis] artifact_type=\(suggestion.intent)")
            print("[ManualInvokeJarvis] artifact_ready=yes reason=suggestion_generated")
            publishSuggestion(suggestion)
            await ActiveContextRefresh.shared.noteSuggestion()
            return Result(
                workflow: effective.effectiveWorkflow.workflowType.rawValue,
                behavior: effective.effectiveBehavior.state.rawValue,
                intent: suggestion.intent,
                evidenceQuality: finalEvidenceQuality,
                usedVisualFallback: useVisual,
                visualFallbackReason: visualReason,
                currentEntity: memory.currentEntity,
                relatedEntities: related,
                suggestionProduced: true,
                suggestionId: suggestion.id
            )
        } else {
            print("[ManualInvokeJarvis] suggestion_created id=none")
            print("[ManualInvokeJarvis] artifact_ready=no reason=suggestion_suppressed_unknown_or_idle")
            return Result(
                workflow: effective.effectiveWorkflow.workflowType.rawValue,
                behavior: effective.effectiveBehavior.state.rawValue,
                intent: finalIntent,
                evidenceQuality: finalEvidenceQuality,
                usedVisualFallback: useVisual,
                visualFallbackReason: visualReason,
                currentEntity: memory.currentEntity,
                relatedEntities: related,
                suggestionProduced: false,
                suggestionId: nil
            )
        }
    }

    // MARK: - Testable helper

    static func runPipeline(
        source: String,
        synthesizedSnapshot: CanonicalGeneratedExecutionContextSnapshot,
        hasBrowserContext: Bool,
        browserTabTitles: [String] = [],
        selectedBrowserTabTitle: String? = nil,
        producer: ContextEventProducer,
        coordinator: WorkflowIntelligenceCoordinator,
        behavioral: BehavioralIntelligenceCoordinator,
        overrideWorkflow: WorkflowState? = nil,
        overrideBehavior: BehavioralStateRecord? = nil
    ) async -> Result {
        print("[ManualInvokeJarvis] started source=\(source)")
        print("[ManualInvokeJarvis] context_refresh_started")

        print("[ManualInvokeJarvis] current_context_priority=yes")
        print("[ManualInvokeJarvis] current_title=\"\(synthesizedSnapshot.windowTitle.prefix(120))\"")

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
        print("[ManualInvokeJarvis] stale_cluster_suppressed=\(packet.contextShiftDetected ? "yes" : "no")")
        let focusObs: FocusEpochTracker.Observation? = {
            guard let selected = selectedBrowserTabTitle, !selected.isEmpty else { return nil }
            return FocusEpochTracker.shared.observeSelectedTab(
                title: selected,
                workflowLabel: state.workflowType.rawValue
            )
        }()
        let effective: FocusOverride.Decision = {
            guard let obs = focusObs else {
                return FocusOverride.Decision(applied: false, effectiveWorkflow: state, effectiveBehavior: stabilized, reason: "no_focus_observation")
            }
            return FocusOverride.applyIfNeeded(
                workflowState: state,
                behavioralRecord: stabilized,
                focusObservation: obs,
                recentTabTitles: hasBrowserContext ? browserTabTitles : []
            )
        }()
        if effective.applied {
            print("[ManualInvokeJarvis] focus_override_applied=yes old_workflow=\(state.workflowType.rawValue) new_workflow=\(effective.effectiveWorkflow.workflowType.rawValue)")
            print("[ManualInvokeJarvis] focus_override_behavior=yes old_behavior=\(stabilized.state.rawValue) new_behavior=\(effective.effectiveBehavior.state.rawValue)")
            print("[FocusOverride] applied=yes old_workflow=\(state.workflowType.rawValue) new_workflow=\(effective.effectiveWorkflow.workflowType.rawValue) reason=\(effective.reason)")
            print("[FocusOverride] old_behavior=\(stabilized.state.rawValue) new_behavior=\(effective.effectiveBehavior.state.rawValue) reason=\(effective.reason)")
        }

        let activeComp = await TaskCompartmentTracker.shared.getActiveCompartment()
        let allComps = await TaskCompartmentTracker.shared.compartments
        
        if let active = activeComp {
            print("[ManualInvokeJarvis] active_compartment=\"\(active.label)\"")
            let bgNames = allComps.filter { $0.id != active.id }.map { "\($0.label)" }
            print("[ManualInvokeJarvis] background_compartments=[\(bgNames.joined(separator: ", "))]")
            
            // Extract terms
            let activeTerms = active.dominantTerms.sorted()
            print("[ManualInvokeJarvis] terms_used=\(activeTerms.joined(separator: ","))")
            
            let bgTerms = allComps.filter { $0.id != active.id }.flatMap { $0.dominantTerms }.sorted()
            let excluded = bgTerms.filter { !active.dominantTerms.contains($0) }
            print("[ManualInvokeJarvis] terms_excluded=\(excluded.joined(separator: ","))")
        }

        let memory = WorkingMemoryBuilder.build(
            workflow: effective.effectiveWorkflow,
            behavior: effective.effectiveBehavior,
            packet: packet,
            browserTabTitles: hasBrowserContext ? browserTabTitles : [],
            selectedBrowserTabTitle: selectedBrowserTabTitle,
            activeCompartment: activeComp,
            allCompartments: allComps
        )
        let related = memory.recentEntities.filter { $0 != memory.currentEntity }
        print("[ManualInvokeJarvis] current_focus_priority=yes")
        print("[ManualInvokeJarvis] current_entity=\"\(memory.currentEntity.prefix(120))\"")
        print("[ManualInvokeJarvis] related_entities=[\(related.prefix(6).joined(separator: ", "))]")

        // Failure 4 Content Probe
        let isStudy = effective.effectiveWorkflow.workflowType == .studying || effective.effectiveBehavior.state == .learning
        var selectedTextAvailable = "no"
        var axContentAvailable = "no"
        var axChars = 0
        var probedQuality = hasNonVisualContext ? (hasBrowserContext ? "browser_tabs" : "title_only") : "none"
        if hasSelection { probedQuality = "selection" }

        if isStudy {
            print("[ManualInvokeJarvis] study_content_probe started")
            
            // 1. Probe selected text
            let hasSel = !(synthesizedSnapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            selectedTextAvailable = hasSel ? "yes" : "no"
            
            // 2. Probe AX page content (tests can mock AX content or use recentOCRExcerpt)
            var axText = ""
            if let axCtx = AXWindowContentSource.shared.extractActiveWindowContent() {
                axText = axCtx.visibleTextFragments.joined(separator: " ")
            }
            if axText.isEmpty, let ocr = synthesizedSnapshot.recentOCRExcerpt {
                axText = ocr
            }
            axChars = axText.count
            if axChars > 0 {
                axContentAvailable = "yes"
            }
            
            // 3. Fallbacks
            if hasSel {
                probedQuality = "selection"
            } else if axChars > 100 {
                probedQuality = "ax_content"
            } else if hasBrowserContext {
                probedQuality = "browser_tabs"
            } else {
                let ocr = (synthesizedSnapshot.recentOCRExcerpt ?? "")
                if !ocr.isEmpty {
                    probedQuality = "ax_content"
                } else {
                    probedQuality = "title_only"
                }
            }
            
            print("[ManualInvokeJarvis] selected_text_available=\(selectedTextAvailable)")
            print("[ManualInvokeJarvis] ax_content_available=\(axContentAvailable) chars=\(axChars)")
            print("[ManualInvokeJarvis] evidence_quality=\(probedQuality)")
        }

        let finalEvidenceQuality = isStudy ? probedQuality : evidenceQuality

        let errorTerms = ["error", "exception", "stack", "trace", "failed", "fatal", "panic", "traceback"]
        let lowerTitleR = synthesizedSnapshot.windowTitle.lowercased()
        let lowerSelR = (synthesizedSnapshot.selectedText ?? "").lowercased()
        let hasErrorTermsR = errorTerms.contains { lowerTitleR.contains($0) || lowerSelR.contains($0) }
        
        let suggestion = await JarvisSuggestionGenerator.generate(
            workflowState: effective.effectiveWorkflow,
            behavioralRecord: effective.effectiveBehavior,
            packet: packet,
            recentTitles: buffer.short.recentTitles,
            repeatedTerms: buffer.short.repeatedTerms,
            forceShow: true,
            memory: memory,
            judgmentDecisionType: nil,
            hasSelection: hasSelection,
            hasAXContent: axContentAvailable == "yes" || probedQuality == "ax_content",
            hasErrorTerms: hasErrorTermsR
        )

        let finalIntent = suggestion?.intent ?? (isStudy ? (probedQuality == "title_only" ? "organize_study_plan" : "generate_quiz") : "none")
        print("[ManualInvokeJarvis] action_intent=\(finalIntent)")

        if suggestion != nil {
            print("[ManualInvokeJarvis] action_intent=\(suggestion!.intent)")
            print("[ManualInvokeJarvis] artifact_type=\(suggestion!.intent)")
        }
        
        return Result(
            workflow: effective.effectiveWorkflow.workflowType.rawValue,
            behavior: effective.effectiveBehavior.state.rawValue,
            intent: suggestion?.intent ?? finalIntent,
            evidenceQuality: finalEvidenceQuality,
            usedVisualFallback: useVisual,
            visualFallbackReason: visualReason,
            currentEntity: memory.currentEntity,
            relatedEntities: related,
            suggestionProduced: suggestion != nil,
            suggestionId: suggestion?.id
        )
    }
}
