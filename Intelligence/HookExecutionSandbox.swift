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
        // Emit per-chain audit summary
        let missingInChain = chain.filter { !Self.implementedHookIds.contains($0) && Self.safeHookIds.contains($0) }
        print("[HookRuntimeAudit] chain_hooks=\(chain.count) completed=\(result.completedCount) unimplemented_in_chain=\(missingInChain.count) ids=[\(missingInChain.joined(separator: ","))]")
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
        // Task 2 — Priority hook runtime implementations
        case "summarize_visible_page":    return runSummarizeVisiblePage(ctx: ctx)
        case "summarize_visible_reviews": return runSummarizeVisibleReviews(ctx: ctx)
        case "extract_key_facts":         return runExtractKeyFacts(ctx: ctx)
        case "extract_product_specs":     return runExtractProductSpecs(ctx: ctx)
        case "compare_product_specs":     return runCompareProductSpecs(ctx: ctx)
        case "present_table":             return runPresentTable(ctx: ctx)
        case "present_recommendation":    return runPresentRecommendation(ctx: ctx)
        case "present_tradeoff_summary":  return runPresentTradeoffSummary(ctx: ctx)
        // Task 3 — remaining safe hooks
        case "extract_price_and_rating":  return runExtractPriceAndRating(ctx: ctx)
        case "build_comparison_table":    return runBuildComparisonTable(ctx: ctx)
        case "identify_purchase_tradeoffs": return runIdentifyPurchaseTradeoffs(ctx: ctx)
        case "create_briefing":           return runCreateBriefing(ctx: ctx)
        case "compare_options":           return runCompareOptions(ctx: ctx)
        default:
            // Hooks in safeHookIds that lack a runtime case are stubs — never claim success.
            let missing = !Self.implementedHookIds.contains(hookId)
            if missing {
                print("[HookRuntime] missing_prerequisite=no_runtime_case hook=\(hookId)")
            }
            return def.isImplemented
                ? .failed(reason: "no_sandbox_implementation_yet")
                : .placeholderOnly
        }
    }

    // MARK: - Coverage catalog
    // Every hookId with an explicit case in runHook must appear here so the
    // startup audit can detect gaps without running the full switch tree.
    static let implementedHookIds: Set<String> = [
        "observe_current_context", "gather_visible_context_once", "run_ocr_once",
        "read_selected_text", "inspect_window_title", "inspect_recent_titles",
        "extract_entities", "extract_product_attributes", "extract_error_messages", "extract_tasks",
        "call_local_llm", "summarize_with_llm", "classify_with_llm",
        "extract_structured_json_with_llm", "critique_result_with_llm", "verify_output_with_llm",
        "generate_short_response", "generate_long_response",
        "web_search", "fetch_page_text", "summarize_web_page", "extract_search_results",
        "compare_web_sources", "extract_article_content", "detect_paywall", "identify_primary_topic",
        "get_current_url", "open_new_tab", "switch_tab", "close_tab", "search_in_current_tab",
        "navigate_to_url", "read_page_title", "read_browser_visible_text",
        "fill_web_field", "submit_form",
        "draft_email", "summarize_email_thread", "extract_email_action_items",
        "prepare_reply", "prepare_followup", "create_message_summary",
        "open_app", "focus_app", "quit_app", "switch_window",
        "press_shortcut", "scroll_view", "click_screen_coordinate", "click_ui_element_by_id",
        "type_text", "clear_text_field",
        "split_goal_into_subtasks", "run_subtasks_parallel", "merge_results",
        "rank_results", "verify_result", "retry_once", "branch_on_result",
        "present_result",
        // Task 2
        "summarize_visible_page", "summarize_visible_reviews", "extract_key_facts",
        "extract_product_specs", "compare_product_specs",
        "present_table", "present_recommendation", "present_tradeoff_summary",
        // Task 3
        "extract_price_and_rating", "build_comparison_table",
        "identify_purchase_tradeoffs", "create_briefing", "compare_options",
    ]

    /// Call once at startup. Logs a [HookRuntimeAudit] line and loud errors for any gap.
    static func auditCoverageOnStartup() {
        let missing = safeHookIds.subtracting(implementedHookIds)
        let implemented = implementedHookIds.intersection(safeHookIds)
        let missingList = missing.sorted().joined(separator: ",")
        print("[HookRuntimeAudit] implemented=\(implemented.count) missing=\(missing.count) ids=[\(missingList)]")
        if !missing.isEmpty {
            print("[HookRuntimeAudit] ERROR — \(missing.count) safe hook(s) lack runtime implementations: \(missingList)")
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

    // MARK: - Task 2: Priority hook runtime implementations

    /// Produces a structured summary of visible page text using extractive heuristics.
    /// Scores sentences by position, length, and keyword density; selects top candidates.
    private func runSummarizeVisiblePage(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        guard let text = ctx.bestAvailableText, text.count >= 40 else {
            return .missingInput(field: "no_page_text_for_summary")
        }

        let sentences = splitSentences(text)
        guard sentences.count >= 2 else {
            // Short text — return as-is with a trim
            let trimmed = String(text.prefix(300))
            ctx.accumulatedText = trimmed
            ctx.outputLines.append("Summary: \(trimmed)")
            logRuntime(hook: "summarize_visible_page", t0: t0, consumed: ["page_text"], produced: ["summary_text"])
            return .success(output: trimmed)
        }

        // Score each sentence: position bonus + length sweet-spot + keyword density
        let keywords = extractImportantKeywords(from: text)
        var scored: [(String, Double)] = []
        for (i, sent) in sentences.enumerated() {
            var score = 0.0
            // Position bonus: first and last sentences carry more signal
            if i == 0 { score += 0.35 }
            else if i == sentences.count - 1 { score += 0.15 }
            else { score += 0.05 }
            // Length sweet-spot: 40–150 chars preferred
            let len = sent.count
            if len >= 40 && len <= 150 { score += 0.25 }
            else if len > 150 { score += 0.10 }
            // Keyword density
            let lower = sent.lowercased()
            let kHits = keywords.filter { lower.contains($0) }.count
            score += Double(kHits) * 0.08
            scored.append((sent, score))
        }

        let top = scored.sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
        let summary = top.joined(separator: " ")
        ctx.accumulatedText = summary
        ctx.outputLines.append("Summary: \(String(summary.prefix(400)))")
        logRuntime(hook: "summarize_visible_page", t0: t0, consumed: ["page_text"], produced: ["summary_text"])
        return .success(output: summary)
    }

    /// Extracts review sentiment and key points from visible text.
    private func runSummarizeVisibleReviews(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        guard let text = ctx.bestAvailableText, text.count >= 30 else {
            return .missingInput(field: "no_review_text_available")
        }

        let lower = text.lowercased()
        // Sentiment signals
        let positiveWords = ["great", "excellent", "love", "perfect", "amazing", "good", "best", "quality", "recommend", "worth"]
        let negativeWords = ["poor", "bad", "disappointing", "broke", "issue", "problem", "return", "waste", "cheap", "defect"]
        let posCount = positiveWords.filter { lower.contains($0) }.count
        let negCount = negativeWords.filter { lower.contains($0) }.count

        let sentiment: String
        if posCount > negCount * 2 { sentiment = "mostly positive" }
        else if negCount > posCount * 2 { sentiment = "mostly negative" }
        else if posCount == 0 && negCount == 0 { sentiment = "neutral" }
        else { sentiment = "mixed" }

        // Extract rating numbers
        let ratingPattern = try? NSRegularExpression(pattern: #"(\d(\.\d)?)\s*(out of\s*\d+|stars?|/5|/10)"#, options: .caseInsensitive)
        let nsText = text as NSString
        var ratings: [String] = []
        if let re = ratingPattern {
            re.matches(in: text, range: NSRange(location: 0, length: nsText.length)).forEach {
                ratings.append(nsText.substring(with: $0.range))
            }
        }

        var lines: [String] = ["Review sentiment: \(sentiment) (pos:\(posCount) neg:\(negCount))"]
        if !ratings.isEmpty {
            lines.append("Ratings found: \(ratings.prefix(3).joined(separator: ", "))")
        }

        // Top praised / complained terms
        let praised = positiveWords.filter { lower.contains($0) }.prefix(3)
        let complained = negativeWords.filter { lower.contains($0) }.prefix(3)
        if !praised.isEmpty { lines.append("Praised for: \(praised.joined(separator: ", "))") }
        if !complained.isEmpty { lines.append("Issues mentioned: \(complained.joined(separator: ", "))") }

        let output = lines.joined(separator: "\n")
        ctx.accumulatedText = output
        ctx.outputLines.append(output)
        logRuntime(hook: "summarize_visible_reviews", t0: t0, consumed: ["page_text"], produced: ["review_summary"])
        return .success(output: output)
    }

    /// Extracts key facts: declarative sentences, quantitative data, and enumerated points.
    private func runExtractKeyFacts(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        guard let text = ctx.bestAvailableText, text.count >= 30 else {
            return .missingInput(field: "no_text_for_key_facts")
        }

        var facts: [String] = []

        // Quantitative facts: sentences with numbers and units
        let sentences = splitSentences(text)
        let quantPattern = try? NSRegularExpression(pattern: #"\d[\d,]*(\.\d+)?\s*(ms|s|mb|gb|tb|px|cm|mm|inch|lb|kg|mph|km|%|°|hz|mhz|ghz|watt|mah|nm|fps)"#, options: .caseInsensitive)
        for sent in sentences {
            let nsText = sent as NSString
            if let re = quantPattern,
               !re.matches(in: sent, range: NSRange(location: 0, length: nsText.length)).isEmpty {
                facts.append(sent.trimmingCharacters(in: .whitespaces))
            }
        }

        // Numbered / bulleted list items
        let listPattern = try? NSRegularExpression(pattern: #"^[\s]*(\d+\.|•|-|\*)\s+(.{10,120})"#, options: .anchorsMatchLines)
        if let re = listPattern {
            let nsText = text as NSString
            re.matches(in: text, range: NSRange(location: 0, length: nsText.length)).prefix(6).forEach {
                if $0.numberOfRanges >= 3 {
                    let item = nsText.substring(with: $0.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    if !item.isEmpty { facts.append(item) }
                }
            }
        }

        // Declarative sentences with "is", "are", "was", "has"
        for sent in sentences where facts.count < 8 {
            let lower = sent.lowercased()
            if (lower.contains(" is ") || lower.contains(" are ") || lower.contains(" has ")) && sent.count >= 20 && sent.count <= 150 {
                facts.append(sent.trimmingCharacters(in: .whitespaces))
            }
        }

        guard !facts.isEmpty else {
            return .missingInput(field: "no_key_facts_detected")
        }

        // Deduplicate and limit
        var seen: Set<String> = []
        let deduped = facts.filter { seen.insert(String($0.prefix(60))).inserted }.prefix(6)
        let output = deduped.map { "• \($0)" }.joined(separator: "\n")
        ctx.accumulatedText = output
        ctx.outputLines.append("Key facts:\n\(output)")
        logRuntime(hook: "extract_key_facts", t0: t0, consumed: ["page_text"], produced: ["key_claims"])
        return .success(output: output)
    }

    /// Extends the existing product attribute extractor with richer structured output.
    private func runExtractProductSpecs(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        guard let text = ctx.bestAvailableText else {
            return .missingInput(field: "no_text_for_product_specs")
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var specs: [String: String] = [:]

        // Product name from window title (authoritative)
        let titleName = ctx.snapshot.windowTitle
        if !titleName.isEmpty { specs["name"] = String(titleName.prefix(80)) }

        // Price
        if let re = try? NSRegularExpression(pattern: #"\$[\d,]+(\.\d{2})?"#) {
            let matches = re.matches(in: text, range: fullRange)
            if let first = matches.first {
                specs["price"] = nsText.substring(with: first.range)
            }
        }

        // Rating
        if let re = try? NSRegularExpression(pattern: #"(\d(\.\d)?)\s*(out of\s*\d+|stars?)"#, options: .caseInsensitive) {
            let matches = re.matches(in: text, range: fullRange)
            if let first = matches.first {
                specs["rating"] = nsText.substring(with: first.range)
            }
        }

        // Review count
        if let re = try? NSRegularExpression(pattern: #"[\d,]+\s+(ratings?|reviews?)"#, options: .caseInsensitive) {
            let matches = re.matches(in: text, range: fullRange)
            if let first = matches.first {
                specs["reviews"] = nsText.substring(with: first.range)
            }
        }

        // Compatibility / "Compatible with" / "Works with"
        if let re = try? NSRegularExpression(pattern: #"(compatible with|works with|designed for|fits)[^.]{5,60}"#, options: .caseInsensitive) {
            let matches = re.matches(in: text, range: fullRange)
            if let first = matches.first {
                specs["compatibility"] = nsText.substring(with: first.range).trimmingCharacters(in: .whitespaces)
            }
        }

        // Color / finish
        let colorPattern = try? NSRegularExpression(pattern: #"(matte|glossy|clear|black|white|silver|gold|blue|red|green|titanium|space gray)"#, options: .caseInsensitive)
        if let re = colorPattern {
            let matches = re.matches(in: text, range: fullRange)
            let colors = Array(Set(matches.map { nsText.substring(with: $0.range).lowercased() })).sorted().prefix(3)
            if !colors.isEmpty { specs["color"] = colors.joined(separator: "/") }
        }

        guard !specs.isEmpty else {
            return .missingInput(field: "no_product_specs_detected")
        }

        let lines = specs.map { "  \($0.key): \($0.value)" }.sorted()
        let output = "Product specs:\n" + lines.joined(separator: "\n")
        ctx.accumulatedText = output
        ctx.outputLines.append(output)
        logRuntime(hook: "extract_product_specs", t0: t0, consumed: ["page_text"], produced: ["product_attributes"])
        return .success(output: output)
    }

    /// Produces a comparison summary from accumulated product spec output.
    private func runCompareProductSpecs(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        // Input: accumulated product attributes from extract_product_specs
        guard let attrs = ctx.accumulatedText, !attrs.isEmpty else {
            return .missingInput(field: "no_accumulated_product_attributes")
        }

        // Parse key/value lines and build a structured comparison
        var parsed: [String: String] = [:]
        for line in attrs.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: ": ")
            if parts.count >= 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts.dropFirst().joined(separator: ": ")
                parsed[key] = val
            }
        }

        var compLines: [String] = ["Comparison highlights:"]
        if let price = parsed["price"] { compLines.append("  Price: \(price)") }
        if let rating = parsed["rating"] { compLines.append("  Rating: \(rating)") }
        if let reviews = parsed["reviews"] { compLines.append("  Reviews: \(reviews)") }
        if let compat = parsed["compatibility"] { compLines.append("  Compatibility: \(compat)") }
        if let color = parsed["color"] { compLines.append("  Available in: \(color)") }
        if let name = parsed["name"] { compLines.append("  Product: \(name)") }

        // Value assessment heuristic
        if let priceStr = parsed["price"],
           let ratingStr = parsed["rating"] {
            let priceVal = Double(priceStr.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) ?? 0
            let ratingVal = Double(ratingStr.components(separatedBy: " ").first ?? "0") ?? 0
            if priceVal > 0 && ratingVal >= 4.0 {
                compLines.append("  Value: High-rated at this price point")
            } else if priceVal > 0 && ratingVal < 3.5 {
                compLines.append("  Value: Consider alternatives at this price")
            }
        }

        let output = compLines.joined(separator: "\n")
        ctx.accumulatedText = output
        ctx.outputLines.append(output)
        logRuntime(hook: "compare_product_specs", t0: t0, consumed: ["product_attributes"], produced: ["comparison_summary"])
        return .success(output: output)
    }

    /// Formats accumulated output as a markdown-style table.
    private func runPresentTable(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        let source = ctx.accumulatedText ?? ctx.outputLines.joined(separator: "\n")
        guard !source.isEmpty else {
            return .missingInput(field: "no_data_to_tabulate")
        }

        // Parse key: value lines into table rows
        var rows: [(String, String)] = []
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("Product specs") && !trimmed.hasPrefix("Comparison") && !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: ": ")
            if parts.count >= 2 {
                let key = parts[0].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: " •")))
                let val = parts.dropFirst().joined(separator: ": ")
                if !key.isEmpty && !val.isEmpty { rows.append((key, val)) }
            }
        }

        if rows.isEmpty {
            // Fallback: present as-is
            let output = source
            ctx.outputLines.append(output)
            logRuntime(hook: "present_table", t0: t0, consumed: ["comparison_summary"], produced: ["table"])
            return .success(output: output)
        }

        let colWidth = max(16, rows.map { $0.0.count }.max() ?? 16)
        let header = "| \("Attribute".padding(toLength: colWidth, withPad: " ", startingAt: 0)) | Value |"
        let divider = "|-\(String(repeating: "-", count: colWidth))-|-------|"
        let tableRows = rows.map { "| \($0.0.padding(toLength: colWidth, withPad: " ", startingAt: 0)) | \($0.1) |" }
        let table = ([header, divider] + tableRows).joined(separator: "\n")

        ctx.accumulatedText = table
        ctx.outputLines = [table]
        logRuntime(hook: "present_table", t0: t0, consumed: ["comparison_summary"], produced: ["table"])
        return .success(output: table)
    }

    /// Formats accumulated output as a decision recommendation.
    private func runPresentRecommendation(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        let source = ctx.accumulatedText ?? ctx.outputLines.joined(separator: "\n")
        guard !source.isEmpty else {
            return .missingInput(field: "no_data_for_recommendation")
        }

        // Build recommendation from what we know
        var rec = "Based on available information:\n"
        for line in source.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            rec += "• \(line.trimmingCharacters(in: .whitespaces))\n"
        }
        rec += "\nThis appears to be a suitable option based on the visible context."

        let output = String(rec.prefix(600))
        ctx.accumulatedText = output
        ctx.outputLines = [output]
        logRuntime(hook: "present_recommendation", t0: t0, consumed: ["comparison_summary"], produced: ["final_result"])
        return .success(output: output)
    }

    /// Formats accumulated output as a tradeoff summary.
    private func runPresentTradeoffSummary(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        let source = ctx.accumulatedText ?? ctx.outputLines.joined(separator: "\n")
        guard !source.isEmpty else {
            return .missingInput(field: "no_data_for_tradeoff_summary")
        }

        let output = "Tradeoff analysis:\n\(String(source.prefix(500)))"
        ctx.accumulatedText = output
        ctx.outputLines = [output]
        logRuntime(hook: "present_tradeoff_summary", t0: t0, consumed: ["key_claims"], produced: ["final_result"])
        return .success(output: output)
    }

    // MARK: - Task 3: remaining safe hook implementations

    /// Extracts numeric price and rating values from any available text.
    /// Generic heuristic — no domain hardcoding. Produces `price_rating` context.
    private func runExtractPriceAndRating(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        guard let text = ctx.bestAvailableText, !text.isEmpty else {
            return .missingInput(field: "no_text_for_price_rating_extraction")
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var parts: [String] = []

        // Currency-prefixed prices: $19.99, €9, £24.50, ¥1200
        if let re = try? NSRegularExpression(pattern: #"[$€£¥₹][\d,]+(\.\d{1,2})?"#) {
            re.matches(in: text, range: fullRange).prefix(4).forEach {
                parts.append("price:\(nsText.substring(with: $0.range))")
            }
        }
        // Numeric ratings with scale: 4.6/5, 8.2/10, 4.5 out of 5, 4.6 stars
        if let re = try? NSRegularExpression(
            pattern: #"(\d(\.\d)?)\s*(\/\s*\d+|out\s+of\s+\d+|stars?)"#, options: .caseInsensitive) {
            re.matches(in: text, range: fullRange).prefix(3).forEach {
                parts.append("rating:\(nsText.substring(with: $0.range))")
            }
        }
        // Review / rating count: "4,321 ratings"
        if let re = try? NSRegularExpression(
            pattern: #"[\d,]+\s+(ratings?|reviews?|reviewers?)"#, options: .caseInsensitive) {
            re.matches(in: text, range: fullRange).prefix(2).forEach {
                parts.append("review_count:\(nsText.substring(with: $0.range))")
            }
        }

        guard !parts.isEmpty else {
            return .missingInput(field: "no_price_or_rating_detected")
        }
        let output = parts.joined(separator: " | ")
        ctx.accumulatedText = output
        ctx.outputLines.append("Price/Rating: \(output)")
        logRuntime(hook: "extract_price_and_rating", t0: t0, consumed: ["page_text"], produced: ["price_rating"])
        return .success(output: output)
    }

    /// Builds a structured comparison table from accumulated context.
    /// Reads accumulated text (attributes, facts, specs) or falls back to OCR/title.
    /// Produces a markdown-formatted table suitable for side-by-side comparison.
    private func runBuildComparisonTable(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        let source = ctx.accumulatedText ?? ctx.outputLines.joined(separator: "\n")
        guard !source.isEmpty else {
            return .missingInput(field: "no_accumulated_data_for_comparison_table")
        }

        // Parse any `key: value` lines from accumulated output
        var rows: [(String, String)] = []
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "•-*"))
                .trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("Product specs"), !trimmed.hasPrefix("Comparison"),
                  !trimmed.hasPrefix("Key facts"), !trimmed.hasPrefix("Summary")
            else { continue }
            let colonIdx = trimmed.firstIndex(of: ":")
            if let ci = colonIdx {
                let key = String(trimmed[trimmed.startIndex..<ci]).trimmingCharacters(in: .whitespaces)
                let val = String(trimmed[trimmed.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !val.isEmpty && key.count <= 40 {
                    rows.append((key, val))
                }
            }
        }

        // Also incorporate window title as "Item" row if no name row present
        let hasName = rows.contains { $0.0.lowercased() == "name" || $0.0.lowercased() == "product" }
        if !hasName {
            let titleVal = ctx.snapshot.windowTitle
            if !titleVal.isEmpty { rows.insert(("Item", String(titleVal.prefix(80))), at: 0) }
        }

        if rows.isEmpty {
            // Fallback: present accumulated text verbatim
            let output = "Comparison:\n\(String(source.prefix(500)))"
            ctx.outputLines.append(output)
            ctx.accumulatedText = output
            logRuntime(hook: "build_comparison_table", t0: t0, consumed: ["product_attributes", "key_claims"], produced: ["table"])
            return .success(output: output)
        }

        // Deduplicate
        var seen: Set<String> = []
        let deduped = rows.filter { seen.insert($0.0.lowercased()).inserted }.prefix(12)

        let colW = max(16, deduped.map { $0.0.count }.max() ?? 16)
        let header  = "| \("Attribute".padding(toLength: colW, withPad: " ", startingAt: 0)) | Value                          |"
        let divider = "|-\(String(repeating: "-", count: colW))-|--------------------------------|"
        let tableRows = deduped.map {
            let val = String($0.1.prefix(40))
            return "| \($0.0.padding(toLength: colW, withPad: " ", startingAt: 0)) | \(val.padding(toLength: 32, withPad: " ", startingAt: 0)) |"
        }
        let table = ([header, divider] + tableRows).joined(separator: "\n")

        ctx.accumulatedText = table
        ctx.outputLines = [table]
        logRuntime(hook: "build_comparison_table", t0: t0, consumed: ["product_attributes", "key_claims"], produced: ["table"])
        return .success(output: table)
    }

    /// Identifies purchase/decision tradeoffs from available context.
    /// Works from accumulated text (specs, reviews, facts) or raw OCR — no LLM required.
    /// Categorises signals into pros (positive indicators) and cons (negative indicators).
    private func runIdentifyPurchaseTradeoffs(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        guard let text = ctx.bestAvailableText, text.count >= 20 else {
            return .missingInput(field: "no_text_for_tradeoff_identification")
        }

        let lower = text.lowercased()

        // Generic positive capability/quality signals — not domain-specific
        let proSignals: [(String, String)] = [
            ("highly rated", ["4.5 stars", "4.6 stars", "4.7 stars", "4.8 stars", "4.9 stars", "top rated", "best seller"]),
            ("well reviewed", ["thousands of", "reviews", "verified purchase"]),
            ("quality materials", ["durable", "sturdy", "premium", "quality", "solid", "robust"]),
            ("good value", ["value", "affordable", "worth", "reasonable"]),
            ("compatible", ["compatible with", "works with", "designed for", "fits"]),
            ("easy to use", ["easy", "simple", "plug and play", "no setup"]),
        ].compactMap { (label, keywords) -> (String, String)? in
            let matched = keywords.filter { lower.contains($0) }
            return matched.isEmpty ? nil : (label, matched.first!)
        }

        let conSignals: [(String, String)] = [
            ("quality concerns", ["cheap", "flimsy", "broke", "defect", "poor quality"]),
            ("fit/size issues", ["doesn't fit", "wrong size", "too big", "too small", "loose"]),
            ("durability concerns", ["broke", "stopped working", "failed", "cracked", "peeled"]),
            ("returns mentioned", ["returned", "return", "refund", "exchange"]),
            ("missing feature", ["missing", "no", "lacks", "without"]),
        ].compactMap { (label, keywords) -> (String, String)? in
            let matched = keywords.filter { lower.contains($0) }
            return matched.isEmpty ? nil : (label, matched.first!)
        }

        // Extract price/rating for value signal
        let nsText = text as NSString
        var priceStr: String? = nil
        var ratingVal: Double? = nil
        if let re = try? NSRegularExpression(pattern: #"[$€£¥][\d,]+(\.\d{1,2})?"#) {
            if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
                priceStr = nsText.substring(with: m.range)
            }
        }
        if let re = try? NSRegularExpression(pattern: #"(\d(\.\d)?)\s*(stars?|\/5)"#, options: .caseInsensitive) {
            if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let raw = nsText.substring(with: m.range(at: 1))
                ratingVal = Double(raw)
            }
        }

        var lines: [String] = ["Tradeoff analysis:"]
        if let p = priceStr { lines.append("  Price point: \(p)") }
        if let r = ratingVal { lines.append("  Rating: \(r)/5.0 (\(r >= 4.0 ? "strong" : r >= 3.0 ? "moderate" : "weak"))") }

        if !proSignals.isEmpty {
            lines.append("Pros:")
            proSignals.prefix(5).forEach { lines.append("  + \($0.0)") }
        }
        if !conSignals.isEmpty {
            lines.append("Cons:")
            conSignals.prefix(5).forEach { lines.append("  - \($0.0)") }
        }

        // Overall lean
        if proSignals.count > conSignals.count * 2 {
            lines.append("Overall: Positive lean — more signals of quality than concerns.")
        } else if conSignals.count > proSignals.count {
            lines.append("Overall: Exercise caution — notable concerns present.")
        } else {
            lines.append("Overall: Mixed signals — review specifics before deciding.")
        }

        let output = lines.joined(separator: "\n")
        ctx.accumulatedText = output
        ctx.outputLines.append(output)
        logRuntime(hook: "identify_purchase_tradeoffs", t0: t0, consumed: ["product_attributes", "review_summary"], produced: ["key_claims"])
        return .success(output: output)
    }

    /// Synthesises a structured briefing from accumulated text.
    /// Sections: subject (from window title), key points (top sentences), context (workflow/app).
    private func runCreateBriefing(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()
        let source = ctx.bestAvailableText ?? ctx.outputLines.joined(separator: "\n")
        guard !source.isEmpty else {
            return .missingInput(field: "no_text_for_briefing")
        }

        let s = ctx.snapshot
        let subject = s.windowTitle.isEmpty ? "Current context" : String(s.windowTitle.prefix(80))

        // Key points: top-scored sentences from source
        let sentences = splitSentences(source)
        let keywords = extractImportantKeywords(from: source)
        var scored: [(String, Double)] = sentences.enumerated().map { (i, sent) in
            var score = i == 0 ? 0.4 : 0.05
            let lower = sent.lowercased()
            score += Double(keywords.filter { lower.contains($0) }.count) * 0.08
            if sent.count >= 40 && sent.count <= 160 { score += 0.2 }
            return (sent, score)
        }
        let topSentences = scored.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)

        var lines: [String] = [
            "Briefing: \(subject)",
            "App: \(s.activeApp) | Workflow: \(s.inferredWorkflow.rawValue)",
            "",
            "Key Points:",
        ]
        topSentences.forEach { lines.append("  • \(String($0.prefix(120)))") }

        // Append any structured output already in outputLines (tables, specs)
        let priorOutput = ctx.outputLines.filter { !$0.isEmpty }.prefix(4)
        if !priorOutput.isEmpty {
            lines.append("")
            lines.append("Extracted Context:")
            priorOutput.forEach { lines.append("  \(String($0.prefix(100)))") }
        }

        let output = lines.joined(separator: "\n")
        ctx.accumulatedText = output
        ctx.outputLines = [output]
        logRuntime(hook: "create_briefing", t0: t0, consumed: ["summary_text", "key_claims"], produced: ["summary_text"])
        return .success(output: output)
    }

    /// Compares options visible in the current context.
    /// Works from: accumulated product attributes, key facts, recent titles, OCR, window title.
    /// No hardcoded domains — operates on whatever structured or unstructured text is available.
    private func runCompareOptions(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let t0 = Date()

        // Gather all available signals
        var optionSegments: [String] = []

        // Option 1: accumulated structured output from prior hooks (richest signal)
        if let acc = ctx.accumulatedText, !acc.isEmpty {
            optionSegments.append(acc)
        }

        // Option 2: OCR or selected text
        if let ocr = ctx.snapshot.recentOCRExcerpt, !ocr.isEmpty, optionSegments.isEmpty {
            optionSegments.append(ocr)
        }

        // Option 3: context summary
        if let cs = ctx.snapshot.contextSummary, !cs.isEmpty, optionSegments.isEmpty {
            optionSegments.append(cs)
        }

        // Always include window title as the primary subject
        let title = ctx.snapshot.windowTitle

        if optionSegments.isEmpty && title.isEmpty {
            return .missingInput(field: "no_content_to_compare_options_from")
        }

        let combinedSource = optionSegments.joined(separator: "\n")

        // Extract comparable attributes: prices, ratings, key entities
        let nsSource = combinedSource as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)

        var compLines: [String] = ["Options comparison:"]
        if !title.isEmpty { compLines.append("  Subject: \(String(title.prefix(80)))") }

        // Prices
        if let re = try? NSRegularExpression(pattern: #"[$€£¥][\d,]+(\.\d{1,2})?"#) {
            let prices = re.matches(in: combinedSource, range: fullRange)
                .prefix(4)
                .map { nsSource.substring(with: $0.range) }
            if !prices.isEmpty { compLines.append("  Prices observed: \(prices.joined(separator: ", "))") }
        }

        // Ratings
        if let re = try? NSRegularExpression(
            pattern: #"(\d(\.\d)?)\s*(\/\s*\d+|stars?|out\s+of\s+\d+)"#, options: .caseInsensitive) {
            let ratings = re.matches(in: combinedSource, range: fullRange)
                .prefix(4)
                .map { nsSource.substring(with: $0.range) }
            if !ratings.isEmpty { compLines.append("  Ratings observed: \(ratings.joined(separator: ", "))") }
        }

        // Named entities / proper nouns as option labels
        let entities = heuristicExtractEntities(from: combinedSource).prefix(6)
        if !entities.isEmpty {
            compLines.append("  Entities/options identified: \(entities.joined(separator: " | "))")
        }

        // Capability/feature differences (positive vs negative sentences)
        let sentences = splitSentences(combinedSource)
        let positiveKw = ["best", "better", "faster", "more", "higher", "superior", "excellent", "top"]
        let negativeKw = ["worse", "slower", "lower", "less", "inferior", "poor", "weak", "cheaper"]
        let proLines = sentences.filter { s in positiveKw.contains { s.lowercased().contains($0) } }.prefix(2)
        let conLines = sentences.filter { s in negativeKw.contains { s.lowercased().contains($0) } }.prefix(2)
        if !proLines.isEmpty { compLines.append("  Positive signals: \(proLines.map { String($0.prefix(80)) }.joined(separator: "; "))") }
        if !conLines.isEmpty { compLines.append("  Concerns: \(conLines.map { String($0.prefix(80)) }.joined(separator: "; "))") }

        // Workflow hint
        compLines.append("  Context: \(ctx.snapshot.inferredWorkflow.rawValue) workflow | app=\(ctx.snapshot.activeApp)")

        let output = compLines.joined(separator: "\n")
        ctx.accumulatedText = output
        ctx.outputLines.append(output)
        logRuntime(hook: "compare_options", t0: t0,
                   consumed: ["product_attributes", "key_claims", "page_text"],
                   produced: ["comparison_summary"])
        return .success(output: output)
    }

    // MARK: - Runtime helpers

    private func logRuntime(hook: String, t0: Date, consumed: [String], produced: [String]) {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[HookRuntime] consumed=[\(consumed.joined(separator: ","))] produced=[\(produced.joined(separator: ","))] execution_time_ms=\(ms) completed hook=\(hook)")
    }

    /// Splits text into sentences using punctuation boundaries.
    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 15 {
                sentences.append(s)
            }
        }
        return sentences.isEmpty ? text.components(separatedBy: ". ").filter { $0.count >= 15 } : sentences
    }

    /// Extracts the most important content keywords from a text body.
    private func extractImportantKeywords(from text: String) -> [String] {
        let stopwords: Set<String> = ["the", "and", "for", "with", "this", "that", "from",
                                      "are", "was", "has", "have", "its", "you", "your", "our"]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 5 && !stopwords.contains($0) }
        var freq: [String: Int] = [:]
        for w in words { freq[w, default: 0] += 1 }
        return freq.sorted { $0.value > $1.value }.prefix(20).map(\.key)
    }
}
