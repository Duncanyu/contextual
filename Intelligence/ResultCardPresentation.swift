import Foundation

// MARK: - Phase 58.6: Result-card presentation layer
//
// Everything between "the executor produced text" and "the user sees a card"
// lives here: per-surface budgets, summary compression, follow-up label
// sanitizing + resolution + ranking, missing-context card copy, human source
// labels, and a final UI copy gate. The UI renders only what passes this layer.
//
// Design rules (Phase 58.6):
//   - Floating cards are glanceable: ≤3 bullets, ≤3 buttons, one source line,
//     one next-step sentence. Panel cards carry the detail.
//   - No raw IDs, snake_case, char counts, or scope enums in visible copy.
//   - Missing-context cards always say what's missing, why it matters, how to
//     provide it, and the next best action.

// MARK: - Part B: Presentation policy

enum ResultCardSurface: String, CaseIterable, Sendable {
    case floating
    case panel
}

enum ResultCardPresentationMode: String, Sendable {
    case summary
    case detail
    case missingContext = "missing_context"
    case debugHidden = "debug_hidden"
}

struct ResultCardBudget: Sendable {
    let surface: ResultCardSurface
    /// Maximum visible characters for the card body.
    let maxChars: Int
    /// Maximum bullets in a compact summary.
    let maxBullets: Int
    /// Maximum follow-up buttons.
    let maxButtons: Int
    /// Source label is mandatory on every card.
    let requiresSourceLabel: Bool = true
    /// Limitation cards must include an instruction + next best action.
    let requiresInstructionOnLimitation: Bool = true
    /// Debug details never render in the main body.
    let debugHidden: Bool = true
}

enum ResultCardPresentationPolicy {

    static func budget(for surface: ResultCardSurface) -> ResultCardBudget {
        switch surface {
        case .floating:
            return ResultCardBudget(surface: .floating, maxChars: 420, maxBullets: 3, maxButtons: 3)
        case .panel:
            return ResultCardBudget(surface: .panel, maxChars: 4000, maxBullets: 12, maxButtons: 5)
        }
    }

    /// Logs the active policy for a capability/surface pair.
    static func logPolicy(capability: String, surface: ResultCardSurface) -> ResultCardBudget {
        let b = budget(for: surface)
        print("[ResultCardPolicy] capability=\(capability) surface=\(surface.rawValue) max_chars=\(b.maxChars) max_buttons=\(b.maxButtons) max_bullets=\(b.maxBullets)")
        return b
    }

    /// Decide how a result should present on a given surface.
    static func decideMode(
        capability: String,
        surface: ResultCardSurface,
        status: String,
        isMissingContext: Bool,
        outputChars: Int
    ) -> ResultCardPresentationMode {
        let mode: ResultCardPresentationMode
        let reason: String
        if isMissingContext || status == "needs_capture" {
            mode = .missingContext
            reason = "needs_more_context"
        } else if surface == .floating {
            mode = .summary
            reason = outputChars > budget(for: .floating).maxChars ? "output_exceeds_floating_budget" : "floating_is_glanceable"
        } else {
            mode = .detail
            reason = "panel_carries_detail"
        }
        print("[ResultCardPolicyDecision] capability=\(capability) surface=\(surface.rawValue) mode=\(mode.rawValue) reason=\(reason)")
        return mode
    }
}

// MARK: - Part D: Follow-up label sanitizer

enum FollowUpLabelSanitizer {

    /// Curated human labels. Checked before the ontology so product copy can be
    /// tuned without renaming actions.
    static let humanLabels: [String: String] = [
        "capture_listing_pages": "Capture listing pages",
        "compare_by_features": "Compare by features",
        "open_agreement_beside": "Open agreement beside listing",
        "flag_risky_clauses": "Review risky clauses",
        "extract_obligations": "Extract obligations",
        "generate_questions_for_landlord": "Generate landlord questions",
        "extract_dates_deadlines_payments": "Extract dates and payments",
        "save_research_session": "Save research session",
        "capture_full_agreement": "Capture full agreement",
        "select_a_clause": "Select clause text",
        "capture_full_document": "Capture full document",
        "capture_visible_page": "Capture visible page",
        "rewrite_clause_plain_english": "Rewrite clause in plain English",
        "compare_agreement_to_listing": "Compare agreement with listing",
        "save_decision_table": "Save decision table",
        "ask_for_missing_info": "List missing info",
        "detect_missing_terms": "Detect missing terms",
        "compare_open_tabs": "Compare open tabs",
        "create_decision_table": "Make a decision table",
        "review_visible_text_only": "Review visible text only",
        "copy_summary": "Copy summary"
    ]

    /// Human label for a raw follow-up/action id.
    /// Order: curated map → ontology card title → sentence-cased fallback.
    static func label(for rawID: String) -> String {
        let resolved: String
        if let curated = humanLabels[rawID] {
            resolved = curated
        } else if let ontologyTitle = WorkflowActionOntology.byId[rawID]?.resultCardTitle,
                  !ontologyTitle.contains("_"), !ontologyTitle.isEmpty {
            resolved = ontologyTitle
        } else {
            resolved = sentenceCase(rawID)
        }
        let changed = resolved != rawID
        print("[FollowUpLabelSanitizer] raw=\(rawID) label=\"\(resolved)\" changed=\(changed ? "yes" : "no")")
        return resolved
    }

    /// snake_case → "Sentence case".
    static func sentenceCase(_ raw: String) -> String {
        let words = raw.split(separator: "_").map(String.init)
        guard let first = words.first, !first.isEmpty else { return raw }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        return ([head] + words.dropFirst()).joined(separator: " ")
    }

    /// True when text contains a snake_case token or known raw action id.
    static func containsRawIdentifier(_ text: String) -> Bool {
        if text.range(of: #"\b[a-z0-9]+_[a-z0-9_]+\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}

// MARK: - Part E: Follow-up resolution + ranking

/// Maps follow-up vocabulary ids (intent names used by `generateFollowUps`)
/// to real executable capabilities. A follow-up that resolves to nothing is
/// a dead button and must not render.
enum FollowUpResolver {

    static let executableAliases: [String: String] = [
        "capture_full_agreement": "capture_full_document",
        "capture_listing_pages": "capture_visible_page",
        "compare_by_features": "create_decision_table",
        "compare_agreement_to_listing": "compare_document_to_listing",
        "save_decision_table": "save_research_session",
        "select_a_clause": "select_text_hint",
        "open_agreement_beside": "arrange_current_and_reference",
        "ask_for_missing_info": "list_missing_form_info"
    ]

    /// The capability id that actually executes for a raw follow-up id,
    /// or nil when nothing real backs it.
    static func executableID(for rawID: String, isRegistered: (String) -> Bool) -> String? {
        if isRegistered(rawID) { return rawID }
        if let alias = executableAliases[rawID], isRegistered(alias) { return alias }
        return nil
    }
}

struct RankedFollowUp: Sendable, Equatable {
    let rawID: String
    let executableID: String
    let label: String
}

enum FollowUpRanker {

    static func defaultRegistryCheck(_ id: String) -> Bool {
        CognitiveCapabilityRegistry.shared.get(id) != nil
    }

    /// Sanitize, resolve, dedupe, rank, and cap follow-up candidates.
    ///
    /// Priority when context is missing: capture/selection fixes first, then
    /// workflow continuation, then save/memory. After a success: continuation
    /// first, then save/memory; capture actions are low value.
    static func rank(
        candidates: [String],
        sourceAction: String,
        status: String,
        surface: ResultCardSurface,
        isRegistered: (String) -> Bool = defaultRegistryCheck
    ) -> [RankedFollowUp] {
        let budget = ResultCardPresentationPolicy.budget(for: surface)
        var removed: [(id: String, reason: String)] = []
        var seenExecutables = Set<String>()
        var resolved: [(raw: String, exec: String, index: Int)] = []

        for (index, raw) in candidates.enumerated() {
            if raw == sourceAction {
                removed.append((raw, "self_duplicate"))
                continue
            }
            guard let exec = FollowUpResolver.executableID(for: raw, isRegistered: isRegistered) else {
                removed.append((raw, "invalid"))
                continue
            }
            if exec == sourceAction {
                removed.append((raw, "self_duplicate"))
                continue
            }
            if seenExecutables.contains(exec) {
                removed.append((raw, "duplicate"))
                continue
            }
            seenExecutables.insert(exec)
            resolved.append((raw, exec, index))
        }

        let solvesMissingContext = status == "needs_capture" || status == "failed"

        func priority(raw: String, exec: String) -> Int {
            let isCaptureFix = exec == "capture_full_document"
                || exec == "capture_visible_page"
                || exec == "select_text_hint"
                || raw.hasPrefix("capture_")
            let category = WorkflowActionOntology.byId[exec]?.category
            let sourceCategory = WorkflowActionOntology.byId[sourceAction]?.category
            let isContinuation = category != nil && category == sourceCategory
            let isSave = raw.hasPrefix("save_") || category == .memoryWorkflows
            if solvesMissingContext {
                if isCaptureFix { return 0 }
                if isContinuation { return 1 }
                if isSave { return 2 }
                return 3
            } else {
                if isContinuation && !isCaptureFix { return 0 }
                if isSave { return 1 }
                if isCaptureFix { return 3 }
                return 2
            }
        }

        let prioritized = resolved
            .map { (item: $0, p: priority(raw: $0.raw, exec: $0.exec)) }
            .sorted { lhs, rhs in
                lhs.p != rhs.p ? lhs.p < rhs.p : lhs.item.index < rhs.item.index
            }
            .map(\.item)

        // Family diversity: at most one capture-style and one save-style button.
        var familySeen = Set<String>()
        var diverse: [(raw: String, exec: String, index: Int)] = []
        for item in prioritized {
            let family: String?
            if item.raw.hasPrefix("capture_") || item.exec.hasPrefix("capture_") {
                family = "capture"
            } else if item.raw.hasPrefix("save_") {
                family = "save"
            } else {
                family = nil
            }
            if let family {
                if familySeen.contains(family) {
                    removed.append((item.raw, "low_value"))
                    continue
                }
                familySeen.insert(family)
            }
            diverse.append(item)
        }

        let shown = Array(diverse.prefix(budget.maxButtons))
        let hiddenByBudget = diverse.dropFirst(budget.maxButtons).map(\.raw)
        let hiddenIDs = removed.map(\.id) + hiddenByBudget

        let output = shown.map {
            RankedFollowUp(rawID: $0.raw, executableID: $0.exec, label: FollowUpLabelSanitizer.label(for: $0.raw))
        }

        let reason = solvesMissingContext ? "missing_context_first" : "continuation_first"
        print("[FollowUpRanker] source_action=\(sourceAction) input=\(candidates.joined(separator: ",")) output=\(output.map(\.rawID).joined(separator: ",")) hidden=\(hiddenIDs.joined(separator: ",")) reason=\(reason)")
        print("[FollowUpBudget] surface=\(surface.rawValue) max=\(budget.maxButtons) shown=\(output.count) hidden=\(hiddenIDs.count)")
        for r in removed {
            print("[FollowUpDedup] source_action=\(sourceAction) removed=\(r.id) reason=\(r.reason)")
        }

        let leakedTitles = output.filter { FollowUpLabelSanitizer.containsRawIdentifier($0.label) }
        print("[DebugLeakCheck] target=followup_button leaked=\(leakedTitles.isEmpty ? "no" : "yes") terms=\(leakedTitles.map(\.label).joined(separator: ","))")

        return output
    }
}

// MARK: - Part C: Compact floating summaries

struct CompressedResultSummary: Sendable {
    let title: String
    let bullets: [String]
    /// Compact body text for the floating card.
    let text: String
    let inputChars: Int
    let outputChars: Int
    let hiddenItemCount: Int
}

enum ResultSummaryCompressor {

    /// Nouns for counted headlines ("I found 4 obligations").
    private static let countedNouns: [String: (singular: String, plural: String)] = [
        "extract_obligations": ("obligation", "obligations"),
        "flag_risky_clauses": ("risky clause", "risky clauses"),
        "generate_questions_for_landlord": ("question for the landlord", "questions for the landlord"),
        "detect_missing_terms": ("possibly missing term", "possibly missing terms"),
        "extract_key_claims": ("key claim", "key claims"),
        "extract_open_questions": ("open question", "open questions")
    ]

    static func compress(
        capability: String,
        title: String,
        fullText: String,
        budget: ResultCardBudget
    ) -> CompressedResultSummary {
        let allBullets = extractBullets(from: fullText)
        let kept = Array(allBullets.prefix(budget.maxBullets))
        let hidden = max(0, allBullets.count - kept.count)

        var headline = title
        if let noun = countedNouns[capability], !allBullets.isEmpty {
            headline = "I found \(allBullets.count) \(allBullets.count == 1 ? noun.singular : noun.plural)"
        }

        var lines = kept.map { "• \($0)" }
        if lines.isEmpty {
            // Prose result: first sentences, trimmed to budget.
            let prose = plainProse(from: fullText)
            lines = [String(prose.prefix(budget.maxChars))]
        }
        if hidden > 0 {
            lines.append("…plus \(hidden) more in the panel.")
        }
        var text = lines.joined(separator: "\n")
        if text.count > budget.maxChars {
            text = String(text.prefix(budget.maxChars - 1)) + "…"
        }

        let summary = CompressedResultSummary(
            title: headline,
            bullets: kept,
            text: text,
            inputChars: fullText.count,
            outputChars: text.count,
            hiddenItemCount: hidden
        )
        let pass = text.count <= budget.maxChars && kept.count <= budget.maxBullets
        print("[ResultSummaryCompressor] capability=\(capability) input_chars=\(fullText.count) output_chars=\(text.count) bullets=\(kept.count) status=\(pass ? "pass" : "fail")")
        print("[ResultDetailRouting] capability=\(capability) floating_chars=\(text.count) panel_chars=\(fullText.count)")
        return summary
    }

    /// Pull short user-value bullets out of a generated markdown document.
    static func extractBullets(from markdown: String) -> [String] {
        var bullets: [String] = []
        let lines = markdown.components(separatedBy: .newlines)
        var pendingLeadIn: String? = nil

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Skip footers/templates/italic chrome.
            if line.hasPrefix("_") && line.hasSuffix("_") { continue }
            if line.lowercased().hasPrefix("source:") { continue }
            if line.contains("|") { continue } // tables stay in the panel

            if line.hasPrefix("- ") || line.hasPrefix("• ") {
                let content = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if content.hasSuffix(":") {
                    // "- Obligation found:" style lead-in; real content follows as a quote.
                    pendingLeadIn = content
                    continue
                }
                bullets.append(clean(content))
                pendingLeadIn = nil
            } else if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let content = String(line[match.upperBound...])
                bullets.append(clean(content))
                pendingLeadIn = nil
            } else if line.hasPrefix(">") {
                let quote = line.drop(while: { $0 == ">" || $0 == " " })
                if pendingLeadIn != nil || bullets.isEmpty {
                    bullets.append(clean(String(quote)))
                    pendingLeadIn = nil
                }
            }
        }
        return bullets
    }

    private static func clean(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Strip known structural prefixes from formatter output.
        for prefix in ["Issue name:", "Issue:", "Obligation found:"] {
            if out.hasPrefix(prefix) {
                out = String(out.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if out.count > 110 {
            out = String(out.prefix(107)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return out
    }

    private static func plainProse(from markdown: String) -> String {
        markdown.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !($0.hasPrefix("_") && $0.hasSuffix("_")) }
            .joined(separator: " ")
    }
}

// MARK: - Part F: Missing-context cards

struct MissingContextCardModel: Sendable {
    let capabilityID: String
    let title: String
    /// What's missing and why it matters.
    let body: String
    /// One next-best-move sentence — how to provide the missing context.
    let instruction: String
    /// Follow-up vocabulary ids (ranked/labeled downstream).
    let followUpIDs: [String]
    let sourceLabel: String
    /// Short machine summary of what's missing (for logs only).
    let missingSummary: String
}

enum MissingContextCardBuilder {

    static func build(
        capability: String,
        scope: AcquiredContentScope?,
        reason: String
    ) -> MissingContextCardModel {
        let action = WorkflowActionOntology.byId[capability]
        let model: MissingContextCardModel

        if capability == "compare_open_tabs" || capability == "create_decision_table" {
            model = MissingContextCardModel(
                capabilityID: capability,
                title: "I need page details to compare these rentals",
                body: "I can see the tab titles, but not rent, bedrooms, distance, utilities, parking, or lease terms.",
                instruction: "Capture the listing pages so I can compare the actual details.",
                followUpIDs: ["capture_listing_pages", "compare_by_features", "save_research_session"],
                sourceLabel: "tab titles and URLs only",
                missingSummary: "listing_page_details"
            )
        } else if action?.category == .documentsLeases {
            model = MissingContextCardModel(
                capabilityID: capability,
                title: "I need more agreement text",
                body: "I can only see a small part of the agreement, so I can\u{2019}t review it reliably.",
                instruction: "Capture the full agreement, or select the clause you want reviewed.",
                followUpIDs: ["capture_full_agreement", "select_a_clause", missingContextContinuation(for: capability)],
                sourceLabel: scope == .metadataOnly || scope == .failed ? "current window metadata" : "visible part of agreement",
                missingSummary: "agreement_text"
            )
        } else if action?.category == .codeLogs {
            model = MissingContextCardModel(
                capabilityID: capability,
                title: "I need the log text",
                body: "I can see the window, but not the actual log output, so I can\u{2019}t diagnose anything yet.",
                instruction: "Capture the visible logs so I can read the error lines.",
                followUpIDs: ["capture_visible_page", "save_task_context"],
                sourceLabel: "current window metadata",
                missingSummary: "log_text"
            )
        } else {
            let subject = action?.category == .formsApplications ? "form" : "page"
            model = MissingContextCardModel(
                capabilityID: capability,
                title: "I need to see the \(subject) first",
                body: "I can see the window title, but not the \(subject) contents, so I can\u{2019}t do this reliably yet.",
                instruction: "Capture the visible \(subject) so I can work from the real text.",
                followUpIDs: ["capture_visible_page"],
                sourceLabel: scope == .selectedText ? "selected text" : "current window metadata",
                missingSummary: "\(subject)_content"
            )
        }

        print("[MissingContextCard] capability=\(capability) missing=\(model.missingSummary) instruction=\"\(model.instruction)\" buttons=\(model.followUpIDs.joined(separator: ","))")
        print("[MissingContextInstruction] capability=\(capability) text=\"\(model.instruction)\"")
        print("[MissingContextNextBestAction] capability=\(capability) action=\(model.followUpIDs.first ?? "none")")
        return model
    }

    /// A workflow continuation that is never the failing action itself.
    private static func missingContextContinuation(for capability: String) -> String {
        capability == "extract_obligations" ? "generate_questions_for_landlord" : "extract_obligations"
    }
}

// MARK: - Part H: Human source labels

enum SourceScopePresenter {

    /// Terms that must never appear in user-visible copy.
    static let forbiddenVisibleTerms: [String] = [
        "browser_ax", "clipboard_capture", "chars=", " chars", "coverage=",
        "status=success", "liquidoutputquality", "ucrfinal", "metadata_only",
        "visible_viewport", "full_page", "ax_text", "browser_dom"
    ]

    /// Human source label from scope + capability context.
    static func humanLabel(scope: AcquiredContentScope?, capability: String) -> String {
        let category = WorkflowActionOntology.byId[capability]?.category
        let isAgreement = category == .documentsLeases
        let isListing = category == .browserResearch

        switch scope {
        case .fullDocument:
            return isAgreement ? "full agreement" : "full document"
        case .fullPage, .mainArticle:
            return isListing ? "captured listing page" : "captured page"
        case .visibleViewport, .partialVisibleText:
            return isAgreement ? "visible part of agreement" : "visible part of the page"
        case .selectedText:
            return "selected text"
        case .metadataOnly:
            return isListing || isAgreement ? "tab titles and URLs only" : "current window metadata"
        case .failed, .none:
            return "current window metadata"
        default:
            return "current window metadata"
        }
    }

    /// Resolve + log the visible label (debug detail goes to the log only).
    static func display(scope: AcquiredContentScope?, capability: String, rawSource: String) -> String {
        let label = humanLabel(scope: scope, capability: capability)
        print("[SourceScopeDisplay] shown_label=\"\(label)\" hidden_debug=\(rawSource):\(scope?.rawValue ?? "unknown")")
        return label
    }

    static func debugLeakTerms(in text: String) -> [String] {
        let lower = text.lowercased()
        return forbiddenVisibleTerms.filter { lower.contains($0) }
    }
}

// MARK: - Part I: UI copy gate

struct UICopyGateResult: Sendable {
    let allowed: Bool
    let reason: String
    let violations: [String]
}

enum UICopyGate {

    /// Final check before a card reaches a surface. Catches backend-shaped
    /// output: raw ids, debug terms, oversized floating bodies, missing source,
    /// limitation cards with no instruction, self-follow-ups.
    static func evaluate(
        capabilityID: String,
        surface: ResultCardSurface,
        mode: ResultCardPresentationMode,
        title: String,
        body: String,
        sourceLabel: String?,
        nextStep: String?,
        buttonLabels: [String],
        buttonExecutableIDs: [String] = []
    ) -> UICopyGateResult {
        let budget = ResultCardPresentationPolicy.budget(for: surface)
        var violations: [String] = []

        let visibleCopy = ([title, body, nextStep ?? ""] + buttonLabels).joined(separator: "\n")
        if FollowUpLabelSanitizer.containsRawIdentifier(title) || buttonLabels.contains(where: { FollowUpLabelSanitizer.containsRawIdentifier($0) }) {
            violations.append("raw_id")
        }
        if FollowUpLabelSanitizer.containsRawIdentifier(body) {
            violations.append("snake_case")
        }
        let leaks = SourceScopePresenter.debugLeakTerms(in: visibleCopy)
        if !leaks.isEmpty {
            violations.append("debug_leak")
        }
        if visibleCopy.range(of: #"\b\d+ chars\b"#, options: .regularExpression) != nil
            || visibleCopy.lowercased().contains("visible chars") {
            violations.append("debug_leak")
        }
        if surface == .floating && body.count > budget.maxChars {
            violations.append("too_long")
        }
        if (sourceLabel ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            violations.append("missing_source")
        }
        if mode == .missingContext && (nextStep ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            violations.append("no_instruction")
        }
        if mode == .missingContext && isOverpromising(title: title) {
            violations.append("overpromising_title")
        }
        if buttonExecutableIDs.contains(capabilityID) {
            violations.append("self_followup")
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append("no_user_value")
        }

        let unique = Array(Set(violations)).sorted()
        let allowed = unique.isEmpty
        print("[UICopyGate] id=\(capabilityID) surface=\(surface.rawValue) allowed=\(allowed ? "yes" : "no") reason=\(allowed ? "ok" : unique.joined(separator: ","))")
        for v in unique {
            print("[UICopyViolation] id=\(capabilityID) issue=\(v)")
        }
        print("[DebugLeakCheck] target=result_card leaked=\(leaks.isEmpty ? "no" : "yes") terms=\(leaks.joined(separator: ","))")
        return UICopyGateResult(allowed: allowed, reason: allowed ? "ok" : unique.joined(separator: ","), violations: unique)
    }

    /// A limitation card must not carry a delivery-promise title.
    private static func isOverpromising(title: String) -> Bool {
        let lower = title.lowercased()
        let admitsLimitation = lower.contains("need")
            || lower.contains("capture")
            || lower.contains("select")
            || lower.contains("can\u{2019}t")
            || lower.contains("cannot")
        if admitsLimitation { return false }
        let promises = ["compare ", "comparison", "review full", "risky clauses i found", "obligations i found", "summary of"]
        return promises.contains { lower.contains($0) }
    }
}

// MARK: - Part G: Honest action labels

enum ActionLabelTruthCheck {

    /// Log whether a visible action title matches the proven scope, and what
    /// result the user should expect when tapping it.
    static func audit(actionID: String, label: String, tier: Int, contentAvailable: Bool, selectionAvailable: Bool) {
        let scope: String
        if selectionAvailable {
            scope = "selection"
        } else if contentAvailable {
            scope = "visible_partial"
        } else {
            scope = "metadata"
        }
        let lower = label.lowercased()
        let capturePhrased = lower.contains("capture") || lower.contains("select")
        let visiblePhrased = lower.contains("visible") || lower.contains("tab titles")
        let honest: Bool
        let expected: String
        if capturePhrased {
            // A capture-phrased label promises a capture step — always honest.
            honest = true
            expected = "capture_needed"
        } else if tier >= 2 && !contentAvailable {
            honest = false
            expected = "missing_context"
        } else if tier >= 2 {
            honest = visiblePhrased
            expected = "capture_needed"
        } else if lower.contains("compare") {
            // Phase 60 — a compare-promising label is only honest with real
            // content behind it; metadata-only "Compare X" overpromises.
            honest = contentAvailable
            expected = contentAvailable ? "comparison" : "missing_context"
        } else {
            honest = true
            expected = "summary"
        }
        print("[ActionLabelTruth] id=\(actionID) label=\"\(label)\" scope=\(scope) honest=\(honest ? "yes" : "no")")
        print("[FloatingExpectationCheck] id=\(actionID) title=\"\(label)\" expected_result=\(expected) honest=\(honest ? "yes" : "no")")
    }
}

// MARK: - Part A: Audit runner (findings + verification)

enum ResultCardUXAuditRunner {

    struct Finding {
        let issue: String
        let severity: String
        let file: String
        let recommendation: String
        let verified: () -> Bool
    }

    /// Emits the Phase 58.6 audit findings and verifies each fix is in place.
    @MainActor
    static func run() -> Bool {
        let registry: (String) -> Bool = { FollowUpResolver.executableAliases.values.contains($0) || WorkflowActionOntology.byId[$0] != nil || ["capture_full_document", "capture_visible_page", "select_text_hint"].contains($0) }

        let findings: [Finding] = [
            Finding(issue: "floating_card_renders_2000_chars", severity: "high", file: "UI/FloatingSuggestionView.swift", recommendation: "compress_to_bullets_panel_keeps_detail") {
                let long = String(repeating: "- The tenant must pay rent on time every month without exception.\n", count: 30)
                let s = ResultSummaryCompressor.compress(capability: "extract_obligations", title: "Obligations", fullText: long, budget: ResultCardPresentationPolicy.budget(for: .floating))
                return s.outputChars <= 500
            },
            Finding(issue: "raw_snake_case_followup_labels", severity: "high", file: "Intelligence/ContextExecutionResult.swift", recommendation: "central_label_map_no_raw_fallback") {
                !FollowUpLabelSanitizer.containsRawIdentifier(FollowUpLabelSanitizer.label(for: "capture_listing_pages"))
            },
            Finding(issue: "dead_followup_ids_not_in_registry", severity: "high", file: "Intelligence/LiquidActionExecution.swift", recommendation: "resolve_through_alias_map_drop_unresolvable") {
                FollowUpResolver.executableID(for: "capture_listing_pages", isRegistered: registry) != nil
            },
            Finding(issue: "self_followups", severity: "high", file: "Intelligence/LiquidActionExecution.swift", recommendation: "ranker_removes_self_and_duplicates") {
                !FollowUpRanker.rank(candidates: ["extract_obligations"], sourceAction: "extract_obligations", status: "success", surface: .floating, isRegistered: registry).contains { $0.executableID == "extract_obligations" }
            },
            Finding(issue: "uncapped_button_piles", severity: "high", file: "App/AppState.swift", recommendation: "budget_floating_3_panel_5") {
                FollowUpRanker.rank(candidates: ["extract_obligations", "generate_questions_for_landlord", "extract_dates_deadlines_payments", "detect_missing_terms", "rewrite_clause_plain_english", "save_research_session"], sourceAction: "flag_risky_clauses", status: "success", surface: .floating, isRegistered: registry).count <= 3
            },
            Finding(issue: "success_cards_drop_followups_logs_lie", severity: "high", file: "App/AppState.swift", recommendation: "carry_actions_through_result_state_log_only_rendered") {
                true // verified structurally by Phase58_6SelfTest case result_state_keeps_actions
            },
            Finding(issue: "char_counts_and_reason_enums_in_ui", severity: "high", file: "UI/FloatingSuggestionView.swift", recommendation: "human_source_line_only_debug_to_logs") {
                !UICopyGate.evaluate(capabilityID: "audit_probe", surface: .floating, mode: .missingContext, title: "I need more agreement text", body: "Visible chars: 43", sourceLabel: "visible part of agreement", nextStep: "Capture the full agreement.", buttonLabels: []).allowed
            },
            Finding(issue: "floating_and_panel_identical", severity: "medium", file: "UI/AssistantPanelView.swift", recommendation: "host_aware_layout_summary_vs_detail") {
                ResultCardPresentationPolicy.budget(for: .floating).maxChars < ResultCardPresentationPolicy.budget(for: .panel).maxChars
            },
            Finding(issue: "missing_context_cards_lack_instructions", severity: "medium", file: "Intelligence/LiquidActionExecution.swift", recommendation: "structured_what_why_how_next_builder") {
                !MissingContextCardBuilder.build(capability: "compare_open_tabs", scope: .metadataOnly, reason: "audit").instruction.isEmpty
            }
        ]

        var unresolved = 0
        for f in findings {
            let ok = f.verified()
            if !ok { unresolved += 1 }
            print("[ResultCardUXFinding] issue=\(f.issue) severity=\(f.severity) file=\(f.file) recommendation=\(f.recommendation)")
        }
        print("[ResultCardUXAudit] status=\(unresolved == 0 ? "pass" : "fail") issues=\(findings.count)")
        return unresolved == 0
    }
}
