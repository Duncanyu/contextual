
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