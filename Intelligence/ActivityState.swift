import Foundation

/// Phase 21.4 — Separate user activity state from domain/workflow classification.
///
/// Key invariant: idle means NO user interaction (keyboard / pointer / clicks /
/// tab changes / window changes). Low domain-classification confidence NEVER
/// implies idle — that should remain `unknown_domain`, not `idle` activity.
///
/// Sources (in priority order):
///   1. Typing score from the temporal short window (activityIntensity on keyboard events)
///   2. Pointer score from the temporal short window
///   3. Compartment dwell: how long the user has stayed in the same focused context
///   4. Recent context events: tab/title changes imply navigation (not idle)
///
/// This struct is pure / value type / Sendable — no side effects.
public struct ActivityState: Sendable, Equatable {

    // MARK: - State enum

    public enum State: String, Sendable, Equatable, CaseIterable {
        case typing       // keyboard activity detected
        case interacting  // pointer movement / clicks detected
        case navigating   // recent tab/window change; no keyboard/pointer yet
        case reading      // stable dwell, no strong input signal
        case engaged      // stable dwell > 2 min with prior activity
        case idle         // no keyboard, pointer, navigation for threshold seconds
    }

    // MARK: - Dwell state

    public enum DwellState: String, Sendable, Equatable {
        case fresh      // < 2 min in compartment
        case settled    // 2–10 min in compartment
        case deep_work  // > 10 min in compartment
    }

    // MARK: - Fields

    public let state: State
    public let dwellState: DwellState
    public let dwellSeconds: TimeInterval
    public let typingScore: Double   // 0–1 from temporal window
    public let pointerScore: Double  // 0–1 from temporal window
    public let isIdle: Bool          // convenience

    // MARK: - Derive from signals

    /// Derives activity state from the temporal window scores and compartment dwell.
    /// - Parameters:
    ///   - typingScore: From `TemporalContextWindow.typingScore`
    ///   - pointerScore: From `TemporalContextWindow.pointerScore`
    ///   - dwellSeconds: How long the active compartment has been focused
    ///   - hadRecentNavigation: True if a tab/title change was observed in the last ~30s
    ///   - idleThresholdSeconds: Consider user idle after this many seconds of no input
    public static func derive(
        typingScore: Double,
        pointerScore: Double,
        dwellSeconds: TimeInterval,
        hadRecentNavigation: Bool = false,
        idleThresholdSeconds: TimeInterval = 90
    ) -> ActivityState {

        let dwellState: DwellState = {
            if dwellSeconds < 120 { return .fresh }
            if dwellSeconds < 600 { return .settled }
            return .deep_work
        }()

        let inputSignal = max(typingScore, pointerScore)

        let state: State = {
            if typingScore > 0.05 { return .typing }
            if pointerScore > 0.05 { return .interacting }
            if hadRecentNavigation { return .navigating }
            // No recent input at all
            if inputSignal == 0 && dwellSeconds < idleThresholdSeconds { return .reading }
            if inputSignal == 0 && dwellSeconds >= idleThresholdSeconds { return .idle }
            // Had some engagement in the window even if tapering off
            if dwellState == .settled || dwellState == .deep_work { return .engaged }
            return .reading
        }()

        let isIdle = state == .idle

        let activityStr = state.rawValue
        let dwellStr = String(format: "%.0f", dwellSeconds)
        let inputStr = String(format: "%.2f", inputSignal)
        print("[ActivityState] state=\(activityStr) dwell_s=\(dwellStr) input_signal=\(inputStr) reason=\(state == .idle ? "no_user_input" : "user_activity_detected")")
        print("[CompartmentDwell] duration_s=\(dwellStr) state=\(dwellState.rawValue)")

        return ActivityState(
            state: state,
            dwellState: dwellState,
            dwellSeconds: dwellSeconds,
            typingScore: typingScore,
            pointerScore: pointerScore,
            isIdle: isIdle
        )
    }

    // MARK: - Convenience

    /// True when the user is actively engaged with the machine.
    public var isActive: Bool { !isIdle }

    /// True when the dwell state suggests deep, focused work.
    public var isDeepWork: Bool { dwellState == .deep_work }
}
