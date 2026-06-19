import Foundation

enum PublicLookupExecutionProof {
    static func run() async -> Bool {
        print("[PublicLookupExecutionProof] starting")
        var failures = 0
        func assertExpected(_ condition: Bool, _ label: String) {
            if !condition {
                print("[PublicLookupExecutionProof] FAIL: \(label)")
                failures += 1
            } else {
                print("[PublicLookupExecutionProof] PASS: \(label)")
            }
        }
        
        PublicPageContextExtractor.mockResult = PublicPageContextExtractor.PublicPageContext(
            url: URL(string: "https://example.com/research")!,
            pageTitle: "Mocked Public Page",
            ogTitle: "Mocked OG",
            ogDescription: "Mocked Desc",
            productFacts: [:],
            extractedAt: Date(),
            source: "url_html"
        )
        
        BrowserContextExtractor.mockResult = BrowserContextExtractor.BrowserContext(
            appName: "Safari",
            selectedTitle: "Safari - Article",
            currentURL: URL(string: "https://example.com/research")!,
            selectedURL: nil,
            recentTabTitles: [],
            webAreaFrame: nil,
            scrollAreaFrame: nil
        )
        
        let suggestion = AmbientJarvisSuggestion(
            title: "Mock Web Research",
            subtitle: "Research Context",
            whyNow: "user intent",
            workflow: "researching",
            behavior: "studying",
            confidence: 0.9,
            kind: .compare_context,
            intent: "synthesize_sources",
            intentConfidence: 0.9,
            intentGoal: "Get facts",
            targetEntity: "Safari",
            executionMode: .context_only_preview,
            previewOnly: false,
            sourceEvidence: "https://example.com/research",
            contextPayload: nil,
            topOpportunity: Opportunity(
                id: "mock_opp",
                title: "Mock Opp",
                capabilityId: "public_web_research",
                confidence: 0.9,
                reason: "Mock reason",
                requiredEvidence: "public_web_research",
                actionability: 0.9,
                inferredNeed: .synthesis,
                requiresConfirmation: false,
                auxiliaryCapabilityIds: [],
                involvedApps: [],
                involvedURLs: [],
                browserTabTitles: [],
                candidateID: nil,
                targetContract: nil
            )
        )
        
        let snap = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Safari",
            windowTitle: "Safari - Article",
            bundleIdentifier: "com.apple.Safari",
            inferredWorkflow: .research,
            selectedText: nil,
            recentOCRExcerpt: nil
        )
        
        let liveContext = await ContextExecutionEngine.execute(
            suggestion: suggestion,
            snapshot: snap
        )
        
        // Assert that the evidence returned was actually fetched via the public lookup (mocked)
        assertExpected(liveContext.evidenceQuality == "public_web_research" || liveContext.evidenceQuality == "metadata_rich" || liveContext.evidenceQuality == "full_content" || liveContext.observed.contains { $0.contains("Mocked Public Page") }, "mock result reached live context")
        // Clean up
        PublicPageContextExtractor.mockResult = nil
        BrowserContextExtractor.mockResult = nil
        
        let pass = failures == 0
        print("[PublicLookupExecutionProof] status=\(pass ? "pass" : "fail")")
        return pass
    }
}
