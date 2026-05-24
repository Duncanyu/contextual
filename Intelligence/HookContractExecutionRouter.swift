// HookContractExecutionRouter.swift
//
// Deterministic execution router for hook-chain contracts.
// Inspects hook metadata + contract structure to decide whether and how to execute.
// No LLM, no heuristic gates, no hardcoded domain logic.
//
// Current runtime support:
//   one_shot           → execute
//   observe_once       → execute (sandbox handles bounded capture)
//   interactive_loop   → unsupported_for_runtime (future agentic layer)
//   external_control   → unsupported_for_runtime (future computer control layer)
//   confirmation_req.  → unsupported_for_runtime (confirmation UI not yet wired)

import Foundation

// MARK: - Routing Decision

enum HookContractRoutingDecision: Sendable {
    /// Contract is safe to execute now. Chain and inferred mode are provided.
    case execute(chain: [String], mode: HookExecutionMode)

    /// Contract requires explicit user confirmation before execution can proceed.
    /// The confirmation gate is not yet wired at runtime — treat as unsupported for now.
    case requiresConfirmation(chain: [String], mode: HookExecutionMode)

    /// The runtime does not yet support this execution mode.
    /// Callers should surface a structured failure card rather than executing.
    case unsupportedForRuntime(mode: HookExecutionMode, reason: String)
}

// MARK: - Audit result (returned from auditResults; used by self-test for consistency checks)

struct ExecutionModeAuditResult: Sendable, Equatable {
    let oneShot: Int
    let observeOnce: Int
    let interactiveLoop: Int
    let externalControl: Int
    let confirmationRequired: Int
    var total: Int { oneShot + observeOnce + interactiveLoop + externalControl + confirmationRequired }
}

// MARK: - Router

/// Deterministic, metadata-driven execution router.
/// No AI decision layer. Pure contract + registry inspection.
enum HookContractExecutionRouter {

    // MARK: Route

    /// Route a contract to an execution decision.
    /// - Parameter logging: Pass `false` to suppress per-hook and contract-level logs
    ///   (used during exhaustive self-tests to keep output readable).
    static func route(
        contract: DynamicGeneratedActionContract,
        registry: HookCapabilityRegistry = .shared,
        logging: Bool = true
    ) -> HookContractRoutingDecision {
        let modeResult = ContractExecutionModeInferrer.infer(
            hookPlanIds: contract.hookPlanIds,
            registry: registry
        )
        let mode = modeResult.inferredMode

        if logging {
            // Per-hook classification log (for audit/debug)
            for hookId in contract.hookPlanIds {
                let hookMode = modeResult.hookModes[hookId] ?? .one_shot
                print("[HookExecutionClassification] hook=\(hookId) mode=\(hookMode.rawValue)")
            }
            // Contract-level inference log
            print("[ExecutionMode] inferred=\(mode.rawValue)")
            print("[ExecutionMode] requires_confirmation=\(modeResult.requiresConfirmation ? "yes" : "no")")
            print("[ExecutionMode] external_control=\(modeResult.containsExternalControl ? "yes" : "no")")
            print("[ExecutionMode] loop=\(modeResult.containsLoopingBehavior ? "yes" : "no")")
        }

        // Route based on mode support
        guard mode.isRuntimeSupported else {
            let reason: String
            switch mode {
            case .interactive_loop:      reason = "agentic_loop_not_yet_implemented"
            case .external_control:      reason = "external_app_control_not_yet_implemented"
            case .confirmation_required: reason = "confirmation_gate_not_yet_wired"
            default:                     reason = "unsupported_mode:\(mode.rawValue)"
            }
            if logging {
                print("[ExecutionMode] routing=unsupported_for_runtime reason=\(reason) chain=[\(contract.hookPlanIds.joined(separator: ","))]")
            }
            return .unsupportedForRuntime(mode: mode, reason: reason)
        }

        if modeResult.requiresConfirmation {
            if logging {
                print("[ExecutionMode] routing=requires_confirmation chain=[\(contract.hookPlanIds.joined(separator: ","))]")
            }
            return .requiresConfirmation(chain: contract.hookPlanIds, mode: mode)
        }

        if logging {
            print("[ExecutionMode] routing=execute mode=\(mode.rawValue) chain=[\(contract.hookPlanIds.joined(separator: ","))]")
        }
        return .execute(chain: contract.hookPlanIds, mode: mode)
    }

    // MARK: Audit

    /// Returns the execution-mode distribution across all registry hooks.
    /// Pure — no printing. Used by auditStartup() and self-tests.
    static func auditResults(registry: HookCapabilityRegistry = .shared) -> ExecutionModeAuditResult {
        var counts: [HookExecutionMode: Int] = [:]
        for def in registry.all {
            counts[def.executionMode, default: 0] += 1
        }
        return ExecutionModeAuditResult(
            oneShot:              counts[.one_shot,              default: 0],
            observeOnce:          counts[.observe_once,          default: 0],
            interactiveLoop:      counts[.interactive_loop,      default: 0],
            externalControl:      counts[.external_control,      default: 0],
            confirmationRequired: counts[.confirmation_required, default: 0]
        )
    }

    /// Emits [ExecutionModeAudit] summary across all hooks in the registry.
    /// Call once at app startup (after registry init) to verify classifications.
    static func auditStartup(registry: HookCapabilityRegistry = .shared) {
        let r = auditResults(registry: registry)
        print("[ExecutionModeAudit] one_shot=\(r.oneShot) observe_once=\(r.observeOnce) interactive_loop=\(r.interactiveLoop) external_control=\(r.externalControl) confirmation_required=\(r.confirmationRequired)")
    }
}

// MARK: - Observe Once Executor

/// Bounded context capture coordinator for observe_once execution mode.
/// Safe, privacy-preserving, and non-agentic.
enum ObserveOnceExecutor {
    
    /// Performs one bounded observation (AX window content and/or screen OCR)
    /// and merges the results into the snapshot if not already present.
    static func executePreObservation(
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        scheduler: VisualContextScheduler,
        budgetSnapshot: GeneratedExecutionBudgetSnapshot
    ) async -> (snapshot: CanonicalGeneratedExecutionContextSnapshot, observationCount: Int) {
        
        let hasOCR = !(snapshot.recentOCRExcerpt ?? "").isEmpty
        let hasAX = snapshot.contextSummary?.contains("ax=") == true
        if hasOCR || hasAX {
            print("[ObserveOnceExecution] skipped reason=already_observed")
            return (snapshot, 0)
        }
        
        print("[ObserveOnceExecution] started")
        
        // 1. AX window read
        let axContent = AXWindowContentSource.shared.extractActiveWindowContent()
        let axText = axContent?.visibleTextFragments.joined(separator: "\n") ?? ""
        
        // 2. Bounded OCR read
        let req = BoundedVisualContextRequest(
            reason: "observe_once_execution",
            workflowType: .debugging,
            intentType: .synthesize,
            requiresOCR: true,
            requiresVisualDescription: false,
            maxWindowSeconds: 5,
            maxOCRCharacters: 2000,
            maxDescriptionCharacters: 0,
            budget: ExecutionBudget(allowsVision: false, allowsOCR: true),
            permissionAvailability: snapshot.permissionAvailability
        )
        let visualResult = await scheduler.collect(request: req, budgetSnapshot: budgetSnapshot)
        
        var enrichedSnapshot = snapshot
        if let axContent = axContent {
            enrichedSnapshot = enrichedSnapshot.merging(axWindowTextExcerpt: axText)
        }
        if visualResult.status == .completed || visualResult.status == .partial {
            enrichedSnapshot = enrichedSnapshot.merging(visualResult: visualResult)
        }
        
        let axChars = axText.count
        let ocrChars = visualResult.ocrExcerpt?.count ?? 0
        
        print("[ObserveOnceExecution] observation_count=1")
        print("[ObserveOnceExecution] injected_snapshot ocr_chars=\(ocrChars) ax_chars=\(axChars)")
        
        return (enrichedSnapshot, 1)
    }
}
