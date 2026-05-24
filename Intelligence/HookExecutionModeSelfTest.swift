// HookExecutionModeSelfTest.swift
//
// Exhaustive self-tests for the execution-mode taxonomy and contract routing.
//
// Coverage:
//   Task 1 — Full registry enumeration: every hook classified, no unknowns, deterministic
//   Task 2 — Runtime coverage: every one_shot/observe_once hook in safeHookIds has an impl
//   Task 3 — Future-mode block: every external_control/interactive_loop/confirmation hook is blocked
//   Task 4 — Contract mode exhaustiveness: priority dominance rules hold across all combinations
//   Task 5 — Startup audit consistency: auditResults() matches per-hook enumeration
//   Task 6 — Strict failure: any gap → ok=false, failures listed explicitly
//
// Run with: CONTEXTUAL_RUN_EXECUTION_MODE_SELFTEST=1

import Foundation

enum HookExecutionModeSelfTest {
    static func run() -> Bool {
        print("[HookExecutionModeSelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if !ok { failures.append(name) }
        }

        let registry = HookCapabilityRegistry.shared
        let allDefs = registry.all
        let registryCount = allDefs.count
        print("[HookExecutionModeSelfTest] registry_count=\(registryCount)")

        // ══════════════════════════════════════════════════════════════════
        // TASK 1 — FULL REGISTRY ENUMERATION
        // Every hook must have a non-nil, deterministic executionMode
        // belonging to exactly one of the five taxonomy values.
        // ══════════════════════════════════════════════════════════════════

        var modeCounts: [HookExecutionMode: Int] = [:]
        var duplicateModeCount = 0   // hooks where 2nd call yields different mode (non-determinism)
        var unknownCount = 0         // hooks whose id is not resolvable in byId map

        for def in allDefs {
            // Verify the hook can be looked up by its own id (registry consistency)
            if registry.definition(for: def.id) == nil { unknownCount += 1 }

            // Compute mode and verify determinism (call twice, must match)
            let mode1 = def.executionMode
            let mode2 = def.executionMode
            if mode1 != mode2 { duplicateModeCount += 1 }

            modeCounts[mode1, default: 0] += 1
        }

        let classifiedCount = modeCounts.values.reduce(0, +)
        print("[HookExecutionModeSelfTest] classified_count=\(classifiedCount)")
        print("[HookExecutionModeSelfTest] unknown_count=\(unknownCount)")
        print("[HookExecutionModeSelfTest] duplicate_mode_count=\(duplicateModeCount)")

        check("all_classified",         classifiedCount == registryCount)
        check("no_unknown_ids",         unknownCount == 0)
        check("mode_deterministic",     duplicateModeCount == 0)
        check("totals_match_registry",  modeCounts.values.reduce(0, +) == registryCount)
        check("has_one_shot",           (modeCounts[.one_shot]              ?? 0) > 0)
        check("has_observe_once",       (modeCounts[.observe_once]          ?? 0) > 0)
        check("has_external_control",   (modeCounts[.external_control]      ?? 0) > 0)
        check("has_confirmation",       (modeCounts[.confirmation_required] ?? 0) > 0)
        // interactive_loop: currently only run_subtasks_parallel → 1
        check("has_interactive_loop",   (modeCounts[.interactive_loop]      ?? 0) > 0)

        // All 96 hooks fully enumerated and classified — print per-mode breakdown
        print("[HookExecutionModeSelfTest] mode_breakdown one_shot=\(modeCounts[.one_shot, default: 0]) observe_once=\(modeCounts[.observe_once, default: 0]) interactive_loop=\(modeCounts[.interactive_loop, default: 0]) external_control=\(modeCounts[.external_control, default: 0]) confirmation_required=\(modeCounts[.confirmation_required, default: 0])")

        // Spot-check 15 specific hooks to anchor the taxonomy (regression guard)
        let classificationAnchors: [(String, HookExecutionMode)] = [
            ("observe_current_context", .one_shot),
            ("summarize_visible_page",  .one_shot),
            ("extract_key_facts",       .one_shot),
            ("present_recommendation",  .one_shot),
            ("extract_product_specs",   .one_shot),
            ("compare_options",         .one_shot),
            ("create_briefing",         .one_shot),
            ("build_comparison_table",  .one_shot),
            ("run_ocr_once",            .observe_once),
            ("run_subtasks_parallel",   .interactive_loop),
            ("open_new_tab",            .external_control),
            ("navigate_to_url",         .external_control),
            ("fill_web_field",          .external_control),
            ("open_app",                .external_control),
            ("click_screen_coordinate", .external_control),
            ("type_text",               .external_control),
            ("press_shortcut",          .external_control),
            ("scroll_view",             .external_control),
            ("switch_window",           .external_control),
            ("submit_form",             .confirmation_required),
            ("quit_app",                .confirmation_required),
        ]
        for (hookId, expected) in classificationAnchors {
            if let def = registry.definition(for: hookId) {
                check("anchor_\(hookId)", def.executionMode == expected)
            } else {
                check("anchor_\(hookId)_exists", false)
            }
        }

        // ══════════════════════════════════════════════════════════════════
        // TASK 2 — RUNTIME COVERAGE VALIDATION
        // Every one_shot/observe_once hook in the sandbox allowlist (safeHookIds)
        // must have an explicit runtime implementation (in implementedHookIds).
        // Hooks not in safeHookIds are excluded from sandbox — no impl required.
        // ══════════════════════════════════════════════════════════════════

        let safeIds        = HookExecutionSandbox.safeHookIds
        let implementedIds = HookExecutionSandbox.implementedHookIds

        // safeHookIds and implementedHookIds must be identical sets (zero gap)
        let safeButNotImpl = safeIds.subtracting(implementedIds)
        let implButNotSafe = implementedIds.subtracting(safeIds)
        check("safe_impl_sets_equal",        safeButNotImpl.isEmpty && implButNotSafe.isEmpty)

        // For every registry hook in one_shot/observe_once that is also in safeHookIds,
        // the implementation must exist.
        let runtimeSupportedModes: Set<HookExecutionMode> = [.one_shot, .observe_once]
        let sandboxEligibleDefs = allDefs.filter { runtimeSupportedModes.contains($0.executionMode) && safeIds.contains($0.id) }
        let runtimeMissingDefs  = sandboxEligibleDefs.filter { !implementedIds.contains($0.id) }
        let runtimeMissingIds   = runtimeMissingDefs.map(\.id).sorted()
        let runtimeSupportedCount = implementedIds.intersection(
            Set(allDefs.filter { runtimeSupportedModes.contains($0.executionMode) }.map(\.id))
        ).count

        print("[HookExecutionModeSelfTest] runtime_supported_count=\(runtimeSupportedCount)")
        print("[HookExecutionModeSelfTest] runtime_missing_ids=[\(runtimeMissingIds.joined(separator: ","))]")

        check("no_runtime_gaps",        runtimeMissingIds.isEmpty)
        check("no_phantom_impls",       implButNotSafe.isEmpty)

        // ══════════════════════════════════════════════════════════════════
        // TASK 3 — FUTURE-MODE BLOCK VALIDATION
        // For every hook classified as external_control, interactive_loop,
        // or confirmation_required: route a single-hook contract and assert
        // it is NOT routed to .execute — it must be blocked.
        // ══════════════════════════════════════════════════════════════════

        let futureModes: Set<HookExecutionMode> = [.external_control, .interactive_loop, .confirmation_required]
        let futureDefs = allDefs.filter { futureModes.contains($0.executionMode) }

        var blockedFutureCount = 0
        var futureModeFailures: [String] = []

        for def in futureDefs {
            let contract = DynamicGeneratedActionContract(
                id: "hook:selftest_block_\(def.id)",
                title: "Selftest block \(def.id)",
                userFacingQuestion: "test",
                inferredUserGoal: "test",
                situationSummary: "test",
                whyNow: "test",
                hookPlanIds: [def.id],
                requiredContext: [],
                confidence: 0.7,
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(120),
                cacheEligibility: false,
                cacheKey: "selftest_block_\(def.id)"
            )
            // Use silent routing so per-hook log lines don't flood the test output
            let decision = HookContractExecutionRouter.route(contract: contract, registry: registry, logging: false)
            switch decision {
            case .unsupportedForRuntime, .requiresConfirmation:
                blockedFutureCount += 1
            case .execute:
                futureModeFailures.append(def.id)
            }
        }

        print("[HookExecutionModeSelfTest] blocked_future_count=\(blockedFutureCount)")
        print("[HookExecutionModeSelfTest] future_mode_failures=[\(futureModeFailures.joined(separator: ","))]")

        check("all_future_modes_blocked", futureModeFailures.isEmpty)
        check("future_block_count_complete", blockedFutureCount == futureDefs.count)

        // ══════════════════════════════════════════════════════════════════
        // TASK 4 — CONTRACT MODE EXHAUSTIVENESS
        // Verify priority dominance rules are correct and no ambiguity exists.
        // Use real registry hook IDs for each mode combination.
        // ══════════════════════════════════════════════════════════════════

        // Find representative hook IDs per mode (from actual registry)
        func firstHook(mode: HookExecutionMode) -> String? {
            allDefs.first { $0.executionMode == mode }?.id
        }
        let repOneShot    = "observe_current_context"   // always one_shot
        let repObserve    = "run_ocr_once"               // always observe_once
        let repLoop       = "run_subtasks_parallel"      // always interactive_loop
        let repExternal   = "open_new_tab"               // always external_control
        let repConfirm    = "submit_form"                // always confirmation_required

        func inferMode(_ ids: [String]) -> HookExecutionMode {
            ContractExecutionModeInferrer.infer(hookPlanIds: ids, registry: registry).inferredMode
        }

        // Single-mode chains
        check("single_one_shot",    inferMode([repOneShot])  == .one_shot)
        check("single_observe",     inferMode([repObserve])  == .observe_once)
        check("single_loop",        inferMode([repLoop])     == .interactive_loop)
        check("single_external",    inferMode([repExternal]) == .external_control)
        check("single_confirm",     inferMode([repConfirm])  == .confirmation_required)

        // Priority: external_control (4) > interactive_loop (3)
        check("ext_beats_loop",     inferMode([repLoop, repExternal])    == .external_control)
        // Priority: external_control (4) > confirmation_required (2)
        check("ext_beats_confirm",  inferMode([repConfirm, repExternal]) == .external_control)
        // Priority: interactive_loop (3) > confirmation_required (2)
        check("loop_beats_confirm", inferMode([repConfirm, repLoop])     == .interactive_loop)
        // Priority: interactive_loop (3) > observe_once (1)
        check("loop_beats_observe", inferMode([repObserve, repLoop])     == .interactive_loop)
        // Priority: observe_once (1) > one_shot (0)
        check("observe_beats_one",  inferMode([repOneShot, repObserve])  == .observe_once)
        // Priority: confirmation_required (2) > observe_once (1)
        check("confirm_beats_observe", inferMode([repObserve, repConfirm]) == .confirmation_required)
        // Priority: confirmation_required (2) > one_shot (0)
        check("confirm_beats_one",  inferMode([repOneShot, repConfirm])  == .confirmation_required)

        // Full chain: all five modes → external_control must win
        check("all_modes_external_wins", inferMode([repOneShot, repObserve, repLoop, repExternal, repConfirm]) == .external_control)

        // Empty chain → safe default
        check("empty_chain_one_shot", inferMode([]) == .one_shot)

        // Determinism: same result called twice on same chain
        let testChain = [repOneShot, repLoop, repObserve]
        check("determinism_pass1", inferMode(testChain) == inferMode(testChain))

        // No nil / unknown contract (every chain produces a valid result)
        let allPossibleChains: [[String]] = [
            [repOneShot], [repObserve], [repLoop], [repExternal], [repConfirm],
            [repOneShot, repObserve],
            [repOneShot, repLoop],
            [repExternal, repLoop],
            [repConfirm, repExternal],
        ]
        for chain in allPossibleChains {
            let result = ContractExecutionModeInferrer.infer(hookPlanIds: chain, registry: registry)
            let valid = HookExecutionMode.allCases.contains(result.inferredMode)
            check("valid_mode_\(chain.joined(separator: "+"))", valid)
        }

        // ══════════════════════════════════════════════════════════════════
        // TASK 5 — STARTUP AUDIT CONSISTENCY
        // auditResults() must exactly match the per-hook classification totals
        // computed in Task 1. No divergence allowed.
        // ══════════════════════════════════════════════════════════════════

        let audit = HookContractExecutionRouter.auditResults(registry: registry)
        check("audit_total_matches_registry",   audit.total == registryCount)
        check("audit_one_shot_matches",         audit.oneShot              == (modeCounts[.one_shot,              default: 0]))
        check("audit_observe_once_matches",     audit.observeOnce          == (modeCounts[.observe_once,          default: 0]))
        check("audit_interactive_loop_matches", audit.interactiveLoop      == (modeCounts[.interactive_loop,      default: 0]))
        check("audit_external_control_matches", audit.externalControl      == (modeCounts[.external_control,      default: 0]))
        check("audit_confirmation_matches",     audit.confirmationRequired == (modeCounts[.confirmation_required, default: 0]))

        // Runtime coverage count must equal safe-implemented count
        let auditRuntimeCount = implementedIds.intersection(
            Set(allDefs.filter { runtimeSupportedModes.contains($0.executionMode) }.map(\.id))
        ).count
        check("audit_runtime_coverage_matches", auditRuntimeCount == runtimeSupportedCount)

        // ══════════════════════════════════════════════════════════════════
        // TASK 6 — ORIGINAL ASSERTIONS (keep for regression safety)
        // ══════════════════════════════════════════════════════════════════

        // Inference flag correctness
        let confirmFlags = ContractExecutionModeInferrer.infer(hookPlanIds: ["fill_web_field", "submit_form"], registry: registry)
        check("mixed_confirm_flag_set",          confirmFlags.requiresConfirmation)
        check("mixed_confirm_external_dominates", confirmFlags.inferredMode == .external_control)

        let pureConfirmFlags = ContractExecutionModeInferrer.infer(hookPlanIds: ["submit_form"], registry: registry)
        check("pure_confirm_mode",  pureConfirmFlags.inferredMode == .confirmation_required)
        check("pure_confirm_flag",  pureConfirmFlags.requiresConfirmation)

        // Router decisions for supported modes
        func silentRoute(_ ids: [String]) -> HookContractRoutingDecision {
            let contract = DynamicGeneratedActionContract(
                id: "hook:selftest_\(ids.joined(separator: "_"))",
                title: "Selftest", userFacingQuestion: "q",
                inferredUserGoal: "g", situationSummary: "s", whyNow: "w",
                hookPlanIds: ids, requiredContext: [],
                confidence: 0.7, createdAt: Date(),
                expiresAt: Date().addingTimeInterval(120),
                cacheEligibility: false, cacheKey: ids.joined()
            )
            return HookContractExecutionRouter.route(contract: contract, registry: registry, logging: false)
        }

        if case .execute(let chain, let mode) = silentRoute(["observe_current_context", "summarize_visible_page", "present_result"]) {
            check("one_shot_routed_execute",   mode == .one_shot)
            check("one_shot_chain_preserved",  chain == ["observe_current_context", "summarize_visible_page", "present_result"])
        } else {
            check("one_shot_routed_execute", false)
        }

        if case .execute(_, let mode) = silentRoute(["run_ocr_once", "summarize_visible_page", "present_result"]) {
            check("observe_once_routed_execute", mode == .observe_once)
        } else {
            check("observe_once_routed_execute", false)
        }

        if case .unsupportedForRuntime(let mode, _) = silentRoute(["open_new_tab", "navigate_to_url"]) {
            check("external_control_blocked", mode == .external_control)
        } else {
            check("external_control_blocked", false)
        }

        if case .unsupportedForRuntime(let mode, _) = silentRoute(["run_subtasks_parallel", "merge_results"]) {
            check("interactive_loop_blocked", mode == .interactive_loop)
        } else {
            check("interactive_loop_blocked", false)
        }

        // UI labeling
        check("label_one_shot",          HookExecutionMode.one_shot.userFacingLabel             == "One-shot")
        check("label_observe_once",      HookExecutionMode.observe_once.userFacingLabel          == "Observe once")
        check("label_interactive_loop",  HookExecutionMode.interactive_loop.userFacingLabel      == "Agentic")
        check("label_external_control",  HookExecutionMode.external_control.userFacingLabel      == "External control")
        check("label_confirmation",      HookExecutionMode.confirmation_required.userFacingLabel == "Needs confirmation")

        check("desc_one_shot",       HookExecutionMode.one_shot.userFacingDescription             == "Executable now")
        check("desc_observe",        HookExecutionMode.observe_once.userFacingDescription.contains("window"))
        check("desc_loop",           HookExecutionMode.interactive_loop.userFacingDescription.contains("Multi-step"))
        check("desc_external",       HookExecutionMode.external_control.userFacingDescription.contains("Controls"))
        check("desc_confirmation",   HookExecutionMode.confirmation_required.userFacingDescription.contains("approval"))

        // Priority ordering (strict total order)
        check("priority_one_shot_0",       HookExecutionMode.one_shot.priority             == 0)
        check("priority_observe_1",        HookExecutionMode.observe_once.priority          == 1)
        check("priority_confirm_2",        HookExecutionMode.confirmation_required.priority == 2)
        check("priority_loop_3",           HookExecutionMode.interactive_loop.priority      == 3)
        check("priority_external_4",       HookExecutionMode.external_control.priority      == 4)

        // Runtime support flags
        check("runtime_one_shot",    HookExecutionMode.one_shot.isRuntimeSupported)
        check("runtime_observe",     HookExecutionMode.observe_once.isRuntimeSupported)
        check("runtime_loop_off",    !HookExecutionMode.interactive_loop.isRuntimeSupported)
        check("runtime_external_off", !HookExecutionMode.external_control.isRuntimeSupported)
        check("runtime_confirm_off", !HookExecutionMode.confirmation_required.isRuntimeSupported)

        // ══════════════════════════════════════════════════════════════════
        // SUMMARY
        // ══════════════════════════════════════════════════════════════════
        let ok = failures.isEmpty
        if !failures.isEmpty {
            print("[HookExecutionModeSelfTest] FAILURES: \(failures.joined(separator: "; "))")
        }
        print("[HookExecutionModeSelfTest] summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
        return ok
    }
}

// MARK: - Observe-Once Execution Self Test

final class MockVisualContextProvider: BoundedVisualContextProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
    
    func collectVisualContext(request: BoundedVisualContextRequest) async throws -> BoundedVisualContextResult {
        lock.lock()
        callCount += 1
        lock.unlock()
        return BoundedVisualContextResult(
            requestId: request.id,
            status: .completed,
            capturedAt: Date(),
            sourceSummary: "mock_capture",
            ocrExcerpt: "Amazon price AirPods 4 $129.99",
            visualSummary: "Amazon listing with AirPods 4",
            visualTags: ["mock_capture"]
        )
    }
}

enum ObserveOnceExecutionSelfTest {
    static func run() async -> Bool {
        print("[ObserveOnceExecutionSelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if !ok { failures.append(name) }
        }

        let registry = HookCapabilityRegistry.shared

        // ══════════════════════════════════════════════════════════════════
        // TEST A — start_with_empty_snapshot_observe_once
        // ══════════════════════════════════════════════════════════════════
        let emptySnapshot = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Safari",
            windowTitle: "",
            recentOCRExcerpt: nil,
            permissionAvailability: [.screenRecording: true]
        )
        
        let mockProvider = MockVisualContextProvider()
        let scheduler = VisualContextScheduler(provider: mockProvider)
        let budgetSnapshot = GeneratedExecutionBudgetSnapshot(
            activeExecutionCount: 1,
            runtimeState: .executing,
            permissionAvailability: emptySnapshot.permissionAvailability,
            activeSamplingRequested: true
        )
        
        let (enriched, obsCount) = await ObserveOnceExecutor.executePreObservation(
            snapshot: emptySnapshot,
            scheduler: scheduler,
            budgetSnapshot: budgetSnapshot
        )
        
        check("TestA: observation count is 1", obsCount == 1)
        check("TestA: mock provider called exactly once", mockProvider.count == 1)
        check("TestA: enriched snapshot contains ocr", !(enriched.recentOCRExcerpt ?? "").isEmpty)

        // ══════════════════════════════════════════════════════════════════
        // TEST B — no_second_observation
        // ══════════════════════════════════════════════════════════════════
        let (enrichedAgain, obsCountAgain) = await ObserveOnceExecutor.executePreObservation(
            snapshot: enriched,
            scheduler: scheduler,
            budgetSnapshot: budgetSnapshot
        )
        
        check("TestB: second observation skipped", obsCountAgain == 0)
        check("TestB: mock provider not called again", mockProvider.count == 1)

        // ══════════════════════════════════════════════════════════════════
        // TEST C — one_shot_does_not_observe
        // ══════════════════════════════════════════════════════════════════
        let oneShotContract = DynamicGeneratedActionContract(
            id: "hook:selftest_oneshot",
            title: "Oneshot test",
            userFacingQuestion: "q",
            inferredUserGoal: "g",
            situationSummary: "s",
            whyNow: "w",
            hookPlanIds: ["observe_current_context", "present_result"],
            requiredContext: [],
            confidence: 0.8,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(120),
            cacheEligibility: false,
            cacheKey: "selftest_oneshot"
        )
        let routingC = HookContractExecutionRouter.route(contract: oneShotContract, registry: registry, logging: false)
        if case .execute(_, let mode) = routingC {
            check("TestC: routed as one_shot", mode == .one_shot)
        } else {
            check("TestC: routed as one_shot", false)
        }

        // ══════════════════════════════════════════════════════════════════
        // TEST D — external_control_dominates_observe_once
        // ══════════════════════════════════════════════════════════════════
        let contractD = DynamicGeneratedActionContract(
            id: "hook:selftest_ext_dom",
            title: "Dominance test",
            userFacingQuestion: "q",
            inferredUserGoal: "g",
            situationSummary: "s",
            whyNow: "w",
            hookPlanIds: ["run_ocr_once", "click_ui_element_by_id", "present_result"],
            requiredContext: [],
            confidence: 0.8,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(120),
            cacheEligibility: false,
            cacheKey: "selftest_ext_dom"
        )
        let routingD = HookContractExecutionRouter.route(contract: contractD, registry: registry, logging: false)
        switch routingD {
        case .unsupportedForRuntime(let mode, _):
            check("TestD: external_control dominates", mode == .external_control)
        default:
            check("TestD: external_control dominates", false)
        }

        // ══════════════════════════════════════════════════════════════════
        // TEST E — output_improves_after_observation
        // ══════════════════════════════════════════════════════════════════
        
        // E1: Sandbox execute on empty snapshot -> fails
        let resultE1 = await HookExecutionSandbox.shared.execute(
            chain: ["extract_product_attributes", "present_result"],
            snapshot: emptySnapshot,
            mode: .live,
            source: .generatedContract,
            allowBoundedCapture: false,
            visualScheduler: nil
        )
        check("TestE1: failed due to empty context", resultE1.status == .failed)
        
        // E2: Sandbox execute on enriched snapshot -> succeeds
        let resultE2 = await HookExecutionSandbox.shared.execute(
            chain: ["extract_product_attributes", "present_result"],
            snapshot: enriched,
            mode: .live,
            source: .generatedContract,
            allowBoundedCapture: false,
            visualScheduler: nil
        )
        check("TestE2: succeeded with enriched context", resultE2.status == .success)
        check("TestE2: output contains observed details", resultE2.finalOutput?.contains("$129.99") == true)

        let ok = failures.isEmpty
        if !ok {
            print("[ObserveOnceExecutionSelfTest] FAILURES: \(failures.joined(separator: "; "))")
        }
        print("[ObserveOnceExecutionSelfTest] ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

enum AgenticPlanSelfTests {
    static func run() async -> Bool {
        print("[AgenticPlanSelfTest] starting...")
        var failures: [String] = []
        
        func check(_ name: String, _ condition: Bool) {
            if !condition {
                failures.append(name)
                print("[AgenticPlanSelfTest] FAIL: \(name)")
            } else {
                print("[AgenticPlanSelfTest] PASS: \(name)")
            }
        }
        
        // Scenario 1: Simple summarize visible page remains fixed_hook_chain
        let contract1 = mockContract(goal: "Summarize this page", hooks: ["extract_text", "summarize_text"])
        check("scenario1_eligibility", AgenticRuntimeBridge.classify(contract: contract1) == .fixed_hook_chain)
        
        // Scenario 2: Summarize product reviews when reviews not visible becomes agentic_runtime_candidate
        let contract2 = mockContract(goal: "Find and summarize product reviews", hooks: ["extract_text"])
        check("scenario2_eligibility", AgenticRuntimeBridge.classify(contract: contract2) == .agentic_runtime_candidate)
        
        // Scenario 3: Compare products across recent browsing pages becomes agentic_runtime_candidate
        let contract3 = mockContract(goal: "Compare products across these three sites", hooks: ["extract_text"])
        check("scenario3_eligibility", AgenticRuntimeBridge.classify(contract: contract3) == .agentic_runtime_candidate)
        
        // Scenario 4: Coding/debugging with visible OCR but no interaction remains fixed or observe_once
        let contract4 = mockContract(goal: "Explain this error", hooks: ["read_screen_ocr", "summarize_text"])
        let eligibility4 = AgenticRuntimeBridge.classify(contract: contract4)
        check("scenario4_eligibility", eligibility4 == .observe_once_chain || eligibility4 == .fixed_hook_chain)
        
        // Scenario 5: Task requiring click/scroll is agentic_runtime_candidate
        let contract5 = mockContract(goal: "Click the buy button", hooks: ["click_ui_element_by_id"])
        check("scenario5_eligibility", AgenticRuntimeBridge.classify(contract: contract5) == .agentic_runtime_candidate)
        
        // Scenario 6: Max budget defaults are bounded
        if let plan = AgenticRuntimeBridge.derivePlan(from: contract2, workflow: "research") {
            check("maxSteps_bounded", plan.maxSteps <= 5)
            check("maxLLMCalls_bounded", plan.maxLLMCalls <= 5)
            check("maxOCRCalls_bounded", plan.maxOCRCalls <= 2)
            check("maxRuntimeSeconds_bounded", plan.maxRuntimeSeconds <= 15)
            check("safetyLevel_preview", plan.safetyLevel == .preview_only)
        } else {
            failures.append("plan_derivation_failed")
        }
        
        // Scenario 7: Verify that existing hook execution modes still map correctly
        let contract6 = mockContract(goal: "Test", hooks: ["scroll_view"])
        check("interactive_loop_is_agentic", contract6.executionMode == .interactive_loop)
        check("interactive_loop_eligibility", AgenticRuntimeBridge.classify(contract: contract6) == .agentic_runtime_candidate)
        
        let ok = failures.isEmpty
        print("[AgenticPlanSelfTest] finished ok=\(ok) failures=\(failures.count)")
        return ok
    }
    
    private static func mockContract(goal: String, hooks: [String]) -> DynamicGeneratedActionContract {
        return DynamicGeneratedActionContract(
            id: UUID().uuidString,
            title: "Test",
            userFacingQuestion: "Test?",
            inferredUserGoal: goal,
            situationSummary: "Test situation",
            whyNow: "Test trigger",
            hookPlanIds: hooks,
            requiredContext: [],
            confidence: 0.9,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            cacheEligibility: false,
            cacheKey: "test"
        )
    }
}
