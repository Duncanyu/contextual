import Foundation

// MARK: - Need

/// The intermediate layer between observed activity and generated opportunity.
/// Rather than mapping domain → capability directly, the engine infers what the
/// user likely *needs* from all available signals, then maps need → capabilities.
public enum Need: String, Sendable, Equatable, CaseIterable, Codable {
    case recall          // test/practice what was just studied
    case organization    // structure information into a useful form
    case explanation     // understand something in the context
    case debugging       // find and fix an error or performance issue
    case planning        // figure out what to do next
    case testing         // verify that something works correctly
    case comparison      // evaluate options against each other
    case synthesis       // combine multiple sources into unified notes
    case summarization   // condense material into a digest
    case drafting        // write or respond to something
    case architecture    // design the structure of a system/project
    case nextSteps       // safe general fallback when need is unclear
}

// MARK: - Opportunity

/// Phase 22 — A structured action opportunity produced by OpportunityEngine.
/// Every title must pass OpportunityValidator (action verb required).
public struct Opportunity: Sendable, Equatable, Codable {
    public let id: String
    public let title: String               // action-verb phrase, never observation
    public let capabilityId: String        // primary capability
    public let confidence: Double          // 0.0 – 1.0
    public let reason: String             // internal rationale string
    public let requiredEvidence: String   // "title_only" | "browser_tabs" | "ax_content" | "selection"
    public let actionability: Double      // 0.0 – 1.0: can execute now?
    public let inferredNeed: Need
    public let requiresConfirmation: Bool
    public let auxiliaryCapabilityIds: [String]
}

// MARK: - OpportunityValidator

/// Rejects proposal titles that merely describe activity rather than offering action.
public enum OpportunityValidator {

    private static let observationalPrefixes: [String] = [
        "looks like you're", "looks like you are",
        "you seem to be", "you are currently", "you're currently",
        "i noticed", "it looks like", "i see that", "i can see",
        "you appear to be", "it appears you", "it seems you"
    ]

    private static let requiredActionVerbs: Set<String> = [
        "create", "generate", "explain", "compare", "organize", "draft",
        "open", "play", "start", "summarize", "extract", "diagnose",
        "improve", "rewrite", "plan", "check", "find", "make", "build",
        "analyze", "review", "synthesize", "help", "show", "identify"
    ]

    /// Returns true if title is acceptable (action verb present, not observation-only).
    public static func validate(_ title: String) -> Bool {
        let lower = title.lowercased()

        if let prefix = observationalPrefixes.first(where: { lower.hasPrefix($0) }) {
            print("[OpportunityValidator] rejected reason=observation_only prefix=\"\(prefix)\"")
            return false
        }

        let tokens = lower
            .components(separatedBy: CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters))
            .filter { !$0.isEmpty }

        guard tokens.contains(where: { requiredActionVerbs.contains($0) }) else {
            print("[OpportunityValidator] rejected reason=no_action_verb title=\"\(title.prefix(60))\"")
            return false
        }

        print("[OpportunityValidator] accepted title=\"\(title.prefix(60))\"")
        return true
    }
}

// MARK: - OpportunityEngine

/// Phase 22 — Converts ambient signals into ranked action opportunities.
///
/// Pipeline:
///   signals → need inference → opportunity generation → validation → ranked list
///
/// Design constraints:
/// - Zero model calls. Fully deterministic.
/// - Need inference uses domain + mode + evidence signals — NOT direct domain→capability map.
/// - Title generation is entity-aware and action-verb-first.
/// - All titles must pass OpportunityValidator before being returned.
public enum OpportunityEngine {

    // MARK: - Public entry point

    /// Evaluates all available signals and returns a ranked list of opportunities.
    /// The first element is the highest-confidence actionable opportunity.
    public static func evaluate(
        determinerSignal: DeterminerSignal,
        activityState: ActivityState?,
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        evidenceQuality: String
    ) -> [Opportunity] {

        let domain = determinerSignal.inferredDomain
        let mode   = determinerSignal.inferredMode

        let entityLabel = memory.currentEntity.isEmpty
            ? (compartment?.label ?? "")
            : memory.currentEntity

        print("[OpportunityEngine] evaluated=yes domain=\(domain.rawValue) mode=\(mode.rawValue)")

        // Step 1 — Infer needs from signals (not direct mapping)
        let needs = inferNeeds(
            domain: domain,
            mode: mode,
            memory: memory,
            compartment: compartment,
            activityState: activityState,
            evidenceQuality: evidenceQuality
        )

        let needNames = needs.prefix(3).map { "\($0.0.rawValue):\(String(format: "%.2f", $0.1))" }.joined(separator: ",")
        print("[OpportunityEngine] inferred_needs=[\(needNames)]")

        // Step 2 — Generate opportunities from needs
        var candidates: [Opportunity] = []
        for (need, needConfidence) in needs {
            let opps = opportunitiesForNeed(
                need: need,
                needConfidence: needConfidence,
                domain: domain,
                mode: mode,
                entity: entityLabel,
                evidenceQuality: evidenceQuality,
                memory: memory
            )
            candidates.append(contentsOf: opps)
        }

        // Step 3 — Validate and de-duplicate (keep highest confidence per capId)
        var seen = Set<String>()
        var validated: [Opportunity] = []
        for opp in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            guard !seen.contains(opp.capabilityId) else { continue }
            guard OpportunityValidator.validate(opp.title) else { continue }
            seen.insert(opp.capabilityId)
            validated.append(opp)
        }

        // If nothing survived validation, produce a safe fallback
        if validated.isEmpty {
            let fallback = makeFallback(entity: entityLabel, evidenceQuality: evidenceQuality)
            validated = [fallback]
        }

        // Log top opportunity
        if let top = validated.first {
            print("[OpportunityEngine] top_opportunity capability=\(top.capabilityId) confidence=\(String(format: "%.2f", top.confidence))")
            print("[OpportunityEngine] top_title=\"\(top.title)\"")
        }

        return validated
    }

    // MARK: - Need inference

    /// Infers what the user likely needs from activity signals.
    /// This is NOT a direct domain→capability map. Domain sets context;
    /// concrete evidence signals (errors, multiple sources, comparison
    /// candidates, writing mode) refine the need.
    private static func inferNeeds(
        domain: DeterminerSignal.Domain,
        mode: DeterminerSignal.Mode,
        memory: WorkingMemorySnapshot,
        compartment: TaskCompartment?,
        activityState: ActivityState?,
        evidenceQuality: String
    ) -> [(Need, Double)] {

        var needs: [(Need, Double)] = []

        let concepts = Set(memory.repeatedConcepts.map { $0.lowercased() })

        // Evidence-driven signal: error terms always surface debugging need regardless of domain
        let errorTerms: Set<String> = ["error", "exception", "crash", "failed", "bug",
                                       "issue", "broken", "stack", "trace", "warning", "undefined"]
        let hasErrors = !concepts.intersection(errorTerms).isEmpty
        if hasErrors {
            needs.append((.debugging, 0.90))
        }

        // Evidence-driven: multiple comparison candidates → comparison need
        let hasComparisons = memory.comparisonCandidates.count >= 2
        if hasComparisons {
            needs.append((.comparison, 0.88))
        }

        // Evidence-driven: multiple sources open → synthesis need
        let hasMultipleSources = memory.relatedFocusEntities.count >= 2
            || evidenceQuality == "browser_tabs"
        if hasMultipleSources && !hasComparisons {
            needs.append((.synthesis, 0.82))
        }

        // Evidence-driven: writing mode → drafting need
        if mode == .writing || mode == .communicating {
            needs.append((.drafting, 0.85))
        }

        // Domain sets the remaining contextual needs (secondary to evidence signals above)
        switch domain {
        case .studying:
            switch mode {
            case .reading, .learning, .browsing, .unknown:
                needs.append((.recall, 0.85))
                needs.append((.organization, 0.70))
                needs.append((.explanation, 0.55))
            case .writing:
                needs.append((.organization, 0.80))
            default:
                needs.append((.recall, 0.75))
                needs.append((.organization, 0.60))
            }

        case .coding:
            if !hasErrors {   // debugging already added above if errors present
                if mode == .building {
                    needs.append((.testing, 0.80))
                    needs.append((.architecture, 0.65))
                    needs.append((.planning, 0.60))
                } else if mode == .debugging {
                    needs.append((.debugging, 0.85))
                    needs.append((.planning, 0.55))
                } else {
                    needs.append((.planning, 0.75))
                    needs.append((.testing, 0.60))
                }
            }

        case .creative_coding:
            if !hasErrors {
                // Game/project building primarily needs testing and planning
                needs.append((.testing, 0.88))
                needs.append((.planning, 0.65))
                needs.append((.architecture, 0.50))
            }

        case .shopping:
            if !hasComparisons {
                needs.append((.comparison, 0.85))
            }
            needs.append((.summarization, 0.65))

        case .researching:
            if !hasMultipleSources {
                needs.append((.synthesis, 0.80))
            }
            needs.append((.summarization, 0.72))
            needs.append((.organization, 0.55))

        case .communicating:
            if mode != .writing && mode != .communicating {  // not already added
                needs.append((.drafting, 0.82))
            }
            needs.append((.organization, 0.60))

        case .gaming:
            // Passive gaming: planning/next steps; not much cognitive need
            needs.append((.nextSteps, 0.55))

        case .unknown, .browsing, .working:
            let isActive = activityState?.isActive == true
            needs.append((.nextSteps, isActive ? 0.65 : 0.40))
            if isActive { needs.append((.planning, 0.50)) }

        case .watching:
            // Minimal interruption; don't suggest much
            break
        }

        return needs.sorted { $0.1 > $1.1 }
    }

    // MARK: - Opportunity generation per need

    private static func opportunitiesForNeed(
        need: Need,
        needConfidence: Double,
        domain: DeterminerSignal.Domain,
        mode: DeterminerSignal.Mode,
        entity: String,
        evidenceQuality: String,
        memory: WorkingMemorySnapshot
    ) -> [Opportunity] {

        switch need {

        case .recall:
            return [
                make(capId: "generate_quiz",
                     need: .recall, entity: entity,
                     confidence: needConfidence * 0.92,
                     evidence: "ax_content",
                     actionability: evidenceQuality == "ax_content" ? 0.9 : 0.6,
                     aux: ["create_review_plan"]),
                make(capId: "create_review_plan",
                     need: .recall, entity: entity,
                     confidence: needConfidence * 0.80,
                     evidence: "title_only",
                     actionability: 0.85,
                     aux: ["generate_quiz"])
            ]

        case .organization:
            return [
                make(capId: "create_study_outline",
                     need: .organization, entity: entity,
                     confidence: needConfidence * 0.85,
                     evidence: "title_only",
                     actionability: 0.85,
                     aux: ["create_checklist"]),
                make(capId: "create_checklist",
                     need: .organization, entity: entity,
                     confidence: needConfidence * 0.72,
                     evidence: "title_only",
                     actionability: 0.85)
            ]

        case .debugging:
            return [
                make(capId: "diagnose_error",
                     need: .debugging, entity: entity,
                     confidence: needConfidence * 0.92,
                     evidence: "title_only",
                     actionability: 0.90,
                     aux: ["debug_performance"]),
                make(capId: "debug_performance",
                     need: .debugging, entity: entity,
                     confidence: needConfidence * 0.78,
                     evidence: "title_only",
                     actionability: 0.80)
            ]

        case .testing:
            if domain == .creative_coding {
                return [
                    make(capId: "generate_test_checklist",
                         need: .testing, entity: entity,
                         confidence: needConfidence * 0.92,
                         evidence: "title_only",
                         actionability: 0.90,
                         aux: ["create_game_design_checklist", "explain_how_to_make_faster"]),
                    make(capId: "create_game_design_checklist",
                         need: .testing, entity: entity,
                         confidence: needConfidence * 0.80,
                         evidence: "title_only",
                         actionability: 0.88)
                ]
            } else {
                return [
                    make(capId: "create_checklist",
                         need: .testing, entity: entity,
                         confidence: needConfidence * 0.85,
                         evidence: "title_only",
                         actionability: 0.85)
                ]
            }

        case .planning:
            return [
                make(capId: "create_next_steps",
                     need: .planning, entity: entity,
                     confidence: needConfidence * 0.85,
                     evidence: "title_only",
                     actionability: 0.85)
            ]

        case .comparison:
            return [
                make(capId: "compare_options",
                     need: .comparison, entity: entity,
                     confidence: needConfidence * 0.92,
                     evidence: "browser_tabs",
                     actionability: evidenceQuality == "browser_tabs" ? 0.90 : 0.65,
                     aux: ["decision_matrix"]),
                make(capId: "decision_matrix",
                     need: .comparison, entity: entity,
                     confidence: needConfidence * 0.78,
                     evidence: "browser_tabs",
                     actionability: 0.75)
            ]

        case .synthesis:
            return [
                make(capId: "synthesize_sources",
                     need: .synthesis, entity: entity,
                     confidence: needConfidence * 0.90,
                     evidence: "browser_tabs",
                     actionability: evidenceQuality == "browser_tabs" ? 0.88 : 0.60,
                     aux: ["create_next_steps"]),
                make(capId: "summarize_reference",
                     need: .synthesis, entity: entity,
                     confidence: needConfidence * 0.74,
                     evidence: "title_only",
                     actionability: 0.80)
            ]

        case .summarization:
            return [
                make(capId: "summarize_context",
                     need: .summarization, entity: entity,
                     confidence: needConfidence * 0.85,
                     evidence: "title_only",
                     actionability: 0.85)
            ]

        case .drafting:
            return [
                make(capId: "draft_reply",
                     need: .drafting, entity: entity,
                     confidence: needConfidence * 0.88,
                     evidence: "title_only",
                     actionability: 0.70,   // confirmation required
                     requiresConfirmation: true,
                     aux: ["extract_action_items"]),
                make(capId: "extract_action_items",
                     need: .drafting, entity: entity,
                     confidence: needConfidence * 0.72,
                     evidence: "title_only",
                     actionability: 0.80)
            ]

        case .architecture:
            return [
                make(capId: "create_next_steps",
                     need: .architecture, entity: entity,
                     confidence: needConfidence * 0.75,
                     evidence: "title_only",
                     actionability: 0.80)
            ]

        case .explanation:
            return [
                make(capId: "explain_context",
                     need: .explanation, entity: entity,
                     confidence: needConfidence * 0.82,
                     evidence: "title_only",
                     actionability: 0.85)
            ]

        case .nextSteps:
            return [
                make(capId: "create_next_steps",
                     need: .nextSteps, entity: entity,
                     confidence: needConfidence * 0.82,
                     evidence: "title_only",
                     actionability: 0.85)
            ]
        }
    }

    // MARK: - Title builder (action-verb first, entity-aware)

    /// Produces an action-verb-first title for the given capability.
    /// All titles here are pre-validated to contain action verbs.
    static func title(forCapabilityId capId: String, entity: String) -> String {
        let short = String(entity.prefix(38)).trimmingCharacters(in: .whitespaces)
        let e = short.isEmpty ? nil : short

        switch capId {
        case "generate_quiz":
            return e.map { "Generate practice questions from these \($0) notes" }
                   ?? "Generate practice questions from these notes"
        case "create_review_plan":
            return e.map { "Create a review plan for \($0)" }
                   ?? "Create a review plan for this material"
        case "create_study_outline":
            return e.map { "Create a study outline for \($0)" }
                   ?? "Create a study outline for this material"
        case "generate_test_checklist":
            return e.map { "Create a testing checklist for \($0)" }
                   ?? "Create a testing checklist for this project"
        case "create_game_design_checklist":
            return e.map { "Create a game design checklist for \($0)" }
                   ?? "Create a game design checklist"
        case "diagnose_error":
            return "Diagnose the current error"
        case "debug_performance":
            return e.map { "Find performance issues in \($0)" }
                   ?? "Find performance issues in this project"
        case "improve_project":
            return e.map { "Improve \($0)" }
                   ?? "Improve this project"
        case "explain_how_to_make_faster":
            return "Explain how to make this faster"
        case "compare_options":
            return "Compare the options you're viewing"
        case "decision_matrix":
            return "Build a decision matrix for this comparison"
        case "synthesize_sources":
            return "Synthesize the sources you've opened into notes"
        case "summarize_reference":
            return e.map { "Summarize \($0)" }
                   ?? "Summarize this reference"
        case "summarize_context":
            return "Summarize the current context"
        case "draft_reply":
            return "Draft a reply to this message"
        case "extract_action_items":
            return "Extract action items from this thread"
        case "create_checklist":
            return e.map { "Create a checklist for \($0)" }
                   ?? "Create a checklist for this session"
        case "create_next_steps":
            return e.map { "Create next steps for \($0)" }
                   ?? "Create next steps for the current task"
        case "explain_context":
            return "Explain the key concepts here"
        default:
            return "Help with the current task"
        }
    }

    // MARK: - Helpers

    private static func make(
        capId: String,
        need: Need,
        entity: String,
        confidence: Double,
        evidence: String,
        actionability: Double = 0.80,
        requiresConfirmation: Bool = false,
        aux: [String] = []
    ) -> Opportunity {
        Opportunity(
            id: "opp:\(need.rawValue):\(capId):\(UUID().uuidString.prefix(6))",
            title: title(forCapabilityId: capId, entity: entity),
            capabilityId: capId,
            confidence: min(0.95, confidence),
            reason: need.rawValue,
            requiredEvidence: evidence,
            actionability: actionability,
            inferredNeed: need,
            requiresConfirmation: requiresConfirmation,
            auxiliaryCapabilityIds: aux
        )
    }

    private static func makeFallback(entity: String, evidenceQuality: String) -> Opportunity {
        Opportunity(
            id: "opp:nextSteps:create_next_steps:fallback",
            title: title(forCapabilityId: "create_next_steps", entity: entity),
            capabilityId: "create_next_steps",
            confidence: 0.40,
            reason: "safe_fallback",
            requiredEvidence: "title_only",
            actionability: 0.80,
            inferredNeed: .nextSteps,
            requiresConfirmation: false,
            auxiliaryCapabilityIds: []
        )
    }
}
