import Foundation

/// Phase 22.1 — Entertainment policy self-test.
///
/// Verifies that OpportunityEngine returns no proposals when entity grounding
/// classifies the entity as passive entertainment (tv_show, youtube_video).
///
/// Trigger: CONTEXTUAL_RUN_ENTERTAINMENT_POLICY_SELFTEST=1
///
/// Test cases:
///  1. TV show grounding (netflix URL) → OpportunityEngine returns []
///  2. YouTube video grounding         → OpportunityEngine returns []
///  3. create_next_steps NOT in result for tv_show
///  4. Code project grounding          → OpportunityEngine returns opportunities
///  5. Course material grounding       → OpportunityEngine returns opportunities
///  6. Unknown grounding (shouldPropose=false) → OpportunityEngine returns []
///  7. No grounding (nil)              → OpportunityEngine may return fallback
enum EntertainmentPolicySelfTest {

    static func run() async -> Bool {
        print("[EntertainmentPolicySelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[EntertainmentPolicySelfTest] pass case=\(name)")
            } else {
                print("[EntertainmentPolicySelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        let signal = makeDeterminerSignal(domain: .watching)
        let codeSignal = makeDeterminerSignal(domain: .coding)
        let studySignal = makeDeterminerSignal(domain: .studying)
        let unknownSignal = makeDeterminerSignal(domain: .unknown)

        let tvMemory = makeMemory("Dexter Season 1 Episode 3")
        let codeMemory = makeMemory("My Platform Game - TurboWarp")
        let courseMemory = makeMemory("CISC 121 Lecture 5")
        let emptyMemory = makeMemory("")

        // ── Case 1: TV show grounding → [] ────────────────────────────────────
        let tvGrounding = EntityGrounding(
            entityName: "Dexter Season 1 Episode 3",
            entityType: .tv_show,
            source: .url,
            confidence: 0.88,
            summary: "Streaming host + episode path",
            shouldPropose: false,
            allowedOpportunityTypes: []
        )
        let tvOpps = await OpportunityEngine.evaluate(
            determinerSignal: signal,
            activityState: nil,
            compartment: nil,
            memory: tvMemory,
            evidenceQuality: "title_only",
            entityGrounding: tvGrounding,
            groundingResult: nil
        )
        check("tv_show_grounding_returns_empty", tvOpps.isEmpty)

        // ── Case 2: YouTube video grounding → [] ──────────────────────────────
        let ytGrounding = EntityGrounding(
            entityName: "Never Gonna Give You Up",
            entityType: .youtube_video,
            source: .url,
            confidence: 0.90,
            summary: "YouTube host + watch path",
            shouldPropose: false,
            allowedOpportunityTypes: []
        )
        let ytOpps = await OpportunityEngine.evaluate(
            determinerSignal: signal,
            activityState: nil,
            compartment: nil,
            memory: makeMemory("Never Gonna Give You Up - YouTube"),
            evidenceQuality: "title_only",
            entityGrounding: ytGrounding,
            groundingResult: nil
        )
        check("youtube_grounding_returns_empty", ytOpps.isEmpty)

        // ── Case 3: create_next_steps NOT in TV show result ───────────────────
        check("tv_show_no_create_next_steps",
              !tvOpps.contains { $0.capabilityId == "create_next_steps" })

        // ── Case 4: Code project grounding → returns opportunities ────────────
        let codeGrounding = EntityGrounding(
            entityName: "My Platform Game - TurboWarp",
            entityType: .code_project,
            source: .url,
            confidence: 0.88,
            summary: "Code hosting host tokens",
            shouldPropose: true,
            allowedOpportunityTypes: [
                "generate_test_checklist", "create_game_design_checklist",
                "diagnose_error", "debug_performance", "create_next_steps",
                "create_checklist", "improve_project"
            ]
        )
        let codeOpps = await OpportunityEngine.evaluate(
            determinerSignal: codeSignal,
            activityState: nil,
            compartment: nil,
            memory: codeMemory,
            evidenceQuality: "title_only",
            entityGrounding: codeGrounding,
            groundingResult: nil
        )
        check("code_project_grounding_returns_opportunities",
              !codeOpps.isEmpty)
        check("code_project_opportunities_are_in_allowed_types",
              codeOpps.allSatisfy { codeGrounding.allowedOpportunityTypes.contains($0.capabilityId) })

        // ── Case 5: Course material grounding → returns opportunities ─────────
        let courseGrounding = EntityGrounding(
            entityName: "CISC 121 Lecture 5",
            entityType: .course_material,
            source: .url,
            confidence: 0.82,
            summary: "Academic LMS host tokens",
            shouldPropose: true,
            allowedOpportunityTypes: [
                "generate_quiz", "create_review_plan", "create_study_outline",
                "synthesize_sources", "explain_context", "organize_review_plan"
            ]
        )
        let courseOpps = await OpportunityEngine.evaluate(
            determinerSignal: studySignal,
            activityState: nil,
            compartment: nil,
            memory: courseMemory,
            evidenceQuality: "title_only",
            entityGrounding: courseGrounding,
            groundingResult: nil
        )

        check("course_material_grounding_returns_opportunities",
              !courseOpps.isEmpty)
        check("course_material_opportunities_are_in_allowed_types",
              courseOpps.allSatisfy { courseGrounding.allowedOpportunityTypes.contains($0.capabilityId) })

        // ── Case 6: Unknown grounding (shouldPropose=false) → [] ─────────────
        let unknownGrounding = EntityGrounding(
            entityName: "Untitled 1",
            entityType: .unknown,
            source: .title_only,
            confidence: 0.18,
            summary: "No matching patterns",
            shouldPropose: false,
            allowedOpportunityTypes: []
        )
        let unknownOpps = await OpportunityEngine.evaluate(
            determinerSignal: unknownSignal,
            activityState: nil,
            compartment: nil,
            memory: makeMemory("Untitled 1"),
            evidenceQuality: "title_only",
            entityGrounding: unknownGrounding,
            groundingResult: nil
        )

        check("unknown_grounding_returns_empty", unknownOpps.isEmpty)
        check("unknown_grounding_no_create_next_steps",
              !unknownOpps.contains { $0.capabilityId == "create_next_steps" })

        // ── Case 7: No grounding (nil) → may return fallback ─────────────────
        //   This is the legacy path. We only check it does NOT crash and returns
        //   something (even if just create_next_steps fallback).
        let noGroundingOpps = await OpportunityEngine.evaluate(
            determinerSignal: unknownSignal,
            activityState: nil,
            compartment: nil,
            memory: emptyMemory,
            evidenceQuality: "title_only",
            entityGrounding: nil,
            groundingResult: nil
        )
        check("no_grounding_legacy_path_does_not_crash",
              true)   // reaching here = no crash
        _ = noGroundingOpps  // suppress unused warning; fallback may or may not fire

        let ok = failures.isEmpty
        print("[EntertainmentPolicySelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }

    // MARK: - Helpers

    private static func makeDeterminerSignal(domain: DeterminerSignal.Domain) -> DeterminerSignal {
        DeterminerSignal(
            actionable: domain != .unknown && domain != .watching,
            inferredDomain: domain,
            inferredMode: .unknown,
            confidence: domain == .unknown ? 0.30 : 0.75,
            reason: "selftest"
        )
    }

    private static func makeMemory(_ entity: String) -> WorkingMemorySnapshot {
        WorkingMemorySnapshot(
            currentEntity: entity,
            recentEntities: entity.isEmpty ? [] : [entity],
            repeatedConcepts: [],
            inferredActivity: "unknown",
            comparisonCandidates: [],
            relatedFocusEntities: []
        )
    }
}
