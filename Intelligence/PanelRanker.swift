import Foundation

// MARK: - Phase 51 (Rescue Sprint): Panel Ranking
//
// The panel must feel like it knows what the user is doing — not like a junk
// drawer of utilities. This ranker is a pure function over the published
// actions so it is deterministic and self-testable.
//
// Sections (top to bottom):
//   suggested_now    — the single best action for the current moment
//   understand_this  — cognitive actions over real content (summarize, extract…)
//   act_on_this      — friction/local actions that change the environment
//   workspace        — restore/remember workspace family
//   utilities        — copy URL, collect references… always demoted to bottom
//
// Suppression rules:
//   duplicate          — same capability appearing twice
//   insufficient_scope — cognitive action with no readable content available
//   utility_demoted    — utility competing for a top slot

enum PanelSection: String, Sendable, CaseIterable {
    case suggestedNow  = "suggested_now"
    case understand    = "understand_this"
    case act           = "act_on_this"
    case capture       = "capture_enable_context"
    case workspace     = "workspace"
    case utilities     = "utilities"
}

struct PanelRankingInput: Sendable {
    let actionID: String
    let capabilityId: String
    let title: String
    let isHighlighted: Bool
}

struct PanelRankingDecision: Sendable {
    let actionID: String
    let capabilityId: String
    let section: PanelSection
    let rank: Int
    let suppressed: Bool
    let suppressionReason: String?
    let reason: String
}

enum PanelRanker {

    /// SwiftUI re-evaluates the panel body frequently; only log when the
    /// decision set actually changes.
    private static let logLock = NSLock()
    private static var lastLogSignature: String = ""

    static let cognitiveCapabilityIds: Set<String> = [
        "explicit_visible_capture_summary", "extract_action_items", "create_checklist",
        "summarize_visible_content", "summarize_full_page", "summarize_full_document",
        "summarize_article", "summarize_selected_text",
        "rewrite_text", "improve_text", "draft_reply", "explain_context", "diagnose_error"
    ]

    /// Generic cognitive ids that must never crowd the panel (Part I cap).
    static let genericCognitiveIds: Set<String> = [
        "explicit_visible_capture_summary", "extract_action_items", "create_checklist",
        "summarize_visible_content", "rewrite_text", "improve_text", "explain_context", "draft_reply"
    ]

    private static let accessCommandIds: Set<String> = ["enable_page_access", "capture_then_summarize"]

    /// Rank panel actions into sections.
    /// - Parameters:
    ///   - actions: published actions in pipeline order
    ///   - contentAvailable: whether real readable content exists for cognitive
    ///     actions (nil = unknown → do not suppress, the executor gates honestly)
    static func rank(
        actions: [PanelRankingInput],
        contentAvailable: Bool?,
        largeSelection: Bool = false
    ) -> [PanelRankingDecision] {
        var decisions: [PanelRankingDecision] = []
        var logLines: [String] = []
        var seenCapabilities = Set<String>()
        var rankBySection: [PanelSection: Int] = [:]
        // Phase 53 — caps: ≤3 suggested-now (≤1 generic there); generic cognitive
        // actions capped panel-wide unless the user selected a large body of text.
        let maxSuggestedNow = 3
        let maxGenericVisible = largeSelection ? 3 : 1
        var genericVisible = 0

        for action in actions {
            let cap = action.capabilityId

            // Rule: no duplicate capabilities.
            if !seenCapabilities.insert(cap).inserted {
                let d = PanelRankingDecision(
                    actionID: action.actionID, capabilityId: cap,
                    section: .utilities, rank: -1,
                    suppressed: true, suppressionReason: "duplicate",
                    reason: "duplicate_capability"
                )
                logLines.append("[PanelSuppression] capability=\(cap) reason=duplicate")
                decisions.append(d)
                continue
            }

            let baseSection = section(for: cap)

            // Rule: cognitive actions with provably no content are suppressed —
            // the honest top action in that state is capture/enable access, which
            // arrives as its own action.
            if baseSection == .understand, contentAvailable == false,
               !isAccessAction(cap),
               !isSpecificLiquidCaptureNeededAction(cap) {
                let d = PanelRankingDecision(
                    actionID: action.actionID, capabilityId: cap,
                    section: .understand, rank: -1,
                    suppressed: true, suppressionReason: "insufficient_scope",
                    reason: "no_readable_content"
                )
                logLines.append("[PanelSuppression] capability=\(cap) reason=insufficient_scope")
                decisions.append(d)
                continue
            }

            // Phase 53 — panel-wide generic cognitive cap.
            let isGeneric = genericCognitiveIds.contains(cap)
            if isGeneric {
                if genericVisible >= maxGenericVisible {
                    let d = PanelRankingDecision(
                        actionID: action.actionID, capabilityId: cap,
                        section: baseSection, rank: -1,
                        suppressed: true, suppressionReason: "generic_cap",
                        reason: "generic_cognitive_capped"
                    )
                    logLines.append("[PanelSuppression] capability=\(cap) reason=generic_cap")
                    decisions.append(d)
                    continue
                }
                genericVisible += 1
            }

            // Highlighted action gets the suggested-now slot — but never a utility,
            // never a fourth suggestion, and at most one generic.
            let suggestedCount = rankBySection[.suggestedNow, default: 0]
            let genericInSuggested = decisions.contains {
                $0.section == .suggestedNow && !$0.suppressed && genericCognitiveIds.contains($0.capabilityId)
            }
            let section: PanelSection
            let reason: String
            if action.isHighlighted && baseSection != .utilities
                && suggestedCount < maxSuggestedNow
                && !(isGeneric && genericInSuggested) {
                section = .suggestedNow
                reason = "highlighted_best_match"
                logLines.append("[SuggestedNow] capability=\(cap) reason=highlighted_best_match")
            } else if action.isHighlighted && baseSection == .utilities {
                section = .utilities
                reason = "utility_never_suggested_now"
                logLines.append("[PanelSuppression] capability=\(cap) reason=utility_demoted")
            } else {
                section = baseSection
                reason = "section_match"
            }

            let rank = rankBySection[section, default: 0]
            rankBySection[section] = rank + 1
            let d = PanelRankingDecision(
                actionID: action.actionID, capabilityId: cap,
                section: section, rank: rank,
                suppressed: false, suppressionReason: nil,
                reason: reason
            )
            logLines.append("[PanelRanking] capability=\(cap) section=\(section.rawValue) rank=\(rank) reason=\(reason)")
            decisions.append(d)
        }

        // Phase 53 — section + diversity logs.
        for section in PanelSection.allCases {
            let ids = decisions.filter { $0.section == section && !$0.suppressed }.map(\.capabilityId)
            if !ids.isEmpty {
                logLines.append("[PanelSection] section=\(section.rawValue) actions=\(ids.joined(separator: ","))")
            }
        }
        logLines.append("[PanelGenericCap] generic_count=\(genericVisible) allowed=\(maxGenericVisible)")
        let visible = decisions.filter { !$0.suppressed }
        let specificVisible = visible.filter {
            WorkflowActionOntology.byId[$0.capabilityId]?.isSpecificAction == true
        }.count
        let genericTrioVisible = visible.filter {
            ["explicit_visible_capture_summary", "extract_action_items", "create_checklist"].contains($0.capabilityId)
        }.count
        let diversityPassed = genericTrioVisible < 3 && genericVisible <= maxGenericVisible
        logLines.append("[PanelDiversityCheck] passed=\(diversityPassed ? "yes" : "no") reason=\(diversityPassed ? "generic_capped_specific_present" : "generic_trio_dominates") specific=\(specificVisible) generic=\(genericVisible)")

        // SwiftUI calls this on every panel re-render — only log when the
        // decision set actually changed.
        let signature = logLines.joined(separator: "|")
        logLock.lock()
        let changed = signature != lastLogSignature
        if changed { lastLogSignature = signature }
        logLock.unlock()
        if changed {
            for line in logLines { print(line) }
        }

        return decisions
    }

    static func section(for capabilityId: String) -> PanelSection {
        let traits = CapabilityPolicyResolver.resolve(capabilityID: capabilityId)
        if traits.contains(.internalAcquisitionAction) || accessCommandIds.contains(capabilityId) { return .capture }
        // Phase 53 — ontology actions map by category and result type:
        // insights → "Understand this workflow"; drafts/notes/system actions →
        // "Act on this workflow"; setup → capture; workspace aliases → workspace.
        if let liquid = WorkflowActionOntology.byId[capabilityId] {
            switch liquid.executionKind {
            case .setupCard:
                return .capture
            case .workspaceAlias:
                return liquid.category == .workspaceFriction || liquid.category == .memoryWorkflows ? .workspace : .act
            case .memoryNote:
                return .act
            case .metadataNote:
                return liquid.resultType == "note_card" ? .act : .understand
            case .contentInsight:
                return liquid.resultType == "draft_card" ? .act : .understand
            case .selectionTransform:
                return .act
            }
        }
        if cognitiveCapabilityIds.contains(capabilityId) { return .understand }
        if traits.contains(.metadataUtility) || traits.contains(.unverifiedBrowserMutator) { return .utilities }
        if traits.contains(.workspaceArrangement) { return .workspace }
        if traits.contains(.mediaOrFocusSupport) || traits.contains(.sourceIndependentAction) { return .act }
        // Unknown capabilities go to "act on this" — they are environment actions
        // by default, never top suggestions.
        return .act
    }

    /// Capture/access actions stay visible even when content is unavailable —
    /// they are the honest path to getting content.
    private static func isAccessAction(_ capabilityId: String) -> Bool {
        let traits = CapabilityPolicyResolver.resolve(capabilityID: capabilityId)
        return isSpecificLiquidCaptureNeededAction(capabilityId)
            || traits.contains(.internalAcquisitionAction)
            || accessCommandIds.contains(capabilityId)
    }

    private static func isSpecificLiquidCaptureNeededAction(_ capabilityId: String) -> Bool {
        guard let action = WorkflowActionOntology.byId[capabilityId] else { return false }
        return action.isSpecificAction && action.executionKind == .contentInsight
    }

    /// Section display titles for the panel UI.
    static func displayTitle(for section: PanelSection) -> String {
        switch section {
        case .suggestedNow: return "Suggested now"
        case .understand:   return "Understand this workflow"
        case .act:          return "Act on this workflow"
        case .capture:      return "Capture / enable context"
        case .workspace:    return "Workspace"
        case .utilities:    return "Utilities"
        }
    }
}
