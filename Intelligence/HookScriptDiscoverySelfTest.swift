// HookScriptDiscoverySelfTest.swift
// Tests the multi-pass HookScriptDiscovery planner using mocks.
//
// Triggered by: CONTEXTUAL_RUN_HOOK_SCRIPT_DISCOVERY_SELFTEST=1
// Uses mock paths (no Ollama calls) for deterministic results.
//
// Expected output:
//   [HookScriptDiscoverySelfTest] started
//   [HookScriptDiscoverySelfTest] case=compare_products result=pass
//   [HookScriptDiscoverySelfTest] case=product_details result=pass
//   [HookScriptDiscoverySelfTest] case=summarize_page result=pass
//   [HookScriptDiscoverySelfTest] case=explain_error result=pass
//   [HookScriptDiscoverySelfTest] case=selected_text_unavailable result=pass
//   [HookScriptDiscoverySelfTest] case=no_valid_hooks result=pass
//   [HookScriptDiscoverySelfTest] ok=true failures=0

import Foundation

@MainActor
enum HookScriptDiscoverySelfTest {

    static func run() {
        print("[HookScriptDiscoverySelfTest] started")

        var failures = 0
        let registry = HookCapabilityRegistry.shared

        func check(name: String, chain: [String]?, expectNil: Bool = false,
                   mustContain: [String] = [], mustNotContain: [String] = []) {
            if expectNil {
                if chain == nil {
                    print("[HookScriptDiscoverySelfTest] case=\(name) result=pass")
                } else {
                    print("[HookScriptDiscoverySelfTest] case=\(name) result=fail reason=expected_nil got=[\(chain!.joined(separator: ","))]")
                    failures += 1
                }
                return
            }
            guard let c = chain else {
                print("[HookScriptDiscoverySelfTest] case=\(name) result=fail reason=nil_chain")
                failures += 1
                return
            }
            // Must end with presentation or app_control
            let lastId = c.last ?? ""
            let lastDef = registry.all.first(where: { $0.id == lastId })
            guard lastDef?.category == .presentation || lastDef?.category == .app_control else {
                print("[HookScriptDiscoverySelfTest] case=\(name) result=fail reason=no_presentation_end chain=[\(c.joined(separator: ","))]")
                failures += 1
                return
            }
            // Must contain required hooks
            for required in mustContain {
                guard c.contains(required) else {
                    print("[HookScriptDiscoverySelfTest] case=\(name) result=fail reason=missing_hook \(required) chain=[\(c.joined(separator: ","))]")
                    failures += 1
                    return
                }
            }
            // Must NOT contain excluded hooks
            for excluded in mustNotContain {
                guard !c.contains(excluded) else {
                    print("[HookScriptDiscoverySelfTest] case=\(name) result=fail reason=unexpected_hook \(excluded) chain=[\(c.joined(separator: ","))]")
                    failures += 1
                    return
                }
            }
            print("[HookScriptDiscoverySelfTest] case=\(name) result=pass chain=[\(c.joined(separator: ","))]")
        }

        // Build a fake snapshot with no selected text
        let emptySnapshot = makeSnapshot(hasSelectedText: false, hasOCR: false)
        let selSnapshot   = makeSnapshot(hasSelectedText: true, hasOCR: false)
        let candidates = registry.all

        // Case 1: compare products → should include a compare + presentation hook
        let compareChain = HookScriptDiscovery.executeMock(
            goal: "Compare SOLIX models by capacity and price",
            candidates: candidates,
            snapshot: emptySnapshot
        )
        check(name: "compare_products", chain: compareChain, mustContain: ["compare_product_specs"])

        // Case 2: product details → should include extract_product_specs + presentation
        let detailChain = HookScriptDiscovery.executeMock(
            goal: "Show product specs and details",
            candidates: candidates,
            snapshot: emptySnapshot
        )
        check(name: "product_details", chain: detailChain, mustContain: ["extract_product_specs"])

        // Case 3: summarize page → should include summarize_visible_page
        let summaryChain = HookScriptDiscovery.executeMock(
            goal: "Summarize the visible page content",
            candidates: candidates,
            snapshot: emptySnapshot
        )
        check(name: "summarize_page", chain: summaryChain, mustContain: ["summarize_visible_page"])

        // Case 4: explain error → should produce a valid chain with presentation
        let errorChain = HookScriptDiscovery.executeMock(
            goal: "Explain error in terminal output",
            candidates: candidates,
            snapshot: emptySnapshot
        )
        check(name: "explain_error", chain: errorChain)

        // Case 5: selected_text_unavailable → must NOT include read_selected_text
        let noSelChain = HookScriptDiscovery.executeMock(
            goal: "selected_text_unavailable test scenario",
            candidates: candidates,
            snapshot: emptySnapshot   // no selected text
        )
        check(name: "selected_text_unavailable", chain: noSelChain, mustNotContain: ["read_selected_text"])

        // Case 6: no valid hooks → should return nil
        let noHookChain = HookScriptDiscovery.executeMock(
            goal: "impossible no valid hooks scenario",
            candidates: [],           // no candidates
            snapshot: emptySnapshot
        )
        check(name: "no_valid_hooks", chain: noHookChain, expectNil: true)

        // Case 7: Xcode domain filter — product/shopping hooks must NOT appear in debugging workflow
        // HookDomainFilter removes shopping-specific hooks before the chain builder sees them.
        let xcodeCandidates = HookDomainFilter.filter(
            candidates: candidates,
            workflow: .debugging,
            app: "Xcode"
        )
        let xcodeChain = HookScriptDiscovery.executeMock(
            goal: "Summarize what this Swift file does",
            candidates: xcodeCandidates,
            snapshot: emptySnapshot
        )
        let shoppingHookIds = ["extract_product_specs", "extract_price_and_rating",
                                "compare_product_specs", "identify_purchase_tradeoffs",
                                "summarize_visible_reviews"]
        check(name: "xcode_domain_filter", chain: xcodeChain,
              mustNotContain: shoppingHookIds)

        // Case 8: Shopping domain — product hooks must be available in browsing workflow
        let shoppingCandidates = HookDomainFilter.filter(
            candidates: candidates,
            workflow: .browsing,
            app: "Safari"
        )
        let amazonChain = HookScriptDiscovery.executeMock(
            goal: "Compare SOLIX models by capacity and price",
            candidates: shoppingCandidates,
            snapshot: emptySnapshot
        )
        check(name: "shopping_domain_filter", chain: amazonChain,
              mustContain: ["compare_product_specs"])

        // Case 9 (Task D): Generic hook fit — goal with no product/price/purchase intent
        // should result in product-specific hooks being rejected by HookCandidateFit,
        // while generic hooks (summarize, extract facts, etc.) remain available.
        // This is validated via candidatesForStep which applies the goal fit filter.
        // Here we verify via executeMock that a non-product goal produces a non-product chain.
        let genericGoalSnapshot = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "SelfTest",
            windowTitle: "quarterly review notes",
            selectedText: nil,
            clipboardText: nil,
            recentOCRExcerpt: nil
        )
        // browsing candidates include shopping hooks; but goal has no product intent
        let browsingCandidatesForFit = HookDomainFilter.filter(
            candidates: candidates,
            workflow: .browsing,
            app: "SelfTest"
        )
        // executeMock uses goal keywords, so "summarize" → summarize_visible_page chain (not product chain)
        let genericChain = HookScriptDiscovery.executeMock(
            goal: "Summarize the visible page content and extract key points",
            candidates: browsingCandidatesForFit,
            snapshot: genericGoalSnapshot
        )
        let productOnlyIds: [String] = [
            "extract_product_specs", "extract_price_and_rating",
            "compare_product_specs", "identify_purchase_tradeoffs",
            "summarize_visible_reviews"
        ]
        check(name: "generic_goal_no_product_hooks", chain: genericChain,
              mustNotContain: productOnlyIds)

        // Case 10 (Task D): Product-goal selects product hooks.
        // A goal explicitly mentioning "product specs" should produce a product-hook chain.
        let productChainMock = HookScriptDiscovery.executeMock(
            goal: "Extract product specs and compare models by price",
            candidates: browsingCandidatesForFit,
            snapshot: emptySnapshot
        )
        check(name: "product_goal_gets_product_hooks", chain: productChainMock,
              mustContain: ["compare_product_specs"])

        print("[HookScriptDiscoverySelfTest] ok=\(failures == 0) failures=\(failures)")
    }

    // MARK: - Snapshot helpers

    private static func makeSnapshot(hasSelectedText: Bool, hasOCR: Bool) -> CanonicalGeneratedExecutionContextSnapshot {
        CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "SelfTest",
            windowTitle: "selftest",
            selectedText: hasSelectedText ? "selected sample text" : nil,
            clipboardText: nil,
            recentOCRExcerpt: hasOCR ? "ocr sample text" : nil
        )
    }
}
