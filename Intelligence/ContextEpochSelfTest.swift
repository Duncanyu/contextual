import Foundation

/// Phase 20G — ContextEpochTracker behavior:
///   1. starts new epoch on context shift, archives previous
///   2. previous-epoch titles are flagged stale, current-epoch titles are not
///   3. no shift → titles continue to accumulate in same epoch (id stable)
///
/// Trigger:
///   CONTEXTUAL_RUN_CONTEXT_EPOCH_SELFTEST=1
@MainActor
enum ContextEpochSelfTest {

    static func run() async -> Bool {
        print("[ContextEpochSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[ContextEpochSelfTest] pass case=\(name)") }
            else  { print("[ContextEpochSelfTest] fail case=\(name)"); failures.append(name) }
        }

        ContextEpochTracker.shared.resetForTests()

        // 1. Seed an "Anker shopping" epoch.
        ContextEpochTracker.shared.observe(
            contextShiftDetected: false,
            shiftReason: "seed",
            earlyTopTerms: [],
            recentTopTerms: ["anker", "solix", "200w", "powerbank"],
            recentTitles: ["Anker Prime 200W", "Anker Solix Battery"]
        )
        let firstEpoch = ContextEpochTracker.shared.currentEpoch()
        check("first_observation_records_terms", firstEpoch.terms.contains("anker"))
        check("first_observation_no_previous", ContextEpochTracker.shared.previousEpoch() == nil)

        // 2. A non-shift second observation keeps the same epoch id.
        ContextEpochTracker.shared.observe(
            contextShiftDetected: false,
            shiftReason: "no_shift",
            earlyTopTerms: ["anker"],
            recentTopTerms: ["anker", "solix"],
            recentTitles: ["Anker Prime 200W"]
        )
        let sameEpoch = ContextEpochTracker.shared.currentEpoch()
        check("no_shift_preserves_epoch_id", sameEpoch.id == firstEpoch.id)

        // 3. A real context shift → new epoch, previous archived.
        ContextEpochTracker.shared.observe(
            contextShiftDetected: true,
            shiftReason: "recent_title_cluster_shift",
            earlyTopTerms: ["anker", "solix"],
            recentTopTerms: ["cisc", "computing", "problem", "solving"],
            recentTitles: ["CISC 101 — Week 1", "Intro to Problem Solving"]
        )
        let newEpoch = ContextEpochTracker.shared.currentEpoch()
        let prev = ContextEpochTracker.shared.previousEpoch()
        check("shift_starts_new_epoch", newEpoch.id != firstEpoch.id)
        check("shift_archives_previous", prev?.id == firstEpoch.id)
        check("new_epoch_has_new_terms", newEpoch.terms.contains("cisc"))

        // 4. Previous-epoch title is now stale; current-epoch title is not.
        check("previous_epoch_title_is_stale",
              ContextEpochTracker.shared.isStale(title: "Anker Prime 200W") == true)
        check("current_epoch_title_not_stale",
              ContextEpochTracker.shared.isStale(title: "CISC 101 — Week 1") == false)

        // 5. Titles whose tokens overlap current terms are not stale.
        check("overlapping_token_not_stale",
              ContextEpochTracker.shared.isStale(title: "Computing Fundamentals") == false)

        // 6. Reset clears state.
        ContextEpochTracker.shared.resetForTests()
        let reset = ContextEpochTracker.shared.currentEpoch()
        check("reset_clears_terms", reset.terms.isEmpty)
        check("reset_clears_previous", ContextEpochTracker.shared.previousEpoch() == nil)

        let ok = failures.isEmpty
        print("[ContextEpochSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
