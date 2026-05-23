// LiveChainSelfTest.swift
// Part H: Live verification of HookScriptDiscovery with real Ollama calls.
// Tests three specific scenarios: shopping, coding, no-selection.
//
// Triggered by: CONTEXTUAL_RUN_LIVE_CHAIN_SELFTEST=1
// Uses real Ollama calls (qwen2.5:1.5b) — requires Ollama running.
//
// Expected output:
//   [LiveChainSelfTest] started
//   [LiveChainSelfTest] case=shopping result=pass chain=[...] contains_product_hook=true
//   [LiveChainSelfTest] case=coding result=pass chain=[...] no_shopping_hooks=true
//   [LiveChainSelfTest] case=no_selection result=pass chain=[...] no_read_selected_text=true
//   [LiveChainSelfTest] ok=true failures=0

import Foundation

struct LiveChainSelfTest {

    static func run() async {
        print("[LiveChainSelfTest] started")

        let registry = HookCapabilityRegistry.shared
        let candidates = registry.all

        var failures = 0

        // ── Case 1: Shopping context ──────────────────────────────────────────
        // Expect: chain contains a product-spec or comparison hook
        let shoppingSnap = makeSnapshot(app: "Safari",
                                        title: "Anker SOLIX C1000 Portable Power Station – Amazon.com",
                                        hasSelectedText: false,
                                        hasOCR: false)
        let shoppingGoal = "Extract product specs and compare SOLIX models by capacity and price"

        if let chain = await HookScriptDiscovery.buildChainForLiveTest(
            goal: shoppingGoal,
            candidates: candidates,
            snapshot: shoppingSnap,
            workflow: .browsing
        ) {
            let productHooks: Set<String> = [
                "extract_product_specs", "extract_price_and_rating",
                "compare_product_specs", "build_comparison_table",
                "identify_purchase_tradeoffs", "summarize_visible_reviews"
            ]
            let hasProductHook = chain.contains { productHooks.contains($0) }
            let hasPresentation = chain.contains { id in
                registry.all.first(where: { $0.id == id })?.category == .presentation
            }
            let ok = hasProductHook && hasPresentation
            if ok {
                print("[LiveChainSelfTest] case=shopping result=pass chain=[\(chain.joined(separator: ","))] contains_product_hook=true")
            } else {
                print("[LiveChainSelfTest] case=shopping result=fail chain=[\(chain.joined(separator: ","))] contains_product_hook=\(hasProductHook) has_presentation=\(hasPresentation)")
                failures += 1
            }
        } else {
            print("[LiveChainSelfTest] case=shopping result=fail reason=nil_chain")
            failures += 1
        }

        // ── Case 2: Coding context ────────────────────────────────────────────
        // Expect: chain does NOT contain shopping-specific hooks; ends with presentation
        let codingSnap = makeSnapshot(app: "Xcode",
                                      title: "TaskInferenceEngine.swift — Contextual",
                                      hasSelectedText: false,
                                      hasOCR: false)
        let codingGoal = "Summarize what this Swift file does and identify key functions"

        if let chain = await HookScriptDiscovery.buildChainForLiveTest(
            goal: codingGoal,
            candidates: candidates,
            snapshot: codingSnap,
            workflow: .debugging
        ) {
            let shoppingOnlyHooks: Set<String> = [
                "extract_product_specs", "extract_price_and_rating",
                "compare_product_specs", "build_comparison_table",
                "identify_purchase_tradeoffs", "summarize_visible_reviews"
            ]
            let hasShoppingHook = chain.contains { shoppingOnlyHooks.contains($0) }
            let hasPresentation = chain.contains { id in
                registry.all.first(where: { $0.id == id })?.category == .presentation
            }
            let ok = !hasShoppingHook && hasPresentation
            if ok {
                print("[LiveChainSelfTest] case=coding result=pass chain=[\(chain.joined(separator: ","))] no_shopping_hooks=true")
            } else {
                print("[LiveChainSelfTest] case=coding result=fail chain=[\(chain.joined(separator: ","))] no_shopping_hooks=\(!hasShoppingHook) has_presentation=\(hasPresentation)")
                failures += 1
            }
        } else {
            print("[LiveChainSelfTest] case=coding result=fail reason=nil_chain")
            failures += 1
        }

        // ── Case 3: No selection ──────────────────────────────────────────────
        // Expect: read_selected_text is NOT in the chain (Part E validation)
        let noSelSnap = makeSnapshot(app: "Safari",
                                     title: "WWDC25 Session: What's New in Swift",
                                     hasSelectedText: false,
                                     hasOCR: false)
        let noSelGoal = "Summarize the visible page content and extract key points"

        if let chain = await HookScriptDiscovery.buildChainForLiveTest(
            goal: noSelGoal,
            candidates: candidates,
            snapshot: noSelSnap,
            workflow: .browsing
        ) {
            let hasReadSel = chain.contains("read_selected_text")
            let hasPresentation = chain.contains { id in
                registry.all.first(where: { $0.id == id })?.category == .presentation
            }
            let ok = !hasReadSel && hasPresentation
            if ok {
                print("[LiveChainSelfTest] case=no_selection result=pass chain=[\(chain.joined(separator: ","))] no_read_selected_text=true")
            } else {
                print("[LiveChainSelfTest] case=no_selection result=fail chain=[\(chain.joined(separator: ","))] no_read_selected_text=\(!hasReadSel) has_presentation=\(hasPresentation)")
                failures += 1
            }
        } else {
            print("[LiveChainSelfTest] case=no_selection result=fail reason=nil_chain")
            failures += 1
        }

        print("[LiveChainSelfTest] ok=\(failures == 0) failures=\(failures)")
    }

    // MARK: - Snapshot helpers

    private static func makeSnapshot(
        app: String,
        title: String,
        hasSelectedText: Bool,
        hasOCR: Bool
    ) -> CanonicalGeneratedExecutionContextSnapshot {
        CanonicalGeneratedExecutionContextSnapshot(
            activeApp: app,
            windowTitle: title,
            selectedText: hasSelectedText ? "sample selected text" : nil,
            clipboardText: nil,
            recentOCRExcerpt: hasOCR ? "sample ocr text" : nil
        )
    }
}
