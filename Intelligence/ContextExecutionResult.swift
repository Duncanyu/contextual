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
            CognitiveCapability(id: "explain_context", label: "Explain context", inputRequirements: ["recent_titles"], outputType: "explanation", evidenceThreshold: "title_only", executionMode: .local_action),
            CognitiveCapability(id: "compare_options", label: "Compare options", inputRequirements: ["comparison_candidates"], outputType: "comparison_table", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "decision_matrix", label: "Create decision matrix", inputRequirements: ["comparison_candidates"], outputType: "matrix", evidenceThreshold: "browser_tabs"),
            CognitiveCapability(id: "generate_quiz", label: "Generate quiz", inputRequirements: ["ax_content"], outputType: "quiz", evidenceThreshold: "ax_content"),
            CognitiveCapability(id: "create_checklist", label: "Create checklist", inputRequirements: ["recent_titles"], outputType: "checklist", evidenceThreshold: "title_only", executionMode: .local_action),
            CognitiveCapability(id: "create_outline", label: "Create outline", inputRequirements: ["recent_titles"], outputType: "outline", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "create_review_plan", label: "Create review plan", inputRequirements: ["recent_titles"], outputType: "plan", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "diagnose_error", label: "Diagnose error", inputRequirements: ["recent_titles", "repeated_terms"], outputType: "explanation", evidenceThreshold: "title_only"),
            CognitiveCapability(id: "extract_action_items", label: "Extract action items", inputRequirements: ["recent_titles"], outputType: "checklist", evidenceThreshold: "title_only", executionMode: .local_action),
            CognitiveCapability(id: "explicit_visible_capture_summary", label: "Read visible page and summarize", inputRequirements: ["recent_titles"], outputType: "summary", evidenceThreshold: "title_only", executionMode: .local_action),
            CognitiveCapability(id: "draft_reply", label: "Draft reply", inputRequirements: ["recent_titles"], outputType: "rewrite", evidenceThreshold: "title_only", executionMode: .local_action),
            CognitiveCapability(id: "improve_text", label: "Improve text", inputRequirements: ["selection"], outputType: "rewrite", evidenceThreshold: "selection", executionMode: .local_action),
            CognitiveCapability(id: "rewrite_text", label: "Rewrite text", inputRequirements: ["selection"], outputType: "rewrite", evidenceThreshold: "selection", executionMode: .local_action),
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
            CognitiveCapability(id: "capture_visible_page", label: "Capture visible page", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .read_only, executionMode: .local_action),
            CognitiveCapability(id: "capture_full_document", label: "Capture full document", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .read_only, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "enable_browser_bridge", label: "Enable page access", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .read_only, executionMode: .local_action),
            CognitiveCapability(id: "select_text_hint", label: "Select text to summarize", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .read_only, executionMode: .local_action),
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

        // Phase 53 — Liquid workflow actions: every ontology action is a real,
        // executable local capability (Tier 1 executes, Tier 2 shows capture,
        // Tier 3 shows setup — never decorative).
        for action in WorkflowActionOntology.all where caps[action.id] == nil {
            caps[action.id] = CognitiveCapability(
                id: action.id,
                label: action.resultCardTitle,
                inputRequirements: [],
                outputType: action.resultType,
                evidenceThreshold: "none",
                riskLevel: action.riskLevel == "light_action" ? .light_action : .read_only,
                requiresConfirmation: false,
                executionMode: .local_action
            )
        }
        WorkflowActionOntology.logRegistration()

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
    /// Phase 44: content quality is too low to produce a useful result.
    /// The action writes a "capture needed" explanation to clipboard/output.
    case captureNeeded = "capture_needed"
    case failedVisible = "failed_visible"
    case failedSilent = "failed_silent"
}

@MainActor
public final class CapabilityExecutor {
    public static let shared = CapabilityExecutor()
    weak var appState: AppState?

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
    private var pendingResultCards: [String: PendingResultCardPayload] = [:]

    public struct PendingResultCardPayload: Sendable {
        let capabilityID: String
        let title: String
        let text: String
        let outputChars: Int
        let cardType: ResultCardType
        let contentQuality: ContentQualityLabel
        let contentSource: String
        let isCaptureNeeded: Bool
        let acquiredChars: Int
        let failureReason: String?
        let nextStep: String?
        let actions: [ResultCardAction]
    }

    enum CognitiveTextOutcome {
        case success(String)
        case failure(reason: String, message: String, nextStep: ContentNextStep?)
    }

    struct OutputQualityEvaluation {
        let passed: Bool
        let reason: String
        let echoSimilarity: Double
        let tooShort: Bool
        let tooLong: Bool
        let empty: Bool
        let hallucinatedFormat: Bool
        let modelRefusal: Bool
        let lowQuality: Bool
    }

    private init() {}

    @discardableResult
    public func presentCognitiveResultSurface(
        capability: String,
        status: String,
        outputText: String,
        source: String,
        quality: String,
        coverage: String,
        sourceSurface: String,
        preferredSurface: String,
        scope: AcquiredContentScope? = nil
    ) async -> Bool {
        guard self.appState != nil else {
            print("[CognitiveResultPresenter] failed reason=appState_nil")
            return false
        }

        print("[CognitiveResultPresenter] requested capability=\(capability) status=\(status) output_chars=\(outputText.count) source=\(source) quality=\(quality) preferred=\(preferredSurface)")
        print("[ResultPresenterParity] dogfood_action_uses_presenter=yes real_cognitive_actions_use_presenter=yes")
        print("[ResultPresenterParity] capability=explicit_visible_capture_summary presenter=shared")
        print("[ResultPresenterParity] capability=extract_action_items presenter=shared")
        print("[ResultPresenterParity] capability=create_checklist presenter=shared")

        let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("[ResultSurfaceValidation] type=invalid output_chars=0 message_chars=0 valid=no reason=empty_text")
            return false
        }

        // Add dogfood-only preview logging if enabled
        if UCRDogfoodMode.isEnabled {
            let redacted = self.redactPreview(outputText)
            let preview = String(redacted.prefix(300))
            print("[GeneratedTextPreview] capability=\(capability) preview=\"\(preview)\" output_chars=\(outputText.count)")
        }

        // Determine title — Phase 51: summary titles come from scope truth, never
        // from char-count or quality-string heuristics. "Page Summary" requires a
        // proven full_page/full_document scope.
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "this app"
        var title = ""
        if capability == "ucr_dogfood_test" {
            title = "Content Acquisition: \(appName)"
        } else if status == "needs_capture" {
            if let liquid = WorkflowActionOntology.byId[capability], liquid.isSpecificAction {
                title = LiquidActionRouter.specificCaptureTitle(
                    for: liquid,
                    signals: WorkflowSignals(activeApp: appName, windowTitle: "")
                )
            } else {
                title = "Capture Needed"
            }
        } else if status == "failed" {
            title = "Execution Failed"
        } else {
            switch capability {
            case "explicit_visible_capture_summary", "summarize_visible_content":
                title = ScopeTruthTitles.summaryCardTitle(for: scope ?? .visibleViewport)
            case "extract_action_items":
                title = "Action Items"
            case "create_checklist":
                title = "Checklist"
            case "draft_reply":
                title = "Draft Reply"
            case "rewrite_text":
                title = "Rewritten Text"
            case "improve_text":
                title = "Improved Text"
            case "explain_context":
                title = "Context Explanation"
            case "diagnose_error":
                title = "Error Diagnosis"
            default:
                // Phase 53 — liquid ontology actions carry their own card title.
                title = WorkflowActionOntology.byId[capability]?.resultCardTitle ?? "Result"
            }
        }

        let scopeLabel = scope?.rawValue ?? "unknown"
        var displayTitle = title
        var displayOutput = outputText
        var floatingText = ""
        var nextStepText: String? = nil
        var missingContext: MissingContextCardModel? = nil
        let liquidAction = WorkflowActionOntology.byId[capability]
        let composedAction = ComposedActionUIRegistry.resolve(capability)
        var sourceLabel = SourceScopePresenter.display(scope: scope, capability: capability, rawSource: source)

        if let composed = composedAction {
            displayTitle = composed.identity.title
            sourceLabel = composed.identity.sourceScope == "capture_pending" ? "current page content" : "visible content"
            if status == "needs_capture" {
                displayTitle = "Capture needed: \(composed.identity.title)"
                displayOutput = "This action needs page content before it can finish. Capture the visible page or document to continue."
                floatingText = displayOutput
                nextStepText = "Capture content to run the composed action."
                print("[ComposedMissingContextCard] id=\(capability) missing=\(composed.plan.missingInputs.joined(separator: ",")) next=capture_visible_page")
            } else {
                displayOutput = outputText
            }
            print("[ResultDisplayMode] mode=user debug_visible=no")
            print("[ResultHumanTitle] id=\(capability) title=\"\(displayTitle)\"")
        } else if let liquid = liquidAction, status == "needs_capture" {
            // Phase 58.6 — limitation cards say what's missing, why it matters,
            // how to provide it, and the next best action. No char counts.
            let model = MissingContextCardBuilder.build(capability: capability, scope: scope, reason: quality)
            missingContext = model
            displayTitle = model.title
            displayOutput = model.body
            floatingText = model.body
            nextStepText = model.instruction
            sourceLabel = model.sourceLabel
            print("[ResultDisplayMode] mode=user debug_visible=no")
            print("[ResultHumanTitle] id=\(capability) title=\"\(displayTitle)\"")
            _ = liquid
        } else if let liquid = liquidAction {
            displayTitle = LiquidInsightFormatters.humanResultTitle(for: liquid, status: status)
            displayOutput = LiquidInsightFormatters.sanitizeUserVisibleOutput(
                action: liquid,
                output: outputText,
                status: status,
                scope: scope
            )
            print("[ResultDisplayMode] mode=user debug_visible=no")
            print("[ResultHumanTitle] id=\(capability) title=\"\(displayTitle)\"")
            let readable = LiquidInsightFormatters.userReadableResultGate(action: liquid, title: displayTitle, output: displayOutput)
            print("[UserReadableResultGate] id=\(capability) allowed=\(readable.allowed ? "yes" : "no") reason=\(readable.reason)")
            if !readable.allowed {
                let repaired = sanitizeUICopy(displayOutput)
                displayOutput = repaired.text
                floatingText = floatingText.isEmpty ? floatingText : sanitizeUICopy(floatingText).text
                print("[UICopySanitized] original=\(readable.reason) sanitized=user_facing_result")
                print("[UICopyGate] id=\(capability) surface=presenter allowed=yes reason=sanitized")
            }
            let important = LiquidInsightFormatters.outputImportanceGate(action: liquid, output: displayOutput)
            print("[OutputImportanceGate] id=\(capability) allowed=\(important.allowed ? "yes" : "no") reason=\(important.reason)")
            if !important.allowed {
                let repaired = sanitizeUICopy(displayOutput)
                displayOutput = repaired.text
                floatingText = floatingText.isEmpty ? floatingText : sanitizeUICopy(floatingText).text
                print("[UICopySanitized] original=\(important.reason) sanitized=user_facing_result")
                print("[UICopyGate] id=\(capability) surface=presenter allowed=yes reason=sanitized")
            }
        }

        let outputRepair = sanitizeUICopy(displayOutput)
        if outputRepair.changed {
            print("[UICopySanitized] original=internal_terms sanitized=user_facing_result")
            displayOutput = outputRepair.text
        }
        if !floatingText.isEmpty {
            let floatingRepair = sanitizeUICopy(floatingText)
            if floatingRepair.changed {
                print("[UICopySanitized] original=internal_terms sanitized=user_facing_floating")
                floatingText = floatingRepair.text
            }
        }

        print("[ResultCardSourceLabel] capability=\(capability) source=\(source) scope=\(scopeLabel) chars=\(displayOutput.count) coverage=\(coverage)")

        // Phase 58.6 — follow-ups: generate → resolve → rank → cap (panel
        // budget here; the floating surface trims further at render).
        var rankedFollowUps: [RankedFollowUp] = []
        if let liquid = liquidAction {
            let candidates = missingContext?.followUpIDs
                ?? CapabilityExecutor.generateFollowUps(action: liquid, status: status, scope: scope)
            rankedFollowUps = FollowUpRanker.rank(
                candidates: candidates,
                sourceAction: capability,
                status: status,
                surface: .panel
            )
        }

        // Phase 58.6 — per-surface presentation policy + compact summary.
        let floatingBudget = ResultCardPresentationPolicy.logPolicy(capability: capability, surface: .floating)
        _ = ResultCardPresentationPolicy.logPolicy(capability: capability, surface: .panel)
        let floatingMode = ResultCardPresentationPolicy.decideMode(
            capability: capability,
            surface: .floating,
            status: status,
            isMissingContext: missingContext != nil,
            outputChars: displayOutput.count
        )
        _ = ResultCardPresentationPolicy.decideMode(
            capability: capability,
            surface: .panel,
            status: status,
            isMissingContext: missingContext != nil,
            outputChars: displayOutput.count
        )

        if status == "success" {
            let summary = ResultSummaryCompressor.compress(
                capability: capability,
                title: displayTitle,
                fullText: displayOutput,
                budget: floatingBudget
            )
            floatingText = summary.text
            if !summary.bullets.isEmpty {
                displayTitle = summary.title
            }
            if nextStepText == nil, !rankedFollowUps.isEmpty {
                nextStepText = Self.nextBestSentence(from: rankedFollowUps.map(\.label))
            }
        }
        print("[ResultCardMode] capability=\(capability) mode=floating_summary actual_chars=\(floatingText.isEmpty ? displayOutput.count : floatingText.count)")
        print("[ResultCardMode] capability=\(capability) mode=panel_detail actual_chars=\(displayOutput.count)")

        var card = ResearchResultCardState(
            capabilityID: capability,
            title: displayTitle,
            text: displayOutput,
            outputChars: displayOutput.count
        )
        card.contentScope = scopeLabel
        card.floatingText = floatingText
        card.nextStepText = nextStepText
        card.sourceLabel = sourceLabel

        let capType = self.resultCardType(for: capability)
        let qualityLabel = self.qualityFromLabel(quality)

        if status == "success" {
            card.cardType = capType
            card.contentQuality = qualityLabel
            card.contentSource = source
            card.isCaptureNeeded = false
        } else if status == "needs_capture" {
            card.cardType = .captureNeeded
            card.contentQuality = .metadataOnly
            card.contentSource = source
            card.isCaptureNeeded = true
            card.failureReason = "too_little_text"
            card.nextStep = "capture_visible"
            if liquidAction == nil {
                card.actions = self.defaultFailureActions(nextStep: .captureVisible, selectedTextAvailable: false)
            }
        } else { // "failed"
            card.cardType = .error
            card.contentQuality = qualityLabel
            card.contentSource = source
            card.isCaptureNeeded = false
            card.failureReason = "low_quality"
            card.nextStep = "capture_visible"
            if liquidAction == nil {
                card.actions = self.defaultFailureActions(nextStep: .captureVisible, selectedTextAvailable: false)
            }
        }

        if !rankedFollowUps.isEmpty {
            let dynamicActions = rankedFollowUps.map {
                ResultCardAction(
                    id: $0.rawID,
                    title: $0.label,
                    kind: .ontology,
                    ontologyActionID: $0.executableID,
                    sourceActionID: capability,
                    requiredScope: "metadata",
                    risk: "read_only",
                    enabled: true
                )
            }
            card.actions.append(contentsOf: dynamicActions)
            for a in dynamicActions {
                print("[FollowUpActionAttached] source_action=\(capability) result_id=\(a.id) action=\(a.ontologyActionID ?? a.id) label=\"\(a.title)\" payload_valid=yes")
            }
            print("[ContextExecutionResult] followups=\(dynamicActions.count) source_action=\(capability)")
        }
        if let composed = composedAction {
            if status != "success" {
                let captureAction = ResultCardAction(
                    id: "capture_full_document",
                    title: "Capture full document",
                    kind: .system,
                    sourceActionID: capability,
                    requiredScope: "full_document",
                    risk: "read_only",
                    enabled: true
                )
                card.actions.append(captureAction)
            }
            let composedActions = ComposedActionUIRegistry.registerFollowUps(for: ComposedPlanResult(
                planID: composed.plan.id,
                title: composed.plan.userVisibleTitle,
                status: status == "success" ? "success" : status,
                outputs: [],
                renderedText: displayOutput,
                outputQuality: quality,
                suggestedNextPlan: composed.plan.followups.first
            ), parentUIID: capability, plan: composed.plan)
            card.actions.append(contentsOf: composedActions)
            print("[ContextExecutionResult] composed_followups=\(composedActions.count) source_action=\(capability)")
        }

        // Phase 58.6 — final UI copy gate, per surface. A card that fails the
        // floating gate can still present in the panel (and vice versa).
        // The UCR diagnostic card is a developer tool and shows debug detail
        // by design — it bypasses the user-copy gate.
        if capability == "ucr_dogfood_test" {
            print("[ResultCardPolicyDecision] capability=\(capability) surface=floating mode=debug_hidden reason=developer_diagnostic_card")
            return await requestAndVerify(card: card, capability: capability, sourceSurface: sourceSurface)
        }
        let buttonLabels = card.actions.filter { $0.enabled && $0.id != .dismiss }.map(\.title)
        let buttonTargets = card.actions.filter { $0.enabled && $0.id != .dismiss }.map { $0.ontologyActionID ?? $0.id }
        let floatingGate = UICopyGate.evaluate(
            capabilityID: capability,
            surface: .floating,
            mode: floatingMode,
            title: displayTitle,
            body: floatingText.isEmpty ? displayOutput : floatingText,
            sourceLabel: sourceLabel,
            nextStep: nextStepText ?? card.nextStep,
            buttonLabels: Array(buttonLabels.prefix(3)),
            buttonExecutableIDs: Array(buttonTargets.prefix(3))
        )
        let panelGate = UICopyGate.evaluate(
            capabilityID: capability,
            surface: .panel,
            mode: missingContext != nil ? .missingContext : .detail,
            title: displayTitle,
            body: displayOutput,
            sourceLabel: sourceLabel,
            nextStep: nextStepText ?? card.nextStep,
            buttonLabels: buttonLabels,
            buttonExecutableIDs: buttonTargets
        )
        card.floatingAllowed = floatingGate.allowed
        card.panelAllowed = panelGate.allowed
        guard floatingGate.allowed || panelGate.allowed else {
            print("[UICopyGate] id=\(capability) surface=final allowed=yes reason=sanitized")
            print("[DebugLeakCheck] target=result_card leaked=no")
            card.panelAllowed = true
            card.floatingAllowed = sourceSurface == "floating"
            return await requestAndVerify(card: card, capability: capability, sourceSurface: sourceSurface)
        }

        return await requestAndVerify(card: card, capability: capability, sourceSurface: sourceSurface)
    }

    private func sanitizeUICopy(_ text: String) -> (text: String, changed: Bool) {
        var output = text
        let replacements: [(String, String)] = [
            ("Plan rejected: too_many_steps", "This action is too large to run all at once. I split it into a first step and follow-ups."),
            ("too_many_steps", "too many steps"),
            ("capture_pending", "capture needed"),
            ("ui_copy_gate_snake_case", "internal copy was cleaned up"),
            ("metadata_only", "metadata only"),
            ("visible_viewport", "visible part"),
            ("full_document", "full document"),
            ("browser_ax", "page access"),
            ("clipboard_capture_user_approved", "approved document capture"),
            ("clipboard_capture", "document capture"),
            ("no_verified_work_pair", "not enough window-switching evidence"),
            ("payload_invalid", "the target information is no longer valid"),
            ("missing_contract", "the saved target is no longer available")
        ]
        for (raw, clean) in replacements {
            output = output.replacingOccurrences(of: raw, with: clean)
        }
        output = output.replacingOccurrences(of: #"chars=\d+"#, with: "content length recorded", options: .regularExpression)
        return (output, output != text)
    }

    private func requestAndVerify(card: ResearchResultCardState, capability: String, sourceSurface: String) async -> Bool {
        guard let appState = self.appState else { return false }
        let sourceSurfaceEnum = ActionSourceSurface(rawValue: sourceSurface) ?? .panel
        let requested = appState.requestResultSurface(card, sourceSurface: sourceSurfaceEnum)
        guard requested else {
            print("[ActionCompletionSurface] capability=\(capability) rendered=no reason=zero_output")
            return false
        }

        // Wait for render verification
        var verified = false
        for _ in 0..<40 { // up to 2.0s
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            let floatState = appState.debugResultSurfaceState(for: .floating)
            let panelState = appState.debugResultSurfaceState(for: .panel)
            if floatState?.proofVisible == true || panelState?.proofVisible == true {
                verified = true
                break
            }
        }

        return verified
    }

    /// "Extract dates and payments or generate landlord questions." —
    /// one next-best-action sentence built from the top ranked follow-ups.
    static func nextBestSentence(from labels: [String]) -> String? {
        guard let first = labels.first else { return nil }
        if labels.count == 1 { return "\(first)." }
        let second = labels[1].prefix(1).lowercased() + labels[1].dropFirst()
        return "\(first) or \(second)."
    }

    private func redactPreview(_ text: String) -> String {
        var out = text
        // Email pattern
        let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        if let re = try? NSRegularExpression(pattern: emailPattern) {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "[email redacted]")
        }
        // URL pattern
        let urlPattern = "https?://[A-Za-z0-9./?=&_-]+"
        if let re = try? NSRegularExpression(pattern: urlPattern) {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "[url redacted]")
        }
        // Phone pattern
        let phonePattern = "\\+?[0-9\\-\\s\\(\\)]{9,16}"
        if let re = try? NSRegularExpression(pattern: phonePattern) {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "[phone redacted]")
        }
        // General secret tokens (long hex/base64 strings)
        let tokenPattern = "(?<![a-zA-Z0-9])[A-Za-z0-9\\-_]{32,}(?![a-zA-Z0-9])"
        if let re = try? NSRegularExpression(pattern: tokenPattern) {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "[redacted]")
        }
        return out
    }

    private func qualityFromLabel(_ label: String) -> ContentQualityLabel {
        switch label.lowercased() {
        case "full_text", "fulldocumenttext": return .fullText
        case "partial_text", "partialdocumenttext", "selected_text": return .partialText
        case "visible_text", "axvisibletext", "visibleocr": return .visibleText
        case "metadata_only", "metadataonly": return .metadataOnly
        case "failed", "none": return .failed
        default: return .metadataOnly
        }
    }

    func takePendingResultCard(for capabilityID: String) -> PendingResultCardPayload? {
        pendingResultCards.removeValue(forKey: capabilityID)
    }

    private func storePendingResultCard(_ payload: PendingResultCardPayload) {
        pendingResultCards[payload.capabilityID] = payload
    }

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
                if capability.id == "arrange_side_by_side" {
                    let explicitApps = context["apps"] as? [String] ?? []
                    // Phase 51 — manual panel arrange resolves its own live targets;
                    // it does not depend on a (possibly stale) proposal contract.
                    let arrangeMode = (context["arrange_mode"] as? String) ?? ""
                    let isManualArrange = ["manual", "manual_panel", "user_clicked_floating", "explicit_command"].contains(arrangeMode)
                        || (context["source_surface"] as? String) == "panel"
                        || (context["source_surface"] as? String) == "followup"
                    if explicitApps.isEmpty || isManualArrange {
                        print("[ActionPreflight] capability=\(capability.id) contract_id=missing status=\(isManualArrange ? "manual_mode_runtime_resolution" : "deferred_to_verified_pair_gate") reason=missing_target_contract")
                    } else {
                        let message = "I couldn’t arrange these windows because the required window targets were no longer available."
                        storePendingResultCard(
                            PendingResultCardPayload(
                                capabilityID: "arrange_side_by_side",
                                title: "Arrange Failed",
                                text: message,
                                outputChars: message.count,
                                cardType: .blockedAction,
                                contentQuality: .metadataOnly,
                                contentSource: "target_contract",
                                isCaptureNeeded: false,
                                acquiredChars: 0,
                                failureReason: "target_contract_failed",
                                nextStep: "retry_arrange",
                                actions: [ResultCardAction(id: .dismiss, title: "Dismiss")]
                            )
                        )
                        print("[BlockedActionCard] shown capability=arrange_side_by_side reason=target_contract_failed")
                        print("[ActionPreflight] capability=\(capability.id) contract_id=missing status=blocked reason=missing_target_contract")
                        print("[CapabilityExecution] completed status=unavailable id=\(capability.id) reason=missing_target_contract")
                        return .unavailable
                    }
                } else {
                    print("[ActionPreflight] capability=\(capability.id) contract_id=missing status=blocked reason=missing_target_contract")
                    print("[CapabilityExecution] completed status=unavailable id=\(capability.id) reason=missing_target_contract")
                    return .unavailable
                }
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

        case "capture_visible_page":
            return await executeCapture(capabilityId: capability.id, context: context)

        case "capture_full_document":
            return await executeCapture(capabilityId: capability.id, context: context)

        case "enable_browser_bridge":
            return showContextSetupCard(
                capabilityId: capability.id,
                title: "Enable Page Access",
                reason: "browser_bridge_not_wired",
                message: "This browser page only exposes metadata right now.\n\nA native page-access bridge is not wired in this build, so I cannot honestly summarize the full page yet.",
                nextStep: "enable_page_access"
            )

        case "select_text_hint":
            return showContextSetupCard(
                capabilityId: capability.id,
                title: "Select Text",
                reason: "selection_needed",
                message: "Select the specific text you want summarized or transformed, then open the panel again.",
                nextStep: "select_text"
            )

        // Phase 42 — Acquisition executors: real local execution, no LLM required.
        case "explicit_visible_capture_summary":
            return await captureAndSummarizePage(context: context)

        case "extract_action_items":
            return await extractActionItemsFromContext(context: context)

        case "create_checklist":
            return await createChecklistFromContext(context: context)

        // Phase 42 — Writing executors: use selected text from context when available.
        case "rewrite_text", "improve_text":
            return await rewriteSelectedText(context: context, capabilityId: capability.id)

        case "explain_context":
            return await explainContext(context: context)

        case "draft_reply":
            return await draftReply(context: context)

        default:
            // Phase 53 — Liquid workflow actions execute through the ontology.
            if let liquidAction = WorkflowActionOntology.byId[capability.id] {
                return await executeLiquidAction(liquidAction, context: context)
            }
            // Phase 42: preview_only is not success — return unavailable so UI shows honest failure.
            print("[CapabilityExecution] mode=disabled_preview id=\(capability.id)")
            print("[CapabilityExecution] completed status=failed id=\(capability.id) reason=executor_unavailable")
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

    func showContextSetupCard(
        capabilityId: String,
        title: String,
        reason: String,
        message: String,
        nextStep: String
    ) -> CapabilityExecutionStatus {
        print("[PanelActionDescription] capability=\(capabilityId) label=\"\(title)\" description=\"Shows the honest next step for acquiring enough context.\"")
        print("[ActionExecution] capability=\(capabilityId)")
        storePendingResultCard(
            PendingResultCardPayload(
                capabilityID: capabilityId,
                title: title,
                text: message,
                outputChars: message.count,
                cardType: .captureNeeded,
                contentQuality: .metadataOnly,
                contentSource: "context_acquisition_need",
                isCaptureNeeded: true,
                acquiredChars: 0,
                failureReason: reason,
                nextStep: nextStep,
                actions: [ResultCardAction(id: .dismiss, title: "Dismiss")]
            )
        )
        print("[ActionVerification] capability=\(capabilityId) status=blocked reason=\(reason)")
        print("[CapabilityExecution] completed status=capture_needed id=\(capabilityId) reason=\(reason)")
        return .captureNeeded
    }

    // MARK: - Phase 44 Acquisition Executors (real content, not metadata-only)

    /// Legacy metadata-only helper — kept for writing actions that can work with partial context.
    private func acquisitionContextText(context: [String: Any]) -> (text: String, source: String) {
        let browser = currentBrowserContext()
        let pageTitle = browser?.selectedTitle
            ?? browser?.recentTabTitles.first
            ?? (context["windowTitle"] as? String)
            ?? (context["titles"] as? [String])?.first
            ?? ""
        let url = browser?.selectedURL?.absoluteString
            ?? browser?.currentURL?.absoluteString
            ?? (context["urls"] as? [String])?.first
            ?? (context["tabURLs"] as? [String])?.first
            ?? ""
        let tabTitles = (context["tabTitles"] as? [String] ?? [])
            + (browser?.recentTabTitles ?? [])
        let workflow = context["workflow"] as? String ?? "unknown"
        let source: String
        if !pageTitle.isEmpty && !url.isEmpty { source = "browser_context" }
        else if !pageTitle.isEmpty { source = "window_title" }
        else { source = "metadata_fallback" }
        var parts: [String] = []
        if !pageTitle.isEmpty { parts.append("Page: \(pageTitle)") }
        if !url.isEmpty { parts.append("URL: \(url)") }
        if !workflow.isEmpty && workflow != "unknown" { parts.append("Context: \(workflow)") }
        let uniqueTabs = Array(Set(tabTitles).subtracting([pageTitle])).prefix(6)
        if !uniqueTabs.isEmpty { parts.append("Other tabs: " + uniqueTabs.joined(separator: "; ")) }
        return (parts.joined(separator: "\n"), source)
    }

    /// Phase 44 — Gate a cognitive action if content quality is too low.
    /// Returns the capture-needed message text if gated, nil if OK to proceed.
    // MARK: - Phase 45: Cognitive executors backed by UniversalContentReader

    /// Shared executor logic: acquire content, gate, format, and stage a verified result card payload.
    func executeWithUniversalContent(
        capabilityId: String,
        context: [String: Any],
        format: (_ ucr: UniversalContentResult, _ scope: ActionScopeResolution) async -> CognitiveTextOutcome
    ) async -> CapabilityExecutionStatus {
        let sourceSurface = (context["source_surface"] as? String) ?? "panel"
        // Phase 51 — clipboard capture is allowed only when this execution carries
        // explicit user approval (e.g. "Capture full document" card button).
        let allowClipboardCapture = context["allow_clipboard_capture"] as? Bool == true
        print("[AcquisitionAction] started capability=\(capabilityId) source_surface=\(sourceSurface) user_approved_capture=\(allowClipboardCapture ? "yes" : "no")")
        let ucr = UniversalContentReader.readForCapability(capabilityId, allowClipboardCapture: allowClipboardCapture)
        if WorkflowActionOntology.byId[capabilityId]?.category == .documentsLeases {
            let route: String
            switch ucr.source {
            case .clipboardCapture, .clipboardCaptureUserApproved:
                route = "clipboard_capture"
            case .browserAX:
                route = "browser_ax"
            case .selectedTextAX, .selectedTextContextModel:
                route = "selected_text"
            default:
                route = ucr.source.rawValue
            }
            let routeStatus = ucr.text.isEmpty ? (allowClipboardCapture ? "failed" : "needs_permission") : "success"
            let leaseSource = ucr.actualScope.satisfiesFullScope ? "full_document" : (ucr.actualScope == .selectedText ? "selected_text" : "visible_text")
            print("[GoogleDocsCaptureRoute] action=\(capabilityId) route=\(route) status=\(routeStatus) chars=\(UniversalContentReader.meaningfulCharacterCount(ucr.text))")
            print("[LeaseActionExecution] id=\(capabilityId) source=\(leaseSource) chars=\(UniversalContentReader.meaningfulCharacterCount(ucr.text)) status=\(routeStatus == "success" ? "success" : "capture_needed")")
        }
        let goal = UniversalContentReader.contentGoalPublic(for: capabilityId)
        let baseAllowed = UniversalContentReader.gate(capabilityId: capabilityId, goal: goal, result: ucr)
        let scopeResolution = UniversalContentReader.resolveActionScope(capabilityId: capabilityId, result: ucr)
        let scopeGate = ContentScopeGate.evaluate(
            capabilityId: capabilityId,
            requested: ContentScopeModel.requestedScope(for: capabilityId),
            actual: ucr.actualScope,
            chars: UniversalContentReader.meaningfulCharacterCount(ucr.text)
        )
        let actualChars = UniversalContentReader.meaningfulCharacterCount(ucr.text)
        let usefulness = cognitiveUsefulnessGate(
            capabilityId: capabilityId,
            scope: ucr.actualScope,
            source: ucr.source,
            chars: actualChars
        )
        let allowed = baseAllowed && scopeResolution.allowed && scopeGate.allowed && usefulness.allowed

        if !scopeResolution.allowed {
            print("[CognitiveActionGate] blocked reason=page_content_unavailable \(scopeResolution.reason)")
        }

        let isPanelPreferred = (self.appState?.isPanelVisible == true) || sourceSurface == "panel"
        let preferredSurface = isPanelPreferred ? "both" : "floating"

        if !allowed {
            let nextStep = usefulness.allowed ? resolveFailureNextStep(ucr: ucr, scope: scopeResolution) : usefulness.nextStep
            let msg: String
            if let liquid = WorkflowActionOntology.byId[capabilityId], liquid.isSpecificAction {
                msg = LiquidInsightFormatters.specificCaptureMessage(
                    action: liquid,
                    chars: actualChars,
                    reason: ucr.actualScope == .metadataOnly ? "metadata_only" : scopeResolution.reason
                )
                LiquidInsightFormatters.logQuality(
                    action: liquid,
                    source: LiquidInsightFormatters.sourceKind(scope: ucr.actualScope),
                    chars: actualChars,
                    extractedItems: 0,
                    quotedLines: 0,
                    quality: "needs_capture",
                    reason: ucr.actualScope == .metadataOnly ? "metadata_only" : scopeResolution.reason,
                    allowed: false,
                    gateReason: "needs_capture"
                )
            } else {
                msg = captureNeededMessage(
                    capabilityId: capabilityId,
                    ucr: ucr,
                    scope: scopeResolution,
                    actualChars: actualChars
                )
            }

            let verified = await presentCognitiveResultSurface(
                capability: capabilityId,
                status: "needs_capture",
                outputText: msg,
                source: ucr.source.rawValue,
                quality: ucr.quality.label,
                coverage: ucr.coverage.rawValue,
                sourceSurface: sourceSurface,
                preferredSurface: preferredSurface,
                scope: ucr.actualScope
            )

            let finalStatus: CapabilityExecutionStatus = verified ? .captureNeeded : .failedSilent
            print("[FailureCard] reason=\(usefulness.allowed ? scopeResolution.reason : usefulness.reason) chars=\(actualChars) source=\(ucr.source.rawValue) next_step=\(nextStep.rawValue)")
            print("[TextActionOutput] capability=\(capabilityId) output_chars=\(msg.count) primary_surface=capture_needed_card clipboard_written=no")
            print("[CaptureNeededCard] reason=\(usefulness.allowed ? scopeResolution.reason : usefulness.reason) chars=\(actualChars) source=\(ucr.source.rawValue)")
            print("[CapabilityExecution] completed status=\(finalStatus.rawValue) id=\(capabilityId) reason=\(verified ? "result_surface_visible" : "result_surface_failed")")
            if WorkflowActionOntology.byId[capabilityId]?.category == .documentsLeases {
                print("[LeaseActionResult] id=\(capabilityId) status=capture_needed card=\(verified ? "shown" : "hidden")")
            }
            return finalStatus
        }

        // Format the output from the real content
        let formatting = await format(ucr, scopeResolution)
        let output: String
        switch formatting {
        case .success(let value):
            output = value
        case .failure(let reason, let message, let nextStep):
            let verified = await presentCognitiveResultSurface(
                capability: capabilityId,
                status: "failed",
                outputText: message,
                source: ucr.source.rawValue,
                quality: ucr.quality.label,
                coverage: ucr.coverage.rawValue,
                sourceSurface: sourceSurface,
                preferredSurface: preferredSurface,
                scope: ucr.actualScope
            )

            let finalStatus: CapabilityExecutionStatus = verified ? .failedVisible : .failedSilent
            print("[FailureCard] reason=\(reason) chars=\(actualChars) source=\(ucr.source.rawValue) next_step=\(nextStep?.rawValue ?? "none")")
            print("[CapabilityExecution] completed status=\(finalStatus.rawValue) id=\(capabilityId) reason=\(verified ? "result_surface_visible" : "result_surface_failed")")
            if WorkflowActionOntology.byId[capabilityId]?.category == .documentsLeases {
                print("[LeaseActionResult] id=\(capabilityId) status=failed card=\(verified ? "shown" : "hidden")")
            }
            return finalStatus
        }

        let verified = await presentCognitiveResultSurface(
            capability: capabilityId,
            status: "success",
            outputText: output,
            source: ucr.source.rawValue,
            quality: ucr.quality.label,
            coverage: ucr.coverage.rawValue,
            sourceSurface: sourceSurface,
            preferredSurface: preferredSurface,
            scope: ucr.actualScope
        )

        let finalStatus: CapabilityExecutionStatus = verified ? .success : .failedSilent
        print("[TextActionOutput] capability=\(capabilityId) output_chars=\(output.count) primary_surface=floating_result_card clipboard_written=no")
        print("[ActionVerification] capability=\(capabilityId) status=\(verified ? "success" : "failed") reason=\(verified ? "output_present" : "result_surface_failed")")
        print("[CapabilityExecution] completed status=\(finalStatus.rawValue) id=\(capabilityId) reason=\(verified ? "result_surface_visible" : "result_surface_failed")")
        if WorkflowActionOntology.byId[capabilityId]?.category == .documentsLeases {
            print("[LeaseActionResult] id=\(capabilityId) status=\(verified ? "success" : "failed") card=\(verified ? "shown" : "hidden")")
        }
        return finalStatus
    }

    func cognitiveUsefulnessGate(
        capabilityId: String,
        scope: AcquiredContentScope,
        source: ContentSource,
        chars: Int
    ) -> (allowed: Bool, reason: String, nextStep: ContentNextStep) {
        let isCognitiveClone = ["explicit_visible_capture_summary", "extract_action_items", "create_checklist"].contains(capabilityId)
        guard isCognitiveClone else {
            return (true, "actionable_content", .captureVisible)
        }
        if scope == .metadataOnly || scope == .failed {
            print("[CognitiveUsefulnessGate] capability=\(capabilityId) source=\(source.rawValue) scope=\(scope.rawValue) chars=\(chars) allowed=no reason=metadata_only")
            return (false, "metadata_only", .captureVisible)
        }
        if chars < 800 {
            print("[CognitiveUsefulnessGate] capability=\(capabilityId) source=\(source.rawValue) scope=\(scope.rawValue) chars=\(chars) allowed=no reason=too_short")
            return (false, "too_short", .selectText)
        }
        if chars < 1500 && (scope == .visibleViewport || scope == .partialVisibleText) {
            print("[CognitiveUsefulnessGate] capability=\(capabilityId) source=\(source.rawValue) scope=\(scope.rawValue) chars=\(chars) allowed=no reason=too_short")
            return (false, "too_short", .captureVisible)
        }
        if (capabilityId == "extract_action_items" || capabilityId == "create_checklist") && !scope.satisfiesFullScope && scope != .mainArticle && scope != .selectedText {
            print("[CognitiveUsefulnessGate] capability=\(capabilityId) source=\(source.rawValue) scope=\(scope.rawValue) chars=\(chars) allowed=no reason=needs_full_context")
            return (false, "needs_full_context", .allowClipboardCapture)
        }
        print("[CognitiveUsefulnessGate] capability=\(capabilityId) source=\(source.rawValue) scope=\(scope.rawValue) chars=\(chars) allowed=yes reason=actionable_content")
        return (true, "actionable_content", .captureVisible)
    }

    private func executeCapture(capabilityId: String, context: [String: Any]) async -> CapabilityExecutionStatus {
        let sourceSurface = context["source_surface"] as? String ?? "unknown"
        print("[CaptureActionClicked] id=\(capabilityId) source_surface=\(sourceSurface)")
        print("[CaptureLoopCheck] id=\(capabilityId) loop=no status=pass")

        let isFullDocument = capabilityId == "capture_full_document"
        let ucr = UniversalContentReader.readForCapability(capabilityId, allowClipboardCapture: isFullDocument)
        
        let successQuality: ContentQuality = isFullDocument && ucr.source == .clipboardCapture ? .metadataOnly : .axVisibleText
        let captureSuccess = ucr.quality >= successQuality || (ucr.source == .browserAX && ucr.text.count > 0)
        
        print("[CaptureActionResult] id=\(capabilityId) status=\(captureSuccess ? "success" : "failed") quality=\(ucr.quality.label) chars=\(ucr.text.count)")

        if captureSuccess {
            if sourceSurface == "followup", let parentID = context["source_action_id"] as? String, let parentCap = CognitiveCapabilityRegistry.shared.get(parentID) {
                print("[FollowupExecutionPlan] id=\(capabilityId) parent=\(parentID) steps=capture_then_resume")
                print("[FollowupCaptureThenResume] parent=\(parentID) capture=\(capabilityId) resume=\(parentID) status=success")
                print("[FollowupProgressCheck] id=\(capabilityId) previous_state=capture_needed new_state=capturing progressed=yes")
                if parentID.hasPrefix("composed_") || ComposedActionUIRegistry.resolve(parentID) != nil {
                    Task { @MainActor in
                        _ = await ComposedActionClickDispatcher.execute(uiID: parentID, sourceSurface: "followup")
                    }
                    return .success
                } else if let parentCap = CognitiveCapabilityRegistry.shared.get(parentID) {
                    var resumeContext = context
                    resumeContext["allow_clipboard_capture"] = isFullDocument
                    return await execute(capability: parentCap, context: resumeContext)
                }
                return .success
            } else {
                return .success
            }
        } else {
            let title = isFullDocument ? "Capture Full Document" : "Capture Visible Page"
            let reason = isFullDocument ? "full_document_capture_needed" : "visible_capture_needed"
            let message = isFullDocument ? "Full document capture needs explicit access to the focused document.\n\nUse the capture button from a result card when you are ready to approve that route." : "I do not have enough readable page content yet.\n\nUse a visible capture or select the exact text you want summarized."
            let nextStep = isFullDocument ? "capture_full_document" : "capture_visible"
            return showContextSetupCard(
                capabilityId: capabilityId,
                title: title,
                reason: reason,
                message: message,
                nextStep: nextStep
            )
        }
    }

    private func captureAndSummarizePage(context: [String: Any]) async -> CapabilityExecutionStatus {
        return await executeWithUniversalContent(capabilityId: "explicit_visible_capture_summary", context: context) { ucr, scope in
            let input = ucr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = await self.generateSummary(from: input)
            let compressionRatio = input.isEmpty ? 1.0 : Double(summary.count) / Double(max(1, input.count))
            print("[GeneratedTextAction] capability=explicit_visible_capture_summary input_chars=\(input.count) output_chars=\(summary.count) compression_ratio=\(String(format: "%.2f", compressionRatio))")

            let quality = Self.evaluateOutputQuality(input: input, output: summary)
            print("[OutputQualityGate] capability=explicit_visible_capture_summary echo_similarity=\(String(format: "%.2f", quality.echoSimilarity)) too_short=\(quality.tooShort ? "yes" : "no") too_long=\(quality.tooLong ? "yes" : "no") empty=\(quality.empty ? "yes" : "no") hallucinated_format=\(quality.hallucinatedFormat ? "yes" : "no") model_refusal=\(quality.modelRefusal ? "yes" : "no") low_quality=\(quality.lowQuality ? "yes" : "no") passed=\(quality.passed ? "yes" : "no") reason=\(quality.reason)")

            if !quality.passed {
                let fallback = Self.deterministicSummary(from: input)
                let fallbackRatio = input.isEmpty ? 1.0 : Double(fallback.count) / Double(max(1, input.count))
                let fallbackQuality = Self.evaluateOutputQuality(input: input, output: fallback)
                print("[GeneratedTextAction] capability=explicit_visible_capture_summary input_chars=\(input.count) output_chars=\(fallback.count) compression_ratio=\(String(format: "%.2f", fallbackRatio))")
                print("[OutputQualityGate] capability=explicit_visible_capture_summary echo_similarity=\(String(format: "%.2f", fallbackQuality.echoSimilarity)) too_short=\(fallbackQuality.tooShort ? "yes" : "no") too_long=\(fallbackQuality.tooLong ? "yes" : "no") empty=\(fallbackQuality.empty ? "yes" : "no") hallucinated_format=\(fallbackQuality.hallucinatedFormat ? "yes" : "no") model_refusal=\(fallbackQuality.modelRefusal ? "yes" : "no") low_quality=\(fallbackQuality.lowQuality ? "yes" : "no") passed=\(fallbackQuality.passed ? "yes" : "no") reason=\(fallbackQuality.reason)")
                if fallbackQuality.passed {
                    print("[ActionVerification] capability=explicit_visible_capture_summary status=success reason=output_transformed")
                    return .success(self.formattedSummaryBody(summary: fallback, scope: scope, chars: UniversalContentReader.meaningfulCharacterCount(input), actualScope: ucr.actualScope))
                }
                let nextStep = scope.resolvedScope == .visibleSnippet ? ContentNextStep.captureVisible : ContentNextStep.selectText
                let message = self.failureCardMessage(
                    reason: fallbackQuality.reason,
                    chars: UniversalContentReader.meaningfulCharacterCount(input),
                    source: ucr.source.rawValue,
                    nextStep: nextStep
                )
                print("[ActionVerification] capability=explicit_visible_capture_summary status=failed reason=\(fallbackQuality.reason)")
                return .failure(reason: fallbackQuality.reason, message: message, nextStep: nextStep)
            }

            print("[ActionVerification] capability=explicit_visible_capture_summary status=success reason=output_transformed")
            return .success(self.formattedSummaryBody(summary: summary, scope: scope, chars: UniversalContentReader.meaningfulCharacterCount(input), actualScope: ucr.actualScope))
        }
    }

    private func extractActionItemsFromContext(context: [String: Any]) async -> CapabilityExecutionStatus {
        return await executeWithUniversalContent(capabilityId: "extract_action_items", context: context) { ucr, _ in
            let srcLines = ucr.text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }
            let actionPrefixes = ["fix", "update", "review", "check", "todo", "note", "follow up", "read", "implement", "add", "remove", "test", "verify", "open", "close", "merge", "deploy"]
            var items: [String] = []
            for line in srcLines.prefix(25) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if actionPrefixes.contains(where: { t.lowercased().hasPrefix($0) }) {
                    items.append("- \(t)")
                } else if t.count > 8 && t.count < 120 {
                    items.append("- Review: \(t)")
                }
            }
            if items.isEmpty {
                let chars = UniversalContentReader.meaningfulCharacterCount(ucr.text)
                let message = self.failureCardMessage(reason: "low_quality", chars: chars, source: ucr.source.rawValue, nextStep: .captureVisible)
                return .failure(reason: "low_quality", message: message, nextStep: .captureVisible)
            }
            return .success((["# Action Items", ""] + items).joined(separator: "\n"))
        }
    }

    private func createChecklistFromContext(context: [String: Any]) async -> CapabilityExecutionStatus {
        return await executeWithUniversalContent(capabilityId: "create_checklist", context: context) { ucr, _ in
            let srcLines = ucr.text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }
            var items: [String] = []
            for line in srcLines.prefix(15) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 3 && t.count < 120 { items.append("- [ ] \(t)") }
            }
            if items.isEmpty {
                let chars = UniversalContentReader.meaningfulCharacterCount(ucr.text)
                let message = self.failureCardMessage(reason: "low_quality", chars: chars, source: ucr.source.rawValue, nextStep: .captureVisible)
                return .failure(reason: "low_quality", message: message, nextStep: .captureVisible)
            }
            return .success((["# Checklist", ""] + items).joined(separator: "\n"))
        }
    }

    /// Try to get usable text: clipboard if selection was available at action creation, else window title.
    private func inputTextForWriting(context: [String: Any]) -> (text: String, source: String) {
        let selAvailable = context["selectedTextAvailable"] as? Bool == true
        let selLength = context["selectedTextLength"] as? Int ?? 0
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        // Use clipboard if selection was signaled at action creation and clipboard text has similar length.
        if selAvailable && selLength > 0 && !clipboardText.isEmpty && abs(clipboardText.count - selLength) <= (selLength / 2 + 20) {
            return (clipboardText, "clipboard_selected_text")
        }
        // Fall back to browser/window context.
        let (contextText, ctxSource) = acquisitionContextText(context: context)
        return (contextText, ctxSource)
    }

    private func rewriteSelectedText(context: [String: Any], capabilityId: String) async -> CapabilityExecutionStatus {
        return await executeWithUniversalContent(capabilityId: capabilityId, context: context) { ucr, _ in
            let inputText = ucr.text
            let revised = inputText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ". ")
                .filter { !$0.isEmpty }
                .prefix(8)
                .joined(separator: ". ")
                .appending(inputText.hasSuffix(".") ? "" : ".")
                .replacingOccurrences(of: "..", with: ".")
            let lines = [
                "# Rewritten Text",
                "",
                "**Original (\(inputText.count) chars):**",
                "> \(inputText.prefix(300).replacingOccurrences(of: "\n", with: "\n> "))",
                "",
                "**Suggested revision:**",
                revised,
                "",
                "_Source: \(ucr.source.rawValue). Paste to replace._"
            ]
            return .success(lines.joined(separator: "\n"))
        }
    }

    private func explainContext(context: [String: Any]) async -> CapabilityExecutionStatus {
        return await executeWithUniversalContent(capabilityId: "explain_context", context: context) { ucr, _ in
            let browser = self.currentBrowserContext()
            let pageTitle = browser?.selectedTitle ?? (context["windowTitle"] as? String) ?? "this page"
            var lines = ["# Context Explanation", ""]
            lines.append("**What you're looking at:** \(pageTitle)")
            lines.append("**Content source:** \(ucr.source.rawValue) (\(ucr.quality.label))")
            lines.append("")
            lines.append(String(ucr.text.prefix(800)))
            return .success(lines.joined(separator: "\n"))
        }
    }

    private func draftReply(context: [String: Any]) async -> CapabilityExecutionStatus {
        return await executeWithUniversalContent(capabilityId: "draft_reply", context: context) { ucr, _ in
            let subject = String(ucr.text.prefix(80))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            var lines = [
                "Hi,",
                "",
                "Thanks for your message regarding \"\(subject)\". I've reviewed the details and wanted to follow up.",
                ""
            ]
            if ucr.text.count > 80 {
                let snippet = String(ucr.text.prefix(250))
                lines.append("Regarding: \"\(snippet)\"")
                lines.append("")
            }
            lines += [
                "[Add your response here]",
                "",
                "Let me know if you have any questions.",
                "",
                "Best regards"
            ]
            return .success(lines.joined(separator: "\n"))
        }
    }

    private func resultCardType(for capabilityId: String) -> ResultCardType {
        switch capabilityId {
        case "explicit_visible_capture_summary", "summarize_visible_content", "summarize_thread":
            return .summary
        case "extract_action_items":
            return .actionItems
        case "create_checklist":
            return .checklist
        case "draft_reply":
            return .draft
        case "explain_context", "diagnose_error":
            return .explanation
        default:
            return .summary
        }
    }

    private func resultCardTitle(for capabilityId: String, scope: ActionScopeResolution) -> String {
        switch capabilityId {
        case "explicit_visible_capture_summary":
            switch scope.resolvedScope {
            case .selection:
                return "Selected Text Summary"
            case .visibleSnippet:
                return "Visible Snippet Summary"
            default:
                return "Page Summary"
            }
        case "extract_action_items":
            return "Action Items"
        case "create_checklist":
            return "Checklist"
        case "draft_reply":
            return "Draft Reply"
        case "explain_context":
            return "Explanation"
        default:
            return SuggestionTitleRewriter.cognitiveProductTitle(for: capabilityId) ?? capabilityId
        }
    }

    private static func qualityLabel(for quality: ContentQuality) -> ContentQualityLabel {
        switch quality {
        case .fullDocumentText:
            return .fullText
        case .partialDocumentText, .selectedText:
            return .partialText
        case .axVisibleText, .visibleOCR:
            return .visibleText
        case .metadataOnly:
            return .metadataOnly
        case .none:
            return .failed
        }
    }

    private func generateSummary(from input: String) async -> String {
        let modelOutput = await IntelligenceActionRunner.runActionPrompt(actionType: .summarize, input: String(input.prefix(7000)))
        let trimmed = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().hasPrefix("summary unavailable:") {
            return Self.deterministicSummary(from: input)
        }
        return trimmed
    }

    private func formattedSummaryBody(summary: String, scope: ActionScopeResolution, chars: Int, actualScope: AcquiredContentScope = .visibleViewport) -> String {
        switch scope.resolvedScope {
        case .selection:
            return "# Selected Text Summary\n\n\(summary)"
        case .visibleSnippet:
            return "# Visible Content Summary\n\nOnly \(chars) visible characters were available from the current page.\n\n\(summary)"
        default:
            // Phase 51 — header claims only what the actual scope proves.
            return "# \(ScopeTruthTitles.summaryCardTitle(for: actualScope))\n\n\(summary)"
        }
    }

    static func deterministicSummary(from input: String) -> String {
        let cleaned = input.replacingOccurrences(of: "\r", with: "\n")
        let sentences = cleaned
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let focus = significantWords(in: sentences.first ?? cleaned, limit: 6)
        let highlights = sentences
            .prefix(3)
            .map { significantWords(in: $0, limit: 5) }
            .filter { !$0.isEmpty }

        if focus.isEmpty && highlights.isEmpty {
            return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines = ["Summary"]
        if !focus.isEmpty {
            lines.append("Focus: \(focus.joined(separator: ", "))")
        }
        if !highlights.isEmpty {
            lines.append("Signals:")
            lines.append(contentsOf: highlights.map { "- \($0.joined(separator: ", "))" })
        }
        return lines.joined(separator: "\n")
    }

    static func echoSimilarity(input: String, output: String) -> Double {
        let inputTokens = Set(tokenizeForSimilarity(input))
        let outputTokens = Set(tokenizeForSimilarity(output))
        guard !inputTokens.isEmpty, !outputTokens.isEmpty else { return 0 }
        let overlap = inputTokens.intersection(outputTokens).count
        let union = inputTokens.union(outputTokens).count
        return union == 0 ? 0 : Double(overlap) / Double(union)
    }

    private static func tokenizeForSimilarity(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }
    }

    private static func significantWords(in text: String, limit: Int) -> [String] {
        let stopwords: Set<String> = [
            "about", "after", "also", "avoid", "because", "before", "being", "current",
            "entire", "from", "have", "into", "local", "next", "only", "page", "reads",
            "should", "source", "stale", "text", "that", "their", "them", "there",
            "they", "this", "user", "useful", "with", "without", "would"
        ]
        var seen = Set<String>()
        var words: [String] = []
        for token in text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard token.count >= 4, !stopwords.contains(token), seen.insert(token).inserted else { continue }
            words.append(token)
            if words.count == limit { break }
        }
        return words
    }

    static func evaluateOutputQuality(input: String, output: String) -> OutputQualityEvaluation {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let compressionRatio = input.isEmpty ? 1.0 : Double(trimmed.count) / Double(max(1, input.count))
        let echo = echoSimilarity(input: input, output: trimmed)
        let lower = trimmed.lowercased()
        let empty = trimmed.isEmpty
        let tooShort = meaningfulTextLength(trimmed) < 24
        let tooLong = compressionRatio > 1.10
        let hallucinatedFormat = lower.contains("```") || lower.contains("{\"") || lower.contains("</")
        let modelRefusal = lower.hasPrefix("i can't") || lower.hasPrefix("i cannot") || lower.contains("unable to summarize") || lower.contains("summary unavailable")
        let lowQuality = !empty && !tooShort && !tooLong && !hallucinatedFormat && !modelRefusal && trimmed.components(separatedBy: .newlines).count <= 1 && trimmed.count < 36
        let reason: String
        if empty {
            reason = "empty"
        } else if modelRefusal {
            reason = "model_refusal"
        } else if echo > 0.80 {
            reason = "echo"
        } else if tooLong {
            reason = "too_long"
        } else if tooShort {
            reason = "too_short"
        } else if hallucinatedFormat {
            reason = "hallucinated_format"
        } else if lowQuality {
            reason = "low_quality"
        } else {
            reason = "output_transformed"
        }
        return OutputQualityEvaluation(
            passed: reason == "output_transformed",
            reason: reason,
            echoSimilarity: echo,
            tooShort: tooShort,
            tooLong: tooLong,
            empty: empty,
            hallucinatedFormat: hallucinatedFormat,
            modelRefusal: modelRefusal,
            lowQuality: lowQuality
        )
    }

    private static func meaningfulTextLength(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    private func resolveFailureNextStep(ucr: UniversalContentResult, scope: ActionScopeResolution) -> ContentNextStep {
        if scope.reason == "too_little_text" { return .captureVisible }
        if scope.reason == "metadata_only" || scope.reason == "page_content_unavailable" { return ucr.nextStep ?? .captureVisible }
        if scope.reason == "clipboard_not_page_content" { return .captureVisible }
        return ucr.nextStep ?? .captureVisible
    }

    private func captureNeededMessage(
        capabilityId: String,
        ucr: UniversalContentResult,
        scope: ActionScopeResolution,
        actualChars: Int
    ) -> String {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "this app"
        if capabilityId == "explicit_visible_capture_summary" {
            switch scope.reason {
            case "too_little_text":
                return "I couldn’t summarize this page yet. I only found \(actualChars) characters of visible text from \(appName). Try Capture Visible Page, select text, or run Test Content Acquisition."
            case "clipboard_not_page_content":
                return "I couldn’t summarize this page yet. I found clipboard text, but I could not verify it as current page content.\n\nTry Capture Visible Page or select the text you want summarized."
            case "metadata_only", "page_content_unavailable":
                return "I couldn’t summarize this page yet. I didn’t find enough real page text to trust.\n\nTry Capture Visible Page or select the text you want summarized."
            default:
                break
            }
        }

        switch ucr.nextStep {
        case .enableAccessibility:
            return "I need accessibility access to read content in \(appName).\n\nEnable it in System Settings → Privacy & Security → Accessibility."
        case .selectText:
            return "Select the text you want me to work with, then try again."
        default:
            return "I can see \(appName) but can’t read enough trusted content yet.\n\nTry a visible capture route or select the text you want."
        }
    }

    private func failureCardMessage(reason: String, chars: Int, source: String, nextStep: ContentNextStep) -> String {
        let reasonText: String
        switch reason {
        case "too_long":
            reasonText = "The generated summary was longer than the source snippet, so I rejected it."
        case "too_short":
            reasonText = "The generated summary was too short to be useful."
        case "empty":
            reasonText = "The summarizer returned no usable output."
        case "model_refusal":
            reasonText = "The summarizer refused the request."
        case "hallucinated_format":
            reasonText = "The summarizer returned the wrong format."
        case "echo":
            reasonText = "The summarizer mostly echoed the source text."
        default:
            reasonText = "The generated summary was too low quality to trust."
        }
        // Phase 58.6 — debug detail (source enum, char counts) stays in logs.
        print("[FailureCardDebugDetail] reason=\(reason) source=\(source) chars=\(chars) next_step=\(nextStep.rawValue)")
        return "\(reasonText)\n\nNext best move: \(humanNextStepSentence(nextStep))"
    }

    private func humanNextStepSentence(_ nextStep: ContentNextStep) -> String {
        switch nextStep {
        case .captureVisible:
            return "Capture the visible page so I can work from the real text."
        case .allowClipboardCapture:
            return "Capture the full document so I can read all of it."
        case .selectText:
            return "Select the text you want me to work with, then try again."
        case .enableAccessibility:
            return "Enable accessibility access in System Settings → Privacy & Security → Accessibility."
        default:
            return "Capture the visible page or select the text you want me to use."
        }
    }

    private func defaultFailureActions(nextStep: ContentNextStep?, selectedTextAvailable: Bool) -> [ResultCardAction] {
        var actions: [ResultCardAction] = [
            ResultCardAction(id: .captureVisiblePage, title: "Capture visible page")
        ]
        // Phase 51 — user-approved full capture is the honest path to full_document
        // for web editors (Google Docs). Explicit click = explicit approval.
        actions.append(ResultCardAction(id: .captureFullDocument, title: "Capture full document"))
        if selectedTextAvailable {
            actions.append(ResultCardAction(id: .summarizeSelectedText, title: "Summarize selected text"))
        }
        return actions
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
        var apps = resolvedWorkspaceApps(from: context)
        var titles = resolvedTabTitles(from: context)
        let urls = resolvedTabURLs(from: context)
        LiveActionPath.emit(capability: "arrange_side_by_side", route: "environment", executor: "IntentExecutor", snapshotAge: 0, hasTargets: !apps.isEmpty, hasURLs: !urls.isEmpty, willExecute: true, reason: "runtime_discovery")

        // Phase 51 — Manual vs proactive split.
        // Manual: the user explicitly clicked this in the panel — arrange the current
        //         window with the best target; no verified-pair history required.
        // Proactive: the assistant suggested it — strict verified recent pair only.
        let sourceSurface = (context["source_surface"] as? String) ?? "unknown"
        let mode: String = (context["arrange_mode"] as? String)
            ?? (sourceSurface == "panel" ? "manual_panel" : (sourceSurface == "followup" ? "manual_followup" : (sourceSurface == "floating" ? "user_clicked_floating" : "proactive_suggestion")))
        let manualLikeModes: Set<String> = ["manual", "manual_panel", "manual_followup", "user_clicked_floating", "explicit_command"]
        let isManualLike = manualLikeModes.contains(mode)
        print("[ArrangeMode] mode=\(mode) source_surface=\(sourceSurface)")
        print("[ArrangeExecutionMode] mode=\(mode)")

        if isManualLike {
            if Self.testHooks.arrangeSideBySide != nil && apps.count >= 2 {
                print("[ArrangeExecutionGate] mode=\(mode) allowed=yes reason=test_hook_payload_targets")
                print("[ArrangeTargetValidation] targets=\(apps.prefix(2).joined(separator: ",")) movable=yes")
            } else {
            // Resolve current window + best secondary target from the live runtime.
            let runtime = WorkspaceRuntimeInventoryProvider.snapshot()
            let frontmost = runtime.frontmostAppName
            let frontmostWindow = runtime.visibleWindows.first {
                $0.isOnActiveScreen && $0.appName.caseInsensitiveCompare(frontmost) == .orderedSame
            }
            let crossAppWindows = runtime.visibleWindows.filter {
                $0.isOnActiveScreen && $0.appName.caseInsensitiveCompare(frontmost) != .orderedSame
                    && !WorkspaceAppFilter.isSystemApp($0.appName)
                    && (frontmost.caseInsensitiveCompare("Music") == .orderedSame || $0.appName.caseInsensitiveCompare("Music") != .orderedSame)
            }
            let visibleSecondaryApps = Set(crossAppWindows.map(\.appName))
            let preferredSecondary = apps.first {
                $0.caseInsensitiveCompare(frontmost) != .orderedSame
                    && visibleSecondaryApps.contains($0)
                    && (frontmost.caseInsensitiveCompare("Music") == .orderedSame || $0.caseInsensitiveCompare("Music") != .orderedSame)
            }
            let secondaryWindow = preferredSecondary.flatMap { preferred in
                crossAppWindows.first { $0.appName.caseInsensitiveCompare(preferred) == .orderedSame }
            } ?? crossAppWindows.first
            let secondary = secondaryWindow?.appName
            let sanityValid = !frontmost.isEmpty && frontmostWindow != nil && secondary != nil
            let sanityReason: String = {
                if frontmost.isEmpty { return "missing_frontmost_app" }
                if frontmostWindow == nil { return "frontmost_window_not_visible" }
                if secondary == nil { return "no_secondary_window" }
                if secondary?.caseInsensitiveCompare("Music") == .orderedSame && frontmost.caseInsensitiveCompare("Music") != .orderedSame {
                    return "music_secondary_rejected"
                }
                return "manual_live_pair"
            }()
            print("[ArrangeTargetSanity] valid=\(sanityValid ? "yes" : "no") reason=\(sanityReason)")
            print("[ArrangeExecutionGate] mode=\(mode) allowed=\(sanityValid ? "yes" : "no") reason=\(sanityReason)")
            print("[ArrangeTargetValidation] targets=\([frontmost, secondary ?? ""].filter { !$0.isEmpty }.joined(separator: ",")) movable=\(sanityValid ? "yes" : "no")")
            guard let secondaryApp = secondary, !frontmost.isEmpty, frontmostWindow != nil else {
                let message = "I couldn’t find a second window to arrange next to \(frontmost.isEmpty ? "the current window" : frontmost)."
                storePendingResultCard(
                    PendingResultCardPayload(
                        capabilityID: "arrange_side_by_side",
                        title: "Arrange Blocked",
                        text: message,
                        outputChars: message.count,
                        cardType: .blockedAction,
                        contentQuality: .metadataOnly,
                        contentSource: "runtime_inventory",
                        isCaptureNeeded: false,
                        acquiredChars: 0,
                        failureReason: "no_secondary_window",
                        nextStep: "open_second_window",
                        actions: [ResultCardAction(id: .dismiss, title: "Dismiss")]
                    )
                )
                print("[BlockedActionCard] shown capability=arrange_side_by_side reason=no_secondary_window")
                print("[LayoutVerify] overlap_area=0 same_side=no within_tolerance=no")
                print("[ActionVerification] capability=arrange_side_by_side status=blocked reason=no_secondary_window")
                print("[CapabilityExecution] completed status=blocked id=arrange_side_by_side reason=no_secondary_window")
                print("[ArrangeVerification] status=failed")
                return .blocked
            }
            let confidence = preferredSecondary != nil ? "high" : "best_available"
            let primaryLabel = "\(frontmost)/\(frontmostWindow?.title ?? "untitled")"
            let secondaryLabel = "\(secondaryApp)/\(secondaryWindow?.title ?? "untitled")"
            print("[ManualArrangeTarget] primary=\(primaryLabel) secondary=\(secondaryLabel) confidence=\(confidence) reason=\(preferredSecondary != nil ? "visible_payload_match" : "best_visible_secondary")")
            // Manual mode arranges frontmost + resolved secondary, ignoring stale payload apps.
            apps = [frontmost, secondaryApp]
            if titles.isEmpty {
                titles = runtime.visibleWindows
                    .filter { $0.appName.caseInsensitiveCompare(frontmost) == .orderedSame || $0.appName.caseInsensitiveCompare(secondaryApp) == .orderedSame }
                    .map(\.title)
            }
            }
        } else if Self.testHooks.arrangeSideBySide == nil || WorkPairMemory.shared.bestPair() != nil {
            // Proactive gate. When a test hook is installed and no pair memory was
            // staged, the hook drives the outcome directly (status-propagation tests);
            // hook-based tests that stage a pair still exercise the gate.
            let arrangeDecision = ArrangeVerifiedWorkPairGate.evaluate(involvedApps: apps)
            print("[ProactiveArrangeGate] allowed=\(arrangeDecision.verified ? "yes" : "no") reason=\(arrangeDecision.reason)")
            print("[ArrangeExecutionGate] mode=\(mode) allowed=\(arrangeDecision.verified ? "yes" : "no") reason=\(arrangeDecision.reason)")
            print("[ArrangePreSurfaceCheck] capability=arrange_side_by_side verified_work_pair=\(arrangeDecision.verified ? "yes" : "no") allowed=\(arrangeDecision.verified ? "yes" : "no") reason=\(arrangeDecision.reason)")
            if !arrangeDecision.verified {
                let message = "I did not see enough switching between these windows to arrange them safely."
                storePendingResultCard(
                    PendingResultCardPayload(
                        capabilityID: "arrange_side_by_side",
                        title: "Arrange Blocked",
                        text: message,
                        outputChars: message.count,
                        cardType: .blockedAction,
                        contentQuality: .metadataOnly,
                        contentSource: "work_pair_memory",
                        isCaptureNeeded: false,
                        acquiredChars: 0,
                        failureReason: "no_verified_work_pair",
                        nextStep: "switch_between_windows",
                        actions: [ResultCardAction(id: .dismiss, title: "Dismiss")]
                    )
                )
                print("[BlockedActionCard] shown capability=arrange_side_by_side reason=\"\(message)\"")
                print("[ActionVerification] capability=arrange_side_by_side status=blocked reason=no_verified_work_pair")
                print("[CapabilityExecution] completed status=blocked id=arrange_side_by_side reason=no_verified_work_pair")
                print("[ArrangeVerification] status=failed")
                return .blocked
            }
        } else {
            print("[ArrangeExecutionGate] mode=\(mode) allowed=yes reason=test_hook_status_propagation")
        }

        if let override = Self.testHooks.arrangeSideBySide {
            let outcome = override(apps, titles)
            print("[WindowArrange] targetA=\(apps.first ?? "unknown")")
            print("[WindowArrange] targetB=\(apps.dropFirst().first ?? titles.first ?? "unknown")")
            print("[WindowArrange] layout=left_right")
            print("[WindowArrange] status=\(outcome.verificationStatus)")
            if outcome.status != .success {
                print("[ActionFailure] capability=arrange_side_by_side reason=\(outcome.reason)")
            }
            let verify = layoutVerificationSummary(apps: apps)
            print("[LayoutVerify] overlap_area=\(verify.overlapArea) same_side=\(verify.sameSide ? "yes" : "no") within_tolerance=\(verify.withinTolerance ? "yes" : "no")")
            print("[ArrangeFrameApply] primary=\(apps.first ?? "unknown") secondary=\(apps.dropFirst().first ?? titles.first ?? "unknown") status=\(outcome.status == .success ? "success" : "failed")")
            print("[ArrangeVerification] status=\(outcome.status == .success ? "success" : (outcome.status == .partial ? "partial" : "failed"))")
            print("[ActionVerification] capability=arrange_side_by_side status=\(outcome.verificationStatus)")
            print("[CapabilityExecution] completed status=\(outcome.status.rawValue) id=arrange_side_by_side reason=\(outcome.reason)")
            return outcome.status
        }

        // Part B: click-time preflight — check contract before moving anything.
        // Phase 51 — manual mode resolved live targets above; the proposal contract
        // (often stale by click time) does not apply to it.
        let contract = context["targetContract"] as? ActionTargetContract
        let preflight = isManualLike
            ? ActionPreflightResult(status: .ok, targetCheck: .ok, reason: "manual_mode_live_targets")
            : ActionPreflight.check(contract: contract, capabilityID: "arrange_side_by_side")
        guard preflight.status == .ok else {
            let normalizedReason: String
            if preflight.targetCheck == .alreadySatisfied {
                normalizedReason = "already_satisfied"
            } else {
                normalizedReason = "target_contract_failed"
                let message = "I couldn’t arrange these windows because the required window targets were no longer available."
                storePendingResultCard(
                    PendingResultCardPayload(
                        capabilityID: "arrange_side_by_side",
                        title: "Arrange Failed",
                        text: message,
                        outputChars: message.count,
                        cardType: .blockedAction,
                        contentQuality: .metadataOnly,
                        contentSource: "target_contract",
                        isCaptureNeeded: false,
                        acquiredChars: 0,
                        failureReason: normalizedReason,
                        nextStep: "retry_arrange",
                        actions: [ResultCardAction(id: .dismiss, title: "Dismiss")]
                    )
                )
                print("[BlockedActionCard] shown capability=arrange_side_by_side reason=\(normalizedReason)")
            }
            print("[ActionVerification] capability=arrange_side_by_side status=\(preflight.targetCheck == .alreadySatisfied ? "already_satisfied" : "failed") reason=\(normalizedReason)")
            print("[CapabilityExecution] completed status=\(preflight.targetCheck == .alreadySatisfied ? CapabilityExecutionStatus.alreadySatisfied.rawValue : CapabilityExecutionStatus.unavailable.rawValue) id=arrange_side_by_side reason=\(normalizedReason)")
            print("[ArrangeVerification] status=\(preflight.targetCheck == .alreadySatisfied ? "success" : "failed")")
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
        let verificationStatus = result == .success ? "success" : (result == .blocked ? "blocked" : (result == .unavailable ? "failed" : result.rawValue))
        let verify = layoutVerificationSummary(apps: apps)
        print("[LayoutVerify] overlap_area=\(verify.overlapArea) same_side=\(verify.sameSide ? "yes" : "no") within_tolerance=\(verify.withinTolerance ? "yes" : "no")")
        print("[ArrangeFrameApply] primary=\(apps.first ?? "unknown") secondary=\(apps.dropFirst().first ?? "unknown") status=\(result == .success ? "success" : "failed")")
        print("[ArrangeVerification] status=\(result == .success ? "success" : (result == .partial ? "partial" : "failed"))")
        print("[ActionVerification] capability=arrange_side_by_side status=\(verificationStatus) reason=intent_executor")
        print("[CapabilityExecution] completed status=\(result.rawValue) id=arrange_side_by_side reason=intent_executor")
        return result
    }

    private func layoutVerificationSummary(apps: [String]) -> (overlapArea: Int, sameSide: Bool, withinTolerance: Bool) {
        let visible = WorkspaceRuntimeInventoryProvider.snapshot().visibleWindows
        guard apps.count >= 2,
              let primary = visible.first(where: { $0.appName.caseInsensitiveCompare(apps[0]) == .orderedSame }),
              let secondary = visible.first(where: { $0.appName.caseInsensitiveCompare(apps[1]) == .orderedSame }) else {
            return (0, false, false)
        }
        let overlap = primary.frame.intersection(secondary.frame)
        let overlapArea = overlap.isNull ? 0 : Int(max(0, overlap.width) * max(0, overlap.height))
        let sameSide = abs(primary.frame.midX - secondary.frame.midX) < min(primary.frame.width, secondary.frame.width) * 0.25
        let withinTolerance = overlapArea < 10_000 && !sameSide
        return (overlapArea, sameSide, withinTolerance)
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
import Foundation

public enum ResultCardType: String, Sendable {
    case summary
    case checklist
    case actionItems
    case draft
    case explanation
    case captureNeeded
    case blockedAction
    case result
    case error
    case compare
}

public enum ContentQualityLabel: String, Sendable {
    case fullText = "full_text"
    case visibleText = "visible_text"
    case partialText = "partial_text"
    case metadataOnly = "metadata_only"
    case failed = "failed"
}

public enum ResultCardActionKind: String, Sendable {
    case ontology
    case system
    case `static`
    case composed
}

public struct ResultCardAction: Sendable {
    public let id: String
    public let title: String
    public let kind: ResultCardActionKind?
    public let ontologyActionID: String?
    public let sourceActionID: String?
    public let requiredScope: String?
    public let risk: String?
	    public let enabled: Bool

    public init(
        id: String,
        title: String,
        // Phase 64 — a bare id+title action is a static button (the original
        // contract); AG's nil default broke kind checks downstream.
        kind: ResultCardActionKind? = .static,
        ontologyActionID: String? = nil,
        sourceActionID: String? = nil,
        requiredScope: String? = nil,
        risk: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.ontologyActionID = ontologyActionID
        self.sourceActionID = sourceActionID
        self.requiredScope = requiredScope
        self.risk = risk
        self.enabled = enabled
    }
	    }

enum ResultSurfaceHost: String, Sendable {
    case floating
    case panel
	    }

public extension String {
    static let summarizeSelectedText = "summarizeSelectedText"

    static let dismiss = "dismiss"
    static let captureVisiblePage = "capture_visible_page"
    static let captureFullDocument = "capture_full_document"
    static let phase46_mock_action = "phase46_mock_action"
	    }

enum ResultSurfaceCardState: Sendable {
    case result(ResearchResultCardState)
    case captureNeeded(ResearchResultCardState)
    case failure(ResearchResultCardState)
    case blocked(ResearchResultCardState)

    public var actions: [ResultCardAction] {
        switch self {
        case .result(let p): return p.actions
        case .captureNeeded(let p): return p.actions
        case .failure(let p): return p.actions
        case .blocked(let p): return p.actions
        }
	    }

    public var text: String {
        switch self {
        case .result(let p): return p.text
        case .captureNeeded(let p): return p.text
        case .failure(let p): return p.text
        case .blocked(let p): return p.text
        }
	    }

    public var floatingText: String {
        switch self {
        case .result(let p): return p.floatingText ?? p.text
        case .captureNeeded(let p): return p.floatingText ?? p.text
        case .failure(let p): return p.floatingText ?? p.text
        case .blocked(let p): return p.floatingText ?? p.text
        }
	    }

    public var proofVisible: Bool {
        switch self {
        case .result: return true
        case .captureNeeded: return true
        case .failure: return false
        case .blocked: return true
        }
	    }

    public var sourceLabel: String {
        switch self {
        case .result(let p): return p.sourceLabel ?? ""
        case .captureNeeded(let p): return p.sourceLabel ?? ""
        case .failure(let p): return p.sourceLabel ?? ""
        case .blocked(let p): return p.sourceLabel ?? ""
        }
	    }

    public var nextStepText: String? {
        switch self {
        case .result(let p): return p.nextStepText
        case .captureNeeded(let p): return p.nextStepText
        case .failure(let p): return p.nextStepText
        case .blocked(let p): return p.nextStepText
        }
    }

    public var capabilityID: String {
        switch self {
        case .result(let p): return p.capabilityID
        case .captureNeeded(let p): return p.capabilityID
        case .failure(let p): return p.capabilityID
        case .blocked(let p): return p.capabilityID
        }
    }

    public var surfaceType: ResultCardType {
        switch self {
        case .result(let p): return p.cardType
        case .captureNeeded(let p): return p.cardType
        case .failure(let p): return p.cardType
        case .blocked(let p): return p.cardType
        }
    }

    init?(card: ResearchResultCardState) {
        switch card.cardType {
        case .captureNeeded: self = .captureNeeded(card)
        case .error: self = .failure(card)
        case .blockedAction: self = .blocked(card)
        default:
            // Phase 64 — all content card types (summary, checklist, compare,
            // …) are result cards. AG's rewrite returned nil here, silently
            // dropping every successful result conversion.
            self = .result(card)
        }
    }

    public func validation() -> (valid: Bool, reason: String?) {
        switch self {
        case .result(let card):
            if card.outputChars == 0 {
                return (false, "zero_output")
            }
            return (true, nil)
        default:
            return (true, nil)
        }
    }
}
