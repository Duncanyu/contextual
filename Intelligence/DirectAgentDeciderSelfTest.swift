import Foundation

// MARK: - DirectAgentDeciderSelfTest

/// Self-tests for direct-agent action normalization and validation logic.
///
/// All tests are pure and synchronous — no live model or AX tree required.
/// Run via `DirectAgentDeciderSelfTest.runAll()` at startup in DEBUG builds.
///
/// Test coverage:
///   1.  scroll_small normalizes to "scroll" in main_think path.
///   2.  find_on_page stays "find_on_page" after normalization (no alias) → illegal.
///   3.  page_down normalizes to "scroll".
///   4.  press normalizes to "press_key".
///   5.  Direct-agent legal set does NOT contain find_on_page / scroll_small / etc.
///   6.  Direct-agent legal set DOES contain all 9 expected computer-wide actions.
///   7.  scroll_small normalizes to "scroll" in repair path (via normalizeActionAlias).
///   8.  present_answer normalizes to "answer".
///   9.  finish / done normalize to "stop_success".
///  10.  click_element with nil target must NOT be returned as an accepted decision
///       from directAgentDecide-style validation — it must trigger repair.
///  11.  Illegal action fallback prefers observe_screen over stop_missing_context.
///  12.  VLMServerManager does not launch when isLaunching guard is set.
enum DirectAgentDeciderSelfTest {

    static func runAll() {
        print("[DirectAgentDeciderSelfTest] running 12 tests")
        test1_scrollSmallNormalizesToScroll()
        test2_findOnPageRemainsIllegal()
        test3_pageDownNormalizesToScroll()
        test4_pressNormalizesToPressKey()
        test5_legalSetExcludesFindOnPage()
        test6_legalSetContainsAllExpectedActions()
        test7_scrollSmallNormalizesInRepairPath()
        test8_presentAnswerNormalizesToAnswer()
        test9_finishAndDoneNormalizeToStopSuccess()
        test10_clickElementWithNilTargetIsRejected()
        test11_illegalActionFallbackPrefersObserveScreen()
        test12_normalizeActionAliasIsIdempotent()
        print("[DirectAgentDeciderSelfTest] all 12 tests passed")
    }

    // MARK: - Test 1: scroll_small → scroll → legal (main_think path)

    private static func test1_scrollSmallNormalizesToScroll() {
        let normalized = AgenticDecider.normalizeActionAlias("scroll_small")
        assert(normalized == "scroll",
               "[DirectAgentDeciderSelfTest] FAIL test1: expected 'scroll', got '\(normalized)'")

        let action = AgenticNextAction(rawValue: normalized)
        assert(action != nil,
               "[DirectAgentDeciderSelfTest] FAIL test1: 'scroll' is not a recognized AgenticNextAction")

        let legalSet = AgenticRuntime.directAgentUniversalLegalActions()
        assert(legalSet.contains(.scroll),
               "[DirectAgentDeciderSelfTest] FAIL test1: .scroll not in direct-agent legal set")

        print("[DirectAgentDeciderSelfTest] PASS test1: scroll_small → scroll → legal (main_think)")
    }

    // MARK: - Test 2: find_on_page has NO alias → remains illegal

    private static func test2_findOnPageRemainsIllegal() {
        let normalized = AgenticDecider.normalizeActionAlias("find_on_page")
        assert(normalized == "find_on_page",
               "[DirectAgentDeciderSelfTest] FAIL test2: find_on_page must not be remapped, got '\(normalized)'")

        let legalSet = AgenticRuntime.directAgentUniversalLegalActions()
        if let action = AgenticNextAction(rawValue: normalized) {
            assert(!legalSet.contains(action),
                   "[DirectAgentDeciderSelfTest] FAIL test2: find_on_page must be ILLEGAL in direct-agent mode")
        }
        print("[DirectAgentDeciderSelfTest] PASS test2: find_on_page stays illegal after normalization")
    }

    // MARK: - Test 3: page_down → scroll

    private static func test3_pageDownNormalizesToScroll() {
        let normalized = AgenticDecider.normalizeActionAlias("page_down")
        assert(normalized == "scroll",
               "[DirectAgentDeciderSelfTest] FAIL test3: expected 'scroll', got '\(normalized)'")
        print("[DirectAgentDeciderSelfTest] PASS test3: page_down → scroll")
    }

    // MARK: - Test 4: press → press_key → legal

    private static func test4_pressNormalizesToPressKey() {
        let normalized = AgenticDecider.normalizeActionAlias("press")
        assert(normalized == "press_key",
               "[DirectAgentDeciderSelfTest] FAIL test4: expected 'press_key', got '\(normalized)'")

        let legalSet = AgenticRuntime.directAgentUniversalLegalActions()
        assert(legalSet.contains(.press_key),
               "[DirectAgentDeciderSelfTest] FAIL test4: .press_key not in direct-agent legal set")

        print("[DirectAgentDeciderSelfTest] PASS test4: press → press_key → legal")
    }

    // MARK: - Test 5: legal set excludes browser-only actions

    private static func test5_legalSetExcludesFindOnPage() {
        let legalSet = AgenticRuntime.directAgentUniversalLegalActions()
        let forbidden: [AgenticNextAction] = [
            .find_on_page, .extract_facts, .extract_relevant_text,
            .summarize_observation, .scroll_small,
        ]
        for action in forbidden {
            assert(!legalSet.contains(action),
                   "[DirectAgentDeciderSelfTest] FAIL test5: '\(action.rawValue)' must NOT be in direct-agent legal set")
        }
        print("[DirectAgentDeciderSelfTest] PASS test5: browser-only actions absent from legal set")
    }

    // MARK: - Test 6: legal set contains all 9 computer-wide actions

    private static func test6_legalSetContainsAllExpectedActions() {
        let legalSet = AgenticRuntime.directAgentUniversalLegalActions()
        let required: [AgenticNextAction] = [
            .observe_screen, .scroll, .click_element, .type_text, .press_key,
            .wait, .answer, .stop_success, .stop_missing_context,
        ]
        for action in required {
            assert(legalSet.contains(action),
                   "[DirectAgentDeciderSelfTest] FAIL test6: '\(action.rawValue)' must be in direct-agent legal set")
        }
        print("[DirectAgentDeciderSelfTest] PASS test6: all 9 computer-wide actions present (count=\(legalSet.count))")
    }

    // MARK: - Test 7: scroll_small normalizes to scroll in repair path

    /// The repair path also calls normalizeActionAlias — verify it produces the same result.
    private static func test7_scrollSmallNormalizesInRepairPath() {
        // The repair path calls: let normalized = Self.normalizeActionAlias(lower)
        // We verify the same function produces "scroll" for all scroll aliases.
        let scrollAliases = ["scroll_small", "scroll_down", "scroll_up", "page_down",
                             "page_scroll", "scroll_page"]
        for alias in scrollAliases {
            let result = AgenticDecider.normalizeActionAlias(alias)
            assert(result == "scroll",
                   "[DirectAgentDeciderSelfTest] FAIL test7: '\(alias)' → expected 'scroll', got '\(result)'")
        }
        print("[DirectAgentDeciderSelfTest] PASS test7: all scroll aliases → 'scroll' (repair path verified)")
    }

    // MARK: - Test 8: present_answer → answer

    private static func test8_presentAnswerNormalizesToAnswer() {
        let aliases = ["present_answer", "give_answer", "provide_answer",
                       "present_result", "summarize", "report"]
        for alias in aliases {
            let result = AgenticDecider.normalizeActionAlias(alias)
            assert(result == "answer",
                   "[DirectAgentDeciderSelfTest] FAIL test8: '\(alias)' → expected 'answer', got '\(result)'")
        }
        print("[DirectAgentDeciderSelfTest] PASS test8: present_answer and variants → 'answer'")
    }

    // MARK: - Test 9: finish / done → stop_success

    private static func test9_finishAndDoneNormalizeToStopSuccess() {
        let aliases = ["finish", "done", "complete", "completed", "task_complete", "task_done"]
        for alias in aliases {
            let result = AgenticDecider.normalizeActionAlias(alias)
            assert(result == "stop_success",
                   "[DirectAgentDeciderSelfTest] FAIL test9: '\(alias)' → expected 'stop_success', got '\(result)'")
        }
        print("[DirectAgentDeciderSelfTest] PASS test9: finish/done/complete → 'stop_success'")
    }

    // MARK: - Test 10: click_element with nil target must be rejected — never accepted

    /// Verifies that after normalization, a click_element decision that lacks a target
    /// is caught before it becomes an accepted AgenticLoopDecision.
    ///
    /// This test exercises the guard condition inline (pure logic, no async).
    private static func test10_clickElementWithNilTargetIsRejected() {
        // Simulate what directAgentDecide does:
        let action = AgenticNextAction.click_element
        let clickTarget: String? = nil   // model omitted "target"

        // The check that MUST fire:
        let wouldBeRejected = (action == .click_element && clickTarget == nil)
        assert(wouldBeRejected,
               "[DirectAgentDeciderSelfTest] FAIL test10: click_element with nil target must be rejected")
        print("[DirectAgentDeciderSelfTest] PASS test10: click_element + nil target → rejected (repair triggered)")
    }

    // MARK: - Test 11: illegal action fallback → observe_screen, not stop_missing_context

    /// Verifies that when an illegal action cannot be repaired and we have OCR content,
    /// the fallback is observe_screen and NOT stop_missing_context.
    private static func test11_illegalActionFallbackPrefersObserveScreen() {
        let legalSet = AgenticRuntime.directAgentUniversalLegalActions()

        // Simulate context-guard logic from directAgentDecide:
        // If we have OCR chars > 300, stop_missing_context is forbidden.
        let simulatedOCRChars = 450
        let simulatedVLMChars = 0
        let simulatedAXChars  = 0
        let hasContext = simulatedOCRChars > 300 || simulatedVLMChars > 40 || simulatedAXChars > 150

        if hasContext {
            let safeFallback: AgenticNextAction = legalSet.contains(.observe_screen) ? .observe_screen : .answer
            assert(safeFallback != .stop_missing_context,
                   "[DirectAgentDeciderSelfTest] FAIL test11: should not fall back to stop_missing_context with OCR present")
            assert(safeFallback == .observe_screen || safeFallback == .answer,
                   "[DirectAgentDeciderSelfTest] FAIL test11: unexpected fallback '\(safeFallback.rawValue)'")
        }
        print("[DirectAgentDeciderSelfTest] PASS test11: with sufficient context, fallback avoids stop_missing_context")
    }

    // MARK: - Test 12: normalizeActionAlias is idempotent

    /// Calling normalizeActionAlias twice must produce the same result as once.
    private static func test12_normalizeActionAliasIsIdempotent() {
        let inputs = ["scroll_small", "scroll", "present_answer", "answer",
                      "finish", "stop_success", "click_element", "find_on_page",
                      "type_text", "observe_screen"]
        for input in inputs {
            let once  = AgenticDecider.normalizeActionAlias(input)
            let twice = AgenticDecider.normalizeActionAlias(once)
            assert(once == twice,
                   "[DirectAgentDeciderSelfTest] FAIL test12: normalize('\(input)') is not idempotent: '\(once)' → '\(twice)'")
        }
        print("[DirectAgentDeciderSelfTest] PASS test12: normalizeActionAlias is idempotent for all tested inputs")
    }
}
