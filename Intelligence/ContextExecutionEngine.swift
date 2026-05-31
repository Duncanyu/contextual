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
        snapshot: CanonicalGeneratedExecutionContextSnapshot?
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
        
		let pageCtx = await PublicPageContextExtractor.shared.extract(
			windowTitle: windowTitle,
			axTextFragments: axFragments,
			clipboardText: snapshot?.clipboardText
		)

        // Phase 18C grounding fix — passive public-web enrichment runs BEFORE
        // intent inference so both stages can use the same enriched envelope.
        // Sensitive workflows + env disable + non-eligible terms all return
        // an empty WebContextEnrichment; downstream code never branches on it.
        let webEnrichment = await WebContextEnricher.shared.enrich(
            terms: packet.topicTerms,
            workflowType: workflow.workflowType
        )

        // Phase 20A Working Memory Generation
        let memory = WorkingMemoryBuilder.build(
            workflow: workflow,
            behavior: behavior,
            packet: packet
        )

        var envelope = Envelope(
            workflow: workflow,
            behavior: behavior,
            packet: packet,
            snapshot: snapshot,
            web: webEnrichment,
			page: pageCtx,
            memory: memory,
            judgment: .empty
        )

		var evidenceQuality: String = pageCtx.productFacts.isEmpty ? "title_only" : "product_metadata"
		print("[ContextEvidence] quality=\(evidenceQuality)")

        // Stage 1 — intent inference.
        let intent = await inferIntent(envelope: envelope)
        let confStr = String(format: "%.2f", intent.confidence)
        print("[ContextExecutionEngine] stage1_intent=\(intent.intent) source=\(intent.source) confidence=\(confStr)")

        // Phase 19: Goal inference.
        let goal = await GoalInferenceEngine.inferGoal(
            workflow: workflow,
            behavior: behavior,
            packet: packet,
            snapshot: snapshot
        )

        // Public Web Research Enrichment (Phase 19 & 20C)
        if evidenceQuality == "title_only" {
            print("[ContextEvidence] attempting_public_web_research=yes")
            let searchTitles = !envelope.memory.comparisonCandidates.isEmpty ? envelope.memory.comparisonCandidates : packet.recentTitles
            let researchResult = await PublicWebResearchEnricher.shared.searchAndFetch(
                intent: intent.intent,
                intentGoal: intent.goal,
                workflow: workflow.workflowType,
                behavior: behavior.state,
                titles: searchTitles,
                terms: packet.topicTerms
            )
            envelope.webResearchFacts = researchResult.facts
            if !envelope.webResearchFacts.isEmpty {
                evidenceQuality = "public_web_research"
                print("[ContextEvidence] quality=\(evidenceQuality)")
            }
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
            evidenceQuality: evidenceQuality
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
    print("[ContextExecutionEngine] using_intent=\(suggestion.intent) goal=\"\(suggestion.intentGoal)\"")
        let workflow = synthesizeWorkflow(from: suggestion, snapshot: snapshot)
        let behavior = synthesizeBehavior(from: suggestion)
        let packet   = synthesizePacket(from: suggestion, snapshot: snapshot)
        return await execute(workflow: workflow, behavior: behavior, packet: packet, snapshot: snapshot)
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
        evidenceQuality: String
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
                        let pageMeta = renderPublicPageMetadata(envelope.page)
                        let productFacts = renderProductFacts(envelope.page)
                        // Phase 20D — if the judgment is invalid we override
                        // the artifact type even when the model produced one.
                        // Section content stays the model's; the rendered
                        // judgment line above the artifact tells the user why.
                        let finalArtifact: CognitiveArtifact = {
                            if envelope.judgment.comparisonValidity == .invalid,
                               parsed.artifact.artifactType != "clarification_brief" {
                                print("[ArtifactSelector] override=clarification_brief reason=model_attempted_invalid_comparison")
                                return CognitiveArtifact(artifactType: "clarification_brief", sections: parsed.artifact.sections)
                            }
                            return parsed.artifact
                        }()
                        return ContextExecutionResult(
                            intent: intent,
                            goalInference: goal,
                            cognitiveArtifact: finalArtifact,
                            judgment: envelope.judgment,
                            observed: parsed.observed,
                            inferred: parsed.inferred,
                            unknown: parsed.unknown,
                            nextQuestion: parsed.nextQuestion,
                            webContext: web,
                            publicPageMetadata: pageMeta,
                            extractedProductFacts: productFacts,
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
        return fallbackStructured(intent: intent, goal: goal, envelope: envelope, evidenceQuality: evidenceQuality)
    }

    private static func fallbackStructured(
        intent: InferredIntent,
        goal: GoalInference,
        envelope: Envelope,
        evidenceQuality: String
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

        // 2. Public web context — rendered as its own list passed to the
        //    result; no inference logic here.
        var webContext: [String] = envelope.web.entries.map { e in
            "[\(e.source)] \(e.title): \(e.extract)"
        }
        webContext.append(contentsOf: envelope.webResearchFacts.map { "[\($0.method)] \($0.sourceTitle): \($0.label) = \($0.value)" })

		let pageMeta = renderPublicPageMetadata(envelope.page)
		let productFacts = renderProductFacts(envelope.page)
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
        if quality == "title_only" && !envelope.hasOCRDetail && !envelope.hasSelectedText {
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

        // Phase 20D — artifact type is now derived from the JUDGMENT, not
        // from a goal-string switch. Section content comes from evidence
        // (observed + judgment.rationale + judgment.missingInformation),
        // not from canned strings per artifact type.
        let artifactType = ArtifactSelector.type(for: envelope.judgment)
        let sections = buildFallbackSections(
            artifactType: artifactType,
            judgment: envelope.judgment,
            observed: observed,
            inferred: inferred,
            unknown: unknown
        )

        let artifact = CognitiveArtifact(artifactType: artifactType, sections: sections)

        // Override next question if judgment is invalid — the brief requires
        // we ask the clarifying question rather than push a comparison.
        var finalNextQuestion = nextQuestion
        if envelope.judgment.comparisonValidity == .invalid {
            finalNextQuestion = "It looks like these items may serve different needs — what are you actually trying to accomplish here?"
        }

        return ContextExecutionResult(
            intent: intent,
            goalInference: goal,
            cognitiveArtifact: artifact,
            judgment: envelope.judgment,
            observed: observed,
            inferred: inferred,
            unknown: unknown,
            nextQuestion: finalNextQuestion,
            webContext: webContext,
			publicPageMetadata: pageMeta,
			extractedProductFacts: productFacts,
			evidenceQuality: quality,
            source: "fallback"
        )
    }

    /// Build the cognitive-artifact sections from judgment + evidence. No
    /// canned strings per artifact type — section CONTENT comes from
    /// `judgment.rationale` and `judgment.missingInformation`, plus the
    /// engine's already-collected observed/inferred/unknown bullets.
    private static func buildFallbackSections(
        artifactType: String,
        judgment: ContextJudgment,
        observed: [String],
        inferred: [String],
        unknown: [String]
    ) -> [CognitiveArtifact.ArtifactSection] {
        switch artifactType {
        case "clarification_brief":
            return [
                .init(heading: "What I noticed",
                      items: Array(observed.prefix(3))),
                .init(heading: "Why I can't directly compare these",
                      items: judgment.rationale.filter { !$0.hasPrefix("entities=") }),
                .init(heading: "What's missing",
                      items: judgment.missingInformation),
            ]
        case "recommendation_brief":
            return [
                .init(heading: "Items being compared",
                      items: judgment.entities.map { String($0.prefix(80)) }),
                .init(heading: "Shared dimensions worth comparing",
                      items: judgment.rationale.filter { $0.hasPrefix("dimensions=") || $0.hasPrefix("shared_concepts=") }),
                .init(heading: "Missing for a complete recommendation",
                      items: judgment.missingInformation),
            ]
        case "research_brief":
            return [
                .init(heading: "Main takeaways",
                      items: Array(observed.prefix(3))),
                .init(heading: "Shared concepts across sources",
                      items: judgment.rationale.filter { $0.hasPrefix("shared_concepts=") }),
                .init(heading: "Worth investigating next",
                      items: judgment.missingInformation),
            ]
        case "diagnostic_brief":
            return [
                .init(heading: "Strongest signals",
                      items: Array(observed.prefix(3))),
                .init(heading: "What's still unclear",
                      items: judgment.missingInformation),
            ]
        default: // knowledge_brief
            return [
                .init(heading: "Key signals",
                      items: Array(observed.prefix(2)) + Array(inferred.prefix(2))),
                .init(heading: "Likely questions",
                      items: Array(unknown.prefix(3))),
            ]
        }
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
        - evidence_quality=\(evidenceQuality). If title_only, do not compare specs.

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
        let artifact: CognitiveArtifact
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
                all.append(section.heading)
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
			if evidenceQuality == "title_only" {
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
        
        let artifact: CognitiveArtifact
        if let a = decoded.artifact {
            artifact = CognitiveArtifact(
                artifactType: a.artifactType,
                sections: a.sections.map { .init(heading: $0.heading, items: $0.items) }
            )
        } else {
            artifact = CognitiveArtifact(artifactType: "knowledge_brief", sections: [])
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
