import Foundation

/// Phase 22.2 — Canonical signal priority resolver (Task E).
///
/// Resolves the contradiction that arises when multiple context signals disagree:
///   - Workflow model says "shopping" (from temporal buffer)
///   - DeterminerSignal says "creative_coding" (from current focus)
///   - EntityGrounding says "code_project" (from URL or app category)
///
/// Priority order (highest to lowest confidence):
///   1. EntityGrounding  — what the user is actually looking at right now
///   2. DeterminerSignal — focused signal from current vocabulary + compartment
///   3. TaskCompartment  — established context trust from dwell
///   4. Workflow model   — temporal aggregate, weakest for real-time decisions
///
/// Required logs: [SemanticPriority], [SemanticState]
enum SemanticPriorityResolver {

    // MARK: - Types

    enum Winner: String {
        case entityGrounding = "entity_grounding"
        case determinerSignal = "determiner"
        case compartment      = "compartment"
        case workflow         = "workflow"
    }

    struct SemanticState {
        let domain: DeterminerSignal.Domain
        let mode: DeterminerSignal.Mode
        let entityType: EntityGrounding.EntityType
        let entityConfidence: Double
        let winner: Winner
    }

    // MARK: - Entry point

    /// Resolve the authoritative semantic state from all available signals.
    ///
    /// - Parameters:
    ///   - grounding: Result from EntityGroundingLayer (may be nil).
    ///   - determinerSignal: Output of DeterminerSignal.evaluate().
    ///   - compartment: Currently active TaskCompartment.
    ///   - workflowTypeRaw: Raw value of the workflow model's current type (for conflict logging).
    ///   - semanticGrounding: Result from SemanticGroundingEngine (highest authority).
    static func resolve(
        grounding: EntityGrounding?,
        determinerSignal: DeterminerSignal,
        compartment: TaskCompartment?,
        workflowTypeRaw: String = "unknown",
        semanticGrounding: SemanticGroundingResult? = nil
    ) -> SemanticState {

        // ── Priority 0: SemanticGroundingResult — new grounded engine ────────
        if let sg = semanticGrounding, sg.confidence >= 0.70 {
            let entityType = entityTypeFromKind(sg.entityKind)
            let domain = domainFromGroundedDomain(sg.domain, fallback: determinerSignal.inferredDomain)
            
            let result = SemanticState(
                domain: domain,
                mode: determinerSignal.inferredMode,
                entityType: entityType,
                entityConfidence: sg.confidence,
                winner: .entityGrounding // We can use .entityGrounding or add a new one, but for now reuse
            )
            print("[SemanticPriority] winner=semantic_grounding domain=\(domain.rawValue) kind=\(sg.entityKind)")
            return result
        }

        // ── Priority 1: EntityGrounding — hard physical evidence ─────────────
        // URL-sourced grounding above 0.5 confidence always wins; title-only
        // grounding needs at least 0.72 to beat the determiner.
        if let g = grounding {
            let threshold: Double = (g.source == .url || g.source == .app_metadata) ? 0.50 : 0.72
            if g.confidence >= threshold && g.entityType != .unknown {
                let domain = domainFromEntityType(
                    g.entityType,
                    fallbackDomain: determinerSignal.inferredDomain
                )
                let result = SemanticState(
                    domain: domain,
                    mode: determinerSignal.inferredMode,
                    entityType: g.entityType,
                    entityConfidence: g.confidence,
                    winner: .entityGrounding
                )
                logResult(result, grounding: g, workflowTypeRaw: workflowTypeRaw)
                return result
            }
        }

        // ── Priority 2: DeterminerSignal — focused current-vocabulary signal ─
        if determinerSignal.confidence >= 0.50 && determinerSignal.inferredDomain != .unknown {
            let entityType = entityTypeFromDomain(determinerSignal.inferredDomain)
            let result = SemanticState(
                domain: determinerSignal.inferredDomain,
                mode: determinerSignal.inferredMode,
                entityType: entityType,
                entityConfidence: 0.0,
                winner: .determinerSignal
            )
            logResult(result, grounding: grounding, workflowTypeRaw: workflowTypeRaw)
            return result
        }

        // ── Priority 3: TaskCompartment — established dwell trust ─────────────
        if let comp = compartment, comp.compartmentTrust >= 0.40 {
            let domain = domainFromWorkflow(comp.workflow)
            let entityType = entityTypeFromDomain(domain)
            let result = SemanticState(
                domain: domain,
                mode: determinerSignal.inferredMode,
                entityType: entityType,
                entityConfidence: 0.0,
                winner: .compartment
            )
            logResult(result, grounding: grounding, workflowTypeRaw: workflowTypeRaw)
            return result
        }

        // ── Priority 4: Workflow fallback ─────────────────────────────────────
        let result = SemanticState(
            domain: determinerSignal.inferredDomain,
            mode: determinerSignal.inferredMode,
            entityType: .unknown,
            entityConfidence: 0.0,
            winner: .workflow
        )
        logResult(result, grounding: grounding, workflowTypeRaw: workflowTypeRaw)
        return result
    }

    /// Map SemanticGroundingResult.entityKind to EntityGrounding.EntityType
    private static func entityTypeFromKind(_ kind: String) -> EntityGrounding.EntityType {
        let k = kind.lowercased()
        switch k {
        case "youtube_video", "video": return .youtube_video
        case "tv_show", "streaming_site": return .tv_show
        case "music_app": return .music_app
        case "game", "competitive_game": return .game
        case "source_code_file", "code_editor", "creative_coding_project": return .code_project
        case "document", "spreadsheet", "slide_deck": return .document
        case "course_material": return .course_material
        case "ai_assistant": return .document // No AI assistant type in EntityType yet, use document for now
        case "product": return .product
        case "search_query", "website": return .website
        default: return .unknown
        }
    }

    private static func domainFromGroundedDomain(_ domain: String, fallback: DeterminerSignal.Domain) -> DeterminerSignal.Domain {
        let d = domain.lowercased()
        switch d {
        case "coding": return .coding
        case "creative_coding": return .creative_coding
        case "gaming": return .gaming
        case "watching", "media": return .watching
        case "studying": return .studying
        case "researching": return .researching
        case "working", "designing", "productivity": return .working
        case "shopping": return .shopping
        case "communicating": return .communicating
        case "browsing": return .browsing
        default:
            if let gd = DeterminerSignal.Domain(rawValue: d) {
                return gd
            }
            return fallback
        }
    }

    // MARK: - Domain derivation helpers

    /// Map EntityType to the most appropriate DeterminerSignal.Domain.
    /// Prefers the fallback domain when it carries more specific information
    /// (e.g. .creative_coding vs .coding for a code_project entity).
    static func domainFromEntityType(
        _ type: EntityGrounding.EntityType,
        fallbackDomain: DeterminerSignal.Domain
    ) -> DeterminerSignal.Domain {
        switch type {
        case .tv_show, .youtube_video, .streaming_site:
            return .watching
        case .music_app:
            return .watching // Or .media if available, but .watching is the entertainment domain
        case .code_project:
            // Preserve creative_coding distinction when the determiner already has it
            return fallbackDomain == .creative_coding ? .creative_coding : .coding
        case .course_material:
            return .studying
        case .email_thread:
            return .communicating
        case .product:
            return .shopping
        case .document:
            return fallbackDomain == .researching ? .researching : .browsing
        case .game:
            return .gaming
        case .website:
            // Generic website — let the determiner or workflow decide
            return fallbackDomain == .unknown ? .browsing : fallbackDomain
        case .unknown:
            return fallbackDomain
        default:
            return fallbackDomain
        }
    }

    /// Rough reverse-map: domain → most likely entity type.
    /// Used when no grounding is available.
    static func entityTypeFromDomain(_ domain: DeterminerSignal.Domain) -> EntityGrounding.EntityType {
        switch domain {
        case .watching:      return .youtube_video
        case .studying:      return .course_material
        case .coding, .creative_coding: return .code_project
        case .communicating: return .email_thread
        case .shopping:      return .product
        case .researching:   return .document
        case .gaming:        return .game
        case .browsing, .working, .unknown: return .unknown
        }
    }

    /// Map AmbientWorkflowType to a DeterminerSignal.Domain (for compartment fallback).
    private static func domainFromWorkflow(_ workflow: AmbientWorkflowType) -> DeterminerSignal.Domain {
        switch workflow {
        case .studying:    return .studying
        case .coding:      return .coding
        case .debugging:   return .coding
        case .writing:     return .working
        case .reading:     return .browsing
        case .watching:    return .watching
        case .emailing:    return .communicating
        case .shopping:    return .shopping
        case .comparing:   return .shopping
        case .researching: return .researching
        case .browsing:    return .browsing
        case .gaming:      return .gaming
        case .meeting:     return .communicating
        default:           return .unknown
        }
    }

    // MARK: - Required logging

    private static func logResult(
        _ state: SemanticState,
        grounding: EntityGrounding?,
        workflowTypeRaw: String
    ) {
        print("[SemanticPriority] winner=\(state.winner.rawValue)"
            + " domain=\(state.domain.rawValue)"
            + " entity_type=\(state.entityType.rawValue)")

        // Log workflow conflicts when grounding or determiner overrides it
        if state.winner == .entityGrounding || state.winner == .determinerSignal {
            if workflowTypeRaw != "unknown" && workflowTypeRaw != state.domain.rawValue {
                print("[SemanticPriority] ignored_workflow=\(workflowTypeRaw)"
                    + " reason=current_grounding_conflict"
                    + " winning_signal=\(state.winner.rawValue)")
            }
        }

        print("[SemanticState] domain=\(state.domain.rawValue)"
            + " mode=\(state.mode.rawValue)"
            + " entity_type=\(state.entityType.rawValue)"
            + " entity_confidence=\(String(format: "%.2f", state.entityConfidence))")
    }
}
