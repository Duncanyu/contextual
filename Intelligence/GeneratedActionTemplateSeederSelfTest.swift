import Foundation

/// T18.3.6 — GeneratedActionTemplateSeeder + PrewarmConsumer self-tests.
/// Verifies seeding idempotency, shared manager wiring, library retrieval on seeded data,
/// prewarm consumer deterministic path, and live proposal path isolation.
/// Not wired to launch; run via self-test harness only.
enum GeneratedActionTemplateSeederSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()

		// MARK: 1 — seedIfNeeded inserts templates

		let store1 = InMemoryGeneratedActionPersistenceStore(records: [])
		let manager1 = GeneratedActionPersistenceManager(store: store1, policy: .strictTest)
		let seeder1 = GeneratedActionTemplateSeeder()
		await seeder1.seedIfNeeded(into: manager1, referenceTime: now)
		let all1 = await manager1.snapshot()
		check("seed_inserts_templates", all1.count > 0)
		check("seed_inserts_at_least_ten", all1.count >= 10)

		// MARK: 2 — Second seed call does NOT duplicate

		let countBefore = all1.count
		await seeder1.seedIfNeeded(into: manager1, referenceTime: now)
		let all2 = await manager1.snapshot()
		check("seed_idempotent_no_duplicates", all2.count == countBefore)

		// MARK: 3 — All seeded templates start eligible

		let allEligible = all1.allSatisfy { $0.reuseEligibility == .eligible }
		check("seeded_templates_all_eligible", allEligible)

		// MARK: 4 — GeneratedActionTemplateLibrary.shared uses GeneratedActionPersistenceManager.shared

		// Verify that seeding .shared manager makes templates visible to the library
		let sharedManager = GeneratedActionPersistenceManager.shared
		let freshSeeder = GeneratedActionTemplateSeeder()
		await freshSeeder.seedIfNeeded(into: sharedManager, referenceTime: now)
		let sharedAll = await sharedManager.snapshot()
		check("shared_manager_sees_seeds", !sharedAll.isEmpty)

		// MARK: 5 — Debugging workflow retrieves debugging template

		let debugWorkflow = WorkflowType.debugging
		let debugResults = await manager1.reusableActions(
			for: debugWorkflow,
			intentType: .unknown,
			availableContextTypes: [.selectedText, .errorContext, .workflowContext]
		)
		check("debugging_retrieves_template", !debugResults.isEmpty)
		check("debugging_template_eligible", debugResults.first?.reuseEligibility == .eligible)
		let debugTitle = debugResults.first?.title.lowercased() ?? ""
		check("debugging_template_not_summarize", !debugTitle.hasPrefix("summarize"))
		check("debugging_template_not_explain_generic", !debugTitle.hasPrefix("explain selected"))

		// MARK: 6 — Research workflow retrieves research template

		let researchResults = await manager1.reusableActions(
			for: .research,
			intentType: .unknown,
			availableContextTypes: [.workflowContext]
		)
		check("research_retrieves_template", !researchResults.isEmpty)

		// MARK: 7 — Browsing workflow retrieves browsing template

		let browsingResults = await manager1.reusableActions(
			for: .browsing,
			intentType: .unknown,
			availableContextTypes: [.workflowContext]
		)
		check("browsing_retrieves_template", !browsingResults.isEmpty)

		// MARK: 8 — Unknown workflow can retrieve generic fallback template

		let genericResults = await manager1.reusableActions(
			for: .unknown,
			intentType: .unknown,
			availableContextTypes: [.none]
		)
		check("unknown_workflow_retrieves_fallback", !genericResults.isEmpty)

		// MARK: 9 — Specific workflow also returns .unknown templates (workflow-agnostic matches)

		let debugPlusGeneric = await manager1.reusableActions(
			for: .debugging,
			intentType: .unknown,
			availableContextTypes: [.workflowContext, .errorContext]
		)
		// Should include both debugging-specific AND generic (.unknown workflow) templates
		let hasGeneric = debugPlusGeneric.contains { $0.workflowType == .unknown }
		check("specific_workflow_also_returns_generic", hasGeneric)

		// MARK: 10 — Prewarm consumer creates deterministic template from request

		let prewarmQueue = GeneratedActionTemplatePrewarmQueue(maxPending: 5)
		let prewarmManager = GeneratedActionPersistenceManager(store: InMemoryGeneratedActionPersistenceStore(records: []), policy: .strictTest)
		let prewarmSeeder = GeneratedActionTemplateSeeder()

		let req = GeneratedActionTemplatePrewarmRequest(
			workflowType: .debugging,
			intentType: .explain,
			availableContextTypes: [.selectedText, .errorContext],
			missReason: .noMatchForContext,
			appName: "Xcode",
			decisionConfidence: 0.8
		)
		await prewarmQueue.enqueue(req)
		check("prewarm_queue_has_item", await prewarmQueue.pendingCount == 1)

		let consumer = GeneratedActionTemplatePrewarmConsumer()
		await consumer.consume(
			from: prewarmQueue,
			seeder: prewarmSeeder,
			manager: prewarmManager,
			referenceTime: now
		)
		check("prewarm_queue_drained", await prewarmQueue.pendingCount == 0)
		let prewarmAll = await prewarmManager.snapshot()
		check("prewarm_created_template", !prewarmAll.isEmpty)

		// MARK: 11 — Prewarm consumer skips already-satisfied requests

		let satisfiedManager = GeneratedActionPersistenceManager(store: InMemoryGeneratedActionPersistenceStore(records: []), policy: .strictTest)
		let satisfiedSeeder = GeneratedActionTemplateSeeder()
		await satisfiedSeeder.seedIfNeeded(into: satisfiedManager, referenceTime: now)
		let satisfiedQueue = GeneratedActionTemplatePrewarmQueue(maxPending: 5)
		await satisfiedQueue.enqueue(req) // same request for .debugging

		let satisfiedConsumer = GeneratedActionTemplatePrewarmConsumer()
		await satisfiedConsumer.consume(
			from: satisfiedQueue,
			seeder: satisfiedSeeder,
			manager: satisfiedManager,
			referenceTime: now
		)
		// Queue should be drained; no duplicates added
		let satisfiedAll = await satisfiedManager.snapshot()
		check("prewarm_no_duplicate_when_satisfied", await satisfiedQueue.pendingCount == 0)
		let debugOnlyCount = satisfiedAll.filter { $0.workflowType == .debugging }.count
		check("prewarm_no_extra_debug_templates", debugOnlyCount <= 3) // seeder provides ~3 debug templates

		// MARK: 12 — Live proposal path returns libraryRecords without LocalAI call

		// Re-use the seeded manager1 which now has templates.
		// Build a stub library over manager1 and a stub engine.
		let stubLibrary = SeederSelfTestStubLibrary(manager: manager1)
		let countingClient = SeederSelfTestCountingLLMClient()
		let engine = DynamicGeneratedProposalEngine(
			modelManager: SeederSelfTestAlwaysAvailableGate(),
			client: countingClient,
			decisionEngine: SeederSelfTestAlwaysThinkDecision(),
			templateLibrary: stubLibrary,
			timeoutSeconds: 2
		)
		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Xcode",
			inferredWorkflow: .debugging,
			selectedText: "error: null pointer",
			workflowConfidence: 0.8,
			generatedAt: now,
			freshnessScore: 0.85
		)
		let result = await engine.generateProposals(
			snapshot: snap,
			existingStaticActions: [],
			reusableActions: []
		)
		check("live_path_no_llm_call", countingClient.callCount == 0)
		check("live_path_status_synthesized", result.status == .synthesized)
		check("live_path_library_records_populated", !result.libraryRecords.isEmpty)
		check("live_path_should_chime", result.shouldChimeIn)

		let ok = failures.isEmpty
		print("[TemplateSeederSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}

// MARK: - Stubs

/// Wraps a real manager for library lookups (uses shared retrieve logic via GeneratedActionTemplateLibrary).
private struct SeederSelfTestStubLibrary: GeneratedActionTemplateLibraryProviding {
	let manager: GeneratedActionPersistenceManager

	func retrieve(
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) async -> GeneratedActionTemplateLibraryResult {
		let workflowType = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
		let intentType = situational.inferredIntent.map { WorkflowExecutionMapper.intentType(from: $0) } ?? .unknown
		var contextTypes: [ContextRequirementType] = []
		if situational.selectedTextSignal.availability == .available {
			contextTypes += [.textSnippet, .selectedText]
		}
		contextTypes += [.workflowContext, .errorContext]

		let matches = await manager.reusableActions(
			for: workflowType,
			intentType: intentType,
			availableContextTypes: contextTypes
		)
		return matches.isEmpty ? .empty(reason: .noMatchForContext) : .found(matches)
	}

	func enqueuePrewarm(
		situational: SituationalContextSnapshot,
		decision: AgenticProposalDecision,
		referenceTime: Date
	) async {}
}

private final class SeederSelfTestCountingLLMClient: DynamicGeneratedProposalLLMGenerating, @unchecked Sendable {
	private(set) var callCount = 0
	func generate(prompt: String, model: String) async throws -> String {
		callCount += 1
		return "{}"
	}
}

private struct SeederSelfTestAlwaysAvailableGate: DynamicGeneratedProposalAvailabilityChecking {
	func isGenerationAvailable() async -> Bool { true }
}

private struct SeederSelfTestAlwaysThinkDecision: AgenticProposalDeciding {
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
			confidence: 0.85,
			interruptionCost: 0.2,
			reason: "test_always_think",
			decisionSource: .heuristic
		)
	}
	func recordTimeout(fingerprint: String, at time: Date) async {}
}
