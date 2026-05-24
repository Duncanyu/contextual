import Foundation

/// Fast deterministic dynamic action contract (no live large-model proposal generation).
///
/// This is produced by a composer (typically model-driven task inference + hook mapping) and then
/// converted into a `ValidatedDynamicGeneratedProposal` for the existing proposal activation pipeline.
struct DynamicGeneratedActionContract: Sendable, Equatable {
	let id: String
	let title: String
	let userFacingQuestion: String
	let inferredUserGoal: String
	let situationSummary: String
	let whyNow: String
	let hookPlanIds: [String]
	let requiredContext: [ContextRequirementType]
	let confidence: Double
	let createdAt: Date
	let expiresAt: Date
	let cacheEligibility: Bool
	let cacheKey: String
}

struct HookComposedProposal: Sendable, Equatable {
	let contract: DynamicGeneratedActionContract
	let proposal: ValidatedDynamicGeneratedProposal
}

// MARK: - Execution mode (computed, no stored state)

extension DynamicGeneratedActionContract {
	/// Full execution-mode classification inferred from the hook chain.
	/// Pure and deterministic — no LLM, no logging.
	var executionModeResult: ContractExecutionModeResult {
		ContractExecutionModeInferrer.infer(hookPlanIds: hookPlanIds)
	}
	var executionMode: HookExecutionMode { executionModeResult.inferredMode }
	var requiresConfirmation: Bool { executionModeResult.requiresConfirmation }
	var containsExternalControl: Bool { executionModeResult.containsExternalControl }
	var containsLoopingBehavior: Bool { executionModeResult.containsLoopingBehavior }
}


/// A deterministic bridge that decides whether a selected planner candidate should be treated as agentic.
struct AgenticRuntimeBridge {
    
    // MARK: - Classification
    
    /// Classifies a contract into its agentic eligibility level.
    static func classify(contract: DynamicGeneratedActionContract) -> AgenticRuntimeEligibility {
        // 1. Check existing execution mode
        if contract.executionModeResult.executionMode == .interactive_loop || 
           contract.executionModeResult.executionMode == .external_control {
            return .agentic_runtime_candidate
        }
        
        // 2. Check for agentic-family hook IDs
        let agenticHookIds: Set<String> = [
            "scroll_view", "click_screen_coordinate", "click_ui_element_by_id",
            "type_text", "open_new_tab", "switch_tab", "navigate_to_url",
            "open_app", "focus_app", "press_shortcut"
        ]
        
        for hookId in contract.hookPlanIds {
            if agenticHookIds.contains(hookId) {
                return .agentic_runtime_candidate
            }
        }
        
        // 3. Check goal for implied agentic behavior (e.g. "scroll", "reviews not visible")
        let goal = contract.goal.lowercased()
        if goal.contains("scroll") || goal.contains("find") || goal.contains("click") || goal.contains("navigate") {
            return .agentic_runtime_candidate
        }
        
        // 4. Check for multi-step comparison/search across sources
        if goal.contains("compare") && (goal.contains("sources") || goal.contains("sites") || goal.contains("pages")) {
            return .agentic_runtime_candidate
        }
        
        // 5. Default based on HookExecutionMode
        if contract.executionModeResult.executionMode == .observe_once {
            return .observe_once_chain
        }
        
        return .fixed_hook_chain
    }
    
    // MARK: - Plan Derivation
    
    /// Derives an AgenticTaskPlan from a contract if it is eligible.
    static func derivePlan(from contract: DynamicGeneratedActionContract, workflow: String) -> AgenticTaskPlan? {
        let eligibility = classify(contract: contract)
        
        print("[AgenticPlan] eligibility=\(eligibility == .agentic_runtime_candidate ? "yes" : "no") reason=\(eligibility.rawValue)")
        
        guard eligibility == .agentic_runtime_candidate else {
            return nil
        }
        
        let families = mapActionFamilies(from: contract.hookPlanIds)
        
        let plan = AgenticTaskPlan(
            id: UUID().uuidString,
            goal: contract.goal,
            workflow: workflow,
            sourceProposalId: contract.id,
            allowedActionFamilies: families,
            requiredObservations: contract.requiredContext.map { $0.rawValue },
            successCriteria: [contract.expectedOutcome],
            stopConditions: [.success_criteria_met, .max_steps_reached, .user_cancelled],
            maxSteps: 5,
            maxLLMCalls: 5,
            maxOCRCalls: 2,
            maxRuntimeSeconds: 15,
            requiresPermission: contract.requiresConfirmation,
            safetyLevel: .preview_only,
            createdAt: Date()
        )
        
        print("[AgenticPlan] created id=\(plan.id) goal=\(plan.goal) workflow=\(plan.workflow)")
        print("[AgenticPlan] allowed_families=\(plan.allowedActionFamilies.map(\.rawValue))")
        print("[AgenticPlan] limits steps=\(plan.maxSteps) llm_calls=\(plan.maxLLMCalls) ocr_calls=\(plan.maxOCRCalls) runtime_s=\(plan.maxRuntimeSeconds)")
        print("[AgenticPlan] preview_only=true")
        print("[AgenticPlan] blocked_execution reason=not_implemented_yet")
        
        return plan
    }
    
    // MARK: - Mapping Helpers
    
    private static func mapActionFamilies(from hookIds: [String]) -> [AgenticActionFamily] {
        var families: Set<AgenticActionFamily> = [.observe, .stop]
        
        for id in hookIds {
            if id.contains("scroll") { families.insert(.scroll) }
            if id.contains("click") { families.insert(.click) }
            if id.contains("type") { families.insert(.type) }
            if id.contains("navigate") { families.insert(.navigate) }
            if id.contains("tab") { families.insert(.switch_tab) }
            if id.contains("ocr") || id.contains("read") { families.insert(.read_screen) }
            if id.contains("extract") { families.insert(.extract) }
            if id.contains("summarize") { families.insert(.summarize) }
            if id.contains("present") { families.insert(.present) }
        }
        
        return Array(families).sorted(by: { $0.rawValue < $1.rawValue })
    }
}
