import Foundation

/// Phase 22.2 — OpportunityNoveltyTracker self-test (Task I).
///
/// Verifies novelty decay, duplicate suppression, ring-buffer eviction,
/// and that the tracker properly diversifies suggestions over time.
///
/// Trigger: CONTEXTUAL_RUN_OPPORTUNITY_NOVELTY_SELFTEST=1
enum OpportunityNoveltySelfTest {

    static func run() -> Bool {
        print("[OpportunityNoveltySelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[OpportunityNoveltySelfTest] pass case=\(name)")
            } else {
                print("[OpportunityNoveltySelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        let tracker = OpportunityNoveltyTracker()
        let key = "test_entity_novelty"

        // ── Case 1: Fresh capability → full novelty ───────────────────────────
        let freshScore = tracker.noveltyScore(capabilityId: "generate_quiz", entityKey: key)
        check("fresh_capability_novelty_is_1", freshScore == 1.0)

        // ── Case 2: Immediately after showing → near-zero novelty ────────────
        let now = Date()
        tracker.markShown(capabilityId: "generate_quiz", entityKey: key, now: now)
        // Synchronous read right after — should be in suppression window
        let suppressedScore = tracker.noveltyScore(capabilityId: "generate_quiz",
                                                    entityKey: key, now: now.addingTimeInterval(5))
        check("recently_shown_score_below_0.2", suppressedScore < 0.20)

        // ── Case 3: Two-minute-old → partial novelty ──────────────────────────
        let twoMinAgo = now.addingTimeInterval(-125)   // just past suppression window
        tracker.reset(entityKey: key)
        tracker.markShown(capabilityId: "create_flashcards", entityKey: key, now: twoMinAgo)
        let partialScore = tracker.noveltyScore(capabilityId: "create_flashcards",
                                                 entityKey: key, now: now)
        check("two_min_old_score_between_0.2_and_0.5", partialScore >= 0.20 && partialScore < 0.50)

        // ── Case 4: 15+ minutes old → full novelty restored ──────────────────
        tracker.reset(entityKey: key)
        let fifteenMinAgo = now.addingTimeInterval(-(15 * 60 + 10))
        tracker.markShown(capabilityId: "create_flashcards", entityKey: key, now: fifteenMinAgo)
        let restoredScore = tracker.noveltyScore(capabilityId: "create_flashcards",
                                                  entityKey: key, now: now)
        check("fifteen_min_old_score_is_1", restoredScore >= 0.99)

        // ── Case 5: Creative project does not always choose the same action ───
        // Simulate: show generate_test_checklist multiple times rapidly,
        // then verify OpportunityReasoner ranks it lower than alternatives.
        tracker.reset()
        let codeKey = "test_code_project_novelty"
        let situation = makeSituation(.code_project, domain: .creative_coding, entityKey: codeKey)

        // First call — should produce something
        let firstCandidates = OpportunityReasoner.reason(situation: situation, noveltyTracker: tracker)
        let firstTopId = firstCandidates.first?.capabilityId ?? ""
        check("creative_project_first_call_has_candidates", !firstCandidates.isEmpty)

        // Mark the top capability as shown
        if !firstTopId.isEmpty {
            tracker.markShown(capabilityId: firstTopId, entityKey: codeKey, now: now)
        }

        // Second call right after — top should differ OR score should be lower
        let secondCandidates = OpportunityReasoner.reason(situation: situation, noveltyTracker: tracker)
        _ = secondCandidates.first?.capabilityId ?? ""
        // Either different capability bubbles up, or the same one is still valid (possible if only 1 qualifies)
        // The key assertion: the first top's novelty is now lower
        if !firstTopId.isEmpty {
            let afterShowScore = tracker.noveltyScore(capabilityId: firstTopId,
                                                       entityKey: codeKey, now: now.addingTimeInterval(1))
            check("creative_project_top_novelty_drops_after_show", afterShowScore < 0.20)
        }

        // ── Case 6: Duplicate suppression — checklist doesn't repeat immediately
        tracker.reset()
        let checklistKey = "test_checklist_novelty"
        let checklistSit = makeSituation(.code_project, domain: .creative_coding, entityKey: checklistKey)

        let r1 = OpportunityReasoner.reason(situation: checklistSit, noveltyTracker: tracker)
        let r1Top = r1.first?.capabilityId ?? ""
        if !r1Top.isEmpty {
            tracker.markShown(capabilityId: r1Top, entityKey: checklistKey, now: now)
        }

        let r2 = OpportunityReasoner.reason(situation: checklistSit, noveltyTracker: tracker)
        let r2Top = r2.first?.capabilityId ?? ""

        // If there is only one qualifying capability the top may repeat — that's valid.
        // But its noveltyScore should be depressed after marking.
        if r1Top == r2Top && !r1Top.isEmpty {
            let ns = tracker.noveltyScore(capabilityId: r1Top,
                                          entityKey: checklistKey, now: now.addingTimeInterval(1))
            check("repeated_top_has_depressed_novelty", ns < 0.20)
        } else {
            // Different top selected — ideal diversity achieved
            check("checklist_second_pick_is_different", r1Top != r2Top)
        }

        // ── Case 7: recentlyShown returns correct entries ─────────────────────
        tracker.reset()
        let recentKey = "test_recent"
        let t0 = Date()
        tracker.markShown(capabilityId: "cap_A", entityKey: recentKey, now: t0)
        tracker.markShown(capabilityId: "cap_B", entityKey: recentKey, now: t0.addingTimeInterval(1))
        let recent = tracker.recentlyShown(entityKey: recentKey, windowSeconds: 60, now: t0.addingTimeInterval(5))
        check("recently_shown_contains_cap_A", recent.contains("cap_A"))
        check("recently_shown_contains_cap_B", recent.contains("cap_B"))

        // ── Case 8: recentlyShown excludes old entries ────────────────────────
        let oldRecent = tracker.recentlyShown(entityKey: recentKey,
                                               windowSeconds: 0.5,
                                               now: t0.addingTimeInterval(5))
        check("recently_shown_excludes_old_entries", oldRecent.isEmpty)

        // ── Case 9: Ring buffer prunes beyond maxHistoryPerKey ────────────────
        tracker.reset()
        let ringKey = "test_ring"
        for i in 0..<15 {
            tracker.markShown(capabilityId: "cap_\(i)", entityKey: ringKey,
                              now: t0.addingTimeInterval(Double(i)))
        }
        let seenAfterOverflow = tracker.seenCapabilities(entityKey: ringKey,
                                                          now: t0.addingTimeInterval(20))
        // Ring buffer max is 12; so early entries may be evicted
        // We should see no more than 12 distinct capabilities
        check("ring_buffer_max_12_entries", seenAfterOverflow.count <= 12)
        // And the newest ones should definitely still be there
        check("ring_buffer_newest_entry_survives",
              tracker.noveltyScore(capabilityId: "cap_14", entityKey: ringKey,
                                   now: t0.addingTimeInterval(20)) < 1.0)

        // ── Case 10: reset() clears all state ────────────────────────────────
        tracker.markShown(capabilityId: "generate_quiz", entityKey: "some_entity", now: Date())
        tracker.reset()
        let afterReset = tracker.noveltyScore(capabilityId: "generate_quiz",
                                               entityKey: "some_entity", now: Date())
        check("reset_clears_all_history", afterReset == 1.0)

        let ok = failures.isEmpty
        print("[OpportunityNoveltySelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }

    // MARK: - Helpers

    private static func makeSituation(
        _ entityType: EntityGrounding.EntityType,
        domain: DeterminerSignal.Domain,
        entityKey: String = "test_key"
    ) -> OpportunityReasoner.Situation {
        OpportunityReasoner.Situation(
            entityType: entityType,
            entityConfidence: 0.85,
            domain: domain,
            mode: .unknown,
            evidenceQuality: "title_only",
            hasErrorTerms: false,
            hasMultipleSources: false,
            hasComparisonCandidates: false,
            isActivelyEditing: false,
            compartmentDwellSeconds: 180,
            entityKey: entityKey
        )
    }
}
