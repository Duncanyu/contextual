import Foundation

/// Stage-2 output from the `ContextExecutionEngine`. The structure is fixed
/// across every workflow on purpose — the explicit Observed / Web /
/// Inferred / Unknown split is what prevents the model from inventing facts.
public struct ContextExecutionResult: Sendable, Codable, Equatable {
    /// The Stage-1 intent that produced this result.
    public let intent: InferredIntent

    /// Phase 19: Inferred goal and generated cognitive artifact.
    public let goalInference: GoalInference
    public let cognitiveArtifact: ArtifactResult
    public let actionCard: ActionCard?

    /// Phase 20D: The engine's judgment about evidence quality and
    /// comparison validity. Rendered above the artifact (one line) so the
    /// user can see *why* the artifact takes the shape it does.
    public let judgment: ContextJudgment

    /// Items that appear verbatim or paraphrase what is in the context packet
    /// (titles, apps, repeated terms, OCR hints).
    public let observed: [String]

    /// Cautious interpretations derived from observation. These items use
    /// hedging language ("appears", "may", "seems") rather than asserting.
    public let inferred: [String]

    /// Explicit gaps — things the engine does NOT know because they are not
    /// present in the supplied context.
    public let unknown: [String]

    /// A single short question the user could answer to clarify the situation.
    public let nextQuestion: String

    /// Public-web research facts (if enrichment fired). ALWAYS rendered
    /// in its own labelled section so it is never confused with on-screen
    /// observation. Empty when enrichment was skipped or returned nothing.
    public let webContext: [PublicWebResearchEnricher.PublicGroundedFact]

	/// Public page metadata extracted from a public URL (OpenGraph/JSON-LD), if available.
	public let publicPageMetadata: PublicPageContextExtractor.PublicPageContext?

	/// Explicitly extracted product facts (JSON-LD Product fields only), if available.
	public let extractedProductFacts: [String: String]

	/// Coarse evidence quality gate used to keep outputs conservative.
	/// "title_only" | "product_metadata"
	public let evidenceQuality: String

    /// `model` when the local model produced this structured payload,
    /// `fallback` when the engine assembled it deterministically from context
    /// signals.
    public let source: String

    public let executedAt: Date

    public init(
        intent: InferredIntent,
        goalInference: GoalInference,
        cognitiveArtifact: ArtifactResult,
        actionCard: ActionCard? = nil,
        judgment: ContextJudgment = .empty,
        observed: [String],
        inferred: [String],
        unknown: [String],
        nextQuestion: String,
        webContext: [PublicWebResearchEnricher.PublicGroundedFact] = [],
        publicPageMetadata: PublicPageContextExtractor.PublicPageContext? = nil,
        extractedProductFacts: [String: String] = [:],
        evidenceQuality: String = "unknown",
        source: String = "unknown",
        executedAt: Date = Date()
        ) {
        self.intent = intent
        self.goalInference = goalInference
        self.cognitiveArtifact = cognitiveArtifact
        self.actionCard = actionCard
        self.judgment = judgment
        self.observed = observed
        self.inferred = inferred
        self.unknown = unknown
        self.nextQuestion = nextQuestion
        self.webContext = webContext
        self.publicPageMetadata = publicPageMetadata
        self.extractedProductFacts = extractedProductFacts
        self.evidenceQuality = evidenceQuality
        self.source = source
        self.executedAt = executedAt
        }

    /// Plain-text rendering for the assistant panel.
    /// Phase 19: Prioritizes the Cognitive Artifact.
    public func render() -> String {
        func bullet(_ items: [String]) -> String {
            guard !items.isEmpty else { return "- (none)" }
            return items.map { "- \($0)" }.joined(separator: "\n")
        }
        var sections: [String] = []
        
        // 1. Intent & Goal
        sections.append("""
        Intent: \(intent.intent)
        Goal: \(goalInference.goal)
        """)
        // Phase 20D — surface the engine's own judgment one line above the
        // artifact, but only when it is *not* a clean direct comparison.
        // For valid direct comparisons we stay quiet — no need to explain.
        if judgment.comparisonValidity != .direct {
            sections.append("""
            Judgment: relationship=\(judgment.relationship.rawValue); comparison_validity=\(judgment.comparisonValidity.rawValue); decision_type=\(judgment.decisionType.rawValue)
            """)
        }
        
        // 2. Cognitive Artifact
        sections.append(cognitiveArtifact.render())
        
        // 3. Grounded Evidence (Secondary)
        sections.append("""
        ---
        Observed from screen:
        \(bullet(observed))
        """)
        
        if let pm = publicPageMetadata {
            let pmStrings = pm.productFacts.map { "\($0.key): \($0.value)" }
            sections.append("""
            Public page metadata:
            \(pmStrings.isEmpty ? (pm.pageTitle ?? "Unknown Page") : bullet(pmStrings))
            """)
        }

        if !webContext.isEmpty {
            let webStrings = webContext.map { "[\($0.method)] \($0.sourceTitle): \($0.label) = \($0.value)" }
            sections.append("""
            Public web context (sourced externally):
            \(bullet(webStrings))
            """)
        }
        
        sections.append("""
        Possibly inferred:
        \(bullet(inferred))
        """)
        sections.append("""
        Not enough information:
        \(bullet(unknown))
        """)
        
        sections.append("""
        Useful next question:
        \(nextQuestion)
        """)
        
        return sections.joined(separator: "\n\n")
    }
}
import Foundation

public struct ArtifactSection: Sendable, Codable, Equatable {
    public let header: String
    public let items: [String]
    
    public init(header: String, items: [String]) {
        self.header = header
        self.items = items
    }
}

public struct ArtifactCard: Sendable, Codable, Equatable {
    public let title: String
    public let description: String
    public let tags: [String]
    
    public init(title: String, description: String, tags: [String]) {
        self.title = title
        self.description = description
        self.tags = tags
    }
}

public struct ArtifactResult: Sendable, Codable, Equatable {
    public let type: String
    public let title: String
    public let subtitle: String
    public let sections: [ArtifactSection]
    public let primaryCards: [ArtifactCard]
    public let tableRows: [[String]]?
    public let missingInfo: [String]
    public let confidence: Double
    public let nextActions: [String]
    
    public init(
        type: String,
        title: String,
        subtitle: String,
        sections: [ArtifactSection] = [],
        primaryCards: [ArtifactCard] = [],
        tableRows: [[String]]? = nil,
        missingInfo: [String] = [],
        confidence: Double = 0.5,
        nextActions: [String] = []
    ) {
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
        self.primaryCards = primaryCards
        self.tableRows = tableRows
        self.missingInfo = missingInfo
        self.confidence = confidence
        self.nextActions = nextActions
    }

    public func render() -> String {
        print("[ArtifactRender] type=\(type)")
        print("[ArtifactRender] sections=\(sections.count)")
        print("[ArtifactRender] table=\(tableRows != nil ? "yes" : "no")")
        print("[ArtifactRender] readable=yes")
        
        var out = [String]()
        out.append("# \(title)")
        if !subtitle.isEmpty { out.append("_\(subtitle)_") }
        
        for card in primaryCards {
            out.append("### \(card.title)")
            out.append("\(card.description) [\(card.tags.joined(separator: ", "))]")
        }
        
        if let rows = tableRows {
            for row in rows {
                out.append("| " + row.joined(separator: " | ") + " |")
            }
        }
        
        for sec in sections {
            out.append("## \(sec.header)")
            for item in sec.items {
                out.append("- \(item)")
            }
        }
        
        if !missingInfo.isEmpty {
            out.append("## Missing Info")
            for m in missingInfo {
                out.append("- \(m)")
            }
        }
        
        if !nextActions.isEmpty {
            out.append("## Next Actions")
            for a in nextActions {
                out.append("- \(a)")
            }
        }
        
        return out.joined(separator: "\n\n")
    }
}
import Foundation

public enum ExecutionMode: String, Codable, Sendable {
    case preview_only = "preview_only"
    case local_action = "local_action"
    case external_action = "external_action"
}

public enum RiskLevel: String, Codable, Sendable {
    case read_only = "read_only"
    case light_action = "light_action"
    case destructive = "destructive"
}

public enum PrivacyLevel: String, Codable, Sendable {
    case local = "local"
    case shareable = "shareable"
}

public struct CognitiveCapability: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let inputRequirements: [String]
    public let outputType: String
    public let evidenceThreshold: String
    public let privacyLevel: PrivacyLevel
    public let riskLevel: RiskLevel
    public let requiresConfirmation: Bool
    public let executionMode: ExecutionMode
    
    public init(
        id: String,
        label: String,
        inputRequirements: [String],
        outputType: String,
        evidenceThreshold: String,
        privacyLevel: PrivacyLevel = .local,
        riskLevel: RiskLevel = .read_only,
        requiresConfirmation: Bool = false,
        executionMode: ExecutionMode = .preview_only
    ) {
        self.id = id
        self.label = label
        self.inputRequirements = inputRequirements
        self.outputType = outputType
        self.evidenceThreshold = evidenceThreshold
        self.privacyLevel = privacyLevel
        self.riskLevel = riskLevel
        self.requiresConfirmation = requiresConfirmation
        self.executionMode = executionMode
    }
}

public final class CognitiveCapabilityRegistry: Sendable {
    public static let shared = CognitiveCapabilityRegistry()
    
    public let capabilities: [String: CognitiveCapability]
    
    private init() {
        var caps = [String: CognitiveCapability]()
        
        // Read-only cognitive
        let cognitiveList = [
            CognitiveCapability(id: "summarize_context", label: "Summarize context", inputRequirements: ["recent_titles"], outputType: "summary", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "explain_context", label: "Explain context", inputRequirements: ["recent_titles"], outputType: "explanation", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "compare_options", label: "Compare options", inputRequirements: ["comparison_candidates"], outputType: "comparison_table", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "decision_matrix", label: "Create decision matrix", inputRequirements: ["comparison_candidates"], outputType: "matrix", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "generate_quiz", label: "Generate quiz", inputRequirements: ["ax_content"], outputType: "quiz", evidenceThreshold: "ax_content"),
            CognitiveCapability(id: "create_checklist", label: "Create checklist", inputRequirements: ["recent_titles"], outputType: "checklist", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "create_outline", label: "Create outline", inputRequirements: ["recent_titles"], outputType: "outline", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "create_review_plan", label: "Create review plan", inputRequirements: ["recent_titles"], outputType: "plan", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "diagnose_error", label: "Diagnose error", inputRequirements: ["recent_titles", "repeated_terms"], outputType: "explanation", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "extract_action_items", label: "Extract action items", inputRequirements: ["recent_titles"], outputType: "checklist", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "draft_reply", label: "Draft reply", inputRequirements: ["recent_titles"], outputType: "rewrite", evidenceThreshold: "title_only", requiresConfirmation: true),
            CognitiveCapability(id: "improve_text", label: "Improve text", inputRequirements: ["selection"], outputType: "rewrite", evidenceThreshold: "selection"),
            CognitiveCapability(id: "rewrite_text", label: "Rewrite text", inputRequirements: ["selection"], outputType: "rewrite", evidenceThreshold: "selection"),
            CognitiveCapability(id: "synthesize_sources", label: "Synthesize sources", inputRequirements: ["recent_titles"], outputType: "summary", evidenceThreshold: "browser_tabs"),
            // Phase 21.1 — Creative coding / project capabilities
            CognitiveCapability(id: "improve_project", label: "Improve project", inputRequirements: ["recent_titles"], outputType: "suggestions", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "debug_performance", label: "Debug performance", inputRequirements: ["recent_titles", "repeated_terms"], outputType: "explanation", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "create_game_design_checklist", label: "Create game design checklist", inputRequirements: ["recent_titles"], outputType: "checklist", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "explain_how_to_make_faster", label: "Explain how to make it faster", inputRequirements: ["recent_titles"], outputType: "explanation", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "summarize_reference", label: "Summarize reference material", inputRequirements: ["recent_titles"], outputType: "summary", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "create_next_steps", label: "Create next steps", inputRequirements: ["recent_titles"], outputType: "checklist", evidenceThreshold: "title_only"),
            // Phase 22 — OpportunityEngine capabilities
            CognitiveCapability(id: "create_study_outline", label: "Create study outline", inputRequirements: ["recent_titles"], outputType: "outline", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "generate_test_checklist", label: "Create testing checklist", inputRequirements: ["recent_titles"], outputType: "checklist", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "compare_rental_options", label: "Compare rental options", inputRequirements: ["recent_titles", "browser_tabs"], outputType: "comparison_table", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "draft_listing_ad", label: "Draft listing ad", inputRequirements: ["recent_titles", "browser_tabs"], outputType: "draft", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "create_listing_checklist", label: "Create listing checklist", inputRequirements: ["recent_titles", "browser_tabs"], outputType: "checklist", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "extract_pricing_guidance", label: "Extract pricing guidance", inputRequirements: ["recent_titles", "browser_tabs"], outputType: "summary", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "identify_missing_listing_details", label: "Identify missing listing details", inputRequirements: ["recent_titles", "browser_tabs"], outputType: "checklist", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "create_questions_to_ask_landlord", label: "Create landlord questions", inputRequirements: ["recent_titles", "browser_tabs"], outputType: "draft", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "compare_listing_platforms", label: "Compare listing platforms", inputRequirements: ["recent_titles", "browser_tabs"], outputType: "comparison_table", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "summarize_thread", label: "Summarize thread", inputRequirements: ["recent_titles", "browser_tabs"], outputType: "summary", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "synthesize_advice", label: "Synthesize advice", inputRequirements: ["recent_titles", "browser_tabs"], outputType: "summary", evidenceThreshold: "browser_tabs")
        ]

        for c in cognitiveList { caps[c.id] = c }
        
        // Light local system actions
        let localList = [
            CognitiveCapability(id: "play_focus_media", label: "Play focus media", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "pause_media", label: "Pause media", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action),
            CognitiveCapability(id: "suggest_focus_playlist", label: "Suggest focus playlist", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .preview_only),
            CognitiveCapability(id: "enable_reduce_interruptions", label: "Enable Reduce Interruptions", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "launch_recent_workspace", label: "Launch recent workspace", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "open_related_app_set", label: "Open related app set", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "open_relevant_app", label: "Open relevant app", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "start_focus_timer", label: "Start focus timer", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "copy_current_url", label: "Copy current URL", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action),
            CognitiveCapability(id: "copy_all_related_links", label: "Copy all related links", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action),
            CognitiveCapability(id: "copy_result_to_clipboard", label: "Copy to clipboard", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action),
            // Part I: clearer user-facing labels
            CognitiveCapability(id: "remember_workspace", label: "Save current app/window setup", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action),
            CognitiveCapability(id: "open_current_task_panel", label: "Open task panel", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action)
        ]
        
        for c in localList { caps[c.id] = c }

        // Phase 26.1 — Friction-reduction capabilities (environment actions, not text generation)
        let frictionList = [
            CognitiveCapability(id: "collect_references", label: "Collect references", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: false, executionMode: .local_action),
            CognitiveCapability(id: "pin_reference_tabs", label: "Collect repeated tabs", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "restore_research_tabs", label: "Restore research tabs", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "restore_workspace", label: "Restore workspace", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "arrange_side_by_side", label: "Arrange side by side", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "switch_to_paired_app", label: "Switch to paired app", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "split_research_setup", label: "Split research setup", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "resume_focus_media", label: "Resume focus media", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "extract_and_organize", label: "Extract and organize", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: false, executionMode: .local_action),
            CognitiveCapability(id: "precompute_answer", label: "Pre-load answer", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .read_only, requiresConfirmation: false, executionMode: .preview_only),
        ]

        for c in frictionList { caps[c.id] = c }

        self.capabilities = caps
        
        print("[CapabilityRegistry] loaded count=\(caps.count)")
        for c in caps.values.sorted(by: { $0.id < $1.id }) {
            print("[Capability] id=\(c.id) mode=\(c.executionMode.rawValue) risk=\(c.riskLevel.rawValue) confirmation=\(c.requiresConfirmation ? "yes" : "no")")
        }
    }
    
    public func get(_ id: String) -> CognitiveCapability? {
        capabilities[id]
    }
}
import Foundation

public struct SelectedCapability: Sendable, Codable, Equatable {
    public let primary: CognitiveCapability
    public let secondary: CognitiveCapability?
    public let auxiliary: CognitiveCapability?
    public let reason: String
}

public enum CapabilitySelector {

    public static func select(
        compartment: TaskCompartment?,
        workingMemory: WorkingMemorySnapshot,
        evidenceQuality: String,
        currentApp: String,
        behavior: BehavioralState,
        userInitiated: Bool,
        availableCapabilities: [CognitiveCapability],
        determinerSignal: DeterminerSignal? = nil,
        entityGrounding: EntityGrounding? = nil,
        topOpportunity: Opportunity? = nil
    ) -> SelectedCapability? {
        print("[CapabilitySelector] evidence_quality=\(evidenceQuality)")

        // Phase 26.4 — Disable CapabilitySelector fallback when:
        // - no topOpportunity exists
        // - and any safety block matches: grounding shouldNotPropose, title_only/browser_tabs quality, watching/entertainment, unknown workflow/domain
        let domainRaw = determinerSignal?.inferredDomain.rawValue ?? "unknown"
        let isWatchingOrEntertainment = domainRaw == "watching" || domainRaw == "entertainment" || entityGrounding?.isEntertainment == true
        let isWorkflowUnknown = compartment?.workflow == .unknown || compartment?.workflow == .idle || determinerSignal?.inferredDomain == .unknown
        let isTitleOrTabs = evidenceQuality == "title_only" || evidenceQuality == "browser_tabs"
        let groundingShouldNotPropose = entityGrounding?.shouldPropose == false

        if topOpportunity == nil && !userInitiated {
            if groundingShouldNotPropose || isTitleOrTabs || isWatchingOrEntertainment || isWorkflowUnknown {
                print("[CapabilitySelector] skipped reason=no_safe_opportunity")
                print("[JarvisSuppression] reason=no_safe_opportunity")
                return nil
            }
        }

        let registry = CognitiveCapabilityRegistry.shared

        // 1. Primary Action selection based on context
        let result: SelectedCapability = {

            // Phase 21.1 — DeterminerSignal domain takes highest priority so
            // creative_coding / researching sessions with workflow=unknown are
            // not routed to compare_options.
            if let ds = determinerSignal, ds.actionable {
                switch ds.inferredDomain {
                case .creative_coding:
                    print("[CapabilitySelector] domain_override=creative_coding mode=\(ds.inferredMode.rawValue)")
                    let primaryId: String = {
                        switch ds.inferredMode {
                        case .debugging:  return "debug_performance"
                        case .building:   return "improve_project"
                        default:          return "create_game_design_checklist"
                        }
                    }()
                    return SelectedCapability(
                        primary: registry.get(primaryId) ?? registry.get("improve_project")!,
                        secondary: registry.get("explain_how_to_make_faster"),
                        auxiliary: registry.get("create_next_steps"),
                        reason: "DeterminerSignal domain=creative_coding"
                    )

                case .studying:
                    print("[CapabilitySelector] domain_override=studying mode=\(ds.inferredMode.rawValue)")
                    let primaryId: String = {
                        switch evidenceQuality {
                        case "selection":   return "explain_context"
                        case "ax_content":  return "generate_quiz"
                        case "browser_tabs": return "synthesize_sources"
                        default:            return "create_review_plan"
                        }
                    }()
                    return SelectedCapability(
                        primary: registry.get(primaryId)!,
                        secondary: registry.get("create_checklist"),
                        auxiliary: registry.get("play_focus_media"),
                        reason: "DeterminerSignal domain=studying"
                    )

                case .researching:
                    print("[CapabilitySelector] domain_override=researching mode=\(ds.inferredMode.rawValue)")
                    return SelectedCapability(
                        primary: registry.get("summarize_reference") ?? registry.get("synthesize_sources")!,
                        secondary: registry.get("create_next_steps"),
                        auxiliary: registry.get("summarize_context"),
                        reason: "DeterminerSignal domain=researching"
                    )

                case .coding:
                    print("[CapabilitySelector] domain_override=coding mode=\(ds.inferredMode.rawValue)")
                    return SelectedCapability(
                        primary: ds.inferredMode == .debugging ? registry.get("diagnose_error")! : registry.get("create_checklist")!,
                        secondary: registry.get("explain_context"),
                        auxiliary: nil,
                        reason: "DeterminerSignal domain=coding"
                    )

                case .shopping:
                    // Only show compare_options when the mode confirms comparison intent.
                    print("[CapabilitySelector] domain_override=shopping mode=\(ds.inferredMode.rawValue)")
                    if ds.inferredMode == .comparing {
                        return SelectedCapability(
                            primary: registry.get("compare_options")!,
                            secondary: registry.get("decision_matrix"),
                            auxiliary: registry.get("copy_result_to_clipboard"),
                            reason: "DeterminerSignal domain=shopping mode=comparing"
                        )
                    }
                    return SelectedCapability(
                        primary: registry.get("summarize_context")!,
                        secondary: registry.get("create_checklist"),
                        auxiliary: nil,
                        reason: "DeterminerSignal domain=shopping mode=browsing"
                    )

                case .unknown:
                    // Phase 21.4 — Task F: Active unknown domain.
                    // User is clearly active but domain is unclassifiable.
                    // Route to create_next_steps (safe, non-presumptuous fallback)
                    // rather than suppressing or guessing. Only when ds.actionable
                    // is true (which requires activity signal in 21.4 gate).
                    print("[CapabilitySelector] domain=unknown activity=\(ds.inferredMode.rawValue)")
                    print("[CapabilitySelector] selected=create_next_steps reason=active_unknown_safe_fallback")
                    return SelectedCapability(
                        primary: registry.get("create_next_steps")!,
                        secondary: registry.get("summarize_context"),
                        auxiliary: registry.get("start_focus_timer"),
                        reason: "active_unknown_safe_fallback"
                    )

                default:
                    // For other domains fall through to existing heuristics below.
                    break
                }
            }

            // Error/Debugging (behavior-based fallback)
            if behavior == .debugging || workingMemory.repeatedConcepts.contains("error") {
                return SelectedCapability(
                    primary: registry.get("diagnose_error")!,
                    secondary: registry.get("create_checklist")!,
                    auxiliary: registry.get("play_focus_media"),
                    reason: "Debugging behavior detected"
                )
            }

            // Studying (behavior-based fallback)
            if behavior == .learning || (compartment?.workflow == .studying) {
                let primaryId: String = {
                    switch evidenceQuality {
                    case "selection":   return "explain_context"
                    case "ax_content":  return "generate_quiz"
                    case "browser_tabs": return "synthesize_sources"
                    default:            return "create_review_plan"
                    }
                }()
                return SelectedCapability(
                    primary: registry.get(primaryId)!,
                    secondary: registry.get("create_checklist"),
                    auxiliary: registry.get("play_focus_media"),
                    reason: "Studying context active"
                )
            }

            // Shopping (behavior-based fallback) — only when explicitly comparing
            if behavior == .comparing || (compartment?.workflow == .shopping) {
                return SelectedCapability(
                    primary: registry.get("compare_options")!,
                    secondary: registry.get("decision_matrix"),
                    auxiliary: registry.get("copy_result_to_clipboard"),
                    reason: "Shopping/Comparison detected"
                )
            }

            // Communicating
            if behavior == .reading && (currentApp.contains("Mail") || currentApp.contains("Slack") || currentApp.contains("Messages")) {
                return SelectedCapability(
                    primary: registry.get("draft_reply")!,
                    secondary: registry.get("extract_action_items"),
                    auxiliary: registry.get("start_focus_timer"),
                    reason: "Communication app active"
                )
            }

            // Writing
            if behavior == .writing {
                return SelectedCapability(
                    primary: evidenceQuality == "selection" ? registry.get("improve_text")! : registry.get("create_outline")!,
                    secondary: registry.get("summarize_context"),
                    auxiliary: registry.get("play_focus_media"),
                    reason: "Writing behavior detected"
                )
            }

            // Default/Research
            return SelectedCapability(
                primary: registry.get("summarize_context")!,
                secondary: registry.get("explain_context"),
                auxiliary: registry.get("start_focus_timer"),
                reason: "General research/browsing"
            )
        }()
        
        print("[CapabilitySelector] selected=\(result.primary.id) reason=\"\(result.reason)\" can_execute_now=\(result.primary.executionMode == .local_action ? "yes" : "no")")
        
        return result
    }
}
import Foundation
import AppKit
import ApplicationServices

public enum CapabilityExecutionStatus: String, Codable, Sendable {
    case previewGenerated = "preview_generated"
    case success = "success"
    // Part D: honest status — partial and alreadySatisfied must not collapse to success
    case partial = "partial"
    case alreadySatisfied = "already_satisfied"
    case unavailable = "unavailable"
    case cancelled = "cancelled"
    case blocked = "blocked"
    case openedSearch = "opened_search"
}

@MainActor
public final class CapabilityExecutor {
    public static let shared = CapabilityExecutor()

	struct LocalActionOutcome {
		let status: CapabilityExecutionStatus
		let verificationStatus: String
		let reason: String
	}

	struct TestHooks {
		var focusShortcutAvailable: (() -> Bool)?
		var runFocusShortcut: (() -> LocalActionOutcome)?
		var arrangeSideBySide: (([String], [String]) -> LocalActionOutcome)?
		var switchToPairedApp: (([String]) -> LocalActionOutcome)?
		var restoreWorkspace: (([String], [String]) -> LocalActionOutcome)?
		var restoreResearchTabs: (([String]) -> LocalActionOutcome)?
		var splitResearchSetup: ((String, [String]) -> LocalActionOutcome)?
		var openAppPair: (([String]) -> LocalActionOutcome)?
	}

	static var testHooks = TestHooks()
    private var cachedFocusShortcut: (name: String?, checkedAt: Date)?

    private init() {}

    private func hasTestHook(for capabilityID: String) -> Bool {
        switch capabilityID {
        case "arrange_side_by_side": return Self.testHooks.arrangeSideBySide != nil
        case "switch_to_paired_app": return Self.testHooks.switchToPairedApp != nil
        case "restore_workspace": return Self.testHooks.restoreWorkspace != nil
        case "split_research_setup": return Self.testHooks.splitResearchSetup != nil
        default: return false
        }
    }

    public func isFocusShortcutAvailable() async -> Bool {
        if let override = Self.testHooks.focusShortcutAvailable {
            return override()
        }
        return focusShortcut(named: "Contextual Focus On") != nil
    }
    
    public func execute(capability: CognitiveCapability, context: [String: Any]) async -> CapabilityExecutionStatus {
        let sourceSurface = (context["source_surface"] as? String) ?? "unknown"
        let proposalID = (context["proposal_id"] as? String) ?? "unknown"
        print("[CapabilityExecution] started id=\(capability.id) source_surface=\(sourceSurface)")
        print("[CapabilityExecution] proposal_id=\(proposalID) id=\(capability.id)")
        print("[CapabilityExecution] mode=\(capability.executionMode.rawValue) id=\(capability.id)")

        // Phase 36.1 — Live path enforcement at execution time.
        // Proposal-bound capabilities that arrive here without a target contract are blocked.
        // No runtime-discovery fallback. No silent app substitution.
        // (Test hooks bypass this gate so hook-based tests can still drive the capability code directly.)
        if LivePathEnforcer.requiresContract(capability.id) && !hasTestHook(for: capability.id) {
            let hasContract = context["targetContract"] is ActionTargetContract
            print("[LivePathEnforcement] capability=\(capability.id) path=executor contract_required=yes contract_present=\(hasContract ? "yes" : "no") allowed=\(hasContract ? "yes" : "no") surface=executor reason=\(hasContract ? "contract_present" : "missing_target_contract")")
            if !hasContract {
                print("[ActionPreflight] capability=\(capability.id) contract_id=missing status=blocked reason=missing_target_contract")
                print("[CapabilityExecution] completed status=unavailable id=\(capability.id) reason=missing_target_contract")
                return .unavailable
            }
        }

        if capability.requiresConfirmation {
            if context["confirmation_satisfied"] as? Bool == true {
                print("[CapabilityExecution] confirmation_satisfied=yes source=user_click")
            } else {
                // In a real app, this would trigger a UI prompt.
                print("[CapabilityExecution] confirmation_required=yes")
            }
        } else {
            print("[CapabilityExecution] confirmation_required=no")
        }
        
        switch capability.id {
        case "suggest_focus_playlist":
            print("[CapabilityExecution] status=preview_generated id=\(capability.id)")
            print("[CapabilityExecution] completed status=success id=\(capability.id) reason=preview_only")
            return .previewGenerated

        case "enable_reduce_interruptions":
            return enableReduceInterruptions(context: context)

        case "copy_result_to_clipboard":
            return copyToClipboard(context: context)
            
        case "start_focus_timer":
            return startFocusTimer(context: context)
            
        case "play_focus_media":
            return await playFocusMedia(context: context)

        case "launch_recent_workspace":
            return launchRecentWorkspace(context: context)

        case "open_related_app_set":
            return openCommonAppPair(context: context)
            
        case "pause_media":
            return await pauseMedia()
            
        case "open_relevant_app":
            return openRelevantApp(context: context)

        // Phase 26.1 — Friction-reduction executors
        case "collect_references":
            return collectReferences(context: context)

        case "pin_reference_tabs":
            return pinReferenceTabs(context: context)

        case "restore_research_tabs":
            return restoreResearchTabs(context: context)

        case "restore_workspace":
            return restoreWorkspace(context: context)

        case "arrange_side_by_side":
            return arrangeSideBySide(context: context)

        case "switch_to_paired_app":
            return switchToPairedApp(context: context)

        case "split_research_setup":
            return splitResearchSetup(context: context)

        case "resume_focus_media":
            return await playFocusMedia(context: context)

        case "extract_and_organize":
            return collectReferences(context: context)  // same collect logic

        case "precompute_answer":
            print("[CapabilityExecution] status=preview_generated id=precompute_answer")
            print("[CapabilityExecution] completed status=success id=precompute_answer reason=preview_only")
            return .previewGenerated

        // Phase 31 — New local actions
        case "open_paired_app":
            let appName = context["appName"] as? String ?? (context["apps"] as? [String])?.first ?? ""
            return Phase31LocalActions.openPairedApp(appName: appName, reason: "user_click")

        case "switch_to_last_task_window":
            let appName = context["appName"] as? String ?? (context["apps"] as? [String])?.first ?? ""
            let titleHint = context["windowTitleHint"] as? String
            return Phase31LocalActions.switchToLastTaskWindow(appName: appName, windowTitleSubstring: titleHint)

        case "copy_current_url":
            let url = context["url"] as? String
                ?? (context["tabURLs"] as? [String])?.first
                ?? currentBrowserContext()?.selectedURL?.absoluteString
                ?? currentBrowserContext()?.currentURL?.absoluteString
            let title = context["title"] as? String
                ?? (context["tabTitles"] as? [String])?.first
            return Phase31LocalActions.copyCurrentURL(url: url, title: title)

        case "copy_all_related_links":
            let urls = context["urls"] as? [String] ?? []
            let titles = context["titles"] as? [String] ?? context["tabTitles"] as? [String] ?? []
            return Phase31LocalActions.copyAllRelatedLinks(urls: urls, titles: titles)

        case "open_focus_shortcut_setup":
            return Phase31LocalActions.openFocusShortcutSetup()

        case "remember_workspace":
            return rememberWorkspace(context: context)

        case "open_current_task_panel":
            return openCurrentTaskPanel()

        default:
            if capability.executionMode == .preview_only {
                print("[CapabilityExecution] status=preview_generated id=\(capability.id)")
                print("[CapabilityExecution] completed status=success id=\(capability.id) reason=preview_only")
                return .previewGenerated
            }
            print("[CapabilityExecution] blocked reason=capability_unavailable")
            return .unavailable
        }
    }
    
    private func copyToClipboard(context: [String: Any]) -> CapabilityExecutionStatus {
        guard let text = context["text"] as? String else {
            print("[ActionExecution] capability=copy_result_to_clipboard")
            print("[ActionFailure] capability=copy_result_to_clipboard reason=missing_data")
            print("[ActionVerification] capability=copy_result_to_clipboard status=failed")
            print("[CapabilityExecution] blocked reason=missing_data")
            return .blocked
        }
        print("[ActionExecution] capability=copy_result_to_clipboard")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let copied = NSPasteboard.general.string(forType: .string) == text
        print("[ClipboardAction] status=\(copied ? "success" : "failed")")
        print("[ActionVerification] capability=copy_result_to_clipboard status=\(copied ? "success" : "failed")")
        print("[CapabilityExecution] completed status=success id=copy_result_to_clipboard")
        return copied ? .success : .blocked
    }

    private func rememberWorkspace(context: [String: Any]) -> CapabilityExecutionStatus {
        print("[PanelActionDescription] capability=remember_workspace label=\"Save current app/window setup\" description=\"Remembers the current app/window/tab setup for future restore/switch/arrange suggestions.\"")
        print("[ActionExecution] capability=remember_workspace")
        let runtime = WorkspaceRuntimeInventoryProvider.snapshot()
        let runtimeVisibleApps = Array(Set(runtime.visibleWindows.map(\.appName) + [runtime.frontmostAppName])).filter { !$0.isEmpty }
        let apps = (context["apps"] as? [String] ?? runtimeVisibleApps)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let urls = (context["tabURLs"] as? [String] ?? [])
        let tabTitles = (context["tabTitles"] as? [String] ?? runtime.browserTabTitles)
        let workflow = (context["workflow"] as? String)
            ?? (context["workflow"] as? AmbientWorkflowType)?.rawValue
            ?? "unknown"
        let compartment = (context["compartmentLabel"] as? String)
            ?? (context["workflow"] as? String)
            ?? (context["workflow"] as? AmbientWorkflowType)?.rawValue
            ?? "none"
        guard apps.count >= 2 || urls.count >= 1 || tabTitles.count >= 2 else {
            print("[ActionFailure] capability=remember_workspace reason=insufficient_workspace_context")
            print("[ActionVerification] capability=remember_workspace status=failed")
            print("[CapabilityExecution] completed status=unavailable id=remember_workspace reason=insufficient_workspace_context")
            return .unavailable
        }
        DurableMemory.shared.recordWorkspaceObservation(
            workflow: workflow,
            compartment: compartment,
            apps: apps,
            bundleIDs: runtime.runningApps.filter { apps.contains($0.appName) }.map(\.bundleID),
            urls: urls,
            tabTitles: tabTitles,
            windowTitle: context["windowTitle"] as? String,
            selectedTabTitle: tabTitles.first
        )
        print("[ActionVerification] capability=remember_workspace status=success")
        print("[CapabilityExecution] completed status=success id=remember_workspace reason=workspace_recorded")
        return .success
    }

    private func openCurrentTaskPanel() -> CapabilityExecutionStatus {
        print("[PanelActionDescription] capability=open_current_task_panel label=\"Open task panel\" description=\"Opens the Contextual assistant panel focused on the current inferred task.\"")
        print("[ActionExecution] capability=open_current_task_panel")
        NotificationCenter.default.post(name: .contextualOpenTaskPanel, object: nil)
        print("[ActionVerification] capability=open_current_task_panel status=success")
        print("[CapabilityExecution] completed status=success id=open_current_task_panel reason=panel_requested")
        return .success
    }
    
    private func startFocusTimer(context: [String: Any]) -> CapabilityExecutionStatus {
        // No timer service is wired in this build.
        // Returning .unavailable rather than faking success — honest about capability state.
        print("[CapabilityExecution] completed status=unavailable id=start_focus_timer reason=no_timer_service_wired")
        return .unavailable
    }

    private func enableReduceInterruptions(context: [String: Any]) -> CapabilityExecutionStatus {
        print("[ActionExecution] capability=enable_reduce_interruptions")
        // Phase 32.1: Detect shortcut availability with structured log
        let focusDetection = FocusShortcutDetector.detect()
        LiveActionPath.emit(capability: "enable_reduce_interruptions", route: "environment", executor: "FocusShortcut", snapshotAge: 0, hasTargets: focusDetection.available, hasURLs: false, willExecute: focusDetection.available, reason: focusDetection.available ? "shortcut_found" : "shortcut_missing")
        if let override = Self.testHooks.runFocusShortcut {
            let outcome = override()
            print("[FocusAction] method=shortcuts status=\(outcome.verificationStatus)")
            if outcome.status != .success {
                print("[ActionFailure] capability=enable_reduce_interruptions reason=\(outcome.reason)")
            }
            print("[ActionVerification] capability=enable_reduce_interruptions status=\(outcome.verificationStatus)")
            print("[CapabilityExecution] completed status=\(outcome.status.rawValue) id=enable_reduce_interruptions reason=\(outcome.reason)")
            return outcome.status
        }

        guard let shortcutName = focusShortcut(named: "Contextual Focus On") else {
            print("[FocusAction] method=shortcuts status=unavailable reason=shortcut_missing")
            print("[ActionFailure] capability=enable_reduce_interruptions reason=shortcut_missing")
            print("[ActionVerification] capability=enable_reduce_interruptions status=failed")
            print("[CapabilityExecution] completed status=unavailable id=enable_reduce_interruptions reason=shortcut_missing")
            return .unavailable
        }

        let result = runProcess("/usr/bin/shortcuts", arguments: ["run", shortcutName])
        let verification = result.success ? "success" : "failed"
        print("[FocusAction] method=shortcuts status=\(verification)")
        if !result.success {
            print("[ActionFailure] capability=enable_reduce_interruptions reason=shortcut_run_failed")
        }
        print("[ActionVerification] capability=enable_reduce_interruptions status=\(verification)")
        print("[CapabilityExecution] completed status=\(result.success ? CapabilityExecutionStatus.success.rawValue : CapabilityExecutionStatus.unavailable.rawValue) id=enable_reduce_interruptions reason=\(result.success ? "shortcut_ran" : "shortcut_run_failed")")
        return result.success ? .success : .unavailable
    }
    
    private func playFocusMedia(context: [String: Any]) async -> CapabilityExecutionStatus {
        print("[ActionExecution] capability=play_focus_media")
        let intent = context["musicIntent"] as? MusicIntent
        let (success, status, reason, actualName) = await MusicExecutor.play(intent: intent)
        if success {
            print("[MusicAction] action=\((intent?.action ?? .resume).rawValue) status=success")
            print("[ActionVerification] capability=play_focus_media status=success")
            print("[CapabilityExecution] completed status=success id=play_focus_media reason=\(reason)")
			if let name = actualName {
				let comp = context["compartment"] as? TaskCompartment
				let workflow = context["workflow"] as? AmbientWorkflowType ?? .unknown
				PlaylistMemory.shared.record(name: name, compartment: comp, workflow: workflow)
				let durableContext = DurableMemoryContext.build(
					workflow: workflow.rawValue,
					compartment: comp?.label,
					app: (context["apps"] as? [String])?.first ?? "music",
					activity: "active",
					browserType: nil
				)
				DurableMemory.shared.recordMusicPreference(playlist: name, context: durableContext, source: "accepted_action")
			}
            return .success
        }
        print("[MusicAction] action=\((intent?.action ?? .resume).rawValue) status=failed")
        print("[ActionFailure] capability=play_focus_media reason=\(reason)")
        print("[ActionVerification] capability=play_focus_media status=failed")
        print("[CapabilityExecution] completed status=\(status.rawValue) id=play_focus_media reason=\(reason)")
        return status
    }
    
    private func launchRecentWorkspace(context: [String: Any]) -> CapabilityExecutionStatus {
        return restoreWorkspace(context: context)
    }
    
    private func pauseMedia() async -> CapabilityExecutionStatus {
        let (success, reason) = await MusicExecutor.pause()
        if success {
            print("[CapabilityExecution] completed status=success id=pause_media reason=\(reason)")
            return .success
        }
        print("[CapabilityExecution] completed status=unavailable id=pause_media reason=\(reason)")
        return .unavailable
    }
    
    private func openRelevantApp(context: [String: Any]) -> CapabilityExecutionStatus {
        guard let appName = context["appName"] as? String else {
             return .blocked
        }

        print("[ActionExecution] capability=open_relevant_app")

        // Use modern API if possible, fallback to launchApplication for simplicity in this prototype
        if NSWorkspace.shared.launchApplication(appName) {
            print("[ActionVerification] capability=open_relevant_app status=success")
            print("[CapabilityExecution] completed status=success id=open_relevant_app")
            return .success
        }
        print("[ActionFailure] capability=open_relevant_app reason=failed_to_launch_app")
        print("[ActionVerification] capability=open_relevant_app status=failed")
        return .unavailable
    }

    // MARK: - Phase 26.1 — Friction action executors

    /// Collect current tab titles + URLs, format as markdown, copy to clipboard.
    private func collectReferences(context: [String: Any]) -> CapabilityExecutionStatus {
        print("[ActionExecution] capability=collect_references")
        let tabTitles = context["tabTitles"] as? [String] ?? []
        let tabURLs = context["tabURLs"] as? [String] ?? []
        let entity = context["entity"] as? String ?? ""
        let repeatedConcepts = context["repeatedConcepts"] as? [String] ?? []

        var lines: [String] = []
        if !entity.isEmpty {
            lines.append("# References: \(entity)")
        } else {
            lines.append("# Collected References")
        }
        lines.append("")

        // Pair titles with URLs where available
        let count = max(tabTitles.count, tabURLs.count)
        if count == 0 && repeatedConcepts.isEmpty {
            print("[ReferenceCollector] collected count=0")
            print("[ActionFailure] capability=collect_references reason=no_references_found")
            print("[ActionVerification] capability=collect_references status=failed")
            print("[CapabilityExecution] completed status=unavailable id=collect_references reason=no_references_found")
            return .unavailable
        }

        for i in 0..<count {
            let title = i < tabTitles.count ? tabTitles[i] : "Untitled"
            let url = i < tabURLs.count ? tabURLs[i] : nil
            if let url = url, !url.isEmpty {
                lines.append("- [\(title)](\(url))")
            } else {
                lines.append("- \(title)")
            }
        }

        if !repeatedConcepts.isEmpty {
            lines.append("")
            lines.append("## Related concepts")
            for concept in repeatedConcepts.prefix(8) {
                lines.append("- \(concept)")
            }
        }

        let markdown = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)

        print("[ReferenceCollector] collected count=\(count)")
        print("[ReferenceCollector] copied_to_clipboard=yes")
        print("[ActionVerification] capability=collect_references status=success")
        print("[CapabilityExecution] completed status=success id=collect_references")
        return .success
    }

    /// Pin reference tabs — not wired to browser pinning yet.
    /// Falls back to collecting repeated tab info to clipboard.
    private func pinReferenceTabs(context: [String: Any]) -> CapabilityExecutionStatus {
        return restoreResearchTabs(context: context)
    }

    private func restoreResearchTabs(context: [String: Any]) -> CapabilityExecutionStatus {
        print("[ActionExecution] capability=restore_research_tabs")
        let urls = resolvedTabURLs(from: context)
        if let override = Self.testHooks.restoreResearchTabs {
            let outcome = override(urls)
            print("[TabRestore] opened=\(urls.count)")
            print("[TabRestore] status=\(outcome.verificationStatus)")
            if outcome.status != .success {
                print("[ActionFailure] capability=restore_research_tabs reason=\(outcome.reason)")
            }
            print("[ActionVerification] capability=restore_research_tabs status=\(outcome.verificationStatus)")
            print("[CapabilityExecution] completed status=\(outcome.status.rawValue) id=restore_research_tabs reason=\(outcome.reason)")
            return outcome.status
        }

        guard !urls.isEmpty else {
            print("[ActionFailure] capability=restore_research_tabs reason=no_tab_urls")
            print("[ActionVerification] capability=restore_research_tabs status=failed")
            print("[CapabilityExecution] completed status=unavailable id=restore_research_tabs reason=no_tab_urls")
            return .unavailable
        }

        let browserApp = resolvedBrowserAppName(from: context)
        var opened = 0
        for urlString in urls {
            guard let url = URL(string: urlString), openURL(url, preferredAppName: browserApp) else { continue }
            opened += 1
        }
        let status = opened > 0 ? CapabilityExecutionStatus.success : .unavailable
        let verification = opened == urls.count ? "success" : (opened > 0 ? "partial" : "failed")
        print("[TabRestore] opened=\(opened)")
        print("[TabRestore] status=\(verification)")
        if opened == 0 {
            print("[ActionFailure] capability=restore_research_tabs reason=failed_to_open_urls")
        }
        print("[ActionVerification] capability=restore_research_tabs status=\(verification)")
        print("[CapabilityExecution] completed status=\(status.rawValue) id=restore_research_tabs reason=\(opened > 0 ? "opened_urls" : "failed_to_open_urls")")
        return status
    }

    private func restoreWorkspace(context: [String: Any]) -> CapabilityExecutionStatus {
        print("[ActionExecution] capability=restore_workspace")
        let apps = resolvedWorkspaceApps(from: context)
        let urls = resolvedTabURLs(from: context)
        LiveActionPath.emit(capability: "restore_workspace", route: "environment", executor: "WorkspaceRestore", snapshotAge: 0, hasTargets: !apps.isEmpty, hasURLs: !urls.isEmpty, willExecute: !apps.isEmpty || !urls.isEmpty, reason: "user_click")

        if let override = Self.testHooks.restoreWorkspace {
            let outcome = override(apps, urls)
            print("[WorkspaceRestore] apps=\(apps.joined(separator: ","))")
            print("[WorkspaceRestore] status=\(outcome.verificationStatus)")
            if outcome.status != .success {
                print("[ActionFailure] capability=restore_workspace reason=\(outcome.reason)")
            }
            print("[ActionVerification] capability=restore_workspace status=\(outcome.verificationStatus)")
            print("[CapabilityExecution] completed status=\(outcome.status.rawValue) id=restore_workspace reason=\(outcome.reason)")
            return outcome.status
        }

        guard !apps.isEmpty || !urls.isEmpty else {
            print("[ActionFailure] capability=restore_workspace reason=no_apps_or_urls")
            print("[ActionVerification] capability=restore_workspace status=failed")
            print("[CapabilityExecution] completed status=blocked id=restore_workspace reason=no_apps_or_urls")
            return .blocked
        }

        var openedApps = 0
        for app in apps where launchOrActivate(appName: app) {
            openedApps += 1
        }

        let browserApp = resolvedBrowserAppName(from: context)
        var openedURLs = 0
        for urlString in urls {
            guard let url = URL(string: urlString), openURL(url, preferredAppName: browserApp) else { continue }
            openedURLs += 1
        }

        let anySuccess = openedApps > 0 || openedURLs > 0
        let verification = (openedApps == apps.count && openedURLs == urls.count) ? "success" : (anySuccess ? "partial" : "failed")
        print("[WorkspaceRestore] apps=\(apps.joined(separator: ","))")
        print("[WorkspaceRestore] status=\(verification)")
        if !anySuccess {
            print("[ActionFailure] capability=restore_workspace reason=failed_to_restore_workspace")
        }
        print("[ActionVerification] capability=restore_workspace status=\(verification)")
        print("[CapabilityExecution] completed status=\(anySuccess ? CapabilityExecutionStatus.success.rawValue : CapabilityExecutionStatus.unavailable.rawValue) id=restore_workspace reason=\(anySuccess ? "restored_workspace" : "failed_to_restore_workspace")")
        return anySuccess ? .success : .unavailable
    }

    private func arrangeSideBySide(context: [String: Any]) -> CapabilityExecutionStatus {
        print("[ActionExecution] capability=arrange_side_by_side")
        let apps = resolvedWorkspaceApps(from: context)
        let titles = resolvedTabTitles(from: context)
        let urls = resolvedTabURLs(from: context)
        LiveActionPath.emit(capability: "arrange_side_by_side", route: "environment", executor: "IntentExecutor", snapshotAge: 0, hasTargets: !apps.isEmpty, hasURLs: !urls.isEmpty, willExecute: true, reason: "runtime_discovery")

        if let override = Self.testHooks.arrangeSideBySide {
            let outcome = override(apps, titles)
            print("[WindowArrange] targetA=\(apps.first ?? "unknown")")
            print("[WindowArrange] targetB=\(apps.dropFirst().first ?? titles.first ?? "unknown")")
            print("[WindowArrange] layout=left_right")
            print("[WindowArrange] status=\(outcome.verificationStatus)")
            if outcome.status != .success {
                print("[ActionFailure] capability=arrange_side_by_side reason=\(outcome.reason)")
            }
            print("[ActionVerification] capability=arrange_side_by_side status=\(outcome.verificationStatus)")
            print("[CapabilityExecution] completed status=\(outcome.status.rawValue) id=arrange_side_by_side reason=\(outcome.reason)")
            return outcome.status
        }

        // Part B: click-time preflight — check contract before moving anything
        let contract = context["targetContract"] as? ActionTargetContract
        let preflight = ActionPreflight.check(contract: contract, capabilityID: "arrange_side_by_side")
        guard preflight.status == .ok else {
            let normalizedReason: String
            if preflight.targetCheck == .alreadySatisfied {
                normalizedReason = "already_satisfied"
            } else {
                normalizedReason = "target_contract_failed"
            }
            print("[ActionVerification] capability=arrange_side_by_side status=\(preflight.targetCheck == .alreadySatisfied ? "already_satisfied" : "failed") reason=\(normalizedReason)")
            print("[CapabilityExecution] completed status=\(preflight.targetCheck == .alreadySatisfied ? CapabilityExecutionStatus.alreadySatisfied.rawValue : CapabilityExecutionStatus.unavailable.rawValue) id=arrange_side_by_side reason=\(normalizedReason)")
            return preflight.targetCheck == .alreadySatisfied ? .alreadySatisfied : .unavailable
        }

        // Phase 34: Intent-driven execution via LayoutEngine with runtime window discovery.
        let compartment = context["compartment"] as? TaskCompartment
        let result = IntentExecutor.execute(
            intent: "arrange_side_by_side",
            compartment: compartment,
            preferredAppA: apps.count >= 1 ? apps[0] : nil,
            preferredAppB: apps.count >= 2 ? apps[1] : nil,
            titleHintA: titles.first,
            titleHintB: titles.dropFirst().first
        )
        // Part D: propagate partial status honestly
        print("[CapabilityExecution] completed status=\(result.rawValue) id=arrange_side_by_side reason=intent_executor")
        return result
    }

    private func switchToPairedApp(context: [String: Any]) -> CapabilityExecutionStatus {
        print("[ActionExecution] capability=switch_to_paired_app")
        let apps = resolvedWorkspaceApps(from: context)
        let titleHint = context["windowTitleHint"] as? String ?? context["suggestionTitle"] as? String
        LiveActionPath.emit(capability: "switch_to_paired_app", route: "environment", executor: "NSWorkspace", snapshotAge: 0, hasTargets: !apps.isEmpty, hasURLs: false, willExecute: !apps.isEmpty, reason: "user_click")
        if let override = Self.testHooks.switchToPairedApp {
            let outcome = override(apps)
            print("[SwitchAction] target=\(apps.first ?? "unknown")")
            print("[SwitchAction] status=\(outcome.verificationStatus)")
            if outcome.status != .success {
                print("[ActionFailure] capability=switch_to_paired_app reason=\(outcome.reason)")
            }
            print("[ActionVerification] capability=switch_to_paired_app status=\(outcome.verificationStatus)")
            print("[CapabilityExecution] completed status=\(outcome.status.rawValue) id=switch_to_paired_app reason=\(outcome.reason)")
            return outcome.status
        }

        // Part B: click-time preflight
        let contract = context["targetContract"] as? ActionTargetContract
        let preflight = ActionPreflight.check(contract: contract, capabilityID: "switch_to_paired_app")
        guard preflight.status == .ok else {
            let normalizedReason = preflight.targetCheck == .alreadySatisfied ? "already_satisfied" : "target_contract_failed"
            print("[ActionVerification] capability=switch_to_paired_app status=\(preflight.targetCheck == .alreadySatisfied ? "already_satisfied" : "failed") reason=\(normalizedReason)")
            print("[CapabilityExecution] completed status=\(preflight.targetCheck == .alreadySatisfied ? CapabilityExecutionStatus.alreadySatisfied.rawValue : CapabilityExecutionStatus.unavailable.rawValue) id=switch_to_paired_app reason=\(normalizedReason)")
            return preflight.targetCheck == .alreadySatisfied ? .alreadySatisfied : .unavailable
        }

        // Phase 34: Intent-driven execution with runtime discovery
        let compartment = context["compartment"] as? TaskCompartment
        let result = IntentExecutor.execute(
            intent: "switch_to_paired_app",
            compartment: compartment,
            preferredAppA: apps.first,
            titleHintA: titleHint
        )
        print("[SwitchAction] target=\(apps.first ?? "discovered")")
        print("[SwitchAction] status=\(result == .success ? "success" : "failed")")
        print("[CapabilityExecution] completed status=\(result.rawValue) id=switch_to_paired_app reason=intent_executor")
        return result
    }

    private func openCommonAppPair(context: [String: Any]) -> CapabilityExecutionStatus {
        print("[ActionExecution] capability=open_related_app_set")
        let apps = resolvedWorkspaceApps(from: context)
        if let override = Self.testHooks.openAppPair {
            let outcome = override(apps)
            print("[OpenPair] apps=\(apps.joined(separator: ","))")
            print("[OpenPair] status=\(outcome.verificationStatus)")
            if outcome.status != .success {
                print("[ActionFailure] capability=open_related_app_set reason=\(outcome.reason)")
            }
            print("[ActionVerification] capability=open_related_app_set status=\(outcome.verificationStatus)")
            print("[CapabilityExecution] completed status=\(outcome.status.rawValue) id=open_related_app_set reason=\(outcome.reason)")
            return outcome.status
        }

        guard !apps.isEmpty else {
            print("[ActionFailure] capability=open_related_app_set reason=no_apps")
            print("[ActionVerification] capability=open_related_app_set status=failed")
            print("[CapabilityExecution] completed status=blocked id=open_related_app_set reason=no_apps")
            return .blocked
        }

        var launched = 0
        for app in Array(apps.prefix(2)) where launchOrActivate(appName: app) {
            launched += 1
        }
        let verification = launched == min(apps.count, 2) ? "success" : (launched > 0 ? "partial" : "failed")
        print("[OpenPair] apps=\(Array(apps.prefix(2)).joined(separator: ","))")
        print("[OpenPair] status=\(verification)")
        if launched == 0 {
            print("[ActionFailure] capability=open_related_app_set reason=failed_to_launch_pair")
        }
        print("[ActionVerification] capability=open_related_app_set status=\(verification)")
        print("[CapabilityExecution] completed status=\(launched > 0 ? CapabilityExecutionStatus.success.rawValue : CapabilityExecutionStatus.unavailable.rawValue) id=open_related_app_set reason=\(launched > 0 ? "opened_app_pair" : "failed_to_launch_pair")")
        return launched > 0 ? .success : .unavailable
    }

    private func splitResearchSetup(context: [String: Any]) -> CapabilityExecutionStatus {
        print("[ActionExecution] capability=split_research_setup")
        let urls = resolvedTabURLs(from: context)
        let browser = resolvedBrowserAppName(from: context) ?? "Unknown"
        LiveActionPath.emit(capability: "split_research_setup", route: "environment", executor: "IntentExecutor", snapshotAge: 0, hasTargets: true, hasURLs: !urls.isEmpty, willExecute: true, reason: "runtime_discovery")

        if let override = Self.testHooks.splitResearchSetup {
            let outcome = override(browser, urls)
            print("[TabSplit] browser=\(browser)")
            print("[TabSplit] strategy=\(BrowserSplitStrategy.strategy(for: browser))")
            print("[TabSplit] status=\(outcome.verificationStatus)")
            if outcome.status != .success {
                print("[ActionFailure] capability=split_research_setup reason=\(outcome.reason)")
            }
            print("[ActionVerification] capability=split_research_setup status=\(outcome.verificationStatus)")
            print("[CapabilityExecution] completed status=\(outcome.status.rawValue) id=split_research_setup reason=\(outcome.reason)")
            return outcome.status
        }

        // Phase 34: Intent-driven execution — discovers URL from browser if not in payload
        let result = IntentExecutor.execute(
            intent: "split_research_setup",
            compartment: context["compartment"] as? TaskCompartment,
            targetURL: urls.dropFirst().first ?? urls.first,
            browserName: browser
        )
        print("[CapabilityExecution] completed status=\(result.rawValue) id=split_research_setup reason=intent_executor")
        return result
    }

    private func resolvedWorkspaceApps(from context: [String: Any]) -> [String] {
        let explicit = (context["apps"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !WorkspaceAppFilter.isSystemApp($0) }
        if !explicit.isEmpty {
            return explicit.reduce(into: [String]()) { acc, app in
                if !acc.contains(app) { acc.append(app) }
            }
        }

        let hints = Set(resolvedTabTitles(from: context).map { $0.lowercased() })
        let patterns = WorkspacePatternTracker.shared.knownPatterns()
        if let best = patterns.max(by: { patternSupport($0, titleHints: hints) < patternSupport($1, titleHints: hints) }) {
            return best.apps.filter { !WorkspaceAppFilter.isSystemApp($0) }
        }
        return []
    }

    private func resolvedTabURLs(from context: [String: Any]) -> [String] {
        let explicit = (context["tabURLs"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !explicit.isEmpty { return explicit }

        let hints = Set(resolvedTabTitles(from: context).map { $0.lowercased() })
        let patterns = WorkspacePatternTracker.shared.knownPatterns()
        if let best = patterns.max(by: { patternSupport($0, titleHints: hints) < patternSupport($1, titleHints: hints) }) {
            return Array(best.urls.prefix(8))
        }

        if let browser = currentBrowserContext(), let selected = browser.selectedURL?.absoluteString ?? browser.currentURL?.absoluteString {
            return [selected]
        }
        return []
    }

    private func resolvedTabTitles(from context: [String: Any]) -> [String] {
        let explicit = (context["tabTitles"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !explicit.isEmpty { return explicit }
        if let browser = currentBrowserContext() {
            let selected = browser.selectedTitle.map { [$0] } ?? []
            return Array((selected + browser.recentTabTitles).prefix(10))
        }
        return []
    }

    private func resolvedBrowserAppName(from context: [String: Any]) -> String? {
        if let explicit = context["browserAppName"] as? String, !explicit.isEmpty {
            return explicit
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName,
           ["Safari", "Google Chrome", "Chrome", "Firefox", "Arc", "Brave Browser", "Microsoft Edge"].contains(frontmost) {
            return frontmost
        }
        return currentBrowserContext()?.appName
    }

    private func currentBrowserContext() -> BrowserContextExtractor.BrowserContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return BrowserContextExtractor.extract(appName: app.localizedName ?? "", activeAppPID: app.processIdentifier)
    }

    private func patternSupport(_ pattern: WorkspacePattern, titleHints: Set<String>) -> Int {
        let tabs = Set(pattern.tabTitles.map { $0.lowercased() })
        return tabs.intersection(titleHints).count * 3 + min(pattern.urls.count, 4) + pattern.frequency
    }

    private func pairedAppTarget(from apps: [String]) -> String? {
        let current = NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased()
        return apps.first { $0.lowercased() != current } ?? apps.first
    }

    private func launchOrActivate(appName: String) -> Bool {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
            return running.activate(options: [.activateIgnoringOtherApps])
        }
        return NSWorkspace.shared.launchApplication(appName)
    }

    private func openURL(_ url: URL, preferredAppName: String?) -> Bool {
        guard let preferredAppName else {
            return NSWorkspace.shared.open(url)
        }
        let result = runProcess("/usr/bin/open", arguments: ["-a", preferredAppName, url.absoluteString])
        return result.success || NSWorkspace.shared.open(url)
    }

    private func browserSplitStrategy(for browser: String) -> String {
        let lower = browser.lowercased()
        if lower.contains("firefox") { return "open_url_new_window" }
        if lower.contains("chrome") || lower.contains("brave") || lower.contains("edge") || lower.contains("arc") { return "open_url_new_window" }
        if lower.contains("safari") { return "new_document" }
        return "open_url_new_window"
    }

    private func openURLInNewWindow(_ urlString: String, browserName: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let lower = browserName.lowercased()
        if lower.contains("firefox") {
            return runProcess("/usr/bin/open", arguments: ["-a", browserName, "--args", "-new-window", url.absoluteString]).success
        }
        if lower.contains("chrome") || lower.contains("brave") || lower.contains("edge") || lower.contains("arc") {
            return runProcess("/usr/bin/open", arguments: ["-a", browserName, "--args", "--new-window", url.absoluteString]).success
        }
        if lower.contains("safari") {
            let script = "tell application \"Safari\" to make new document with properties {URL:\"\(url.absoluteString)\"}"
            return runProcess("/usr/bin/osascript", arguments: ["-e", script]).success
        }
        return openURL(url, preferredAppName: browserName)
    }

    private func focusShortcut(named preferred: String) -> String? {
        if let override = Self.testHooks.focusShortcutAvailable {
            return override() ? preferred : nil
        }
        if let cachedFocusShortcut,
           Date().timeIntervalSince(cachedFocusShortcut.checkedAt) < 60 {
            return cachedFocusShortcut.name
        }
        let result = runProcess("/usr/bin/shortcuts", arguments: ["list"])
        guard result.success else {
            cachedFocusShortcut = (nil, Date())
            return nil
        }
        let shortcuts = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let found = shortcuts.first { $0.caseInsensitiveCompare(preferred) == .orderedSame }
        cachedFocusShortcut = (found, Date())
        return found
    }

    private func runProcess(_ launchPath: String, arguments: [String]) -> (success: Bool, stdout: String, stderr: String) {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (task.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines), err.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (false, "", error.localizedDescription)
        }
    }

    private struct ArrangeVerification {
        let targetA: String
        let targetB: String
        let verified: Bool
    }

    private func arrangeWindowsForTargets(apps: [String], titleHints: [String]) -> ArrangeVerification? {
        let targetApps = apps.isEmpty ? fallbackArrangeApps(from: titleHints) : apps
        guard !targetApps.isEmpty else { return nil }
        guard let screenFrame = NSScreen.main?.visibleFrame else { return nil }

        let leftFrame = CGRect(x: screenFrame.minX, y: screenFrame.minY, width: floor(screenFrame.width / 2.0), height: screenFrame.height)
        let rightFrame = CGRect(x: screenFrame.minX + floor(screenFrame.width / 2.0), y: screenFrame.minY, width: ceil(screenFrame.width / 2.0), height: screenFrame.height)

        if targetApps.count == 1 {
            guard let bundle = appBundleIdentifier(named: targetApps[0]) else { return nil }
            let elements = windowElements(bundleIdentifier: bundle)
            guard elements.count >= 2 else { return nil }
            let leftOK = setWindow(elements[0], frame: leftFrame)
            let rightOK = setWindow(elements[1], frame: rightFrame)
            return ArrangeVerification(targetA: targetApps[0], targetB: targetApps[0], verified: leftOK && rightOK)
        }

        guard let leftBundle = appBundleIdentifier(named: targetApps[0]),
              let rightBundle = appBundleIdentifier(named: targetApps[1]),
              let leftWindow = windowElements(bundleIdentifier: leftBundle).first,
              let rightWindow = windowElements(bundleIdentifier: rightBundle).first else {
            return nil
        }
        let leftOK = setWindow(leftWindow, frame: leftFrame)
        let rightOK = setWindow(rightWindow, frame: rightFrame)
        return ArrangeVerification(targetA: targetApps[0], targetB: targetApps[1], verified: leftOK && rightOK)
    }

    private func fallbackArrangeApps(from titleHints: [String]) -> [String] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName.map { [$0] } ?? []
        if frontmost.isEmpty {
            return []
        }
        if titleHints.count >= 2 {
            return [frontmost[0], frontmost[0]]
        }
        let patterns = WorkspacePatternTracker.shared.knownPatterns()
        if let firstPattern = patterns.first, firstPattern.apps.count >= 2 {
            return Array(firstPattern.apps.prefix(2))
        }
        return frontmost
    }

    private func appBundleIdentifier(named appName: String) -> String? {
        NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName })?.bundleIdentifier
    }

    private func windowElements(bundleIdentifier: String) -> [AXUIElement] {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return [] }
        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements
    }

    private func setWindow(_ window: AXUIElement, frame: CGRect) -> Bool {
        var position = CGPoint(x: frame.minX, y: frame.minY)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let posValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }
        let posSet = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue) == .success
        let sizeSet = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
        guard posSet && sizeSet else { return false }
        return verifyWindow(window, expectedFrame: frame)
    }

    private func verifyWindow(_ window: AXUIElement, expectedFrame: CGRect) -> Bool {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef,
              let sizeValue = sizeRef else {
            return false
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(posValue as! AXValue) == .cgPoint,
              AXValueGetType(sizeValue as! AXValue) == .cgSize,
              AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return false
        }
        let actual = CGRect(origin: point, size: size)
        return abs(actual.minX - expectedFrame.minX) < 12
            && abs(actual.minY - expectedFrame.minY) < 12
            && abs(actual.width - expectedFrame.width) < 24
            && abs(actual.height - expectedFrame.height) < 24
    }
}

// MARK: - Phase 26.1 — System app filter

/// Filters system apps, notification daemons, and assistant-internal processes
/// from workspace patterns and launch lists.
enum WorkspaceAppFilter {

    /// Apps that should never be learned as part of a workspace pattern
    /// or offered for launch by friction actions.
    private static let systemAppNames: Set<String> = [
        "usernotificationcenter",
        "notification center",
        "loginwindow",
        "systemuiserver",
        "dock",
        "finder",             // always running, not a workspace app
        "spotlight",
        "screencaptureui",
        "securityagent",
        "universalcontrol",
        "coreservicesuiagent",
        "airplayuiagent",
        "talagent",
        "storeuid",
        "assistantclient",    // Siri
        "control center",
        "music",              // background media — handled separately
        "spotify",            // background media — handled separately
        "contextual",         // the assistant itself
    ]

    /// Bundle ID prefixes that indicate system/internal processes.
    private static let systemBundlePrefixes: [String] = [
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.controlcenter",
        "com.apple.Spotlight",
    ]

    static func isSystemApp(_ appName: String) -> Bool {
        let lower = appName.lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespaces)
        return systemAppNames.contains(lower)
    }

    static func isSystemBundle(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return systemBundlePrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }
}

public struct ActionCard: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    public let explanation: String
    public let primaryAction: CognitiveCapability
    public let secondaryAction: CognitiveCapability?
    public let auxiliaryAction: CognitiveCapability?
    public let previewPayload: ArtifactResult
    public let evidenceNote: String
    public let confidence: Double
    public let confirmationState: String // "none", "required", "confirmed"
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        explanation: String,
        primaryAction: CognitiveCapability,
        secondaryAction: CognitiveCapability? = nil,
        auxiliaryAction: CognitiveCapability? = nil,
        previewPayload: ArtifactResult,
        evidenceNote: String,
        confidence: Double,
        confirmationState: String = "none"
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.auxiliaryAction = auxiliaryAction
        self.previewPayload = previewPayload
        self.evidenceNote = evidenceNote
        self.confidence = confidence
        self.confirmationState = confirmationState
        
        print("[ActionCard] rendered id=\(id)")
        print("[ActionCard] primary=\(primaryAction.id)")
        if let s = secondaryAction { print("[ActionCard] secondary=\(s.id)") }
        if let a = auxiliaryAction { print("[ActionCard] auxiliary=\(a.id)") }
    }
}
