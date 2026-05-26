// HookExecutionMode.swift
//
// Execution-mode taxonomy for the hook runtime.
// Purely metadata-driven — no LLM, no heuristic gates, no hardcoded app/domain logic.
// Contracts inherit the highest-priority mode from their hook chain.

import Foundation

// MARK: - Taxonomy

/// Deterministic execution mode for a hook or an entire hook-chain contract.
/// Computed from hook metadata (category + id + safety); never decided by a model.
enum HookExecutionMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Bounded, sequential execution entirely from existing context snapshot.
    /// No loops, no external control, no new captures.
    case one_shot

    /// May acquire additional context once (bounded OCR / visual capture) then executes.
    /// Stops after one capture pass — never re-observes.
    case observe_once

    /// Iterative observe → act → reobserve loop.
    /// Not yet implemented in the runtime sandbox.
    case interactive_loop

    /// Manipulates external applications, browser UI, or system controls.
    /// Requires accessibility or UI-automation permissions.
    /// Not yet enabled at runtime.
    case external_control

    /// Risky action that is user-impactful (send, delete, purchase, publish, quit).
    /// Requires explicit user confirmation before proceeding.
    /// Confirmation gate not yet wired at runtime.
    case confirmation_required

    // MARK: Runtime support

    /// Whether the current runtime sandbox supports execution of this mode.
    /// `one_shot` and `observe_once` are fully supported.
    /// All others are future-flagged and blocked at the router.
    var isRuntimeSupported: Bool {
        switch self {
        case .one_shot, .observe_once: return true
        case .interactive_loop, .external_control, .confirmation_required: return false
        }
    }

    // MARK: UI labels

    /// Short chip label shown in the proposal card.
    var userFacingLabel: String {
        switch self {
        case .one_shot:             return "One-shot"
        case .observe_once:         return "Observe once"
        case .interactive_loop:     return "Agentic"
        case .external_control:     return "External control"
        case .confirmation_required: return "Needs confirmation"
        }
    }

    /// One-line description of what the mode means for the user.
    var userFacingDescription: String {
        switch self {
        case .one_shot:             return "Executable now"
        case .observe_once:         return "Reads current window once before answering."
        case .interactive_loop:     return "Multi-step adaptive execution"
        case .external_control:     return "Controls apps or browser"
        case .confirmation_required: return "Risky action — requires your approval"
        }
    }

    // MARK: Priority (for contract-level inference)

    /// Restriction priority used during chain-level inference.
    /// A contract's effective mode = the highest-priority mode among its hooks.
    var priority: Int {
        switch self {
        case .one_shot:              return 0
        case .observe_once:          return 1
        case .confirmation_required: return 2
        case .interactive_loop:      return 3
        case .external_control:      return 4
        }
    }
}

// MARK: - Contract Execution Mode Result

/// Complete execution-mode classification of a hook-chain contract.
struct ContractExecutionModeResult: Sendable, Equatable {
    /// The dominant (highest-priority) execution mode in the hook chain.
    let inferredMode: HookExecutionMode
    /// True when any hook in the chain carries a confirmation requirement.
    let requiresConfirmation: Bool
    /// True when any hook in the chain is external_control.
    let containsExternalControl: Bool
    /// True when any hook in the chain is interactive_loop.
    let containsLoopingBehavior: Bool
    /// Per-hook modes, keyed by hook ID. For audit/debug only.
    let hookModes: [String: HookExecutionMode]

    static let oneShotDefault = ContractExecutionModeResult(
        inferredMode: .one_shot,
        requiresConfirmation: false,
        containsExternalControl: false,
        containsLoopingBehavior: false,
        hookModes: [:]
    )
}

// MARK: - Inferrer (pure — no logging side effects)

/// Deterministically infers the execution mode of a hook chain from hook metadata.
/// Pure function — no logging, no LLM, no network calls.
/// Logging is the caller's responsibility (see HookContractExecutionRouter).
enum ContractExecutionModeInferrer {
    static func infer(
        hookPlanIds: [String],
        registry: HookCapabilityRegistry = .shared
    ) -> ContractExecutionModeResult {
        guard !hookPlanIds.isEmpty else { return .oneShotDefault }

        var dominantMode: HookExecutionMode = .one_shot
        var requiresConfirmation = false
        var containsExternalControl = false
        var containsLoopingBehavior = false
        var hookModes: [String: HookExecutionMode] = [:]

        for id in hookPlanIds {
            let mode: HookExecutionMode
            if let def = registry.definition(for: id) {
                mode = def.executionMode
                if def.safety == .confirmation_required { requiresConfirmation = true }
            } else {
                // Unknown hook — conservative default unless it is a known observe_once hook
                if id == "run_ocr_once" || id == "gather_visible_context_once" {
                    mode = .observe_once
                } else {
                    mode = .one_shot
                }
            }
            hookModes[id] = mode

            if mode == .external_control    { containsExternalControl = true }
            if mode == .interactive_loop    { containsLoopingBehavior = true }
            if mode == .confirmation_required { requiresConfirmation = true }
            if mode.priority > dominantMode.priority { dominantMode = mode }
        }

        return ContractExecutionModeResult(
            inferredMode: dominantMode,
            requiresConfirmation: requiresConfirmation,
            containsExternalControl: containsExternalControl,
            containsLoopingBehavior: containsLoopingBehavior,
            hookModes: hookModes
        )
    }
}

// MARK: - HookCapabilityDefinition execution mode

extension HookCapabilityDefinition {
    /// Deterministically computed execution mode — no LLM required.
    /// Derived from hook id, category, and safety metadata.
    var executionMode: HookExecutionMode {
        // --- ID-based overrides (hooks that differ from their category default) ---

        // Active context acquisition: triggers bounded OCR / visual capture
        if id == "run_ocr_once" || id == "gather_visible_context_once" {
            return .observe_once
        }

        // Browser manipulation (non-passive): opens/navigates/fills UI elements
        let browserControlIds: Set<String> = [
            "open_new_tab", "switch_tab", "close_tab",
            "search_in_current_tab", "navigate_to_url", "fill_web_field"
        ]
        if browserControlIds.contains(id) { return .external_control }

        // Form submission — external control AND risky
        if id == "submit_form" { return .confirmation_required }

        // Quitting an app is irreversible without re-launch
        if id == "quit_app" { return .confirmation_required }

        // Parallel sub-task orchestration → iterative loop semantics
        if id == "run_subtasks_parallel" { return .interactive_loop }

        // --- Category defaults (evaluated before safety for app_control/dangerous) ---
        // external_control (priority 4) outranks confirmation_required (priority 2).
        // The contract inferrer's requiresConfirmation flag already captures safety
        // separately — the hook-level executionMode reflects the execution mechanic.
        switch category {
        case .app_control:  return .external_control   // all app_control hooks manipulate system/apps
        case .dangerous:    return .external_control   // dangerous hooks always require external control
        default: break
        }

        // --- Safety metadata override (non-app_control, non-dangerous categories only) ---
        if safety == .confirmation_required { return .confirmation_required }

        return .one_shot   // sensing, extraction, reasoning, llm, web, presentation, etc.
    }
}

// MARK: - Agentic Task Plan

/// A typed foundation for agentic execution.
/// This models a multi-step task that involves observation and action.
struct AgenticTaskPlan: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let goal: String
    let workflow: String
    let sourceProposalId: String?
    
    let allowedActionFamilies: [AgenticActionFamily]
    let requiredObservations: [String]
    let successCriteria: [String]
    let stopConditions: [AgenticStopCondition]
    
    // Limits / Budgets
    let maxSteps: Int
    let maxLLMCalls: Int
    let maxOCRCalls: Int
    let maxRuntimeSeconds: Int
    
    let requiresPermission: Bool
    let safetyLevel: AgenticSafetyLevel
    let createdAt: Date
}

// MARK: - Action Families

/// High-level categories of actions an agent can perform.
enum AgenticActionFamily: String, Codable, Sendable, CaseIterable {
    case observe
    case read_screen
    case find_on_page
    case scroll
    case click
    case type
    case switch_tab
    case navigate
    case extract
    case summarize
    case present
    case stop
}

// MARK: - Safety Levels

enum AgenticSafetyLevel: String, Codable, Sendable, CaseIterable {
    case preview_only
    case confirmation_required
    case yolo_allowed_future
}

// MARK: - Stop Conditions

enum AgenticStopCondition: String, Codable, Sendable, CaseIterable {
    case success_criteria_met
    case max_steps_reached
    case missing_required_permission
    case unsafe_action_required
    case stuck_no_progress
    case user_cancelled
    // Phase 4O — evidence-aware stop conditions
    /// All required evidence requirements were satisfied; loop ended cleanly.
    case evidence_satisfied
    /// Budget exhausted but at least one required evidence slot was not satisfied.
    case partial_evidence_budget_exhausted
    /// No remaining legal action could make progress on missing evidence.
    case no_more_safe_actions
}

// MARK: - Eligibility

/// Classification for whether a proposal is a candidate for agentic runtime.
enum AgenticRuntimeEligibility: String, Codable, Sendable, CaseIterable {
    /// Standard sequential hook execution (no looping, no external control).
    case fixed_hook_chain
    /// Single pass observation (OCR/Visual) then execution.
    case observe_once_chain
    /// Candidate for full agentic execution (interactive loop / multi-step).
    case agentic_runtime_candidate
}

extension AgenticRuntimeEligibility {
    var userFacingLabel: String {
        switch self {
        case .fixed_hook_chain: return "One-shot"
        case .observe_once_chain: return "Observe & Act"
        case .agentic_runtime_candidate: return "Agentic preview"
        }
    }
    
    var userFacingDescription: String {
        switch self {
        case .fixed_hook_chain: return "Executable now"
        case .observe_once_chain: return "Reads current window once before answering."
        case .agentic_runtime_candidate: return "Needs controlled execution"
        }
    }
}
