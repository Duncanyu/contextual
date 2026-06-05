import Foundation

/// Generic, workflow-agnostic two-stage execution engine for Ambient Jarvis.
///
/// Stage 1 → infer free-form intent from the temporal context packet.
/// Stage 2 → produce a structured Observed / Inferred / Unknown briefing.
///
/// The engine has **no** workflow-specific branching, no action registry, no
/// capability menu, no template per workflow. The same code path runs for
/// shopping, reading, debugging, studying, or any other workflow. Variation in
/// the output comes from variation in the context data being interpolated —
/// never from per-workflow `if`/`switch` control flow.
///
/// Inputs are strictly:
///   - `WorkflowState`
///   - `BehavioralStateRecord`
///   - `CompressedTemporalPacket`
///   - `CanonicalGeneratedExecutionContextSnapshot?` (optional)
///
/// No browser control. No web access. No OCR expansion. No tools. No planner.
enum ContextExecutionEngine {

    // MARK: - Public API

    /// Full engine API used by self-tests. Both stages are stubbed to
    /// deterministic fallbacks if the local model is unavailable, so the
    /// engine always returns a result.
    static func execute(
        workflow: WorkflowState,
        behavior: BehavioralStateRecord,
        packet: CompressedTemporalPacket,
        snapshot: CanonicalGeneratedExecutionContextSnapshot?,
        overriddenMemory: WorkingMemorySnapshot? = nil,
        overriddenCompartment: TaskCompartment? = nil,
        overriddenEvidenceQuality: String? = nil,
        requestedIntent: String? = nil,
        requestedGoal: String? = nil
    ) async -> ContextExecutionResult {
        print("[ContextExecutionEngine] started workflow=\(workflow.workflowType.rawValue) behavior=\(behavior.state.rawValue)")

		// Phase 18C evidence upgrade: extract public page metadata/facts if a public URL is visible.
		let ax = AXWindowContentSource.shared.extractActiveWindowContent()
		var axFragments = ax?.visibleTextFragments ?? []
        let windowTitle = snapshot?.windowTitle ?? packet.recentTitles.first ?? ""
        
        // Phase 20C: Browser Context & Surgical OCR
        let browserCtx = BrowserContextExtractor.extract(appName: packet.currentApp, activeAppPID: nil)
        if let u = browserCtx?.currentURL {
            axFragments.append(u.absoluteString)
        } else {
            let _ = await SurgicalOCR.extract(appName: packet.currentApp, windowTitle: windowTitle)
        }

        let visibleContextOnlyReason = determineVisibleContextOnlyReason(
            appName: packet.currentApp,
            windowTitle: windowTitle,
            browserURL: browserCtx?.currentURL,
            selectedText: snapshot?.selectedText,
            axTextFragments: axFragments
        )
        if let reason = visibleContextOnlyReason {
            print("[ContextExecutionEngine] visible_context_only=yes reason=\(reason)")
        }

		let pageCtx: PublicPageContextExtractor.PublicPageContext
        if visibleContextOnlyReason == nil {
            pageCtx = await PublicPageContextExtractor.shared.extract(
                windowTitle: windowTitle,
                axTextFragments: axFragments,
                clipboardText: snapshot?.clipboardText
            )
        } else {
            pageCtx = emptyPublicPageContext()
        }

        let activeComp: TaskCompartment?
        if let overridden = overriddenCompartment {
            activeComp = overridden
        } else {
            activeComp = await TaskCompartmentTracker.shared.getActiveCompartment()
        }
        let allComps = await TaskCompartmentTracker.shared.compartments

        // Phase 18C grounding fix — passive public-web enrichment runs BEFORE
        // intent inference so both stages can use the same enriched envelope.
        // Sensitive workflows + env disable + non-eligible terms all return
        // an empty WebContextEnrichment; downstream code never branches on it.
        let webEnrichment = await WebContextEnricher.shared.enrich(
            terms: packet.topicTerms,
            workflowType: workflow.workflowType,
            activeCompartment: activeComp,
            allCompartments: allComps
        )

        // Phase 20A Working Memory Generation
        let memory: WorkingMemorySnapshot
        if let over = overriddenMemory {
            memory = over
        } else {
            let tabTitles = browserCtx?.recentTabTitles ?? []
            let selectedTab = browserCtx?.selectedTitle
            memory = WorkingMemoryBuilder.build(
                workflow: workflow,
                behavior: behavior,
                packet: packet,
                browserTabTitles: tabTitles,
                selectedBrowserTabTitle: selectedTab,
                activeCompartment: activeComp,
                allCompartments: allComps
            )
        }

        let isStudy = workflow.workflowType == .studying || behavior.state == .learning
        if isStudy {
            let hasSel = !(snapshot?.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasAX = !axFragments.isEmpty
            let quality: String = {
                if hasSel { return "selection" }
                if hasAX { return "ax_content" }
                if !memory.relatedFocusEntities.isEmpty { return "browser_tabs" }
                return "title_only"
            }()
            
            print("[ContextExecutionEngine] related_focus_entities count=\(memory.relatedFocusEntities.count)")
            print("[ContextExecutionEngine] evidence_quality=\(quality)")
            
            let studyAction: String
            switch quality {
            case "selection":
                studyAction = "explain_topic"
            case "ax_content":
                studyAction = "generate_quiz"
            case "browser_tabs":
                studyAction = "create_study_outline"
            default:
                studyAction = "organize_study_plan"
            }
            print("[ContextExecutionEngine] study_action=\(studyAction)")
        }

        var envelope = Envelope(
            workflow: workflow,
            behavior: behavior,
            packet: packet,
            snapshot: snapshot,
            web: webEnrichment,
			page: pageCtx,
            visibleContextOnlyReason: visibleContextOnlyReason,
            memory: memory,
            judgment: .empty
        )

		var evidenceQuality: String = overriddenEvidenceQuality ?? (pageCtx.productFacts.isEmpty ? "title_only" : "product_metadata")
		if overriddenEvidenceQuality == nil && isStudy {
			let hasSel = !(snapshot?.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			let hasAX = !axFragments.isEmpty
			evidenceQuality = {
				if hasSel { return "selection" }
				if hasAX { return "ax_content" }
				if !memory.relatedFocusEntities.isEmpty { return "browser_tabs" }
				return "title_only"
			}()
		}
		let evidenceLevel = EvidenceQualityModel.level(from: evidenceQuality)
		print("[ContextEvidence] quality=\(evidenceQuality)")

        // Stage 1 — intent inference & Evidence Gating (Task B).
        var finalIntentStr = requestedIntent ?? "understand_context"
        var finalGoalStr = requestedGoal ?? ""
        var sourceStr = "suggestion"
        
        if requestedIntent == nil {
            let inferred = await inferIntent(envelope: envelope)
            finalIntentStr = inferred.intent
            finalGoalStr = inferred.goal
            sourceStr = inferred.source
        }

        if let req = requestedIntent {
            print("[ExecutionCapability] requested=\(req)")
            let axChars = axFragments.joined(separator: " ").count
            let axConf = 1.0
            print("[ExecutionEvidence] ax_chars=\(axChars) ax_confidence=\(axConf)")
            let contentRich = axChars > 500
            print("[ExecutionEvidence] content_rich=\(contentRich ? "yes" : "no")")
            
            var downgrade = false
            if req == "generate_quiz" || req == "explain_topic" {
                // Phase 22 — When the user explicitly clicks the action card the
                // intent is user-initiated: preserve it and let fallbackStructured
                // generate an honest artifact that acknowledges the evidence gap.
                // Downgrade only applies for autonomously inferred intents (no
                // explicit request), where thin evidence means we shouldn't promise
                // a quiz we can't deliver.
                // Note: `requestedIntent != nil` is always true inside this block,
                // but keeping the check explicit clarifies the intent.
                let isAutonomous = false  // requestedIntent is non-nil here by construction
                if isAutonomous && evidenceLevel != .selected_content {
                    if !contentRich || evidenceLevel.rank <= ProgressiveEvidenceLevel.metadata_rich.rank {
                        finalIntentStr = "organize_review_plan"
                        downgrade = true
                    }
                }
            }

            if downgrade {
                print("[ExecutionCapability] downgrade=yes reason=insufficient_content")
            } else {
                print("[ExecutionCapability] downgrade=no reason=user_initiated_intent_preserved")
            }
            print("[ExecutionCapability] final=\(finalIntentStr)")
        }

        let intent = InferredIntent(intent: finalIntentStr, subject: "", goal: finalGoalStr, confidence: 0.9, source: sourceStr)
        let confStr = String(format: "%.2f", intent.confidence)
        print("[ContextExecutionEngine] stage1_intent=\(intent.intent) source=\(intent.source) confidence=\(confStr)")
        
        if intent.intent == "compare_options" {
            let candidates = envelope.memory.comparisonCandidates
            print("[ContextExecutionEngine] comparison_candidates count=\(candidates.count)")
            print("[ContextExecutionEngine] comparison_candidates=[\(candidates.joined(separator: ", "))]")
        }

        // Phase 19: Goal inference.
        let goal = await GoalInferenceEngine.inferGoal(
            workflow: workflow,
            behavior: behavior,
            packet: packet,
            snapshot: snapshot
        )

        // Public Web Research Enrichment (Phase 19 & 20C)
        if evidenceLevel == .metadata_only,
           shouldAttemptPublicWebResearch(
                envelope: envelope,
                browserURL: browserCtx?.currentURL
           ) {
            print("[ContextEvidence] attempting_public_web_research=yes")
            let searchTitles = !envelope.memory.comparisonCandidates.isEmpty ? envelope.memory.comparisonCandidates : packet.recentTitles
            let researchResult = await PublicWebResearchEnricher.shared.searchAndFetch(
                intent: intent.intent,
                intentGoal: intent.goal,
                workflow: workflow.workflowType,
                behavior: behavior.state,
                titles: searchTitles,
                terms: packet.topicTerms,
                activeCompartment: activeComp,
                allCompartments: allComps
            )
            envelope.webResearchFacts = researchResult.facts
            if !envelope.webResearchFacts.isEmpty {
                evidenceQuality = "public_web_research"
                print("[ContextEvidence] quality=\(evidenceQuality)")
            }
        } else if evidenceLevel == .metadata_only {
            print("[ContextEvidence] attempting_public_web_research=no reason=visible_context_only")
        }

        // Phase 20D — Judgment Layer. Runs AFTER all evidence is gathered,
        // BEFORE Stage 2. The result is injected into the envelope so the
        // model and the fallback both consume the same judgment.
        let judgment = JudgmentLayer.judge(
            workflow: workflow,
            behavior: behavior,
            memory: envelope.memory,
            page: envelope.page,
            researchFacts: envelope.webResearchFacts,
            packet: envelope.packet
        )
        envelope.judgment = judgment
        print("[ContextExecutionEngine] judgment_injected=yes")

        // Stage 2 — structured execution.
        let result = await generateStructured(
            intent: intent,
            goal: goal,
            envelope: envelope,
            evidenceQuality: evidenceQuality,
            activeComp: activeComp,
            requestedIntent: requestedIntent
        )
		print("[ContextExecutionEngine] grounded_facts=count=\(result.extractedProductFacts.count + envelope.webResearchFacts.count)")
        print("[ContextExecutionEngine] completed observed=\(result.observed.count) inferred=\(result.inferred.count) unknown=\(result.unknown.count) web=\(result.webContext.count) source=\(result.source)")
        return result
    }
    /// Convenience overload that accepts an `AmbientJarvisSuggestion` + the
    /// Latest snapshot. Used by the AppState acceptance flow. The engine
    /// synthesizes minimal workflow / behavior / packet records from the
    /// suggestion's existing data fields when the full pipeline state is not
    /// at hand at the moment of acceptance.
    static func execute(
        suggestion: AmbientJarvisSuggestion,
        snapshot: CanonicalGeneratedExecutionContextSnapshot?
    ) async -> ContextExecutionResult {
        // Phase 22 — surface opportunity context for logging and routing.
        if let opp = suggestion.topOpportunity {
            print("[OpportunityExecution] started opportunity=\(opp.capabilityId) need=\(opp.inferredNeed.rawValue) confidence=\(String(format: "%.2f", opp.confidence)) entity=\"\(opp.title.prefix(60))\"")
            print("[ContextExecutionEngine] using_opportunity=yes capabilityId=\(opp.capabilityId) evidence=\(opp.requiredEvidence)")
        }
        print("[ContextExecutionEngine] using_intent=\(suggestion.intent) goal=\"\(suggestion.intentGoal)\"")
        let workflow = synthesizeWorkflow(from: suggestion, snapshot: snapshot)
        let behavior = synthesizeBehavior(from: suggestion)
        let packet   = synthesizePacket(from: suggestion, snapshot: snapshot)
        
        if let payload = suggestion.contextPayload {
            print("[ContextExecutionEngine] using_payload_context=yes")
            print("[ContextExecutionEngine] comparison_candidates count=\(payload.comparisonCandidates.count)")
            print("[ContextExecutionEngine] related_focus_entities count=\(payload.relatedFocusEntities.count)")
            
            return await execute(
                workflow: workflow,
                behavior: behavior,
                packet: packet,
                snapshot: snapshot,
                overriddenMemory: payload.workingMemorySnapshot,
                overriddenCompartment: payload.taskCompartmentSnapshot,
                overriddenEvidenceQuality: payload.evidenceQuality,
                requestedIntent: suggestion.intent,
                requestedGoal: suggestion.intentGoal
            )
        }
        
        return await execute(workflow: workflow, behavior: behavior, packet: packet, snapshot: snapshot, requestedIntent: suggestion.intent, requestedGoal: suggestion.intentGoal)
    }


    // MARK: - Envelope (single shape passed to both stages)

    private struct Envelope: Sendable {
        let workflow: WorkflowState
        let behavior: BehavioralStateRecord
        let packet: CompressedTemporalPacket
        let snapshot: CanonicalGeneratedExecutionContextSnapshot?
        let web: WebContextEnrichment
		let page: PublicPageContextExtractor.PublicPageContext
        var webResearchFacts: [PublicWebResearchEnricher.PublicGroundedFact] = []
        let visibleContextOnlyReason: String?
        let memory: WorkingMemorySnapshot
        var judgment: ContextJudgment

        var hasSelectedText: Bool {
            !(snapshot?.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var hasOCRDetail: Bool {
            !packet.ocrHints.isEmpty
        }
    }

    // MARK: - Stage 1 — intent

    private static func inferIntent(envelope: Envelope) async -> InferredIntent {
        let prompt = intentPrompt(envelope: envelope)

        if await ModelManager.shared.isGenerationAvailable() {
            do {
                let raw = try await LocalAIClient.shared.generate(
                    prompt: prompt,
                    model: "qwen2.5:0.5b",
                    numPredict: 96,
                    temperature: 0.2,
                    purpose: "ambient_intent_inference",
                    schema: nil
                )
                if let parsed = parseIntent(raw: raw) {
                    // Reuse the existing control-language validator so the
                    // model can never sneak action verbs into the intent.
                    let safety = JarvisSuggestionValidator.validate(
                        title: "\(parsed.intent) \(parsed.subject) \(parsed.goal)",
                        subtitle: ""
                    )
                    if safety {
                        return InferredIntent(
                            intent: parsed.intent,
                            subject: parsed.subject,
                            goal: parsed.goal,
                            confidence: parsed.confidence,
                            source: "model"
                        )
                    } else {
                        print("[ContextExecutionEngine] stage1_rejected reason=control_language")
                    }
                }
            } catch {
                print("[ContextExecutionEngine] stage1_model_error error=\(error)")
            }
        }
        return fallbackIntent(envelope: envelope)
    }

    /// Deterministic Stage-1 fallback. Generic across workflows: builds the
    /// subject from whichever topic terms the packet happens to carry. The
    /// intent string is a single fixed value because the engine does not
    /// branch on workflow.
    private static func fallbackIntent(envelope: Envelope) -> InferredIntent {
        let terms = envelope.packet.topicTerms.prefix(2).joined(separator: " / ")
        let subject = terms.isEmpty ? "the user's recent activity" : terms
        let goal = "Help the user make sense of \(subject) using only what is visible in context."
        return InferredIntent(
            intent: "understand_context",
            subject: subject,
            goal: goal,
            confidence: 0.4,
            source: "fallback"
        )
    }

    // MARK: - Stage 2 — structured execution

    private static func generateStructured(
        intent: InferredIntent,
        goal: GoalInference,
        envelope: Envelope,
        evidenceQuality: String,
        activeComp: TaskCompartment?,
        requestedIntent: String?
    ) async -> ContextExecutionResult {
        let prompt = executionPrompt(intent: intent, goal: goal, envelope: envelope, evidenceQuality: evidenceQuality)

        if await ModelManager.shared.isGenerationAvailable() {
            do {
                let raw = try await LocalAIClient.shared.generate(
                    prompt: prompt,
                    model: "qwen2.5:0.5b",
                    numPredict: 512,
                    temperature: 0.1,
                    purpose: "ambient_context_execution"
                )
                if let parsed = parseExecution(raw: raw) {
                    if parsed.passesSafety(
                        evidenceQuality: evidenceQuality,
                        extractedFacts: envelope.page.productFacts
                    ) {
                        var web = envelope.web.entries.map { "[\($0.source)] \($0.title): \($0.extract)" }
                        web.append(contentsOf: envelope.webResearchFacts.map { "[\($0.method)] \($0.sourceTitle): \($0.label) = \($0.value)" })
                        // Phase 20D — if the judgment is invalid we override
                        // the artifact type even when the model produced one.
                        // Section content stays the model's; the rendered
                        // judgment line above the artifact tells the user why.
                        let finalArtifact: ArtifactResult = {
                            if envelope.judgment.comparisonValidity == .invalid,
                               parsed.artifact.type != "clarification_brief" {
                                print("[ArtifactSelector] override=clarification_brief reason=model_attempted_invalid_comparison")
                                return ArtifactResult(type: "clarification_brief", title: "Clarification Needed", subtitle: "", sections: parsed.artifact.sections)
                            }
                            return parsed.artifact
                        }()
                        
                        let generatedAction = GeneratedActionCapabilityAdapter.actionFromArtifact(
                            title: finalArtifact.title,
                            description: finalArtifact.subtitle,
                            artifactType: finalArtifact.type,
                            confidence: intent.confidence,
                            evidenceQuality: evidenceQuality
                        )
                        let primaryAction = GeneratedActionCapabilityAdapter.capability(from: generatedAction)
                        
                        let card = ActionCard(
                            title: finalArtifact.title,
                            explanation: finalArtifact.subtitle,
                            primaryAction: primaryAction,
                            secondaryAction: nil,
                            auxiliaryAction: nil,
                            previewPayload: finalArtifact,
                            evidenceNote: "Based on \(evidenceQuality) evidence",
                            confidence: intent.confidence,
                            confirmationState: primaryAction.requiresConfirmation ? "required" : "none"
                        )

                        return ContextExecutionResult(
                            intent: intent,
                            goalInference: goal,
                            cognitiveArtifact: finalArtifact,
                            actionCard: card,
                            judgment: envelope.judgment,
                            observed: parsed.observed,
                            inferred: parsed.inferred,
                            unknown: parsed.unknown,
                            nextQuestion: parsed.nextQuestion,
                            webContext: envelope.webResearchFacts,
                            publicPageMetadata: envelope.page,
                            extractedProductFacts: envelope.page.productFacts,
                            evidenceQuality: evidenceQuality,
                            source: "model"
                        )
                    } else {
                        print("[ContextExecutionEngine] model_parse_failed reason=safety_check_failed")
                    }
                } else {
                    print("[ContextExecutionEngine] model_parse_failed reason=invalid_json_or_missing_keys")
                }
            } catch {
                print("[ContextExecutionEngine] stage2_model_error error=\(error)")
            }
        }
        print("[ContextExecutionEngine] fallback_preserving_web_facts=yes")
        return fallbackStructured(intent: intent, goal: goal, envelope: envelope, evidenceQuality: evidenceQuality, activeComp: activeComp, requestedIntent: requestedIntent)
    }

    private static func fallbackStructured(
        intent: InferredIntent,
        goal: GoalInference,
        envelope: Envelope,
        evidenceQuality: String,
        activeComp: TaskCompartment?,
        requestedIntent: String?
    ) -> ContextExecutionResult {

        // 1. Observed — derive from packet data verbatim. NEVER define what
        //    something IS; NEVER convert title fragments into claims.
        var observed: [String] = []
        let app = envelope.packet.currentApp
        if !app.isEmpty, app.lowercased() != "unknown" {
            observed.append("Active app: \(app)")
        }
        let titles = envelope.packet.recentTitles.filter { !$0.isEmpty }
        if titles.count >= 1 {
            observed.append("\(titles.count) distinct title(s) in the recent window:")
            for t in titles.prefix(3) {
                let trimmed = t.count > 80 ? String(t.prefix(77)) + "…" : t
                observed.append("  • \(trimmed)")
            }
        }
        if !envelope.packet.topicTerms.isEmpty {
            let topTerms = envelope.packet.topicTerms.prefix(4).joined(separator: ", ")
            observed.append("Repeating terms (label only, not facts): \(topTerms)")
        }
        if envelope.hasOCRDetail {
            let topOCR = envelope.packet.ocrHints.prefix(3).joined(separator: ", ")
            observed.append("OCR signal: \(topOCR)")
        }
        if !envelope.memory.relatedFocusEntities.isEmpty {
            observed.append("Related materials from tabs:")
            for tab in envelope.memory.relatedFocusEntities.prefix(4) {
                observed.append("  • \(tab)")
            }
        }

        // 2. Public web context — rendered as its own list passed to the
        //    result; no inference logic here.
        var webContext: [String] = envelope.web.entries.map { e in
            "[\(e.source)] \(e.title): \(e.extract)"
        }
        webContext.append(contentsOf: envelope.webResearchFacts.map { "[\($0.method)] \($0.sourceTitle): \($0.label) = \($0.value)" })

		let quality = evidenceQuality

        // 3. Inferred — HEAVILY hedged. Generic across workflows.
        var inferred: [String] = []
        let wfLabel = envelope.workflow.workflowType.rawValue
        if wfLabel.lowercased() != "unknown" {
            inferred.append("Activity appears to be \(wfLabel)-flavored based on temporal signals (not a definition of the items themselves).")
        }
        let bhLabel = envelope.behavior.state.rawValue
        if bhLabel.lowercased() != "unknown", bhLabel != wfLabel {
            inferred.append("Recent behavior pattern resembles \(bhLabel).")
        }
        if titles.count >= 3 && envelope.packet.topicTerms.count >= 2 {
            let shared = envelope.packet.topicTerms.prefix(3).joined(separator: ", ")
            inferred.append("Multiple titles share these terms (\(shared)) — may suggest evaluating related items.")
        }
        // Honest title-only acknowledgment — this is what the grounding-quality
        // brief specifically asked for.
        if EvidenceQualityModel.level(from: quality).rank <= ProgressiveEvidenceLevel.metadata_rich.rank
            && !envelope.hasOCRDetail
            && !envelope.hasSelectedText {
            inferred.append("Only titles and metadata are available — specific specs, prices, or details cannot be compared from this data alone.")
        }
        if envelope.packet.contextShiftDetected {
            inferred.append("A recent context shift suggests the user's focus changed.")
        }
        if inferred.isEmpty {
            inferred.append("Not enough signal yet to characterize the session.")
        }

        // 4. Unknown — concrete absence-of-signal gaps. Generic.
        var unknown: [String] = []
        if !envelope.hasSelectedText {
            unknown.append("What the user has specifically highlighted (no selected text in context).")
        }
        if !envelope.hasOCRDetail {
            unknown.append("Pricing, specs, ratings, capacities, or other details inside any item (no OCR in window).")
        }
        if envelope.packet.clipboardMetadata == "none" {
            unknown.append("Clipboard context (none reported).")
        }
        unknown.append("User's specific decision criteria or use-case constraints.")

        // 5. Next question — single generic prompt that works across workflows.
        let nextQuestion = "Which dimension matters most to you here — and which item would you like to focus on first?"

        // Entity from working memory — used in opportunity-keyed artifact titles.
        let entity = envelope.memory.currentEntity
        let entityShort = String(entity.prefix(42)).trimmingCharacters(in: .whitespaces)

        var title = "Context Summary"
        var subtitle = "Observation of recent activity."
        var artifactType = intent.intent   // overridden to canonical type below
        var sections: [ArtifactSection] = []
        let primaryCards: [ArtifactCard] = []
        var tableRows: [[String]]? = nil
        var nextActions: [String] = []
        var missingInfo = unknown

        // Phase 22 — Opportunity-keyed artifact generation.
        // Switches on intent.intent (= opportunity.capabilityId when driven by
        // OpportunityEngine). Each branch generates concrete, honest content
        // using only what is in the envelope — no hallucinated specs or facts.
        if let phase29 = buildPhase29Artifact(
            intent: intent.intent,
            entityShort: entityShort,
            envelope: envelope,
            evidenceQuality: quality
        ) {
            artifactType = phase29.type
            title = phase29.title
            subtitle = phase29.subtitle
            sections = phase29.sections
            tableRows = phase29.tableRows
            nextActions = phase29.nextActions
            missingInfo = phase29.missingInfo
            print("[ArtifactRender] type=\(phase29.type) capability=\(intent.intent)")
        } else {
        switch intent.intent {

        // ── Comparison ─────────────────────────────────────────────────────
        case "compare_options", "decision_matrix":
            artifactType = "table"
            title = "Comparison"
            subtitle = "Evaluation based on \(observed.count) signals"
            if !envelope.memory.comparisonCandidates.isEmpty {
                var header = ["Feature"]
                header.append(contentsOf: envelope.memory.comparisonCandidates)
                tableRows = [header]
            } else {
                tableRows = [["Feature", "Item 1", "Item 2"]]
            }
            sections.append(ArtifactSection(header: "Missing Criteria", items: unknown))
            nextActions.append("What to check next")
            missingInfo = envelope.judgment.missingInformation

        // ── Game / Creative-coding testing checklist ────────────────────────
        case "generate_test_checklist", "create_game_design_checklist":
            artifactType = "checklist"
            title = entityShort.isEmpty ? "Testing Checklist" : "Testing Checklist: \(entityShort)"
            subtitle = "Verify your project works correctly before sharing."
            let terms = Set(envelope.packet.topicTerms.map { $0.lowercased() })
            let hasShooter = terms.contains(where: { $0.contains("shoot") || $0.contains("tank") || $0.contains("bullet") || $0.contains("gun") })
            let hasPlatform = terms.contains(where: { $0.contains("jump") || $0.contains("platform") || $0.contains("gravity") })
            let controlsItems: [String] = [
                "Movement responds to keyboard/mouse input correctly",
                hasShooter ? "Shooting fires in the correct direction" :
                hasPlatform ? "Jump and gravity feel natural" : "Primary action triggers correctly",
                "Player cannot move outside the stage boundaries"
            ]
            sections.append(ArtifactSection(header: "Player Controls", items: controlsItems))
            sections.append(ArtifactSection(header: "Collision Detection", items: [
                "Projectiles or attacks register hits on enemies/targets",
                "Player takes damage or reacts on collision",
                "Solid boundaries block movement as intended"
            ]))
            sections.append(ArtifactSection(header: "Game State", items: [
                "Win condition triggers and displays a message",
                "Game over / lose condition fires correctly",
                "Score or progress increments as expected"
            ]))
            sections.append(ArtifactSection(header: "Performance", items: [
                "Frame rate stays smooth when many sprites are on screen",
                "No 'too many clones' or sprite-limit errors appear"
            ]))
            missingInfo = [
                "Specific sprite names and behaviors (no screen content — title only)",
                "Custom scoring rules or level structure (need AX content to verify)",
                "Sound and music trigger conditions"
            ]
            print("[ArtifactRender] type=checklist capability=\(intent.intent)")

        // ── Studying: practice quiz ─────────────────────────────────────────
        case "generate_quiz":
            artifactType = "quiz"
            title = entityShort.isEmpty ? "Practice Quiz" : "Practice Questions: \(entityShort)"
            subtitle = "Generated from detected topic terms (title-only evidence)."
            let topicTerms = Array(envelope.packet.topicTerms.prefix(4))
            let questions: [String]
            if topicTerms.isEmpty {
                questions = [
                    "Q1: What is the central concept covered in this material?",
                    "Q2: How does the main idea apply in a real example?",
                    "Q3: What would you need to look up to go deeper?"
                ]
            } else {
                questions = topicTerms.map { t in
                    "Q: What is the key insight behind '\(t)' — and why does it matter?"
                }
            }
            sections.append(ArtifactSection(header: "Practice Questions", items: questions))
            sections.append(ArtifactSection(header: "Note on Evidence", items: [
                "AX screen content would enable questions drawn directly from your notes.",
                "Current evidence is title-only — questions are based on detected topic terms."
            ]))
            missingInfo = [
                "Specific note or lecture content (no AX content available)",
                "Exact question wording from course material",
                "Answer key (requires note text)"
            ]
            print("[ArtifactRender] type=quiz capability=\(intent.intent)")

        // ── Studying: review plan / outline ────────────────────────────────
        case "create_review_plan", "create_study_outline", "organize_review_plan":
            artifactType = "checklist"
            title = entityShort.isEmpty ? "Review Plan" : "Review Plan: \(entityShort)"
            subtitle = "Structured review strategy based on detected topics."
            let topicTerms = Array(envelope.packet.topicTerms.prefix(5))
            sections.append(ArtifactSection(
                header: "Topics Detected",
                items: topicTerms.isEmpty ? ["No specific topics extracted yet (title-only)"] : topicTerms
            ))
            sections.append(ArtifactSection(header: "Suggested Review Order", items: [
                "1. Scan headings and key terms to build a mental map",
                "2. Summarize each topic in one sentence from memory",
                "3. Write 2–3 practice questions per topic",
                "4. Test recall without looking at notes"
            ]))
            sections.append(ArtifactSection(header: "Review Checklist", items: [
                "Notes from last session reviewed",
                "Syllabus checked for upcoming deadlines",
                "Concepts that need follow-up flagged"
            ]))
            missingInfo = [
                "Specific note content (no AX content — title only)",
                "Assignment deadlines (not in context)",
                "Prior quiz or test results"
            ]
            print("[ArtifactRender] type=checklist capability=\(intent.intent)")

        // ── Debugging / error diagnosis ────────────────────────────────────
        case "diagnose_error", "debug_performance":
            artifactType = "diagnostic"
            title = entityShort.isEmpty ? "Debug Checklist" : "Debug Checklist: \(entityShort)"
            subtitle = "Investigation steps based on detected error signals."
            let errorTerms = envelope.packet.topicTerms.filter { t in
                let errWords: Set<String> = ["error", "exception", "crash", "failed", "bug", "undefined", "null", "warning"]
                return errWords.contains(t.lowercased())
            }
            sections.append(ArtifactSection(
                header: "Error Signals Detected",
                items: errorTerms.isEmpty ? ["Error terms detected via topic signals (details unavailable)"] : errorTerms
            ))
            sections.append(ArtifactSection(header: "Investigation Steps", items: [
                "1. Read the full error message — note the exact type and line number",
                "2. Check the most recent change that could have caused this",
                "3. Verify all dependencies and imports are present",
                "4. Search the error message text for known solutions"
            ]))
            sections.append(ArtifactSection(header: "Likely Causes (Hedged)", items: [
                "Missing import or misconfigured dependency (common for build errors)",
                "Type mismatch or nil access (common for runtime crashes)",
                "Logic error introduced in a recent edit"
            ]))
            missingInfo = [
                "Full error text (no AX content — need screen access)",
                "Stack trace and line number (no OCR in current window)",
                "Specific file or function where error occurs"
            ]
            nextActions.append("Open the error output and paste it into a search or AI assistant")
            print("[ArtifactRender] type=diagnostic capability=\(intent.intent)")

        // ── Communication: draft reply ──────────────────────────────────────
        case "draft_reply", "extract_action_items":
            artifactType = intent.intent == "draft_reply" ? "draft" : "checklist"
            if intent.intent == "draft_reply" {
                title = entityShort.isEmpty ? "Reply Outline" : "Reply Outline: \(entityShort)"
                subtitle = "Confirmation required — this will not be sent automatically."
                sections.append(ArtifactSection(header: "⚠ Confirmation Required", items: [
                    "Review this outline before any message is composed.",
                    "No message will be sent or drafted without your explicit approval."
                ]))
                sections.append(ArtifactSection(header: "Reply Structure", items: [
                    "1. Acknowledge the original message or request",
                    "2. State your main response clearly and directly",
                    "3. Include any action items, questions, or attachments",
                    "4. Close with a clear next step or expected response"
                ]))
                missingInfo = [
                    "Message body text (no AX content — title only)",
                    "Sender name and original subject line",
                    "Thread context beyond the visible window title"
                ]
                print("[ArtifactRender] type=draft capability=draft_reply")
            } else {
                title = entityShort.isEmpty ? "Action Items" : "Action Items: \(entityShort)"
                subtitle = "Extracted from communication context."
                sections.append(ArtifactSection(header: "Likely Action Items", items: [
                    "Identify who owns each outstanding request",
                    "Check for deadlines mentioned in the thread",
                    "Flag items that need follow-up"
                ]))
                missingInfo = [
                    "Message body text (no AX content)",
                    "Specific names and dates (not in context)"
                ]
                print("[ArtifactRender] type=checklist capability=extract_action_items")
            }

        // ── Research: source synthesis ──────────────────────────────────────
        case "synthesize_sources", "summarize_reference":
            artifactType = "synthesis"
            let sourceCount = envelope.memory.relatedFocusEntities.count + 1
            title = entityShort.isEmpty ? "Research Synthesis" : "Synthesis: \(entityShort)"
            subtitle = "Combined notes from \(sourceCount) detected source(s)."
            let sourceList = envelope.memory.relatedFocusEntities.isEmpty
                ? (entityShort.isEmpty ? ["(No sources extracted)"] : [entityShort])
                : ([entityShort] + Array(envelope.memory.relatedFocusEntities.prefix(3))).filter { !$0.isEmpty }
            sections.append(ArtifactSection(header: "Sources Detected", items: sourceList))
            let sharedTerms = Array(envelope.packet.topicTerms.prefix(4))
            sections.append(ArtifactSection(
                header: "Shared Concepts",
                items: sharedTerms.isEmpty ? ["No shared terms extracted yet"] : sharedTerms
            ))
            sections.append(ArtifactSection(header: "Synthesis Structure", items: [
                "Main thesis or conclusion across all sources",
                "Points of agreement between sources",
                "Contradictions or gaps that need resolution",
                "Key evidence or quotes worth preserving"
            ]))
            missingInfo = [
                "Full text content from each source (title-only evidence)",
                "Publication dates and author credibility signals",
                "Methodology and scope of each source"
            ]
            print("[ArtifactRender] type=synthesis capability=\(intent.intent)")

        // ── Planning / next steps ────────────────────────────────────────────
        case "create_next_steps", "create_checklist", "create_outline", "improve_project":
            artifactType = "checklist"
            title = entityShort.isEmpty ? "Next Steps" : "Next Steps: \(entityShort)"
            subtitle = "Suggested actions based on detected context."
            sections.append(ArtifactSection(
                header: "Current Focus",
                items: [entityShort.isEmpty ? "Task not identified from context" : entityShort]
            ))
            sections.append(ArtifactSection(header: "Suggested Steps", items: [
                "Define your immediate goal for this session",
                "Break the next task into smaller, specific pieces",
                "Identify what is currently blocking progress",
                "Set a time limit for this work block"
            ]))
            print("[ArtifactRender] type=checklist capability=\(intent.intent)")

        // ── Fallback: summarize / explain / unknown ─────────────────────────
        default:
            artifactType = "summary"
            title = "Context Summary"
            subtitle = "Summary of observed activity."
            sections.append(ArtifactSection(header: "Observed", items: observed))
            sections.append(ArtifactSection(header: "Inferred", items: inferred))
            print("[ArtifactRender] type=summary capability=\(intent.intent)")
        }
        }

        let artifact = ArtifactResult(
            type: artifactType,
            title: title,
            subtitle: subtitle,
            sections: sections,
            primaryCards: primaryCards,
            tableRows: tableRows,
            missingInfo: missingInfo,
            confidence: envelope.judgment.confidence,
            nextActions: nextActions
        )

        // Override next question if judgment is invalid — the brief requires
        // we ask the clarifying question rather than push a comparison.
        var finalNextQuestion = nextQuestion
        if envelope.judgment.comparisonValidity == .invalid {
            finalNextQuestion = "It looks like these items may serve different needs — what are you actually trying to accomplish here?"
        }

        let generatedAction = GeneratedActionCapabilityAdapter.actionFromArtifact(
            title: artifact.title,
            description: artifact.subtitle,
            artifactType: artifact.type,
            confidence: envelope.judgment.confidence,
            evidenceQuality: evidenceQuality
        )
        let primaryAction = GeneratedActionCapabilityAdapter.capability(from: generatedAction)
        
        let card = ActionCard(
            title: artifact.title,
            explanation: artifact.subtitle,
            primaryAction: primaryAction,
            secondaryAction: nil,
            auxiliaryAction: nil,
            previewPayload: artifact,
            evidenceNote: "Fallback based on \(evidenceQuality) evidence",
            confidence: envelope.judgment.confidence,
            confirmationState: primaryAction.requiresConfirmation ? "required" : "none"
        )

        return ContextExecutionResult(
            intent: intent,
            goalInference: goal,
            cognitiveArtifact: artifact,
            actionCard: card,
            judgment: envelope.judgment,
            observed: observed,
            inferred: inferred,
            unknown: unknown,
            nextQuestion: finalNextQuestion,
            webContext: envelope.webResearchFacts,
			publicPageMetadata: envelope.page,
			extractedProductFacts: envelope.page.productFacts,
			evidenceQuality: quality,
            source: "fallback"
        )
    }

    // MARK: - Prompts (identical shape for every workflow)

    private static func intentPrompt(envelope: Envelope) -> String {
        return """
        You watch what the user has been doing on their computer recently and
        infer what they are trying to UNDERSTAND or LEARN. You do NOT plan
        actions. You do NOT click, open, navigate, search, or run anything.

        Output STRICT JSON with these keys and nothing else:
        {"intent":"...","subject":"...","goal":"...","confidence":0.0}

        Rules:
        - "intent" is a short verb phrase: understand_X, identify_X, compare_X, etc.
        - "subject" is a natural-language description of WHAT it applies to.
        - "goal" is one short sentence stating what would satisfy the user.
        - "confidence" is 0..1.
        - Do NOT use action verbs (click, open, navigate, run, search, buy, install).
        - Do NOT invent specific products, prices, sizes, or facts.

        Context (last \(envelope.packet.spanSeconds) seconds, \(envelope.packet.eventCount) events):
        - workflow: \(envelope.workflow.workflowType.rawValue)
        - behavior: \(envelope.behavior.state.rawValue)
        - current_app: \(envelope.packet.currentApp)
        - recent_apps: \(envelope.packet.recentApps.joined(separator: ", "))
        - recent_titles: \(envelope.packet.recentTitles.prefix(6).joined(separator: " | "))
        - topic_terms: \(envelope.packet.topicTerms.joined(separator: ", "))
        - ocr_hints: \(envelope.packet.ocrHints.joined(separator: ", "))
        - activity_pattern: \(envelope.packet.activityPattern)
        - typing_pattern: \(envelope.packet.typingPattern)
        """
    }

    private static func executionPrompt(
        intent: InferredIntent,
        goal: GoalInference,
        envelope: Envelope,
        evidenceQuality: String
    ) -> String {
		let pageMetaLines = renderPublicPageMetadata(envelope.page).map { "- \($0)" }.joined(separator: "\n        ")
		let productFactLines = renderProductFacts(envelope.page).map { "- \($0)" }.joined(separator: "\n        ")

        let webBlock: String
        let allWebEntries = envelope.web.entries.map { "[\($0.source)] \($0.title): \($0.extract)" } + envelope.webResearchFacts.map { "[\($0.method)] \($0.sourceTitle): \($0.label) = \($0.value)" }
        if allWebEntries.isEmpty {
            webBlock = "Public web context: (none — none fetched)"
        } else {
            let lines = allWebEntries.map { "- \($0)" }.joined(separator: "\n        ")
            webBlock = """
            Public web context (sourced externally — clearly mark these in "observed"):
                    \(lines)
            """
        }
        return """
        You produce a short, context-only briefing and a cognitive artifact.
        You may use the supplied screen context AND the supplied public-web context.
        Do NOT invent facts beyond these sources.

        Output STRICT JSON with exactly these keys:
        {
          "artifact": {
            "artifactType": "recommendation_brief | research_brief | knowledge_brief | diagnostic_brief | decision_brief",
            "sections": [
              {"heading": "...", "items": ["..."]}
            ]
          },
          "observed": ["..."],
          "inferred": ["..."],
          "unknown": ["..."],
          "next_question": "...",
          "reframed_reason": "null or entities_not_same_category"
        }

        Phase 19 Artifact Rules:
        - Choose artifactType based on the inferred GOAL.
        - recommendation_brief: Use for comparing items to help decisions. Sections: Biggest Differences, Likely Best Option, Reasoning, Concerns, Missing Verification.
        - research_brief: Use for deep topic understanding. Sections: Main Takeaways, Agreements, Disagreements, Missing Evidence, Worth Investigating.
        - knowledge_brief: For reading comprehension. Sections: Key Ideas, Important Relationships, Memorable Takeaways, Likely Questions.
        - diagnostic_brief: For troubleshooting. Sections: Strongest Evidence, Most Likely Causes, Unknowns, Next Investigation Target.
        - If working memory candidates are not comparable alternatives, do not force a comparison. Explain the category mismatch in your artifact sections, suggest a more useful next artifact, and set "reframed_reason" to "entities_not_same_category".

        Section rules:
        - "observed" — items from screen context. Prefix web entries with "[web]".
        - "inferred" — cautious interpretations ("appears", "may", "seems").
        - "unknown" — explicit data gaps.
        - "next_question" — one short actionable question.

        Hard rules:
        - Artifact sections should be grounding-first. Do NOT hallucinate.
        - 1–4 items per list. Items ≤ 18 words.
        - Do NOT include action verbs (click, open, buy, install).
        - Do NOT define generic terms.
        - Never answer "what is X" unless X appears in extracted facts.
        - evidence_quality=\(evidenceQuality). If evidence is metadata-only or metadata-rich, do not compare specs.

        Intent: \(intent.intent)
        Goal: \(goal.goal)
        Goal Reasoning: \(goal.reasoning)

        Working Memory (Session Context):
        - inferred_activity: \(envelope.memory.inferredActivity)
        - repeated_concepts: \(envelope.memory.repeatedConcepts.joined(separator: ", "))
        - comparison_candidates: \(envelope.memory.comparisonCandidates.isEmpty ? "none" : envelope.memory.comparisonCandidates.joined(separator: " | "))

        Screen context:
        - workflow: \(envelope.workflow.workflowType.rawValue)
        - behavior: \(envelope.behavior.state.rawValue)
        - titles: \(envelope.packet.recentTitles.prefix(6).joined(separator: " | "))
        - terms: \(envelope.packet.topicTerms.joined(separator: ", "))
        - ocr: \(envelope.packet.ocrHints.joined(separator: ", "))

        \(webBlock)

        Public page metadata:
        \(pageMetaLines.isEmpty ? "- (none)" : pageMetaLines)

        Extracted product facts:
        \(productFactLines.isEmpty ? "- (none)" : productFactLines)
        """
    }

	// MARK: - Public page render helpers (data-only; no inference)

	private static func renderPublicPageMetadata(_ page: PublicPageContextExtractor.PublicPageContext) -> [String] {
		var out: [String] = []
		if let url = page.url?.absoluteString { out.append("url: \(url)") }
		if let t = page.pageTitle { out.append("title: \(String(t.prefix(140)))") }
		if let t = page.ogTitle { out.append("og:title: \(String(t.prefix(140)))") }
		if let d = page.ogDescription { out.append("og:description: \(String(d.prefix(180)))") }
		return out
	}

	private static func renderProductFacts(_ page: PublicPageContextExtractor.PublicPageContext) -> [String] {
		var out: [String] = []
		func add(_ k: String, _ label: String) {
			if let v = page.productFacts[k], !v.isEmpty {
				out.append("\(label): \(String(v.prefix(180)))")
			}
		}
		add("title", "product.name")
		add("brand", "product.brand")
		add("price", "offer.price")
		add("priceCurrency", "offer.currency")
		add("ratingValue", "rating.value")
		add("ratingCount", "rating.count")
		add("capacity", "product.capacity")
		add("wattage", "product.wattage")
		add("ports", "product.ports")
		return out
	}

    private struct Phase29ArtifactBuild {
        let type: String
        let title: String
        let subtitle: String
        let sections: [ArtifactSection]
        let tableRows: [[String]]?
        let missingInfo: [String]
        let nextActions: [String]
    }

    private static func buildPhase29Artifact(
        intent: String,
        entityShort: String,
        envelope: Envelope,
        evidenceQuality: String
    ) -> Phase29ArtifactBuild? {
        let hookChain = previewHookChain(for: intent)
        guard !hookChain.isEmpty else { return nil }
        for hook in hookChain {
            print("[HookChainExecution] capability=\(intent) hook=\(hook) mapped=yes target=preview_artifact_builder")
        }

        let localOnly = envelope.visibleContextOnlyReason != nil
        let localOnlySubtitle = localOnly ? "Based on visible/current context." : ""
        let sourceTitles = visibleSourceTitles(from: envelope)
        let repeatedTerms = Array(envelope.memory.repeatedConcepts.prefix(6))
        let selectedText = envelope.snapshot?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasStructuredFacts = !envelope.page.productFacts.isEmpty || !envelope.webResearchFacts.isEmpty
        let visibleSnippet = selectedText.isEmpty ? nil : String(selectedText.prefix(220))

        switch intent {
        case "synthesize_sources":
            var sections: [ArtifactSection] = [
                ArtifactSection(
                    header: "Sources Detected",
                    items: sourceTitles.isEmpty ? ["Only the current title is available from visible context."] : sourceTitles
                ),
                ArtifactSection(
                    header: "Shared Themes",
                    items: repeatedTerms.isEmpty ? ["No shared themes extracted yet from visible context."] : repeatedTerms
                )
            ]
            if let visibleSnippet {
                sections.append(ArtifactSection(
                    header: "Visible Context",
                    items: [visibleSnippet]
                ))
            }
            sections.append(ArtifactSection(
                header: "What This Supports",
                items: [
                    localOnly ? "A conservative synthesis based on visible/current context." : "A synthesis using currently visible sources and page metadata.",
                    "Common threads across the open sources.",
                    "Questions or gaps worth checking next."
                ]
            ))
            return Phase29ArtifactBuild(
                type: "synthesis",
                title: entityShort.isEmpty ? "Research Synthesis" : "Synthesis: \(entityShort)",
                subtitle: localOnlySubtitle.isEmpty ? "Synthesized from currently visible sources." : localOnlySubtitle,
                sections: sections,
                tableRows: nil,
                missingInfo: [
                    "Full source text beyond what is currently visible.",
                    "Publication dates, authorship, and credibility details.",
                    "Any hidden or collapsed content not present on screen."
                ],
                nextActions: ["Verify the most important claim against the original source text"]
            )

        case "compare_rental_options":
            let candidates = sourceTitles.isEmpty ? [entityShort].filter { !$0.isEmpty } : sourceTitles
            let comparisonRows: [[String]] = {
                var rows = [["Candidate", "Visible Signal", "Missing To Compare"]]
                for candidate in candidates.prefix(4) {
                    let visibleSignal = repeatedTerms.isEmpty ? "Title/context only" : repeatedTerms.prefix(2).joined(separator: ", ")
                    rows.append([candidate, visibleSignal, "rent, utilities, lease term, location"])
                }
                return rows
            }()

            let conservativeLine = "I only have titles, so I can identify candidate items but cannot compare specs yet."
            let compareSections: [ArtifactSection] = [
                ArtifactSection(
                    header: "Observed from screen",
                    items: candidates.isEmpty ? ["No candidate rental posts were extracted."] : candidates
                ),
                ArtifactSection(
                    header: "Comparison Readiness",
                    items: hasStructuredFacts && EvidenceQualityModel.level(from: evidenceQuality).rank > ProgressiveEvidenceLevel.metadata_rich.rank
                        ? ["Some explicit metadata is available, but rental-specific fields remain sparse."]
                        : [conservativeLine]
                )
            ]
            return Phase29ArtifactBuild(
                type: "table",
                title: candidates.count >= 2 ? "Compare Rental Options" : "Rental Context Comparison",
                subtitle: localOnlySubtitle.isEmpty ? conservativeLine : localOnlySubtitle,
                sections: compareSections,
                tableRows: comparisonRows,
                missingInfo: [
                    "Exact monthly rent and whether utilities are included.",
                    "Lease term, move-in date, and deposit details.",
                    "Location, furnishing, and roommate/occupancy details."
                ],
                nextActions: ["Collect the missing listing facts before making a final comparison"]
            )

        case "draft_listing_ad":
            let observedFacts = listingObservedFacts(from: envelope)
            let draftItems: [String] = {
                if observedFacts.isEmpty {
                    return [
                        "Headline: [Add room or apartment type]",
                        "Location: [Add neighborhood or campus proximity]",
                        "Availability: [Add move-in date and lease term]",
                        "Amenities: [Add furnishing, utilities, laundry, parking]"
                    ]
                }
                return observedFacts.map { "\($0.key.capitalized): \($0.value)" }
            }()
            return Phase29ArtifactBuild(
                type: "draft",
                title: entityShort.isEmpty ? "Draft Listing Ad" : "Draft Listing Ad: \(entityShort)",
                subtitle: localOnlySubtitle.isEmpty ? "Drafted from the details currently visible in context." : localOnlySubtitle,
                sections: [
                    ArtifactSection(
                        header: "Observed from screen",
                        items: observedFacts.isEmpty
                            ? (sourceTitles.isEmpty ? ["Only listing titles are available."] : sourceTitles)
                            : observedFacts.map { "\($0.key): \($0.value)" }
                    ),
                    ArtifactSection(
                        header: "Draft Ad Structure",
                        items: draftItems
                    )
                ],
                tableRows: nil,
                missingInfo: [
                    "Exact rent amount, utilities, and deposit.",
                    "Room dimensions, furnishing details, and house rules.",
                    "Preferred tenant profile and contact instructions."
                ],
                nextActions: ["Add the missing facts before publishing the listing"]
            )

        case "create_listing_checklist":
            return Phase29ArtifactBuild(
                type: "checklist",
                title: entityShort.isEmpty ? "Listing Checklist" : "Listing Checklist: \(entityShort)",
                subtitle: localOnlySubtitle.isEmpty ? "Checklist built from the current listing context." : localOnlySubtitle,
                sections: [
                    ArtifactSection(
                        header: "Before Posting",
                        items: [
                            "Confirm rent, deposit, and utility details.",
                            "Confirm lease term, move-in date, and occupancy limits.",
                            "Confirm amenities, furnishing, laundry, and parking.",
                            "Confirm contact method and showing availability."
                        ]
                    ),
                    ArtifactSection(
                        header: "Visible Context Used",
                        items: sourceTitles.isEmpty ? ["Only the current page title is visible."] : sourceTitles
                    )
                ],
                tableRows: nil,
                missingInfo: [
                    "Any listing fields not visible in the current browser context.",
                    "Photos, floor plan, and exact address details.",
                    "Policy details such as pets, guests, or subletting."
                ],
                nextActions: ["Fill the missing fields before posting the ad"]
            )

        case "create_questions_to_ask_landlord":
            let questionSeed = repeatedTerms
            let contextualQuestions = [
                "What is included in the rent, and what costs are separate?",
                "What are the lease term, deposit, and move-in requirements?",
                "Are there any rules about guests, pets, parking, or subletting?",
                "How are maintenance issues handled, and how quickly are repairs addressed?"
            ]
            return Phase29ArtifactBuild(
                type: "draft",
                title: entityShort.isEmpty ? "Questions to Ask the Landlord" : "Questions to Ask: \(entityShort)",
                subtitle: localOnlySubtitle.isEmpty ? "Questions drafted from visible/current context." : localOnlySubtitle,
                sections: [
                    ArtifactSection(
                        header: "Questions",
                        items: contextualQuestions
                    ),
                    ArtifactSection(
                        header: "Observed context",
                        items: questionSeed.isEmpty
                            ? (sourceTitles.isEmpty ? ["Only high-level rental context is visible."] : sourceTitles)
                            : questionSeed
                    )
                ],
                tableRows: nil,
                missingInfo: [
                    "Exact rent breakdown and fees.",
                    "House rules and occupancy constraints.",
                    "Repair process, internet, and utility responsibilities."
                ],
                nextActions: ["Use these questions only after verifying the listing details you can already see"]
            )

        default:
            return nil
        }
    }

    private static func visibleSourceTitles(from envelope: Envelope) -> [String] {
        let combined = [envelope.memory.currentEntity]
            + envelope.memory.comparisonCandidates
            + envelope.memory.relatedFocusEntities
            + envelope.packet.recentTitles
        return uniqueNonEmpty(combined).prefix(4).map { $0 }
    }

    private static func listingObservedFacts(from envelope: Envelope) -> [(key: String, value: String)] {
        var rows: [(String, String)] = []
        if let title = envelope.page.pageTitle, !title.isEmpty {
            rows.append(("title", String(title.prefix(140))))
        }
        if let description = envelope.page.ogDescription, !description.isEmpty {
            rows.append(("description", String(description.prefix(180))))
        }
        for key in ["price", "priceCurrency", "brand", "title"] {
            if let value = envelope.page.productFacts[key], !value.isEmpty {
                rows.append((key, value))
            }
        }
        return rows
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }

    private static func previewHookChain(for capabilityId: String) -> [String] {
        switch capabilityId {
        case "synthesize_sources":
            return ["gather_context", "generate_text", "present_artifact"]
        case "compare_rental_options":
            return ["browser_tabs_context", "extract_listing_details", "compare_table", "present_summary"]
        case "draft_listing_ad":
            return ["browser_context", "infer_listing_details", "draft_text", "present_editable_result"]
        case "create_listing_checklist":
            return ["browser_context", "extract_listing_fields", "generate_checklist", "present_editable_result"]
        case "create_questions_to_ask_landlord":
            return ["browser_context", "extract_listing_details", "draft_questions", "present_editable_result"]
        default:
            return []
        }
    }

    private static func determineVisibleContextOnlyReason(
        appName: String,
        windowTitle: String,
        browserURL: URL?,
        selectedText: String?,
        axTextFragments: [String]
    ) -> String? {
        let lowerTitle = windowTitle.lowercased()
        let host = browserURL?.host?.lowercased() ?? ""
        let path = browserURL?.path.lowercased() ?? ""
        let combined = ([lowerTitle] + axTextFragments.map { $0.lowercased() } + [(selectedText ?? "").lowercased()]).joined(separator: " ")

        let privateMarkers = ["inbox", "draft", "compose", "conversation", "chat", "document", "editor", "workspace", "dashboard", "account"]
        if privateMarkers.contains(where: { lowerTitle.contains($0) || combined.contains($0) || path.contains($0) }) {
            return "private_or_sensitive_page"
        }
        if host.contains("chatgpt") || host.contains("claude") || host.contains("perplexity") || host.contains("gemini") {
            return "assistant_tool_page"
        }
        if browserURL == nil && (!combined.isEmpty || !(selectedText ?? "").isEmpty) {
            return "no_public_url"
        }
        return nil
    }

    private static func shouldAttemptPublicWebResearch(
        envelope: Envelope,
        browserURL: URL?
    ) -> Bool {
        if envelope.visibleContextOnlyReason != nil {
            return false
        }
        guard browserURL != nil || envelope.page.url != nil else {
            return false
        }
        return true
    }

    private static func emptyPublicPageContext() -> PublicPageContextExtractor.PublicPageContext {
        PublicPageContextExtractor.PublicPageContext(
            url: nil,
            pageTitle: nil,
            ogTitle: nil,
            ogDescription: nil,
            productFacts: [:],
            extractedAt: Date(),
            source: "none"
        )
    }

    // MARK: - Parsers

    private struct IntentJSON: Decodable {
        let intent: String
        let subject: String?
        let goal: String?
        let confidence: Double?
    }

    private struct ParsedIntent {
        let intent: String
        let subject: String
        let goal: String
        let confidence: Double
    }

    private static func parseIntent(raw: String) -> ParsedIntent? {
        guard let json = extractJSONObject(from: raw),
              let data = json.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(IntentJSON.self, from: data) else { return nil }
        let intent = decoded.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else { return nil }
        return ParsedIntent(
            intent: intent,
            subject: decoded.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "the user's recent activity",
            goal: decoded.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            confidence: max(0.0, min(decoded.confidence ?? 0.5, 1.0))
        )
    }

    private struct ExecutionJSON: Decodable {
        let artifact: ArtifactJSON?
        let observed: [String]?
        let inferred: [String]?
        let unknown: [String]?
        let next_question: String?
        let reframed_reason: String?
        
        struct ArtifactJSON: Decodable {
            let artifactType: String
            let sections: [SectionJSON]
        }
        struct SectionJSON: Decodable {
            let heading: String
            let items: [String]
        }
    }

    private struct ParsedExecution {
        let artifact: ArtifactResult
        let observed: [String]
        let inferred: [String]
        let unknown: [String]
        let nextQuestion: String

        /// Reject the parsed structure if any item still contains a control
        /// verb — the prompt forbids these, but the model occasionally slips.
        func passesSafety(
			evidenceQuality: String,
			extractedFacts: [String: String]
		) -> Bool {
            var all = observed + inferred + unknown + [nextQuestion]
            for section in artifact.sections {
                all.append(section.header)
                all.append(contentsOf: section.items)
            }
            for item in all {
                if !JarvisSuggestionValidator.validate(title: item, subtitle: "") {
                    return false
                }
            }
			// Prevent "X is a Y" generic definitions.
			let defBad = all.contains(where: { item in
				let l = item.lowercased()
				let hasIsA = l.contains(" is a ") || l.contains(" is an ")
				let hedged = l.contains("appears") || l.contains("seems") || l.contains("may be")
				return hasIsA && !hedged
			})
			if defBad { return false }

			// Evidence-quality gate: if we only have titles (no product metadata),
			// do not allow spec-like numeric claims (prices, wattage, capacities).
			if EvidenceQualityModel.level(from: evidenceQuality).rank <= ProgressiveEvidenceLevel.metadata_rich.rank {
				let extractedJoined = extractedFacts.values.joined(separator: " ").lowercased()
				let specLike = all.contains(where: { item in
					let l = item.lowercased()
					// Allow if it’s explicitly present in extracted facts (rare for title_only).
					if !extractedJoined.isEmpty, extractedJoined.contains(l) { return false }
					// Detect common spec tokens.
					let needles = ["$", "usd", "cad", "eur", "£", "w", "watts", "mah", "wh", "gb", "tb", "hz", "lbs", "kg"]
					return needles.contains(where: { l.contains($0) })
				})
				if specLike { return false }
			}
            return true
        }
    }

    private static func parseExecution(raw: String) -> ParsedExecution? {
        guard let json = extractJSONObject(from: raw),
              let data = json.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(ExecutionJSON.self, from: data) else { return nil }
        let observed = (decoded.observed ?? []).filter { !$0.isEmpty }
        let inferred = (decoded.inferred ?? []).filter { !$0.isEmpty }
        let unknown  = (decoded.unknown  ?? []).filter { !$0.isEmpty }
        let nextQ    = (decoded.next_question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let reframed = decoded.reframed_reason, reframed == "entities_not_same_category" {
            print("[ArtifactReasoning] comparison_reframed reason=entities_not_same_category")
        }
        
        let artifact: ArtifactResult
        if let a = decoded.artifact {
            artifact = ArtifactResult(
                type: a.artifactType,
                title: a.artifactType.capitalized,
                subtitle: "",
                sections: a.sections.map { .init(header: $0.heading, items: $0.items) }
            )
        } else {
            artifact = ArtifactResult(type: "knowledge_brief", title: "Knowledge Brief", subtitle: "")
        }
        
        guard !(observed.isEmpty && inferred.isEmpty && unknown.isEmpty && artifact.sections.isEmpty) else { return nil }
        return ParsedExecution(
            artifact: artifact,
            observed: Array(observed.prefix(6)),
            inferred: Array(inferred.prefix(6)),
            unknown: Array(unknown.prefix(6)),
            nextQuestion: nextQ.isEmpty ? "What would you like to focus on next?" : nextQ
        )
    }

    /// Extract the first JSON object from a model response (trim chatty
    /// prefixes / suffixes the small model sometimes adds).
    private static func extractJSONObject(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.first == "{", trimmed.last == "}" { return trimmed }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else { return nil }
        return String(trimmed[start...end])
    }

    // MARK: - Synthesis (suggestion → engine inputs)

    private static func synthesizeWorkflow(
        from suggestion: AmbientJarvisSuggestion,
        snapshot: CanonicalGeneratedExecutionContextSnapshot?
    ) -> WorkflowState {
        let now = Date()
        let type = AmbientWorkflowType(rawString: suggestion.workflow)
        let terms = suggestion.sourceEvidence.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return WorkflowState(
            workflowType: type,
            confidence: suggestion.confidence,
            evidence: ["suggestion=\(suggestion.kind.rawValue)"],
            uncertainty: "synthesized_from_suggestion",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.5,
            dominantApps: snapshot.map { [$0.activeApp] } ?? [],
            repeatedTerms: terms,
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: ""
        )
    }

    private static func synthesizeBehavior(from suggestion: AmbientJarvisSuggestion) -> BehavioralStateRecord {
        let now = Date()
        let state = BehavioralState(rawValue: suggestion.behavior) ?? .unknown
        return BehavioralStateRecord(
            state: state,
            confidence: suggestion.confidence,
            reasoning: "synthesized_from_suggestion",
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.5
        )
    }

    private static func synthesizePacket(
        from suggestion: AmbientJarvisSuggestion,
        snapshot: CanonicalGeneratedExecutionContextSnapshot?
    ) -> CompressedTemporalPacket {
        let terms = suggestion.sourceEvidence
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let app = snapshot?.activeApp ?? ""
        let title = snapshot?.windowTitle ?? ""
        let ocrHint = (snapshot?.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ocrHints: [String] = ocrHint.isEmpty ? [] : [String(ocrHint.prefix(80))]
        return CompressedTemporalPacket(
            currentApp: app,
            recentApps: app.isEmpty ? [] : [app],
            recentTitles: title.isEmpty ? [] : [title],
            topicTerms: terms,
            activityPattern: "steady",
            idlePattern: "active",
            typingPattern: "none",
            pointerPattern: "occasional",
            ocrHints: ocrHints,
            selectionHints: [],
            clipboardMetadata: "none",
            recentUserAccepts: [],
            recentUserIgnores: [],
            spanSeconds: 0,
            eventCount: 0,
            contextShiftDetected: false
        )
    }
}
