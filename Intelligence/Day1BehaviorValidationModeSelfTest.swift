import Foundation

public struct Day1BehaviorValidationModeSelfTest: Sendable {
    
    public static func run() async -> Bool {
        print("[Day1BehaviorValidationModeSelfTest] starting")
        var failures: [String] = []
        
        let now = Date()
        
        // Save original userdefaults state
        let hadOriginalValue = UserDefaults.standard.object(forKey: "contextual.day1BehaviorValidationMode") != nil
        let originalValue = UserDefaults.standard.bool(forKey: "contextual.day1BehaviorValidationMode")
        
        // 1. Check userdefaults enabled
        UserDefaults.standard.set(true, forKey: "contextual.day1BehaviorValidationMode")
        
        if Day1BehaviorValidationMode.isEnabled && Day1BehaviorValidationMode.source == "userdefaults" {
            print("[Day1BehaviorValidationModeSelfTest] pass case=userdefaults_enabled")
        } else {
            print("[Day1BehaviorValidationModeSelfTest] fail case=userdefaults_enabled")
            failures.append("userdefaults_enabled")
        }
        
        // 2. Test proposal generation returns quiet when day 1 validation is active
        let snapshot = CanonicalGeneratedExecutionContextSnapshot(
            activeApp: "Firefox",
            windowTitle: "Amazon.com: buy items",
            bundleIdentifier: "org.mozilla.firefox",
            inferredWorkflow: .browsing,
            selectedText: nil,
            clipboardText: nil,
            recentOCRExcerpt: nil,
            contextSummary: "Browsing keyboard reviews",
            workflowConfidence: 0.85,
            availableContextTypes: [.workflowContext],
            permissionAvailability: [.screenRecording: false],
            generatedAt: now,
            freshnessScore: 0.90
        )
        
        let engine = DynamicGeneratedProposalEngine.shared
        let result = await engine.generateProposals(
            snapshot: snapshot,
            existingStaticActions: [],
            reusableActions: [],
            referenceTime: now
        )
        
        if result.status == DynamicGeneratedProposalSynthesisStatus.quietByGate {
            print("[Day1BehaviorValidationModeSelfTest] pass case=proposal_pipeline_disabled")
        } else {
            print("[Day1BehaviorValidationModeSelfTest] fail case=proposal_pipeline_disabled got=\(result.status)")
            failures.append("proposal_pipeline_disabled")
        }
        
        // 3. Test hook composer blocked
        let inference = TaskInferenceResult(
            shouldChime: true,
            possibleUserGoal: "compare products",
            confidence: 0.74,
            neededCapabilityCategories: ["extract", "compare", "output"],
            whyNow: "tab switching",
            missingContext: [],
            expirySeconds: 18,
            createdAt: now,
            need: [],
            needReason: nil
        )
        let situational = SituationalContextSynthesizer.synthesize(from: snapshot, referenceTime: now)
        
        let planningOutput = await TaskInferencePlanningPipeline.compose(
            inference: inference,
            snapshot: snapshot,
            situational: situational,
            recentTitles: []
        )
        
        if planningOutput == nil {
            print("[Day1ValidationModeSelfTest] pass case=hook_composer_blocked")
        } else {
            print("[Day1ValidationModeSelfTest] fail case=hook_composer_blocked")
            failures.append("hook_composer_blocked")
        }
        
        // 4. Test agentic plan blocked
        let contract = DynamicGeneratedActionContract(
            id: "agentic:test_contract",
            title: "Compare prices",
            userFacingQuestion: "Should I compare?",
            inferredUserGoal: "Compare products",
            situationSummary: "comparing",
            whyNow: "comparison page",
            hookPlanIds: ["observe_current_context", "present_result"],
            requiredContext: [.textSnippet],
            confidence: 0.85,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            cacheEligibility: true,
            cacheKey: "test"
        )
        
        let plan = AgenticRuntimeBridge.derivePlan(from: contract, workflow: "shopping")
        if plan == nil {
            print("[Day1ValidationModeSelfTest] pass case=agentic_blocked")
        } else {
            print("[Day1ValidationModeSelfTest] fail case=agentic_blocked")
            failures.append("agentic_blocked")
        }
        
        // 5. Test startup status logging
        Day1BehaviorValidationMode.logStatus()
        
        // Restore original userdefaults state
        if hadOriginalValue {
            UserDefaults.standard.set(originalValue, forKey: "contextual.day1BehaviorValidationMode")
        } else {
            UserDefaults.standard.removeObject(forKey: "contextual.day1BehaviorValidationMode")
        }
        
        let ok = failures.isEmpty
        print("[Day1ValidationModeSelfTest] completed ok=\(ok)")
        return ok
    }
}
