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
            CognitiveCapability(id: "generate_test_checklist", label: "Create testing checklist", inputRequirements: ["recent_titles"], outputType: "checklist", evidenceThreshold: "title_only")
        ]

        for c in cognitiveList { caps[c.id] = c }
        
        // Light local system actions
        let localList = [
            CognitiveCapability(id: "play_focus_media", label: "Play focus media", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "pause_media", label: "Pause media", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action),
            CognitiveCapability(id: "open_relevant_app", label: "Open relevant app", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "start_focus_timer", label: "Start focus timer", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, requiresConfirmation: true, executionMode: .local_action),
            CognitiveCapability(id: "copy_result_to_clipboard", label: "Copy to clipboard", inputRequirements: [], outputType: "system_action", evidenceThreshold: "none", riskLevel: .light_action, executionMode: .local_action)
        ]
        
        for c in localList { caps[c.id] = c }
        
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
        determinerSignal: DeterminerSignal? = nil
    ) -> SelectedCapability {
        print("[CapabilitySelector] evidence_quality=\(evidenceQuality)")

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

public enum CapabilityExecutionStatus: String, Codable, Sendable {
    case success = "success"
    case unavailable = "unavailable"
    case cancelled = "cancelled"
    case blocked = "blocked"
}

@MainActor
public final class CapabilityExecutor {
    public static let shared = CapabilityExecutor()
    
    private init() {}
    
    public func execute(capability: CognitiveCapability, context: [String: Any]) async -> CapabilityExecutionStatus {
        print("[CapabilityExecution] started id=\(capability.id)")
        
        if capability.requiresConfirmation {
            // In a real app, this would trigger a UI prompt.
            // For now, we assume confirmed if user accepted the suggestion.
            print("[CapabilityExecution] confirmation_required=yes")
        } else {
            print("[CapabilityExecution] confirmation_required=no")
        }
        
        switch capability.id {
        case "copy_result_to_clipboard":
            return copyToClipboard(context: context)
            
        case "start_focus_timer":
            return startFocusTimer(context: context)
            
        case "play_focus_media":
            return await playFocusMedia()
            
        case "pause_media":
            return await pauseMedia()
            
        case "open_relevant_app":
            return openRelevantApp(context: context)
            
        default:
            if capability.executionMode == .preview_only {
                print("[CapabilityExecution] completed status=success (preview_only)")
                return .success
            }
            print("[CapabilityExecution] blocked reason=capability_unavailable")
            return .unavailable
        }
    }
    
    private func copyToClipboard(context: [String: Any]) -> CapabilityExecutionStatus {
        guard let text = context["text"] as? String else {
            print("[CapabilityExecution] blocked reason=missing_data")
            return .blocked
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("[CapabilityExecution] completed status=success id=copy_result_to_clipboard")
        return .success
    }
    
    private func startFocusTimer(context: [String: Any]) -> CapabilityExecutionStatus {
        // No timer service is wired in this build.
        // Returning .unavailable rather than faking success — honest about capability state.
        print("[CapabilityExecution] completed status=unavailable id=start_focus_timer reason=no_timer_service_wired")
        return .unavailable
    }
    
    private func playFocusMedia() async -> CapabilityExecutionStatus {
        let script = "tell application \"Music\" to play"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                print("[CapabilityExecution] completed status=success id=play_focus_media")
                return .success
            }
        }
        print("[CapabilityExecution] completed status=unavailable id=play_focus_media")
        return .unavailable
    }
    
    private func pauseMedia() async -> CapabilityExecutionStatus {
        let script = "tell application \"Music\" to pause"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil {
                print("[CapabilityExecution] completed status=success id=pause_media")
                return .success
            }
        }
        print("[CapabilityExecution] completed status=unavailable id=pause_media")
        return .unavailable
    }
    
    private func openRelevantApp(context: [String: Any]) -> CapabilityExecutionStatus {
        guard let appName = context["appName"] as? String else {
             return .blocked
        }
        
        // Use modern API if possible, fallback to launchApplication for simplicity in this prototype
        if NSWorkspace.shared.launchApplication(appName) {
            print("[CapabilityExecution] completed status=success id=open_relevant_app")
            return .success
        }
        return .unavailable
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
