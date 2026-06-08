import Foundation

// MARK: - Phase 36.3 — State-aware Suggestion Cooldown
//
// The legacy cooldown was keyed `capability|entity` — coarse, time-based, global.
// If the same useful action was shown 30s ago, the next tick was silenced even when
// the underlying runtime state (e.g. windows still not arranged) still warranted it.
// That produced empty UI: music suppressed by task-preferred, task suppressed by cooldown.
//
// The new arbiter:
//   • Keys cooldown on (capability, target fingerprint, layout/target state, source path,
//     compartment label) so the cooldown only fires for the SAME exact thing.
//   • Bypasses when state changed since the last show (user un-arranged, target appeared)
//     or when runtime friction visibly persists (user didn't act and a longer window has passed).
//   • Demotes to panel_only inside an anti-flicker window so the assistant is never empty.
//
// The arbiter does not store global state on its own — callers pass last-shown info in.

enum CooldownArbiterStatus: String, Sendable {
    case inactive            // no cooldown applies
    case bypass              // a cooldown key was found but the state changed; allow floating
    case panelOnly = "panel_only"  // recently shown for same state; demote to panel
    case active              // very recent (anti-flicker window); suppress entirely
}

struct CooldownArbiterDecision: Sendable {
    let capabilityID: String
    let cooldownKey: String
    let status: CooldownArbiterStatus
    let bypass: Bool
    let reason: String

    func log() {
        let active = (status == .active || status == .panelOnly) ? "yes" : "no"
        print("[SuggestionCooldown] capability=\(capabilityID) cooldown_key=\(cooldownKey) active=\(active) bypass=\(bypass ? "yes" : "no") reason=\(reason)")
        switch status {
        case .bypass:
            print("[SuggestionCooldown] bypassed capability=\(capabilityID) reason=\(reason)")
        case .active, .panelOnly:
            print("[SuggestionCooldown] applied capability=\(capabilityID) reason=\(reason)")
        case .inactive:
            break
        }
    }
}

enum SuggestionCooldownArbiter {

    /// Hard anti-flicker window. Inside this, even a useful repeat is suppressed
    /// outright so the assistant doesn't re-emit the same card 4 times in a row.
    static let antiFlickerSeconds: TimeInterval = 5

    /// Soft demote-to-panel window. Inside this, the same action+state shown recently
    /// is allowed but demoted to panel so it isn't a noisy floating popup.
    static let panelOnlyWindowSeconds: TimeInterval = 60

    /// Hard bypass after this much elapsed time — runtime friction persists, the user
    /// clearly didn't act, so the assistant may surface the action again as floating.
    static let persistentFrictionBypassSeconds: TimeInterval = 90

    struct Input: Sendable {
        let capabilityID: String
        let targetFingerprint: String     // e.g. "Firefox+Preview"
        let targetState: String           // e.g. "present_not_arranged" / "already_arranged"
        let sourcePath: String            // e.g. "runtime_workspace_friction"
        let compartmentLabel: String?
        let lastShownAt: Date?
        let lastShownKey: String?
        let recentDismissCount: Int       // user-dismiss feedback for this capability
        let now: Date
    }

    static func evaluate(_ input: Input) -> CooldownArbiterDecision {
        let key = makeKey(
            capabilityID: input.capabilityID,
            targetFingerprint: input.targetFingerprint,
            targetState: input.targetState,
            sourcePath: input.sourcePath,
            compartmentLabel: input.compartmentLabel
        )

        guard let lastShownAt = input.lastShownAt, let lastKey = input.lastShownKey else {
            let d = CooldownArbiterDecision(
                capabilityID: input.capabilityID,
                cooldownKey: key,
                status: .inactive,
                bypass: false,
                reason: "no_prior_show"
            )
            d.log()
            return d
        }

        let elapsed = input.now.timeIntervalSince(lastShownAt)

        // Different cooldown key → underlying targets/state changed → bypass.
        if lastKey != key {
            let d = CooldownArbiterDecision(
                capabilityID: input.capabilityID,
                cooldownKey: key,
                status: .bypass,
                bypass: true,
                reason: "high_usefulness_runtime_state_changed"
            )
            d.log()
            return d
        }

        // Same key — recent dismissal feedback respects the cooldown more aggressively.
        if input.recentDismissCount >= 2 && elapsed < panelOnlyWindowSeconds {
            let d = CooldownArbiterDecision(
                capabilityID: input.capabilityID,
                cooldownKey: key,
                status: .panelOnly,
                bypass: false,
                reason: "same_action_same_targets_recently_dismissed"
            )
            d.log()
            return d
        }

        if elapsed < antiFlickerSeconds {
            let d = CooldownArbiterDecision(
                capabilityID: input.capabilityID,
                cooldownKey: key,
                status: .active,
                bypass: false,
                reason: "anti_flicker_window"
            )
            d.log()
            return d
        }

        if elapsed < panelOnlyWindowSeconds {
            let d = CooldownArbiterDecision(
                capabilityID: input.capabilityID,
                cooldownKey: key,
                status: .panelOnly,
                bypass: false,
                reason: "same_action_same_targets_recently_shown"
            )
            d.log()
            return d
        }

        // Persistent runtime friction — user didn't act, enough time has passed: re-float.
        if elapsed >= persistentFrictionBypassSeconds {
            let d = CooldownArbiterDecision(
                capabilityID: input.capabilityID,
                cooldownKey: key,
                status: .bypass,
                bypass: true,
                reason: "runtime_friction_persists"
            )
            d.log()
            return d
        }

        let d = CooldownArbiterDecision(
            capabilityID: input.capabilityID,
            cooldownKey: key,
            status: .inactive,
            bypass: false,
            reason: "outside_cooldown_window"
        )
        d.log()
        return d
    }

    /// Build a deterministic cooldown key. Target fingerprint is normalized so that
    /// "Firefox+Preview" and "Preview+Firefox" hash to the same key.
    static func makeKey(
        capabilityID: String,
        targetFingerprint: String,
        targetState: String,
        sourcePath: String,
        compartmentLabel: String?
    ) -> String {
        let normalizedTargets = targetFingerprint
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .sorted()
            .joined(separator: "+")
        let comp = (compartmentLabel ?? "none").lowercased()
        return "\(capabilityID)|\(normalizedTargets)|\(targetState)|\(sourcePath)|\(comp)"
    }
}

// MARK: - Self-test

enum SuggestionCooldownArbiterSelfTest {

    static func run() -> Bool {
        print("[SuggestionCooldownArbiterSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[SuggestionCooldownArbiterSelfTest] pass case=\(name)") }
            else { print("[SuggestionCooldownArbiterSelfTest] fail case=\(name)"); failures.append(name) }
        }

        let now = Date()
        let baseKey = SuggestionCooldownArbiter.makeKey(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease"
        )

        // No prior show → inactive
        let none = SuggestionCooldownArbiter.evaluate(.init(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease",
            lastShownAt: nil,
            lastShownKey: nil,
            recentDismissCount: 0,
            now: now
        ))
        check("no_prior_inactive", none.status == .inactive)

        // 3s ago same key → active (anti-flicker)
        let recent = SuggestionCooldownArbiter.evaluate(.init(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease",
            lastShownAt: now.addingTimeInterval(-3),
            lastShownKey: baseKey,
            recentDismissCount: 0,
            now: now
        ))
        check("anti_flicker_active", recent.status == .active)

        // 30s ago same key → panel_only
        let panelOnly = SuggestionCooldownArbiter.evaluate(.init(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease",
            lastShownAt: now.addingTimeInterval(-30),
            lastShownKey: baseKey,
            recentDismissCount: 0,
            now: now
        ))
        check("recent_panel_only", panelOnly.status == .panelOnly)
        check("recent_panel_only_reason", panelOnly.reason == "same_action_same_targets_recently_shown")

        // 100s ago same key, persistent friction → bypass
        let persistent = SuggestionCooldownArbiter.evaluate(.init(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease",
            lastShownAt: now.addingTimeInterval(-100),
            lastShownKey: baseKey,
            recentDismissCount: 0,
            now: now
        ))
        check("persistent_bypass", persistent.status == .bypass)
        check("persistent_bypass_reason", persistent.reason == "runtime_friction_persists")

        // State changed (already_arranged → not_arranged): different key → bypass
        let oldKey = SuggestionCooldownArbiter.makeKey(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "already_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease"
        )
        let stateChange = SuggestionCooldownArbiter.evaluate(.init(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease",
            lastShownAt: now.addingTimeInterval(-20),
            lastShownKey: oldKey,
            recentDismissCount: 0,
            now: now
        ))
        check("state_change_bypass", stateChange.status == .bypass)
        check("state_change_reason", stateChange.reason == "high_usefulness_runtime_state_changed")

        // Two dismissals in panel window → respect cooldown
        let dismissed = SuggestionCooldownArbiter.evaluate(.init(
            capabilityID: "arrange_side_by_side",
            targetFingerprint: "Firefox+Preview",
            targetState: "present_not_arranged",
            sourcePath: "runtime_workspace_friction",
            compartmentLabel: "lease",
            lastShownAt: now.addingTimeInterval(-30),
            lastShownKey: baseKey,
            recentDismissCount: 3,
            now: now
        ))
        check("dismissals_panel_only", dismissed.status == .panelOnly)
        check("dismissals_reason", dismissed.reason == "same_action_same_targets_recently_dismissed")

        // Target fingerprint normalization (order independence)
        let kA = SuggestionCooldownArbiter.makeKey(capabilityID: "x", targetFingerprint: "A+B", targetState: "s", sourcePath: "p", compartmentLabel: "c")
        let kB = SuggestionCooldownArbiter.makeKey(capabilityID: "x", targetFingerprint: "B+A", targetState: "s", sourcePath: "p", compartmentLabel: "c")
        check("key_target_order_independent", kA == kB)

        let ok = failures.isEmpty
        print("[SuggestionCooldownArbiterSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
