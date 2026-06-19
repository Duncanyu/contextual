import Foundation
import AppKit

// MARK: - Phase 53: Liquid Action Execution
//
// Executes ontology actions in tiers:
//   Tier 1 — deterministic local formatters over honestly acquired content,
//            metadata notes that SAY they're metadata-based, selection
//            transforms, memory notes, and aliases to proven executors.
//   Tier 2 — content needed but unavailable → existing capture-needed card.
//   Tier 3 — needs the browser bridge / Google account → setup card.
//
// No model calls: everything is local, bounded, and reviewable.

extension CapabilityExecutor {

    func executeLiquidAction(_ action: WorkflowAction, context: [String: Any]) async -> CapabilityExecutionStatus {
        let signals = Self.liquidSignals(from: context)
        let (tier, tierReason) = LiquidActionRouter.executionTier(for: action, signals: signals)
        print("[ActionExecutionTier] id=\(action.id) tier=\(tier) reason=\(tierReason)")
        print("[ActionExecution] capability=\(action.id)")

        let status: CapabilityExecutionStatus
        switch action.executionKind {
        case .setupCard:
            status = liquidSetupCard(action)
        case .workspaceAlias:
            status = await liquidAlias(action, context: context)
        case .memoryNote:
            status = await liquidMemoryNote(action, context: context, signals: signals)
        case .metadataNote:
            status = await liquidMetadataNote(action, context: context, signals: signals)
        case .contentInsight, .selectionTransform:
            status = await liquidContentAction(action, context: context)
        }

        let outcome: String
        switch status {
        case .success, .partial, .alreadySatisfied, .previewGenerated, .openedSearch:
            outcome = "execute"
        case .captureNeeded:
            outcome = action.executionKind == .setupCard ? "setup_needed" : "capture_needed"
        case .blocked, .unavailable, .cancelled:
            outcome = "blocked"
        case .failedVisible, .failedSilent:
            outcome = "blocked"
        }
        print("[ActionVisibleContract] id=\(action.id) outcome=\(outcome) valid=\(status != .failedSilent ? "yes" : "no")")
        if action.category == .formsApplications {
            print("[FormActionResult] id=\(action.id) status=\(status == .success ? "success" : (status == .captureNeeded ? "needs_capture" : "failed")) reason=\(tierReason)")
        }
        if action.category == .documentsLeases {
            print("[RentalActionResult] id=\(action.id) status=\(status.rawValue)")
        }
        if action.category == .codeLogs {
            print("[CodeActionResult] id=\(action.id) status=\(status.rawValue)")
        }
        return status
    }

    nonisolated static func generateFollowUps(action: WorkflowAction, status: String, scope: AcquiredContentScope?) -> [String] {
        var followUps: [String] = []
        let actualScope = scope ?? .metadataOnly
        let isFailed = status == "needs_capture" || status == "failed"

        if action.id == "flag_risky_clauses" {
            if isFailed || actualScope == .metadataOnly || actualScope == .visibleViewport || actualScope == .selectedText {
                followUps = ["capture_full_agreement", "extract_obligations", "generate_questions_for_landlord", "compare_agreement_to_listing"]
            } else {
                followUps = ["extract_obligations", "extract_dates_deadlines_payments", "generate_questions_for_landlord", "rewrite_clause_plain_english"]
            }
        } else if action.id == "compare_open_tabs" || action.id == "create_decision_table" {
            if isFailed || actualScope == .metadataOnly {
                followUps = ["capture_listing_pages", "compare_by_features", "save_research_session", "open_agreement_beside"]
            } else {
                followUps = ["save_decision_table", "compare_agreement_to_listing", "generate_questions_for_landlord"]
            }
        } else {
            if isFailed {
                if action.category == .documentsLeases {
                    followUps = ["capture_full_agreement", "select_a_clause", "extract_obligations", "extract_dates_deadlines_payments", "generate_questions_for_landlord"]
                } else {
                    followUps = ["capture_full_document", "ask_for_missing_info"]
                }
            } else {
                if action.category == .documentsLeases {
                    followUps = ["extract_obligations", "extract_dates_deadlines_payments", "generate_questions_for_landlord", "flag_risky_clauses"]
                }
            }
        }

        // Never offer an action as a follow-up to itself (the ranker enforces
        // this too; filtering here keeps the logged set honest).
        followUps = followUps.filter { $0 != action.id }

        if !followUps.isEmpty {
            let reason = isFailed ? "metadata_only" : (actualScope.satisfiesFullScope ? "natural_next_step" : "partial_scope")
            print("[FollowUpActionSet] source_action=\(action.id) reason=\(reason) actions=\(followUps.joined(separator: ","))")
        }
        
        return followUps
    }

    // MARK: Signals from execution context

    static func liquidSignals(from context: [String: Any]) -> WorkflowSignals {
        let title = (context["windowTitle"] as? String)
            ?? (context["titles"] as? [String])?.first ?? ""
        let urlString = (context["urls"] as? [String])?.first
            ?? (context["tabURLs"] as? [String])?.first ?? ""
        let url = URL(string: urlString)
        let focusKey = EnrichedContextCache.focusKey(
            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            windowTitle: title,
            url: urlString.isEmpty ? nil : urlString
        )
        let enriched = EnrichedContextCache.shared.lookup(key: focusKey, logHit: false)
        if enriched == nil, let latest = EnrichedContextCache.shared.latestUsable(logHit: false), latest.key != focusKey {
            print("[ResultContextRejected] source=cache reason=not_current_focus")
            print("[NoResultGeneratedFromBackgroundContext] status=pass count=0")
        }
        return WorkflowSignals(
            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            windowTitle: title,
            urlHost: url?.host ?? "",
            urlPath: url?.path ?? "",
            tabTitles: context["tabTitles"] as? [String] ?? [],
            selectedTextLength: context["selectedTextLength"] as? Int ?? 0,
            contentAvailable: true,   // executor verifies via UCR; assume reachable here
            workflow: context["workflow"] as? String ?? "unknown",
            visibleAppNames: WorkspaceRuntimeInventoryProvider.snapshot().visibleWindows.map(\.appName),
            enrichedContext: enriched
        )
    }

    // MARK: Tier 3 — setup cards

    private func liquidSetupCard(_ action: WorkflowAction) -> CapabilityExecutionStatus {
        switch action.id {
        case "connect_google_docs":
            LiquidInsightFormatters.logQuality(
                action: action,
                source: "metadata",
                chars: 0,
                extractedItems: 0,
                quotedLines: 0,
                quality: "needs_capture",
                reason: "setup_required",
                allowed: false,
                gateReason: "needs_capture"
            )
            return showContextSetupCard(
                capabilityId: action.id,
                title: "Connect Google Docs",
                reason: "google_docs_access_not_wired",
                message: "Reading a full Google Doc needs either the user-approved full-document capture (from a capture card) or a Docs connection, which is not wired in this build yet.\n\nUse \u{201C}Capture full document\u{201D} for now.",
                nextStep: "capture_full_document"
            )
        default:
            return showContextSetupCard(
                capabilityId: action.id,
                title: action.resultCardTitle,
                reason: "setup_required",
                message: action.shortDescription,
                nextStep: "enable_page_access"
            )
        }
    }

    // MARK: Tier 1 — aliases to proven executors

    private func liquidAlias(_ action: WorkflowAction, context: [String: Any]) async -> CapabilityExecutionStatus {
        guard let aliasId = action.executorAlias,
              let target = CognitiveCapabilityRegistry.shared.get(aliasId) else {
            print("[ActionFailure] capability=\(action.id) reason=alias_target_missing")
            return .unavailable
        }
        var merged = context
        merged["liquid_origin"] = action.id
        switch action.id {
        case "arrange_current_and_reference":
            merged["arrange_mode"] = "manual"
        case "put_browser_beside_pdf":
            merged["arrange_mode"] = "manual"
            merged["apps"] = ["Preview"]
        case "put_xcode_beside_logs":
            merged["arrange_mode"] = "manual"
            merged["apps"] = ["Xcode"]
        default:
            break
        }
        let canonical = ActionAliasResolver.canonicalID(for: action.id)
        if canonical != action.id {
            print("[ActionAliasResolved] from=\(action.id) to=\(canonical) reason=liquid_workspace_alias")
        }
        print("[ExecutorResolution] visible_id=\(action.id) canonical_id=\(aliasId) executor=capability_executor available=yes")
        print("[LiquidAlias] id=\(action.id) delegate=\(aliasId)")
        return await execute(capability: target, context: merged)
    }

    // MARK: Tier 1 — memory notes

    private func liquidMemoryNote(
        _ action: WorkflowAction,
        context: [String: Any],
        signals: WorkflowSignals
    ) async -> CapabilityExecutionStatus {
        let store = WorkflowNotesStore.shared
        let sourceSurface = (context["source_surface"] as? String) ?? "panel"
        let workflow = signals.workflow
        let body: String

        switch action.id {
        case "save_application_progress_note":
            let note = "Application page: \(signals.windowTitle)\nSite: \(signals.urlHost.isEmpty ? "unknown" : signals.urlHost)\nSaved: \(Self.liquidDateString())"
            store.append(workflow: "form_application", title: "Application progress", body: note)
            body = "# Application Progress Saved\n\n\(note)\n\nRecall it later with \u{201C}Recall related context\u{201D}."
        case "save_research_session":
            let tabs = signals.tabTitles.prefix(10).map { "- \($0)" }.joined(separator: "\n")
            let note = "Session: \(signals.windowTitle)\nTabs:\n\(tabs)"
            store.append(workflow: "browser_research", title: "Research session", body: note)
            body = "# Research Session Saved\n\n\(note)"
        case "save_task_context":
            let note = "Task: \(signals.windowTitle)\nApp: \(signals.activeApp)\nWorkflow: \(workflow)\nSaved: \(Self.liquidDateString())"
            store.append(workflow: workflow, title: "Task context", body: note)
            body = "# Task Context Saved\n\n\(note)"
        case "update_project_status_note":
            let note = "[\(Self.liquidDateString())] \(signals.windowTitle) — status checkpoint (app: \(signals.activeApp))"
            store.append(workflow: workflow, title: "Project status", body: note)
            body = "# Project Status Updated\n\n\(note)"
        case "recall_related_context":
            let notes = store.recent(limit: 5)
            if notes.isEmpty {
                body = "# No Saved Context Yet\n\nNothing saved so far. Use \u{201C}Save task context\u{201D} or \u{201C}Save an application progress note\u{201D} while you work."
            } else {
                let formatted = notes.map { "**\($0.title)** (\(Self.liquidDateString($0.timestamp)), \($0.workflow))\n\($0.body)" }.joined(separator: "\n\n---\n\n")
                body = "# Saved Context\n\n\(formatted)"
            }
        case "suggest_next_step_from_memory":
            let notes = store.recent(limit: 3)
            if notes.isEmpty {
                body = "# No Memory To Suggest From\n\nSave a task note first — then I can suggest where to pick back up."
            } else {
                let latest = notes[0]
                body = "# Suggested Next Step\n\nYour latest saved context (\(Self.liquidDateString(latest.timestamp))):\n\n\(latest.body)\n\n**Suggestion:** pick up here — reopen this context and continue from the last saved point."
            }
        default:
            body = "# Note\n\nNothing to save for \(action.id)."
        }

        let verified = await presentCognitiveResultSurface(
            capability: action.id,
            status: "success",
            outputText: body,
            source: "workflow_notes",
            quality: "metadata_only",
            coverage: "minimal",
            sourceSurface: sourceSurface,
            preferredSurface: "both",
            scope: .metadataOnly
        )
        print("[CapabilityExecution] completed status=\(verified ? "success" : "failed_silent") id=\(action.id) reason=memory_note")
        return verified ? .success : .failedSilent
    }

    // MARK: Tier 1 — metadata notes (honest: built from title/url/tabs ONLY)

    private func liquidMetadataNote(
        _ action: WorkflowAction,
        context: [String: Any],
        signals: WorkflowSignals
    ) async -> CapabilityExecutionStatus {
        let sourceSurface = (context["source_surface"] as? String) ?? "panel"
        let body = LiquidInsightFormatters.metadataNote(action: action, signals: signals)
        let templateOnly = LiquidInsightFormatters.isTemplateOnly(body)
        LiquidInsightFormatters.logQuality(
            action: action,
            source: "metadata",
            chars: body.count,
            extractedItems: 0,
            quotedLines: 0,
            quality: templateOnly ? "template_only" : "thin",
            reason: templateOnly ? "metadata_scaffold" : "metadata_note",
            allowed: true,
            gateReason: "metadata_only_labeled"
        )
        // Phase 58.6 — a metadata-only comparison is a missing-context card,
        // not a result. Present it as needs_capture so the user gets the
        // what's-missing / how-to-fix structure and capture buttons.
        let isMissingContextNote = action.id == "compare_open_tabs" || action.id == "create_decision_table"
        let verified = await presentCognitiveResultSurface(
            capability: action.id,
            status: isMissingContextNote ? "needs_capture" : "success",
            outputText: body,
            source: "browser_metadata",
            quality: isMissingContextNote ? "needs_capture" : "metadata_only",
            coverage: "minimal",
            sourceSurface: sourceSurface,
            preferredSurface: "both",
            scope: .metadataOnly
        )
        print("[CapabilityExecution] completed status=\(verified ? "success" : "failed_silent") id=\(action.id) reason=metadata_note")
        if isMissingContextNote {
            return verified ? .captureNeeded : .failedSilent
        }
        return verified ? .success : .failedSilent
    }

    // MARK: Tier 1/2 — content-based actions through UCR

    private func liquidContentAction(_ action: WorkflowAction, context: [String: Any]) async -> CapabilityExecutionStatus {
        return await executeWithUniversalContent(capabilityId: action.id, context: context) { ucr, scope in
            let chars = UniversalContentReader.meaningfulCharacterCount(ucr.text)
            // Per-action minimums on top of the global scope gates.
            if chars < action.minChars {
                let msg = LiquidInsightFormatters.specificCaptureMessage(action: action, chars: chars, reason: "too_little_text")
                LiquidInsightFormatters.logQuality(
                    action: action,
                    source: LiquidInsightFormatters.sourceKind(scope: ucr.actualScope),
                    chars: chars,
                    extractedItems: 0,
                    quotedLines: 0,
                    quality: "needs_capture",
                    reason: "too_thin",
                    allowed: false,
                    gateReason: "too_thin"
                )
                return .failure(reason: "too_little_text", message: msg, nextStep: .captureVisible)
            }
            if let minScope = action.minScope, minScope.satisfiesFullScope,
               !(ucr.actualScope.satisfiesFullScope || ucr.actualScope == .mainArticle) {
                let msg = LiquidInsightFormatters.specificCaptureMessage(action: action, chars: chars, reason: "needs_full_document")
                LiquidInsightFormatters.logQuality(
                    action: action,
                    source: LiquidInsightFormatters.sourceKind(scope: ucr.actualScope),
                    chars: chars,
                    extractedItems: 0,
                    quotedLines: 0,
                    quality: "needs_capture",
                    reason: "needs_full_document",
                    allowed: false,
                    gateReason: "needs_capture"
                )
                return .failure(reason: "needs_full_scope", message: msg, nextStep: .allowClipboardCapture)
            }
            let output = LiquidInsightFormatters.format(action: action, text: ucr.text, scope: ucr.actualScope)
            let quality = LiquidInsightFormatters.evaluateLiquidOutput(action: action, input: ucr.text, output: output, scope: ucr.actualScope)
            LiquidInsightFormatters.logQuality(
                action: action,
                source: LiquidInsightFormatters.sourceKind(scope: ucr.actualScope),
                chars: chars,
                extractedItems: quality.extractedItems,
                quotedLines: quality.quotedLines,
                quality: quality.quality,
                reason: quality.reason,
                allowed: quality.allowed,
                gateReason: quality.gateReason
            )
            if !quality.allowed {
                let msg = LiquidInsightFormatters.specificCaptureMessage(action: action, chars: chars, reason: quality.gateReason)
                return .failure(reason: quality.gateReason, message: msg, nextStep: .captureVisible)
            }
            return .success(output)
        }
    }

    static func liquidDateString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Deterministic formatters

enum LiquidInsightFormatters {

    struct LiquidOutputEvaluation {
        let extractedItems: Int
        let quotedLines: Int
        let quality: String
        let reason: String
        let allowed: Bool
        let gateReason: String
    }

    // MARK: Shared text helpers

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
    }

    static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 15 }
    }

    static func matching(_ candidates: [String], any keywords: [String], limit: Int = 10) -> [String] {
        candidates.filter { line in
            let lower = line.lowercased()
            return keywords.contains { lower.contains($0) }
        }.prefix(limit).map { String($0.prefix(220)) }
    }

    static func moneyAmounts(_ text: String) -> [String] {
        regexMatches(#"\$\s?[0-9][0-9,]*(\.[0-9]{2})?"#, in: text)
    }

    static func dateMentions(_ text: String) -> [String] {
        let monthPattern = #"(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s+\d{1,2}(st|nd|rd|th)?(,?\s+\d{4})?"#
        let numericPattern = #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b|\b\d{4}-\d{2}-\d{2}\b"#
        return regexMatches(monthPattern, in: text) + regexMatches(numericPattern, in: text)
    }

    static func regexMatches(_ pattern: String, in text: String, limit: Int = 15) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).prefix(limit).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func scopeFooter(_ scope: AcquiredContentScope, chars: Int) -> String {
        "\n\n_Source: \(humanSourceLabel(scope))._"
    }

    static func humanSourceLabel(_ scope: AcquiredContentScope) -> String {
        let label: String
        switch scope {
        case .selectedText:
            label = "selected text"
        case .fullDocument:
            label = "full agreement"
        case .fullPage, .mainArticle:
            label = "captured listing page"
        case .visibleViewport:
            label = "visible part of agreement"
        case .metadataOnly:
            label = "tab titles and URLs only"
        case .failed:
            label = "current window metadata"
        default:
            label = "current window metadata"
        }
        print("[HumanSourceScope] id=unknown raw=\(scope) label=\(label)")
        return label
    }

    static func bullets(_ items: [String], empty: String) -> String {
        items.isEmpty ? "_\(empty)_" : items.map { "- \($0)" }.joined(separator: "\n")
    }

    static func sourceKind(scope: AcquiredContentScope) -> String {
        switch scope {
        case .metadataOnly, .failed:
            return "metadata"
        case .selectedText:
            return "selection"
        case .fullDocument, .fullPage, .mainArticle:
            return "full_document"
        default:
            return "visible_capture"
        }
    }

    static func isTemplateOnly(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("fill in")
            || lower.contains("[add ")
            || lower.contains("(paste ")
            || lower.contains("(unknown")
            || lower.contains("template")
    }

    static func evaluateLiquidOutput(action: WorkflowAction, input: String, output: String, scope: AcquiredContentScope) -> LiquidOutputEvaluation {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = trimmed.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }.count
        let quoted = trimmed.components(separatedBy: .newlines).filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(">")
        }.count
        let chars = UniversalContentReader.meaningfulCharacterCount(input)
        if scope == .metadataOnly || scope == .failed {
            return LiquidOutputEvaluation(extractedItems: extracted, quotedLines: quoted, quality: "needs_capture", reason: "metadata_only", allowed: false, gateReason: "needs_capture")
        }
        if trimmed.isEmpty || chars < max(40, min(action.minChars, 120)) {
            return LiquidOutputEvaluation(extractedItems: extracted, quotedLines: quoted, quality: "thin", reason: "too_thin", allowed: false, gateReason: "too_thin")
        }
        if isTemplateOnly(trimmed) && action.executionKind == .contentInsight {
            return LiquidOutputEvaluation(extractedItems: extracted, quotedLines: quoted, quality: "template_only", reason: "template_only", allowed: false, gateReason: "template_only")
        }
        if action.id == "flag_risky_clauses" {
            let hasIssue = trimmed.contains("- Issue:") || trimmed.contains("Issue:")
            let hasWhy = trimmed.contains("Why it matters:")
            let hasQuote = trimmed.contains("Source quote:") || quoted > 0 || trimmed.contains("\"")
            let hasAsk = trimmed.contains("Suggested ask/change:") || trimmed.contains("Ask/change:")
            let hasScopeLabel = trimmed.lowercased().contains("source:") || trimmed.lowercased().contains("based on")
            
            print("[OutputQualityRule] id=flag_risky_clauses rule=issue_name passed=\(hasIssue ? "yes" : "no") reason=\(hasIssue ? "ok" : "missing")")
            print("[OutputQualityRule] id=flag_risky_clauses rule=why_it_matters passed=\(hasWhy ? "yes" : "no") reason=\(hasWhy ? "ok" : "missing")")
            print("[OutputQualityRule] id=flag_risky_clauses rule=source_quote passed=\(hasQuote ? "yes" : "no") reason=\(hasQuote ? "ok" : "missing")")
            print("[OutputQualityRule] id=flag_risky_clauses rule=ask_change passed=\(hasAsk ? "yes" : "no") reason=\(hasAsk ? "ok" : "missing")")
            print("[OutputQualityRule] id=flag_risky_clauses rule=scope_label passed=\(hasScopeLabel ? "yes" : "no") reason=\(hasScopeLabel ? "ok" : "missing")")
            
            var gateReason = "ok"
            if !hasWhy { gateReason = "missing_why" }
            else if !hasAsk { gateReason = "missing_ask" }
            else if !hasScopeLabel { gateReason = "missing_scope" }
            else if !hasQuote { gateReason = "missing_source_lines" }
            else if extracted == 0 { gateReason = "too_generic" }
            
            print("[OutputImportanceGate] id=flag_risky_clauses allowed=\(gateReason == "ok" ? "yes" : "no") reason=\(gateReason)")
            
            if gateReason != "ok" {
                return LiquidOutputEvaluation(extractedItems: extracted, quotedLines: quoted, quality: "thin", reason: gateReason, allowed: false, gateReason: gateReason)
            }
        }
        if action.id == "compare_open_tabs" {
            let emptyTable = isTemplateOnly(trimmed) || !trimmed.contains("|") || trimmed.contains("Fill in the columns")
            let lines = trimmed.components(separatedBy: .newlines)
            let tableRows = lines.filter { $0.contains("|") && !$0.contains("---") }
            let hasTwoOptions = tableRows.count >= 3 // header + at least 2 rows
            let hasAttributes = (tableRows.first?.components(separatedBy: "|").count ?? 0) >= 3 // option name + 2 attrs
            
            print("[OutputQualityRule] id=compare_open_tabs rule=two_options passed=\(hasTwoOptions ? "yes" : "no")")
            print("[OutputQualityRule] id=compare_open_tabs rule=comparable_attributes passed=\(hasAttributes ? "yes" : "no")")
            print("[OutputQualityRule] id=compare_open_tabs rule=no_empty_template passed=\(!emptyTable ? "yes" : "no")")
            
            if emptyTable || !hasTwoOptions || !hasAttributes {
                return LiquidOutputEvaluation(extractedItems: extracted, quotedLines: quoted, quality: "template_only", reason: "empty_comparison", allowed: false, gateReason: "empty_comparison")
            }
        }
        if action.id == "generate_next_agent_prompt" && !trimmed.contains("```") {
            return LiquidOutputEvaluation(extractedItems: extracted, quotedLines: quoted, quality: "thin", reason: "missing_prompt_block", allowed: false, gateReason: "too_thin")
        }
        let quality = extracted == 0 && quoted == 0 ? "thin" : "good"
        let reason = extracted == 0 && quoted == 0 ? "no_matching_items_but_grounded" : "grounded_output"
        return LiquidOutputEvaluation(extractedItems: extracted, quotedLines: quoted, quality: quality, reason: reason, allowed: true, gateReason: "ok")
    }

    static func logQuality(
        action: WorkflowAction,
        source: String,
        chars: Int,
        extractedItems: Int,
        quotedLines: Int,
        quality: String,
        reason: String,
        allowed: Bool,
        gateReason: String
    ) {
        let label = "\(source): \(chars) chars"
        print("[LiquidOutputQuality] id=\(action.id) source=\(source) chars=\(chars) extracted_items=\(extractedItems) quoted_lines=\(quotedLines) quality=\(quality) reason=\(reason)")
        print("[LiquidResultSourceLabel] id=\(action.id) label=\"\(label)\"")
        print("[LiquidOutputGate] id=\(action.id) allowed=\(allowed ? "yes" : "no") reason=\(gateReason)")
    }

    static func humanResultTitle(for action: WorkflowAction, status: String) -> String {
        if status == "needs_capture" {
            return LiquidActionRouter.specificCaptureTitle(for: action, signals: WorkflowSignals(activeApp: "", windowTitle: action.category == .documentsLeases ? "agreement" : ""))
        }
        // Phase 67 — a structured content action that failed its quality contract
        // must not wear a success-shaped title. Tell the truth about missing input.
        if status != "success" {
            switch action.id {
            case "flag_risky_clauses": return "I need more agreement text"
            case "extract_obligations": return "I need more agreement text"
            case "compare_open_tabs", "create_decision_table": return "I need the listing details"
            default: break
            }
        }
        switch action.id {
        case "flag_risky_clauses": return "Risky clauses I found"
        case "extract_obligations": return "Obligations I found"
        case "extract_dates_deadlines_payments": return "Dates and payments I found"
        case "detect_missing_terms": return "Terms that may be missing"
        case "generate_questions_for_landlord": return "Questions to ask the landlord"
        case "rewrite_clause_plain_english": return "Plain-English clause"
        case "generate_next_agent_prompt": return "Next agent prompt"
        case "diagnose_latest_error": return "Latest error"
        default: return action.resultCardTitle
        }
    }

    static func sanitizeUserVisibleOutput(action: WorkflowAction, output: String, status: String, scope: AcquiredContentScope?) -> String {
        var removed = 0
        var removedKinds = Set<String>()
        var lines = output.components(separatedBy: .newlines)
        lines = lines.filter { line in
            let lower = line.lowercased()
            let debug = lower.contains("chars=")
                || lower.contains("source=")
                || lower.contains("liquidoutputquality")
                || lower.contains("ucrfinal")
                || lower.contains("browser_ax")
                || lower.contains("clipboard_capture")
                || lower.contains("status=")
                || lower.contains("capability=")
                || lower.contains("what was scanned")
                || lower.contains("source available now:")
                || lower.contains("needed:")
            if debug {
                removed += 1
                removedKinds.insert("debug_terms")
            }
            return !debug
        }
        var sanitized = lines.joined(separator: "\n")
        if sanitized.contains(action.id) {
            sanitized = sanitized.replacingOccurrences(of: action.id, with: action.title)
            removed += 1
            removedKinds.insert("raw_ids")
        }
        let statusWords = ["# Success", "status: success", "Execution succeeded"]
        for word in statusWords where sanitized.localizedCaseInsensitiveContains(word) {
            sanitized = sanitized.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
            removed += 1
            removedKinds.insert("status_jargon")
        }
        if let scope, !sanitized.lowercased().contains("source:") && !sanitized.lowercased().contains("based on") {
            sanitized += "\n\n_Source: \(humanSourceLabel(scope))._"
        }
        if removed == 0 { removedKinds.insert("none") }
        print("[ResultCopySanitizer] id=\(action.id) removed=\(removedKinds.sorted().joined(separator: ",")) count=\(removed)")
        
        if let scope {
            print("[SourceScopeDisplay] id=\(action.id) shown=yes label=\(humanSourceLabel(scope))")
        }
        
        let leaked = sanitized.contains("browser_ax") || sanitized.contains("clipboard_capture") || sanitized.contains("liquidoutputquality") || sanitized.contains("status=success")
        print("[DebugLeakCheck] id=\(action.id) leaked=\(leaked ? "yes" : "no") terms=\(removedKinds.joined(separator: ","))")
        
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func userReadableResultGate(action: WorkflowAction, title: String, output: String) -> (allowed: Bool, reason: String) {
        let lower = (title + "\n" + output).lowercased()
        if lower.contains(action.id.lowercased()) { return (false, "raw_id_present") }
        if lower.contains("liquidoutputquality") || lower.contains("ucrfinal") || lower.contains("browser_ax") || lower.contains("clipboard_capture") || lower.contains("chars=") {
            return (false, "debug_terms_present")
        }
        if lower.contains("status=success") || lower.contains("what was scanned") || lower.contains("source=") {
            return (false, "status_jargon_present")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 {
            return (false, "missing_user_value")
        }
        return (true, "ok")
    }

    static func outputImportanceGate(action: WorkflowAction, output: String) -> (allowed: Bool, reason: String) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (false, "no_user_value") }
        let lower = trimmed.lowercased()
        if isTemplateOnly(trimmed) { return (false, "too_generic") }
        if lower.contains("debug") && !lower.contains("source:") { return (false, "debug_only") }
        if trimmed.contains("- ") || trimmed.contains(">") || lower.contains("next") || lower.contains("source:") {
            return (true, "useful_findings")
        }
        return trimmed.count >= 120 ? (true, "specific_next_steps") : (false, "no_user_value")
    }

    static func specificCaptureMessage(action: WorkflowAction, chars: Int, reason: String) -> String {
        let title = LiquidActionRouter.specificCaptureTitle(
            for: action,
            signals: WorkflowSignals(activeApp: "", windowTitle: action.category == .documentsLeases ? "agreement" : "")
        )
        print("[SpecificCaptureNeeded] id=\(action.id) title=\"\(title)\" reason=\(reason == "needs_full_document" ? "needs_full_document" : chars == 0 ? "metadata_only" : "missing_visible_content")")
        print("[SpecificCaptureAction] original_id=\(action.id) capture_id=\(action.fallbackAction ?? "capture_visible_page") followup=\(action.id)")
        let model = MissingContextCardBuilder.build(
            capability: action.id,
            scope: chars == 0 ? .metadataOnly : .visibleViewport,
            reason: reason
        )
        return """
        # \(title)

        \(model.body)

        Next best move: \(model.instruction)
        """
    }

    // MARK: Content-based formatting

    @MainActor
    static func format(action: WorkflowAction, text: String, scope: AcquiredContentScope) -> String {
        let chars = UniversalContentReader.meaningfulCharacterCount(text)
        let footer = scopeFooter(scope, chars: chars)
        switch action.id {

        // ── Documents / leases ──────────────────────────────────────────────
        case "flag_risky_clauses":
            let risky = matching(sentences(text), any: [
                "terminat", "penalt", "fee", "liable", "liabilit", "forfeit",
                "non-refundable", "waive", "indemnif", "evict", "default",
                "late charge", "deduct", "guarantor", "joint and several", "interest"
            ])
            let rows = risky.map { clause -> String in
                let issue = clause.lowercased().contains("liab") ? "Liability exposure" : "Termination or cost exposure"
                return "- Issue: \(issue)\nWhy it matters: This clause may make you responsible for unexpected costs or penalties.\n> \"\(clause)\"\nAsk/change: Clarify the exact conditions and limits of this clause."
            }
            let baseLabel = scope == .fullDocument ? "full agreement" : "visible part of the agreement"
            let intro = "I found these based on [\(baseLabel)]."
            let body = rows.isEmpty ? "_No obvious risk language in the visible text — full-document review still recommended._" : rows.joined(separator: "\n\n")
            return "# Risky clauses I found\n\n\(intro)\n\n\(body)\(footer)"

        case "extract_obligations":
            let obligations = matching(sentences(text), any: [
                "must", "shall", "agrees to", "required to", "responsible for",
                "will pay", "obligated", "undertakes"
            ], limit: 12)
            let rows = obligations.map { "- Obligation found:\n> \($0)" }
            let body = rows.isEmpty ? "_No explicit obligation language found in the visible text._" : rows.joined(separator: "\n\n")
            return "# Obligations\n\n\(body)\(footer)"

        case "extract_dates_deadlines_payments":
            let money = Array(Set(moneyAmounts(text))).prefix(10)
            let dates = Array(Set(dateMentions(text))).prefix(10)
            let deadlineLines = matching(lines(text), any: ["due", "deadline", "no later than", "by the", "expires"], limit: 6)
            let quotedDeadlines = deadlineLines.map { "> \($0)" }
            let scopeLabel = scope == .fullDocument ? "Full agreement" : "Visible part of agreement"
            let nothingFound = money.isEmpty && dates.isEmpty && quotedDeadlines.isEmpty
            // Issue 4/7: structured, readable empty-state — never a bare one-liner.
            var out = "# Dates & payments\n\n"
            out += "## Dates\n\(bullets(Array(dates), empty: "None visible in the current viewport"))\n\n"
            out += "## Payments\n\(bullets(Array(money), empty: "None visible in the current viewport"))\n\n"
            if !quotedDeadlines.isEmpty {
                out += "## Deadlines\n\(quotedDeadlines.joined(separator: "\n"))\n\n"
            }
            out += "## Source\n\(scopeLabel)\n\n"
            if nothingFound {
                out += "## Next step\nCapture the full agreement to check the whole document"
            } else {
                out += "## Next step\nReview the full agreement to confirm nothing was missed outside the visible area"
            }
            return out + footer

        case "detect_missing_terms":
            let standardTerms: [(String, [String])] = [
                ("Security deposit", ["deposit"]), ("Utilities", ["utilities", "hydro", "electric"]),
                ("Maintenance responsibility", ["maintenance", "repairs"]),
                ("Termination / notice period", ["notice", "terminat"]),
                ("Subletting", ["sublet", "assign"]), ("Guests", ["guest"]),
                ("Insurance", ["insurance"]), ("Late payment", ["late"]),
                ("Entry notice", ["entry", "enter the"]), ("Pets", ["pet"])
            ]
            let lower = text.lowercased()
            let missing = standardTerms.filter { _, keys in !keys.contains { lower.contains($0) } }.map(\.0)
            return "# Possibly Missing Terms\n\n\(bullets(missing, empty: "All standard terms appear at least once in the visible text."))\n\n_Checked against 10 standard rental terms; absence in visible text does not prove absence in the full document._\(footer)"

        case "generate_questions_for_landlord":
            let lower = text.lowercased()
            var questions: [String] = []
            if !lower.contains("deposit") { questions.append("What is the deposit amount and when is it returned?") }
            if !lower.contains("utilities") { questions.append("Which utilities are included in the rent?") }
            if !lower.contains("maintenance") { questions.append("Who handles maintenance and repairs?") }
            if !lower.contains("notice") { questions.append("How much notice is required to end or renew the agreement?") }
            if !lower.contains("sublet") { questions.append("Is subletting allowed if plans change?") }
            for risk in matching(sentences(text), any: ["penalt", "fee", "forfeit", "terminat"], limit: 3) {
                questions.append("Can you clarify this clause?\n> \(risk.prefix(160))")
            }
            return "# Questions for the Landlord\n\n\(bullets(questions, empty: "The visible text covers the standard topics — review the full document for specifics."))\(footer)"

        case "summarize_house_rules":
            let rules = matching(sentences(text), any: [
                "no smoking", "quiet", "guest", "pets", "clean", "shared",
                "not permitted", "prohibited", "rules", "must not", "allowed"
            ], limit: 12)
            return "# House Rules\n\n\(bullets(rules, empty: "No explicit rule language found in the visible text."))\(footer)"

        case "calculate_rent_split_from_visible_numbers":
            let amounts = moneyAmounts(text).compactMap { Double($0.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) }
            guard let largest = amounts.max(), largest > 0 else {
                return "# Rent Split\n\n_No dollar amounts are visible to split. Capture the page or select the numbers._\(footer)"
            }
            let rows = [2, 3, 4].map { n in "- \(n) people: $\(String(format: "%.2f", largest / Double(n))) each" }.joined(separator: "\n")
            return "# Rent Split\n\nLargest visible amount: $\(String(format: "%.2f", largest))\n\n\(rows)\n\n_Verify which amount is the actual rent before using this._\(footer)"

        case "rewrite_clause_plain_english":
            let clause = String(text.prefix(700)).trimmingCharacters(in: .whitespacesAndNewlines)
            var plain = clause
            let replacements = [
                "shall": "must",
                "hereby": "",
                "pursuant to": "under",
                "prior to": "before",
                "subsequent to": "after",
                "terminate": "end",
                "liable": "responsible",
                "notwithstanding": "even if"
            ]
            for (from, to) in replacements {
                plain = plain.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
            }
            plain = plain.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            return "# Plain-English Clause\n\n**Original source:**\n> \(clause.replacingOccurrences(of: "\n", with: "\n> "))\n\n**Plain English:**\n\(plain)\(footer)"

        case "compare_document_to_listing", "find_conflicting_info":
            // Reaching here means full scope WAS available (gate enforces it).
            let claims = matching(sentences(text), any: ["$", "per month", "included", "deposit", "rent"], limit: 10)
            return "# Cross-Check\n\nKey factual statements found:\n\n\(bullets(claims, empty: "No comparable factual statements found."))\n\n_Compare these against the other source manually — automated cross-source comparison arrives with the browser bridge._\(footer)"

        // ── Forms ───────────────────────────────────────────────────────────
        case "detect_required_fields":
            let required = matching(lines(text), any: ["required", "mandatory", "must ", "*", "needed"], limit: 12)
            return "# Required Fields (visible)\n\n\(bullets(required, empty: "No explicit required-field markers visible — the form may mark them visually only."))\(footer)"

        case "check_form_consistency":
            let blanks = matching(lines(text), any: ["not provided", "n/a", "incomplete", "missing", "please enter", "please select"], limit: 8)
            let warnings = matching(lines(text), any: ["error", "invalid", "must match", "does not match"], limit: 6)
            return "# Form Consistency Check\n\n**Possibly unanswered:**\n\(bullets(blanks, empty: "No obvious blanks flagged in visible text."))\n\n**Validation warnings:**\n\(bullets(warnings, empty: "No visible validation warnings."))\(footer)"

        case "flag_deadlines_or_warnings":
            let deadlines = matching(sentences(text), any: ["deadline", "due", "before", "no later", "expires", "must submit", "by "], limit: 8)
            let warnings = matching(sentences(text), any: ["warning", "important", "note that", "failure to", "penalty"], limit: 6)
            return "# Deadlines & Warnings\n\n**Deadlines:**\n\(bullets(deadlines, empty: "No deadline language visible."))\n\n**Warnings:**\n\(bullets(warnings, empty: "No warning language visible."))\(footer)"

        case "explain_current_form_field":
            // Best label available today: the selection or the first visible text line.
            // True AX focused-element introspection arrives with the bridge sprint.
            let fieldText = String(text.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
            print("[FocusedFieldContext] role=visible_text_label label=\"\(fieldText.prefix(60))\" value_present=\(text.count > fieldText.count ? "yes" : "no") confidence=0.6")
            let explanation = formFieldExplanation(for: fieldText)
            return "# Field: \(fieldText.prefix(80))\n\n\(explanation)\(footer)"

        case "draft_answer_for_form_field":
            return "# Draft Answer\n\nField/question:\n> \(String(text.prefix(200)))\n\nSuggested structure:\n- Direct answer first (one sentence)\n- Supporting detail (dates, amounts, program names)\n- Anything the form explicitly asks to include\n\n_Fill in your specifics — this scaffold is from the selected field text._\(footer)"

        // ── Code / logs ─────────────────────────────────────────────────────
        case "diagnose_latest_error":
            let errors = matching(lines(text), any: ["error", "failed", "exception", "fatal", "assert"], limit: 8)
            let last = errors.last ?? "(no explicit error line visible)"
            return "# Latest Error\n\n**Most recent error line:**\n> \(last)\n\n**All visible error lines:**\n\(bullets(errors, empty: "No error lines visible."))\n\n**Next check:** reproduce with verbose output, then look at the first error in the chain — later ones are usually fallout.\(footer)"

        case "summarize_log_failure":
            let errors = matching(lines(text), any: ["error", "failed", "fatal", "exception"], limit: 10)
            return "# Log Failure Summary\n\n- Visible error lines: \(errors.count)\n- First: \(errors.first ?? "—")\n- Last: \(errors.last ?? "—")\n\n\(bullets(Array(errors.prefix(6)), empty: "No failure lines visible."))\(footer)"

        case "generate_next_agent_prompt":
            let errors = matching(lines(text), any: ["error", "failed", "fatal", "fail case", "exception"], limit: 5)
            let files = Array(Set(regexMatches(#"[A-Za-z0-9_/]+\.(swift|py|ts|js|rs|m|h|log|md)"#, in: text))).prefix(6)
            return """
            # Next Agent Prompt

            ```
            Fix the following failure.

            Symptoms:
            \(errors.isEmpty ? "- (paste the failing output here)" : errors.map { "- \($0)" }.joined(separator: "\n"))

            Files involved:
            \(files.isEmpty ? "- (unknown — find via the error trace)" : files.map { "- \($0)" }.joined(separator: "\n"))

            Requirements:
            - Find the root cause before changing code.
            - Add or update a test that fails before the fix and passes after.
            - Report exactly what was verified and how.
            ```
            \(footer)
            """

        case "create_regression_test_prompt":
            let errors = matching(lines(text), any: ["error", "failed", "fail case", "exception"], limit: 4)
            return "# Regression Test Prompt\n\n```\nWrite a regression test for this failure:\n\(errors.map { "- \($0)" }.joined(separator: "\n"))\n\nThe test must fail on the current behavior and pass once fixed. Keep it deterministic — no timing or network dependence.\n```\(footer)"

        case "identify_repeated_log_pattern":
            var counts: [String: Int] = [:]
            for line in lines(text) {
                let normalized = line.replacingOccurrences(of: #"[0-9]+"#, with: "N", options: .regularExpression)
                counts[String(normalized.prefix(120)), default: 0] += 1
            }
            let repeated = counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(6)
            let rows = repeated.map { "- ×\($0.value): \($0.key)" }
            return "# Repeated Log Patterns\n\n\(bullets(rows, empty: "No repeated lines in the visible log."))\(footer)"

        case "map_log_to_subsystem":
            let tags = regexMatches(#"\[[A-Za-z0-9_.]+\]"#, in: text, limit: 200)
            var counts: [String: Int] = [:]
            for t in tags { counts[t, default: 0] += 1 }
            let top = counts.sorted { $0.value > $1.value }.prefix(8).map { "- \($0.key): \($0.value) lines" }
            return "# Log Subsystems\n\n\(bullets(top, empty: "No [Tag]-style subsystem markers visible."))\(footer)"

        case "explain_recent_code_file":
            let funcs = regexMatches(#"func\s+[A-Za-z0-9_]+"#, in: text, limit: 15)
            let types = regexMatches(#"(class|struct|enum|protocol)\s+[A-Za-z0-9_]+"#, in: text, limit: 10)
            return "# Code Overview\n\n**Types:**\n\(bullets(types, empty: "No type declarations visible."))\n\n**Functions:**\n\(bullets(funcs, empty: "No function declarations visible."))\(footer)"

        case "find_unverified_claims_in_agent_response":
            let claims = sentences(text).filter { s in
                let lower = s.lowercased()
                let claimsDone = ["done", "complete", "fixed", "passes", "works", "implemented", "verified", "all tests"].contains { lower.contains($0) }
                let hasEvidence = ["exit code", "output", "log", "ran ", "result=", "passed="].contains { lower.contains($0) }
                return claimsDone && !hasEvidence
            }.prefix(8).map { String($0.prefix(180)) }
            return "# Unverified Claims\n\n\(bullets(Array(claims), empty: "Every completion claim in the visible text carries some evidence."))\n\n_Ask for logs/output for each flagged claim before trusting it._\(footer)"

        case "make_next_ticket":
            let errors = matching(lines(text), any: ["error", "failed", "exception"], limit: 3)
            return "# Draft Ticket\n\n**Title:** \(errors.first.map { String($0.prefix(80)) } ?? "Investigate visible failure")\n\n**Body:**\n- Symptom: \(errors.first ?? "(describe)")\n- Where seen: visible log/output\n- Repro: (fill in)\n- Expected vs actual: (fill in)\(footer)"

        // ── Research ────────────────────────────────────────────────────────
        case "extract_key_claims":
            let claims = sentences(text).filter { s in
                s.rangeOfCharacter(from: .decimalDigits) != nil || s.contains("%") || s.lowercased().contains(" is ") || s.lowercased().contains(" will ")
            }.prefix(8).map { String($0.prefix(200)) }
            return "# Key Claims\n\n\(bullets(Array(claims), empty: "No factual claims found in the visible text."))\(footer)"

        // ── Writing / communication (selection transforms) ──────────────────
        case "tighten_selected_text":
            let tightened = tighten(text)
            return "# Tightened\n\n\(tightened)\n\n_\(text.count) → \(tightened.count) chars._\(footer)"

        case "make_more_professional":
            return "# Professional Version\n\n\(professionalize(text))\(footer)"

        case "make_less_ai_sounding":
            return "# De-AI'd Version\n\n\(deAI(text))\(footer)"

        case "convert_notes_to_message":
            let points = lines(text).prefix(8).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ")) }
            return "# Message Draft\n\nHi,\n\n\(points.joined(separator: " "))\n\nLet me know if you need anything else.\(footer)"

        case "turn_notes_into_checklist":
            let items = lines(text).prefix(15).map { "- [ ] \($0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ")))" }
            return "# Checklist\n\n\(items.joined(separator: "\n"))\(footer)"

        case "extract_open_questions":
            let questions = sentences(text).filter { sentence in
                sentence.contains("?") || ["how ", "what ", "when ", "should we", "unclear", "tbd", "to decide"].contains { kw in sentence.lowercased().contains(kw) }
            }.prefix(10).map { String($0.prefix(180)) }
            return "# Open Questions\n\n\(bullets(Array(questions), empty: "No open questions found in the selection."))\(footer)"

        case "draft_message_to_prospective_tenant":
            return "# Tenant Message Draft\n\nHi,\n\nThanks for your interest. Regarding:\n> \(String(text.prefix(200)))\n\n[Confirm availability / viewing time / next step]\n\nBest,\(footer)"

        // ── Generic fallthrough (summarize family handled elsewhere) ───────
        default:
            let summary = CapabilityExecutor.deterministicSummary(from: text)
            return "# \(action.resultCardTitle)\n\n\(summary)\(footer)"
        }
    }

    // MARK: Metadata notes (no content claim — and the card says so)

    static func metadataNote(action: WorkflowAction, signals: WorkflowSignals) -> String {
        let basis = "\n\n_Built from the page title and open tabs only — not the page contents._"
        switch action.id {
        case "compare_open_tabs", "create_decision_table":
            print("[OutputFallback] id=\(action.id) fallback=follow_up_card reason=metadata_too_thin")
            return "# I need page details to compare these rentals\n\nI can see the tab titles, but not rent, bedrooms, distance, utilities, parking, or lease terms.\(basis)"

        case "make_research_brief":
            let sources = signals.tabTitles.prefix(8).map { "- \($0)" }.joined(separator: "\n")
            return "# Research Brief\n\n**Topic:** \(signals.windowTitle)\n\n**Sources open now:**\n\(sources.isEmpty ? "- (current page only)" : sources)\n\n**Questions to answer:**\n- \n- \n\n**Findings:**\n- \(basis)"

        case "identify_next_research_step":
            let n = signals.tabTitles.count
            let suggestion: String
            if n >= 4 { suggestion = "You have \(n) tabs open — consolidate: save this session, then eliminate options that fail your main criterion." }
            else if n >= 2 { suggestion = "Compare the \(n) open sources directly — build the decision table next." }
            else { suggestion = "Single source open — find one independent source to verify the key claims before deciding." }
            return "# Next Research Step\n\n\(suggestion)\(basis)"

        case "list_missing_form_info":
            return "# Info This Page May Need\n\n\(formPageInfoList(title: signals.windowTitle, host: signals.urlHost))\n\n_Based on the page title \u{201C}\(signals.windowTitle.prefix(60))\u{201D} — not the live form contents. Capture the page for a field-level check._"

        case "make_application_checklist":
            return """
            # Application Checklist

            - [ ] Confirm eligibility requirements
            - [ ] Gather identity documents (SIN, ID)
            - [ ] Gather financial documents (income, tax return, bank info)
            - [ ] Complete each section: program → personal → financial
            - [ ] Review for consistency before submitting
            - [ ] Save/print the confirmation page
            - [ ] Note the deadline and follow-up dates
            \(basis)
            """

        case "create_tenant_move_in_checklist":
            return """
            # Move-In Checklist

            - [ ] Signed copy of the agreement received
            - [ ] Deposit amount + receipt confirmed
            - [ ] Move-in inspection photos taken
            - [ ] Utilities transferred or confirmed included
            - [ ] Keys/fobs received and tested
            - [ ] Landlord contact info saved
            - [ ] Renter's insurance arranged
            - [ ] First rent payment date noted
            \(basis)
            """

        default:
            return "# \(action.resultCardTitle)\n\n\(action.shortDescription)\(basis)"
        }
    }

    // MARK: Helpers

    static func formFieldExplanation(for fieldText: String) -> String {
        let lower = fieldText.lowercased()
        let known: [(String, String)] = [
            ("sin", "Your Social Insurance Number — 9 digits. Required for government financial applications; never share it outside official forms."),
            ("program", "The academic program you're applying for or enrolled in. Use the exact name/code from your offer or enrolment letter."),
            ("income", "Usually your gross (pre-tax) income for the requested period. Check whether it asks for your income, your parents', or both."),
            ("financial", "Financial details — income, savings, assets. Have your tax return and bank statements at hand."),
            ("current situation", "Your present enrolment/employment/living status. Answer as of today, not your expected future status."),
            ("marital", "Your legal marital status as of the date specified on the form."),
            ("dependent", "Whether someone relies on you financially, or whether you are claimed as a dependant — read the form's own definition."),
            ("address", "Usually your permanent address, not a temporary school-term address — check which one the field asks for.")
        ]
        for (key, explanation) in known where lower.contains(key) {
            return explanation
        }
        return "This field asks for: \u{201C}\(fieldText.prefix(120))\u{201D}. Answer exactly what is asked, keep formats consistent with earlier pages, and check for an info icon next to the field for the official definition."
    }

    static func formPageInfoList(title: String, host: String) -> String {
        let lower = title.lowercased()
        if lower.contains("financial") {
            return "- Last year's income (and possibly your parents'/spouse's)\n- Tax return / Notice of Assessment\n- Bank account details\n- Savings, assets, investments\n- Scholarships or other aid amounts"
        }
        if lower.contains("personal") {
            return "- Full legal name (matching ID)\n- Date of birth\n- SIN\n- Address and contact info\n- Citizenship / residency status"
        }
        if lower.contains("program") {
            return "- School / institution name\n- Program name and code\n- Study period dates\n- Course load (full-time / part-time)"
        }
        if lower.contains("situation") {
            return "- Current enrolment status\n- Employment status\n- Living arrangement (with parents / rental)\n- Marital status\n- Dependants"
        }
        return "- Identity details (name, DOB, ID numbers)\n- Contact information\n- Supporting document numbers\n- Dates relevant to \(title.isEmpty ? "this application" : "\u{201C}\(title.prefix(50))\u{201D}")"
    }

    static func tighten(_ text: String) -> String {
        var out = text
        let filler = [" very ", " really ", " just ", " actually ", " basically ",
                      " quite ", " simply ", " in order to ", " that being said, ",
                      " it should be noted that ", " needless to say, "]
        let replacements = [" in order to ": " to ", " that being said, ": " ", " it should be noted that ": " ", " needless to say, ": " "]
        for (k, v) in replacements { out = out.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        for f in filler where !replacements.keys.contains(f) {
            out = out.replacingOccurrences(of: f, with: " ", options: .caseInsensitive)
        }
        return out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func professionalize(_ text: String) -> String {
        var out = text
        let map = ["gonna": "going to", "wanna": "want to", "kinda": "somewhat",
                   "stuff": "items", "a lot of": "many", "thing": "matter",
                   "asap": "as soon as possible", "btw": "for reference",
                   "can't": "cannot", "won't": "will not", "don't": "do not",
                   "hey": "Hello", "yeah": "yes"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        return out
    }

    static func deAI(_ text: String) -> String {
        var out = text
        let aiPhrases = ["Furthermore, ", "Moreover, ", "In conclusion, ",
                         "It's important to note that ", "It is important to note that ",
                         "Certainly! ", "Overall, ", "In summary, ", "delve into",
                         "I hope this helps", "Additionally, ", "It's worth noting that "]
        for phrase in aiPhrases {
            out = out.replacingOccurrences(of: phrase, with: "", options: .caseInsensitive)
        }
        out = out.replacingOccurrences(of: "delve", with: "dig", options: .caseInsensitive)
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
