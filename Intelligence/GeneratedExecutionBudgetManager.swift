import Foundation

/// Tunable caps for in-memory execution frequency tracking (no persistence).
struct GeneratedExecutionBudgetConfiguration: Sendable, Equatable {
	var maxStartsPerWindow: Int
	var frequencyWindowSeconds: TimeInterval
	var historyCapacity: Int

	static let production = GeneratedExecutionBudgetConfiguration(
		maxStartsPerWindow: 8,
		frequencyWindowSeconds: 60,
		historyCapacity: 32
	)

	static let strictTest = GeneratedExecutionBudgetConfiguration(
		maxStartsPerWindow: 2,
		frequencyWindowSeconds: 30,
		historyCapacity: 16
	)
}

/// Phase 17 execution budget layer — explicit, event-driven, isolated from proposal budgeting.
actor GeneratedExecutionBudgetManager {

	private let cpuProvider: CpuBudgetSnapshotProvider
	private let configuration: GeneratedExecutionBudgetConfiguration

	private struct HistoryEntry: Sendable {
		enum Kind: String, Sendable {
			case started
			case completed
			case rejected
			case primitiveStarted
			case primitiveCompleted
		}

		let at: Date
		let kind: Kind
		let actionIdPrefix: String
	}

	private var history: [HistoryEntry] = []
	private var trackedActiveExecutions: Int = 0
	private var primitivesRunning: Int = 0

	init(
		cpuProvider: CpuBudgetSnapshotProvider = ConservativeCpuBudgetSnapshotProvider(),
		configuration: GeneratedExecutionBudgetConfiguration = .production
	) {
		self.cpuProvider = cpuProvider
		self.configuration = configuration
	}

	// MARK: - Decisions

	func canStartExecution(
		action: GeneratedExecutionAction,
		contextSnapshot: GeneratedExecutionBudgetSnapshot
	) async -> BudgetDecision {
		let budget = action.executionPlan.executionBudget

		if let invalid = validateBudgetShape(budget) {
			return invalid
		}
		if budget.allowsBackgroundWork {
			return deny(.backgroundWorkNotAllowed, budget: budget, meta: ["gate": "start"])
		}
		if trackedActiveExecutions >= budget.maxConcurrentTasks {
			return deny(.concurrencyLimitReached, budget: budget, meta: concurrencyMeta(snapshot: contextSnapshot))
		}
		if contextSnapshot.activeExecutionCount > 0 || isActiveRuntimeState(contextSnapshot.runtimeState) {
			return deny(.executionAlreadyActive, budget: budget, meta: concurrencyMeta(snapshot: contextSnapshot))
		}
		if recentEventCount(kind: .started, within: configuration.frequencyWindowSeconds)
			>= configuration.maxStartsPerWindow
		{
			return deny(
				.generationFrequencyExceeded,
				budget: budget,
				recommendedDelay: configuration.frequencyWindowSeconds / 2,
				meta: frequencyMeta()
			)
		}
		if let cpuDecision = evaluateCpuBudget(budget: budget, gate: "start") {
			return cpuDecision
		}

		let decision = BudgetDecision.allow(priority: budget.budgetPriority, metadata: ["gate": "start"])
		logBudget(decision: decision, actionId: action.id, snapshot: contextSnapshot)
		return decision
	}

	func canGatherContext(
		requirements: [ContextRequirementType],
		budget: ExecutionBudget,
		snapshot: GeneratedExecutionBudgetSnapshot
	) async -> BudgetDecision {
		if let invalid = validateBudgetShape(budget) {
			return invalid
		}
		if budget.allowsBackgroundWork {
			return deny(.backgroundWorkNotAllowed, budget: budget, meta: ["gate": "gather"])
		}

		let expensiveRequirements = requirements.filter(Self.isExpensiveContextRequirement)
		if !expensiveRequirements.isEmpty {
			if !activeSamplingPermitted(budget: budget, snapshot: snapshot) {
				return deny(.activeSamplingDenied, budget: budget, meta: ["gate": "gather", "expensive": "1"])
			}
			if requirements.contains(.fusedVisual) || requirements.contains(.screenCapture) {
				if !budget.allowsVision && !budget.allowsOCR {
					return deny(.visionNotAllowed, budget: budget, meta: ["gate": "gather"])
				}
				if !snapshot.permissionGranted(.screenRecording) {
					return deny(.expensiveContextDenied, budget: budget, meta: ["gate": "gather", "perm": "screen"])
				}
			}
			if requirements.contains(.screenCapture) && !budget.allowsOCR {
				return deny(.ocrNotAllowed, budget: budget, meta: ["gate": "gather"])
			}
		} else if snapshot.activeSamplingRequested && !activeSamplingPermitted(budget: budget, snapshot: snapshot) {
			return deny(.activeSamplingDenied, budget: budget, meta: ["gate": "gather", "sampling": "1"])
		}

		if let cpuDecision = evaluateCpuBudget(budget: budget, gate: "gather") {
			return cpuDecision
		}

		return BudgetDecision.allow(priority: budget.budgetPriority, metadata: ["gate": "gather"])
	}

	/// Explicit bounded visual context collection (T17.8) — never bypasses vision/OCR/sampling gates.
	func canCollectVisualContext(
		request: BoundedVisualContextRequest,
		snapshot: GeneratedExecutionBudgetSnapshot
	) async -> BudgetDecision {
		let budget = request.budget
		if let invalid = validateBudgetShape(budget) {
			return invalid
		}
		if budget.allowsBackgroundWork {
			return deny(.backgroundWorkNotAllowed, budget: budget, meta: ["gate": "visual"])
		}
		if !activeSamplingPermitted(budget: budget, snapshot: snapshot) {
			return deny(.activeSamplingDenied, budget: budget, meta: ["gate": "visual"])
		}
		if request.requiresOCR && !budget.allowsOCR {
			return deny(.ocrNotAllowed, budget: budget, meta: ["gate": "visual"])
		}
		if request.requiresVisualDescription && !budget.allowsVision {
			return deny(.visionNotAllowed, budget: budget, meta: ["gate": "visual"])
		}
		if request.allowedSources.contains(.screenCapture)
			&& !request.permissionGranted(.screenRecording)
			&& !snapshot.permissionGranted(.screenRecording)
		{
			return deny(.expensiveContextDenied, budget: budget, meta: ["gate": "visual", "perm": "screen"])
		}
		if let cpuDecision = evaluateCpuBudget(budget: budget, gate: "visual") {
			return cpuDecision
		}
		return BudgetDecision.allow(priority: budget.budgetPriority, metadata: ["gate": "visual"])
	}

	func canRunPrimitive(
		_ primitive: ExecutionPrimitive,
		action: GeneratedExecutionAction,
		snapshot: GeneratedExecutionBudgetSnapshot
	) async -> BudgetDecision {
		let budget = action.executionPlan.executionBudget
		if let invalid = validateBudgetShape(budget) {
			return invalid
		}
		if primitivesRunning >= budget.maxConcurrentTasks {
			return deny(.concurrencyLimitReached, budget: budget, meta: concurrencyMeta(snapshot: snapshot))
		}
		if requiresLLM(primitive) && !budget.allowsLLM {
			return deny(.llmNotAllowed, budget: budget, meta: ["primitive": primitive.rawValue])
		}
		if let cpuDecision = evaluateCpuBudget(budget: budget, gate: "primitive") {
			return cpuDecision
		}

		return BudgetDecision.allow(
			priority: budget.budgetPriority,
			metadata: ["gate": "primitive", "primitive": primitive.rawValue]
		)
	}

	// MARK: - Recording (event-driven)

	func recordExecutionStarted(action: GeneratedExecutionAction) {
		trackedActiveExecutions += 1
		appendHistory(kind: .started, actionId: action.id)
	}

	func recordExecutionCompleted(action: GeneratedExecutionAction, result: ExecutionResult) {
		trackedActiveExecutions = max(0, trackedActiveExecutions - 1)
		primitivesRunning = 0
		appendHistory(kind: .completed, actionId: action.id)
		logBudget(
			decision: BudgetDecision.allow(metadata: ["gate": "complete", "status": result.status.rawValue]),
			actionId: action.id,
			snapshot: nil
		)
	}

	func recordExecutionRejected(action: GeneratedExecutionAction, reason: BudgetDecisionReason) {
		appendHistory(kind: .rejected, actionId: action.id)
		logBudget(
			decision: BudgetDecision.deny(reason: reason, metadata: ["gate": "reject"]),
			actionId: action.id,
			snapshot: nil
		)
	}

	func recordPrimitiveStarted(_ primitive: ExecutionPrimitive, action: GeneratedExecutionAction) {
		primitivesRunning += 1
		appendHistory(kind: .primitiveStarted, actionId: action.id, detail: primitive.rawValue)
	}

	func recordPrimitiveCompleted(_ primitive: ExecutionPrimitive, action: GeneratedExecutionAction) {
		primitivesRunning = max(0, primitivesRunning - 1)
		appendHistory(kind: .primitiveCompleted, actionId: action.id, detail: primitive.rawValue)
	}

	// MARK: - Internals

	private func validateBudgetShape(_ budget: ExecutionBudget) -> BudgetDecision? {
		if budget.maxCPUPercent < 5 {
			return BudgetDecision.deny(reason: .budgetInvalid, metadata: ["detail": "cpu_floor"])
		}
		if budget.maxConcurrentTasks < 1 {
			return BudgetDecision.deny(reason: .budgetInvalid, metadata: ["detail": "concurrency"])
		}
		if budget.maxExecutionTime < 5 {
			return BudgetDecision.deny(reason: .budgetInvalid, metadata: ["detail": "time_floor"])
		}
		return nil
	}

	private func evaluateCpuBudget(budget: ExecutionBudget, gate: String) -> BudgetDecision? {
		let snap = cpuProvider.currentSnapshot()
		if let thermal = snap.thermalStateCode {
			let hot = thermal == "serious" || thermal == "critical"
			if hot && budget.thermalStateSensitivity >= 0.35 {
				return deny(
					.thermalSensitivityDenied,
					budget: budget,
					meta: ["gate": gate, "thermal": thermal]
				)
			}
		}
		if let usage = snap.systemCPUUsagePercent, usage > budget.maxCPUPercent {
			return deny(
				.cpuBudgetExceeded,
				budget: budget,
				meta: ["gate": gate, "cpu": String(format: "%.0f", usage)]
			)
		}
		return nil
	}

	private func activeSamplingPermitted(
		budget: ExecutionBudget,
		snapshot: GeneratedExecutionBudgetSnapshot
	) -> Bool {
		budget.allowsVision || budget.allowsOCR
			|| snapshot.permissionGranted(.screenRecording)
			|| snapshot.permissionGranted(.accessibility)
	}

	private static func isExpensiveContextRequirement(_ type: ContextRequirementType) -> Bool {
		switch type {
		case .fusedVisual, .screenCapture, .multiSource:
			true
		default:
			false
		}
	}

	private func requiresLLM(_ primitive: ExecutionPrimitive) -> Bool {
		switch primitive {
		case .synthesizeResearchSummary, .answerFromContext:
			true
		default:
			false
		}
	}

	private func isActiveRuntimeState(_ state: ExecutionState) -> Bool {
		switch state {
		case .validating, .gatheringContext, .executing, .synthesizingResult:
			true
		default:
			false
		}
	}

	private func recentEventCount(kind: HistoryEntry.Kind, within window: TimeInterval) -> Int {
		let cutoff = Date().addingTimeInterval(-window)
		return history.filter { $0.kind == kind && $0.at >= cutoff }.count
	}

	private func appendHistory(kind: HistoryEntry.Kind, actionId: UUID, detail: String? = nil) {
		let prefix = actionId.uuidString.prefix(8).description
		history.append(HistoryEntry(at: Date(), kind: kind, actionIdPrefix: prefix))
		if history.count > configuration.historyCapacity {
			history.removeFirst(history.count - configuration.historyCapacity)
		}
		_ = detail
	}

	private func deny(
		_ reason: BudgetDecisionReason,
		budget: ExecutionBudget,
		severity: BudgetDecisionSeverity = .deny,
		recommendedDelay: TimeInterval = 0,
		meta: [String: String]
	) -> BudgetDecision {
		var metadata = meta
		metadata["recentStarts"] = String(recentEventCount(kind: .started, within: configuration.frequencyWindowSeconds))
		metadata["activeExecutions"] = String(trackedActiveExecutions)
		let decision = BudgetDecision.deny(
			reason: reason,
			priority: budget.budgetPriority,
			severity: severity,
			recommendedDelay: recommendedDelay,
			metadata: metadata
		)
		logBudget(decision: decision, actionId: nil, snapshot: nil)
		return decision
	}

	private func concurrencyMeta(snapshot: GeneratedExecutionBudgetSnapshot) -> [String: String] {
		[
			"trackedActive": String(trackedActiveExecutions),
			"snapshotActive": String(snapshot.activeExecutionCount),
		]
	}

	private func frequencyMeta() -> [String: String] {
		[
			"recentStarts": String(recentEventCount(kind: .started, within: configuration.frequencyWindowSeconds)),
			"maxStarts": String(configuration.maxStartsPerWindow),
		]
	}

	private func logBudget(
		decision: BudgetDecision,
		actionId: UUID?,
		snapshot: GeneratedExecutionBudgetSnapshot?
	) {
		var meta = IntelligenceDebugMeta(
			reason: decision.reason.rawValue,
			layer: "generated_execution_budget",
			detail: decision.allowed ? "allowed" : "denied"
		)
		if let actionId {
			meta.action = actionId.uuidString.prefix(8).description
		}
		if let snapshot {
			meta.actions = snapshot.activeExecutionCount
		}
		if let cpu = decision.metadata["cpu"] {
			meta.score = cpu
		}
		if let thermal = decision.metadata["thermal"] {
			meta.type = thermal
		}
		if let starts = decision.metadata["recentStarts"] {
			meta.lenBucket = Int(starts) ?? 0
		}
		IntelligenceDebugLogger.log(
			stage: .execution,
			event: decision.allowed ? "budget_allowed" : "budget_denied",
			meta: meta
		)
	}
}

// MARK: - Self-test

extension GeneratedExecutionBudgetManager {
	static func runSelfTest() async -> Bool {
		let allowCpu = StaticCpuBudgetSnapshotProvider(
			snapshot: CpuBudgetSnapshot(systemCPUUsagePercent: 10, thermalStateCode: "nominal")
		)
		let manager = GeneratedExecutionBudgetManager(cpuProvider: allowCpu)
		let action = BudgetSelfTestFixtures.action()
		let idle = GeneratedExecutionBudgetSnapshot.idle

		let startOk = await manager.canStartExecution(action: action, contextSnapshot: idle)
		guard startOk.allowed else { return false }

		await manager.recordExecutionStarted(action: action)
		let overlap = await manager.canStartExecution(action: action, contextSnapshot: idle)
		guard !overlap.allowed, overlap.reason == .executionAlreadyActive else { return false }
		await manager.recordExecutionCompleted(
			action: action,
			result: BudgetSelfTestFixtures.stubResult(action: action)
		)

		let denyCpu = StaticCpuBudgetSnapshotProvider(
			snapshot: CpuBudgetSnapshot(systemCPUUsagePercent: 95, thermalStateCode: "nominal")
		)
		let cpuMgr = GeneratedExecutionBudgetManager(cpuProvider: denyCpu)
		let cpuDeny = await cpuMgr.canStartExecution(action: action, contextSnapshot: .idle)
		guard !cpuDeny.allowed, cpuDeny.reason == .cpuBudgetExceeded else { return false }

		let freqMgr = GeneratedExecutionBudgetManager(
			cpuProvider: allowCpu,
			configuration: .strictTest
		)
		for _ in 0..<3 {
			_ = await freqMgr.canStartExecution(action: action, contextSnapshot: .idle)
			await freqMgr.recordExecutionStarted(action: action)
			await freqMgr.recordExecutionCompleted(
				action: action,
				result: BudgetSelfTestFixtures.stubResult(action: action)
			)
		}
		let freqDeny = await freqMgr.canStartExecution(action: action, contextSnapshot: .idle)
		guard !freqDeny.allowed, freqDeny.reason == .generationFrequencyExceeded else { return false }

		let visionBudget = ExecutionBudget(allowsVision: false, allowsOCR: false)
		let gatherDeny = await manager.canGatherContext(
			requirements: [.screenCapture],
			budget: visionBudget,
			snapshot: .idle
		)
		guard !gatherDeny.allowed,
		      gatherDeny.reason == .visionNotAllowed || gatherDeny.reason == .activeSamplingDenied else { return false }

		let llmAction = BudgetSelfTestFixtures.action(budget: ExecutionBudget(allowsLLM: false))
		let primDeny = await manager.canRunPrimitive(
			.answerFromContext,
			action: llmAction,
			snapshot: GeneratedExecutionBudgetSnapshot(
				activeExecutionCount: 1,
				runtimeState: .executing
			)
		)
		guard !primDeny.allowed, primDeny.reason == .llmNotAllowed else { return false }

		let primMgr = GeneratedExecutionBudgetManager(cpuProvider: allowCpu)
		await primMgr.recordExecutionStarted(action: action)
		await primMgr.recordPrimitiveStarted(.summarizeContext, action: action)
		let primConcurrency = await primMgr.canRunPrimitive(
			.extractActionItems,
			action: action,
			snapshot: GeneratedExecutionBudgetSnapshot(activeExecutionCount: 1, runtimeState: .executing)
		)
		guard !primConcurrency.allowed, primConcurrency.reason == .concurrencyLimitReached else { return false }

		let visualReq = BoundedVisualContextRequest(
			reason: "budget_self_test",
			workflowType: .debugging,
			intentType: .explain,
			requiresOCR: true,
			budget: ExecutionBudget(allowsVision: true, allowsOCR: false)
		)
		let visualDeny = await manager.canCollectVisualContext(request: visualReq, snapshot: .idle)
		guard !visualDeny.allowed, visualDeny.reason == .ocrNotAllowed else { return false }

		return true
	}
}

private enum BudgetSelfTestFixtures {
	static func action(budget: ExecutionBudget = .conservative) -> GeneratedExecutionAction {
		let plan = ExecutionPlan(
			primitives: [.summarizeContext],
			estimatedCost: 0.2,
			estimatedRuntime: 10,
			requiresVision: false,
			requiresOCR: false,
			requiresUserIntent: false,
			requiredPermissions: [.none],
			fallbackBehavior: .failFast,
			executionBudget: budget,
			planConfidence: 0.6
		)
		let now = Date()
		return GeneratedExecutionAction(
			title: "Budget test",
			description: "test",
			workflowType: .unknown,
			intentType: .summarize,
			confidence: 0.6,
			interruptionCost: 0.1,
			requiredContextTypes: [.textSnippet],
			executionPlan: plan,
			explainabilitySummary: "test",
			generationSource: .selfTest,
			createdAt: now,
			expirationDate: now.addingTimeInterval(120),
			isReusable: false,
			reuseScore: 0
		)
	}

	static func stubResult(action: GeneratedExecutionAction) -> ExecutionResult {
		ExecutionResult(
			actionId: action.id,
			status: .success,
			startedAt: Date(),
			completedAt: Date(),
			generatedContent: nil,
			generatedSections: [],
			warnings: [],
			executionMetadata: [:],
			confidence: action.confidence,
			followUpSuggestions: []
		)
	}
}
