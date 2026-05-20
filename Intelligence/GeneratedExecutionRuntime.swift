import Foundation

/// Bounded lifecycle coordinator for generated execution (T17.3 — deterministic primitives).
///
/// Stability (T17.10):
/// - Actor-isolated; does not mutate `AppState` or publish UI state.
/// - `visualContextScheduler` and `persistenceManager` default to `nil` (opt-in injection only).
/// - Do not invoke from SwiftUI `body`, `onAppear`, or panel lifecycle hooks.
/// - Ranking and UI consume snapshots/results; runtime does not own ranking.
actor GeneratedExecutionRuntime {

	private let configuration: GeneratedExecutionRuntimeConfiguration
	private let contextProvider: any GeneratedExecutionContextProvider
	private let primitiveRunner: ExecutionPrimitiveRunner
	private let budgetManager: GeneratedExecutionBudgetManager
	private let workflowPlanner: WorkflowExecutionPlanner
	private let persistenceManager: GeneratedActionPersistenceManager?
	/// Optional bounded visual scheduler (default nil — no visual collection in T17.8).
	private let visualContextScheduler: VisualContextScheduler?
	/// True when context is supplied via T18.1 canonical snapshot bridge (opt-in only).
	private let usesBridgedContext: Bool
	/// Explicit canonical snapshot for sparse visual peek policy (never read from shared app state).
	private let canonicalSnapshot: CanonicalGeneratedExecutionContextSnapshot?
	private let sparseVisualPeekGate: SparseVisualPeekGate
	/// At most one sparse visual peek attempt per execution lifecycle (T18.2).
	private var sparseVisualPeekAttemptedInLifecycle = false
	private var visualEnrichmentPerformedInLifecycle = false
	private var visualEnrichmentUsedOCRInLifecycle = false
	private var visualEnrichmentUsedVisionSummaryInLifecycle = false
	private var visualEnrichmentDecisionInLifecycle: String = "none"

	private(set) var snapshot: GeneratedExecutionRuntimeSnapshot = .initial
	private var cancelRequested = false

	init(
		configuration: GeneratedExecutionRuntimeConfiguration = .production,
		contextProvider: any GeneratedExecutionContextProvider = StaticGeneratedExecutionContextProvider(packet: nil),
		primitiveRunner: ExecutionPrimitiveRunner = ExecutionPrimitiveRunner(),
		budgetManager: GeneratedExecutionBudgetManager = GeneratedExecutionBudgetManager(),
		workflowPlanner: WorkflowExecutionPlanner = WorkflowExecutionPlanner(),
		persistenceManager: GeneratedActionPersistenceManager? = nil,
		visualContextScheduler: VisualContextScheduler? = nil,
		canonicalSnapshot: CanonicalGeneratedExecutionContextSnapshot? = nil,
		contextBridge: GeneratedExecutionContextBridge = GeneratedExecutionContextBridge(),
		optionalBridgedVisualResult: BoundedVisualContextResult? = nil,
		sparseVisualPeekGate: SparseVisualPeekGate = SparseVisualPeekGate()
	) {
		self.configuration = configuration
		self.canonicalSnapshot = canonicalSnapshot
		self.sparseVisualPeekGate = sparseVisualPeekGate
		if let canonicalSnapshot {
			self.contextProvider = BridgedGeneratedExecutionContextProvider(
				snapshot: canonicalSnapshot,
				bridge: contextBridge,
				optionalVisualResult: optionalBridgedVisualResult
			)
			self.usesBridgedContext = true
		} else {
			self.contextProvider = contextProvider
			self.usesBridgedContext = false
		}
		self.primitiveRunner = primitiveRunner
		self.budgetManager = budgetManager
		self.workflowPlanner = workflowPlanner
		self.persistenceManager = persistenceManager
		self.visualContextScheduler = visualContextScheduler
	}

	// MARK: - Public API

	func currentSnapshot() -> GeneratedExecutionRuntimeSnapshot {
		snapshot
	}

	/// Stability probe for tests (default production init: both false).
	func phase17StabilityProbe() -> (hasVisualScheduler: Bool, hasPersistenceManager: Bool) {
		(visualContextScheduler != nil, persistenceManager != nil)
	}

	/// T18.1 probe: bridged context is opt-in only (default false).
	func phase18BridgeProbe() -> Bool {
		usesBridgedContext
	}

	/// T18.2 probe: sparse peek requires scheduler + canonical snapshot injection.
	func phase18SparseVisualPeekProbe() -> (
		hasScheduler: Bool,
		hasCanonicalSnapshot: Bool,
		attemptedPeek: Bool
	) {
		(
			visualContextScheduler != nil,
			canonicalSnapshot != nil,
			sparseVisualPeekAttemptedInLifecycle
		)
	}

	func start(action: GeneratedExecutionAction) async -> GeneratedExecutionStartOutcome {
		if isExecutionActive {
			log(event: "start_rejected", reason: GeneratedExecutionRuntimeError.alreadyRunning.rawValue, actionId: action.id)
			return .rejected(.alreadyRunning)
		}

		if let validationError = validate(action) {
			applyTerminalFailure(error: validationError, actionId: action.id)
			log(event: "start_rejected", reason: validationError.rawValue, actionId: action.id)
			return .rejected(validationError)
		}

		let startBudget = await budgetManager.canStartExecution(
			action: action,
			contextSnapshot: makeBudgetSnapshot(activeSamplingRequested: false)
		)
			if !startBudget.allowed {
				await budgetManager.recordExecutionRejected(action: action, reason: startBudget.reason)
				let meta = startBudget.metadata
					.prefix(6)
					.map { "\($0.key)=\($0.value)" }
					.joined(separator: ",")
				let metaPart = meta.isEmpty ? "" : " meta=\(meta)"
				print("[GeneratedExecutionBudget] denied gate=start reason=\(startBudget.reason.rawValue) actionId=\(action.id.uuidString.prefix(8))\(metaPart)")
				log(event: "start_rejected", reason: startBudget.reason.rawValue, actionId: action.id)
				return .rejected(startBudget.runtimeError)
			}

		cancelRequested = false
		sparseVisualPeekAttemptedInLifecycle = false
		visualEnrichmentPerformedInLifecycle = false
		visualEnrichmentUsedOCRInLifecycle = false
		visualEnrichmentUsedVisionSummaryInLifecycle = false
		visualEnrichmentDecisionInLifecycle = "none"
		let startedAt = Date()
		transition(
			to: .validating,
			actionId: action.id,
			startedAt: startedAt,
			failureReason: nil,
			warningCodes: []
		)
		log(event: "start_accepted", reason: nil, actionId: action.id)
		await budgetManager.recordExecutionStarted(action: action)
		await recordPersistenceReuseIfNeeded(action: action)

		let result = await runLifecycle(action: action, startedAt: startedAt)
		await budgetManager.recordExecutionCompleted(action: action, result: result)
		await recordPersistenceOutcome(action: action, result: result)
		return .completed(result)
	}

	@discardableResult
	func cancel() -> ExecutionResult? {
		guard isExecutionActive else {
			log(event: "cancel_ignored", reason: "not_active", actionId: snapshot.activeActionId)
			return nil
		}
		cancelRequested = true
		log(event: "cancel_requested", reason: nil, actionId: snapshot.activeActionId)
		return nil
	}

	func reset() {
		cancelRequested = false
		sparseVisualPeekAttemptedInLifecycle = false
		visualEnrichmentPerformedInLifecycle = false
		visualEnrichmentUsedOCRInLifecycle = false
		visualEnrichmentUsedVisionSummaryInLifecycle = false
		visualEnrichmentDecisionInLifecycle = "none"
		snapshot = .initial
		log(event: "reset", reason: nil, actionId: nil)
	}

	// MARK: - Lifecycle

	private var isExecutionActive: Bool {
		switch snapshot.currentState {
		case .validating, .gatheringContext, .executing, .synthesizingResult:
			true
		default:
			false
		}
	}

	private func validate(_ action: GeneratedExecutionAction) -> GeneratedExecutionRuntimeError? {
		if action.isExpired {
			return .executionUnavailable
		}

		let plan = action.executionPlan
		if plan.primitives.isEmpty || !plan.isWithinBounds {
			return .invalidPlan
		}

		let budget = plan.executionBudget
		if budget.maxConcurrentTasks != 1 {
			return .budgetExceeded
		}
		if budget.allowsBackgroundWork {
			return .budgetExceeded
		}
		if budget.maxExecutionTime < 5 {
			return .budgetExceeded
		}
		if plan.requiresVision && !budget.allowsVision {
			print("[VisualExecution] event=visual_execution_denied reason=vision_not_allowed_preflight actionId=\(action.id.uuidString.prefix(8))")
			return .budgetExceeded
		}
		if plan.requiresOCR && !budget.allowsOCR {
			print("[VisualExecution] event=visual_execution_denied reason=ocr_not_allowed_preflight actionId=\(action.id.uuidString.prefix(8))")
			return .budgetExceeded
		}
		if plan.estimatedRuntime > budget.maxExecutionTime {
			return .budgetExceeded
		}

		return nil
	}

	private func runLifecycle(action: GeneratedExecutionAction, startedAt: Date) async -> ExecutionResult {
		let budget = action.executionPlan.executionBudget
		let wallClockLimit = configuration.maxExecutionTimeOverride ?? budget.maxExecutionTime
		let deadline = startedAt.addingTimeInterval(wallClockLimit)

		if let abort = checkAbort(action: action, startedAt: startedAt, deadline: deadline) {
			return abort
		}

		let plan = action.executionPlan
		let samplingRequested = plan.requiresVision || plan.requiresOCR
		let gatherBudget = await budgetManager.canGatherContext(
			requirements: action.requiredContextTypes,
			budget: plan.executionBudget,
			snapshot: makeBudgetSnapshot(activeSamplingRequested: samplingRequested)
		)
			if !gatherBudget.allowed {
				let meta = gatherBudget.metadata
					.prefix(6)
					.map { "\($0.key)=\($0.value)" }
					.joined(separator: ",")
				let metaPart = meta.isEmpty ? "" : " meta=\(meta)"
				print("[GeneratedExecutionBudget] denied gate=gather reason=\(gatherBudget.reason.rawValue) actionId=\(action.id.uuidString.prefix(8))\(metaPart)")
				return finishBudgetDenied(
					action: action,
					startedAt: startedAt,
					decision: gatherBudget
			)
		}

		transition(
			to: .gatheringContext,
			actionId: action.id,
			startedAt: startedAt,
			failureReason: nil,
			warningCodes: []
		)

		let baseContext: GeneratedExecutionContext
		do {
			baseContext = try await contextProvider.gatherContext(for: action)
			log(event: "context_gathered", reason: baseContext.sourceType, actionId: action.id)
		} catch let error as GeneratedExecutionRuntimeError {
			return finishFailed(action: action, startedAt: startedAt, error: error)
		} catch {
			return finishFailed(action: action, startedAt: startedAt, error: .missingRequiredContext)
		}

		let context = await maybeEnrichWithSparseVisualPeek(
			action: action,
			baseContext: baseContext,
			plan: plan
		)

		if let abort = checkAbort(action: action, startedAt: startedAt, deadline: deadline) {
			return abort
		}

		let planning = applyWorkflowPlanning(action: action, context: context)
		let executionAction = planning.action

		transition(
			to: .executing,
			actionId: action.id,
			startedAt: startedAt,
			failureReason: nil,
			warningCodes: planning.planningWarnings
		)

		let primitiveRun = await executePrimitives(
			action: executionAction,
			context: context,
			startedAt: startedAt,
			deadline: deadline,
			extraWarnings: planning.planningWarnings
		)

		if let abort = primitiveRun.abortResult {
			return abort
		}

		if let abort = checkAbort(action: action, startedAt: startedAt, deadline: deadline) {
			return abort
		}

		transition(
			to: .synthesizingResult,
			actionId: action.id,
			startedAt: startedAt,
			failureReason: nil,
			warningCodes: primitiveRun.warnings
		)
		log(event: "result_synthesized", reason: primitiveRun.status.rawValue, actionId: action.id)

		var result = GeneratedExecutionResultSynthesizer.synthesize(
			action: executionAction,
			outputs: primitiveRun.outputs,
			warnings: primitiveRun.warnings,
			startedAt: startedAt,
			completedAt: Date(),
			status: primitiveRun.status,
			profile: planning.profile,
			planningWarnings: planning.planningWarnings,
			shapedConfidence: planning.shapedConfidence
		)
		result = decorateResultWithRuntimeMetadata(result)

		transition(
			to: terminalState(for: primitiveRun.status),
			actionId: action.id,
			startedAt: startedAt,
			failureReason: primitiveRun.status == .failed ? .invalidPlan : nil,
			warningCodes: primitiveRun.warnings,
			lastResult: result
		)
		log(event: "completed", reason: primitiveRun.status.rawValue, actionId: action.id)
		return result
	}

	private struct PrimitiveRunOutcome {
		var outputs: [ExecutionPrimitiveOutput]
		var warnings: [String]
		var status: ExecutionResultStatus
		var abortResult: ExecutionResult?
	}

	private struct WorkflowPlanningOutcome {
		let action: GeneratedExecutionAction
		let profile: WorkflowExecutionProfile?
		let planningWarnings: [String]
		let shapedConfidence: Double?
	}

	private func applyWorkflowPlanning(
		action: GeneratedExecutionAction,
		context: GeneratedExecutionContext
	) -> WorkflowPlanningOutcome {
		guard configuration.workflowPlanningEnabled else {
			return WorkflowPlanningOutcome(
				action: action,
				profile: nil,
				planningWarnings: [],
				shapedConfidence: nil
			)
		}
		let shaped = workflowPlanner.shape(action: action, context: context)
		let shapedAction = action.replacing(
			plan: shaped.plan,
			confidence: shaped.shapedConfidence
		)
		return WorkflowPlanningOutcome(
			action: shapedAction,
			profile: shaped.profile,
			planningWarnings: shaped.planningWarnings,
			shapedConfidence: shaped.shapedConfidence
		)
	}

	private func executePrimitives(
		action: GeneratedExecutionAction,
		context: GeneratedExecutionContext,
		startedAt: Date,
		deadline: Date,
		extraWarnings: [String] = []
	) async -> PrimitiveRunOutcome {
		var outputs: [ExecutionPrimitiveOutput] = []
		var warnings: [String] = extraWarnings
		let fallback = action.executionPlan.fallbackBehavior

		for primitive in action.executionPlan.primitives {
			if let abort = checkAbort(action: action, startedAt: startedAt, deadline: deadline) {
				return PrimitiveRunOutcome(
					outputs: outputs,
					warnings: warnings,
					status: .cancelled,
					abortResult: abort
				)
			}

			let primitiveBudget = await budgetManager.canRunPrimitive(
				primitive,
				action: action,
				snapshot: makeBudgetSnapshot(activeSamplingRequested: false)
			)
			if !primitiveBudget.allowed {
				let code = "budget_\(primitiveBudget.reason.rawValue)"
				warnings.append(code)
				log(event: "primitive_skipped", reason: code, actionId: action.id)
				if fallback == .failFast {
					let result = finishBudgetDenied(
						action: action,
						startedAt: startedAt,
						decision: primitiveBudget
					)
					return PrimitiveRunOutcome(
						outputs: outputs,
						warnings: warnings,
						status: .failed,
						abortResult: result
					)
				}
				continue
			}

			await budgetManager.recordPrimitiveStarted(primitive, action: action)
			log(event: "primitive_started", reason: primitive.rawValue, actionId: action.id)

			do {
				let output = try await primitiveRunner.run(
					primitive: primitive,
					context: context,
					action: action
				)
				outputs.append(output)
				warnings.append(contentsOf: output.warnings)
				log(event: "primitive_completed", reason: primitive.rawValue, actionId: action.id)
			} catch ExecutionPrimitiveRunnerError.unsupportedPrimitive {
				let code = "unsupported_\(primitive.rawValue)"
				warnings.append(code)
				log(event: "primitive_skipped", reason: code, actionId: action.id)
				if fallback == .failFast {
					await budgetManager.recordPrimitiveCompleted(primitive, action: action)
					let result = finishFailed(
						action: action,
						startedAt: startedAt,
						error: .invalidPlan,
						extraWarnings: warnings
					)
					return PrimitiveRunOutcome(
						outputs: outputs,
						warnings: warnings,
						status: .failed,
						abortResult: result
					)
				}
			} catch {
				warnings.append(ExecutionPrimitiveRunnerError.insufficientContext.rawValue)
				log(event: "primitive_skipped", reason: "error", actionId: action.id)
				if fallback == .failFast {
					await budgetManager.recordPrimitiveCompleted(primitive, action: action)
					let result = finishFailed(
						action: action,
						startedAt: startedAt,
						error: .invalidPlan,
						extraWarnings: warnings
					)
					return PrimitiveRunOutcome(
						outputs: outputs,
						warnings: warnings,
						status: .failed,
						abortResult: result
					)
				}
			}

			await budgetManager.recordPrimitiveCompleted(primitive, action: action)
			await lifecycleStepPause()
		}

		let status: ExecutionResultStatus
		if outputs.isEmpty {
			status = .failed
		} else if warnings.isEmpty {
			status = .success
		} else {
			status = .partialSuccess
		}

		return PrimitiveRunOutcome(outputs: outputs, warnings: warnings, status: status, abortResult: nil)
	}

	private func checkAbort(
		action: GeneratedExecutionAction,
		startedAt: Date,
		deadline: Date
	) -> ExecutionResult? {
		if cancelRequested || Task.isCancelled {
			return finishCancelled(action: action, startedAt: startedAt)
		}
		if Date() >= deadline {
			return finishTimedOut(action: action, startedAt: startedAt)
		}
		return nil
	}

	private func terminalState(for status: ExecutionResultStatus) -> ExecutionState {
		switch status {
		case .success, .partialSuccess, .pending:
			.completed
		case .failed:
			.failed
		case .cancelled:
			.cancelled
		case .timedOut:
			.timedOut
		}
	}

	private func finishCancelled(action: GeneratedExecutionAction, startedAt: Date) -> ExecutionResult {
		let result = makeTerminalResult(
			action: action,
			status: .cancelled,
			startedAt: startedAt,
			warnings: [GeneratedExecutionRuntimeError.cancelled.rawValue],
			metadata: ["runtimePhase": "cancelled"]
		)
		transition(
			to: .cancelled,
			actionId: action.id,
			startedAt: startedAt,
			failureReason: .cancelled,
			warningCodes: ["cancelled"],
			lastResult: result
		)
		log(event: "cancelled", reason: nil, actionId: action.id)
		cancelRequested = false
		return result
	}

	private func finishTimedOut(action: GeneratedExecutionAction, startedAt: Date) -> ExecutionResult {
		let result = makeTerminalResult(
			action: action,
			status: .timedOut,
			startedAt: startedAt,
			warnings: [GeneratedExecutionRuntimeError.timedOut.rawValue],
			metadata: ["runtimePhase": "timed_out"]
		)
		transition(
			to: .timedOut,
			actionId: action.id,
			startedAt: startedAt,
			failureReason: .timedOut,
			warningCodes: ["timed_out"],
			lastResult: result
		)
		log(event: "timeout", reason: nil, actionId: action.id)
		return result
	}

	private func recordPersistenceReuseIfNeeded(action: GeneratedExecutionAction) async {
		guard let persistenceManager, action.isReusable || action.reuseScore > 0 else { return }
		await persistenceManager.record(.from(kind: .reused, action: action))
	}

	private func recordPersistenceOutcome(action: GeneratedExecutionAction, result: ExecutionResult) async {
		guard let persistenceManager else { return }
		await persistenceManager.recordSuccessfulExecution(action: action, result: result)
	}

	private func makeBudgetSnapshot(activeSamplingRequested: Bool) -> GeneratedExecutionBudgetSnapshot {
		GeneratedExecutionBudgetSnapshot(
			activeExecutionCount: isExecutionActive ? 1 : 0,
			runtimeState: snapshot.currentState,
			permissionAvailability: canonicalSnapshot?.permissionAvailability ?? [:],
			activeSamplingRequested: activeSamplingRequested
		)
	}

	// MARK: - Sparse visual peek (T18.2)

	/// One bounded visual peek per lifecycle when policy, gate, budget, and scheduler allow.
	private func maybeEnrichWithSparseVisualPeek(
		action: GeneratedExecutionAction,
		baseContext: GeneratedExecutionContext,
		plan: ExecutionPlan
	) async -> GeneratedExecutionContext {
		guard let scheduler = visualContextScheduler,
		      let canon = canonicalSnapshot,
		      !sparseVisualPeekAttemptedInLifecycle
		else {
			if visualContextScheduler == nil {
				visualEnrichmentDecisionInLifecycle = "skipped:no_scheduler"
			} else if canonicalSnapshot == nil {
				visualEnrichmentDecisionInLifecycle = "skipped:no_canonical_snapshot"
			} else {
				visualEnrichmentDecisionInLifecycle = "skipped:already_attempted"
			}
			return baseContext
		}
		// Only attempt visual enrichment when the action explicitly requests vision/OCR (T18.3.7).
		if plan.requiresVision == false && plan.requiresOCR == false {
			visualEnrichmentDecisionInLifecycle = "skipped:action_not_visual"
			logVisualExecution(event: "visual_execution_skipped", reason: "action_not_visual", actionId: action.id)
			return baseContext
		}

		logVisualExecution(
			event: "visual_execution_requested",
			reason: "plan_requires_visual",
			actionId: action.id,
			extra: "capture_required=\(plan.requiresVision) ocr_required=\(plan.requiresOCR)"
		)


		sparseVisualPeekAttemptedInLifecycle = true
		let referenceTime = Date()

		let gateEval = await sparseVisualPeekGate.evaluate(snapshot: canon, referenceTime: referenceTime)
		if gateEval.shouldDeny {
			visualEnrichmentDecisionInLifecycle = "denied:\(gateEval.denyReason?.rawValue ?? "gate")"
			logVisualExecution(event: "visual_execution_denied", reason: gateEval.denyReason?.rawValue ?? "gate", actionId: action.id)
			logSparseVisualPeek(
				event: "sparse_visual_peek_denied",
				reason: gateEval.denyReason?.rawValue ?? "gate",
				actionId: action.id
			)
			if gateEval.denyReason == .cooldownWindowActive {
				logSparseVisualPeek(event: "visual_peek_cooldown_denied", reason: "cooldown", actionId: action.id)
			}
			return baseContext
		}

		let peekDecision = SparseVisualPeekPolicy.shouldRequestVisualPeek(
			snapshot: canon,
			action: action,
			gateEvaluation: gateEval,
			referenceTime: referenceTime
		)
		guard peekDecision.shouldPeek, let request = peekDecision.recommendedRequest else {
			visualEnrichmentDecisionInLifecycle = "denied:\(peekDecision.denyReason?.rawValue ?? "policy")"
			logVisualExecution(event: "visual_execution_denied", reason: peekDecision.denyReason?.rawValue ?? "policy", actionId: action.id)
			logSparseVisualPeek(
				event: "sparse_visual_peek_denied",
				reason: peekDecision.denyReason?.rawValue ?? "policy",
				actionId: action.id
			)
			return baseContext
		}

		let budgetSnapshot = makeBudgetSnapshot(
			activeSamplingRequested: plan.requiresVision || plan.requiresOCR || peekDecision.requiresOCR
		)
		let budgetDecision = await budgetManager.canCollectVisualContext(
			request: request,
			snapshot: budgetSnapshot
		)
		if !budgetDecision.allowed {
			visualEnrichmentDecisionInLifecycle = "denied:\(budgetDecision.reason.rawValue)"
			let meta = budgetDecision.metadata
				.prefix(6)
				.map { "\($0.key)=\($0.value)" }
				.joined(separator: ",")
			logVisualExecution(
				event: "visual_execution_denied",
				reason: budgetDecision.reason.rawValue,
				actionId: action.id,
				extra: meta.isEmpty ? nil : "meta=\(meta)"
			)
			logSparseVisualPeek(
				event: "visual_peek_budget_denied",
				reason: budgetDecision.reason.rawValue,
				actionId: action.id
			)
			return baseContext
		}

		logVisualExecution(event: "visual_execution_allowed", reason: peekDecision.allowReason?.rawValue ?? "allowed", actionId: action.id)
		visualEnrichmentDecisionInLifecycle = "allowed:\(peekDecision.allowReason?.rawValue ?? "allowed")"
		logSparseVisualPeek(
			event: "visual_peek_request_started",
			reason: peekDecision.allowReason?.rawValue,
			actionId: action.id
		)

		let visualResult = await scheduler.collect(request: request, budgetSnapshot: budgetSnapshot)
		visualEnrichmentDecisionInLifecycle = "completed:\(visualResult.status.rawValue)"
		let captured = visualResult.capturedAt != nil
		let ocrPresent = (visualResult.ocrExcerpt ?? "").isEmpty == false
		let descriptorPresent = (visualResult.visualSummary ?? "").isEmpty == false || visualResult.visualTags.isEmpty == false
		logVisualExecution(
			event: "visual_execution_completed",
			reason: visualResult.status.rawValue,
			actionId: action.id,
			extra: "capture=\(captured ? "yes" : "no") ocr=\(ocrPresent ? "yes" : "no") descriptors=\(descriptorPresent ? "yes" : "no")"
		)

		if visualResult.status == .completed || visualResult.status == .partial {
			await sparseVisualPeekGate.recordPeekCompleted(at: referenceTime)
			logSparseVisualPeek(
				event: "visual_peek_result_merged",
				reason: visualResult.status.rawValue,
				actionId: action.id
			)
			visualEnrichmentPerformedInLifecycle = true
			visualEnrichmentUsedOCRInLifecycle = (visualResult.ocrExcerpt ?? "").isEmpty == false
			visualEnrichmentUsedVisionSummaryInLifecycle = (visualResult.visualSummary ?? "").isEmpty == false
			visualEnrichmentDecisionInLifecycle = "merged"
			let ocrFlag = visualEnrichmentUsedOCRInLifecycle ? "yes" : "no"
			let descFlag = (visualEnrichmentUsedVisionSummaryInLifecycle || visualResult.visualTags.isEmpty == false) ? "yes" : "no"
			logVisualExecution(
				event: "visual_execution_merged",
				reason: "merged",
				actionId: action.id,
				extra: "ocr=\(ocrFlag) descriptors=\(descFlag)"
			)
			return baseContext.merging(visual: visualResult)
		}

		return baseContext
	}

	private func logVisualExecution(event: String, reason: String?, actionId: UUID?, extra: String? = nil) {
		var parts = ["event=\(event)"]
		if let reason, !reason.isEmpty { parts.append("reason=\(reason)") }
		if let extra, !extra.isEmpty { parts.append(extra) }
		if let actionId { parts.append("actionId=\(actionId.uuidString.prefix(8))") }
		print("[VisualExecution] \(parts.joined(separator: " "))")
	}

	private func logSparseVisualPeek(event: String, reason: String?, actionId: UUID?) {
		var parts = ["event=\(event)"]
		if let reason, !reason.isEmpty { parts.append("reason=\(reason)") }
		if let actionId { parts.append("actionId=\(actionId.uuidString.prefix(8))") }
		print("[SparseVisualPeek] \(parts.joined(separator: " "))")
	}

	private func finishBudgetDenied(
		action: GeneratedExecutionAction,
		startedAt: Date,
		decision: BudgetDecision
	) -> ExecutionResult {
		finishFailed(
			action: action,
			startedAt: startedAt,
			error: decision.runtimeError,
			extraWarnings: [decision.reason.rawValue]
		)
	}

	private func finishFailed(
		action: GeneratedExecutionAction,
		startedAt: Date,
		error: GeneratedExecutionRuntimeError,
		extraWarnings: [String] = []
	) -> ExecutionResult {
		var warnings = [error.rawValue]
		warnings.append(contentsOf: extraWarnings)
		let result = makeTerminalResult(
			action: action,
			status: .failed,
			startedAt: startedAt,
			warnings: warnings,
			metadata: ["runtimePhase": "failed", "error": error.rawValue]
		)
		transition(
			to: .failed,
			actionId: action.id,
			startedAt: startedAt,
			failureReason: error,
			warningCodes: warnings,
			lastResult: result
		)
		log(event: "failed", reason: error.rawValue, actionId: action.id)
		return result
	}

	private func applyTerminalFailure(error: GeneratedExecutionRuntimeError, actionId: UUID) {
		transition(
			to: .failed,
			actionId: actionId,
			startedAt: nil,
			failureReason: error,
			warningCodes: [error.rawValue]
		)
	}

	private func transition(
		to state: ExecutionState,
		actionId: UUID?,
		startedAt: Date?,
		failureReason: GeneratedExecutionRuntimeError?,
		warningCodes: [String],
		lastResult: ExecutionResult? = nil
	) {
		let now = Date()
		snapshot = GeneratedExecutionRuntimeSnapshot(
			currentState: state,
			activeActionId: actionId,
			startedAt: startedAt ?? snapshot.startedAt,
			lastUpdatedAt: now,
			lastResult: lastResult ?? snapshot.lastResult,
			failureReason: failureReason,
			warningCodes: warningCodes
		)
		log(event: "state", reason: state.rawValue, actionId: actionId)
	}

	private func makeTerminalResult(
		action: GeneratedExecutionAction,
		status: ExecutionResultStatus,
		startedAt: Date,
		warnings: [String],
		metadata: [String: String]
	) -> ExecutionResult {
		let meta = runtimeExecutionMetadata(merging: metadata)
		return ExecutionResult(
			actionId: action.id,
			status: status,
			startedAt: startedAt,
			completedAt: Date(),
			generatedContent: nil,
			generatedSections: [],
			warnings: warnings,
			executionMetadata: meta,
			confidence: action.confidence,
			followUpSuggestions: []
		)
	}

	private func decorateResultWithRuntimeMetadata(_ result: ExecutionResult) -> ExecutionResult {
		let merged = runtimeExecutionMetadata(merging: result.executionMetadata)
		// `ExecutionResult` is immutable; return a copy with merged metadata.
		return ExecutionResult(
			id: result.id,
			actionId: result.actionId,
			status: result.status,
			startedAt: result.startedAt,
			completedAt: result.completedAt,
			generatedContent: result.generatedContent,
			generatedSections: result.generatedSections,
			warnings: result.warnings,
			executionMetadata: merged,
			confidence: result.confidence,
			followUpSuggestions: result.followUpSuggestions
		)
	}

	private func runtimeExecutionMetadata(merging base: [String: String]) -> [String: String] {
		var meta = base
		// Taxonomy: distinguish capture vs OCR vs descriptors; do not imply semantic vision.
		meta["visual_enrichment_attempted"] = sparseVisualPeekAttemptedInLifecycle ? "1" : "0"
		meta["visual_enrichment_performed"] = visualEnrichmentPerformedInLifecycle ? "1" : "0"
		meta["visual_enrichment_ocr_performed"] = visualEnrichmentUsedOCRInLifecycle ? "1" : "0"
		meta["visual_enrichment_descriptor_present"] = visualEnrichmentUsedVisionSummaryInLifecycle ? "1" : "0"
		// Backward compatible keys.
		meta["visual_enrichment_used_ocr"] = visualEnrichmentUsedOCRInLifecycle ? "1" : "0"
		meta["visual_enrichment_used_visual_summary"] = visualEnrichmentUsedVisionSummaryInLifecycle ? "1" : "0"
		meta["visual_enrichment_decision"] = visualEnrichmentDecisionInLifecycle
		return meta
	}

	private func log(event: String, reason: String?, actionId: UUID?) {
		var meta = IntelligenceDebugMeta(layer: "generated_execution_runtime", detail: reason)
		if let actionId {
			meta.action = actionId.uuidString.prefix(8).description
		}
		IntelligenceDebugLogger.log(stage: .execution, event: event, meta: meta)
	}

	private func lifecycleStepPause() async {
		let delay = configuration.stepDelayNanoseconds
		if delay > 0 {
			try? await Task.sleep(nanoseconds: delay)
		} else {
			await Task.yield()
		}
	}
}

// MARK: - Lightweight self-test

extension GeneratedExecutionRuntime {
	static func runSelfTest() async -> Bool {
		var slowConfig = GeneratedExecutionRuntimeConfiguration.production
		slowConfig.stepDelayNanoseconds = 12_000_000
		let context = SelfTestFixtures.sampleContext()
		let provider = StaticGeneratedExecutionContextProvider(packet: context)

		let runtime = GeneratedExecutionRuntime(contextProvider: provider)
		let multi = SelfTestFixtures.multiPrimitiveAction()
		let first = await runtime.start(action: multi)
		guard case .completed(let result) = first,
		      result.status == .success || result.status == .partialSuccess,
		      result.generatedSections.count >= 2 else { return false }

		await runtime.reset()

		let rejectRuntime = GeneratedExecutionRuntime(contextProvider: provider)
		guard case .rejected(.invalidPlan) = await rejectRuntime.start(action: SelfTestFixtures.invalidPlanAction()) else {
			return false
		}

		let noContextRuntime = GeneratedExecutionRuntime()
		guard case .completed(let missing) = await noContextRuntime.start(action: SelfTestFixtures.validAction()),
		      missing.status == .failed else { return false }

		let expiredRuntime = GeneratedExecutionRuntime(
			contextProvider: StaticGeneratedExecutionContextProvider(packet: SelfTestFixtures.expiredContext())
		)
		guard case .completed(let expiredResult) = await expiredRuntime.start(action: SelfTestFixtures.validAction()),
		      expiredResult.status == .failed else { return false }

		let degradeRuntime = GeneratedExecutionRuntime(contextProvider: provider)
		let unsupported = SelfTestFixtures.unsupportedPrimitiveAction(fallback: .degradeToSummary)
		guard case .completed(let partial) = await degradeRuntime.start(action: unsupported),
		      partial.status == .partialSuccess || partial.status == .success,
		      partial.warnings.contains(where: { $0.hasPrefix("unsupported_") }) else { return false }

		let failFastRuntime = GeneratedExecutionRuntime(contextProvider: provider)
		let failFast = SelfTestFixtures.unsupportedPrimitiveAction(fallback: .failFast)
		guard case .completed(let failed) = await failFastRuntime.start(action: failFast),
		      failed.status == .failed else { return false }

		let slow = GeneratedExecutionRuntime(configuration: slowConfig, contextProvider: provider)
		let inFlight = Task { await slow.start(action: SelfTestFixtures.validAction()) }
		try? await Task.sleep(nanoseconds: 2_000_000)
		guard case .rejected(.alreadyRunning) = await slow.start(action: SelfTestFixtures.validAction()) else { return false }
		_ = await slow.cancel()
		let inFlightOutcome = await inFlight.value
		guard case .completed(let cancelResult) = inFlightOutcome, cancelResult.status == .cancelled else { return false }

		let timeoutAction = SelfTestFixtures.validAction()
		var timeoutConfig = slowConfig
		timeoutConfig.maxExecutionTimeOverride = 0.001
		timeoutConfig.stepDelayNanoseconds = 25_000_000
		let timeoutRuntime = GeneratedExecutionRuntime(
			configuration: timeoutConfig,
			contextProvider: provider
		)
		guard case .completed(let timed) = await timeoutRuntime.start(action: timeoutAction),
		      timed.status == .timedOut else { return false }

		guard await GeneratedExecutionBudgetManager.runSelfTest() else { return false }
		guard WorkflowExecutionPlanner.runSelfTest() else { return false }
		guard WorkflowExecutionMapper.workflowType(from: .debugging) == .debugging else { return false }
		guard await GeneratedActionPersistenceManager.runSelfTest() else { return false }
		guard await VisualContextScheduler.runSelfTest() else { return false }

		let denyCpu = StaticCpuBudgetSnapshotProvider(
			snapshot: CpuBudgetSnapshot(systemCPUUsagePercent: 99, thermalStateCode: "nominal")
		)
		let budgetDeniedRuntime = GeneratedExecutionRuntime(
			contextProvider: provider,
			budgetManager: GeneratedExecutionBudgetManager(cpuProvider: denyCpu)
		)
		guard case .rejected(.budgetExceeded) = await budgetDeniedRuntime.start(action: SelfTestFixtures.validAction()) else {
			return false
		}

		return true
	}
}

private enum SelfTestFixtures {
	static func sampleContext() -> GeneratedExecutionContext {
		let now = Date()
		return GeneratedExecutionContext(
			sourceType: "self_test",
			appName: "Contextual",
			windowTitle: "Self Test",
			workflowType: .writing,
			intentType: .summarize,
			selectedTextExcerpt: "- Draft outline\n- TODO: finish section\nError: sample failed\nNotes line",
			availableContextTypes: [.textSnippet, .selectedText],
			createdAt: now,
			expirationDate: now.addingTimeInterval(300)
		)
	}

	static func expiredContext() -> GeneratedExecutionContext {
		let now = Date()
		return GeneratedExecutionContext(
			sourceType: "self_test",
			appName: "Contextual",
			windowTitle: "Expired",
			workflowType: .unknown,
			intentType: .unknown,
			selectedTextExcerpt: "stale",
			availableContextTypes: [.textSnippet],
			createdAt: now.addingTimeInterval(-60),
			expirationDate: now.addingTimeInterval(-1)
		)
	}

	static func validAction(budget: ExecutionBudget = .conservative) -> GeneratedExecutionAction {
		action(primitives: [.summarizeContext], budget: budget, fallback: .failFast)
	}

	static func multiPrimitiveAction() -> GeneratedExecutionAction {
		action(primitives: [.summarizeContext, .extractActionItems], budget: .conservative, fallback: .degradeToSummary)
	}

	static func unsupportedPrimitiveAction(fallback: ExecutionFallbackBehavior) -> GeneratedExecutionAction {
		action(primitives: [.summarizeContext, .compareContexts], budget: .conservative, fallback: fallback)
	}

	static func invalidPlanAction() -> GeneratedExecutionAction {
		action(primitives: [], budget: .conservative, fallback: .failFast)
	}

	private static func action(
		primitives: [ExecutionPrimitive],
		budget: ExecutionBudget,
		fallback: ExecutionFallbackBehavior
	) -> GeneratedExecutionAction {
		let plan = ExecutionPlan(
			primitives: primitives,
			estimatedCost: 0.3,
			estimatedRuntime: 10,
			requiresVision: false,
			requiresOCR: false,
			requiresUserIntent: false,
			requiredPermissions: [.none],
			fallbackBehavior: fallback,
			executionBudget: budget,
			planConfidence: 0.7
		)
		let now = Date()
		return GeneratedExecutionAction(
			title: "Self-test execution",
			description: "Runtime self-test",
			workflowType: .writing,
			intentType: .summarize,
			confidence: 0.7,
			interruptionCost: 0.2,
			requiredContextTypes: [.textSnippet],
			executionPlan: plan,
			explainabilitySummary: "self_test",
			generationSource: .selfTest,
			createdAt: now,
			expirationDate: now.addingTimeInterval(300),
			isReusable: false,
			reuseScore: 0
		)
	}
}
