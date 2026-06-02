import Foundation

/// Phase 22 — Compartment transition self-test.
///
/// Verifies that the compartment tracker correctly handles domain switches and that
/// DeterminerSignal does not bleed stale compartment vocabulary into domain scoring.
///
/// Test cases:
///   1. Coding (Scratch/TurboWarp) → Watching (Dexter) with stale packet → NEW compartment
///   2. Coding → Coding → same compartment reused (threshold still passes)
///   3. DeterminerSignal domain ≠ creative_coding for Dexter content (even with stale comp)
///   4. BestEffortDomain blocked when current focus contradicts compartment workflow
///   5. Compartment count grows on cross-domain switch
///   6. Workflow-family incompatibility prevents cross-family compartment reuse
///
/// Trigger:
///   CONTEXTUAL_RUN_COMPARTMENT_TRANSITION_SELFTEST=1
enum CompartmentTransitionSelfTest {

    static func run() async -> Bool {
        print("[CompartmentTransitionSelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[CompartmentTransitionSelfTest] pass case=\(name)")
            } else {
                print("[CompartmentTransitionSelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        await MainActor.run {
            runSyncTests(check: check)
        }

        let ok = failures.isEmpty
        print("[CompartmentTransitionSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }

    // All compartment tracker calls require @MainActor.
    @MainActor
    private static func runSyncTests(check: (String, Bool) -> Void) {

        // ── Case 1 & 5: Scratch/coding → Dexter/watching with stale packet ───────
        //
        // Simulates the real-world bug: user was coding a game in TurboWarp, then
        // opens a video player for Dexter. The temporal packet still contains coding
        // vocabulary (stale, ~30s old).
        //
        // Before fix: Scratch compartment scores 21+ via stale packet terms →
        //             Dexter incorrectly reuses the Scratch compartment.
        // After fix:  Packet-only terms weighted 0.1x + mismatch penalty → score < 1.5
        //             AND workflow-family incompatibility (.coding ≠ .watching) blocks
        //             → new compartment created for Dexter. ✓
        print("[CompartmentTransitionSelfTest] case=scratch_to_dexter_stale_packet")
        TaskCompartmentTracker.shared.reset()

        // Step A: Establish Scratch/coding compartment.
        let scratchComp = TaskCompartmentTracker.shared.ingestUpdate(
            workflow: .coding,
            behavior: .coding,
            title: "Realistic Tank Shooter Demo - TurboWarp",
            tabs: [],
            topicTerms: ["scratch", "sprite", "tank", "shooter", "collision", "turbowarp", "demo"]
        )
        let scratchId = scratchComp.id
        print("[CompartmentTransitionSelfTest] established scratch id=\(scratchId)")

        // Step B: Switch to Dexter. Title/tabs = pure Dexter content.
        // topicTerms simulates the stale temporal packet: Scratch terms haven't flushed,
        // mixed with real Dexter terms ("season", "episode").
        let dexterComp = TaskCompartmentTracker.shared.ingestUpdate(
            workflow: .watching,
            behavior: .watching,
            title: "Dexter Season 1 Episode 3",
            tabs: [],
            topicTerms: ["scratch", "sprite", "shooter", "season", "episode"]
        )
        let dexterId = dexterComp.id
        print("[CompartmentTransitionSelfTest] dexter result id=\(dexterId)")

        check("dexter_gets_new_compartment", dexterId != scratchId)
        check("compartment_count_grew_after_switch",
              TaskCompartmentTracker.shared.compartments.count >= 2)
        check("active_compartment_is_dexter",
              TaskCompartmentTracker.shared.activeCompartmentId == dexterId)

        // ── Case 2: Coding → Coding → same compartment reused ───────────────────
        //
        // Ensures that tightening the threshold didn't break normal compartment reuse.
        // When title tokens give strong overlap (3.0x per token × 3+ tokens = 9.0),
        // the threshold of 1.5 is easily cleared and the compartment is reused.
        print("[CompartmentTransitionSelfTest] case=scratch_to_scratch_reuse")
        TaskCompartmentTracker.shared.reset()

        let scratch1 = TaskCompartmentTracker.shared.ingestUpdate(
            workflow: .coding,
            behavior: .coding,
            title: "Realistic Tank Shooter Demo - TurboWarp",
            tabs: [],
            topicTerms: ["scratch", "sprite", "tank", "shooter"]
        )
        let scratch1Id = scratch1.id

        let scratch2 = TaskCompartmentTracker.shared.ingestUpdate(
            workflow: .coding,
            behavior: .coding,
            title: "Realistic Tank Shooter Demo - TurboWarp",
            tabs: [],
            topicTerms: ["scratch", "sprite", "tank", "collision"]
        )
        check("scratch_to_scratch_reuses_same_compartment", scratch2.id == scratch1Id)
        check("compartment_count_stays_one_on_same_domain",
              TaskCompartmentTracker.shared.compartments.count == 1)

        // ── Case 3: DeterminerSignal domain ≠ creative_coding for Dexter ─────────
        //
        // Even if a stale coding compartment is still present, DeterminerSignal must
        // use current-focus terms only for inferDomain(). "dexter/episode/season" has
        // zero overlap with creativeCodingTerms or codingTerms → domain stays unknown
        // or shifts to watching (if watchingTerms match).
        print("[CompartmentTransitionSelfTest] case=determiner_signal_dexter_domain")

        let staleComp = TaskCompartment(
            workflow: .coding,
            label: "Tank Shooter",
            dominantTerms: ["scratch", "sprite", "tank", "shooter", "collision", "turbowarp"],
            entities: ["Realistic Tank Shooter Demo - TurboWarp"],
            browserTabs: []
        )
        let dexterMemory = WorkingMemorySnapshot(
            currentEntity: "Dexter Season 1 Episode 3",
            recentEntities: ["Dexter Season 1 Episode 3"],
            repeatedConcepts: ["dexter", "episode", "season"],
            inferredActivity: "watching",
            comparisonCandidates: [],
            relatedFocusEntities: []
        )
        let dexterSignal = DeterminerSignal.evaluate(
            memory: dexterMemory,
            compartment: staleComp,        // stale coding compartment still present
            workflowConfidence: 0.0,
            behaviorConfidence: 0.0,
            activeTerms: ["dexter", "episode", "season"],
            currentEntity: "Dexter Season 1 Episode 3"
        )
        // Domain must NOT be creative_coding — current focus has zero Scratch/coding vocab.
        check("dexter_domain_not_creative_coding",
              dexterSignal.inferredDomain != .creative_coding)
        // Domain must NOT be coding either — same reason.
        check("dexter_domain_not_coding",
              dexterSignal.inferredDomain != .coding)
        print("[CompartmentTransitionSelfTest] dexter_inferred_domain=\(dexterSignal.inferredDomain.rawValue)")

        // ── Case 4: BestEffortDomain blocked when focus contradicts compartment ──
        //
        // Simulates the scenario where domain classification returns .unknown (no strong
        // terms), and BestEffortDomain would normally promote the compartment workflow.
        // With the Phase 22 guard, coding must NOT be promoted when the current-focus
        // terms contain no coding vocabulary.
        print("[CompartmentTransitionSelfTest] case=best_effort_domain_blocked")

        let emptyMemory = WorkingMemorySnapshot(
            currentEntity: "Dexter Season 1 Episode 3",
            recentEntities: ["Dexter Season 1 Episode 3"],
            repeatedConcepts: [],          // no terms → domain classification returns .unknown
            inferredActivity: "watching",
            comparisonCandidates: [],
            relatedFocusEntities: []
        )
        // Simulate active pointer movement to trigger BestEffortDomain path.
        let activeState = ActivityState.derive(
            typingScore: 0.0,
            pointerScore: 0.4,             // pointer movement → .interacting (active)
            dwellSeconds: 10.0,
            hadRecentNavigation: false
        )
        let blockedSignal = DeterminerSignal.evaluate(
            memory: emptyMemory,
            compartment: staleComp,        // coding compartment
            workflowConfidence: 0.0,
            behaviorConfidence: 0.0,
            activeTerms: ["dexter", "season"],  // no scratch/sprite/code vocabulary
            currentEntity: "Dexter Season 1 Episode 3",
            activityState: activeState
        )
        // BestEffortDomain should NOT promote coding since focus terms have no
        // coding or creative_coding vocabulary.
        check("best_effort_domain_not_creative_coding",
              blockedSignal.inferredDomain != .creative_coding)
        check("best_effort_domain_not_coding",
              blockedSignal.inferredDomain != .coding)
        print("[CompartmentTransitionSelfTest] blocked_best_effort_domain=\(blockedSignal.inferredDomain.rawValue)")

        // ── Case 6: Workflow-family incompatibility blocks cross-family reuse ─────
        //
        // .coding and .watching are in different workflow families (.coding is in
        // buildFamily; .watching is in passiveFamily). The tracker must reject the
        // coding compartment entirely when workflow=.watching, even if some packet
        // tokens overlap.
        print("[CompartmentTransitionSelfTest] case=workflow_family_incompatibility")
        TaskCompartmentTracker.shared.reset()

        let buildComp = TaskCompartmentTracker.shared.ingestUpdate(
            workflow: .coding,
            behavior: .coding,
            title: "My Platform Game - Scratch",
            tabs: [],
            topicTerms: ["scratch", "platform", "jump", "sprite"]
        )
        let buildId = buildComp.id

        // Switch to watching — different family.
        // Even if "sprite" token overlaps with packet, workflow-family check blocks it.
        let watchComp = TaskCompartmentTracker.shared.ingestUpdate(
            workflow: .watching,
            behavior: .watching,
            title: "Minecraft Let's Play Episode 1",
            tabs: [],
            topicTerms: ["minecraft", "gaming", "play", "sprite", "episode"]
        )
        check("watching_does_not_reuse_build_compartment", watchComp.id != buildId)
        check("watching_created_own_compartment",
              TaskCompartmentTracker.shared.compartments.count == 2)

        // Switching back to Scratch/coding must re-activate the build compartment
        // (not create a third one), since title tokens now match again.
        let backToScratch = TaskCompartmentTracker.shared.ingestUpdate(
            workflow: .coding,
            behavior: .coding,
            title: "My Platform Game - Scratch",
            tabs: [],
            topicTerms: ["scratch", "platform", "jump", "sprite"]
        )
        check("return_to_scratch_reuses_build_compartment", backToScratch.id == buildId)
        check("compartment_count_still_two_after_return",
              TaskCompartmentTracker.shared.compartments.count == 2)
    }
}
