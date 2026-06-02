import Foundation

/// Phase 21.1 — DeterminerSignal self test.
///
/// Verifies that DeterminerSignal correctly:
///   1. Returns actionable=yes when compartment trust is sufficient.
///   2. Returns actionable=yes when entity + active terms are sufficient.
///   3. Returns actionable=no when no structural signals are present.
///   4. Infers creative_coding domain from project/game/scratch terms.
///   5. Infers studying domain from lecture/homework/quiz terms.
///   6. Infers shopping domain from price/buy/cart terms.
///   7. Infers researching domain from paper/arxiv/assistant terms.
///   8. Infers coding domain from swift/xcode/compile terms.
///   9. Does NOT infer shopping when creative_coding terms dominate.
///  10. Mode is .building for creative_coding with build terms present.
///
/// Trigger:
///   CONTEXTUAL_RUN_DETERMINER_SIGNAL_SELFTEST=1
enum DeterminerSignalSelfTest {

    static func run() -> Bool {
        print("[DeterminerSignalSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[DeterminerSignalSelfTest] pass case=\(name)") }
            else  { print("[DeterminerSignalSelfTest] fail case=\(name)"); failures.append(name) }
        }

        // ── Case 1: Actionable via compartment trust ───────────────────────────
        let strongComp = TaskCompartment(
            workflow: .unknown,
            label: "Tank Shooter",
            dominantTerms: ["demo", "shooter", "tank", "turbowarp"],
            entities: ["Realistic Tank Shooter Demo - TurboWarp"],
            browserTabs: [],
            confidence: 0.85,
            activeScore: 1.0
        )
        let ds1 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: strongComp
        )
        check("actionable_via_compartment_trust", ds1.actionable)
        check("compartment_trust_reason", ds1.reason == "compartment_memory_sufficient")

        // ── Case 2: Actionable via entity + active terms ────────────────────────
        let mem2 = WorkingMemorySnapshot(
            currentEntity: "Realistic Tank Shooter Demo - TurboWarp",
            recentEntities: ["Realistic Tank Shooter Demo - TurboWarp"],
            repeatedConcepts: ["demo", "shooter"],
            inferredActivity: "unknown",
            comparisonCandidates: []
        )
        let ds2 = DeterminerSignal.evaluate(
            memory: mem2,
            compartment: nil
        )
        check("actionable_via_entity_and_terms", ds2.actionable)
        check("entity_terms_reason", ds2.reason == "entity_and_terms_sufficient")

        // ── Case 3: Not actionable with no signals ─────────────────────────────
        let emptyMem = WorkingMemorySnapshot(
            currentEntity: "",
            recentEntities: [],
            repeatedConcepts: [],
            inferredActivity: "unknown",
            comparisonCandidates: []
        )
        let ds3 = DeterminerSignal.evaluate(
            memory: emptyMem,
            compartment: nil,
            workflowConfidence: 0.0,
            behaviorConfidence: 0.0
        )
        check("not_actionable_no_signals", !ds3.actionable)
        // Accepts both "no_sufficient_signal" and "blank_or_neutral_tab" —
        // an empty currentEntity is a neutral/blank context either way.
        check("no_signal_reason",
              ds3.reason == "no_sufficient_signal" || ds3.reason == "blank_or_neutral_tab")

        // ── Case 4: creative_coding domain from project/game/scratch terms ─────
        let ds4 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: nil,
            activeTerms: ["scratch", "sprite", "project", "coding"]
        )
        check("domain_creative_coding", ds4.inferredDomain == .creative_coding)

        // ── Case 5: studying domain ────────────────────────────────────────────
        let ds5 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: nil,
            activeTerms: ["lecture", "homework", "quiz", "chapter"]
        )
        check("domain_studying", ds5.inferredDomain == .studying)

        // ── Case 6: shopping domain ────────────────────────────────────────────
        let ds6 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: nil,
            activeTerms: ["price", "buy", "cart", "shipping", "deal"]
        )
        check("domain_shopping", ds6.inferredDomain == .shopping)

        // ── Case 7: researching domain ────────────────────────────────────────
        let ds7 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: nil,
            activeTerms: ["paper", "arxiv", "abstract", "dataset", "gemini"]
        )
        check("domain_researching", ds7.inferredDomain == .researching)

        // ── Case 8: coding domain ─────────────────────────────────────────────
        let ds8 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: nil,
            activeTerms: ["swift", "xcode", "compile", "function", "struct"]
        )
        check("domain_coding", ds8.inferredDomain == .coding)

        // ── Case 9: creative_coding NOT shopping despite "demo" and "build" ───
        // TurboWarp page has zero shopping terms (price/buy/cart) so should
        // never infer shopping.
        let ds9 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: nil,
            activeTerms: ["demo", "shooter", "tank", "turbowarp", "sprite", "coding"]
        )
        check("creative_coding_not_shopping", ds9.inferredDomain != .shopping)
        check("creative_coding_correct_domain", ds9.inferredDomain == .creative_coding)

        // ── Case 10: mode=building for creative_coding + build terms ──────────
        let ds10 = DeterminerSignal.evaluate(
            memory: nil,
            compartment: nil,
            activeTerms: ["scratch", "project", "build", "program", "coding"]
        )
        check("mode_building_for_creative_coding",
              ds10.inferredDomain == .creative_coding && ds10.inferredMode == .building)

        let ok = failures.isEmpty
        print("[DeterminerSignalSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
