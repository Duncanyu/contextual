import Foundation

/// Phase 20G.5 — ManualInvokeJarvis content probe self test
///
/// Trigger:
///   CONTEXTUAL_RUN_MANUAL_INVOKE_JARVIS_SELFTEST=1
@MainActor
public struct ManualInvokeJarvisSelfTest: Sendable {
    
    public static func run() async -> Bool {
        print("[ManualInvokeJarvisSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[ManualInvokeJarvisSelfTest] pass case=\(name)") }
            else  { print("[ManualInvokeJarvisSelfTest] fail case=\(name)"); failures.append(name) }
        }
        
        let producer = ContextEventProducer(
            coordinator: WorkflowIntelligenceCoordinator(),
            behavioralCoordinator: BehavioralIntelligenceCoordinator()
        )
        let coordinator = WorkflowIntelligenceCoordinator()
        let behavioral = BehavioralIntelligenceCoordinator()
        
        // Setup current epoch
        ContextEpochTracker.shared.resetForTests()
        ContextEpochTracker.shared.observe(
            contextShiftDetected: false,
            shiftReason: "seed",
            earlyTopTerms: [],
            recentTopTerms: ["cisc", "121", "studying"],
            recentTitles: ["Week-2 - CISC 121"]
        )
        
        // Test case A: studying page with only titles -> title_only evidence -> organize_study_plan
        let snap1 = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Firefox",
            windowTitle: "Week-2 - CISC 121",
            bundleIdentifier: "org.mozilla.firefox",
            selectedText: nil,
            recentOCRExcerpt: nil
        )
        
        let overrideWorkflow = WorkflowState(
            workflowType: .studying,
            confidence: 0.90,
            evidence: ["test"],
            uncertainty: "none",
            startedAt: Date(),
            lastUpdatedAt: Date(),
            stabilityScore: 0.85,
            dominantApps: ["Firefox"],
            repeatedTerms: [],
            recentTransitions: [],
            suggestedIntentHints: [],
            sourcePacketHash: "h1"
        )
        let overrideBehavior = BehavioralStateRecord(
            state: .learning,
            confidence: 0.85,
            reasoning: "test",
            startedAt: Date(),
            lastUpdatedAt: Date(),
            stabilityScore: 0.80
        )
        
        let res1 = await ManualInvokeJarvis.runPipeline(
            source: "test_title_only",
            synthesizedSnapshot: snap1,
            hasBrowserContext: false,
            browserTabTitles: [],
            selectedBrowserTabTitle: nil,
            producer: producer,
            coordinator: coordinator,
            behavioral: behavioral,
            overrideWorkflow: overrideWorkflow,
            overrideBehavior: overrideBehavior
        )
        
        check("title_only_evidence_probed", res1.evidenceQuality == "title_only")
        // CapabilitySelector returns "create_review_plan" for studying+title_only (CapabilityRegistrySelfTest).
        check("title_only_study_intent_organize", res1.intent == "create_review_plan")
        
        // Test case B: studying page with AX content fallback (via recentOCRExcerpt simulator in runPipeline) -> ax_content -> generate_quiz
        let snap2 = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Firefox",
            windowTitle: "Week-2 - CISC 121",
            bundleIdentifier: "org.mozilla.firefox",
            selectedText: nil,
            recentOCRExcerpt: "CISC 121 Lecture 2. Topic: Computational thinking and problem solving with programming tools."
        )
        
        let res2 = await ManualInvokeJarvis.runPipeline(
            source: "test_ax_content",
            synthesizedSnapshot: snap2,
            hasBrowserContext: false,
            browserTabTitles: [],
            selectedBrowserTabTitle: nil,
            producer: producer,
            coordinator: coordinator,
            behavioral: behavioral,
            overrideWorkflow: overrideWorkflow,
            overrideBehavior: overrideBehavior
        )
        
        check("ax_content_evidence_probed", res2.evidenceQuality == "ax_content")
        check("ax_content_study_intent_quiz", res2.intent == "generate_quiz")
        
        // Test case C: studying page with selection -> selection -> explain_topic
        let snap3 = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Firefox",
            windowTitle: "Week-2 - CISC 121",
            bundleIdentifier: "org.mozilla.firefox",
            selectedText: "Computational thinking",
            recentOCRExcerpt: nil
        )
        
        let res3 = await ManualInvokeJarvis.runPipeline(
            source: "test_selection",
            synthesizedSnapshot: snap3,
            hasBrowserContext: false,
            browserTabTitles: [],
            selectedBrowserTabTitle: nil,
            producer: producer,
            coordinator: coordinator,
            behavioral: behavioral,
            overrideWorkflow: overrideWorkflow,
            overrideBehavior: overrideBehavior
        )
        
        check("selection_evidence_probed", res3.evidenceQuality == "selection")
        // CapabilitySelector returns "explain_context" for studying+selection (CapabilityRegistrySelfTest).
        check("selection_study_intent_explain", res3.intent == "explain_context")
        
        let ok = failures.isEmpty
        print("[ManualInvokeJarvisSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
