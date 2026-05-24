import Foundation

enum HookIOValidatorSelfTest {
    
    private static var failures = 0
    
    private static func check(_ name: String, _ condition: Bool) {
        if condition {
            print("[HookIOValidatorSelfTest] case=\(name) result=pass")
        } else {
            print("[HookIOValidatorSelfTest] case=\(name) result=fail")
            failures += 1
        }
    }
    
    static func run() {
        print("[HookIOValidatorSelfTest] starting validator self-tests")
        failures = 0
        
        let registry = HookCapabilityRegistry.shared
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 1 — Invalid comparison table chain
        // ══════════════════════════════════════════════════════════════════
        let initialInputs1: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain1 = ["build_comparison_table", "present_table"]
        let res1 = HookChainIOValidator.validate(hookIds: chain1, initialAvailableInputs: initialInputs1, registry: registry)
        
        check("invalid_comparison_table_chain_fails", res1.isValid == false)
        check("invalid_comparison_table_chain_failed_hook", res1.failedHookId == "build_comparison_table")
        check("invalid_comparison_table_chain_missing_comparable_items", res1.missingInputs.contains(.comparable_items))
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 2 — Valid comparison chain
        // ══════════════════════════════════════════════════════════════════
        let initialInputs2: Set<HookIOKey> = [.current_context, .app_identifier, .window_title, .page_text]
        let chain2 = ["extract_entities", "compare_options", "build_comparison_table", "present_table"]
        let res2 = HookChainIOValidator.validate(hookIds: chain2, initialAvailableInputs: initialInputs2, registry: registry)
        
        check("valid_comparison_chain_passes", res2.isValid == true)
        check("valid_comparison_chain_final_contains_final_result", res2.finalAvailableOutputs.contains(.final_result))
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 3 — Invalid presentation chain
        // ══════════════════════════════════════════════════════════════════
        let initialInputs3: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain3 = ["present_table"]
        let res3 = HookChainIOValidator.validate(hookIds: chain3, initialAvailableInputs: initialInputs3, registry: registry)
        
        check("invalid_presentation_chain_fails", res3.isValid == false)
        check("invalid_presentation_chain_failed_hook", res3.failedHookId == "present_table")
        check("invalid_presentation_chain_missing_table", res3.missingInputs.contains(.table))
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 4 — Valid summarize chain
        // ══════════════════════════════════════════════════════════════════
        let initialInputs4: Set<HookIOKey> = [.current_context, .app_identifier, .window_title, .page_text]
        let chain4 = ["summarize_visible_page", "present_result"]
        let res4 = HookChainIOValidator.validate(hookIds: chain4, initialAvailableInputs: initialInputs4, registry: registry)
        
        check("valid_summarize_chain_passes", res4.isValid == true)
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 5 — Observe-once chain
        // ══════════════════════════════════════════════════════════════════
        let initialInputs5: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain5 = ["run_ocr_once", "extract_product_specs", "present_result"]
        let res5 = HookChainIOValidator.validate(hookIds: chain5, initialAvailableInputs: initialInputs5, registry: registry)
        
        check("observe_once_chain_passes", res5.isValid == true)
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 6 — Unknown hook
        // ══════════════════════════════════════════════════════════════════
        let initialInputs6: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain6 = ["nonexistent_hook_id"]
        let res6 = HookChainIOValidator.validate(hookIds: chain6, initialAvailableInputs: initialInputs6, registry: registry)
        
        check("unknown_hook_fails", res6.isValid == false)
        check("unknown_hook_failed_hook", res6.failedHookId == "nonexistent_hook_id")
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 7 — Optional inputs do not block
        // ══════════════════════════════════════════════════════════════════
        let initialInputs7: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain7 = ["extract_product_specs", "present_result"]
        let res7 = HookChainIOValidator.validate(hookIds: chain7, initialAvailableInputs: initialInputs7, registry: registry)
        
        check("optional_inputs_do_not_block_passes", res7.isValid == true)
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 8 — Final outputs trace
        // ══════════════════════════════════════════════════════════════════
        let initialInputs8: Set<HookIOKey> = [.current_context, .app_identifier, .window_title, .page_text]
        let chain8 = ["extract_entities", "compare_options", "build_comparison_table"]
        let res8 = HookChainIOValidator.validate(hookIds: chain8, initialAvailableInputs: initialInputs8, registry: registry)
        
        check("final_outputs_trace_passes", res8.isValid == true)
        check("final_outputs_trace_contains_comparison_table", res8.finalAvailableOutputs.contains(.comparison_table))
        check("final_outputs_trace_contains_table", res8.finalAvailableOutputs.contains(.table))
        
        // ══════════════════════════════════════════════════════════════════
        // Deterministic Initial Snapshot Mapper Tests
        // ══════════════════════════════════════════════════════════════════
        let snap1 = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Safari",
            windowTitle: "Shoes",
            recentOCRExcerpt: "Price: $99"
        )
        let snapInputs1 = HookChainIOValidator.initialInputs(from: snap1)
        check("mapper_ocr_mapped_to_ocr_text", snapInputs1.contains(.ocr_text))
        check("mapper_ocr_mapped_to_page_text", snapInputs1.contains(.page_text))
        check("mapper_metadata_mapped", snapInputs1.contains(.current_context) && snapInputs1.contains(.window_title))
        
        let snap2 = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Chrome",
            windowTitle: "Doc",
            selectedText: "Important selected text",
            clipboardText: "Copied link",
            contextSummary: "ax=Fragments of the window structure here"
        )
        let snapInputs2 = HookChainIOValidator.initialInputs(from: snap2)
        check("mapper_selected_text_mapped", snapInputs2.contains(.selected_text))
        check("mapper_clipboard_mapped", snapInputs2.contains(.clipboard_text))
        check("mapper_ax_mapped_to_ax_text", snapInputs2.contains(.ax_window_text))
        check("mapper_ax_mapped_to_page_text", snapInputs2.contains(.page_text))
        
        if failures == 0 {
            print("[HookIOValidatorSelfTest] ok=true failures=0")
        } else {
            print("[HookIOValidatorSelfTest] ok=false failures=\(failures)")
        }
    }
}
