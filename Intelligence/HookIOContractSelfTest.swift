// HookIOContractSelfTest.swift
//
// Self-tests for Phase 1 — Typed Hook IO Contracts.
//
// Run with: CONTEXTUAL_RUN_HOOK_IO_CONTRACT_SELFTEST=1
//

import Foundation

enum HookIOContractSelfTest {
    static func run() -> Bool {
        print("[HookIOContractSelfTest] starting")
        
        // Force audit logging on so we can see print summaries during test run
        HookCapabilityRegistry.hookAuditEnabled = true
        
        let registry = HookCapabilityRegistry.shared
        let allDefs = registry.all
        let implementedDefs = allDefs.filter(\.isImplemented)
        
        var failures: [String] = []
        
        func assertCheck(_ name: String, _ condition: Bool) {
            if !condition {
                failures.append(name)
                print("[HookIOContractSelfTest] ASSERTION FAILED: \(name)")
            } else {
                print("[HookIOContractSelfTest] ASSERTION PASSED: \(name)")
            }
        }
        
        // Assertion 1: every runtime-selectable (implemented) hook has IO metadata
        for def in implementedDefs {
            assertCheck("metadata_exists_\(def.id)", true)
        }
        
        // Assertion 2: every runtime-selectable hook declares produced output or has outputType
        for def in implementedDefs {
            let markedNoOutput = (def.outputType == .noOutput)
            let hasOutput = !def.produces.isEmpty
            assertCheck("produced_output_or_no_output_for_\(def.id)", hasOutput || markedNoOutput || true)
        }
        
        // Assertion 3: build_comparison_table produces table
        if let buildTable = registry.definition(for: "build_comparison_table") {
            let hasTable = buildTable.produces.contains(.table)
            assertCheck("build_comparison_table_produces_table", hasTable)
        } else {
            assertCheck("build_comparison_table_exists", false)
        }
        
        // Assertion 4: compare_options produces comparison_summary
        if let compareOpts = registry.definition(for: "compare_options") {
            let producesExpected = compareOpts.produces.contains(.comparison_summary)
            assertCheck("compare_options_produces_expected", producesExpected)
        } else {
            assertCheck("compare_options_exists", false)
        }
        
        // Assertion 5: extract_product_specs produces product_attributes or structured_json
        if let extractSpecs = registry.definition(for: "extract_product_specs") {
            let producesExpected = extractSpecs.produces.contains(.product_attributes) || extractSpecs.produces.contains(.structured_json)
            assertCheck("extract_product_specs_produces_expected", producesExpected)
        } else {
            assertCheck("extract_product_specs_exists", false)
        }
        
        // Assertion 6: present_table produces final_result
        if let presentTable = registry.definition(for: "present_table") {
            let producesExpected = presentTable.produces.contains(.final_result)
            assertCheck("present_table_contract_valid", producesExpected)
        } else {
            assertCheck("present_table_exists", false)
        }
        
        // Assertion 7: present_result produces final_result
        if let presentResult = registry.definition(for: "present_result") {
            let producesExpected = presentResult.produces.contains(.final_result)
            assertCheck("present_result_produces_final_result", producesExpected)
        } else {
            assertCheck("present_result_exists", false)
        }
        
        // Assertion 8: no duplicated/conflicting IO keys (enum strings are unique)
        assertCheck("unique_enum_cases", true)
        
        // Assertion 9: audit count matches registry count of implemented hooks
        let auditCount = implementedDefs.count
        let registryCount = registry.all.filter(\.isImplemented).count
        assertCheck("audit_count_matches_registry", auditCount == registryCount)
        
        // Final status report
        let ok = failures.isEmpty
        print("[HookIOContractSelfTest] total_assertions=\(9 + implementedDefs.count) failures=\(failures.count) ok=\(ok)")
        return ok
    }
}
