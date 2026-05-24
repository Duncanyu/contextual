import Foundation

enum HookChainRepairSelfTest {
    
    private static var failures = 0
    
    private static func check(_ name: String, _ condition: Bool) {
        if condition {
            print("[HookChainRepairSelfTest] case=\(name) result=pass")
        } else {
            print("[HookChainRepairSelfTest] case=\(name) result=fail")
            failures += 1
        }
    }
    
    static func run() {
        print("[HookChainRepairSelfTest] starting hook chain repair self-tests")
        failures = 0
        
        let registry = HookCapabilityRegistry.shared
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 1 — build_comparison_table -> present_table repairs successfully
        // ══════════════════════════════════════════════════════════════════
        let initial1: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain1 = ["build_comparison_table", "present_table"]
        let res1 = HookChainRepairEngine.repair(originalHookIds: chain1, initialAvailableInputs: initial1, registry: registry)
        
        check("build_comparison_table_present_table_repairs", res1 != nil)
        if let repaired1 = res1 {
            check("build_comparison_table_present_table_contains_compare", repaired1.contains("compare_options") || repaired1.contains("compare_product_specs"))
            check("build_comparison_table_present_table_retains_original_order", repaired1.firstIndex(of: "build_comparison_table")! < repaired1.firstIndex(of: "present_table")!)
        }
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 2 — present_tradeoff_summary repairs successfully
        // ══════════════════════════════════════════════════════════════════
        let initial2: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain2 = ["present_tradeoff_summary"]
        let res2 = HookChainRepairEngine.repair(originalHookIds: chain2, initialAvailableInputs: initial2, registry: registry)
        
        check("present_tradeoff_summary_repairs", res2 != nil)
        if let repaired2 = res2 {
            check("present_tradeoff_summary_contains_identify_purchase_tradeoffs", repaired2.contains("identify_purchase_tradeoffs"))
        }
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 3 — extract_product_specs -> present_table repairs successfully
        // ══════════════════════════════════════════════════════════════════
        let initial3: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain3 = ["extract_product_specs", "present_table"]
        let res3 = HookChainRepairEngine.repair(originalHookIds: chain3, initialAvailableInputs: initial3, registry: registry)
        
        check("extract_product_specs_present_table_repairs", res3 != nil)
        if let repaired3 = res3 {
            check("extract_product_specs_present_table_contains_build_comparison_table", repaired3.contains("build_comparison_table"))
            // Check that it inserted compare_product_specs to bridge from specs to comparable items
            check("extract_product_specs_present_table_contains_compare", repaired3.contains("compare_product_specs") || repaired3.contains("compare_options"))
        }
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 4 — Invalid chain with no producers fails cleanly
        // ══════════════════════════════════════════════════════════════════
        // Define a custom presentation hook that requires .raw_html (unproduced key)
        let hookUnreachable = HookCapabilityDefinition(
            id: "unreachable_presenter",
            description: "Presenter requiring raw_html",
            category: .presentation,
            capability: "present html",
            requires: [.raw_html],
            produces: [.final_result],
            lifecycleStatus: .implemented
        )
        let customRegistry4 = HookCapabilityRegistry(customDefs: [hookUnreachable])
        let res4 = HookChainRepairEngine.repair(originalHookIds: ["unreachable_presenter"], initialAvailableInputs: [], registry: customRegistry4)
        
        check("unreachable_producer_fails_cleanly", res4 == nil)
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 5 — Repair depth exceeded (> 3 insertions) fails safely
        // ══════════════════════════════════════════════════════════════════
        // Hook A requires nothing, produces keyA.
        // Hook B requires keyA, produces keyB.
        // Hook C requires keyB, produces keyC.
        // Hook D requires keyC, produces keyD.
        // Hook E requires keyD (presentation), produces final_result.
        let hookA = HookCapabilityDefinition(id: "hookA", description: "produces keyA", category: .sensing, capability: "A", requires: [], produces: [.current_context], lifecycleStatus: .implemented) // using current_context as placeholder keyA
        let hookB = HookCapabilityDefinition(id: "hookB", description: "requires keyA, produces keyB", category: .extraction, capability: "B", requires: [.current_context], produces: [.selected_text], lifecycleStatus: .implemented) // using selected_text as placeholder keyB
        let hookC = HookCapabilityDefinition(id: "hookC", description: "requires keyB, produces keyC", category: .reasoning, capability: "C", requires: [.selected_text], produces: [.comparison_summary], lifecycleStatus: .implemented) // using comparison_summary as placeholder keyC
        let hookD = HookCapabilityDefinition(id: "hookD", description: "requires keyC, produces keyD", category: .transformation, capability: "D", requires: [.comparison_summary], produces: [.table], lifecycleStatus: .implemented) // using table as placeholder keyD
        let hookE = HookCapabilityDefinition(id: "hookE", description: "requires keyD (presenter)", category: .presentation, capability: "E", requires: [.table], produces: [.final_result], lifecycleStatus: .implemented)
        
        // This requires 4 insertions starting with empty inputs: hookA -> hookB -> hookC -> hookD -> hookE
        let customRegistry5 = HookCapabilityRegistry(customDefs: [hookA, hookB, hookC, hookD, hookE])
        let res5 = HookChainRepairEngine.repair(originalHookIds: ["hookE"], initialAvailableInputs: [], registry: customRegistry5)
        
        check("repair_depth_exceeded_fails", res5 == nil)
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 6 — Repair never inserts external_control hooks
        // ══════════════════════════════════════════════════════════════════
        // Hook E requires keyD (.table)
        // Hook D produces keyD but has permission level .unavailable (external_control)
        let hookDUnavailable = HookCapabilityDefinition(
            id: "hookD_unsafe",
            description: "external control producer",
            category: .app_control,
            capability: "D Unsafe",
            requires: [],
            produces: [.table],
            lifecycleStatus: .implemented,
            permissionLevel: .unavailable
        )
        let customRegistry6 = HookCapabilityRegistry(customDefs: [hookDUnavailable, hookE])
        let res6 = HookChainRepairEngine.repair(originalHookIds: ["hookE"], initialAvailableInputs: [], registry: customRegistry6)
        
        check("external_control_producers_ignored", res6 == nil)
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 7 — Repair preserves original hook order
        // ══════════════════════════════════════════════════════════════════
        let initial7: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain7 = ["build_comparison_table", "present_table"]
        let res7 = HookChainRepairEngine.repair(originalHookIds: chain7, initialAvailableInputs: initial7, registry: registry)
        
        check("order_preserved", res7 != nil)
        if let repaired7 = res7 {
            var lastIdx = -1
            var orderOk = true
            for id in chain7 {
                if let idx = repaired7.firstIndex(of: id) {
                    if idx <= lastIdx {
                        orderOk = false
                    }
                    lastIdx = idx
                } else {
                    orderOk = false
                }
            }
            check("order_preserved_matches_original", orderOk)
        }
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 8 — Repaired chain passes HookChainIOValidator
        // ══════════════════════════════════════════════════════════════════
        let initial8: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain8 = ["build_comparison_table", "present_table"]
        let res8 = HookChainRepairEngine.repair(originalHookIds: chain8, initialAvailableInputs: initial8, registry: registry)
        
        check("repaired_chain_validates_result", res8 != nil)
        if let repaired8 = res8 {
            let val = HookChainIOValidator.validate(hookIds: repaired8, initialAvailableInputs: initial8, registry: registry)
            check("repaired_chain_validator_passes", val.isValid == true)
        }
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 9 — Repair avoids duplicate insertions
        // ══════════════════════════════════════════════════════════════════
        // A chain with multiple hooks that all require the same missing key should not have duplicates inserted
        let initial9: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        // build_comparison_table requires comparable_items, present_recommendation optional tradeoffs
        let chain9 = ["build_comparison_table", "present_table"]
        let res9 = HookChainRepairEngine.repair(originalHookIds: chain9, initialAvailableInputs: initial9, registry: registry)
        
        check("repaired_no_duplicates", res9 != nil)
        if let repaired9 = res9 {
            let compareCount = repaired9.filter { $0 == "compare_options" || $0 == "compare_product_specs" }.count
            check("repaired_no_duplicate_compare_insertions", compareCount <= 1)
        }
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 10 — Observe-once chains remain observe-once-compatible
        // ══════════════════════════════════════════════════════════════════
        // Observe-once hooks (like run_ocr_once) produce page_text, allowing subsequent specs hooks
        let initial10: Set<HookIOKey> = [.current_context, .app_identifier, .window_title]
        let chain10 = ["run_ocr_once", "extract_product_specs", "present_table"]
        let res10 = HookChainRepairEngine.repair(originalHookIds: chain10, initialAvailableInputs: initial10, registry: registry)
        
        check("observe_once_repair_passes", res10 != nil)
        if let repaired10 = res10 {
            // run_ocr_once produces page_text -> extract_product_specs -> compare_product_specs -> build_comparison_table -> present_table
            check("observe_once_repair_contains_run_ocr_once", repaired10.contains("run_ocr_once"))
            let mode = registry.definition(for: "run_ocr_once")!.executionMode
            check("observe_once_hook_is_observe_once", mode == .observe_once)
        }
        
        // ══════════════════════════════════════════════════════════════════
        // CASE 11 — extract_entities produces canonical entities key
        // ══════════════════════════════════════════════════════════════════
        if let extractEntitiesDef = registry.definition(for: "extract_entities") {
            print("[DebugExtractEntities] id=\(extractEntitiesDef.id) implemented=\(extractEntitiesDef.isImplemented) produces=\(extractEntitiesDef.produces.map(\.rawValue))")
            let producesCanonical = extractEntitiesDef.produces.contains(.extracted_entities)
            check("extract_entities_produces_canonical_entities", producesCanonical)
            
            // Verify it can be consumed downstream by compare_options or bridged deterministically
            if let compareOptionsDef = registry.definition(for: "compare_options") {
                let requiredInput = compareOptionsDef.requires.first
                let isCompatible = requiredInput != nil && HookIOSemanticBridge.isCompatible(from: .extracted_entities, to: requiredInput!)
                check("canonical_entities_consumed_by_compare_options", isCompatible)
            } else {
                check("compare_options_exists", false)
            }
        } else {
            check("extract_entities_exists", false)
        }
        
        if failures == 0 {
            print("[HookChainRepairSelfTest] ok=true failures=0")
        } else {
            print("[HookChainRepairSelfTest] ok=false failures=\(failures)")
        }
    }
}
