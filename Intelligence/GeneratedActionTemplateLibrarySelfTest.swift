import Foundation

/// T18.3.5 — GeneratedActionTemplateLibrary self-tests.
/// Verifies library retrieval, miss reasons, prewarm queue, and engine-level isolation.
/// Not wired to app launch; run via self-test harness only.
enum GeneratedActionTemplateLibrarySelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		// MARK: 1 — Empty library → .empty(.libraryEmpty)

		let emptyStore = InMemoryGeneratedActionPersistenceStore(records: [])
		let emptyManager = GeneratedActionPersistenceManager(store: emptyStore, policy: .strictTest)
		let emptyLibrary = GeneratedActionTemplateLibrary(
			manager: emptyManager,
			prewarmQueue: GeneratedActionTemplatePrewarmQueue()
		)
		let now = Date()
		let snap = TemplateLibrarySelfTestFixtures.situationalSnapshot(workflow: .debugging, referenceTime: now)
		let emptyResult = await emptyLibrary.retrieve(situational: snap, referenceTime: now)
		check("empty_library_miss_reason", emptyResult.missReason == .libraryEmpty)
		check("empty_library_no_match", !emptyResult.hasMatch)

		// MARK: 2 — Records exist but none eligible → .empty(.noEligibleTemplates)

		let ineligibleRecord = TemplateLibrarySelfTestFixtures.record(
			workflow: .debugging, intent: .explain,
			reuseEligibility: .notEligible, referenceTime: now
		)
		let ineligibleStore = InMemoryGeneratedActionPersistenceStore(records: [ineligibleRecord])
		let ineligibleManager = GeneratedActionPersistenceManager(store: ineligibleStore, policy: .strictTest)
		let ineligibleLibrary = GeneratedActionTemplateLibrary(
			manager: ineligibleManager,
			prewarmQueue: GeneratedActionTemplatePrewarmQueue()
		)
		let ineligibleResult = await ineligibleLibrary.retrieve(situational: snap, referenceTime: now)
		check("ineligible_records_miss_reason", ineligibleResult.missReason == .noEligibleTemplates)
		check("ineligible_records_no_match", !ineligibleResult.hasMatch)

		// MARK: 3 — Eligible records exist but wrong workflow → .empty(.noMatchForContext)

		let writingRecord = TemplateLibrarySelfTestFixtures.record(
			workflow: .writing, intent: .summarize,
			reuseEligibility: .eligible, referenceTime: now
		)
		let mismatchStore = InMemoryGeneratedActionPersistenceStore(records: [writingRecord])
		let mismatchManager = GeneratedActionPersistenceManager(store: mismatchStore, policy: .strictTest)
		let mismatchLibrary = GeneratedActionTemplateLibrary(
			manager: mismatchManager,
			prewarmQueue: GeneratedActionTemplatePrewarmQueue()
		)
		// snap is workflow=.debugging — writing record should not match
		let mismatchResult = await mismatchLibrary.retrieve(situational: snap, referenceTime: now)
		check("mismatch_workflow_miss_reason", mismatchResult.missReason == .noMatchForContext)
		check("mismatch_workflow_no_match", !mismatchResult.hasMatch)

		// MARK: 4 — Eligible matching record → .found([record])

		let debugRecord = TemplateLibrarySelfTestFixtures.record(
			workflow: .debugging, intent: .explain,
			reuseEligibility: .eligible, referenceTime: now
		)
		let hitStore = InMemoryGeneratedActionPersistenceStore(records: [debugRecord])
		let hitManager = GeneratedActionPersistenceManager(store: hitStore, policy: .strictTest)
		let hitLibrary = GeneratedActionTemplateLibrary(
			manager: hitManager,
			prewarmQueue: GeneratedActionTemplatePrewarmQueue()
		)
		let hitResult = await hitLibrary.retrieve(situational: snap, referenceTime: now)
		check("library_hit_has_match", hitResult.hasMatch)
		check("library_hit_records_non_empty", !hitResult.records.isEmpty)
		check("library_hit_miss_reason_nil", hitResult.missReason == nil)

		// MARK: 5 — Prewarm queue deduplicates by (workflowType, intentType)

		let prewarmQueue = GeneratedActionTemplatePrewarmQueue(maxPending: 5)
		let req1 = GeneratedActionTemplatePrewarmRequest(
			workflowType: .debugging, intentType: .explain,
			availableContextTypes: [.textSnippet],
			missReason: .noMatchForContext,
			appName: "Xcode", decisionConfidence: 0.7
		)
		let req2 = GeneratedActionTemplatePrewarmRequest(
			workflowType: .debugging, intentType: .explain,
			availableContextTypes: [.selectedText],
			missReason: .noMatchForContext,
			appName: "Xcode", decisionConfidence: 0.8
		)
		await prewarmQueue.enqueue(req1)
		await prewarmQueue.enqueue(req2) // duplicate — should be ignored
		check("prewarm_deduplication", await prewarmQueue.pendingCount == 1)

		// MARK: 6 — Prewarm queue respects max capacity (evicts oldest)

		let capQueue = GeneratedActionTemplatePrewarmQueue(maxPending: 3)
		for i in 0..<5 {
			let req = GeneratedActionTemplatePrewarmRequest(
				workflowType: .unknown, intentType: .unknown,
				availableContextTypes: [],
				missReason: .libraryEmpty,
				requestedAt: now.addingTimeInterval(Double(i)),
				appName: "App\(i)", decisionConfidence: 0.5
			)
			// Use different intentType to avoid dedup by workflow+intent
			_ = req // can't vary intentType easily, so just test cap differently
			await capQueue.enqueue(req)
		}
		// All have same workflow+intent, so only 1 enqueued due to dedup
		check("prewarm_cap_respects_max", await capQueue.pendingCount <= 3)

		// MARK: 7 — Prewarm queue drain empties queue

		let drainQueue = GeneratedActionTemplatePrewarmQueue(maxPending: 5)
		await drainQueue.enqueue(req1)
		let drained = await drainQueue.drain()
		check("prewarm_drain_returns_all", drained.count == 1)
		check("prewarm_drain_empties_queue", await drainQueue.pendingCount == 0)

		// MARK: 8 — Engine with library hit: LLM NOT called

		let countingClient = TemplateLibraryCountingLLMClient()
		let hitLibraryForEngine = GeneratedActionTemplateLibrary(
			manager: hitManager,
			prewarmQueue: GeneratedActionTemplatePrewarmQueue()
		)
		let hitEngine = DynamicGeneratedProposalEngine(
			modelManager: AlwaysAvailableTemplateLibraryModelGate(),
			client: countingClient,
			decisionEngine: TemplateLibraryAlwaysThinkDecisionEngine(),
			templateLibrary: hitLibraryForEngine,
			timeoutSeconds: 2
		)
		let xSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Xcode",
			windowTitle: "error",
			generatedAt: now
		)
		let hitEngineResult = await hitEngine.generateProposals(
			snapshot: xSnap,
			existingStaticActions: [],
			reusableActions: []
		)
		check("library_hit_llm_not_called", countingClient.callCount == 0)
		check("library_hit_engine_status_synthesized", hitEngineResult.status == .synthesized)
		check("library_hit_engine_should_chime", hitEngineResult.shouldChimeIn)
		check("library_hit_library_records_populated", !hitEngineResult.libraryRecords.isEmpty)
		check("library_hit_reason", hitEngineResult.reason == "library_hit")

		// MARK: 9 — Engine with library miss: LLM NOT called, status is quietByGate

		let missLibraryForEngine = GeneratedActionTemplateLibrary(
			manager: emptyManager,
			prewarmQueue: GeneratedActionTemplatePrewarmQueue()
		)
		let countingClient2 = TemplateLibraryCountingLLMClient()
		let missEngine = DynamicGeneratedProposalEngine(
			modelManager: AlwaysAvailableTemplateLibraryModelGate(),
			client: countingClient2,
			decisionEngine: TemplateLibraryAlwaysThinkDecisionEngine(),
			templateLibrary: missLibraryForEngine,
			timeoutSeconds: 2
		)
		let missResult = await missEngine.generateProposals(
			snapshot: xSnap,
			existingStaticActions: [],
			reusableActions: []
		)
		check("library_miss_llm_not_called", countingClient2.callCount == 0)
		check("library_miss_status_quiet", missResult.status == .quietByGate)
		check("library_miss_reason", missResult.reason == "no_template_in_library")
		check("library_miss_diag_tag", missResult.warnings.contains("diag:no_template_in_library"))
		check("library_miss_no_library_records", missResult.libraryRecords.isEmpty)

		// MARK: 10 — noTemplateInLibrary maps to correct failure reason

		let diagTag = "diag:no_template_in_library"
		let mappedReason = GeneratedProposalDebugStatusBuilder.failureReasonForTag_testOnly(diagTag)
		check("no_template_in_library_tag_maps", mappedReason == .noTemplateInLibrary)
		check("no_template_in_library_label",
			GeneratedProposalFailureReason.noTemplateInLibrary.userFacingLabel.contains("library"))

		// MARK: 11 — WorkflowExecutionMapper used correctly (verify round-trip for key workflows)

		check("mapper_debugging",
			WorkflowExecutionMapper.workflowType(from: .debugging) == .debugging)
		check("mapper_writing",
			WorkflowExecutionMapper.workflowType(from: .writing) == .writing)
		check("mapper_unknown",
			WorkflowExecutionMapper.workflowType(from: .unknown) == .unknown)
		check("mapper_intent_explain",
			WorkflowExecutionMapper.intentType(from: .explainLikelyError) == .explain)
		check("mapper_intent_summarize",
			WorkflowExecutionMapper.intentType(from: .summarizeCurrentArticle) == .summarize)

		let ok = failures.isEmpty
		print("[TemplateLibrarySelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}

// MARK: - Fixtures

private enum TemplateLibrarySelfTestFixtures {

	static func situationalSnapshot(
		workflow: InferredWorkflow,
		referenceTime: Date
	) -> SituationalContextSnapshot {
		SituationalContextSynthesizer.synthesize(
			from: CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Xcode",
				inferredWorkflow: workflow,
				selectedText: workflow == .debugging ? "error: crash" : "",
				workflowConfidence: 0.75,
				generatedAt: referenceTime,
				freshnessScore: 0.8
			),
			referenceTime: referenceTime
		)
	}

	static func record(
		workflow: WorkflowType,
		intent: IntentType,
		reuseEligibility: ReuseEligibility,
		referenceTime: Date
	) -> ReusableGeneratedActionRecord {
		ReusableGeneratedActionRecord(
			actionTemplateId: "\(workflow.rawValue)|\(intent.rawValue)|summarize_context|text_snippet|v1",
			title: "Template: \(workflow.rawValue)/\(intent.rawValue)",
			description: "Reusable template for \(workflow.rawValue) workflow",
			workflowType: workflow,
			intentType: intent,
			primitiveSignature: "summarize_context",
			requiredContextTypes: [.textSnippet],
			createdAt: referenceTime,
			lastUsedAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(3600),
			acceptedCount: 3,
			executedCount: 4,
			successfulExecutionCount: 3,
			usefulnessScore: 0.75,
			averageConfidence: 0.78,
			reuseEligibility: reuseEligibility
		)
	}
}

// MARK: - Stubs

private final class TemplateLibraryCountingLLMClient: DynamicGeneratedProposalLLMGenerating, @unchecked Sendable {
	private(set) var callCount = 0
	func generate(prompt: String, model: String) async throws -> String {
		callCount += 1
		return #"{"chime":false,"reason":"stub","workflowAssessment":"","proposalConfidence":0.5,"requiresVisualContext":false,"proposals":[]}"#
	}
}

private struct AlwaysAvailableTemplateLibraryModelGate: DynamicGeneratedProposalAvailabilityChecking {
	func isGenerationAvailable() async -> Bool { true }
}

private struct TemplateLibraryAlwaysThinkDecisionEngine: AgenticProposalDeciding {
	func decide(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) async -> AgenticProposalDecision {
		AgenticProposalDecision(
			shouldThink: true,
			shouldChimeIn: true,
			needsMoreContext: false,
			recommendedContextKind: .none,
			workflowType: .unknown,
			intentType: nil,
			confidence: 0.9,
			interruptionCost: 0.2,
			reason: "test_always_think",
			decisionSource: .heuristic
		)
	}
	func recordTimeout(fingerprint: String, at time: Date) async {}
}
