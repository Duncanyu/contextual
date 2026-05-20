import Foundation

enum GeneratedActionPersistenceScoring {
	static func usefulnessScore(
		record: ReusableGeneratedActionRecord,
		policy: GeneratedActionPersistencePolicy,
		now: Date
	) -> Double {
		var score = 0.35
		score += Double(record.acceptedCount) * 0.12
		score += Double(record.successfulExecutionCount) * 0.1
		score += Double(record.repeatedUseCount) * 0.04
		score += record.executionSuccessRate * 0.25

		if policy.dismissedLowersUsefulness {
			score -= Double(record.dismissedCount) * policy.dismissedPenalty
		}
		score -= Double(record.failedExecutionCount) * 0.1

		let daysSinceUse = now.timeIntervalSince(record.lastUsedAt) / 86_400
		score -= daysSinceUse * policy.usefulnessDecayPerDay

		return min(1.0, max(0.0, score))
	}

	static func reuseEligibility(
		record: ReusableGeneratedActionRecord,
		policy: GeneratedActionPersistencePolicy,
		now: Date
	) -> ReuseEligibility {
		if record.isExpired { return .notEligible }
		if record.failedExecutionCount >= policy.maxFailuresBeforeSuppression {
			return .suppressed
		}
		if !policy.failedActionsReusable && record.failedExecutionCount > record.successfulExecutionCount {
			return .notEligible
		}
		let score = usefulnessScore(record: record, policy: policy, now: now)
		let successRate = record.executionSuccessRate
		let acceptedEnough = record.acceptedCount >= policy.minAcceptedCountForReuse
		let repeatedEnough = record.repeatedUseCount >= 2 && record.successfulExecutionCount >= 2

		if score >= policy.minUsefulnessScore,
		   successRate >= policy.minExecutionSuccessRate,
		   (acceptedEnough || repeatedEnough)
		{
			return .eligible
		}
		return .notEligible
	}
}

/// Local-only persistence for reusable generated actions (actor-isolated; no UI).
actor GeneratedActionPersistenceManager {

	/// App-scoped singleton. Use this everywhere — do NOT create separate instances in live code.
	/// (T18.3.6: single shared store so template library and execution runtime see the same records.)
	static let shared = GeneratedActionPersistenceManager()

	private let store: GeneratedActionPersistenceStore
	private let policy: GeneratedActionPersistencePolicy
	private var recordsByTemplate: [String: ReusableGeneratedActionRecord] = [:]
	private var dirty = false
	private var loaded = false

	init(
		store: GeneratedActionPersistenceStore = LocalGeneratedActionPersistenceStore(),
		policy: GeneratedActionPersistencePolicy = .production
	) {
		self.store = store
		self.policy = policy
	}

	/// Inserts a pre-seeded record without triggering eligibility re-scoring.
	/// Idempotent: no-op if a record with the same `actionTemplateId` already exists.
	/// Returns `true` if the record was newly inserted.
	@discardableResult
	func insertSeedRecordIfMissing(_ record: ReusableGeneratedActionRecord) async -> Bool {
		await ensureLoaded()
		guard recordsByTemplate[record.actionTemplateId] == nil else { return false }
		recordsByTemplate[record.actionTemplateId] = record
		dirty = true
		await persistIfNeeded()
		return true
	}

	func record(_ event: GeneratedActionPersistenceEvent) async {
		await ensureLoaded()
		let templateId = event.actionTemplateId
		var record = recordsByTemplate[templateId] ?? makeSeedRecord(from: event)

		switch event.kind {
		case .proposed:
			break
		case .accepted:
			record.acceptedCount += 1
		case .dismissed:
			record.dismissedCount += 1
		case .executed:
			record.executedCount += 1
			record.lastUsedAt = event.timestamp
		case .executionSucceeded:
			record.successfulExecutionCount += 1
			record.lastUsedAt = event.timestamp
		case .executionFailed:
			record.failedExecutionCount += 1
			record.lastUsedAt = event.timestamp
		case .reused:
			record.repeatedUseCount += 1
			record.lastUsedAt = event.timestamp
		case .expired, .suppressed:
			recordsByTemplate.removeValue(forKey: templateId)
			dirty = true
			logPersistence(event: "record_removed", reason: event.kind.rawValue, templateId: templateId)
			await persistIfNeeded()
			return
		}

		record.lastUsedAt = event.timestamp
		record.expiresAt = event.timestamp.addingTimeInterval(policy.expirationInterval)
		record.usefulnessScore = GeneratedActionPersistenceScoring.usefulnessScore(
			record: record,
			policy: policy,
			now: event.timestamp
		)
		let previousEligibility = record.reuseEligibility
		record.reuseEligibility = GeneratedActionPersistenceScoring.reuseEligibility(
			record: record,
			policy: policy,
			now: event.timestamp
		)

		recordsByTemplate[templateId] = record
		pruneExpired(now: event.timestamp)
		enforceCap()
		dirty = true

		logPersistence(event: "persistence_event", reason: event.kind.rawValue, templateId: templateId)
		if previousEligibility != .eligible, record.reuseEligibility == .eligible {
			logPersistence(event: "reuse_eligible", reason: templateId, templateId: templateId)
		}
		await persistIfNeeded()
	}

	func recordSuccessfulExecution(
		action: GeneratedExecutionAction,
		result: ExecutionResult
	) async {
		await record(.from(kind: .executed, action: action, resultStatus: result.status))
		if GeneratedActionReuseConverter.isSuccessful(result.status) {
			await record(.from(kind: .executionSucceeded, action: action, resultStatus: result.status))
			await upsertFromSuccessfulExecution(action: action, result: result)
		} else {
			await record(.from(kind: .executionFailed, action: action, resultStatus: result.status))
		}
	}

	func upsertFromSuccessfulExecution(
		action: GeneratedExecutionAction,
		result: ExecutionResult
	) async {
		guard GeneratedActionReuseConverter.isSuccessful(result.status) else { return }
		guard action.isReusable || action.reuseScore >= policy.minUsefulnessScore else { return }

		await ensureLoaded()
		let signature = GeneratedActionPrimitiveSignature.from(action: action)
		let existing = recordsByTemplate[signature.signatureCode]
		let updated = GeneratedActionReuseConverter.upsertRecord(
			existing: existing,
			action: action,
			result: result,
			policy: policy
		)
		recordsByTemplate[signature.signatureCode] = updated
		pruneExpired()
		enforceCap()
		dirty = true
		await persistIfNeeded()
	}

	func reusableActions(
		for workflowType: WorkflowType,
		intentType: IntentType,
		availableContextTypes: [ContextRequirementType]
	) async -> [ReusableGeneratedActionRecord] {
		await ensureLoaded()
		pruneExpired()
		let available = Set(availableContextTypes)
		return recordsByTemplate.values
			.filter { $0.reuseEligibility == .eligible && !$0.isExpired }
			// A template with .unknown workflow is a generic/fallback — matches any query workflow.
			// A template with a specific workflow only matches the same query workflow.
			.filter { workflowType == .unknown || $0.workflowType == .unknown || $0.workflowType == workflowType }
			// Same logic for intent: .unknown template matches any intent.
			.filter { intentType == .unknown || $0.intentType == .unknown || $0.intentType == intentType }
			// Context: template requirements must be satisfiable by what's available, or template needs nothing.
			.filter { record in
				let required = Set(record.requiredContextTypes.filter { $0 != .none })
				return required.isSubset(of: available) || required.isEmpty
			}
			.sorted { $0.usefulnessScore > $1.usefulnessScore }
	}

	func snapshot() async -> [ReusableGeneratedActionRecord] {
		await ensureLoaded()
		pruneExpired()
		return Array(recordsByTemplate.values)
	}

	func clear() async {
		recordsByTemplate = [:]
		dirty = true
		try? await store.clearAll()
		dirty = false
	}

	// MARK: - Internals

	private func ensureLoaded() async {
		guard !loaded else { return }
		let loadedRecords = await store.loadRecords()
		recordsByTemplate = Dictionary(uniqueKeysWithValues: loadedRecords.map { ($0.actionTemplateId, $0) })
		loaded = true
		pruneExpired()
		enforceCap()
	}

	private func persistIfNeeded() async {
		guard dirty else { return }
		do {
			try await store.saveRecords(Array(recordsByTemplate.values))
			dirty = false
		} catch {
			logPersistence(event: "persistence_write_failed", reason: "save", templateId: nil)
		}
	}

	private func makeSeedRecord(from event: GeneratedActionPersistenceEvent) -> ReusableGeneratedActionRecord {
		ReusableGeneratedActionRecord(
			actionTemplateId: event.actionTemplateId,
			title: "Reusable action",
			description: "Reusable generated execution template",
			workflowType: event.workflowType,
			intentType: event.intentType,
			primitiveSignature: event.primitiveSignature,
			requiredContextTypes: [],
			createdAt: event.timestamp,
			lastUsedAt: event.timestamp,
			expiresAt: event.timestamp.addingTimeInterval(policy.expirationInterval)
		)
	}

	private func pruneExpired(now: Date = Date()) {
		let expiredKeys = recordsByTemplate.filter { $0.value.isExpired || $0.value.expiresAt < now }.map(\.key)
		for key in expiredKeys {
			recordsByTemplate.removeValue(forKey: key)
			logPersistence(event: "record_expired", reason: key, templateId: key)
		}
		if !expiredKeys.isEmpty { dirty = true }
	}

	private func enforceCap() {
		guard recordsByTemplate.count > policy.maxStoredRecords else { return }
		let sorted = recordsByTemplate.values.sorted { lhs, rhs in
			if lhs.usefulnessScore != rhs.usefulnessScore { return lhs.usefulnessScore < rhs.usefulnessScore }
			return lhs.lastUsedAt < rhs.lastUsedAt
		}
		let overflow = recordsByTemplate.count - policy.maxStoredRecords
		for record in sorted.prefix(overflow) {
			recordsByTemplate.removeValue(forKey: record.actionTemplateId)
		}
		dirty = true
	}

	private func logPersistence(event: String, reason: String?, templateId: String?) {
		var meta = IntelligenceDebugMeta(
			reason: reason,
			layer: "generated_action_persistence",
			detail: event
		)
		if let templateId {
			meta.fp = String(templateId.prefix(12))
		}
		meta.actions = recordsByTemplate.count
		IntelligenceDebugLogger.log(stage: .execution, event: event, meta: meta)
	}
}

// MARK: - Self-test

extension GeneratedActionPersistenceManager {
	static func runSelfTest() async -> Bool {
		let store = InMemoryGeneratedActionPersistenceStore()
		let manager = GeneratedActionPersistenceManager(store: store, policy: .strictTest)
		let action = PersistenceSelfTestFixtures.action(reuseScore: 0.7, isReusable: true)
		let success = PersistenceSelfTestFixtures.result(action: action, status: .success)

		await manager.record(.from(kind: .accepted, action: action))
		await manager.recordSuccessfulExecution(action: action, result: success)
		await manager.recordSuccessfulExecution(action: action, result: success)

		let snap = await manager.snapshot()
		guard let record = snap.first, record.acceptedCount >= 1, record.executedCount >= 2 else { return false }
		guard record.successfulExecutionCount >= 2 else { return false }

		let encoded = try? JSONEncoder().encode(record)
		let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
		guard !json.contains("generatedContent"), !json.contains("clipboard") else { return false }

		await manager.record(.from(kind: .dismissed, action: action))
		let afterDismiss = await manager.snapshot().first
		guard let afterDismiss, afterDismiss.usefulnessScore <= record.usefulnessScore else { return false }

		let failManager = GeneratedActionPersistenceManager(store: store, policy: .strictTest)
		let failAction = PersistenceSelfTestFixtures.action(reuseScore: 0.2, isReusable: false)
		for _ in 0..<3 {
			await failManager.recordSuccessfulExecution(
				action: failAction,
				result: PersistenceSelfTestFixtures.result(action: failAction, status: .failed)
			)
		}
		let failedRecord = await failManager.snapshot().first
		guard failedRecord?.reuseEligibility != .eligible else { return false }

		let capManager = GeneratedActionPersistenceManager(
			store: InMemoryGeneratedActionPersistenceStore(),
			policy: GeneratedActionPersistencePolicy(
				maxStoredRecords: 2,
				expirationInterval: 3600,
				minAcceptedCountForReuse: 1,
				minExecutionSuccessRate: 0.5,
				minUsefulnessScore: 0.4,
				maxFailuresBeforeSuppression: 5,
				usefulnessDecayPerDay: 0,
				failedActionsReusable: false,
				dismissedLowersUsefulness: true,
				dismissedPenalty: 0.05
			)
		)
		for i in 0..<4 {
			let a = PersistenceSelfTestFixtures.action(title: "A\(i)", reuseScore: 0.8, isReusable: true)
			await capManager.record(.from(kind: .accepted, action: a))
		}
		guard await capManager.snapshot().count <= 2 else { return false }

		let expiredStore = InMemoryGeneratedActionPersistenceStore(
			records: [
				ReusableGeneratedActionRecord(
					actionTemplateId: "expired|sig",
					title: "Old",
					description: "Old",
					workflowType: .unknown,
					intentType: .unknown,
					primitiveSignature: "expired|sig",
					requiredContextTypes: [],
					createdAt: Date().addingTimeInterval(-120),
					lastUsedAt: Date().addingTimeInterval(-120),
					expiresAt: Date().addingTimeInterval(-10)
				),
			]
		)
		let expiredManager = GeneratedActionPersistenceManager(store: expiredStore, policy: .strictTest)
		_ = await expiredManager.snapshot()
		guard await expiredManager.snapshot().isEmpty else { return false }

		let failingStore = InMemoryGeneratedActionPersistenceStore(shouldFailSave: true)
		let failWriteManager = GeneratedActionPersistenceManager(store: failingStore, policy: .strictTest)
		await failWriteManager.record(.from(kind: .accepted, action: action))
		// Should not crash

		let runtime = GeneratedExecutionRuntime(
			contextProvider: StaticGeneratedExecutionContextProvider(packet: PersistenceSelfTestFixtures.context()),
			persistenceManager: failWriteManager
		)
		let runtimeOutcome = await runtime.start(action: action)
		guard case .completed = runtimeOutcome else { return false }

		return true
	}
}

private enum PersistenceSelfTestFixtures {
	static func context() -> GeneratedExecutionContext {
		let now = Date()
		return GeneratedExecutionContext(
			sourceType: "self_test",
			appName: "Contextual",
			windowTitle: "Test",
			workflowType: .writing,
			intentType: .summarize,
			selectedTextExcerpt: "sample",
			availableContextTypes: [.textSnippet],
			createdAt: now,
			expirationDate: now.addingTimeInterval(120)
		)
	}

	static func action(title: String = "Test", reuseScore: Double, isReusable: Bool) -> GeneratedExecutionAction {
		let plan = ExecutionPlan(
			primitives: [.summarizeContext],
			estimatedCost: 0.2,
			estimatedRuntime: 10,
			requiresVision: false,
			requiresOCR: false,
			requiresUserIntent: false,
			requiredPermissions: [.none],
			fallbackBehavior: .failFast,
			executionBudget: .conservative,
			planConfidence: 0.6
		)
		let now = Date()
		return GeneratedExecutionAction(
			title: title,
			description: "Persistence test",
			workflowType: .writing,
			intentType: .summarize,
			confidence: 0.7,
			interruptionCost: 0.1,
			requiredContextTypes: [.textSnippet],
			executionPlan: plan,
			explainabilitySummary: "test",
			generationSource: .selfTest,
			createdAt: now,
			expirationDate: now.addingTimeInterval(300),
			isReusable: isReusable,
			reuseScore: reuseScore
		)
	}

	static func result(action: GeneratedExecutionAction, status: ExecutionResultStatus) -> ExecutionResult {
		ExecutionResult(
			actionId: action.id,
			status: status,
			startedAt: Date(),
			completedAt: Date(),
			generatedContent: "SECRET CONTENT MUST NOT PERSIST",
			generatedSections: [],
			warnings: [],
			executionMetadata: [:],
			confidence: 0.7,
			followUpSuggestions: []
		)
	}
}
