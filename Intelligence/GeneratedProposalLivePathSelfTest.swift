import Foundation

/// T18.3.4 live proposal path wiring tests (not wired to app launch).
enum GeneratedProposalLivePathSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		var firefoxCtx = ContextModel()
		firefoxCtx.activeAppName = "Firefox"
		firefoxCtx.activeAppBundleIdentifier = "org.mozilla.firefox"
		firefoxCtx.activeWindowTitle = "Swift Concurrency — YouTube — Mozilla Firefox"
		firefoxCtx.lastSourceTrigger = .windowTitleChanged
		firefoxCtx.updatedAt = Date()

		let engine = TriggerEngine(cooldownManager: CooldownManager())
		let packet = engine.evaluate(firefoxCtx)
		check("firefox_title_triggers_packet", packet?.triggerType == .contextMetadataEligible)

		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: firefoxCtx.activeWindowTitle ?? "",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .unknown,
			generatedAt: Date(),
			freshnessScore: 0.52,
			packetIsStale: false
		)
		check("no_fused_not_stale_flag", snap.packetIsStale == false)

		let prepared = GeneratedProposalActivationBoundary.prepare(snapshot: snap)
		check("boundary_produces_situational", prepared.situational.primaryAvailableSource == .metadataOnly)
		check(
			"no_fused_has_missing_reason_not_block",
			prepared.situational.missingContextReasons.contains("no_fused_packet")
		)
		check(
			"stale_context_not_primary_failure",
			!prepared.situational.missingContextReasons.contains("stale_context")
		)

		let stubEngine = DynamicGeneratedProposalEngine(
			modelManager: LivePathTestModelGate(),
			client: LivePathStubLLMClient(),
			timeoutSeconds: 2
		)
		let llmResult = await stubEngine.generateProposals(
			snapshot: prepared.snapshot,
			existingStaticActions: [],
			reusableActions: [],
			situational: prepared.situational
		)
		check("engine_accepts_situational", llmResult.status == .synthesized || llmResult.status == .quietByGate)

		let prompt = DynamicGeneratedProposalPromptBuilder.build(
			snapshot: prepared.snapshot,
			existingStaticActions: [],
			reusableCount: 0,
			history: nil,
			budget: .conservative,
			situational: prepared.situational
		)
		check("prompt_has_situational_summary", prompt.contains(prepared.situational.situationalSummary))

		let decision = ReasoningEngine.shared.evaluate(context: firefoxCtx, triggerPacket: packet!)
		check("reasoning_surfaces_metadata", decision.shouldSurface)

		let ok = failures.isEmpty
		print("[GeneratedProposalLivePath] selftest ok=\(ok) failures=\(failures.joined(separator: ";"))")
		return ok
	}
}

private struct LivePathTestModelGate: DynamicGeneratedProposalAvailabilityChecking {
	func isGenerationAvailable() async -> Bool { true }
}

private struct LivePathStubLLMClient: DynamicGeneratedProposalLLMGenerating {
	func generate(prompt: String, model: String) async throws -> String {
		_ = prompt
		return """
		{"shouldChimeIn":true,"reason":"ok","workflowAssessment":"research","proposalConfidence":0.7,"requiresVisualContext":true,"proposals":[{"title":"Outline study questions from page title metadata","description":"Use title-only context","intentType":"explain","workflowType":"research","expectedOutcome":"questions","requiredContextTypes":["text_snippet"],"suggestedPrimitives":["answer_from_context"],"interruptionCost":0.2,"confidence":0.7}]}
		"""
	}
}
