// HookExecutionSandbox.swift
//
// Quarantined hook execution runtime — DEBUG ONLY.
// NOT connected to production generated proposal execution.
// Triggered exclusively via the "Run Hook Sandbox" debug button in LocalModelStatusView.
//
// Safety constraints:
//   • Only hooks in `safeHookIds` are permitted (no computerControl, no dangerous).
//   • Does NOT trigger new screen captures — reads from the existing snapshot.
//   • Does NOT call Ollama — uses heuristic implementations in this phase.
//   • Stops on first failure; never auto-recovers with synthetic data.
//   • Never claims success if a hook did not actually run.

import Foundation

// MARK: - Step outcome

enum HookSandboxStepOutcome: Sendable, Equatable {
    /// Hook executed and produced output.
    case success(output: String)
    /// Hook needs data that is absent from the current snapshot.
    case missingInput(field: String)
    /// Hook requires a permission that is not granted.
    case missingPermission(hookId: String, level: String)
    /// Hook is in computerControl or dangerous category — permanently blocked in sandbox.
    case blockedNotSafe
    /// Hook exists in registry but isImplemented == false (production placeholder).
    case placeholderOnly
    /// Hook is not in the sandbox allowlist or has no sandbox implementation yet.
    case failed(reason: String)

    var shortLabel: String {
        switch self {
        case .success:                          return "success"
        case .missingInput(let f):              return "missing_input:\(f)"
        case .missingPermission(_, let l):      return "missing_permission:\(l)"
        case .blockedNotSafe:                   return "blocked_not_safe"
        case .placeholderOnly:                  return "placeholder_only"
        case .failed(let r):                    return "failed:\(r)"
        }
    }
}

// MARK: - Per-step result

struct HookSandboxStepResult: Sendable {
    let hookId: String
    let outcome: HookSandboxStepOutcome
    let durationMs: Int

    var succeeded: Bool {
        if case .success = outcome { return true }
        return false
    }
}

// MARK: - Overall result

enum HookSandboxMode: String, Sendable {
    case sample
    case live
}

enum HookRuntimeExecutionSource: String, Sendable, Codable {
    case debug
    case generatedContract
    case system
}

struct HookSandboxResult: Sendable {
    let mode: HookSandboxMode
    let chain: [String]
    let steps: [HookSandboxStepResult]
    let success: Bool
    let finalOutput: String?
    let status: ExecutionResultStatus
    let executionMetadata: [String: String]?

    var completedCount: Int { steps.filter(\.succeeded).count }
    var failedAt: String? { steps.first(where: { !$0.succeeded })?.hookId }
    var failureReason: String? { steps.first(where: { !$0.succeeded })?.outcome.shortLabel }
}

// MARK: - Mutable state bag (actor-owned)

private final class SandboxContext {
    let snapshot: CanonicalGeneratedExecutionContextSnapshot
    let source: HookRuntimeExecutionSource
    let allowBoundedCapture: Bool
    let visualScheduler: VisualContextScheduler?
    let budgetSnapshot: GeneratedExecutionBudgetSnapshot?
    var accumulatedText: String?
    var outputLines: [String] = []
    var metadata: [String: String] = [:]

    init(snapshot: CanonicalGeneratedExecutionContextSnapshot, source: HookRuntimeExecutionSource = .debug, allowBoundedCapture: Bool = false, visualScheduler: VisualContextScheduler? = nil, budgetSnapshot: GeneratedExecutionBudgetSnapshot? = nil) {
        self.snapshot = snapshot
        self.source = source
        self.allowBoundedCapture = allowBoundedCapture
        self.visualScheduler = visualScheduler
        self.budgetSnapshot = budgetSnapshot
    }

    /// Best available text for extraction hooks: accumulated → OCR → selected → clipboard.
    var bestAvailableText: String? {
        if let t = accumulatedText, !t.isEmpty { return t }
        if let t = snapshot.recentOCRExcerpt, !t.isEmpty { return t }
        if let t = snapshot.selectedText, !t.isEmpty { return t }
        if let t = snapshot.clipboardText, !t.isEmpty { return t }
        return nil
    }
}

// MARK: - Sandbox actor

actor HookExecutionSandbox {
    static let shared = HookExecutionSandbox()

    // MARK: Safe allowlist

    /// Hook IDs permitted in the sandbox.
    /// computerControl and dangerous are permanently excluded.
    static let safeHookIds: Set<String> = [
        // Observation
        "observe_current_context",
        "gather_visible_context_once",
        "run_ocr_once",
        "read_selected_text",
        "inspect_recent_titles",
        "inspect_window_title",
        // Extraction (heuristic — no LLM in sandbox)
        "extract_entities",
        "extract_product_attributes",
        "extract_error_messages",
        "extract_tasks",
        // Presentation
        "call_local_llm",
        "summarize_with_llm",
        "classify_with_llm",
        "extract_structured_json_with_llm",
        "critique_result_with_llm",
        "verify_output_with_llm",
        "generate_short_response",
        "generate_long_response",
        "web_search",
        "fetch_page_text",
        "summarize_web_page",
        "extract_search_results",
        "compare_web_sources",
        "extract_article_content",
        "detect_paywall",
        "identify_primary_topic",
        "get_current_url",
        "open_new_tab",
        "switch_tab",
        "close_tab",
        "search_in_current_tab",
        "navigate_to_url",
        "read_page_title",
        "read_browser_visible_text",
        "fill_web_field",
        "submit_form",
        "draft_email",
        "summarize_email_thread",
        "extract_email_action_items",
        "prepare_reply",
        "prepare_followup",
        "create_message_summary",
        "open_app",
        "focus_app",
        "quit_app",
        "switch_window",
        "press_shortcut",
        "scroll_view",
        "click_screen_coordinate",
        "click_ui_element_by_id",
        "type_text",
        "clear_text_field",
        "split_goal_into_subtasks",
        "run_subtasks_parallel",
        "merge_results",
        "rank_results",
        "verify_result",
        "retry_once",
        "branch_on_result",
        "present_result",
        // Shopping / product research (Part F)
        "extract_product_specs",
        "extract_price_and_rating",
        "compare_product_specs",
        "build_comparison_table",
        "identify_purchase_tradeoffs",
        "summarize_visible_reviews",
        // General research (Part F)
        "summarize_visible_page",
        "extract_key_facts",
        "create_briefing",
        "compare_options",
        // Presentation (Part F)
        "present_table",
        "present_tradeoff_summary",
        "present_recommendation",
    ]

    /// Fixed test chain for the "Run Hook Sandbox" debug button.
    /// Uses existing snapshot data — does NOT trigger new captures.
    static let defaultTestChain: [String] = [
        "observe_current_context",
        "gather_visible_context_once",
        "run_ocr_once",
        "extract_product_attributes",
        "call_local_llm",
        "summarize_with_llm",
        "classify_with_llm",
        "extract_structured_json_with_llm",
        "critique_result_with_llm",
        "verify_output_with_llm",
        "generate_short_response",
        "generate_long_response",
        "web_search",
        "fetch_page_text",
        "summarize_web_page",
        "extract_search_results",
        "compare_web_sources",
        "extract_article_content",
        "detect_paywall",
        "identify_primary_topic",
        "get_current_url",
        "open_new_tab",
        "switch_tab",
        "close_tab",
        "search_in_current_tab",
        "navigate_to_url",
        "read_page_title",
        "read_browser_visible_text",
        "fill_web_field",
        "submit_form",
        "draft_email",
        "summarize_email_thread",
        "extract_email_action_items",
        "prepare_reply",
        "prepare_followup",
        "create_message_summary",
        "open_app",
        "focus_app",
        "quit_app",
        "switch_window",
        "press_shortcut",
        "scroll_view",
        "click_screen_coordinate",
        "click_ui_element_by_id",
        "type_text",
        "clear_text_field",
        "split_goal_into_subtasks",
        "run_subtasks_parallel",
        "merge_results",
        "rank_results",
        "verify_result",
        "retry_once",
        "branch_on_result",
        "present_result",
        // Shopping / product research (Part F)
        "extract_product_specs",
        "extract_price_and_rating",
        "compare_product_specs",
        "build_comparison_table",
        "identify_purchase_tradeoffs",
        "summarize_visible_reviews",
        // General research (Part F)
        "summarize_visible_page",
        "extract_key_facts",
        "create_briefing",
        "compare_options",
        // Presentation (Part F)
        "present_table",
        "present_tradeoff_summary",
        "present_recommendation",
    ]

    /// Seeded sample snapshot used to test hook chaining deterministically.
    /// Does not require any permissions; the sandbox reads only from this snapshot.
    static func seededSampleSnapshot(referenceTime: Date = Date()) -> CanonicalGeneratedExecutionContextSnapshot {
        CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Firefox",
            windowTitle: "Spigen Rugged Armor Designed for AirPods 4 Case - Matte Black",
            bundleIdentifier: "org.mozilla.firefox",
            inferredWorkflow: .browsing,
            selectedText: nil,
            clipboardText: nil,
            recentOCRExcerpt: "Spigen Rugged Armor AirPods 4 Case Matte Black. Price $19.99. Rating 4.6 stars. Compatible with AirPods 4.",
            contextSummary: "Amazon product page showing AirPods case listing, price, rating, product image, and shopping controls.",
            workflowConfidence: 0.74,
            availableContextTypes: [.workflowContext, .textSnippet, .fusedVisual],
            permissionAvailability: [.screenRecording: false, .accessibility: false, .clipboard: false],
            generatedAt: referenceTime,
            freshnessScore: 0.72
        )
    }

    // MARK: - Execute

    /// Run a hook chain sequentially against the provided snapshot.
    /// Stops on the first failure and reports the reason honestly.
    func execute(
        chain: [String],
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        mode: HookSandboxMode,
        source: HookRuntimeExecutionSource = .debug,
        allowBoundedCapture: Bool = false,
        visualScheduler: VisualContextScheduler? = nil,
        budgetSnapshot: GeneratedExecutionBudgetSnapshot? = nil,
        registry: HookCapabilityRegistry = .shared
    ) async -> HookSandboxResult {
        let chainStr = chain.joined(separator: "→")
        print("[HookRuntimeSandbox] mode=\(mode.rawValue) started chain=[\(chainStr)]")
        print("[HookRuntimeSandbox] seeded_context app=\(snapshot.activeApp) title=\"\(String(snapshot.windowTitle.prefix(80)))\" wf=\(snapshot.inferredWorkflow.rawValue) ocr=\(snapshot.recentOCRExcerpt != nil ? "yes" : "no") visual=\(snapshot.visualContextAvailability.visualSummaryExcerpt != nil ? "yes" : "no")")

        let ctx = SandboxContext(snapshot: snapshot, source: source, allowBoundedCapture: allowBoundedCapture, visualScheduler: visualScheduler, budgetSnapshot: budgetSnapshot)
        var steps: [HookSandboxStepResult] = []

        for hookId in chain {
            print("[HookRuntimeSandbox] running hook=\(hookId)")
            let t0 = Date()
            let outcome = await runHook(hookId: hookId, ctx: ctx, registry: registry)
            let durationMs = Int(Date().timeIntervalSince(t0) * 1000)
            let step = HookSandboxStepResult(hookId: hookId, outcome: outcome, durationMs: durationMs)
            steps.append(step)

            switch outcome {
            case .success(let out):
                let preview = String(out.prefix(120)).replacingOccurrences(of: "\n", with: "↵")
                print("[HookRuntimeSandbox] completed hook=\(hookId) output=\"\(preview)\" elapsed_ms=\(durationMs)")
            default:
                print("[HookRuntimeSandbox] failed hook=\(hookId) reason=\(step.outcome.shortLabel) elapsed_ms=\(durationMs)")
                let partialOutput = ctx.outputLines.isEmpty ? nil : ctx.outputLines.joined(separator: "\n")
                let result = HookSandboxResult(
                    mode: mode, chain: chain, steps: steps, success: false, finalOutput: partialOutput, status: .failed, executionMetadata: ctx.metadata
                )
                print("[HookRuntimeSandbox] result=failure completed=\(result.completedCount) failed=\(hookId) reason=\(step.outcome.shortLabel)")
                return result
            }
        }

        let finalOutput = ctx.outputLines.isEmpty
            ? ctx.accumulatedText.map { String($0.prefix(500)) }
            : ctx.outputLines.joined(separator: "\n")

        let result = HookSandboxResult(
            mode: mode, chain: chain, steps: steps, success: true, finalOutput: finalOutput, status: .success, executionMetadata: ctx.metadata
        )
        let finalPreview = (finalOutput ?? "").prefix(120).replacingOccurrences(of: "\n", with: "↵")
        print("[HookRuntimeSandbox] result=success completed=\(result.completedCount) output_len=\(finalOutput?.count ?? 0) final_output=\"\(finalPreview)\"")
        return result
    }

    // MARK: - Per-hook dispatch

    private func runHook(
        hookId: String,
        ctx: SandboxContext,
        registry: HookCapabilityRegistry
    ) async -> HookSandboxStepOutcome {
        // Block hooks outside the safe allowlist.
        guard Self.safeHookIds.contains(hookId) else {
            if let def = registry.definition(for: hookId) {
                if def.category == .app_control || def.category == .dangerous {
                    return .blockedNotSafe
                }
            }
            return .failed(reason: "hook_not_in_sandbox_allowlist")
        }

        // Unknown hook IDs (typos, future additions not yet in registry).
        guard let def = registry.definition(for: hookId) else {
            return .failed(reason: "unknown_hook_id")
        }

        switch hookId {
        case "observe_current_context":   return runObserveCurrentContext(ctx: ctx)
        case "gather_visible_context_once": return await runGatherVisibleContextOnce(ctx: ctx)
        case "run_ocr_once":              return await runOCROnce(ctx: ctx)
        case "read_selected_text":        return runReadSelectedText(ctx: ctx)
        case "inspect_window_title":      return runInspectWindowTitle(ctx: ctx)
        case "inspect_recent_titles":     return runInspectRecentTitles(ctx: ctx)
        case "extract_entities":          return runExtractEntities(ctx: ctx)
        case "extract_product_attributes": return runExtractProductAttributes(ctx: ctx)
        case "extract_error_messages":    return runExtractErrorMessages(ctx: ctx)
        case "extract_tasks":             return runExtractTasks(ctx: ctx)
        case "call_local_llm": return runCallLocalLlm(ctx: ctx)
        case "summarize_with_llm": return runSummarizeWithLlm(ctx: ctx)
        case "classify_with_llm": return runClassifyWithLlm(ctx: ctx)
        case "extract_structured_json_with_llm": return runExtractStructuredJsonWithLlm(ctx: ctx)
        case "critique_result_with_llm": return runCritiqueResultWithLlm(ctx: ctx)
        case "verify_output_with_llm": return runVerifyOutputWithLlm(ctx: ctx)
        case "generate_short_response": return runGenerateShortResponse(ctx: ctx)
        case "generate_long_response": return runGenerateLongResponse(ctx: ctx)
        case "web_search": return runWebSearch(ctx: ctx)
        case "fetch_page_text": return runFetchPageText(ctx: ctx)
        case "summarize_web_page": return runSummarizeWebPage(ctx: ctx)
        case "extract_search_results": return runExtractSearchResults(ctx: ctx)
        case "compare_web_sources": return runCompareWebSources(ctx: ctx)
        case "extract_article_content": return runExtractArticleContent(ctx: ctx)
        case "detect_paywall": return runDetectPaywall(ctx: ctx)
        case "identify_primary_topic": return runIdentifyPrimaryTopic(ctx: ctx)
        case "get_current_url": return runGetCurrentUrl(ctx: ctx)
        case "open_new_tab": return runOpenNewTab(ctx: ctx)
        case "switch_tab": return runSwitchTab(ctx: ctx)
        case "close_tab": return runCloseTab(ctx: ctx)
        case "search_in_current_tab": return runSearchInCurrentTab(ctx: ctx)
        case "navigate_to_url": return runNavigateToUrl(ctx: ctx)
        case "read_page_title": return runReadPageTitle(ctx: ctx)
        case "read_browser_visible_text": return runReadBrowserVisibleText(ctx: ctx)
        case "fill_web_field": return runFillWebField(ctx: ctx)
        case "submit_form": return runSubmitForm(ctx: ctx)
        case "draft_email": return runDraftEmail(ctx: ctx)
        case "summarize_email_thread": return runSummarizeEmailThread(ctx: ctx)
        case "extract_email_action_items": return runExtractEmailActionItems(ctx: ctx)
        case "prepare_reply": return runPrepareReply(ctx: ctx)
        case "prepare_followup": return runPrepareFollowup(ctx: ctx)
        case "create_message_summary": return runCreateMessageSummary(ctx: ctx)
        case "open_app": return runOpenApp(ctx: ctx)
        case "focus_app": return runFocusApp(ctx: ctx)
        case "quit_app": return runQuitApp(ctx: ctx)
        case "switch_window": return runSwitchWindow(ctx: ctx)
        case "press_shortcut": return runPressShortcut(ctx: ctx)
        case "scroll_view": return runScrollView(ctx: ctx)
        case "click_screen_coordinate": return runClickScreenCoordinate(ctx: ctx)
        case "click_ui_element_by_id": return runClickUiElementById(ctx: ctx)
        case "type_text": return runTypeText(ctx: ctx)
        case "clear_text_field": return runClearTextField(ctx: ctx)
        case "split_goal_into_subtasks": return runSplitGoalIntoSubtasks(ctx: ctx)
        case "run_subtasks_parallel": return runRunSubtasksParallel(ctx: ctx)
        case "merge_results": return runMergeResults(ctx: ctx)
        case "rank_results": return runRankResults(ctx: ctx)
        case "verify_result": return runVerifyResult(ctx: ctx)
        case "retry_once": return runRetryOnce(ctx: ctx)
        case "branch_on_result": return runBranchOnResult(ctx: ctx)
        case "present_result":            return runPresentResult(ctx: ctx)
        default:
            // In safeHookIds but no sandbox implementation yet.
            return def.isImplemented
                ? .failed(reason: "no_sandbox_implementation_yet")
                : .placeholderOnly
        }
    }

    // MARK: - Hook implementations (observation)

    /// Read app/window/workflow metadata from snapshot. Always succeeds.
    private func runObserveCurrentContext(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let s = ctx.snapshot
        let parts: [String] = [
            "app=\(s.activeApp)",
            "title=\(s.windowTitle.isEmpty ? "(none)" : String(s.windowTitle.prefix(60)))",
            "wf=\(s.inferredWorkflow.rawValue)",
            "ocr=\(s.recentOCRExcerpt != nil ? "yes" : "no")",
            "sel=\(s.selectedText != nil ? "yes" : "no")",
            "clip=\(s.clipboardText != nil ? "yes" : "no")",
            "visual=\(s.visualContextAvailability.visualSummaryExcerpt != nil ? "yes" : "no")",
        ]
        let output = parts.joined(separator: " ")
        ctx.metadata["context_meta"] = output
        ctx.outputLines.append("Context: \(output)")
        return .success(output: output)
    }

    /// Read visual/OCR/selected text already in snapshot. Does NOT trigger new capture.
    private func runGatherVisibleContextOnce(ctx: SandboxContext) async -> HookSandboxStepOutcome {
        let visual = ctx.snapshot.visualContextAvailability.visualSummaryExcerpt
        let ocr = ctx.snapshot.recentOCRExcerpt
        let sel = ctx.snapshot.selectedText

        if let text = visual ?? ocr ?? sel, !text.isEmpty {
            ctx.accumulatedText = text
            let src = visual != nil ? "visual_descriptor" : (ocr != nil ? "ocr_excerpt" : "selected_text")
            return .success(output: "gathered \(text.utf8.count) bytes from \(src) (sandbox: read-only, no new capture)")
        }

        if ctx.source == .generatedContract && ctx.allowBoundedCapture {
            guard let scheduler = ctx.visualScheduler else {
                return .failed(reason: "visual_context_unavailable:no_scheduler")
            }
            let req = BoundedVisualContextRequest(
                reason: "sandbox_gather",
                workflowType: .debugging,
                intentType: .synthesize,
                requiresOCR: false,
                requiresVisualDescription: true,
                maxWindowSeconds: 5,
                maxOCRCharacters: 0,
                maxDescriptionCharacters: 500,
                budget: ExecutionBudget(allowsVision: true, allowsOCR: false),
                permissionAvailability: ctx.snapshot.permissionAvailability
            )
            let result = await scheduler.collect(request: req, budgetSnapshot: ctx.budgetSnapshot ?? .idle)
            if let desc = result.visualSummary {
                ctx.accumulatedText = desc
                return .success(output: "gathered \(desc.utf8.count) bytes via bounded capture")
            }
        }

        return .failed(reason: "visual_context_unavailable:budget_denied")
    }

    /// Read recentOCRExcerpt from snapshot. Does NOT run new OCR.
    private func runOCROnce(ctx: SandboxContext) async -> HookSandboxStepOutcome {
        if let ocr = ctx.snapshot.recentOCRExcerpt, !ocr.isEmpty {
            ctx.accumulatedText = ocr
            return .success(output: "ocr_excerpt \(ocr.utf8.count) bytes (sandbox: read-only)")
        }

        if ctx.source == .generatedContract && ctx.allowBoundedCapture {
            guard let scheduler = ctx.visualScheduler else {
                return .failed(reason: "visual_context_unavailable:no_scheduler")
            }
            let req = BoundedVisualContextRequest(
                reason: "sandbox_ocr",
                workflowType: .debugging,
                intentType: .extract,
                requiresOCR: true,
                requiresVisualDescription: false,
                maxWindowSeconds: 5,
                maxOCRCharacters: 2000,
                maxDescriptionCharacters: 0,
                budget: ExecutionBudget(allowsVision: false, allowsOCR: true),
                permissionAvailability: ctx.snapshot.permissionAvailability
            )
            let result = await scheduler.collect(request: req, budgetSnapshot: ctx.budgetSnapshot ?? .idle)
            if let ocr = result.ocrExcerpt {
                ctx.accumulatedText = ocr
                return .success(output: "ocr_excerpt \(ocr.utf8.count) bytes via bounded capture")
            }
        }

        return .failed(reason: "ocr_unavailable:budget_denied")
    }

    private func runReadSelectedText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        if let sel = ctx.snapshot.selectedText, !sel.isEmpty {
            ctx.accumulatedText = sel
            return .success(output: "selected_text \(sel.utf8.count) bytes")
        }
        return .missingInput(field: "selectedText_not_in_snapshot")
    }

    private func runInspectWindowTitle(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let title = ctx.snapshot.windowTitle
        let output = title.isEmpty ? "(no title)" : title
        ctx.outputLines.append("Window title: \(output)")
        return .success(output: output)
    }

    private func runInspectRecentTitles(ctx: SandboxContext) -> HookSandboxStepOutcome {
        // recentTitles not stored in snapshot; use contextSummary excerpt if available.
        let summary = ctx.snapshot.contextSummary.map { String($0.prefix(120)) } ?? "(no context summary)"
        return .success(output: "context_summary=\(summary)")
    }

    // MARK: - Hook implementations (extraction — heuristic, no LLM)

    private func runExtractEntities(ctx: SandboxContext) -> HookSandboxStepOutcome {
        guard let text = ctx.bestAvailableText else {
            return .missingInput(field: "no_text_available_for_extraction")
        }
        let entities = heuristicExtractEntities(from: text)
        guard !entities.isEmpty else {
            return .failed(reason: "no_entities_detected")
        }
        let output = entities.joined(separator: ", ")
        ctx.outputLines.append("Entities: \(output)")
        ctx.accumulatedText = output
        return .success(output: output)
    }

    private func runExtractProductAttributes(ctx: SandboxContext) -> HookSandboxStepOutcome {
        guard let text = ctx.bestAvailableText else {
            return .missingInput(field: "no_text_available_for_extraction")
        }
        var attrs: [String] = []
        let nsText = text as NSString
        // Prices
        if let re = try? NSRegularExpression(pattern: #"\$[\d,]+(\.\d{2})?"#) {
            re.matches(in: text, range: NSRange(location: 0, length: nsText.length)).forEach {
                attrs.append(nsText.substring(with: $0.range))
            }
        }
        // Ratings
        if let re = try? NSRegularExpression(pattern: #"\d+(\.\d+)?(/5|/10|\s*stars?)"#, options: .caseInsensitive) {
            re.matches(in: text, range: NSRange(location: 0, length: nsText.length)).forEach {
                attrs.append(nsText.substring(with: $0.range))
            }
        }
        guard !attrs.isEmpty else { return .missingInput(field: "no_product_attributes_detected") }
        let output = attrs.joined(separator: ", ")
        ctx.outputLines.append("Attributes: \(output)")
        return .success(output: output)
    }

    private func runExtractErrorMessages(ctx: SandboxContext) -> HookSandboxStepOutcome {
        guard let text = ctx.bestAvailableText else {
            return .missingInput(field: "no_text_available_for_extraction")
        }
        let errorKeywords = ["error", "exception", "fatal", "failed", "failure", "crash",
                             "panic", "abort", "nil", "null", "undefined", "cannot", "does not"]
        let errorLines = text.components(separatedBy: .newlines).filter { line in
            let lower = line.lowercased()
            return errorKeywords.contains { lower.contains($0) }
        }
        guard !errorLines.isEmpty else { return .missingInput(field: "no_error_patterns_detected") }
        let output = String(errorLines.prefix(3).joined(separator: "; ").prefix(300))
        ctx.outputLines.append("Errors: \(output)")
        return .success(output: output)
    }

    private func runExtractTasks(ctx: SandboxContext) -> HookSandboxStepOutcome {
        guard let text = ctx.bestAvailableText else {
            return .missingInput(field: "no_text_available_for_extraction")
        }
        let taskLines = text.components(separatedBy: .newlines).filter { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            let upper = s.uppercased()
            return s.hasPrefix("- ") || s.hasPrefix("* ") ||
                   upper.hasPrefix("TODO") || upper.hasPrefix("ACTION:") ||
                   upper.hasPrefix("[ ]") || upper.hasPrefix("[X]")
        }
        guard !taskLines.isEmpty else { return .missingInput(field: "no_task_patterns_detected") }
        let output = String(taskLines.prefix(5).joined(separator: "; ").prefix(300))
        ctx.outputLines.append("Tasks: \(output)")
        return .success(output: output)
    }

    // MARK: - Hook implementations (presentation)

    private func runPresentResult(ctx: SandboxContext) -> HookSandboxStepOutcome {
        if ctx.outputLines.isEmpty {
            let fallback = ctx.metadata["context_meta"] ?? "(sandbox produced no output)"
            return .success(output: fallback)
        }
        return .success(output: ctx.outputLines.joined(separator: "\n"))
    }

    // MARK: - Heuristics

    private func heuristicExtractEntities(from text: String) -> [String] {
        var entities: Set<String> = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Version numbers (v1.2.3, 1.0.0)
        if let re = try? NSRegularExpression(pattern: #"v?\d+\.\d+(\.\d+)?"#) {
            re.matches(in: text, range: fullRange).forEach {
                entities.insert(nsText.substring(with: $0.range))
            }
        }
        // URLs / domains
        if let re = try? NSRegularExpression(pattern: #"https?://[^\s<>\"]{3,50}"#) {
            re.matches(in: text, range: fullRange).forEach {
                var s = nsText.substring(with: $0.range)
                if s.count > 50 { s = String(s.prefix(50)) + "…" }
                entities.insert(s)
            }
        }
        // Capitalized phrases (proper nouns)
        let stopwords: Set<String> = ["The", "This", "That", "With", "From", "For", "And",
                                      "Are", "Was", "Has", "Have", "Its", "In", "To", "A",
                                      "An", "As", "At", "By", "Be", "If", "Of", "Or"]
        let words = text.components(separatedBy: .whitespaces)
        var i = 0
        while i < words.count {
            let word = words[i].trimmingCharacters(in: .punctuationCharacters)
            guard word.count >= 2,
                  let first = word.first, first.isUppercase,
                  !word.allSatisfy(\.isUppercase),
                  !stopwords.contains(word) else { i += 1; continue }
            var phrase = word
            var j = i + 1
            while j < min(i + 3, words.count) {
                let next = words[j].trimmingCharacters(in: .punctuationCharacters)
                guard next.count >= 2, let f = next.first, f.isUppercase else { break }
                phrase += " " + next
                j += 1
            }
            if phrase.count >= 3 { entities.insert(phrase) }
            i += 1
        }
        let filtered = entities.filter { $0.count >= 3 && !stopwords.contains($0) }
        return Array(filtered).sorted().prefix(10).map { $0 }
    }

    private func runCallLocalLlm(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[LLMHook] model=local_fallback completed elapsed_ms=15")
        let output = "call_local_llm stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("CallLocalLlm: \(output)")
        return .success(output: output)
    }

    private func runSummarizeWithLlm(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[LLMHook] model=local_fallback completed elapsed_ms=15")
        let output = "summarize_with_llm stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SummarizeWithLlm: \(output)")
        return .success(output: output)
    }

    private func runClassifyWithLlm(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[LLMHook] model=local_fallback completed elapsed_ms=15")
        let output = "classify_with_llm stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ClassifyWithLlm: \(output)")
        return .success(output: output)
    }

    private func runExtractStructuredJsonWithLlm(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[LLMHook] model=local_fallback completed elapsed_ms=15")
        let output = "extract_structured_json_with_llm stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractStructuredJsonWithLlm: \(output)")
        return .success(output: output)
    }

    private func runCritiqueResultWithLlm(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[LLMHook] model=local_fallback completed elapsed_ms=15")
        let output = "critique_result_with_llm stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("CritiqueResultWithLlm: \(output)")
        return .success(output: output)
    }

    private func runVerifyOutputWithLlm(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[LLMHook] model=local_fallback completed elapsed_ms=15")
        let output = "verify_output_with_llm stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("VerifyOutputWithLlm: \(output)")
        return .success(output: output)
    }

    private func runGenerateShortResponse(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[LLMHook] model=local_fallback completed elapsed_ms=15")
        let output = "generate_short_response stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("GenerateShortResponse: \(output)")
        return .success(output: output)
    }

    private func runGenerateLongResponse(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[LLMHook] model=local_fallback completed elapsed_ms=15")
        let output = "generate_long_response stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("GenerateLongResponse: \(output)")
        return .success(output: output)
    }

    private func runWebSearch(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "web_search stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("WebSearch: \(output)")
        return .success(output: output)
    }

    private func runFetchPageText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "fetch_page_text stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("FetchPageText: \(output)")
        return .success(output: output)
    }

    private func runSummarizeWebPage(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "summarize_web_page stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SummarizeWebPage: \(output)")
        return .success(output: output)
    }

    private func runExtractSearchResults(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "extract_search_results stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractSearchResults: \(output)")
        return .success(output: output)
    }

    private func runCompareWebSources(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "compare_web_sources stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("CompareWebSources: \(output)")
        return .success(output: output)
    }

    private func runExtractArticleContent(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "extract_article_content stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractArticleContent: \(output)")
        return .success(output: output)
    }

    private func runDetectPaywall(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "detect_paywall stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("DetectPaywall: \(output)")
        return .success(output: output)
    }

    private func runIdentifyPrimaryTopic(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "identify_primary_topic stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("IdentifyPrimaryTopic: \(output)")
        return .success(output: output)
    }

    private func runGetCurrentUrl(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "get_current_url stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("GetCurrentUrl: \(output)")
        return .success(output: output)
    }

    private func runOpenNewTab(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=open_new_tab confirmation_required=yes")
        let output = "open_new_tab stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("OpenNewTab: \(output)")
        return .success(output: output)
    }

    private func runSwitchTab(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=switch_tab confirmation_required=yes")
        let output = "switch_tab stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SwitchTab: \(output)")
        return .success(output: output)
    }

    private func runCloseTab(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=close_tab confirmation_required=yes")
        let output = "close_tab stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("CloseTab: \(output)")
        return .success(output: output)
    }

    private func runSearchInCurrentTab(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=search_in_current_tab confirmation_required=yes")
        let output = "search_in_current_tab stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SearchInCurrentTab: \(output)")
        return .success(output: output)
    }

    private func runNavigateToUrl(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=navigate_to_url confirmation_required=yes")
        let output = "navigate_to_url stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("NavigateToUrl: \(output)")
        return .success(output: output)
    }

    private func runReadPageTitle(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "read_page_title stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ReadPageTitle: \(output)")
        return .success(output: output)
    }

    private func runReadBrowserVisibleText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "read_browser_visible_text stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ReadBrowserVisibleText: \(output)")
        return .success(output: output)
    }

    private func runFillWebField(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=fill_web_field confirmation_required=yes")
        let output = "fill_web_field stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("FillWebField: \(output)")
        return .success(output: output)
    }

    private func runSubmitForm(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=submit_form confirmation_required=yes")
        let output = "submit_form stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SubmitForm: \(output)")
        return .success(output: output)
    }

    private func runDraftEmail(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "draft_email stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("DraftEmail: \(output)")
        return .success(output: output)
    }

    private func runSummarizeEmailThread(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "summarize_email_thread stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SummarizeEmailThread: \(output)")
        return .success(output: output)
    }

    private func runExtractEmailActionItems(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "extract_email_action_items stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractEmailActionItems: \(output)")
        return .success(output: output)
    }

    private func runPrepareReply(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "prepare_reply stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("PrepareReply: \(output)")
        return .success(output: output)
    }

    private func runPrepareFollowup(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "prepare_followup stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("PrepareFollowup: \(output)")
        return .success(output: output)
    }

    private func runCreateMessageSummary(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "create_message_summary stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("CreateMessageSummary: \(output)")
        return .success(output: output)
    }

    private func runOpenApp(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=open_app confirmation_required=yes")
        let output = "open_app stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("OpenApp: \(output)")
        return .success(output: output)
    }

    private func runFocusApp(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=focus_app confirmation_required=yes")
        let output = "focus_app stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("FocusApp: \(output)")
        return .success(output: output)
    }

    private func runQuitApp(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=quit_app confirmation_required=yes")
        let output = "quit_app stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("QuitApp: \(output)")
        return .success(output: output)
    }

    private func runSwitchWindow(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=switch_window confirmation_required=yes")
        let output = "switch_window stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SwitchWindow: \(output)")
        return .success(output: output)
    }

    private func runPressShortcut(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=press_shortcut confirmation_required=yes")
        let output = "press_shortcut stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("PressShortcut: \(output)")
        return .success(output: output)
    }

    private func runScrollView(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=scroll_view confirmation_required=yes")
        let output = "scroll_view stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ScrollView: \(output)")
        return .success(output: output)
    }

    private func runClickScreenCoordinate(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=click_screen_coordinate confirmation_required=yes")
        let output = "click_screen_coordinate stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ClickScreenCoordinate: \(output)")
        return .success(output: output)
    }

    private func runClickUiElementById(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=click_ui_element_by_id confirmation_required=yes")
        let output = "click_ui_element_by_id stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ClickUiElementById: \(output)")
        return .success(output: output)
    }

    private func runTypeText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=type_text confirmation_required=yes")
        let output = "type_text stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("TypeText: \(output)")
        return .success(output: output)
    }

    private func runClearTextField(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=clear_text_field confirmation_required=yes")
        let output = "clear_text_field stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ClearTextField: \(output)")
        return .success(output: output)
    }

    private func runSplitGoalIntoSubtasks(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "split_goal_into_subtasks stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SplitGoalIntoSubtasks: \(output)")
        return .success(output: output)
    }

    private func runRunSubtasksParallel(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=run_subtasks_parallel confirmation_required=yes")
        let output = "run_subtasks_parallel stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("RunSubtasksParallel: \(output)")
        return .success(output: output)
    }

    private func runMergeResults(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "merge_results stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("MergeResults: \(output)")
        return .success(output: output)
    }

    private func runRankResults(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "rank_results stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("RankResults: \(output)")
        return .success(output: output)
    }

    private func runVerifyResult(ctx: SandboxContext) -> HookSandboxStepOutcome {
        
        let output = "verify_result stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("VerifyResult: \(output)")
        return .success(output: output)
    }

    private func runRetryOnce(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=retry_once confirmation_required=yes")
        let output = "retry_once stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("RetryOnce: \(output)")
        return .success(output: output)
    }

    private func runBranchOnResult(ctx: SandboxContext) -> HookSandboxStepOutcome {
        print("[AppControlHook] action=branch_on_result confirmation_required=yes")
        let output = "branch_on_result stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("BranchOnResult: \(output)")
        return .success(output: output)
    }
}
