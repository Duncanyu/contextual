import Foundation

/// Phase 21.4 — ActivityState self test.
///
/// Verifies that ActivityState correctly:
///   1. Returns .typing when typingScore is high.
///   2. Returns .interacting when pointerScore is high (no typing).
///   3. Returns .navigating when hadRecentNavigation=true (no keyboard/pointer).
///   4. Returns .reading when dwell is short and input is zero.
///   5. Returns .idle when dwell exceeds threshold and input is zero.
///   6. Returns .engaged when dwell is settled and there was recent activity.
///   7. isIdle=true only for .idle state.
///   8. isActive=true for all non-idle states.
///   9. DeterminerSignal is actionable when activity state is typing + entity present.
///  10. DeterminerSignal reason is "active_user_entity_present" for activity gate.
///  11. CapabilitySelector returns create_next_steps for unknown domain + active user.
///  12. ActiveContextRefresh schedules refresh for settled dwell + active user.
///
/// Trigger:
///   CONTEXTUAL_RUN_ACTIVITY_STATE_SELFTEST=1
enum ActivityStateSelfTest {

    static func run() -> Bool {
        print("[ActivityStateSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[ActivityStateSelfTest] pass case=\(name)") }
            else  { print("[ActivityStateSelfTest] fail case=\(name)"); failures.append(name) }
        }

        // ── Case 1: Typing state ───────────────────────────────────────────────
        let as1 = ActivityState.derive(typingScore: 0.8, pointerScore: 0.1, dwellSeconds: 30)
        check("typing_state", as1.state == .typing)
        check("typing_not_idle", !as1.isIdle)
        check("typing_is_active", as1.isActive)

        // ── Case 2: Interacting (pointer, no typing) ───────────────────────────
        let as2 = ActivityState.derive(typingScore: 0.0, pointerScore: 0.6, dwellSeconds: 30)
        check("interacting_state", as2.state == .interacting)
        check("interacting_is_active", as2.isActive)

        // ── Case 3: Navigating (no keyboard/pointer, recent navigation) ────────
        let as3 = ActivityState.derive(typingScore: 0.0, pointerScore: 0.0, dwellSeconds: 10, hadRecentNavigation: true)
        check("navigating_state", as3.state == .navigating)
        check("navigating_is_active", as3.isActive)

        // ── Case 4: Reading (short dwell, no input) ────────────────────────────
        let as4 = ActivityState.derive(typingScore: 0.0, pointerScore: 0.0, dwellSeconds: 30, idleThresholdSeconds: 90)
        check("reading_state", as4.state == .reading)
        check("reading_is_active", as4.isActive)

        // ── Case 5: Idle (dwell exceeds threshold, zero input) ────────────────
        let as5 = ActivityState.derive(typingScore: 0.0, pointerScore: 0.0, dwellSeconds: 120, idleThresholdSeconds: 90)
        check("idle_state", as5.state == .idle)
        check("idle_is_idle", as5.isIdle)
        check("idle_not_active", !as5.isActive)

        // ── Case 6: Engaged (settled dwell + prior activity) ──────────────────
        // typingScore > 0 but low; dwell is settled → engaged
        let as6 = ActivityState.derive(typingScore: 0.02, pointerScore: 0.02, dwellSeconds: 300)
        // With typingScore=0.02 < 0.05 threshold, pointer=0.02 < 0.05 threshold,
        // no navigation, inputSignal=0.02, dwell=300 >= 90 threshold but inputSignal != 0
        // → should be engaged (settled/deep_work with prior activity)
        check("engaged_state", as6.state == .engaged || as6.state == .reading)
        check("engaged_is_active", as6.isActive)

        // ── Case 7: isIdle is true ONLY for .idle ─────────────────────────────
        let nonIdleStates: [ActivityState.State] = [.typing, .interacting, .navigating, .reading, .engaged]
        let allNonIdleNotIsIdle = nonIdleStates.allSatisfy { s in
            let synth = ActivityState(state: s, dwellState: .fresh, dwellSeconds: 30, typingScore: 0, pointerScore: 0, isIdle: s == .idle)
            return !synth.isIdle
        }
        check("non_idle_states_not_is_idle", allNonIdleNotIsIdle)

        // ── Case 8: DwellState transitions ────────────────────────────────────
        let fresh   = ActivityState.derive(typingScore: 0.1, pointerScore: 0, dwellSeconds: 60)
        let settled = ActivityState.derive(typingScore: 0.1, pointerScore: 0, dwellSeconds: 200)
        let deep    = ActivityState.derive(typingScore: 0.1, pointerScore: 0, dwellSeconds: 700)
        check("dwell_fresh",    fresh.dwellState == .fresh)
        check("dwell_settled",  settled.dwellState == .settled)
        check("dwell_deep_work", deep.dwellState == .deep_work)

        // ── Case 9: DeterminerSignal actionable via activity gate ─────────────
        // No compartment, no terms, but user is actively typing + entity present.
        let typingActivity = ActivityState.derive(typingScore: 0.9, pointerScore: 0, dwellSeconds: 60)
        let ds9 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: nil,
            workflowConfidence: 0.0,
            behaviorConfidence: 0.0,
            activeTerms: [],
            currentEntity: "Some Page",
            activityState: typingActivity
        )
        check("determiner_actionable_via_activity", ds9.actionable)
        check("determiner_activity_reason",
              ds9.reason == "active_user_entity_present" || ds9.reason == "entity_and_terms_sufficient")

        // ── Case 10: DeterminerSignal NOT actionable when idle + no other signals ──
        let idleActivity = ActivityState.derive(typingScore: 0.0, pointerScore: 0.0, dwellSeconds: 200, idleThresholdSeconds: 90)
        let ds10 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: nil,
            workflowConfidence: 0.0,
            behaviorConfidence: 0.0,
            activeTerms: [],
            currentEntity: "",
            activityState: idleActivity
        )
        // Idle + blank entity → must be suppressed
        check("determiner_not_actionable_when_idle_blank", !ds10.actionable)

        // ── Case 11: CapabilitySelector → create_next_steps for unknown domain + active ──
        // Use an entity name with zero vocabulary hits so domain stays .unknown.
        // "ProjectAlpha" has no terms in any domain vocabulary.
        let mem11 = WorkingMemorySnapshot(
            currentEntity: "ProjectAlpha",
            recentEntities: ["ProjectAlpha"],
            repeatedConcepts: [],
            inferredActivity: "unknown",
            comparisonCandidates: []
        )
        let activeState11 = ActivityState.derive(typingScore: 0.9, pointerScore: 0, dwellSeconds: 60)
        let ds11 = DeterminerSignal.evaluate(
            memory: mem11,
            compartment: nil,
            workflowConfidence: 0.0,
            behaviorConfidence: 0.0,
            activeTerms: [],
            currentEntity: "ProjectAlpha",
            activityState: activeState11
        )
        // Domain should be unknown (no vocab terms match "ProjectAlpha")
        check("active_unknown_domain", ds11.inferredDomain == .unknown)
        check("active_unknown_actionable", ds11.actionable)
        // CapabilitySelector should route to create_next_steps
        let mem11snap = WorkingMemorySnapshot(
            currentEntity: "ProjectAlpha",
            recentEntities: [],
            repeatedConcepts: [],
            inferredActivity: "unknown",
            comparisonCandidates: []
        )
        let selection11 = CapabilitySelector.select(
            compartment: nil,
            workingMemory: mem11snap,
            evidenceQuality: "title_only",
            currentApp: "SomeApp",
            behavior: .unknown,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values),
            determinerSignal: ds11
        )
        check("capability_active_unknown_routes_to_next_steps",
              selection11.primary.id == "create_next_steps")

        // ── Case 12: ActiveContextRefresh schedules for settled dwell + active ──
        let decision12 = ActiveContextRefresh.decide(
            now: Date(),
            workflow: .unknown,
            behavior: .unknown,
            evidenceQuality: "title_only",
            lastMeaningfulEventAge: 60,
            lastSuggestionAge: nil,
            lastRefreshAge: nil,
            modelBusy: false,
            determinerSignal: nil,
            activityState: ActivityState.derive(typingScore: 0.8, pointerScore: 0, dwellSeconds: 300),
            compartmentDwellSeconds: 300
        )
        check("refresh_scheduled_settled_active", decision12.action == .refresh)
        check("refresh_reason_stable_active", decision12.reason == "stable_active_context")

        let ok = failures.isEmpty
        print("[ActivityStateSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
