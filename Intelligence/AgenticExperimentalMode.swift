import Foundation

/// Agentic Experimental v1 — product boundary.
///
/// Agentic computer control is no longer treated as a core product feature.
/// It runs as a bounded experimental subsystem with a small set of reliable
/// non-click actions (observe, scroll, type, press key, answer) enabled by
/// default. Visual click grounding is OFF by default and requires an explicit
/// opt-in plus a passing `VisualGroundingSelfTest`.
///
/// Logs emitted:
///   [AgenticMode] mode=experimental_control
///   [AgenticMode] reason=visual_grounding_unreliable
///   [AgenticMode] click_enabled=no  reason=experimental_disabled
///   [AgenticMode] click_enabled=no  reason=grounder_smoke_failed
///   [AgenticMode] click_enabled=yes reason=explicit_opt_in_smoke_passed
///   [AgenticMode] unsupported_goal  reason=click_required_but_disabled
enum AgenticExperimentalMode {

    // MARK: - Mode identity

    /// Stable mode label surfaced in logs and user-facing copy.
    static let modeName = "experimental_control"

    // MARK: - Smoke test result tracking

    /// Set by `VisualGroundingSelfTest.run()`. nil = not yet attempted.
    /// Reads/writes are not synchronized: the smoke test runs once at startup
    /// before any agentic loop is allowed to begin, so contention is not expected.
    nonisolated(unsafe) private static var _smokeTestPassed: Bool? = nil

    /// Mark the visual grounding smoke test as having passed or failed.
    /// Called from `VisualGroundingSelfTest` after a real run.
    static func recordSmokeTestResult(passed: Bool) {
        _smokeTestPassed = passed
    }

    /// True only if the smoke test ran and produced a usable grounded region
    /// within the wall-clock budget. nil (never run) counts as failed.
    static var smokeTestPassed: Bool {
        _smokeTestPassed == true
    }

    // MARK: - Opt-in gate

    /// True when the user has explicitly opted into experimental click grounding
    /// via the environment variable `CONTEXTUAL_ENABLE_EXPERIMENTAL_CLICK=1`.
    static var clickExplicitlyOptedIn: Bool {
        let raw = ProcessInfo.processInfo.environment["CONTEXTUAL_ENABLE_EXPERIMENTAL_CLICK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return raw == "1" || raw == "yes" || raw == "true"
    }

    /// Final gate for click_element. Both the env opt-in AND the smoke test
    /// must succeed; otherwise click_element is removed from the action menu.
    static var clickEnabled: Bool {
        clickExplicitlyOptedIn && smokeTestPassed
    }

    /// Human-readable reason for why click is currently disabled, if it is.
    static var clickDisabledReason: String? {
        if !clickExplicitlyOptedIn { return "experimental_disabled" }
        if !smokeTestPassed { return "grounder_smoke_failed" }
        return nil
    }

    // MARK: - Structured logging

    /// Emit the canonical `[AgenticMode]` banner. Called once at the start of
    /// every agentic run so dogfood logs always identify the active mode + gate.
    static func logBanner() {
        print("[AgenticMode] mode=\(modeName)")
        print("[AgenticMode] reason=visual_grounding_unreliable")
        if let disabledReason = clickDisabledReason {
            print("[AgenticMode] click_enabled=no reason=\(disabledReason)")
        } else {
            print("[AgenticMode] click_enabled=yes reason=explicit_opt_in_smoke_passed")
        }
    }

    /// Heuristic: does the goal text imply a click/navigation action that
    /// experimental v1 cannot reliably perform without grounding?
    /// Used only to format the honest failure answer — never to plan actions.
    static func goalRequiresClickInteraction(_ goal: String) -> Bool {
        let g = goal.lowercased()
        let clickWords: [String] = [
            "click", "press the", "tap ", "open the ", "navigate to ",
            "go to ", "select the ", "choose the ", "submit", "checkout",
            "log in", "sign in", "add to cart", "buy", "purchase"
        ]
        return clickWords.contains(where: { g.contains($0) })
    }

    /// Standard honest-failure copy for goals that require click but click is
    /// disabled. Surfaced as the final answer in lieu of a fake success.
    static let unsupportedClickAnswer: String =
        "I can read and summarize this screen, scroll, type, and use keyboard shortcuts, but visual clicking is currently disabled because grounding is experimental. " +
        "To opt in, set CONTEXTUAL_ENABLE_EXPERIMENTAL_CLICK=1 and ensure the visual grounding smoke test passes."

    /// Log the unsupported-goal event so dogfood logs make the boundary visible.
    static func logUnsupportedClickGoal() {
        let reason = clickDisabledReason ?? "click_disabled"
        print("[AgenticMode] unsupported_goal reason=click_required_but_disabled gate=\(reason)")
    }
}
