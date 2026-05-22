
    private func runObserveCurrentContext(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "observe_current_context stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ObserveCurrentContext: \(output)")
        return .success(output: output)
    }

    private func runReadWindowTitle(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "read_window_title stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ReadWindowTitle: \(output)")
        return .success(output: output)
    }

    private func runReadSelectedText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "read_selected_text stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ReadSelectedText: \(output)")
        return .success(output: output)
    }

    private func runReadClipboard(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "read_clipboard stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ReadClipboard: \(output)")
        return .success(output: output)
    }

    private func runReadAxText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "read_ax_text stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ReadAxText: \(output)")
        return .success(output: output)
    }

    private func runRunOcrOnce(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "run_ocr_once stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("RunOcrOnce: \(output)")
        return .success(output: output)
    }

    private func runSummarizeCurrentContext(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "summarize_current_context stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SummarizeCurrentContext: \(output)")
        return .success(output: output)
    }

    private func runExtractEntities(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "extract_entities stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractEntities: \(output)")
        return .success(output: output)
    }

    private func runExtractProductAttributes(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "extract_product_attributes stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractProductAttributes: \(output)")
        return .success(output: output)
    }

    private func runExtractPrices(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "extract_prices stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractPrices: \(output)")
        return .success(output: output)
    }

    private func runExtractDates(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "extract_dates stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractDates: \(output)")
        return .success(output: output)
    }

    private func runExtractErrors(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "extract_errors stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractErrors: \(output)")
        return .success(output: output)
    }

    private func runExtractLinks(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "extract_links stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractLinks: \(output)")
        return .success(output: output)
    }

    private func runExtractFormFields(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "extract_form_fields stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractFormFields: \(output)")
        return .success(output: output)
    }

    private func runExtractKeyClaims(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "extract_key_claims stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExtractKeyClaims: \(output)")
        return .success(output: output)
    }

    private func runSummarizeVisibleContent(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "summarize_visible_content stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("SummarizeVisibleContent: \(output)")
        return .success(output: output)
    }

    private func runCompareItems(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "compare_items stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("CompareItems: \(output)")
        return .success(output: output)
    }

    private func runExplainCode(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "explain_code stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExplainCode: \(output)")
        return .success(output: output)
    }

    private func runExplainError(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "explain_error stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExplainError: \(output)")
        return .success(output: output)
    }

    private func runClassifyPageType(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "classify_page_type stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ClassifyPageType: \(output)")
        return .success(output: output)
    }

    private func runIdentifyNextStep(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "identify_next_step stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("IdentifyNextStep: \(output)")
        return .success(output: output)
    }

    private func runDetectMissingInformation(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "detect_missing_information stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("DetectMissingInformation: \(output)")
        return .success(output: output)
    }

    private func runRewriteText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "rewrite_text stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("RewriteText: \(output)")
        return .success(output: output)
    }

    private func runFormatAsEmail(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "format_as_email stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("FormatAsEmail: \(output)")
        return .success(output: output)
    }

    private func runConvertToChecklist(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "convert_to_checklist stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ConvertToChecklist: \(output)")
        return .success(output: output)
    }

    private func runCreateTable(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "create_table stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("CreateTable: \(output)")
        return .success(output: output)
    }

    private func runShortenText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "shorten_text stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ShortenText: \(output)")
        return .success(output: output)
    }

    private func runExpandText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "expand_text stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("ExpandText: \(output)")
        return .success(output: output)
    }

    private func runCleanText(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "clean_text stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("CleanText: \(output)")
        return .success(output: output)
    }

    private func runPresentResult(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "present_result stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("PresentResult: \(output)")
        return .success(output: output)
    }

    private func runPresentComparison(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "present_comparison stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("PresentComparison: \(output)")
        return .success(output: output)
    }

    private func runPresentChecklist(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "present_checklist stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("PresentChecklist: \(output)")
        return .success(output: output)
    }

    private func runPresentWarning(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "present_warning stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("PresentWarning: \(output)")
        return .success(output: output)
    }

    private func runCopyToClipboard(ctx: SandboxContext) -> HookSandboxStepOutcome {
        let output = "copy_to_clipboard stub execution success"
        ctx.accumulatedText = output
        ctx.outputLines.append("CopyToClipboard: \(output)")
        return .success(output: output)
    }