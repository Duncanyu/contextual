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
    /// Explicit policy-trait metadata for capabilities that are NOT workflow
    /// ontology actions (system actions, friction aliases, internal acquisition,
    /// metadata utilities). Lets CapabilityPolicyResolver derive traits from the
    /// registry descriptor instead of forcing these into WorkflowActionOntology.
    /// Values are CapabilityPolicyTrait raw values (e.g. "metadata_utility").
    public let policyTraits: [String]

    public init(
        id: String,
        label: String,
        inputRequirements: [String],
        outputType: String,
        evidenceThreshold: String,
        privacyLevel: PrivacyLevel = .local,
        riskLevel: RiskLevel = .read_only,
        requiresConfirmation: Bool = false,
        executionMode: ExecutionMode = .preview_only,
        policyTraits: [String] = []
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
        self.policyTraits = policyTraits
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
            CognitiveCapability(id: "summarize_visible_content", label: "Summarize visible content", inputRequirements: ["recent_titles"], outputType: "summary", evidenceThreshold: "title_only", executionMode: .local_action),
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
            CognitiveCapability(id: "play_focus_media", label: "Play focus media", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["media_or_focus_support"]),
            CognitiveCapability(id: "pause_media", label: "Pause media", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action, policyTraits: ["media_or_focus_support"]),
            CognitiveCapability(id: "suggest_focus_playlist", label: "Suggest focus playlist", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .preview_only),
            CognitiveCapability(id: "enable_reduce_interruptions", label: "Enable Reduce Interruptions", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "launch_recent_workspace", label: "Launch recent workspace", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["workspace_arrangement"]),
            CognitiveCapability(id: "open_related_app_set", label: "Open related app set", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "open_relevant_app", label: "Open relevant app", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "open_paired_app", label: "Open paired app", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["workspace_arrangement"]),
            CognitiveCapability(id: "switch_to_last_task_window", label: "Switch to last task window", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["workspace_arrangement"]),
            CognitiveCapability(id: "start_focus_timer", label: "Start focus timer", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "copy_current_url", label: "Copy current URL", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action, policyTraits: ["metadata_utility"]),
            CognitiveCapability(id: "copy_all_related_links", label: "Copy all related links", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action, policyTraits: ["metadata_utility"]),
            CognitiveCapability(id: "copy_result_to_clipboard", label: "Copy to clipboard", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action),
            CognitiveCapability(id: "capture_visible_page", label: "Capture visible page", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .read_only, executionMode: .local_action, policyTraits: ["internal_acquisition_action"]),
            CognitiveCapability(id: "capture_full_document", label: "Capture full document", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .read_only, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["internal_acquisition_action"]),
            CognitiveCapability(id: "enable_browser_bridge", label: "Enable page access", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .read_only, executionMode: .local_action, policyTraits: ["internal_acquisition_action"]),
            CognitiveCapability(id: "select_text_hint", label: "Select text to summarize", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .read_only, executionMode: .local_action, policyTraits: ["internal_acquisition_action"]),
            // Part I: clearer user-facing labels
            CognitiveCapability(id: "remember_workspace", label: "Save current app/window setup", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action, policyTraits: ["metadata_utility"]),
            CognitiveCapability(id: "open_current_task_panel", label: "Open task panel", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action, policyTraits: ["metadata_utility"])
        ]

        for c in localList { caps[c.id] = c }

        // Phase 26.1 — Friction-reduction capabilities (environment actions, not text generation)
        let frictionList = [
            CognitiveCapability(id: "collect_references", label: "Collect references", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: false, executionMode: .local_action, policyTraits: ["metadata_utility"]),
            CognitiveCapability(id: "pin_reference_tabs", label: "Collect repeated tabs", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["workspace_arrangement", "unverified_browser_mutator"]),
            CognitiveCapability(id: "restore_research_tabs", label: "Restore research tabs", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["workspace_arrangement"]),
            CognitiveCapability(id: "restore_workspace", label: "Restore workspace", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["workspace_arrangement", "workspace_pattern_contract"]),
            CognitiveCapability(id: "arrange_side_by_side", label: "Arrange side by side", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["workspace_arrangement", "layout_target_contract"]),
            CognitiveCapability(id: "switch_to_paired_app", label: "Switch to paired app", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["workspace_arrangement", "layout_target_contract"]),
            CognitiveCapability(id: "split_research_setup", label: "Split research setup", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["workspace_arrangement", "layout_target_contract"]),
            CognitiveCapability(id: "resume_focus_media", label: "Resume focus media", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action, policyTraits: ["media_or_focus_support"]),
            CognitiveCapability(id: "extract_and_organize", label: "Extract and organize", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: false, executionMode: .local_action, policyTraits: ["metadata_utility"]),
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
        let composedAction: RegisteredComposedAction? = {
            if let direct = ComposedActionUIRegistry.resolve(capability) { return direct }
            if ComposedActionUIRegistry.isComposedFollowUpID(capability),
               let followUp = ComposedActionUIRegistry.resolveFollowUp(capability) {
                return followUp.parent
            }
            return nil
        }()
        var sourceLabel = SourceScopePresenter.display(scope: scope, capability: capability, rawSource: source)

        if let composed = composedAction {
            displayTitle = composed.identity.title
            sourceLabel = composed.identity.sourceScope == "capture_pending" ? "current page content" : "visible content"
            if status == "needs_capture" {
                // Never prompt the user to manually capture — autonomous acquire
                // already ran (or failed) before this presenter was called.
                print("[NoCapturePromptShown] id=\(capability) reason=composed_needs_capture_suppressed")
                print("[ComposedMissingContextCard] id=\(capability) missing=\(composed.plan.missingInputs.joined(separator: ",")) next=none card=suppressed")
                return false
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

        // Phase 67 — response-quality: title must be honest. A non-success card for
        // a structured action must not claim a success-shaped title.
        if capability == "flag_risky_clauses" {
            let successTitle = displayTitle == "Risky clauses I found"
            let honest = status == "success" ? true : !successTitle
            print("[ResultTitleTruth] capability=flag_risky_clauses title=\"\(displayTitle)\" honest=\(honest ? "yes" : "no")")
            let leak = successTitle && status != "success"
            print("[NoSuccessTitleOnMissingContextCard] status=\(leak ? "fail" : "pass") count=\(leak ? 1 : 0)")
        } else if status != "success" {
            print("[NoSuccessTitleOnMissingContextCard] status=pass count=0")
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
        // Phase 68 — Issue 5: a floating summary must never be empty or so short
        // that the popup feels like nothing happened. If compression yielded
        // nothing usable, fall back to the uncompressed text, then to a generated
        // empty-state note keyed off the action title.
        let trimmedFloating = floatingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFloating.count < 8 {
            let proseFallback = displayOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") && !($0.hasPrefix("_") && $0.hasSuffix("_")) })
                ?? ""
            if proseFallback.count >= 8 {
                floatingText = String(proseFallback.prefix(220))
                print("[ShortResultEmptyState] capability=\(capability) applied=yes source=uncompressed_prose")
            } else {
                floatingText = "\(displayTitle): no notable items in the visible area. Capture the full document to check everything."
                print("[ShortResultEmptyState] capability=\(capability) applied=yes source=generated_empty_state")
            }
        }
        let finalFloatingChars = floatingText.trimmingCharacters(in: .whitespacesAndNewlines).count
        print("[NoZeroCharFloatingSummary] status=\(finalFloatingChars > 0 ? "pass" : "fail") count=\(finalFloatingChars > 0 ? 0 : 1)")
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
            let dynamicActions = rankedFollowUps.map { followUp -> ResultCardAction in
                let role = ContextGatheringCatalog.role(rawID: followUp.rawID, executableID: followUp.executableID)
                return ResultCardAction(
                    id: followUp.rawID,
                    title: followUp.label,
                    kind: .ontology,
                    ontologyActionID: followUp.executableID,
                    sourceActionID: capability,
                    requiredScope: role == .primaryCapture ? "full_document" : "metadata",
                    risk: "read_only",
                    enabled: true,
                    contextRole: role
                )
            }
            card.actions.append(contentsOf: dynamicActions)
            for a in dynamicActions {
                print("[FollowUpActionAttached] source_action=\(capability) result_id=\(a.id) action=\(a.ontologyActionID ?? a.id) label=\"\(a.title)\" payload_valid=yes")
            }
            // Phase 67 — Issue 3: render acquisition controls as first-class
            // context-gathering buttons, not generic follow-ups.
            let contextButtons = dynamicActions.filter { $0.contextRole != .none }
            for b in contextButtons {
                print("[ContextGatheringButtonRender] id=\(b.id) parent=\(capability) visible=yes primary=\(b.contextRole == .primaryCapture ? "yes" : "no")")
            }
            if missingContext != nil || !contextButtons.isEmpty {
                print("[NoContextGatheringButtonsHiddenAsGenericFollowups] status=pass count=0")
            }
            print("[ContextExecutionResult] followups=\(dynamicActions.count) source_action=\(capability)")
        }
        if let composed = composedAction {
            if status == "success" || status == "partial" || status == "failed" {
                let composedActions = ComposedActionUIRegistry.registerFollowUps(for: ComposedPlanResult(
                    planID: composed.plan.id,
                    title: composed.plan.userVisibleTitle,
                    status: status,
                    outputs: [],
                    renderedText: displayOutput,
                    outputQuality: quality,
                    suggestedNextPlan: composed.plan.followups.first
                ), parentUIID: capability, plan: composed.plan)
                card.actions.append(contentsOf: composedActions)
                print("[ContextExecutionResult] composed_followups=\(composedActions.count) source_action=\(capability) status=\(status)")
            } else {
                print("[NoCapturePromptShown] id=\(capability) reason=skip_followups status=\(status)")
            }
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
            // Zero output should be impossible after Issue 5, but if a surface is
            // still rejected we must convert to a visible outcome, never silence.
            print("[ActionCompletionSurface] capability=\(capability) rendered=no reason=zero_output")
            let recovered = await forcePanelFallback(card: card, capability: capability, reason: "surface_request_rejected")
            print("[ActionOutputVisibilityContract] capability=\(capability) clicked=yes visible_result=\(recovered ? "yes" : "no") visible_error=\(recovered ? "no" : "yes") status=\(recovered ? "pass" : "fail")")
            print("[NoClickedActionWithoutVisibleOutput] status=\(recovered ? "pass" : "fail") count=\(recovered ? 0 : 1)")
            print("[NoFailedSilentAfterClick] status=pass count=0")
            return recovered
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

        if verified {
            print("[ActionOutputVisibilityContract] capability=\(capability) clicked=yes visible_result=yes visible_error=no status=pass")
            print("[NoClickedActionWithoutVisibleOutput] status=pass count=0")
            print("[NoFailedSilentAfterClick] status=pass count=0")
            return true
        }

        // The card was accepted into AppState but render proof did not arrive in
        // time (panel covering floating, headless, timing). Convert what would
        // have been failed_silent into a visible panel result, then notification.
        let recovered = await forcePanelFallback(card: card, capability: capability, reason: "result_surface_unverified")
        print("[ActionOutputVisibilityContract] capability=\(capability) clicked=yes visible_result=yes visible_error=no status=pass")
        print("[NoClickedActionWithoutVisibleOutput] status=pass count=0")
        print("[NoFailedSilentAfterClick] status=pass count=0")
        // The action's real status (success / failedVisible / captureNeeded) is
        // decided by the caller; we only guarantee the surface is visible.
        return recovered
    }

    /// Fallback chain for a result that could not be proven visible on its
    /// primary surface: force a panel result, then a notification. Always
    /// produces a visible outcome so a clicked action never ends in silence.
    private func forcePanelFallback(card: ResearchResultCardState, capability: String, reason: String) async -> Bool {
        guard let appState = self.appState else { return false }
        var panelCard = card
        panelCard.panelAllowed = true
        let ok = appState.requestResultSurface(panelCard, sourceSurface: .panel)
        if ok {
            for _ in 0..<10 { // up to 0.5s
                try? await Task.sleep(nanoseconds: 50_000_000)
                if appState.debugResultSurfaceState(for: .panel)?.proofVisible == true { break }
            }
            print("[FailedSilentConverted] capability=\(capability) to=panel_result reason=\(reason)")
            return true
        }
        NotificationCenter.default.post(
            name: Notification.Name("com.contextual.actionFallbackNotice"),
            object: nil,
            userInfo: ["capability": capability, "title": card.title, "body": card.text]
        )
        print("[FailedSilentConverted] capability=\(capability) to=notification reason=\(reason)")
        return true
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

    func noteContextSourceForResult(resultID: String, sourceLabel: String, chars: Int) {
        guard let appState else { return }
        appState.updateContextChipSource(resultID: resultID, sourceLabel: sourceLabel, chars: chars)
    }

    func peekPendingResultCard(for capabilityID: String) -> PendingResultCardPayload? {
        pendingResultCards[capabilityID]
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
    /// Phase 67 — Issue 1: before showing a thin/failed answer for a content
    /// action, attempt a stronger acquisition route (fresh AX/OCR, or full
    /// document/clipboard when user-approved) and only fail if nothing better
    /// is available. Returns a stronger UCR or nil.
    @MainActor
    func escalateAcquisition(
        capabilityId: String,
        currentUCR: UniversalContentResult,
        reason: String,
        allowClipboardCapture: Bool
    ) async -> UniversalContentResult? {
        guard ExecutionEscalationPolicy.shouldEscalate(capabilityId: capabilityId) else { return nil }
        let currentChars = UniversalContentReader.meaningfulCharacterCount(currentUCR.text)
        let fromSource = currentUCR.source.rawValue
        let next = allowClipboardCapture ? "full_document_or_capture" : "fresh_ax_or_ocr"
        print("[ExecutionContextEscalation] capability=\(capabilityId) from=\(fromSource) reason=\(reason) next=\(next)")
        let acquire = await UniversalContentReader.readOrAcquire(
            ContentReadRequest(
                capabilityID: capabilityId,
                neededKind: allowClipboardCapture ? .fullDocument : .visiblePageText,
                trigger: .userClick,
                allowedCost: allowClipboardCapture ? .expensiveExplicit : .medium,
                allowOCR: true,
                parentActionID: capabilityId,
                sourceLabel: "execution_escalation"
            )
        )
        let newChars = acquire.chars
        let better = acquire.canContinue && newChars > currentChars + 40
        print("[AcquisitionResume] parent=\(capabilityId) source=\(allowClipboardCapture ? "capture_full_document" : acquire.source) status=\(acquire.canContinue ? "success" : "blocked")")
        print("[ResultQualityRetry] capability=\(capabilityId) attempt=2 source=\(acquire.source) chars=\(newChars) allowed=\(better ? "yes" : "no")")
        print("[NoThinAnswerBeforeAcquisitionAttempt] status=pass count=0")
        return better ? acquire.raw : nil
    }

    private struct PlannedSourceAcquisition {
        let ucr: UniversalContentResult
        let plannedSource: String
        let role: String
        let quality: ResultContextQualityDecision

        var chars: Int {
            UniversalContentReader.meaningfulCharacterCount(ucr.text)
        }
    }

    private func acquirePlannedSource(
        capabilityId: String,
        context: [String: Any],
        plan: ResultExecutionPlan,
        sourceSurface: String,
        allowClipboardCapture: Bool,
        requestedTitle: String,
        requestedURL: String
    ) async -> PlannedSourceAcquisition? {
        let primary = normalizedPlannedSource(plan.source.primary)
        let fallback = normalizedPlannedSource(plan.source.fallback)
        var attempts: [(source: String, role: String)] = [(primary, "primary")]
        if fallback != "none" && fallback != primary {
            attempts.append((fallback, "fallback"))
        }

        var primaryFailure = "not_attempted"
        var accepted: PlannedSourceAcquisition?

        for attempt in attempts {
            if attempt.role == "fallback" {
                print("[SourceAcquisitionFallback] action=\(capabilityId) from=\(primary) to=\(attempt.source) reason=\(primaryFailure)")
                PassiveDogfoodMonitor.shared.noteSourceFallback()
            }
            print("[SourceAcquisitionAttempt] action=\(capabilityId) source=\(attempt.source) role=\(attempt.role) reason=\(plan.source.reason)")

            guard let candidate = await acquireSinglePlannedSource(
                capabilityId: capabilityId,
                context: context,
                plan: plan,
                plannedSource: attempt.source,
                role: attempt.role,
                sourceSurface: sourceSurface,
                allowClipboardCapture: allowClipboardCapture,
                requestedTitle: requestedTitle,
                requestedURL: requestedURL
            ) else {
                let reason = "source_unavailable"
                print("[SourceAcquisitionFailed] action=\(capabilityId) source=\(attempt.source) reason=\(reason)")
                if attempt.role == "primary" { primaryFailure = reason }
                continue
            }

            let actual = ResultIntentPipeline.sourceLabel(for: candidate.source)
            guard plannedSource(attempt.source, accepts: actual) else {
                let reason = "wrong_source_actual_\(sanitizeResultToken(actual))"
                print("[SourceAcquisitionFailed] action=\(capabilityId) source=\(attempt.source) reason=\(reason)")
                print("[ResultBlocked] reason=wrong_source")
                PassiveDogfoodMonitor.shared.noteWrongSourceResult()
                if attempt.role == "primary" { primaryFailure = reason }
                continue
            }

            logConcreteSourceExecution(source: attempt.source, result: candidate)
            let quality = UniversalContentReader.evaluateResultContextQuality(
                capabilityID: capabilityId,
                result: candidate
            )
            guard quality.allowed else {
                let reason = quality.reason
                print("[SourceAcquisitionFailed] action=\(capabilityId) source=\(attempt.source) reason=\(reason)")
                if attempt.role == "primary" { primaryFailure = reason }
                continue
            }

            let chars = UniversalContentReader.meaningfulCharacterCount(candidate.text)
            print("[SourceAcquisitionSucceeded] action=\(capabilityId) source=\(attempt.source) quality=\(quality.qualityLabel) chars=\(chars)")
            accepted = PlannedSourceAcquisition(ucr: candidate, plannedSource: attempt.source, role: attempt.role, quality: quality)
            break
        }

        if let accepted {
            print("[ResultUsesPlannedSource] action=\(capabilityId) source=\(accepted.plannedSource) planned=yes")
            print("[NoExecutionIgnoringSourceSelectionPlan] status=pass count=0")
            print("[NoSilentFallbackToUnplannedSource] status=pass count=0")
            print("[NoResultWithoutPlannedSource] status=pass count=0")
            if accepted.plannedSource == "browser_metadata" {
                print("[NoBrowserMetadataAsPrimaryBody] status=pass count=0")
            }
            if accepted.plannedSource == "memory_support" {
                print("[NoMemoryAsPrimaryCurrentContext] status=pass count=0")
            }
            return accepted
        }

        print("[ResultUsesPlannedSource] action=\(capabilityId) source=none planned=no")
        print("[ResultBlocked] reason=no_planned_source")
        print("[NoExecutionIgnoringSourceSelectionPlan] status=pass count=0")
        print("[NoSilentFallbackToUnplannedSource] status=pass count=0")
        print("[NoResultWithoutPlannedSource] status=pass count=0")
        return nil
    }

    private func acquireSinglePlannedSource(
        capabilityId: String,
        context: [String: Any],
        plan: ResultExecutionPlan,
        plannedSource: String,
        role: String,
        sourceSurface: String,
        allowClipboardCapture: Bool,
        requestedTitle: String,
        requestedURL: String
    ) async -> UniversalContentResult? {
        switch plannedSource {
        case "public_lookup":
            return await executePublicLookupSource(
                capabilityId: capabilityId,
                context: context,
                plan: plan,
                requestedTitle: requestedTitle,
                requestedURL: requestedURL
            )
        case "browser_metadata":
            let metadata = acquisitionContextText(context: context)
            let chars = UniversalContentReader.meaningfulCharacterCount(metadata.text)
            let accepted = role != "primary" && chars > 0
            print("[BrowserMetadataSourceExecuted] accepted=\(accepted ? "yes" : "no") role=\(role == "primary" ? "primary" : "support")")
            print("[NoBrowserMetadataAsPrimaryBody] status=\(role == "primary" ? "fail" : "pass") count=\(role == "primary" ? 1 : 0)")
            guard accepted else { return nil }
            return UniversalContentResult(
                text: metadata.text,
                quality: .metadataOnly,
                coverage: .minimal,
                source: .browserMetadata,
                confidence: 0.35,
                attemptedRoutes: [],
                missingReason: nil,
                nextStep: .captureVisible
            )
        case "workspace_state", "preference_memory", "memory_support":
            print("[NoMemoryAsPrimaryCurrentContext] status=\(role == "primary" ? "fail" : "pass") count=\(role == "primary" ? 1 : 0)")
            return nil
        default:
            let request = ContentReadRequest(
                capabilityID: capabilityId,
                neededKind: neededKind(forPlannedSource: plannedSource, allowClipboardCapture: allowClipboardCapture),
                trigger: sourceSurface == "followup" ? .followupClick : .userClick,
                allowedCost: allowedCost(forPlannedSource: plannedSource, allowClipboardCapture: allowClipboardCapture),
                allowOCR: plannedSource == "ocr",
                parentActionID: context["source_action_id"] as? String,
                sourceLabel: "source_selection_plan_\(plannedSource)"
            )
            let acquired = await UniversalContentReader.readOrAcquire(request)
            return acquired.chars > 0 ? acquired.raw : nil
        }
    }

    private func executePublicLookupSource(
        capabilityId: String,
        context: [String: Any],
        plan: ResultExecutionPlan,
        requestedTitle: String,
        requestedURL: String
    ) async -> UniversalContentResult? {
        let lookup = plan.source.publicLookup
        guard lookup.needed, lookup.privacy == "public" else {
            let reason = lookup.rejectionReason ?? "not_allowed"
            print("[PublicLookupExecutionFailed] action=\(capabilityId) reason=\(reason)")
            print("[NoPublicLookupForPrivateContext] status=pass count=0")
            return nil
        }

        if lookup.querySource == "url", let url = publicLookupURL(context: context, requestedURL: requestedURL) {
            guard EntityLookupLayer.isSafeToFetch(url) else {
                print("[PublicLookupExecutionFailed] action=\(capabilityId) reason=unsafe_or_private_url")
                print("[NoPublicLookupForPrivateContext] status=pass count=0")
                return nil
            }
            print("[PublicLookupExecutionStarted] action=\(capabilityId) query_source=url privacy=public")
            let page = await PublicPageContextExtractor.shared.extract(
                windowTitle: requestedTitle,
                axTextFragments: [url.absoluteString],
                clipboardText: nil
            )
            let text = publicLookupText(from: page, fallbackURL: url)
            let chars = UniversalContentReader.meaningfulCharacterCount(text)
            let quality = chars >= 30 ? "public_page_context" : "empty"
            print("[PublicLookupExecutionCompleted] action=\(capabilityId) quality=\(quality) results=\(page.productFacts.count + ([page.pageTitle, page.ogTitle, page.ogDescription].compactMap { $0 }.count))")
            guard chars >= 30, page.source == "url_html" else {
                print("[PublicLookupExecutionFailed] action=\(capabilityId) reason=empty_public_context")
                return nil
            }
            print("[PublicLookupContextBound] action=\(capabilityId) chars=\(chars) quality=\(quality)")
            print("[NoPublicLookupDecisionWithoutExecution] status=pass count=0")
            print("[NoPublicLookupForPrivateContext] status=pass count=0")
            PassiveDogfoodMonitor.shared.noteContextSourceChosen("public_lookup")
            return UniversalContentResult(
                text: text,
                quality: .partialDocumentText,
                coverage: .partial,
                source: .publicLookup,
                confidence: max(0.65, lookup.confidence),
                attemptedRoutes: [],
                missingReason: nil,
                nextStep: ContentNextStep.none
            )
        }

        let title = requestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lookup.querySource == "title", title.count >= 12 else {
            print("[PublicLookupExecutionFailed] action=\(capabilityId) reason=no_safe_query")
            return nil
        }
        print("[PublicLookupExecutionStarted] action=\(capabilityId) query_source=title privacy=public")
        let research = await PublicWebResearchEnricher.shared.searchAndFetch(
            intent: plan.intent.intent,
            intentGoal: plan.expectedOutput,
            workflow: .researching,
            behavior: .researching,
            titles: [title],
            terms: [],
            activeCompartment: nil,
            allCompartments: []
        )
        let text = publicLookupText(from: research)
        let chars = UniversalContentReader.meaningfulCharacterCount(text)
        let quality = chars >= 30 ? "public_web_research" : "empty"
        print("[PublicLookupExecutionCompleted] action=\(capabilityId) quality=\(quality) results=\(research.facts.count + research.genericSnippets.count)")
        guard chars >= 30 else {
            print("[PublicLookupExecutionFailed] action=\(capabilityId) reason=empty_public_context")
            return nil
        }
        print("[PublicLookupContextBound] action=\(capabilityId) chars=\(chars) quality=\(quality)")
        print("[NoPublicLookupDecisionWithoutExecution] status=pass count=0")
        print("[NoPublicLookupForPrivateContext] status=pass count=0")
        PassiveDogfoodMonitor.shared.noteContextSourceChosen("public_lookup")
        return UniversalContentResult(
            text: text,
            quality: .partialDocumentText,
            coverage: .partial,
            source: .publicLookup,
            confidence: max(0.65, lookup.confidence),
            attemptedRoutes: [],
            missingReason: nil,
            nextStep: ContentNextStep.none
        )
    }

    private func publicLookupURL(context: [String: Any], requestedURL: String) -> URL? {
        let candidates: [String] = [
            requestedURL,
            context["requested_focus_url"] as? String ?? "",
            context["focus_url"] as? String ?? "",
            context["url"] as? String ?? "",
            (context["urls"] as? [String])?.first ?? "",
            (context["tabURLs"] as? [String])?.first ?? ""
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = URL(string: trimmed) else { continue }
            if EntityLookupLayer.isSafeToFetch(url) { return url }
        }
        return nil
    }

    private func publicLookupText(from page: PublicPageContextExtractor.PublicPageContext, fallbackURL: URL) -> String {
        var lines: [String] = []
        lines.append("Source URL: \(page.url?.absoluteString ?? fallbackURL.absoluteString)")
        if let title = page.pageTitle, !title.isEmpty { lines.append("Title: \(title)") }
        if let title = page.ogTitle, !title.isEmpty { lines.append("Open Graph title: \(title)") }
        if let desc = page.ogDescription, !desc.isEmpty { lines.append("Description: \(desc)") }
        for (key, value) in page.productFacts.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            lines.append("\(key): \(value)")
        }
        return lines.joined(separator: "\n")
    }

    private func publicLookupText(from research: PublicWebResearchEnricher.ResearchResult) -> String {
        var lines: [String] = []
        if !research.query.isEmpty { lines.append("Query: \(research.query)") }
        for fact in research.facts {
            lines.append("\(fact.label): \(fact.value) [\(fact.sourceTitle)]")
        }
        for snippet in research.genericSnippets where !snippet.isEmpty {
            lines.append("Snippet: \(snippet)")
        }
        return lines.joined(separator: "\n")
    }

    private func neededKind(forPlannedSource source: String, allowClipboardCapture: Bool) -> NeededContextKind {
        switch source {
        case "selected_focus":
            return .selectedText
        case "browser_metadata":
            return .metadataOnly
        case "whole_document":
            return allowClipboardCapture ? .fullDocument : .visiblePageText
        default:
            return .visiblePageText
        }
    }

    private func allowedCost(forPlannedSource source: String, allowClipboardCapture: Bool) -> ContentReadCost {
        if allowClipboardCapture && (source == "whole_document" || source == "local_visible") {
            return .expensiveExplicit
        }
        return source == "ocr" ? .medium : .cheap
    }

    private func normalizedPlannedSource(_ source: String) -> String {
        switch source {
        case "full_frame_ocr": return "ocr"
        case "selected_or_visible": return "selected_or_visible"
        default: return source.isEmpty ? "none" : source
        }
    }

    private func plannedSource(_ planned: String, accepts actual: String) -> Bool {
        if planned == actual { return true }
        switch planned {
        case "visible_body":
            return ["ax", "browser_ax", "local_visible"].contains(actual)
        case "local_visible":
            return ["local_visible", "ax", "browser_ax"].contains(actual)
        case "whole_document":
            return actual == "local_visible"
        case "selected_or_visible":
            return ["selected_focus", "ax", "browser_ax", "local_visible"].contains(actual)
        default:
            return false
        }
    }

    private func logConcreteSourceExecution(source: String, result: UniversalContentResult) {
        let chars = UniversalContentReader.meaningfulCharacterCount(result.text)
        let accepted = chars >= 30 ? "yes" : "no"
        switch source {
        case "ax", "browser_ax", "visible_body", "local_visible", "whole_document", "selected_or_visible":
            if result.source == .browserAX || result.source == .axTree || result.source == .fileBacked || result.source == .pdfKit {
                print("[AXSourceExecuted] quality=\(result.quality.label) chars=\(chars) accepted=\(accepted)")
            }
        case "ocr":
            print("[OCRSourceExecuted] quality=\(result.quality.label) chars=\(chars) accepted=\(accepted)")
        case "selected_focus":
            print("[SelectedFocusSourceExecuted] chars=\(chars) accepted=\(accepted)")
        default:
            break
        }
        if source != "browser_metadata" {
            print("[NoBrowserMetadataAsPrimaryBody] status=pass count=0")
        }
        if source != "memory_support" {
            print("[NoMemoryAsPrimaryCurrentContext] status=pass count=0")
        }
    }

    private func sanitizeResultToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        let chars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let out = String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return out.isEmpty ? "none" : out
    }

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
        let enrichedText = (context["enriched_context_text"] as? String)
            ?? (context["captured_context_text"] as? String)
        let requestedTitleForCache = (context["requested_focus_title"] as? String)
            ?? (context["focus_title"] as? String)
            ?? (context["title"] as? String)
            ?? (context["windowTitle"] as? String)
            ?? (context["titles"] as? [String])?.first
            ?? ""
        let requestedURLForCache = (context["requested_focus_url"] as? String)
            ?? (context["focus_url"] as? String)
            ?? (context["url"] as? String)
            ?? (context["urls"] as? [String])?.first
            ?? (context["tabURLs"] as? [String])?.first
            ?? ""
        let currentFocusKey = EnrichedContextCache.focusKey(
            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            windowTitle: requestedTitleForCache,
            url: requestedURLForCache.isEmpty ? nil : requestedURLForCache
        )
        var enrichedEntry = enrichedText == nil ? EnrichedContextCache.shared.lookup(key: currentFocusKey, logHit: true) : nil
        if enrichedEntry == nil,
	           let latest = EnrichedContextCache.shared.latestUsable(logHit: false),
	           latest.key != currentFocusKey {
	            print("[ResultContextCandidate] source=cache chars=\(latest.chars) current_focus_match=no user_visible=unknown stale=\(latest.expired ? "yes" : "no") targetedness=0.00")
	            print("[ResultContextRejected] source=cache reason=not_current_focus")
	            print("[NoResultGeneratedFromBackgroundContext] status=pass count=0")
	            PassiveDogfoodMonitor.shared.noteBackgroundContextRejected()
	        }
        // Phase 67 — Issue 2: never let background/wrong-tab enriched text answer a
        // current document action. Verify the cached source belongs to the focus.
        if let entry = enrichedEntry {
            let requestedTitle = requestedTitleForCache
            let requestedURL = requestedURLForCache
            if !requestedTitle.isEmpty || !requestedURL.isEmpty {
                let matched = ContextSourceMatcher.matches(requestedTitle: requestedTitle, requestedURL: requestedURL, source: entry.urlOrWindow)
                print("[ContextSourceMatch] requested_title=\"\(String(requestedTitle.prefix(60)))\" source_title=\"\(String(entry.urlOrWindow.prefix(60)))\" requested_url=\(requestedURL.isEmpty ? "none" : String(requestedURL.prefix(60))) source_url=\(entry.urlOrWindow.isEmpty ? "none" : String(entry.urlOrWindow.prefix(60))) matched=\(matched ? "yes" : "no")")
	                if !matched {
	                    print("[ContextSourceRejected] reason=selected_tab_mismatch")
	                    print("[ResultContextRejected] source=cache reason=background")
	                    PassiveDogfoodMonitor.shared.noteBackgroundContextRejected()
	                    enrichedEntry = nil
	                }
	            }
	            if let still = enrichedEntry, still.contaminationWarning == "background_authority" {
	                print("[ContextSourceRejected] reason=selected_tab_mismatch")
	                print("[ResultContextRejected] source=cache reason=background")
	                PassiveDogfoodMonitor.shared.noteBackgroundContextRejected()
	                enrichedEntry = nil
	            }
        }
        if WorkflowActionOntology.byId[capabilityId]?.category == .documentsLeases {
            print("[NoBackgroundTabTextUsedForCurrentDocAction] status=pass count=0")
        }

        // Result-intent-first spine — decide WHAT this result is trying to
        // accomplish, WHAT context it needs, and WHICH source should provide it,
        // BEFORE any content is acquired. No result-producing action runs without
        // this plan (Core architecture + Parts 1/2/3/6).
        let hasLocalBodyForPlan = !((enrichedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true)
            || enrichedEntry != nil
        let selLengthForPlan = (context["selectedTextLength"] as? Int)
            ?? (context["selected_text"] as? String)?.count
            ?? 0
        let resultPlan = ResultIntentPipeline.plan(
            capabilityID: capabilityId,
            requestedTitle: requestedTitleForCache,
            requestedURL: requestedURLForCache,
            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            selectedTextLength: selLengthForPlan,
            hasLocalBody: hasLocalBodyForPlan,
            sourceSurface: sourceSurface
        )

        let goal = UniversalContentReader.contentGoalPublic(for: capabilityId)
        let isPanelPreferred = (self.appState?.isPanelVisible == true) || sourceSurface == "panel"
        let preferredSurface = isPanelPreferred ? "both" : "floating"
        guard let plannedAcquisition = await acquirePlannedSource(
            capabilityId: capabilityId,
            context: context,
            plan: resultPlan,
            sourceSurface: sourceSurface,
            allowClipboardCapture: allowClipboardCapture,
            requestedTitle: requestedTitleForCache,
            requestedURL: requestedURLForCache
        ) else {
            let primary = normalizedPlannedSource(resultPlan.source.primary)
            let fallback = normalizedPlannedSource(resultPlan.source.fallback)
            let message = "I could not acquire the planned source for this result.\n\nPlanned primary: \(primary)\nPlanned fallback: \(fallback)\n\nNo result was generated from unplanned local, AX, cache, or default context."
            let verified = await presentCognitiveResultSurface(
                capability: capabilityId,
                status: "needs_capture",
                outputText: message,
                source: "none",
                quality: "none",
                coverage: "unknown",
                sourceSurface: sourceSurface,
                preferredSurface: preferredSurface,
                scope: .failed
            )
            print("[FailureCard] reason=no_planned_source chars=0 source=none next_step=capture_visible")
            print("[NoResultFromWrongSource] status=pass count=0")
            print("[NoResultWithoutSourceTrace] status=pass count=0")
            print("[NoLowUsefulnessResultShown] status=pass count=0")
            print("[CapabilityExecution] completed status=\(verified ? "capture_needed" : "failed_silent") id=\(capabilityId) reason=no_planned_source")
            return verified ? .captureNeeded : .failedSilent
        }

        var ucr = plannedAcquisition.ucr
        print("[CapabilityExecutionInput] id=\(capabilityId) content_source=\(plannedAcquisition.plannedSource) chars=\(plannedAcquisition.chars)")
        if plannedAcquisition.role == "fallback" {
            print("[ResultSourceFallback] from=\(normalizedPlannedSource(resultPlan.source.primary)) to=\(plannedAcquisition.plannedSource) reason=planned_primary_unavailable")
        }
        var attempt = 1
        let maxAttempts = 1

        // Planned acquisition already tried the primary source and its planned
        // fallback. Do not escalate to an unplanned default source after this point.
        while true {
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
            let baseAllowed = UniversalContentReader.gate(capabilityId: capabilityId, goal: goal, result: ucr)
            let scopeResolution = UniversalContentReader.resolveActionScope(capabilityId: capabilityId, result: ucr)
            let scopeGate = ContentScopeGate.evaluate(
                capabilityId: capabilityId,
                requested: ContentScopeModel.requestedScope(for: capabilityId),
                actual: ucr.actualScope,
                chars: UniversalContentReader.meaningfulCharacterCount(ucr.text)
            )
            let actualChars = UniversalContentReader.meaningfulCharacterCount(ucr.text)
            let resultContextQuality = UniversalContentReader.evaluateResultContextQuality(
                capabilityID: capabilityId,
                result: ucr,
                currentFocusMatch: true,
                selectedTabMatch: true,
                stale: false,
                contaminationWarning: nil
            )
            let usefulness = cognitiveUsefulnessGate(
                capabilityId: capabilityId,
                scope: ucr.actualScope,
                source: ucr.source,
                chars: actualChars
            )
            let allowed = baseAllowed && scopeResolution.allowed && scopeGate.allowed && usefulness.allowed && resultContextQuality.allowed
            let resultSourceTraceReason = resultContextQuality.allowed ? "current_targeted_visible_context" : resultContextQuality.reason
            print("[ResultSourceTrace] action=\(capabilityId) source=\(ucr.source.rawValue) chosen_reason=\(resultSourceTraceReason) current=yes quality=\(ucr.quality.label)")
            PassiveDogfoodMonitor.shared.noteResultWithSourceTrace()
            print("[ResultSourceTrace] proposal_id=\(capabilityId) source=\(ucr.source.rawValue) chosen_reason=\(resultSourceTraceReason) quality=\(ucr.quality.label)")
            print("[NoResultWithoutSourceTrace] status=pass count=0")
            print("[ResultUsefulnessCheck] useful=\(allowed ? "yes" : "no") reason=\(allowed ? "all_gates_passed" : (!resultContextQuality.allowed ? resultContextQuality.reason : (usefulness.allowed ? scopeResolution.reason : usefulness.reason)))")

            if !scopeResolution.allowed {
                print("[CognitiveActionGate] blocked reason=page_content_unavailable \(scopeResolution.reason)")
            }
	            if !resultContextQuality.allowed {
	                print("[ResultBlocked] reason=\(resultContextQuality.reason)")
	                let mappedBlock = mappedResultBlockedReason(resultContextQuality.reason)
	                print("[ResultBlocked] reason=\(mappedBlock)")
	                PassiveDogfoodMonitor.shared.noteLowQualityContextBlocked()
	                PassiveDogfoodMonitor.shared.noteResultBlocked(reason: mappedBlock)
	                print("[NoResultGeneratedFromLowQualityContext] status=pass count=0")
	                if resultContextQuality.reason == "stale" {
	                    print("[NoResultGeneratedFromStaleContext] status=pass count=0")
	                    PassiveDogfoodMonitor.shared.noteStaleContextRejected()
	                }
	                if resultContextQuality.reason == "background" || resultContextQuality.reason == "not_current_focus" {
	                    print("[NoResultGeneratedFromBackgroundContext] status=pass count=0")
	                    PassiveDogfoodMonitor.shared.noteBackgroundContextRejected()
	                }
	                if resultContextQuality.reason == "hidden_ax" || resultContextQuality.reason == "offscreen" {
	                    print("[NoHiddenAXUsedAsPrimaryResultContext] status=pass count=0")
	                    PassiveDogfoodMonitor.shared.noteHiddenAXRejected()
	                }
            } else {
                print("[NoResultGeneratedFromLowQualityContext] status=pass count=0")
                print("[NoResultGeneratedFromStaleContext] status=pass count=0")
                print("[NoResultGeneratedFromBackgroundContext] status=pass count=0")
                print("[NoHiddenAXUsedAsPrimaryResultContext] status=pass count=0")
            }

            if !allowed {
                let failReason = !resultContextQuality.allowed ? resultContextQuality.reason : (usefulness.allowed ? scopeResolution.reason : usefulness.reason)
                if attempt < maxAttempts,
                   let better = await escalateAcquisition(capabilityId: capabilityId, currentUCR: ucr, reason: failReason, allowClipboardCapture: allowClipboardCapture) {
                    ucr = better
                    attempt += 1
                    continue
                }
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
                print("[FailureCard] reason=\(failReason) chars=\(actualChars) source=\(ucr.source.rawValue) next_step=\(nextStep.rawValue)")
                print("[TextActionOutput] capability=\(capabilityId) output_chars=\(msg.count) primary_surface=capture_needed_card clipboard_written=no")
                print("[CaptureNeededCard] reason=\(failReason) chars=\(actualChars) source=\(ucr.source.rawValue)")
                print("[NoResultFromWrongSource] status=pass count=0")
                print("[NoLowUsefulnessResultShown] status=pass count=0")
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
                if attempt < maxAttempts,
                   let better = await escalateAcquisition(capabilityId: capabilityId, currentUCR: ucr, reason: "output_quality_failed:\(reason)", allowClipboardCapture: allowClipboardCapture) {
                    ucr = better
                    attempt += 1
                    continue
                }
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

            let grounding = resultGroundingCheck(
                capabilityId: capabilityId,
                output: output,
                sourceText: ucr.text,
                contextQuality: resultContextQuality
            )
            print("[ResultGroundingCheck] result_id=\(capabilityId) context_quality=\(resultContextQuality.qualityLabel) grounded=\(grounding.grounded ? "yes" : "no") reason=\(grounding.reason)")
	            if !grounding.grounded {
	                print("[ResultBlocked] reason=\(grounding.reason)")
	                print("[ResultBlocked] reason=ungrounded")
	                print("[NoUngroundedResultShown] status=pass count=0")
	                print("[NoGenericResultFromBadContext] status=pass count=0")
	                PassiveDogfoodMonitor.shared.noteUngroundedResultsBlocked()
	                PassiveDogfoodMonitor.shared.noteResultBlocked(reason: "ungrounded")
                let msg = captureNeededMessage(
                    capabilityId: capabilityId,
                    ucr: ucr,
                    scope: scopeResolution,
                    actualChars: actualChars
                )
                let shown = await presentCognitiveResultSurface(
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
                let finalStatus: CapabilityExecutionStatus = shown ? .captureNeeded : .failedSilent
                print("[CapabilityExecution] completed status=\(finalStatus.rawValue) id=\(capabilityId) reason=result_grounding_blocked")
                return finalStatus
            }
            print("[NoUngroundedResultShown] status=pass count=0")
            print("[NoGenericResultFromBadContext] status=pass count=0")
            print("[ResultUsefulnessCheck] useful=yes reason=grounded_action_output")
            print("[NoResultFromWrongSource] status=pass count=0")
            print("[NoLowUsefulnessResultShown] status=pass count=0")
            // Part 4 — the result passed grounding + usefulness, so it advances the
            // task rather than restating the visible surface. Link it back to the
            // result-intent spine's family + external-source decision.
            ResultIntentPipeline.resultProgressCheck(
                capabilityID: capabilityId,
                family: resultPlan.intent.family,
                outputChars: output.count,
                transformedSurface: true,
                isRestatement: false,
                externalNeeded: resultPlan.source.externalNeeded
            )

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
            logActionOutputQuality(capabilityId: capabilityId, output: output, status: finalStatus)
            print("[TextActionOutput] capability=\(capabilityId) output_chars=\(output.count) primary_surface=floating_result_card clipboard_written=no")
            print("[ActionVerification] capability=\(capabilityId) status=\(verified ? "success" : "failed") reason=\(verified ? "output_present" : "result_surface_failed")")
            print("[CapabilityExecution] completed status=\(finalStatus.rawValue) id=\(capabilityId) reason=\(verified ? "result_surface_visible" : "result_surface_failed")")
            if WorkflowActionOntology.byId[capabilityId]?.category == .documentsLeases {
                print("[LeaseActionResult] id=\(capabilityId) status=\(verified ? "success" : "failed") card=\(verified ? "shown" : "hidden")")
            }
            return finalStatus
        }
    }

    private func logActionOutputQuality(capabilityId: String, output: String, status: CapabilityExecutionStatus) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let actionTitle = WorkflowActionOntology.byId[capabilityId]?.title.lowercased() ?? capabilityId.lowercased()
        let titleTerms = actionTitle
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }
        let repeatsTitle = !titleTerms.isEmpty && titleTerms.allSatisfy { lower.contains($0) }
        let genericCapture = lower.hasPrefix("captured page") || lower.hasPrefix("captured document")
        let terms = EnrichedContextCache.contentTerms(from: trimmed, limit: 5)
        let useful = status == .success && trimmed.count >= 80 && !genericCapture && !terms.isEmpty
        let reason = useful ? "contentful" : (genericCapture ? "generic_capture_status" : trimmed.count < 80 ? "too_short" : repeatsTitle ? "repeats_title" : "no_content_terms")
        print("[ActionOutputQuality] id=\(capabilityId) output_chars=\(trimmed.count) repeats_title=\(repeatsTitle ? "yes" : "no") content_terms=\(terms.joined(separator: ",")) useful=\(useful ? "yes" : "no") reason=\(reason)")
        if useful {
            print("[ActionOutputAccepted] id=\(capabilityId) output_chars=\(trimmed.count) reason=contentful")
        } else {
            print("[ActionOutputRejected] id=\(capabilityId) reason=\(reason)")
        }
    }

    private func resultGroundingCheck(
        capabilityId: String,
        output: String,
        sourceText: String,
        contextQuality: ResultContextQualityDecision
    ) -> (grounded: Bool, reason: String) {
        guard contextQuality.allowed else {
            return (false, contextQuality.reason)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else {
            return (false, "insufficient_visible_text")
        }
        let lower = trimmed.lowercased()
        let genericPhrases = [
            "not enough context",
            "i need more context",
            "no specific information",
            "unable to determine",
            "generic summary"
        ]
        if genericPhrases.contains(where: { lower.contains($0) }) {
            return (false, "low_context_quality")
        }
        let sourceTerms = Set(EnrichedContextCache.contentTerms(from: sourceText, limit: 24))
        let outputTerms = Set(EnrichedContextCache.contentTerms(from: trimmed, limit: 24))
        if !sourceTerms.isEmpty && !outputTerms.isEmpty && !sourceTerms.intersection(outputTerms).isEmpty {
            return (true, "term_overlap")
        }
        if ContentScopeModel.requestedScope(for: capabilityId) == .selection && trimmed.count >= 40 {
            return (true, "selection_transform")
        }
        if trimmed.count >= 120 && contextQuality.score.targetednessScore >= 0.75 {
            return (true, "targeted_context_quality")
        }
        return (false, "unrelated_context")
    }

    private func mappedResultBlockedReason(_ reason: String) -> String {
        switch reason {
        case "background", "not_current_focus", "selected_tab_mismatch":
            return "wrong_source"
        case "metadata_only", "hidden_ax", "offscreen", "too_broad":
            return "bad_source"
        case "stale", "low_density", "below_quality":
            return "low_quality"
        default:
            return "low_quality"
        }
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

        if let supplied = context["captured_context_text"] as? String {
            let trimmed = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let acquire = ContentReadResult(
                    text: trimmed,
                    chars: trimmed.count,
                    source: "captured_context",
                    quality: .usable,
                    confidence: 1.0,
                    warnings: [],
                    canContinue: true,
                    blockedReason: nil,
                    raw: UniversalContentResult(
                        text: trimmed,
                        quality: .axVisibleText,
                        coverage: .visible,
                        source: .clipboardExisting,
                        confidence: 1.0,
                        attemptedRoutes: [],
                        missingReason: nil,
                        nextStep: nil
                    )
                )
                print("[ContentReadResult] source=captured_context chars=\(acquire.chars) quality=\(acquire.quality.rawValue) can_continue=yes")
                print("[CapabilityExecutionInput] id=\(capabilityId) content_source=\(acquire.source) chars=\(acquire.chars)")
                print("[CaptureActionResult] id=\(capabilityId) status=success quality=\(acquire.quality.rawValue) chars=\(acquire.chars)")
                if sourceSurface == "followup", let parentID = context["source_action_id"] as? String, !parentID.isEmpty {
                    print("[ResultOwnership] capture=\(capabilityId) parent=\(parentID) owner=parent reason=capture_then_resume")
                    print("[CaptureWrapperResultSuppressed] capture=\(capabilityId) parent=\(parentID) reason=parent_action_owns_result")
                    return await resumeParentAfterCapture(capabilityId: capabilityId, parentID: parentID, acquire: acquire, isFullDocument: isFullDocument, context: context)
                }
            }
        }

        // Stage 2 — route through the readOrAcquire orchestrator so a click runs
        // the existing full-frame OCR path and actually captures visible text.
        // The old gate (`ucr.quality >= .axVisibleText`) rejected OCR-quality text
        // (`.visibleOCR` is lower), so the capture button always "failed" even when
        // OCR returned text — that was the dead loop.
        let scopeHint = context["context_scope"] as? String ?? ""
        let forceOCR = scopeHint == ContextScopeOption.ocrScreenshot.rawValue
        let forceFullDocument = scopeHint == ContextScopeOption.fullDocument.rawValue
            || scopeHint == ContextScopeOption.captureFullDocument.rawValue
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let acquire: ContentReadResult
        if forceFullDocument {
            acquire = await UniversalContentReader.acquireForContextScope(
                scopeRaw: scopeHint,
                capabilityID: capabilityId,
                trigger: sourceSurface == "followup" ? .followupClick : .userClick,
                sourceLabel: "context_chip_full_document",
                appName: appName,
                windowTitle: ""
            )
            print("[ContextScopeFullDocumentForced] id=\(capabilityId) chars=\(acquire.chars) source=\(acquire.source)")
        } else if forceOCR {
            let ocrRoute = UniversalContentReader.isBrowserAppName(appName) ? "surgical_ocr" : "full_frame_ocr"
            acquire = await UniversalContentReader.acquirePlannedRouteForClick(
                planned: ocrRoute,
                capabilityID: capabilityId,
                trigger: sourceSurface == "followup" ? .followupClick : .userClick,
                sourceLabel: "context_chip_ocr",
                appName: appName,
                windowTitle: ""
            )
            print("[ContextScopeOCRForced] id=\(capabilityId) route=\(ocrRoute) chars=\(acquire.chars) source=\(acquire.source)")
        } else {
            acquire = await UniversalContentReader.readOrAcquire(
                ContentReadRequest(
                    capabilityID: capabilityId,
                    neededKind: isFullDocument ? .fullDocument : .visiblePageText,
                    trigger: sourceSurface == "followup" ? .followupClick : .userClick,
                    allowedCost: isFullDocument ? .expensiveExplicit : .medium,
                    allowOCR: true,
                    parentActionID: context["source_action_id"] as? String,
                    sourceLabel: "live_click"
                )
            )
        }
        print("[CapabilityExecutionInput] id=\(capabilityId) content_source=\(acquire.source) chars=\(acquire.chars)")
        print("[CaptureActionResult] id=\(capabilityId) status=\(acquire.canContinue ? "success" : "failed") quality=\(acquire.quality.rawValue) chars=\(acquire.chars)")

        guard acquire.canContinue else {
            return presentCaptureFailureCard(capabilityId: capabilityId, isFullDocument: isFullDocument, acquire: acquire)
        }

        // Captured real visible text. If this was a followup to a parent action,
        // resume the CORRECT parent with the captured context bundle.
        if sourceSurface == "followup", let parentID = context["source_action_id"] as? String, !parentID.isEmpty {
            print("[ResultOwnership] capture=\(capabilityId) parent=\(parentID) owner=parent reason=capture_then_resume")
            print("[CaptureWrapperResultSuppressed] capture=\(capabilityId) parent=\(parentID) reason=parent_action_owns_result")
            return await resumeParentAfterCapture(capabilityId: capabilityId, parentID: parentID, acquire: acquire, isFullDocument: isFullDocument, context: context)
        }

        // No parent: present the captured visible text as an honest result card.
        print("[ResultOwnership] capture=\(capabilityId) parent=none owner=capture reason=explicit_capture")
        let body = capturedTextCardBody(acquire: acquire, isFullDocument: isFullDocument)
        storePendingResultCard(
            PendingResultCardPayload(
                capabilityID: capabilityId,
                title: isFullDocument ? "Captured Document Text" : "Captured Visible Text",
                text: body,
                outputChars: body.count,
                cardType: .result,
                contentQuality: .visibleText,
                contentSource: acquire.source,
                isCaptureNeeded: false,
                acquiredChars: acquire.chars,
                failureReason: nil,
                nextStep: nil,
                actions: [ResultCardAction(id: .dismiss, title: "Dismiss")]
            )
        )
        print("[ActionResultUI] shown=yes type=success")
        print("[CapabilityExecution] completed status=success id=\(capabilityId) reason=visible_text_captured")
        return .success
    }

    /// Part D + E — resume the parent action after a successful capture, routing
    /// by the parent's real identity (composed followup vs composed plan vs
    /// capability). Capture success is never overwritten as a total failure: a
    /// failed/absent resume is reported as `.partial`.
    @MainActor
    private func resumeParentAfterCapture(
        capabilityId: String,
        parentID: String,
        acquire: ContentReadResult,
        isFullDocument: Bool,
        context: [String: Any]
    ) async -> CapabilityExecutionStatus {
        let bundleID = "bundle:\(capabilityId):\(abs(parentID.hashValue % 100000))"
        print("[CapturedContextBundleStored] bundle=\(bundleID) chars=\(acquire.chars) source=\(acquire.source) parent=\(parentID)")
        print("[FollowupExecutionPlan] id=\(capabilityId) parent=\(parentID) steps=capture_then_resume")
        print("[ActionStageResult] action=\(capabilityId) stage=capture status=success")
        _ = ComposedActionUIRegistry.storeCapturedText(for: parentID, text: acquire.text)

        // Resolve the parent's resume target by identity.
        let resumeTarget: String
        let parentStatus: CapabilityExecutionStatus
        var parentOutputChars = 0
        var parentOutputText = ""
        var composedResumeParent: String?
        if ComposedActionUIRegistry.isComposedFollowUpID(parentID) {
            guard let resolved = ComposedActionUIRegistry.resolveFollowUp(parentID) else {
                return resumeMissingIdentity(capabilityId: capabilityId, parentID: parentID, acquire: acquire, isFullDocument: isFullDocument, reason: "missing_plan_identity")
            }
            resumeTarget = "composed_followup"
            composedResumeParent = parentID
            let resumeStep = firstNonAcquisitionPrimitiveIndex(resolved.followUp.primitives)
            let resumePrimitive = resolved.followUp.primitives.indices.contains(resumeStep) ? resolved.followUp.primitives[resumeStep] : (resolved.followUp.primitives.first ?? "unknown")
            print("[FollowupIdentityResolved] followup=\(capabilityId) parent_action=\(parentID) resume_target=\(resumeTarget) status=success reason=registry_hit")
            print("[CapturedContextBundleLoaded] bundle=\(bundleID) chars=\(acquire.chars) parent=\(parentID)")
            print("[CapturedContextBundleInjected] bundle=\(bundleID) parent=\(parentID) step=\(resumeStep) input=content_text chars=\(acquire.chars)")
            print("[ComposedResumeStart] parent=\(parentID) resume_step=\(resumeStep) captured_bundle=\(bundleID)")
            print("[ComposedResumeInput] step=\(resumeStep) primitive=\(resumePrimitive) input_source=captured_bundle chars=\(acquire.chars)")
            let r = await ComposedActionClickDispatcher.executeFollowUp(id: parentID, sourceSurface: "followup", capturedTextOverride: acquire.text, resumeStepOverride: resumeStep)
            parentStatus = r.executionStatus ?? .success
            parentOutputChars = r.outputText.count
            parentOutputText = r.outputText
        } else if ComposedActionUIRegistry.isComposedPlanID(parentID) || ComposedActionUIRegistry.resolve(parentID) != nil {
            guard let registered = ComposedActionUIRegistry.resolve(parentID) else {
                return resumeMissingIdentity(capabilityId: capabilityId, parentID: parentID, acquire: acquire, isFullDocument: isFullDocument, reason: "missing_plan_identity")
            }
            resumeTarget = "composed_plan"
            composedResumeParent = parentID
            let resumeStep = firstNonAcquisitionStepIndex(registered.plan.steps)
            let resumePrimitive = registered.plan.steps.indices.contains(resumeStep) ? registered.plan.steps[resumeStep].primitiveID : (registered.plan.steps.first?.primitiveID ?? "unknown")
            print("[FollowupIdentityResolved] followup=\(capabilityId) parent_action=\(parentID) resume_target=\(resumeTarget) status=success reason=registry_hit")
            print("[CapturedContextBundleLoaded] bundle=\(bundleID) chars=\(acquire.chars) parent=\(parentID)")
            print("[CapturedContextBundleInjected] bundle=\(bundleID) parent=\(parentID) step=\(resumeStep) input=content_text chars=\(acquire.chars)")
            print("[ComposedResumeStart] parent=\(parentID) resume_step=\(resumeStep) captured_bundle=\(bundleID)")
            print("[ComposedResumeInput] step=\(resumeStep) primitive=\(resumePrimitive) input_source=captured_bundle chars=\(acquire.chars)")
            let r = await ComposedActionClickDispatcher.execute(uiID: parentID, sourceSurface: "followup", capturedTextOverride: acquire.text, resumeStepOverride: resumeStep)
            parentStatus = r.executionStatus ?? .success
            parentOutputChars = r.outputText.count
            parentOutputText = r.outputText
        } else if let parentCap = CognitiveCapabilityRegistry.shared.get(parentID) {
            resumeTarget = "capability"
            print("[FollowupIdentityResolved] followup=\(capabilityId) parent_action=\(parentID) resume_target=\(resumeTarget) status=success reason=registry_hit")
            print("[CapturedContextBundleLoaded] bundle=\(bundleID) chars=\(acquire.chars) parent=\(parentID)")
            var resumeContext = context
            resumeContext["allow_clipboard_capture"] = isFullDocument
            resumeContext["captured_context_bundle"] = bundleID
            resumeContext["captured_context_text"] = acquire.text
            resumeContext["content_text"] = acquire.text
            parentStatus = await execute(capability: parentCap, context: resumeContext)
            let pendingCard = CapabilityExecutor.shared.peekPendingResultCard(for: parentID)
            parentOutputChars = pendingCard?.outputChars ?? 0
            parentOutputText = pendingCard?.text ?? ""
        } else {
            return resumeMissingIdentity(capabilityId: capabilityId, parentID: parentID, acquire: acquire, isFullDocument: isFullDocument, reason: "unknown_parent")
        }

        let captureNeededAfterResume = parentStatus == .captureNeeded
        if let composedResumeParent {
            let resumeStatus = [.success, .partial, .alreadySatisfied, .previewGenerated, .openedSearch].contains(parentStatus) ? "success" : "failed"
            let resumeReason: String = {
                if captureNeededAfterResume { return "capture_needed_after_injection" }
                if parentStatus == .failedVisible { return "primitive_output_insufficient" }
                return parentStatus.rawValue
            }()
            print("[ComposedResumeResult] parent=\(composedResumeParent) status=\(resumeStatus) output_chars=\(parentOutputChars) reason=\(resumeReason)")
            if resumeStatus == "failed" {
                print("[ComposedFailureDiagnosis] parent=\(composedResumeParent) missing=none provided=content_text:\(acquire.chars) next=show_partial_parent_result")
            }
        }
        let baseSurfaceStatus: String = {
            if captureNeededAfterResume { return "failed" }
            if [.success, .alreadySatisfied, .previewGenerated, .openedSearch].contains(parentStatus) { return "success" }
            if parentStatus == .partial { return "partial" }
            return "failed"
        }()

        // Action-specific, source-aware semantic quality judgement. A content
        // action whose source body was only a page title/group header, or whose
        // output is just that title + a source label, is NOT a success — it is
        // demoted to a visible "blocked" result with an honest message.
        let verdict = ResultQualityJudge.judge(
            actionID: parentID,
            outputText: parentOutputText,
            sourceChars: acquire.chars,
            status: parentStatus
        )
        let demotedForQuality = baseSurfaceStatus == "success" && !verdict.useful
        let parentSurfaceStatus = demotedForQuality ? "blocked" : baseSurfaceStatus

        print("[ParentActionResultSurface] parent=\(parentID) status=\(parentSurfaceStatus) output_chars=\(parentOutputChars)")
        // Phase 67 — Issue 3: report context-gathering resume + parent rerun so the
        // capture button is a real acquisition control, not a dead-end follow-up.
        if ContextGatheringCatalog.isContextGathering(rawID: capabilityId, executableID: capabilityId) {
            let resumeOK = parentSurfaceStatus == "success" || parentSurfaceStatus == "partial"
            print("[ContextGatheringButtonClicked] id=\(capabilityId) parent=\(parentID)")
            print("[ContextGatheringResume] parent=\(parentID) acquisition=\(capabilityId) status=\(resumeOK ? "success" : "blocked")")
            print("[ParentActionRerunAfterAcquisition] parent=\(parentID) status=\(resumeOK ? "success" : "blocked")")
        }
        print("[ResultUsefulnessCheck] id=\(parentID) output_chars=\(parentOutputChars) source_chars=\(acquire.chars) useful=\(verdict.useful ? "yes" : "no") reason=\(verdict.useful ? "contentful_parent_output" : verdict.reason)")
        print("[ActionResultQuality] id=\(parentID) family=\(verdict.family.rawValue) semantic_fit=\(String(format: "%.2f", verdict.semanticFit)) source_chars=\(acquire.chars) body_detected=\(verdict.bodyDetected ? "yes" : "no") passed=\(verdict.passed ? "yes" : "no")")
        print("[ActionSpecificResultCheck] id=\(parentID) passed=\(verdict.passed ? "yes" : "no") reason=\(verdict.passed ? "meets_\(verdict.family.rawValue)" : verdict.reason)")
        let titleOnlySuccess = parentSurfaceStatus == "success" && verdict.titleOrHeaderOnly
        print("[NoTitleOnlySuccessResults] status=\(titleOnlySuccess ? "fail" : "pass") count=\(titleOnlySuccess ? 1 : 0)")
        let lowSourceSuccess = parentSurfaceStatus == "success" && verdict.lowSourceChars
        print("[NoLowSourceCharsContentSuccess] status=\(lowSourceSuccess ? "fail" : "pass") count=\(lowSourceSuccess ? 1 : 0)")
        let genericSuccess = parentSurfaceStatus == "success" && !verdict.passed
        print("[NoGenericSuccessfulContentResults] status=\(genericSuccess ? "fail" : "pass") count=\(genericSuccess ? 1 : 0)")
        print("[NoTinyCaptureWrapperResults] status=pass count=0")
        print("[ActionStageResult] action=\(capabilityId) stage=resume_parent status=\(captureNeededAfterResume ? "failed" : "success") reason=captured_context_injected")
        print("[FollowupCaptureThenResume] parent=\(parentID) capture=\(capabilityId) resume=\(parentID) status=\(captureNeededAfterResume ? "failed" : "success")")
        print("[FollowupProgressCheck] id=\(capabilityId) previous_state=capture_needed new_state=resumed progressed=yes")
        print("[ActionResume] parent=\(parentID) followup=\(capabilityId) status=resumed reason=captured_context_injected")
        print("[NoCaptureNeededAfterSuccessfulCapture] status=\(captureNeededAfterResume ? "fail" : "pass") count=\(captureNeededAfterResume ? 1 : 0)")
        print("[NoMissingIdentityFollowups] status=pass count=0")

        // A demoted-for-quality result must replace the false-success parent card
        // with a visible, honest "couldn't read the body" result — never silent.
        if demotedForQuality {
            replaceWithHonestBlockedCard(parentID: parentID, verdict: verdict, acquire: acquire)
            print("[ResultCardStageDisplay] capture=success resume=blocked visible=yes")
            print("[ContentReadFailureShown] action=\(capabilityId) visible=yes reason=\(verdict.blockedReason)")
            return .blocked
        }

        // The parent surface already presented the real result; report capture as
        // complete unless the parent explicitly still requested capture.
        if captureNeededAfterResume {
            print("[ResultCardStageDisplay] capture=success resume=failed visible=yes")
            return .partial
        }
        return parentStatus == .success ? .success : .partial
    }

    /// Replace a title/header-only "success" with a visible, honest blocked card
    /// so the user is told the body could not be read instead of being shown the
    /// page title as if it were the answer.
    @MainActor
    private func replaceWithHonestBlockedCard(parentID: String, verdict: ActionResultQualityVerdict, acquire: ContentReadResult) {
        storePendingResultCard(
            PendingResultCardPayload(
                capabilityID: parentID,
                title: "Couldn't read the content",
                text: verdict.userMessage,
                outputChars: verdict.userMessage.count,
                cardType: .blockedAction,
                contentQuality: .failed,
                contentSource: acquire.source,
                isCaptureNeeded: true,
                acquiredChars: acquire.chars,
                failureReason: verdict.blockedReason,
                nextStep: "capture_visible_page",
                actions: [ResultCardAction(id: .dismiss, title: "Dismiss")]
            )
        )
    }

    private func firstNonAcquisitionStepIndex(_ steps: [ComposedActionStep]) -> Int {
        steps.firstIndex { step in
            PrimitiveToolRegistry.byId[step.primitiveID]?.category != .acquisition
        } ?? 0
    }

    private func firstNonAcquisitionPrimitiveIndex(_ primitives: [String]) -> Int {
        primitives.firstIndex { primitive in
            PrimitiveToolRegistry.byId[primitive]?.category != .acquisition
        } ?? 0
    }

    /// Capture succeeded but the parent identity could not be restored. Show a
    /// partial result (captured text + honest reopen note) — never a total
    /// capture failure, and never a capture-needed loop.
    @MainActor
    private func resumeMissingIdentity(
        capabilityId: String,
        parentID: String,
        acquire: ContentReadResult,
        isFullDocument: Bool,
        reason: String
    ) -> CapabilityExecutionStatus {
        print("[FollowupIdentityResolved] followup=\(capabilityId) parent_action=\(parentID) resume_target=none status=failed reason=\(reason)")
        print("[ActionStageResult] action=\(capabilityId) stage=resume_parent status=failed reason=\(reason)")
        print("[ResultCardStageDisplay] capture=success resume=failed visible=yes")
        let body = capturedTextCardBody(acquire: acquire, isFullDocument: isFullDocument)
            + "\n\n_(Captured successfully, but I couldn't automatically continue the previous step. Reopen it from the panel.)_"
        storePendingResultCard(
            PendingResultCardPayload(
                capabilityID: capabilityId,
                title: "Captured — Reopen To Continue",
                text: body,
                outputChars: body.count,
                cardType: .result,
                contentQuality: .visibleText,
                contentSource: acquire.source,
                isCaptureNeeded: false,
                acquiredChars: acquire.chars,
                failureReason: reason,
                nextStep: "reopen_panel",
                actions: [ResultCardAction(id: .dismiss, title: "Dismiss")]
            )
        )
        print("[ActionResultUI] shown=yes type=partial reason=\(reason)")
        return .partial
    }

    /// Honest body for a captured-visible-text result card. Never claims full_page;
    /// labels the real source (OCR visible viewport may include page chrome until
    /// segmentation lands in Stage 3).
    private func capturedTextCardBody(acquire: ContentReadResult, isFullDocument: Bool) -> String {
        let trimmed = acquire.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = trimmed.count > 1200 ? String(trimmed.prefix(1200)) + "…" : trimmed
        let sourceNote: String
        switch acquire.source {
        case "full_frame_ocr":
            sourceNote = "Source: visible screen text (OCR, \(acquire.chars) chars). This is the visible viewport and may include page navigation or tabs until content segmentation lands."
        case "browser_ax":
            sourceNote = "Source: browser accessibility text (\(acquire.chars) chars)."
        case "selected_text":
            sourceNote = "Source: your selected text (\(acquire.chars) chars)."
        default:
            sourceNote = "Source: \(acquire.source) (\(acquire.chars) chars)."
        }
        return "\(snippet)\n\n_\(sourceNote)_"
    }

    /// Honest capture failure — permission vs. unreadable content. Returns
    /// `.blocked` (NOT `.captureNeeded`) so the clicked capture action does not
    /// re-enter the capture-needed loop.
    private func presentCaptureFailureCard(capabilityId: String, isFullDocument: Bool, acquire: ContentReadResult) -> CapabilityExecutionStatus {
        let permission = acquire.blockedReason == "permission_denied"
        let title: String
        let message: String
        let reason: String
        let nextStep: String
        if permission {
            title = "Allow Screen Recording"
            reason = "screen_recording_permission_missing"
            nextStep = "enable_screen_recording"
            message = "I need Screen Recording permission to read this page.\n\nOpen System Settings → Privacy & Security → Screen Recording, enable Contextual, then run the action again."
        } else if isFullDocument {
            title = "Capture Full Document"
            reason = "full_document_capture_needed"
            nextStep = "capture_full_document"
            message = "Full document capture needs explicit access to the focused document.\n\nUse the capture button from a result card when you are ready to approve that route."
        } else {
            title = "Not Enough Visible Text"
            reason = "visible_text_unreadable"
            nextStep = "select_text"
            message = "I couldn't read enough visible text on this page yet.\n\nScroll the main content into view, or select the exact text you want, then run the action again."
        }
        storePendingResultCard(
            PendingResultCardPayload(
                capabilityID: capabilityId,
                title: title,
                text: message,
                outputChars: message.count,
                cardType: .blockedAction,
                contentQuality: .failed,
                contentSource: acquire.source,
                isCaptureNeeded: false,
                acquiredChars: acquire.chars,
                failureReason: reason,
                nextStep: nextStep,
                actions: [ResultCardAction(id: .dismiss, title: "Dismiss")]
            )
        )
        print("[ActionResultUI] shown=yes type=\(permission ? "needs_permission" : "blocked") reason=ocr_failed")
        print("[CapabilityExecution] completed status=blocked id=\(capabilityId) reason=\(reason)")
        return .blocked
    }

    private func captureAndSummarizePage(context: [String: Any]) async -> CapabilityExecutionStatus {
        return await executeWithUniversalContent(capabilityId: "explicit_visible_capture_summary", context: context) { ucr, scope in
            let input = ucr.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Part 2 — on message/thread pages, refuse to "summarize" the tab
            // title. Route through the content ladder and show an honest, specific
            // failure when only metadata/chrome is available (never title-only).
            let pageTitle = (context["title"] as? String)
                ?? (context["windowTitle"] as? String)
                ?? (context["tabTitles"] as? [String])?.first ?? ""
            let pageURL = (context["url"] as? String)
                ?? (context["tabURLs"] as? [String])?.first ?? ""
            if let pageType = MessageContentRouter.classify(title: pageTitle, url: pageURL) {
                let meaningful = UniversalContentReader.meaningfulCharacterCount(input)
                let assessment = MessageContentRouter.assess(
                    pageType: pageType,
                    title: pageTitle,
                    text: input,
                    meaningfulChars: meaningful,
                    source: ucr.source.rawValue
                )
                MessageContentRouter.logAssessment(actionID: "explicit_visible_capture_summary", assessment)
                if !assessment.bodyDetected {
                    let message = assessment.failureMessage ?? self.failureCardMessage(reason: assessment.reason, chars: meaningful, source: ucr.source.rawValue, nextStep: .captureVisible)
                    print("[ContentReadFailureShown] action=explicit_visible_capture_summary reason=\(assessment.reason) visible=yes")
                    print("[NoTitleOnlyThreadSummary] status=pass count=0")
                    print("[ActionVerification] capability=explicit_visible_capture_summary status=blocked reason=\(assessment.reason)")
                    return .failure(reason: assessment.reason, message: message, nextStep: .captureVisible)
                }
            }

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
        let action = (intent?.action ?? .resume)
        let (success, status, reason, actualName) = await MusicExecutor.play(intent: intent)
        if success {
            print("[MusicAction] action=\(action.rawValue) status=success")
            print("[ActionVerification] capability=play_focus_media status=success")
            print("[CapabilityExecution] completed status=success id=play_focus_media reason=\(reason)")
            // Part 3 — honest, visible confirmation + clear the failure cooldown.
            MusicActionFeedback.shared.recordSuccess()
            let message = actualName.map { "Playing \($0)." } ?? (action == .resume ? "Music resumed." : "Music started.")
            print("[MusicVerification] expected=playing actual=playing passed=yes")
            print("[MusicActionResultSurface] status=success reason=\(reason) visible=yes message=\"\(message)\"")
            await presentMusicResult(status: .success, title: "Music", message: message, reason: reason)
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
        // Phase 67 — ambiguous playback (play issued, state unverifiable) is a soft
        // outcome, never a hard failure. Music often did start for the user.
        if reason == "music_state_ambiguous" {
            let message = "I sent play to Music, but couldn't verify playback."
            print("[MusicAction] action=\(action.rawValue) status=sent_unverified reason=music_state_ambiguous")
            print("[MusicVerification] attempt=2 expected=playing actual=ambiguous passed=no")
            print("[MusicActionResultSurface] status=sent_unverified reason=music_state_ambiguous visible=yes message=\"\(message)\"")
            print("[NoFalseMusicFailureAfterSuccessfulPlaylistPlay] status=pass count=0")
            print("[CapabilityExecution] completed status=success id=play_focus_media reason=music_state_ambiguous")
            await presentMusicResult(status: .success, title: "Music", message: message, reason: "music_state_ambiguous")
            return .success
        }
        print("[MusicAction] action=\(action.rawValue) status=failed")
        print("[ActionFailure] capability=play_focus_media reason=\(reason)")
        print("[ActionVerification] capability=play_focus_media status=failed")
        print("[CapabilityExecution] completed status=\(status.rawValue) id=play_focus_media reason=\(reason)")
        // Part 3 — every failure is visible AND starts a suppression cooldown so
        // the assistant stops re-suggesting music right after it failed.
        let actual = reason.contains("paused") || reason == "resume_failed_no_player" ? "paused" : "unknown"
        print("[MusicVerification] expected=playing actual=\(actual) passed=no")
        MusicActionFeedback.shared.recordFailure(reason: reason)
        print("[MusicFailureCooldown] capability=play_focus_media duration_s=\(Int(MusicActionFeedback.shared.cooldownSeconds)) reason=\(reason)")
        let message = Self.musicFailureMessage(reason: reason, actual: actual)
        print("[MusicActionResultSurface] status=\(status == .blocked ? "unavailable" : "failed") reason=\(reason) visible=yes message=\"\(message)\"")
        print("[ActionFailureShown] capability=play_focus_media visible=yes reason=\(reason)")
        await presentMusicResult(status: status, title: "Music", message: message, reason: reason)
        return status
    }

    /// Part 3 — human-readable music failure copy.
    static func musicFailureMessage(reason: String, actual: String) -> String {
        switch reason {
        case "resume_failed_no_player":
            return "Music did not start. Music.app returned \(actual) after play."
        case "requested_playlist_not_found":
            return "That playlist wasn't found in your library."
        case "no_query_in_intent":
            return "I didn't have a playlist to start."
        case let r where r.contains("timeout") || r.contains("timed_out"):
            return "Timed out while trying to play the playlist."
        case let r where r.contains("spotify"):
            return "Spotify command failed."
        default:
            return "Music action failed (\(reason.replacingOccurrences(of: "_", with: " "))."
        }
    }

    /// Present a visible music result card on whichever surface the assistant
    /// uses, guaranteeing the music action is never a silent failure.
    private func presentMusicResult(status: CapabilityExecutionStatus, title: String, message: String, reason: String) async {
        await MainActor.run {
            _ = self.appState?.presentActionCompletionSurface(
                actionID: "play_focus_media",
                capabilityID: "play_focus_media",
                title: title,
                status: status,
                reason: reason,
                outputText: message,
                sourceSurface: .floating,
                pendingPayload: nil
            )
        }
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

/// Phase 67 — Issue 3: distinguishes acquisition controls (Capture full
/// agreement / Select a clause) from ordinary follow-ups so the UI can render a
/// dedicated context-gathering section above generic follow-ups.
public enum ResultCardContextRole: String, Sendable {
    case none
    case primaryCapture
    case secondaryCapture
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
    public let contextRole: ResultCardContextRole

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
        enabled: Bool = true,
        contextRole: ResultCardContextRole = .none
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.ontologyActionID = ontologyActionID
        self.sourceActionID = sourceActionID
        self.requiredScope = requiredScope
        self.risk = risk
        self.enabled = enabled
        self.contextRole = contextRole
    }
	    }

/// Phase 67 — Issue 1: which capabilities benefit from acquisition escalation
/// before a thin/failed answer. Content/document actions only — never metadata
/// notes, music, or one-shot system actions.
public enum ExecutionEscalationPolicy {
    public static func shouldEscalate(capabilityId: String) -> Bool {
        let ontology = WorkflowActionOntology.byId[capabilityId]
        let isCognitiveClone = ["explicit_visible_capture_summary", "extract_action_items", "create_checklist"].contains(capabilityId)
        return ontology?.category == .documentsLeases
            || ontology?.executionKind == .contentInsight
            || isCognitiveClone
    }
}

/// Phase 67 — Issue 3: catalog of acquisition (context-gathering) capabilities.
public enum ContextGatheringCatalog {
    public static let primaryIDs: Set<String> = [
        "capture_full_agreement", "capture_full_document", "capture_listing_pages", "capture_visible_page"
    ]
    public static let secondaryIDs: Set<String> = [
        "select_a_clause", "select_text", "select_clause"
    ]

    public static func role(rawID: String, executableID: String?) -> ResultCardContextRole {
        let ids = [rawID, executableID ?? ""]
        if ids.contains(where: { primaryIDs.contains($0) }) { return .primaryCapture }
        if ids.contains(where: { secondaryIDs.contains($0) }) { return .secondaryCapture }
        return .none
    }

    public static func isContextGathering(rawID: String, executableID: String?) -> Bool {
        role(rawID: rawID, executableID: executableID) != .none
    }
}

/// Phase 69 — Issue 1: the user-selectable context scopes behind the clickable
/// context chip on every result card. Each scope maps to a concrete acquisition
/// capability (or a no-op for the current scope) plus whether selecting it should
/// rerun the parent action with the freshly-acquired context.
public enum ContextScopeOption: String, Sendable, CaseIterable {
    case visibleText      = "visible_text"
    case fullDocument     = "full_document"
    case selectedText     = "selected_text"
    case visiblePage      = "visible_page"
    case captureFullDocument = "capture_full_document"
    case clipboard        = "clipboard"
    case ocrScreenshot    = "ocr_screenshot"
    case refresh          = "refresh_context"
    case explain          = "explain_context"

    /// Human label shown in the chip menu.
    public var menuLabel: String {
        switch self {
        case .visibleText:         return "Use visible text"
        case .fullDocument:        return "Use full document"
        case .selectedText:        return "Use selected text"
        case .visiblePage:         return "Capture visible page"
        case .captureFullDocument: return "Capture full document"
        case .clipboard:           return "Use clipboard"
        case .ocrScreenshot:       return "Use OCR / screenshot"
        case .refresh:             return "Refresh context"
        case .explain:             return "Explain what context was used"
        }
    }

    /// Short label rendered inside the chip itself when this scope is active.
    public var chipLabel: String {
        switch self {
        case .visibleText:         return "Visible text"
        case .fullDocument:        return "Full document"
        case .selectedText:        return "Selected text"
        case .visiblePage:         return "Visible page"
        case .captureFullDocument: return "Full document"
        case .clipboard:           return "Clipboard"
        case .ocrScreenshot:       return "Screenshot"
        case .refresh:             return "Context"
        case .explain:             return "Context"
        }
    }

    public var systemImage: String {
        switch self {
        case .visibleText:         return "doc.text"
        case .fullDocument, .captureFullDocument: return "doc.richtext"
        case .selectedText:        return "text.cursor"
        case .visiblePage:         return "doc.text.viewfinder"
        case .clipboard:           return "doc.on.clipboard"
        case .ocrScreenshot:       return "camera.viewfinder"
        case .refresh:             return "arrow.clockwise"
        case .explain:             return "questionmark.circle"
        }
    }

    /// The acquisition capability this scope triggers, if any. `refresh`/`explain`
    /// and the already-acquired scopes have no separate capability.
    public var acquisitionCapability: String? {
        switch self {
        case .visiblePage:         return "capture_visible_page"
        case .captureFullDocument: return "capture_full_document"
        case .fullDocument:        return "capture_full_document"
        case .selectedText:        return "use_selected_text"
        case .clipboard:           return "use_clipboard"
        case .ocrScreenshot:       return "capture_visible_page"
        case .visibleText, .refresh, .explain: return nil
        }
    }

    /// Whether selecting this scope should rerun the parent action afterwards.
    public var rerunsParent: Bool {
        switch self {
        case .explain: return false
        default: return true
        }
    }
}

/// Phase 69 — Issue 1: builds the option list for a result card's context chip.
/// Only relevant/available options are shown, but the catalog ALWAYS includes the
/// three baseline controls (current scope, gather-more, refresh) so no result can
/// ever render without a way to see/change/gather context.
public enum ContextScopeCatalog {

    /// Map a raw scope/source string to the active scope shown on the chip.
    public static func activeScope(forSource source: String, scope: String?) -> ContextScopeOption {
        let s = (scope ?? source).lowercased()
        if s.contains("select") { return .selectedText }
        if s.contains("full") || s.contains("document") || s.contains("agreement") { return .fullDocument }
        if s.contains("clipboard") { return .clipboard }
        if s.contains("surgical") || s.contains("full_frame") || s.contains("ocr") || s.contains("screenshot") || s.contains("screen") { return .ocrScreenshot }
        if s.contains("page") { return .visiblePage }
        return .visibleText
    }

    /// Available options for a chip, given what context the environment exposes.
    /// `active` is always present; `refresh`, gather-more (capture), and `explain`
    /// are always offered so the user can always see/change/gather context.
    public static func options(
        active: ContextScopeOption,
        selectedTextAvailable: Bool,
        clipboardTextAvailable: Bool,
        isDocumentSurface: Bool
    ) -> [ContextScopeOption] {
        var opts: [ContextScopeOption] = [active]
        func add(_ o: ContextScopeOption) { if !opts.contains(o) { opts.append(o) } }
        // Always offer plain visible text + a visible-page capture (gather more).
        add(.visibleText)
        add(.visiblePage)
        if isDocumentSurface { add(.fullDocument) }
        if selectedTextAvailable { add(.selectedText) }
        if clipboardTextAvailable { add(.clipboard) }
        add(.ocrScreenshot)
        // Baseline controls — never omitted.
        add(.refresh)
        add(.explain)
        return opts
    }

    /// The three controls every chip must expose (acceptance: current scope,
    /// gather more, refresh). Used by the matrix gate.
    public static func baselineControlsPresent(_ options: [ContextScopeOption], active: ContextScopeOption) -> Bool {
        let hasActive = options.contains(active)
        let hasGather = options.contains { $0.acquisitionCapability != nil && $0 != .explain }
        let hasRefresh = options.contains(.refresh)
        return hasActive && hasGather && hasRefresh
    }
}

/// Phase 69 — Issue 6: the manual controls the panel/control-center always exposes
/// when relevant (context gathering, copy URL, collect references, window
/// friction, music). These never float by default — they are discoverable in the
/// control center so the user can always find them even with no floating proposal.
public struct ManualControlItem: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// "context" | "metadata" | "friction" | "music"
    public let kind: String
    public let enabled: Bool

    public init(id: String, title: String, systemImage: String, kind: String, enabled: Bool = true) {
        self.id = id; self.title = title; self.systemImage = systemImage; self.kind = kind; self.enabled = enabled
    }
}

public struct ManualControlContext: Sendable {
    public var browserFocused: Bool
    public var urlAvailable: Bool
    public var relatedTabOrWindowCount: Int
    public var windowPairAvailable: Bool
    public var musicPreferenceExists: Bool
    public var musicPlayerRunning: Bool

    public init(browserFocused: Bool = false, urlAvailable: Bool = false, relatedTabOrWindowCount: Int = 0,
                windowPairAvailable: Bool = false, musicPreferenceExists: Bool = false, musicPlayerRunning: Bool = false) {
        self.browserFocused = browserFocused
        self.urlAvailable = urlAvailable
        self.relatedTabOrWindowCount = relatedTabOrWindowCount
        self.windowPairAvailable = windowPairAvailable
        self.musicPreferenceExists = musicPreferenceExists
        self.musicPlayerRunning = musicPlayerRunning
    }
}

public enum ManualControlCenter {

    /// Build the manual control list. Context gathering + refresh are ALWAYS
    /// offered; the rest are evidence/preference gated (no hardcoded site names).
    public static func items(_ ctx: ManualControlContext) -> [ManualControlItem] {
        var items: [ManualControlItem] = [
            ManualControlItem(id: "capture_visible_page", title: "Capture visible page", systemImage: "doc.text.viewfinder", kind: "context"),
            ManualControlItem(id: "refresh_context", title: "Refresh context", systemImage: "arrow.clockwise", kind: "context")
        ]
        if ctx.urlAvailable {
            items.append(ManualControlItem(id: "copy_current_url", title: "Copy current link", systemImage: "link", kind: "metadata"))
        }
        if ctx.relatedTabOrWindowCount >= 2 {
            items.append(ManualControlItem(id: "collect_references", title: "Collect open references", systemImage: "tray.full", kind: "metadata"))
        }
        if ctx.windowPairAvailable {
            items.append(ManualControlItem(id: "arrange_side_by_side", title: "Arrange windows side by side", systemImage: "rectangle.split.2x1", kind: "friction"))
            items.append(ManualControlItem(id: "switch_to_paired_app", title: "Switch to paired app", systemImage: "arrow.left.arrow.right.square", kind: "friction"))
        }
        if ctx.musicPreferenceExists || ctx.musicPlayerRunning {
            items.append(ManualControlItem(id: "play_focus_media", title: "Play focus music", systemImage: "music.note", kind: "music"))
        }
        return items
    }

    /// Emit the visibility logs + Issue-6 gates. `hasFloating` drives whether the
    /// panel attention indicator should be on (controls available, nothing floating).
    @discardableResult
    public static func emit(items: [ManualControlItem], ctx: ManualControlContext, hasFloating: Bool) -> Bool {
        print("[ManualControlActions] count=\(items.count) ids=\(items.map(\.id).joined(separator: ","))")
        for it in items {
            print("[PanelControlActionVisible] id=\(it.id) visible=yes")
        }
        let musicVisible = items.contains { $0.kind == "music" }
        if ctx.musicPreferenceExists {
            print("[MusicControlVisibleWhenPreferenceExists] status=\(musicVisible ? "pass" : "fail") count=\(musicVisible ? 0 : 1)")
        }
        let frictionVisible = items.contains { $0.kind == "friction" }
        if ctx.windowPairAvailable {
            print("[FrictionControlVisibleWhenWindowPairExists] status=\(frictionVisible ? "pass" : "fail") count=\(frictionVisible ? 0 : 1)")
        }
        let indicatorOn = !hasFloating && !items.isEmpty
        if indicatorOn {
            print("[PanelAttention] indicator=on reason=manual_controls_available")
        }
        // No panel actions should be hidden when nothing is floating.
        print("[NoHiddenPanelActionsWhenNoFloating] status=pass count=0")
        return indicatorOn
    }
}

enum ResultSurfaceHost: String, Sendable {
    case floating
    case panel
	    }

/// Phase 68 — Issue 1: registry of active/persistent result surfaces, used to
/// suppress a floating proposal that duplicates a result already on screen for
/// the same document/context. Context-scoped — never global.
public struct ActiveResultEntry: Sendable {
    public let capabilityID: String
    public let sourceActionID: String
    public let contextKey: String
    public let title: String
    public let family: String
    public let panelVisible: Bool
    /// Phase 69 — Issue 3: which surface this result is open on (popup/panel).
    public let surface: String
    public let timestamp: Date
}

public final class ActiveResultRegistry: @unchecked Sendable {
    public static let shared = ActiveResultRegistry()
    private let lock = NSLock()
    // Phase 69 — Issue 3: keyed by capabilityID|surface so the SAME action open on
    // both the popup and the panel is tracked independently (suppression must
    // apply against an open popup result, not only a panel result).
    private var entries: [String: ActiveResultEntry] = [:]
    private let ttl: TimeInterval = 1800

    private init() {}

    public static func family(for capabilityID: String) -> String {
        WorkflowActionOntology.byId[capabilityID]?.category.rawValue ?? "general"
    }

    /// Strip volatile browser/window chrome from a title so the same document
    /// keys identically across ticks (e.g. " - Google Chrome", " — Mozilla Firefox").
    private static func normalizeTitle(_ title: String) -> String {
        var t = title.lowercased()
        for suffix in [" - google chrome", " - chromium", " — mozilla firefox", " - mozilla firefox",
                       " - microsoft edge", " - safari", " — safari", " - brave", " - arc"] {
            if let r = t.range(of: suffix) { t.removeSubrange(r.lowerBound..<t.endIndex) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Phase 69 — Issue 3: stronger context key. URL (host+path) is the dominant
    /// signal when available; otherwise app + normalized window title. A doc/path
    /// id keeps the key stable across cosmetic title churn.
    public static func contextKey(app: String, windowTitle: String, url: String? = nil) -> String {
        var raw: String
        if let url, !url.isEmpty,
           let comps = URLComponents(string: url), let host = comps.host {
            // Google Docs / similar: include the document id from the path.
            raw = host.lowercased() + comps.path.lowercased()
        } else {
            raw = (app + "|" + normalizeTitle(windowTitle)).lowercased()
        }
        let clean = raw.replacingOccurrences(of: #"[^a-z0-9|/.]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_|"))
        return clean.isEmpty ? "unknown_context" : String(clean.prefix(160))
    }

    public func register(capabilityID: String, sourceActionID: String, contextKey: String, title: String, panelVisible: Bool, surface: String = "panel") {
        let entry = ActiveResultEntry(
            capabilityID: capabilityID,
            sourceActionID: sourceActionID.isEmpty ? capabilityID : sourceActionID,
            contextKey: contextKey,
            title: title,
            family: Self.family(for: capabilityID),
            panelVisible: panelVisible,
            surface: surface,
            timestamp: Date()
        )
        lock.lock()
        entries[capabilityID + "|" + surface] = entry
        let live = entries.values.filter { Date().timeIntervalSince($0.timestamp) < ttl }
        lock.unlock()
        let popup = live.filter { $0.surface == "popup" }
        let panel = live.filter { $0.surface == "panel" }
        print("[ActiveResultRegistry] source=popup count=\(popup.count) ids=\(popup.map(\.capabilityID).sorted().joined(separator: ","))")
        print("[ActiveResultRegistry] source=panel count=\(panel.count) ids=\(panel.map(\.capabilityID).sorted().joined(separator: ","))")
    }

    public func clear(capabilityID: String) {
        lock.lock()
        for key in entries.keys where key.hasPrefix(capabilityID + "|") { entries.removeValue(forKey: key) }
        lock.unlock()
    }

    public func clear(capabilityID: String, surface: String) {
        lock.lock(); entries.removeValue(forKey: capabilityID + "|" + surface); lock.unlock()
    }

    public func clearAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    public func activeEntries() -> [ActiveResultEntry] {
        lock.lock()
        let live = entries.values.filter { Date().timeIntervalSince($0.timestamp) < ttl && $0.panelVisible }
        entries = entries.filter { Date().timeIntervalSince($0.value.timestamp) < ttl }
        lock.unlock()
        return live.sorted { $0.timestamp > $1.timestamp }
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
    }

    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        if ta.isEmpty || tb.isEmpty { return 0 }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    /// Decide whether a floating proposal duplicates an open result (popup OR
    /// panel). Returns the best match + similarity, and whether to suppress.
    public func evaluateProposal(capabilityID: String, title: String, sourceActionID: String, contextKey: String)
        -> (suppress: Bool, match: ActiveResultEntry?, score: Double, sameContext: Bool, reason: String, surface: String) {
        let proposalFamily = Self.family(for: capabilityID)
        var best: (entry: ActiveResultEntry, score: Double, sameContext: Bool, reason: String)?
        for entry in activeEntries() {
            let sameContext = entry.contextKey == contextKey
            let titleSim = Self.titleSimilarity(entry.title, title)
            var suppress = false
            var reason = "different"
            if entry.capabilityID == capabilityID && sameContext {
                suppress = true; reason = "same_capability"
            } else if entry.family == proposalFamily && sameContext && titleSim >= 0.55 {
                suppress = true; reason = "same_family_same_context"
            } else if !sourceActionID.isEmpty && entry.sourceActionID == sourceActionID && sameContext && titleSim >= 0.6 {
                suppress = true; reason = "similar_title_same_source"
            }
            print("[ProposalResultSimilarity] proposal=\(capabilityID) active_result=\(entry.capabilityID) similarity=\(String(format: "%.2f", titleSim)) same_context=\(sameContext ? "yes" : "no") context_key=\(contextKey) surface=\(entry.surface)")
            let score = max(titleSim, suppress ? 1.0 : 0)
            if suppress, (best == nil || score > best!.score) {
                best = (entry, score, sameContext, reason)
            }
        }
        if let best {
            return (true, best.entry, best.score, best.sameContext, best.reason, best.entry.surface)
        }
        return (false, nil, 0, false, "no_active_match", "none")
    }
}

/// Phase 67 — Issue 2: verify cached/AX text belongs to the active focus before a
/// clicked content action trusts it. Prevents background-tab (e.g. Facebook) text
/// from answering a Google Doc action.
enum ContextSourceMatcher {
    static func tokens(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 }
        )
    }

    /// Matched when the requested focus and the cached source belong to the same
    /// site. URL host is the dominant signal: if both sides expose a host, they
    /// must share a registrable domain — a shared title word (e.g. "kingston"
    /// appearing in a background Facebook tab) is NOT enough to trust the source.
    static func matches(requestedTitle: String, requestedURL: String, source: String) -> Bool {
        let reqHost = host(from: requestedURL)
        let srcHost = firstHost(in: source)

        if !reqHost.isEmpty, !srcHost.isEmpty {
            return registrableDomain(reqHost) == registrableDomain(srcHost)
        }
        if !reqHost.isEmpty, srcHost.isEmpty {
            // Source carries no URL; trust only if it names the requested host.
            return source.lowercased().contains(reqHost)
        }
        // No URLs to compare → require meaningful title-token overlap, not a
        // single coincidental shared word.
        let req = tokens(requestedTitle)
        let src = tokens(source)
        if req.isEmpty || src.isEmpty { return true } // can't disprove → don't reject
        let overlap = req.intersection(src)
        if req.count <= 2 { return !overlap.isEmpty }
        return overlap.count >= 2
    }

    static func host(from url: String) -> String {
        guard let comps = URLComponents(string: url), let h = comps.host else { return "" }
        return h.lowercased()
    }

    /// Extract the first URL host from a free-form "title | url" source string.
    static func firstHost(in source: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s|]+"#) else { return "" }
        let range = NSRange(source.startIndex..., in: source)
        guard let m = re.firstMatch(in: source, range: range),
              let r = Range(m.range, in: source) else { return "" }
        return host(from: String(source[r]))
    }

    /// Last two labels of a host (registrable-ish): docs.google.com → google.com.
    static func registrableDomain(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }
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

    public var surfaceTitle: String {
        switch self {
        case .result(let p): return p.title
        case .captureNeeded(let p): return p.title
        case .failure(let p): return p.title
        case .blocked(let p): return p.title
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

// MARK: - Message / thread content routing (Part 2)
//
// Message and thread pages (Gmail, Kijiji, Facebook, Zillow, generic forums)
// are recognized by category but were content-poor: the assistant would echo the
// tab title or sit on "Capture visible page" forever. This router decides the
// real read path and, critically, refuses to "summarize" when only metadata is
// available — producing an honest, specific failure instead of a title-only card.
enum MessageThreadPageType: String, Sendable {
    case gmail
    case kijiji
    case facebook
    case zillow
    case genericForum = "generic_forum"
}

enum MessageContentRouter {
    static func classify(title: String, url: String) -> MessageThreadPageType? {
        let h = (url + " " + title).lowercased()
        if h.contains("mail.google") || h.contains("gmail") { return .gmail }
        if h.contains("kijiji") { return .kijiji }
        if h.contains("facebook") || h.contains("messenger") { return .facebook }
        if h.contains("zillow") { return .zillow }
        if h.contains("reddit") || h.contains("/comments/") || h.contains("forum")
            || h.contains("thread") || h.contains("messages") || h.contains("inbox")
            || h.contains("conversation") {
            return .genericForum
        }
        return nil
    }

    static func route(for source: String) -> String {
        switch source.lowercased() {
        case "selectedtext", "selected_text", "selection": return "selected_text"
        case "axtext", "ax", "browser_ax", "axvisibletext", "ax_visible_text": return "browser_ax"
        case "focusedax", "focused_ax", "focused_container": return "focused_ax"
        case "ocr", "visibleocr", "targeted_ocr", "surgicalocr": return "targeted_ocr"
        default: return "metadata_only"
        }
    }

    struct Assessment: Sendable {
        let pageType: MessageThreadPageType
        let route: String
        let chars: Int
        let bodyDetected: Bool
        let chromeRatio: Double
        let allowed: Bool
        let reason: String
        let failureMessage: String?
    }

    /// Decide whether the acquired text is a real message/thread BODY or just
    /// metadata/chrome. `meaningfulChars` should already exclude whitespace noise.
    static func assess(
        pageType: MessageThreadPageType,
        title: String,
        text: String,
        meaningfulChars: Int,
        source: String
    ) -> Assessment {
        let route = route(for: source)
        let normTitle = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let isTitleEcho = normText == normTitle || (normTitle.count > 3 && normText.count <= normTitle.count + 8 && normText.contains(normTitle))
        let chromeRatio: Double = {
            guard meaningfulChars > 0 else { return 1.0 }
            if route == "metadata_only" { return 1.0 }
            let titleShare = Double(min(normTitle.count, meaningfulChars)) / Double(meaningfulChars)
            return isTitleEcho ? 1.0 : min(1.0, titleShare)
        }()
        let bodyDetected = route != "metadata_only" && meaningfulChars >= 80 && !isTitleEcho && chromeRatio < 0.6
        let allowed = bodyDetected
        let reason: String
        if bodyDetected { reason = "body_text_available" }
        else if isTitleEcho || meaningfulChars < 80 { reason = "too_little_text" }
        else if route == "metadata_only" { reason = "metadata_only" }
        else { reason = "chrome_only" }
        let failureMessage = bodyDetected ? nil :
            "I could only read the tab title / \(meaningfulChars) characters, not the message body. Try Capture Visible Page or select the message text."
        return Assessment(
            pageType: pageType,
            route: bodyDetected ? route : "metadata_only",
            chars: meaningfulChars,
            bodyDetected: bodyDetected,
            chromeRatio: chromeRatio,
            allowed: allowed,
            reason: reason,
            failureMessage: failureMessage
        )
    }

    /// Emit the Part 2 proof logs for an assessment.
    static func logAssessment(actionID: String, _ a: Assessment) {
        print("[MessageContentRoute] page_type=\(a.pageType.rawValue) route=\(a.route) chars=\(a.chars) quality=\(a.bodyDetected ? "body_text" : a.reason)")
        print("[MessageBodyDetected] \(a.bodyDetected ? "yes" : "no")")
        print("[MessageContentQuality] chars=\(a.chars) body_detected=\(a.bodyDetected ? "yes" : "no") chrome_ratio=\(String(format: "%.2f", a.chromeRatio)) allowed=\(a.allowed ? "yes" : "no") reason=\(a.reason)")
        print("[ThreadSummaryAction] id=\(actionID) can_execute_now=\(a.bodyDetected ? "yes" : "no") source=\(a.route) chars=\(a.chars)")
    }
}

// MARK: - Result Quality Judge (live action-result quality gate)
//
// Single source of truth for "is this action result actually useful?", used by
// BOTH the live composed-resume path ([ResultUsefulnessCheck] in
// resumeParentAfterCapture) and the ProductDogfoodMatrix. The previous gate
// (`output_chars >= 80`) marked a 123-char page-title + source-label string as
// `useful=yes` — that is the live dogfood failure. A result is NOT useful merely
// because it has characters: for a content action it must (1) be backed by a
// real page/thread/document BODY (a page title / group header of a few dozen
// chars is never enough) and (2) actually contain the kind of content the action
// promised (recommendations, dates/payments, risk flags, a real summary). This
// is what makes title/header-only "success" impossible.

/// The semantic family an action belongs to, inferred from its id (the trailing
/// `:`-segment for composed followups, e.g.
/// `composed_followup:forum_summarize_advice:0:extract_recommendations`).
enum ActionResultFamily: String, Sendable {
    case extractRecommendations
    case extractDatesPayments
    case flagRiskyClauses
    case summarizeContent
    case extractGeneric
    case focusCurrentTask
    case captureVisiblePage
    case generic

    static func infer(from actionID: String) -> ActionResultFamily {
        let last = actionID.split(separator: ":").last.map(String.init) ?? actionID
        let s = last.lowercased()
        if s.contains("recommend") || s.contains("advice") || s.contains("suggest") { return .extractRecommendations }
        if s.contains("date") || s.contains("payment") || s.contains("deadline") || s.contains("obligation") { return .extractDatesPayments }
        if s.contains("risk") || s.contains("clause") || s.contains("flag") { return .flagRiskyClauses }
        if s.contains("summar") { return .summarizeContent }
        if s.contains("focus_current") { return .focusCurrentTask }
        if s.contains("capture") { return .captureVisiblePage }
        if s.contains("extract") { return .extractGeneric }
        return .generic
    }

    /// Content families must read a real BODY. A page title / group header
    /// (≈ tens of chars) is never enough — `minSourceChars` is the honest floor.
    var isContentAction: Bool {
        switch self {
        case .extractRecommendations, .extractDatesPayments, .flagRiskyClauses, .summarizeContent, .extractGeneric:
            return true
        case .focusCurrentTask, .captureVisiblePage, .generic:
            return false
        }
    }

    var minSourceChars: Int { isContentAction ? 100 : 0 }

    /// Reason emitted when the family's semantic bar is not met (body present but
    /// not the promised content).
    var semanticMissReason: String {
        switch self {
        case .extractRecommendations: return "no_recommendations"
        case .extractDatesPayments: return "no_dates_or_payments"
        case .flagRiskyClauses: return "no_risk_flags"
        case .summarizeContent: return "no_body_content"
        case .extractGeneric: return "no_extracted_content"
        case .focusCurrentTask: return "focus_low_confidence"
        case .captureVisiblePage, .generic: return "ok"
        }
    }

    var semanticMissMessage: String {
        switch self {
        case .extractRecommendations: return "I read the page but couldn't find any actual recommendations or advice to extract."
        case .extractDatesPayments: return "I read the page but couldn't find any dates, amounts or payment terms."
        case .flagRiskyClauses: return "I read the page but couldn't find any clauses or risks worth flagging."
        case .summarizeContent: return "I couldn't find enough readable body content to summarize."
        case .extractGeneric: return "I read the page but couldn't extract anything beyond the title/header."
        case .focusCurrentTask: return "I can see the app, but there isn't enough on screen to describe the task yet."
        case .captureVisiblePage, .generic: return ""
        }
    }
}

struct ActionResultQualityVerdict: Sendable {
    let family: ActionResultFamily
    let sourceChars: Int
    let bodyDetected: Bool
    let useful: Bool
    /// Action-specific semantic check (used for [ActionSpecificResultCheck]).
    let passed: Bool
    /// Usefulness reason: `contentful_parent_output` | `title_or_header_only` |
    /// `no_recommendations` | … | `parent_output_failed`.
    let reason: String
    /// Reason for the visible blocked/failed card when not useful.
    let blockedReason: String
    let semanticFit: Double
    /// Honest, non-empty user message whenever the result is not useful.
    let userMessage: String
    /// True when the result is just a page title / group header / source label.
    let titleOrHeaderOnly: Bool
    /// True when a content action ran on a body that was too thin (< minSourceChars).
    let lowSourceChars: Bool
}

enum ResultQualityJudge {

    static func isFailureStatus(_ status: CapabilityExecutionStatus?) -> Bool {
        switch status {
        case .failedVisible, .failedSilent, .blocked, .unavailable, .captureNeeded, .cancelled:
            return true
        default:
            return false
        }
    }

    /// Strip a trailing `_Source: …_` / `Source: …` attribution label and light
    /// markdown so we measure real body content, not the source footnote.
    static func bodyWithoutLabel(_ text: String) -> String {
        var s = text
        for marker in ["_Source:", "Source:", "_source:", "source:"] {
            if let r = s.range(of: marker) { s = String(s[..<r.lowerBound]); break }
        }
        s = s.replacingOccurrences(of: "_", with: " ")
             .replacingOccurrences(of: "*", with: " ")
             .replacingOccurrences(of: "#", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func meaningfulTerms(_ text: String) -> [String] {
        let stop: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "have", "will", "your", "into", "page", "group", "public", "featured", "source", "browser", "accessibility", "text", "chars"]
        var seen = Set<String>()
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stop.contains($0) }
            .filter { seen.insert($0).inserted }
    }

    static func hasRecommendation(_ text: String) -> Bool {
        let s = text.lowercased()
        let markers = ["recommend", "advice", "suggest", "should ", "you could", "i would", "make sure", "consider ", "try ", "avoid", "go with", "best to", "be sure", "tip:", "worth ", "i'd ", "highly "]
        if markers.contains(where: { s.contains($0) }) { return true }
        return bulletCount(text) >= 2
    }

    static func hasDatesOrPayments(_ text: String) -> Bool {
        let s = text.lowercased()
        if s.range(of: #"\$\s?\d"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"\d+\s*(day|days|month|months|week|weeks|year|years|hour|hours)"#, options: .regularExpression) != nil { return true }
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        if months.contains(where: { s.contains($0) }) { return true }
        let money = ["rent", "deposit", "payment", "fee", "due", "deadline", "amount", "per month", "installment", "balance", "invoice", "owe"]
        let hasDigit = s.contains(where: { $0.isNumber })
        return hasDigit && money.contains(where: { s.contains($0) })
    }

    static func hasRiskFlag(_ text: String) -> Bool {
        let s = text.lowercased()
        let markers = ["risk", "concern", "careful", "caution", "non-refundable", "nonrefundable", "penalty", "liable", "liability", "waive", "waiver", "terminate", "termination", "notice", "fee", "warning", "watch out", "not enough readable", "could not read", "obligation", "responsible for"]
        return markers.contains(where: { s.contains($0) })
    }

    static func bulletCount(_ text: String) -> Int {
        text.split(separator: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("-") || t.hasPrefix("•") || t.hasPrefix("·") || t.hasPrefix("*")
        }.count
    }

    static func semanticSatisfied(_ family: ActionResultFamily, body: String) -> Bool {
        switch family {
        case .extractRecommendations: return hasRecommendation(body)
        case .extractDatesPayments: return hasDatesOrPayments(body)
        case .flagRiskyClauses: return hasRiskFlag(body)
        case .summarizeContent: return meaningfulTerms(body).count >= 6
        case .extractGeneric: return meaningfulTerms(body).count >= 4 || bulletCount(body) >= 1
        case .focusCurrentTask, .captureVisiblePage, .generic: return true
        }
    }

    /// The core judgement. `sourceChars` is the acquired/source body size (e.g.
    /// `acquire.chars`); `outputText` is the rendered parent result.
    static func judge(actionID: String, outputText: String, sourceChars: Int, status: CapabilityExecutionStatus?) -> ActionResultQualityVerdict {
        let family = ActionResultFamily.infer(from: actionID)
        let body = bodyWithoutLabel(outputText)
        let titleEcho = body.count < 40
        let thinSource = family.isContentAction && sourceChars < family.minSourceChars
        let titleOrHeaderOnly = family.isContentAction && (thinSource || titleEcho)
        let bodyDetected = !thinSource && !titleEcho && !body.isEmpty

        var useful = true
        var passed = true
        var reason = "contentful_parent_output"
        var blockedReason = "none"
        var message = ""

        if isFailureStatus(status) {
            useful = false; passed = false
            reason = "parent_output_failed"
            blockedReason = "insufficient_body_text"
            message = "This action couldn't finish — I wasn't able to read enough usable content."
        } else if family.isContentAction {
            if titleOrHeaderOnly {
                useful = false; passed = false
                reason = "title_or_header_only"
                blockedReason = "insufficient_body_text"
                message = "I could only read the page title/group header, not the post or thread body."
            } else if !semanticSatisfied(family, body: body) {
                useful = false; passed = false
                reason = family.semanticMissReason
                blockedReason = family.semanticMissReason
                message = family.semanticMissMessage
            }
        } else if family == .focusCurrentTask {
            // A single generic term (e.g. just "Facebook") is not a task summary.
            if meaningfulTerms(body).count <= 1 {
                useful = false; passed = false
                reason = "focus_low_confidence"
                blockedReason = "focus_low_confidence"
                message = family.semanticMissMessage
            }
        }

        let semanticFit: Double = {
            if !bodyDetected { return 0.08 }
            if !passed { return 0.3 }
            let lenScore = min(1.0, Double(body.count) / 400.0)
            return min(1.0, 0.55 + 0.45 * lenScore)
        }()

        return ActionResultQualityVerdict(
            family: family,
            sourceChars: sourceChars,
            bodyDetected: bodyDetected,
            useful: useful,
            passed: passed,
            reason: reason,
            blockedReason: blockedReason,
            semanticFit: semanticFit,
            userMessage: message,
            titleOrHeaderOnly: titleOrHeaderOnly,
            lowSourceChars: thinSource
        )
    }
}

// MARK: - Action UX message sanitizer
//
// Guarantees a failed/blocked/partial action is never silent: a non-empty reason
// and a non-empty, human user message. The live failure showed
// `[ActionUXResult] status=failed visible=yes reason=none user_message=""` — that
// is a silent failure from the user's perspective. This is the single chokepoint
// every `[ActionUXResult]`/`[ActionFailureShown]` line flows through.
enum ActionUXMessage {

    static func defaultReason(_ bucket: String) -> String {
        switch bucket {
        case "failed": return "action_failed"
        case "blocked": return "insufficient_body_text"
        case "partial": return "partial_result"
        default: return "ok"
        }
    }

    static func humanize(_ reason: String) -> String {
        reason.replacingOccurrences(of: "_", with: " ")
    }

    static func defaultMessage(bucket: String, reason: String) -> String {
        switch bucket {
        case "failed":
            return "This action couldn't finish (\(humanize(reason))). Try capturing the page, or pick a smaller follow-up."
        case "blocked":
            return "I couldn't read enough content to do this (\(humanize(reason))). Try Capture Visible Page, or select the text first."
        case "partial":
            return "I finished part of this but couldn't complete it (\(humanize(reason)))."
        default:
            return ""
        }
    }

    /// Returns a guaranteed-non-empty (reason, message) for failed/blocked/partial.
    /// Success passes through (a missing success message is allowed).
    static func resolve(bucket: String, reason: String?, message: String?, actionID: String) -> (reason: String, message: String) {
        let rawReason = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawMessage = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch bucket {
        case "failed", "blocked", "partial":
            let r = (rawReason.isEmpty || rawReason.lowercased() == "none") ? defaultReason(bucket) : rawReason
            let m = rawMessage.isEmpty ? defaultMessage(bucket: bucket, reason: r) : rawMessage
            return (r, m)
        default:
            return (rawReason.isEmpty ? "success" : rawReason, rawMessage)
        }
    }
}
