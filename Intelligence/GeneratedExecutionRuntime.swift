import Foundation

/// Bounded lifecycle coordinator for generated execution (T17.2 — placeholder flow only).
///
/// Isolated `actor` with explicit snapshots; no UI coupling, no `@Published`, no background loops.
actor GeneratedExecutionRuntime {

	private let configuration: GeneratedExecutionRuntimeConfiguration
	private(set) var snapshot: GeneratedExecutionRuntimeSnapshot = .initial
	private var cancelRequested = false

	init(configuration: GeneratedExecutionRuntimeConfiguration = .production) {
		self.configuration = configuration
	}

	// MARK: - Public API

	func currentSnapshot() -> GeneratedExecutionRuntimeSnapshot {
		snapshot
	}

	/// Validates the action, runs the placeholder lifecycle, and returns a result or rejection.
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

		cancelRequested = false
		let startedAt = Date()
		transition(
			to: .validating,
			actionId: action.id,
			startedAt: startedAt,
			failureReason: nil,
			warningCodes: []
		)
		log(event: "start_accepted", reason: nil, actionId: action.id)

		let result = await runPlaceholderLifecycle(action: action, startedAt: startedAt)
		return .completed(result)
	}

	/// Requests cooperative cancellation of the in-flight placeholder lifecycle.
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

	/// Clears runtime to idle; does not cancel an active lifecycle (call `cancel` first if needed).
	func reset() {
		cancelRequested = false
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
			return .budgetExceeded
		}
		if plan.requiresOCR && !budget.allowsOCR {
			return .budgetExceeded
		}
		if plan.estimatedRuntime > budget.maxExecutionTime {
			return .budgetExceeded
		}

		let needsContext = action.requiredContextTypes.contains { $0 != .none }
		if needsContext && plan.requiresUserIntent {
			// Placeholder: context presence is not verified until T17.3+.
		}

		return nil
	}

	private func runPlaceholderLifecycle(
		action: GeneratedExecutionAction,
		startedAt: Date
	) async -> ExecutionResult {
		let progression: [ExecutionState] = [
			.gatheringContext,
			.executing,
			.synthesizingResult,
		]

		for state in progression {
			if cancelRequested || Task.isCancelled {
				return finishCancelled(action: action, startedAt: startedAt)
			}
			transition(
				to: state,
				actionId: action.id,
				startedAt: startedAt,
				failureReason: nil,
				warningCodes: snapshot.warningCodes
			)
			await lifecycleStepPause()
		}

		if cancelRequested || Task.isCancelled {
			return finishCancelled(action: action, startedAt: startedAt)
		}

		let result = makePlaceholderSuccessResult(action: action, startedAt: startedAt)
		transition(
			to: .completed,
			actionId: action.id,
			startedAt: startedAt,
			failureReason: nil,
			warningCodes: ["primitive_execution_not_implemented"],
			lastResult: result
		)
		log(event: "completed", reason: "placeholder", actionId: action.id)
		return result
	}

	private func finishCancelled(action: GeneratedExecutionAction, startedAt: Date) -> ExecutionResult {
		let result = makeResult(
			action: action,
			status: .cancelled,
			startedAt: startedAt,
			completedAt: Date(),
			warnings: [GeneratedExecutionRuntimeError.cancelled.rawValue],
			metadata: ["runtimePhase": "placeholder_cancelled"]
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

	private func applyTerminalFailure(error: GeneratedExecutionRuntimeError, actionId: UUID) {
		transition(
			to: .failed,
			actionId: actionId,
			startedAt: nil,
			failureReason: error,
			warningCodes: [error.rawValue]
		)
	}

	/// Single path for all snapshot mutations.
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

	// MARK: - Placeholder results

	private func makePlaceholderSuccessResult(
		action: GeneratedExecutionAction,
		startedAt: Date
	) -> ExecutionResult {
		let primitiveCodes = action.executionPlan.primitives.map(\.rawValue).joined(separator: ",")
		return makeResult(
			action: action,
			status: .success,
			startedAt: startedAt,
			completedAt: Date(),
			warnings: ["primitive_execution_not_implemented"],
			metadata: [
				"runtimePhase": "placeholder",
				"primitiveCount": String(action.executionPlan.primitives.count),
				"primitiveCodes": primitiveCodes,
				"planId": action.executionPlan.id.uuidString,
			],
			content: "Execution runtime foundation is wired. Primitive execution is not implemented yet (T17.3+).",
			sections: [
				ExecutionResultSection(
					title: "Runtime",
					body: "Lifecycle validated: validating → gathering_context → executing → synthesizing_result → completed.",
					order: 0
				),
			]
		)
	}

	private func makeResult(
		action: GeneratedExecutionAction,
		status: ExecutionResultStatus,
		startedAt: Date,
		completedAt: Date,
		warnings: [String],
		metadata: [String: String],
		content: String? = nil,
		sections: [ExecutionResultSection] = []
	) -> ExecutionResult {
		ExecutionResult(
			actionId: action.id,
			status: status,
			startedAt: startedAt,
			completedAt: completedAt,
			generatedContent: content,
			generatedSections: sections,
			warnings: warnings,
			executionMetadata: metadata,
			confidence: action.confidence,
			followUpSuggestions: []
		)
	}

	// MARK: - Logging

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
	/// Deterministic in-process checks (no UI, no AI).
	static func runSelfTest() async -> Bool {
		let slowConfig = GeneratedExecutionRuntimeConfiguration(stepDelayNanoseconds: 15_000_000)
		let action = SelfTestFixtures.validAction()

		let runtime = GeneratedExecutionRuntime()
		let first = await runtime.start(action: action)
		guard case .completed(let result) = first, result.status == .success else { return false }
		let snap = await runtime.currentSnapshot()
		guard snap.currentState == .completed, snap.lastResult?.id == result.id else { return false }

		await runtime.reset()
		guard await runtime.currentSnapshot().currentState == .idle else { return false }
		guard await runtime.cancel() == nil else { return false }

		let rejectRuntime = GeneratedExecutionRuntime()
		let rejected = await rejectRuntime.start(action: SelfTestFixtures.invalidPlanAction())
		guard case .rejected(.invalidPlan) = rejected else { return false }

		let slow = GeneratedExecutionRuntime(configuration: slowConfig)
		let inFlight = Task { await slow.start(action: action) }
		try? await Task.sleep(nanoseconds: 2_000_000)
		let overlap = await slow.start(action: action)
		guard case .rejected(.alreadyRunning) = overlap else { return false }
		_ = await slow.cancel()
		guard case .completed(let cancelled) = await inFlight.value, cancelled.status == .cancelled else { return false }

		return true
	}
}

private enum SelfTestFixtures {
	static func validAction() -> GeneratedExecutionAction {
		let budget = ExecutionBudget.conservative
		let plan = ExecutionPlan(
			primitives: [.summarizeContext],
			estimatedCost: 0.3,
			estimatedRuntime: 10,
			requiresVision: false,
			requiresOCR: false,
			requiresUserIntent: false,
			requiredPermissions: [.none],
			fallbackBehavior: .failFast,
			executionBudget: budget,
			planConfidence: 0.7
		)
		let now = Date()
		return GeneratedExecutionAction(
			title: "Self-test execution",
			description: "Runtime foundation self-test",
			workflowType: .unknown,
			intentType: .summarize,
			confidence: 0.7,
			interruptionCost: 0.2,
			requiredContextTypes: [.none],
			executionPlan: plan,
			explainabilitySummary: "self_test",
			generationSource: .selfTest,
			createdAt: now,
			expirationDate: now.addingTimeInterval(300),
			isReusable: false,
			reuseScore: 0
		)
	}

	static func invalidPlanAction() -> GeneratedExecutionAction {
		let action = validAction()
		let emptyPlan = ExecutionPlan(
			primitives: [],
			estimatedCost: 0,
			estimatedRuntime: 0,
			requiresVision: false,
			requiresOCR: false,
			requiresUserIntent: false,
			requiredPermissions: [],
			fallbackBehavior: .failFast,
			executionBudget: .conservative,
			planConfidence: 0
		)
		return GeneratedExecutionAction(
			id: action.id,
			title: action.title,
			description: action.description,
			workflowType: action.workflowType,
			intentType: action.intentType,
			confidence: action.confidence,
			interruptionCost: action.interruptionCost,
			requiredContextTypes: action.requiredContextTypes,
			executionPlan: emptyPlan,
			explainabilitySummary: action.explainabilitySummary,
			generationSource: action.generationSource,
			createdAt: action.createdAt,
			expirationDate: action.expirationDate,
			isReusable: action.isReusable,
			reuseScore: action.reuseScore
		)
	}
}
