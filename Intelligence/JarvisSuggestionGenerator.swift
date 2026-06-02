import Foundation

/// Phase 20D.5 — generator is now evidence-driven rather than
/// workflow-whitelist driven. Every suppression path emits a
/// `[JarvisSuppression]` log so no gate is silent, and a
/// `[JarvisPipeline]` decision line is emitted whether the suggestion is
/// shown or suppressed.
public struct JarvisSuggestionGenerator: Sendable {

    /// Confidence-floor on the workflow trust score. 0.50 is intentionally
    /// lower than the previous 0.60 so a stabilized debugging/research/
    /// studying/writing session can surface a suggestion before its trust
    /// score has fully matured.
    public static let trustScoreFloor: Double = 0.50

    public static func generate(
        workflowState: WorkflowState,
        behavioralRecord: BehavioralStateRecord,
        packet: CompressedTemporalPacket,
        recentTitles: [String],
        repeatedTerms: [String],
        forceShow: Bool = false,
        memory: WorkingMemorySnapshot? = nil,
        judgmentDecisionType: ContextJudgment.DecisionType? = nil,
        hasSelection: Bool = false,
        hasAXContent: Bool = false,
        hasErrorTerms: Bool = false,
        activeCompartment: TaskCompartment? = nil,
        determinerSignal: DeterminerSignal? = nil,
        topOpportunity: Opportunity? = nil      // Phase 22: OpportunityEngine output
    ) async -> AmbientJarvisSuggestion? {
        let cycleId = UUID().uuidString
        PerformanceBudgetManager.shared.beginAmbientCycle(id: cycleId)

        let workflow = workflowState.workflowType
        let behavior = behavioralRecord.state
        print("[JarvisSuggestionGenerator] started workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) force_show=\(forceShow)")

        // Phase 20D.5 — no more workflow whitelist. Workflows are only
        // suppressed when they are structurally meaningless for ambient
        // assistance: `unknown` or `idle`.
        // Phase 21.1 — DeterminerSignal overrides this gate when the
        // structural context (compartment/memory) is already strong enough.
        if workflow == .unknown || workflow == .idle {
            if let ds = determinerSignal, ds.actionable {
                print("[JarvisGate] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) determiner_actionable=yes domain=\(ds.inferredDomain.rawValue)")
                print("[JarvisPipeline] decision=shown reason=determiner_signal_sufficient")
                // Continue — do not suppress.
            } else {
                print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=workflow_not_actionable")
                print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=workflow_not_actionable")
                return nil
            }
        }

        // Phase 20D.5 — no more behavior whitelist. Behaviors are only
        // suppressed when they signal no engagement (`unknown` / `idle`).
        // Phase 21.1 — DeterminerSignal overrides this gate too.
        if behavior == .unknown || behavior == .idle {
            if let ds = determinerSignal, ds.actionable {
                // Already logged above or workflow was actionable; no double-log needed.
            } else {
                print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=behavior_not_actionable")
                print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=behavior_not_actionable")
                return nil
            }
        }

        // Phase 20I — Combined Trust (Task A)
        let workflowTrust = workflowState.workflowTrustScore
        let compartmentTrust = activeCompartment?.compartmentTrust ?? 0.0
        let memoryTrust = memory?.workingMemoryTrust ?? 0.0
        
        if let comp = activeCompartment {
            let trustStr = String(format: "%.2f", compartmentTrust)
            print("[CompartmentTrust] label=\"\(comp.label)\" trust=\(trustStr)")
        }
        
        let combinedTrust: Double
        if forceShow {
            combinedTrust = 1.0
        } else {
            // If workflow trust is low but compartment/memory are strong, we allow it.
            combinedTrust = max(workflowTrust, compartmentTrust, memoryTrust)
        }
        
        let wfStr = String(format: "%.2f", workflowTrust)
        let cpStr = String(format: "%.2f", compartmentTrust)
        let mmStr = String(format: "%.2f", memoryTrust)
        let cbStr = String(format: "%.2f", combinedTrust)
        print("[JarvisTrust] workflow=\(wfStr) compartment=\(cpStr) memory=\(mmStr) combined=\(cbStr)")

        if combinedTrust < Self.trustScoreFloor {
            print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=confidence_too_low trust=\(cbStr) floor=\(Self.trustScoreFloor)")
            print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=confidence_too_low")
            return nil
        }
        
        if compartmentTrust >= Self.trustScoreFloor {
             print("[JarvisPipeline] decision=shown reason=compartment_trust_sufficient")
        }

        // Context-sufficiency — need at least one repeated term or two
        // distinct titles. (This isn't workflow-specific; it just prevents
        // surfacing on a single uninteresting tick.) Manual invoke also
        // bypasses this gate.
        let hasRepeatedTerms = !repeatedTerms.isEmpty || !packet.topicTerms.isEmpty
        let hasRepeatedTitles = recentTitles.count > 1 || packet.recentTitles.count > 1
        if !forceShow && !hasRepeatedTerms && !hasRepeatedTitles {
            print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=insufficient_context")
            print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=insufficient_context")
            return nil
        }

        // Phase 20I — bounded cognitive action selection. Picks an
        // ActionIntent from multi-input signals (judgment + behavior +
        // selection + error hints + memory shape). No workflow→action map.
        let effectiveMemory = memory ?? WorkingMemorySnapshot(
            currentEntity: recentTitles.first ?? "Unknown",
            recentEntities: recentTitles,
            repeatedConcepts: repeatedTerms,
            inferredActivity: behavior.rawValue,
            comparisonCandidates: []
        )
        
        // Phase 21.2 — Failure 3: Blank/neutral tab guard (after memory is built).
        if let ds = determinerSignal, ds.reason == "blank_or_neutral_tab" {
            print("[JarvisSuppression] reason=blank_or_neutral_tab entity=\"\(effectiveMemory.currentEntity)\"")
            print("[JarvisPipeline] decision=suppressed reason=blank_or_neutral_tab")
            return nil
        }

        let evidenceQuality: String = {
            if hasSelection { return "selection" }
            if hasAXContent { return "ax_content" }
            if !effectiveMemory.relatedFocusEntities.isEmpty { return "browser_tabs" }
            return "title_only"
        }()

        let selection = CapabilitySelector.select(
            compartment: activeCompartment,
            workingMemory: effectiveMemory,
            evidenceQuality: evidenceQuality,
            currentApp: packet.currentApp,
            behavior: behavior,
            userInitiated: forceShow,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values),
            determinerSignal: determinerSignal
        )
        let actionIntent = selection.primary
        
        let aiConfStr = String(format: "%.2f", 0.90) // Intent confidence is now more stable in Phase 21
        print("[ActionIntent] inferred intent=\(actionIntent.id) workflow=\(workflow.rawValue) confidence=\(aiConfStr)")
        print("[ActionIntent] evidence_required=\(actionIntent.inputRequirements.joined(separator: ","))")
		print("[ActionIntent] target_entity=\"\(effectiveMemory.currentEntity.prefix(120))\"")

        // 2. Wording generation. The prompt now interpolates the workflow as
        // DATA — no per-workflow code path. The model is allowed to vary
        // wording across debugging / studying / research / shopping naturally.
        let promptTerms = effectiveMemory.repeatedConcepts
        let promptEntities = [effectiveMemory.currentEntity] + effectiveMemory.relatedFocusEntities
        let excludedBgEntities = effectiveMemory.backgroundEntities + effectiveMemory.staleEntities
        
        let allComps = await TaskCompartmentTracker.shared.compartments
        let bgComps = allComps.filter { $0.id != activeCompartment?.id }.map { $0.label }
        
        let globalTerms = Set(repeatedTerms.isEmpty ? packet.topicTerms : repeatedTerms)
        let excludedBgTerms = globalTerms.filter { !promptTerms.contains($0) }.sorted()
        
        print("[JarvisSuggestionGenerator] prompt_terms=\(promptTerms.joined(separator: ","))")
        print("[JarvisSuggestionGenerator] prompt_entities=\(promptEntities.joined(separator: ","))")
        print("[JarvisSuggestionGenerator] excluded_background_entities=\(excludedBgEntities.joined(separator: ","))")
        print("[JarvisSuggestionGenerator] excluded_background_terms=\(excludedBgTerms.joined(separator: ","))")

        // Payload Cache Check
        let compHash = activeCompartment?.id.hashValue ?? 0
        let focusHash = effectiveMemory.currentEntity.hashValue
        if let cachedPayload = PerformanceBudgetManager.shared.getCachedPayload(compartmentHash: compHash, focusHash: focusHash) {
            // Found a cached payload. Use opportunity capabilityId as intent when present,
            // so the execution engine routes to the correct artifact branch on acceptance.
            let cachedIntent = topOpportunity?.capabilityId ?? actionIntent.id
            let cachedTitle = topOpportunity?.title ?? actionIntent.label
            let suggestion = AmbientJarvisSuggestion(
                title: cachedTitle,
                subtitle: "Context-only — preview based on your recent activity.",
                whyNow: "\(behavior.rawValue) behavior in \(workflow.rawValue) workflow",
                workflow: workflow.rawValue,
                behavior: behavior.rawValue,
                confidence: max(workflowState.confidence, behavioralRecord.confidence),
                kind: .cognitive_action,
                intent: cachedIntent,
                intentConfidence: max(workflowState.confidence, behavioralRecord.confidence),
                intentGoal: "Bounded cognitive action (\(cachedIntent)) over recent \(workflow.rawValue) context. Output type: \(actionIntent.outputType).",
                targetEntity: effectiveMemory.currentEntity,
                executionMode: .context_only_preview,
                previewOnly: true,
                sourceEvidence: promptTerms.joined(separator: ","),
                contextPayload: cachedPayload,
                topOpportunity: topOpportunity
            )
            print("[JarvisRouting] kind=cognitive_action semantic_driver=action_opportunity")
            print("[JarvisSuggestionGenerator] generated kind=\(suggestion.kind.rawValue) intent=\(cachedIntent) title=\"\(suggestion.title)\" (cached)")
            return suggestion
        }

        var generatedTitle = ""
        let model = "qwen2.5:0.5b"

        // Phase 22 — OpportunityEngine title is authoritative.
        // When an opportunity is provided, use its deterministic action-verb title directly.
        // The model is only called to generate a richer subtitle explanation when budget allows.
        if let opp = topOpportunity {
            generatedTitle = opp.title
            print("[JarvisRouting] kind=cognitive_action semantic_driver=action_opportunity capability=\(opp.capabilityId)")
            print("[OpportunityEngine] top_title=\"\(opp.title)\"")
        } else if actionIntent.id == "compare_options" {
            // Legacy compare_options path — retained for backward compat
            let candidates = effectiveMemory.comparisonCandidates
            if candidates.count >= 2 {
                let cleanNames = candidates.map {
                    $0.replacingOccurrences(of: "Amazon.ca: Buy ", with: "")
                      .replacingOccurrences(of: " product page", with: "")
                }
                if cleanNames.count == 2 {
                    generatedTitle = "Compare \(cleanNames[0]) and \(cleanNames[1])?"
                } else {
                    let formatted = cleanNames.prefix(cleanNames.count - 1).joined(separator: ", ")
                                  + ", and " + cleanNames.last!
                    generatedTitle = "Compare \(formatted)?"
                }
            } else {
                generatedTitle = "Compare the options you're viewing"
            }
        } else {
            // Phase 22 — model is called to generate action-oriented subtitles, NOT observation titles.
            // The title MUST start with an action verb or the output is rejected.
            let canGenerate = PerformanceBudgetManager.shared.allowHeavyModelGeneration()
            let isAvailable = await ModelManager.shared.isGenerationAvailable()
            if canGenerate && isAvailable {
                let termsDesc = promptTerms.prefix(3).joined(separator: ", ")
                let titlesDesc = promptEntities.prefix(3).joined(separator: " | ")
                let intent = actionIntent.id
                let prompt = """
                You are a helpful assistant. Generate a SHORT action proposal (max 10 words) for what you can do for the user right now. Start with an ACTION VERB (Create, Generate, Summarize, Compare, Explain, Draft, Diagnose, Find, etc.). DO NOT start with "Looks like", "It seems", or any observation phrase.

                Context:
                - Task: \(intent)
                - Workflow: \(workflow.rawValue)
                - Behavior: \(behavior.rawValue)
                - Terms: \(termsDesc)
                - Titles: \(titlesDesc)

                Rules:
                - Start with an action verb.
                - Describe what you will DO, not what the user IS DOING.
                - Output one line only. No quotes.
                """

                do {
                    let raw = try await LocalAIClient.shared.generate(
                        prompt: prompt,
                        model: model,
                        numPredict: 24,
                        temperature: 0.3,
                        purpose: "jarvis_suggestion",
                        schema: nil
                    )
                    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                                     .replacingOccurrences(of: "\"", with: "")
                    // Validate: must pass OpportunityValidator (action verb, no observation prefix)
                    if !cleaned.isEmpty && cleaned.count < 140
                       && OpportunityValidator.validate(cleaned) {
                        generatedTitle = cleaned
                    }
                } catch {
                    print("[JarvisSuggestionGenerator] title generation failed, error=\(error)")
                }
            }
        }

        // Phase 22 — Fallback uses the opportunity title (deterministic) or actionIntent.label.
        // Either way the result is an action phrase, never an observation.
        if generatedTitle.isEmpty {
            generatedTitle = topOpportunity?.title ?? actionIntent.label
        }

        let subtitle = "Context-only — preview based on your recent activity."

        // Safety check.
        guard JarvisSuggestionValidator.validate(title: generatedTitle, subtitle: subtitle) else {
            print("[JarvisSuppression] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) reason=control_language_in_wording")
            print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=none judgment=none artifact=none decision=suppressed reason=control_language_in_wording")
            return nil
        }

        // Phase 21 — intent comes from CapabilitySelector; Phase 22 overrides with
        // the opportunity's capabilityId so the execution engine routes correctly.
        let intent = topOpportunity?.capabilityId ?? actionIntent.id
        let intentGoal = "Bounded cognitive action (\(intent)) over recent \(workflow.rawValue) context. Output type: \(actionIntent.outputType)."

        let payload = SuggestionContextPayload(
            taskCompartmentSnapshot: activeCompartment,
            workingMemorySnapshot: effectiveMemory,
            comparisonCandidates: effectiveMemory.comparisonCandidates,
            relatedFocusEntities: effectiveMemory.relatedFocusEntities,
            activeTerms: promptTerms,
            evidenceQuality: evidenceQuality,
            browserTabs: activeCompartment?.browserTabs.sorted() ?? [],
            actionIntent: intent
        )

        // Phase 22 — Build ActionCard. When an opportunity is available, its
        // capability drives primary/secondary/auxiliary. Falls back to CapabilitySelector.
        let registry = CognitiveCapabilityRegistry.shared
        let primaryAction: CognitiveCapability
        let secondaryAction: CognitiveCapability?
        let auxiliaryAction: CognitiveCapability?
        let cardKind: AmbientSuggestionKind

        if let opp = topOpportunity {
            primaryAction   = registry.get(opp.capabilityId) ?? actionIntent
            secondaryAction = opp.auxiliaryCapabilityIds.first.flatMap { registry.get($0) }
            auxiliaryAction = opp.auxiliaryCapabilityIds.dropFirst().first.flatMap { registry.get($0) }
            cardKind = opp.capabilityId.contains("play_") || opp.capabilityId.contains("timer")
                ? .comfort_action : .cognitive_action
        } else {
            primaryAction   = actionIntent
            secondaryAction = selection.secondary
            auxiliaryAction = selection.auxiliary
            cardKind = forceShow ? .user_initiated : .cognitive_action
        }

        let previewArtifact = ArtifactResult(
            type: primaryAction.outputType,
            title: generatedTitle,
            subtitle: intentGoal,
            confidence: max(workflowState.confidence, behavioralRecord.confidence)
        )
        let card = ActionCard(
            id: "ambient:\(intent):\(effectiveMemory.currentEntity.prefix(32).replacingOccurrences(of: " ", with: "_"))",
            title: generatedTitle,
            explanation: intentGoal,
            primaryAction: primaryAction,
            secondaryAction: secondaryAction,
            auxiliaryAction: auxiliaryAction,
            previewPayload: previewArtifact,
            evidenceNote: "evidence_quality=\(evidenceQuality)",
            confidence: max(workflowState.confidence, behavioralRecord.confidence)
        )
        // [ActionCard] logs emitted inside ActionCard.init
        print("[ActionCard] observation_only=no")
        print("[CognitiveOutput] format=\(primaryAction.outputType) intent=\(intent)")

        let suggestion = AmbientJarvisSuggestion(
            title: generatedTitle,
            subtitle: subtitle,
            whyNow: "\(behavior.rawValue) behavior in \(workflow.rawValue) workflow",
            workflow: workflow.rawValue,
            behavior: behavior.rawValue,
            confidence: max(workflowState.confidence, behavioralRecord.confidence),
            kind: cardKind,
			intent: intent,
			intentConfidence: max(workflowState.confidence, behavioralRecord.confidence),
			intentGoal: intentGoal,
			targetEntity: effectiveMemory.currentEntity,
            executionMode: .context_only_preview,
            previewOnly: true,
            sourceEvidence: promptTerms.joined(separator: ","),
            contextPayload: payload,
            actionCard: card,
            topOpportunity: topOpportunity
        )
        
        PerformanceBudgetManager.shared.setCachedPayload(compartmentHash: compHash, focusHash: focusHash, payload: payload)

        print("[JarvisSuggestionGenerator] generated kind=\(suggestion.kind.rawValue) intent=\(intent) title=\"\(suggestion.title)\"")
        print("[AmbientJarvisSuggestion] title=\"\(suggestion.title)\" intent=\(intent) output_type=\(actionIntent.outputType)")
        print("[JarvisPipeline] workflow=\(workflow.rawValue) behavior=\(behavior.rawValue) intent=\(intent) action_intent=\(actionIntent.id) judgment=upstream artifact=\(actionIntent.outputType) decision=shown reason=evidence_sufficient")
        return suggestion
    }
}

final class PerformanceBudgetManager: @unchecked Sendable {
    static let shared = PerformanceBudgetManager()
    
    // Config
    private let axCacheTTL: TimeInterval = 45.0
    private let suggestionPayloadCacheTTL: TimeInterval = 45.0
    
    // State
    private let axCache = ManagedCache<String, AXWindowContentContext>()
    private let payloadCache = ManagedCache<String, SuggestionContextPayload>()
    
    // Budget
    private let lock = NSLock()
    private var heavyGenerationsInCurrentCycle = 0
    private var currentCycleId = ""
    
    private init() {}
    
    func beginAmbientCycle(id: String) {
        lock.lock()
        defer { lock.unlock() }
        currentCycleId = id
        heavyGenerationsInCurrentCycle = 0
        print("[PerformanceBudget] cycle_started id=\(id)")
    }
    
    func allowHeavyModelGeneration() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let hot = ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious
        if hot {
            print("[PerformanceBudget] skipped reason=thermal_guard")
            print("[ModelBudget] skipped purpose=heavy_generation reason=thermal_guard")
            return false
        }
        
        if heavyGenerationsInCurrentCycle >= 1 {
            print("[PerformanceBudget] skipped reason=model_busy")
            print("[ModelBudget] skipped purpose=heavy_generation reason=cycle_limit")
            return false
        }
        heavyGenerationsInCurrentCycle += 1
        return true
    }
    
    // AX Cache
    func getCachedAX(app: String, url: String, title: String) -> AXWindowContentContext? {
        let key = "\(app)|\(url)|\(title)"
        if let cached = axCache.get(key) {
            print("[ContextCache] hit key=\(key.hashValue)")
            return cached
        }
        print("[ContextCache] miss key=\(key.hashValue)")
        return nil
    }
    
    func setCachedAX(app: String, url: String, title: String, context: AXWindowContentContext) {
        let key = "\(app)|\(url)|\(title)"
        axCache.set(key, value: context, ttl: axCacheTTL)
    }
    
    // Payload Cache
    func getCachedPayload(compartmentHash: Int, focusHash: Int) -> SuggestionContextPayload? {
        let key = "\(compartmentHash)|\(focusHash)"
        if let cached = payloadCache.get(key) {
            print("[ContextCache] hit key=payload_\(key)")
            return cached
        }
        print("[ContextCache] miss key=payload_\(key)")
        return nil
    }
    
    func setCachedPayload(compartmentHash: Int, focusHash: Int, payload: SuggestionContextPayload) {
        let key = "\(compartmentHash)|\(focusHash)"
        payloadCache.set(key, value: payload, ttl: suggestionPayloadCacheTTL)
    }
    
    func logAllowed(ax: Bool, model: Bool, ocr: Bool, visual: Bool) {
        print("[PerformanceBudget] allowed ax=\(ax ? "yes" : "no") model=\(model ? "yes" : "no") ocr=\(ocr ? "yes" : "no") visual=\(visual ? "yes" : "no")")
    }
}

// Simple thread-safe cache
private final class ManagedCache<K: Hashable, V>: @unchecked Sendable {
    private struct Entry {
        let value: V
        let expiry: Date
    }
    
    private let lock = NSLock()
    private var store = [K: Entry]()
    
    func get(_ key: K) -> V? {
        lock.lock()
        defer { lock.unlock() }
        if let entry = store[key] {
            if Date() < entry.expiry {
                return entry.value
            } else {
                store.removeValue(forKey: key)
            }
        }
        return nil
    }
    
    func set(_ key: K, value: V, ttl: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        store[key] = Entry(value: value, expiry: Date().addingTimeInterval(ttl))
    }
}
