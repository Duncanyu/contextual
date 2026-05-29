import CoreGraphics
import Foundation

// MARK: - DirectAgentClickSelfTest

/// Self-tests for DirectAgentGrounder click grounding logic.
///
/// All tests are pure — no AX tree access, no CGEvent posting, no UI side-effects.
/// Run via `DirectAgentClickSelfTest.runAll()` at startup in DEBUG builds.
///
/// Test coverage:
///   1. AX link with matching label → matched (exact substring)
///   2. Missing target string → skip (no crash, graceful nil)
///   3. Unsafe target → blocked by isSafeTarget
///   4. Matched click target → has valid screen coordinates
///   5. Word-overlap grounding → F1 threshold fires on partial match
enum DirectAgentClickSelfTest {

    static func runAll() {
        print("[DirectAgentClickSelfTest] running 5 tests")
        test1_matchingLabelGrounded()
        test2_missingTargetSkips()
        test3_unsafeTargetBlocked()
        test4_matchedClickHasCoordinates()
        test5_wordOverlapGrounding()
        print("[DirectAgentClickSelfTest] all 5 tests passed")
    }

    // MARK: - Test 1: Matching label → grounded result

    /// An AX link element whose label contains the target string should ground successfully.
    private static func test1_matchingLabelGrounded() {
        let elements = [
            makeElement(label: "Sign Up Free", role: "AXButton"),
            makeElement(label: "Learn More",   role: "AXLink"),
            makeElement(label: "Pricing",      role: "AXLink"),
        ]
        let result = DirectAgentGrounder.ground(target: "Learn More", elements: elements)
        assert(result != nil,
               "[DirectAgentClickSelfTest] FAIL test1: expected non-nil grounded result")
        assert(result?.element.label == "Learn More",
               "[DirectAgentClickSelfTest] FAIL test1: expected label 'Learn More', got '\(result?.element.label ?? "nil")'")
        assert(result?.confidence ?? 0 >= 0.90,
               "[DirectAgentClickSelfTest] FAIL test1: expected high confidence, got \(result?.confidence ?? 0)")
        print("[DirectAgentClickSelfTest] PASS test1: exact label match grounded")
    }

    // MARK: - Test 2: Missing target → nil (no crash)

    /// `ground(target:elements:)` with an empty target must return nil without crashing.
    private static func test2_missingTargetSkips() {
        let elements = [makeElement(label: "Submit", role: "AXButton")]
        let result = DirectAgentGrounder.ground(target: "", elements: elements)
        assert(result == nil,
               "[DirectAgentClickSelfTest] FAIL test2: expected nil for empty target")
        print("[DirectAgentClickSelfTest] PASS test2: empty target returns nil")
    }

    // MARK: - Test 3: Unsafe target → blocked

    /// `isSafeTarget` must return false for every known unsafe phrase.
    private static func test3_unsafeTargetBlocked() {
        let unsafeTargets = [
            "buy now",
            "add to cart",
            "checkout",
            "delete account",
            "sign in",
            "pay now",
            "install extension",
            "send message",
        ]
        for unsafe in unsafeTargets {
            assert(!DirectAgentGrounder.isSafeTarget(unsafe),
                   "[DirectAgentClickSelfTest] FAIL test3: '\(unsafe)' should be blocked")
        }
        // A safe target must not be blocked
        assert(DirectAgentGrounder.isSafeTarget("Learn More"),
               "[DirectAgentClickSelfTest] FAIL test3: 'Learn More' should be safe")
        assert(DirectAgentGrounder.isSafeTarget("Next"),
               "[DirectAgentClickSelfTest] FAIL test3: 'Next' should be safe")
        print("[DirectAgentClickSelfTest] PASS test3: unsafe targets blocked, safe targets pass")
    }

    // MARK: - Test 4: Matched click target has valid screen coordinates

    /// When a target is grounded, the element center must be non-zero (non-degenerate frame).
    private static func test4_matchedClickHasCoordinates() {
        let frame  = CGRect(x: 100, y: 200, width: 80, height: 30)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let el     = AXClickableElement(
            label:    "Get Started",
            role:     "AXButton",
            frame:    frame,
            center:   center,
            isLink:   false,
            isButton: true,
            isField:  false
        )
        let result = DirectAgentGrounder.ground(target: "Get Started", elements: [el])
        assert(result != nil,
               "[DirectAgentClickSelfTest] FAIL test4: expected non-nil match")
        let c = result!.element.center
        assert(c.x > 0 && c.y > 0,
               "[DirectAgentClickSelfTest] FAIL test4: center must be non-zero, got \(c)")
        assert(c.x == frame.midX && c.y == frame.midY,
               "[DirectAgentClickSelfTest] FAIL test4: center mismatch expected=\(frame.midX),\(frame.midY) got=\(c)")
        print("[DirectAgentClickSelfTest] PASS test4: matched click has valid screen coordinates x=\(Int(c.x)) y=\(Int(c.y))")
    }

    // MARK: - Test 5: Word-overlap grounding fires at F1 ≥ 0.30

    /// A partial word match should still produce a grounded result when F1 ≥ 0.30.
    private static func test5_wordOverlapGrounding() {
        let elements = [
            makeElement(label: "View Product Details",  role: "AXLink"),
            makeElement(label: "Customer Reviews",      role: "AXButton"),
            makeElement(label: "Technical Specs Sheet", role: "AXLink"),
        ]
        // "product details" overlaps with "View Product Details" → F1 should be ≥ 0.30
        let result = DirectAgentGrounder.ground(target: "product details", elements: elements)
        assert(result != nil,
               "[DirectAgentClickSelfTest] FAIL test5: word overlap should produce a match")
        assert(result?.element.label == "View Product Details",
               "[DirectAgentClickSelfTest] FAIL test5: expected 'View Product Details', got '\(result?.element.label ?? "nil")'")
        print("[DirectAgentClickSelfTest] PASS test5: word-overlap grounding score=\(String(format: "%.2f", result?.confidence ?? 0))")
    }

    // MARK: - Helpers

    private static func makeElement(label: String, role: String) -> AXClickableElement {
        let frame = CGRect(x: 10, y: 10, width: 120, height: 28)
        return AXClickableElement(
            label:    label,
            role:     role,
            frame:    frame,
            center:   CGPoint(x: frame.midX, y: frame.midY),
            isLink:   role == "AXLink",
            isButton: role == "AXButton",
            isField:  false
        )
    }
}
