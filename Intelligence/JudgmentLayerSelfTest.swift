import Foundation

/// Self-test for the Phase 20D Judgment Layer. Trigger:
///   CONTEXTUAL_RUN_JUDGMENT_LAYER_SELFTEST=1
///
/// Verifies the exact scenarios called out in the brief:
///   1. Anker 24,000 mAh + 140 W same product → incompatible_units flag,
///      no false comparison.
///   2. Power bank vs SOLIX F3800 → relationship=differentCategory,
///      comparisonValidity=invalid → ArtifactSelector returns clarification_brief.
///   3. Three chargers in same category → relationship=sameCategory,
///      comparisonValidity=direct or partial → recommendation_brief.
///   4. Research pages (transformer/attention/BERT) → decisionType=knowledgeAcquisition.
///   5. Debugging titles → decisionType=diagnostic.
///   6. WorkingMemory entities feed JudgmentLayer (no bypassing).
///   7. ArtifactSelector uses judgment, not workflow.
@MainActor
enum JudgmentLayerSelfTest {

    static func run() async -> Bool {
        print("[JudgmentLayerSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[JudgmentLayerSelfTest] pass case=\(name)")
            } else {
                print("[JudgmentLayerSelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        // -------- Case 1: incompatible_units (mAh vs W on the same product) --------
        let memory1 = makeMemory(
            candidates: ["Anker 24,000 mAh Power Bank", "Anker 140W Output"],
            concepts: ["anker"]
        )
        let page1 = emptyPage()
        let facts1: [PublicWebResearchEnricher.PublicGroundedFact] = [
            makeFact("capacity", "24000 mAh", "anker-1"),
            makeFact("output", "140W", "anker-1"),
        ]
        let packet1 = makePacket(currentApp: "Firefox", titles: memory1.comparisonCandidates, terms: ["anker", "power", "mah"])
        let workflow1 = makeWorkflow(.shopping); let behavior1 = makeBehavior(.comparing)
        let j1 = JudgmentLayer.judge(workflow: workflow1, behavior: behavior1, memory: memory1, page: page1, researchFacts: facts1, packet: packet1)
        check("incompatible_units_detected_mAh_vs_W", j1.incompatibleUnitsDetected)
        check("incompatible_units_not_direct_comparison", j1.comparisonValidity != .direct)

        // -------- Case 2: power bank vs SOLIX (categorical mismatch via research facts) --------
        let memory2 = makeMemory(
            candidates: ["Anker Laptop Power Bank", "Anker SOLIX F3800"],
            concepts: ["anker"]
        )
        let page2 = emptyPage()
        let facts2: [PublicWebResearchEnricher.PublicGroundedFact] = [
            makeFact("category", "portable battery", "anker-pb"),
            makeFact("category", "home backup power station", "anker-solix"),
        ]
        let packet2 = makePacket(currentApp: "Firefox", titles: memory2.comparisonCandidates, terms: ["anker", "power", "bank"])
        let workflow2 = makeWorkflow(.shopping); let behavior2 = makeBehavior(.comparing)
        let j2 = JudgmentLayer.judge(workflow: workflow2, behavior: behavior2, memory: memory2, page: page2, researchFacts: facts2, packet: packet2)
        check("powerbank_vs_solix_different_category", j2.relationship == .differentCategory)
        check("powerbank_vs_solix_invalid_comparison", j2.comparisonValidity == .invalid)
        check("powerbank_vs_solix_selects_clarification", ArtifactSelector.type(for: j2) == "clarification_brief")

        // -------- Case 3: three chargers in same category --------
        let memory3 = makeMemory(
            candidates: ["Anker Prime 200W Charger", "Baseus 65W Charger", "UGREEN Nexode 100W Charger"],
            concepts: ["charger"]
        )
        let page3 = emptyPage()
        let facts3: [PublicWebResearchEnricher.PublicGroundedFact] = [
            makeFact("wattage", "200W", "anker"),
            makeFact("wattage", "65W", "baseus"),
            makeFact("wattage", "100W", "ugreen"),
        ]
        let packet3 = makePacket(currentApp: "Firefox",
                                 titles: memory3.comparisonCandidates,
                                 terms: ["charger", "usb", "anker", "baseus", "ugreen"])
        let workflow3 = makeWorkflow(.shopping); let behavior3 = makeBehavior(.comparing)
        let j3 = JudgmentLayer.judge(workflow: workflow3, behavior: behavior3, memory: memory3, page: page3, researchFacts: facts3, packet: packet3)
        check("three_chargers_same_category", j3.relationship == .sameCategory)
        check("three_chargers_valid_comparison",
              j3.comparisonValidity == .direct || j3.comparisonValidity == .partial)
        check("three_chargers_selects_recommendation", ArtifactSelector.type(for: j3) == "recommendation_brief")

        // -------- Case 4: research pages --------
        let memory4 = makeMemory(
            candidates: [
                "Attention Is All You Need",
                "The Illustrated Transformer",
                "BERT Explained",
            ],
            concepts: ["transformer", "attention", "encoder"]
        )
        let packet4 = makePacket(currentApp: "Safari",
                                 titles: memory4.comparisonCandidates,
                                 terms: ["transformer", "attention", "encoder", "neural"])
        let workflow4 = makeWorkflow(.researching); let behavior4 = makeBehavior(.researching)
        let j4 = JudgmentLayer.judge(workflow: workflow4, behavior: behavior4, memory: memory4, page: emptyPage(), researchFacts: [], packet: packet4)
        check("research_decision_type", j4.decisionType == .knowledgeAcquisition)
        check("research_selects_research_brief", ArtifactSelector.type(for: j4) == "research_brief")

        // -------- Case 5: debugging --------
        let memory5 = makeMemory(
            candidates: ["main.swift — build failed", "Errors — test run"],
            concepts: ["error", "build"]
        )
        let packet5 = makePacket(currentApp: "Terminal",
                                 titles: memory5.comparisonCandidates,
                                 terms: ["error", "build", "failed", "test"])
        let workflow5 = makeWorkflow(.debugging); let behavior5 = makeBehavior(.debugging)
        let j5 = JudgmentLayer.judge(workflow: workflow5, behavior: behavior5, memory: memory5, page: emptyPage(), researchFacts: [], packet: packet5)
        check("debug_decision_type", j5.decisionType == .diagnostic)
        check("debug_selects_diagnostic_brief", ArtifactSelector.type(for: j5) == "diagnostic_brief")

        // -------- Case 6: WorkingMemory entities are what feeds JudgmentLayer --------
        let memory6 = makeMemory(
            candidates: ["Title A", "Title B"],
            concepts: ["alpha"]
        )
        let j6 = JudgmentLayer.judge(workflow: workflow1, behavior: behavior1, memory: memory6, page: emptyPage(), researchFacts: [], packet: makePacket(currentApp: "Firefox", titles: ["unused"], terms: []))
        check("working_memory_drives_judgment", j6.entities == memory6.comparisonCandidates)

        // -------- Case 7: ArtifactSelector reads judgment, not workflow --------
        let invalidJudgment = ContextJudgment(
            entities: ["X", "Y"],
            relationship: .differentCategory,
            comparisonValidity: .invalid,
            decisionType: .productChoice,
            missingInformation: [],
            rationale: [],
            confidence: 0.5,
            incompatibleUnitsDetected: false
        )
        check("artifact_selector_invalid_returns_clarification",
              ArtifactSelector.type(for: invalidJudgment) == "clarification_brief")

        // -------- Case 8: unit classifier sanity --------
        check("unit_classifier_mAh", NumericUnitClassifier.dimension(forUnit: "mAh") == .chargeCapacity)
        check("unit_classifier_W",   NumericUnitClassifier.dimension(forUnit: "W") == .power)
        check("unit_classifier_Wh",  NumericUnitClassifier.dimension(forUnit: "Wh") == .energyStorage)
        check("unit_classifier_USD", NumericUnitClassifier.dimension(forUnit: "USD") == .price)
        let parsedFacts = NumericUnitClassifier.extractFacts(from: "24,000 mAh and 140W output, $89.99", label: "spec")
        check("unit_classifier_extracts_three_dims",
              Set(parsedFacts.map { $0.dimension }).count >= 3)

        let ok = failures.isEmpty
        print("[JudgmentLayerSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }

    // MARK: - Test fixtures

    private static func makeMemory(candidates: [String], concepts: [String]) -> WorkingMemorySnapshot {
        WorkingMemorySnapshot(
            currentEntity: candidates.first ?? "Unknown",
            recentEntities: candidates,
            repeatedConcepts: concepts,
            inferredActivity: "selftest",
            comparisonCandidates: candidates
        )
    }

    private static func emptyPage() -> PublicPageContextExtractor.PublicPageContext {
        PublicPageContextExtractor.PublicPageContext(
            url: nil, pageTitle: nil, ogTitle: nil, ogDescription: nil,
            productFacts: [:], extractedAt: Date(), source: "selftest_empty"
        )
    }

    private static func makeFact(_ label: String, _ value: String, _ source: String) -> PublicWebResearchEnricher.PublicGroundedFact {
        PublicWebResearchEnricher.PublicGroundedFact(
            label: label, value: value, sourceURL: "https://selftest/\(source)",
            sourceTitle: source, method: "selftest", confidence: 0.9
        )
    }

    private static func makePacket(currentApp: String, titles: [String], terms: [String]) -> CompressedTemporalPacket {
        CompressedTemporalPacket(
            currentApp: currentApp,
            recentApps: [currentApp],
            recentTitles: titles,
            topicTerms: terms,
            activityPattern: "steady",
            idlePattern: "active",
            typingPattern: "none",
            pointerPattern: "occasional",
            ocrHints: [],
            selectionHints: [],
            clipboardMetadata: "none",
            recentUserAccepts: [],
            recentUserIgnores: [],
            spanSeconds: 600,
            eventCount: 10,
            contextShiftDetected: false
        )
    }

    private static func makeWorkflow(_ t: AmbientWorkflowType) -> WorkflowState {
        let now = Date()
        return WorkflowState(
            workflowType: t, confidence: 0.85, evidence: ["selftest"], uncertainty: "test",
            startedAt: now, lastUpdatedAt: now, stabilityScore: 0.7,
            dominantApps: [], repeatedTerms: [], recentTransitions: [],
            suggestedIntentHints: [], sourcePacketHash: "selftest"
        )
    }

    private static func makeBehavior(_ s: BehavioralState) -> BehavioralStateRecord {
        let now = Date()
        return BehavioralStateRecord(state: s, confidence: 0.8, reasoning: "selftest",
                                      startedAt: now, lastUpdatedAt: now, stabilityScore: 0.7)
    }
}
