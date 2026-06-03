import Foundation

/// Phase 20G — CognitiveActionIntentSelector picks bounded cognitive actions from
/// multi-input signals. Each case asserts which intent the selector returns
/// for a workflow/behavior/memory/judgment combination.
///
/// Trigger:
///   CONTEXTUAL_RUN_ACTION_INTENT_SELFTEST=1
@MainActor
public enum ActionIntentSelfTest {

    public static func run() async -> Bool {
        print("[ActionIntentSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[ActionIntentSelfTest] pass case=\(name)") }
            else  { print("[ActionIntentSelfTest] fail case=\(name)"); failures.append(name) }
        }

        func memory(_ entities: [String], related: [String] = [], comparison: [String] = []) -> WorkingMemorySnapshot {
            WorkingMemorySnapshot(
                currentEntity: entities.first ?? "Unknown",
                recentEntities: entities,
                repeatedConcepts: [],
                inferredActivity: "test",
                comparisonCandidates: comparison,
                staleEntities: [],
                relatedFocusEntities: related,
                backgroundEntities: []
            )
        }

        // 1. Studying + multiple related browser tabs -> synthesize_sources
        let r1 = CapabilitySelector.select(
            compartment: TaskCompartment(workflow: .studying, label: "Test", dominantTerms: [], entities: [], browserTabs: [], confidence: 0.9),
            workingMemory: memory(["CISC 101"], related: ["Week 1", "Problem Solving"]),
            evidenceQuality: "browser_tabs",
            currentApp: "Safari",
            behavior: .learning,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("studying_browser_tabs_synthesis", r1?.primary.id == "synthesize_sources")

        // 2. Studying + title only -> create_review_plan
        let r2 = CapabilitySelector.select(
            compartment: TaskCompartment(workflow: .studying, label: "Test", dominantTerms: [], entities: [], browserTabs: [], confidence: 0.9),
            workingMemory: memory(["CISC 101"]),
            evidenceQuality: "title_only",
            currentApp: "Safari",
            behavior: .learning,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("studying_title_only_plan", r2?.primary.id == "create_review_plan")

        // 2b. Studying + AX content -> generate_quiz
        let r2b = CapabilitySelector.select(
            compartment: TaskCompartment(workflow: .studying, label: "Test", dominantTerms: [], entities: [], browserTabs: [], confidence: 0.9),
            workingMemory: memory(["CISC 101"]),
            evidenceQuality: "ax_content",
            currentApp: "Safari",
            behavior: .learning,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("studying_ax_content_quiz", r2b?.primary.id == "generate_quiz")

        // 2c. Studying + selection -> explain_context
        let r2c = CapabilitySelector.select(
            compartment: TaskCompartment(workflow: .studying, label: "Test", dominantTerms: [], entities: [], browserTabs: [], confidence: 0.9),
            workingMemory: memory(["CISC 101"]),
            evidenceQuality: "selection",
            currentApp: "Safari",
            behavior: .learning,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("studying_selection_explain", r2c?.primary.id == "explain_context")

        // 3. Debugging → diagnose_error
        let r3 = CapabilitySelector.select(
            compartment: nil,
            workingMemory: memory(["main.swift"]),
            evidenceQuality: "title_only",
            currentApp: "Cursor",
            behavior: .debugging,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("debugging_diagnoses_error", r3?.primary.id == "diagnose_error")

        // 4. Error terms in any workflow → diagnose_error
        let memError = WorkingMemorySnapshot(
            currentEntity: "build.log",
            recentEntities: ["build.log"],
            repeatedConcepts: ["error"],
            inferredActivity: "test",
            comparisonCandidates: [],
            staleEntities: [],
            relatedFocusEntities: [],
            backgroundEntities: []
        )
        let r4 = CapabilitySelector.select(
            compartment: nil,
            workingMemory: memError,
            evidenceQuality: "title_only",
            currentApp: "Terminal",
            behavior: .coding,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("error_terms_force_diagnostic", r4?.primary.id == "diagnose_error")

        // 5. Writing + selection → improve_text
        let r5 = CapabilitySelector.select(
            compartment: nil,
            workingMemory: memory(["essay.md"]),
            evidenceQuality: "selection",
            currentApp: "TextEdit",
            behavior: .writing,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("writing_with_selection_improves_draft", r5?.primary.id == "improve_text")

        // 6. Writing without selection → create_outline
        let r6 = CapabilitySelector.select(
            compartment: nil,
            workingMemory: memory(["essay.md"]),
            evidenceQuality: "title_only",
            currentApp: "TextEdit",
            behavior: .writing,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("writing_no_selection_outline", r6?.primary.id == "create_outline")

        // 7. Shopping → compare_options
        let r7 = CapabilitySelector.select(
            compartment: TaskCompartment(workflow: .shopping, label: "Amazon", dominantTerms: [], entities: [], browserTabs: [], confidence: 0.9),
            workingMemory: memory(["Anker Prime 200W", "Anker Solix"]),
            evidenceQuality: "title_only",
            currentApp: "Safari",
            behavior: .comparing,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("shopping_compare_options", r7?.primary.id == "compare_options")

        // 8. General Research → summarize_context
        let r8 = CapabilitySelector.select(
            compartment: nil,
            workingMemory: memory(["Attention"]),
            evidenceQuality: "title_only",
            currentApp: "Safari",
            behavior: .researching,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("research_summarize", r8?.primary.id == "summarize_context")

        // 9. General Research + multi → synthesize_sources
        let r9 = CapabilitySelector.select(
            compartment: nil,
            workingMemory: memory(["lecture1", "lecture2", "lecture3"]),
            evidenceQuality: "browser_tabs",
            currentApp: "Safari",
            behavior: .learning, // or learning
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("research_multi_synthesize", r9?.primary.id == "synthesize_sources")

        // 10. Generic fallback
        let r10 = CapabilitySelector.select(
            compartment: nil,
            workingMemory: memory([]),
            evidenceQuality: "title_only",
            currentApp: "Finder",
            behavior: .unknown,
            userInitiated: false,
            availableCapabilities: Array(CognitiveCapabilityRegistry.shared.capabilities.values)
        )
        check("fallback_suggest_next_step", r10?.primary.id == "summarize_context") // summarize_context is the new fallback primary

        let intents = [r1, r2, r2b, r2c, r3, r4, r5, r6, r7, r8, r9, r10]
        let allSafe = intents.allSatisfy { $0?.primary.riskLevel == .read_only || $0?.primary.riskLevel == .light_action }
        check("all_capabilities_safe", allSafe)

        let ok = failures.isEmpty
        print("[ActionIntentSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
