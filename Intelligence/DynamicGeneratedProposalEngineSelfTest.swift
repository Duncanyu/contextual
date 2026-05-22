import Foundation

/// T18.3.1 LLM proposal engine self-tests (no live model; not wired to launch).
enum DynamicGeneratedProposalEngineSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()

		let validJSON = """
		{
		  "shouldChimeIn": true,
		  "reason": "context supports diagnosis",
		  "workflowAssessment": "debugging with log signals",
		  "proposalConfidence": 0.82,
		  "requiresVisualContext": false,
		  "proposals": [
		    {
		      "title": "Trace which context source dominates proposal generation",
		      "description": "Compare fused vs selection weighting in the activation path",
		      "intentType": "explain",
		      "workflowType": "debugging",
		      "expectedOutcome": "Ranked list of dominant context channels with confidence bands",
		      "requiredContextTypes": ["text_snippet"],
		      "suggestedPrimitives": ["answer_from_context", "classify_workflow"],
		      "interruptionCost": 0.22,
		      "confidence": 0.8
		    }
		  ]
		}
		"""

		guard let parsed = DynamicGeneratedProposalParser.parse(from: validJSON) else {
			check("valid_json_parses", false)
			let ok = failures.isEmpty
			print("[DynamicGeneratedProposal] selftest ok=\(ok) failures=\(failures.joined(separator: ";"))")
			return ok
		}
		check("valid_json_parses", parsed.shouldChimeIn && parsed.proposals.count == 1)
		check(
			"not_generic_template",
			!DynamicGeneratedProposalParser.isGenericStaticParaphrase(
				title: parsed.proposals[0].title,
				description: parsed.proposals[0].description
			)
		)

		check("malformed_json_rejected", DynamicGeneratedProposalParser.parse(from: "not json at all") == nil)

		let genericJSON = """
		{"shouldChimeIn":true,"reason":"x","workflowAssessment":"x","proposalConfidence":0.9,"requiresVisualContext":false,"proposals":[{"title":"Summarize selected text","description":"Quick summary","intentType":"summarize","workflowType":"writing","expectedOutcome":"summary","requiredContextTypes":["text_snippet"],"suggestedPrimitives":["summarize_context"],"interruptionCost":0.1,"confidence":0.9}]}
		"""
		let genericParsed = DynamicGeneratedProposalParser.parse(from: genericJSON)
		check(
			"generic_template_suppressed",
			genericParsed?.proposals.isEmpty == true || genericParsed?.shouldChimeIn == false
		)

		let unknownPrimitiveJSON = """
		{"shouldChimeIn":true,"reason":"x","workflowAssessment":"x","proposalConfidence":0.9,"requiresVisualContext":false,"proposals":[{"title":"Audit fusion arbitration drift","description":"Check stale packet handling","intentType":"explain","workflowType":"debugging","expectedOutcome":"report","requiredContextTypes":["text_snippet"],"suggestedPrimitives":["run_shell","delete_files"],"interruptionCost":0.2,"confidence":0.8}]}
		"""
		check(
			"unknown_primitive_rejected",
			DynamicGeneratedProposalParser.parse(from: unknownPrimitiveJSON)?.proposals.isEmpty == true
		)

		let lowConfJSON = """
		{"shouldChimeIn":true,"reason":"x","workflowAssessment":"x","proposalConfidence":0.9,"requiresVisualContext":false,"proposals":[{"title":"Audit fusion arbitration drift","description":"Check stale packet handling","intentType":"explain","workflowType":"debugging","expectedOutcome":"report","requiredContextTypes":["text_snippet"],"suggestedPrimitives":["answer_from_context"],"interruptionCost":0.2,"confidence":0.2}]}
		"""
		check(
			"low_confidence_suppressed",
			DynamicGeneratedProposalParser.parse(from: lowConfJSON)?.proposals.isEmpty == true
		)

		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Xcode",
			inferredWorkflow: .debugging,
			selectedText: "error: connection reset",
			workflowConfidence: 0.7,
			generatedAt: Date(),
			freshnessScore: 0.75
		)
		let mapped = DynamicGeneratedProposalCandidateMapper.candidates(
			from: parsed,
			snapshot: snap,
			budget: .conservative
		)
		check("mapper_produces_candidates", mapped.count == 1)
		check("mapper_not_static_summarize", !mapped[0].title.lowercased().hasPrefix("summarize selected"))

		let staticActivation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [SummarizeAction.summarizeTextId],
				staticRelevanceScores: [
					ActionRelevanceScore(actionId: SummarizeAction.summarizeTextId, score: 0.9, reason: "test"),
				],
				generatedActions: [],
				generatedExecutionCandidates: mapped,
				snapshot: snap,
				useLLMGeneratedCandidatesOnly: true,
				suppressStaticProposalFallback: true
			)
		)
		check(
			"llm_can_outrank_when_strong",
			staticActivation.visibleProposals.first?.title.contains("Trace") == true
				|| staticActivation.topSourceType == .executableGenerated
		)

		let weakSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Notes",
			inferredWorkflow: .unknown,
			generatedAt: Date(),
			freshnessScore: 0.15,
			packetIsStale: true
		)
		let weakLLM = DynamicGeneratedProposalResult(
			status: .synthesized,
			shouldChimeIn: true,
			reason: "test",
			workflowAssessment: "",
			proposalConfidence: 0.3,
			requiresVisualContext: false,
			proposals: parsed.proposals,
			warnings: [],
			llmDiagnosticCause: nil,
			createdAt: Date(),
			libraryRecords: [],
			hookContracts: []
		)
		let weakMapped = DynamicGeneratedProposalCandidateMapper.candidates(
			from: weakLLM,
			snapshot: weakSnap,
			budget: .conservative
		)
		let weakActivation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [SummarizeAction.summarizeTextId],
				generatedExecutionCandidates: weakMapped,
				snapshot: weakSnap,
				useLLMGeneratedCandidatesOnly: true,
				suppressStaticProposalFallback: true
			)
		)
		check("weak_context_suppresses_generated", weakActivation.visibleProposals.isEmpty)

		let stubEngine = DynamicGeneratedProposalEngine(
			modelManager: AlwaysAvailableProposalModelGate(),
			client: StubDynamicProposalLLMClient(response: validJSON),
			timeoutSeconds: 2
		)
		let engineResult = await stubEngine.generateProposals(
			snapshot: snap,
			existingStaticActions: [SummarizeAction.summarizeTextId],
			reusableActions: []
		)
		check("stub_engine_synthesizes", engineResult.status == .synthesized && engineResult.proposals.count == 1)

		let timeoutEngine = DynamicGeneratedProposalEngine(
			modelManager: AlwaysAvailableProposalModelGate(),
			client: SlowDynamicProposalLLMClient(),
			timeoutSeconds: 0.05
		)
		let timeoutResult = await timeoutEngine.generateProposals(
			snapshot: snap,
			existingStaticActions: [],
			reusableActions: []
		)
		check("timeout_fallback", timeoutResult.status == .timeout)

		// MARK: T18.3.7B — Auto visual gather is bounded (at most once per context window)

		let visualScheduler = CountingVisualContextScheduler(
			result: BoundedVisualContextResult(
				requestId: UUID(),
				status: .completed,
				capturedAt: now,
				sourceSummary: "selftest",
				ocrExcerpt: "visible: youtube",
				visualSummary: "A page with a video player and sidebar",
				visualTags: ["video", "player"],
				warnings: [],
				metadata: ["captureCount": "1"],
				expiresAt: now.addingTimeInterval(8)
			)
		)
		let missLibrary = AlwaysMissTemplateLibrary()
		let autoVisualEngine = DynamicGeneratedProposalEngine(
			modelManager: AlwaysAvailableProposalModelGate(),
			client: StubDynamicProposalLLMClient(response: validJSON),
			templateLibrary: missLibrary,
			visualScheduler: visualScheduler,
			timeoutSeconds: 2
		)
		let metadataOnlyBrowserSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "YouTube — Video",
			bundleIdentifier: "com.apple.Safari",
			inferredWorkflow: .browsing,
			workflowConfidence: 0.6,
			permissionAvailability: [.screenRecording: true],
			generatedAt: now,
			freshnessScore: 0.42
		)
		_ = await autoVisualEngine.generateProposals(
			snapshot: metadataOnlyBrowserSnap,
			existingStaticActions: [],
			reusableActions: []
		)
		_ = await autoVisualEngine.generateProposals(
			snapshot: metadataOnlyBrowserSnap,
			existingStaticActions: [],
			reusableActions: []
		)
		check("auto_visual_gather_called_once", visualScheduler.callCount == 1)

		// MARK: T18.3.4A — Decision stage isolation tests

		// NeverThinkDecisionEngine forces quiet → LLM must NOT be called.
		let countingClient = CountingDynamicProposalLLMClient(response: validJSON)
		let neverThinkEngine = DynamicGeneratedProposalEngine(
			modelManager: AlwaysAvailableProposalModelGate(),
			client: countingClient,
			decisionEngine: NeverThinkDecisionEngine(),
			timeoutSeconds: 2
		)
		let browserSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "Browser Tab",
			generatedAt: Date()
		)
		let neverThinkResult = await neverThinkEngine.generateProposals(
			snapshot: browserSnap,
			existingStaticActions: [],
			reusableActions: []
		)
		check("never_think_llm_not_called", countingClient.callCount == 0)
		check("never_think_status_quiet", neverThinkResult.status == .quietByGate)

		// AlwaysThinkDecisionEngine forces think → LLM must be called once.
		let countingClient2 = CountingDynamicProposalLLMClient(response: validJSON)
		let alwaysThinkEngine = DynamicGeneratedProposalEngine(
			modelManager: AlwaysAvailableProposalModelGate(),
			client: countingClient2,
			decisionEngine: AlwaysThinkDecisionEngine(),
			timeoutSeconds: 2
		)
		_ = await alwaysThinkEngine.generateProposals(
			snapshot: snap,
			existingStaticActions: [],
			reusableActions: []
		)
		check("always_think_llm_called_once", countingClient2.callCount == 1)

		check("no_runtime_execution", !SelfTestRuntimeGuard.activationInvokedRuntime)

		let ok = failures.isEmpty
		print("[DynamicGeneratedProposal] selftest ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}

private struct StubDynamicProposalLLMClient: DynamicGeneratedProposalLLMGenerating {
	let response: String
	func generate(prompt: String, model: String) async throws -> String { response }
}

private struct AlwaysAvailableProposalModelGate: DynamicGeneratedProposalAvailabilityChecking {
	func isGenerationAvailable() async -> Bool { true }
}

private struct SlowDynamicProposalLLMClient: DynamicGeneratedProposalLLMGenerating {
	func generate(prompt: String, model: String) async throws -> String {
		try await Task.sleep(nanoseconds: 500_000_000)
		return "{}"
	}
}

// MARK: - T18.3.7B stubs

private final class CountingVisualContextScheduler: VisualContextScheduling, @unchecked Sendable {
	private(set) var callCount = 0
	let result: BoundedVisualContextResult

	init(result: BoundedVisualContextResult) {
		self.result = result
	}

	func collect(
		request: BoundedVisualContextRequest,
		budgetSnapshot: GeneratedExecutionBudgetSnapshot
	) async -> BoundedVisualContextResult {
		callCount += 1
		_ = request
		_ = budgetSnapshot
		return result
	}
}

private struct AlwaysMissTemplateLibrary: GeneratedActionTemplateLibraryProviding {
	func retrieve(
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) async -> GeneratedActionTemplateLibraryResult {
		_ = situational
		_ = referenceTime
		return .empty(reason: .noMatchForContext)
	}

	func enqueuePrewarm(
		situational: SituationalContextSnapshot,
		decision: AgenticProposalDecision,
		referenceTime: Date
	) async {
		_ = situational
		_ = decision
		_ = referenceTime
	}
}

// T18.3.4A stub types

private final class CountingDynamicProposalLLMClient: DynamicGeneratedProposalLLMGenerating, @unchecked Sendable {
	let response: String
	private(set) var callCount = 0
	init(response: String) { self.response = response }
	func generate(prompt: String, model: String) async throws -> String {
		callCount += 1
		return response
	}
}

private struct NeverThinkDecisionEngine: AgenticProposalDeciding {
	func decide(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) async -> AgenticProposalDecision {
		.quiet(reason: "test_never_think")
	}
	func recordTimeout(fingerprint: String, at time: Date) async {}
}

private struct AlwaysThinkDecisionEngine: AgenticProposalDeciding {
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
