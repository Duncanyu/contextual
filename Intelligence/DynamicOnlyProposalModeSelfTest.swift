import Foundation

/// T18.3.2 dynamic-only proposal mode tests (not wired to app launch).
enum DynamicOnlyProposalModeSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		check("mode_enabled", DynamicOnlyProposalMode.isEnabled)

		let packet = TriggerPacket(
			triggerType: .clipboardTextEligible,
			reason: "test",
			candidateActions: [],
			createdAt: Date()
		)
		var ctx = ContextModel()
		ctx.clipboardTextAvailable = true
		ctx.clipboardTextLength = 120
		ctx.lastSourceTrigger = .clipboardTextChanged
		let decision = ReasoningEngine.shared.evaluate(context: ctx, triggerPacket: packet)
		check("empty_candidates_surfaces_dynamic", decision.shouldSurface && decision.primaryActionId == nil)

		let manualPacket = TriggerPacket(
			triggerType: .manualInvocation,
			reason: "test",
			candidateActions: ["analyze_screen"],
			createdAt: Date()
		)
		let manualDecision = ReasoningEngine.shared.evaluate(context: ctx, triggerPacket: manualPacket)
		check(
			"manual_no_generic_primary",
			manualDecision.primaryActionId == nil || !DynamicOnlyProposalMode.isGenericStaticAction(manualDecision.primaryActionId ?? "")
		)

		let relevance = ActionRelevanceScorer.scoreActions(
			candidateActionIds: ["summarize_text", "explain_text", "analyze_screen"],
			contextType: .article,
			features: FeatureExtractor.extract(from: "sample text for scoring")
		)
		check("relevance_filters_generic", relevance.allSatisfy { !DynamicOnlyProposalMode.isGenericStaticAction($0.actionId) })

		let proposal = ProposalGenerator.shared.generate(
			context: ctx,
			triggerPacket: packet,
			decision: ReasoningDecision(
				shouldSurface: true,
				primaryActionId: "summarize_text",
				rankedActionIds: ["summarize_text"],
				reason: "test",
				confidence: 0.9
			),
			inputSourcePreference: .automatic
		)
		check("proposal_generator_blocks_generic", proposal == nil)

		let browserSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Swift concurrency docs - Mozilla Firefox",
			inferredWorkflow: .research,
			workflowConfidence: 0.4,
			generatedAt: Date(),
			freshnessScore: 0.5,
			packetIsStale: false
		)
		let gate = await DynamicGeneratedProposalEngine(
			modelManager: SelfTestAlwaysAvailableModelGate(),
			client: StubDynamicOnlyLLMClient(),
			timeoutSeconds: 2
		).generateProposals(snapshot: browserSnap, existingStaticActions: [], reusableActions: [])
		check(
			"metadata_browser_attempts_llm",
			gate.status != DynamicGeneratedProposalSynthesisStatus.quietByGate || gate.reason != "no_fused_context"
		)

		let unavailable = await DynamicGeneratedProposalEngine(
			modelManager: DenyProposalModelGate(),
			client: StubDynamicOnlyLLMClient(),
			timeoutSeconds: 2
		).generateProposals(snapshot: browserSnap, existingStaticActions: [], reusableActions: [])
		let activation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [SummarizeAction.summarizeTextId],
				generatedExecutionCandidates: [],
				snapshot: browserSnap,
				useLLMGeneratedCandidatesOnly: true,
				suppressStaticProposalFallback: true
			)
		)
		check("unavailable_no_static_fallback", unavailable.status == .modelUnavailable)
		check("activation_hides_static", activation.visibleStaticActionIds.isEmpty)

		let staleClip = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Notes",
			clipboardText: "old clip",
			generatedAt: Date().addingTimeInterval(-600),
			freshnessScore: 0.2,
			sourceMetadata: CanonicalExecutionSourceMetadata(
				clipboardCapturedAt: Date().addingTimeInterval(-600),
				contextUpdatedAt: Date().addingTimeInterval(-600)
			),
			packetIsStale: false
		)
		let suppression = GeneratedExecutionClipboardFreshnessPolicy.evaluate(snapshot: staleClip)
		check("stale_clipboard_suppressed", suppression.includeClipboard == false)

		let validJSON = """
		{"shouldChimeIn":true,"reason":"x","workflowAssessment":"x","proposalConfidence":0.85,"requiresVisualContext":false,"proposals":[{"title":"Map research tabs to implementation tasks","description":"Use window title context","intentType":"explain","workflowType":"research","expectedOutcome":"task list","requiredContextTypes":["text_snippet"],"suggestedPrimitives":["answer_from_context"],"interruptionCost":0.2,"confidence":0.75}]}
		"""
		let parsed = DynamicGeneratedProposalParser.parse(from: validJSON)
		let candidates = DynamicGeneratedProposalCandidateMapper.candidates(
			from: parsed!,
			snapshot: browserSnap,
			budget: .conservative
		)
		let visibleActivation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [],
				generatedExecutionCandidates: candidates,
				snapshot: browserSnap,
				useLLMGeneratedCandidatesOnly: true,
				suppressStaticProposalFallback: true
			)
		)
		check("valid_llm_visible", !visibleActivation.visibleProposals.isEmpty)

		let situational = SituationalContextSynthesizer.synthesize(from: browserSnap)
		let debug = GeneratedProposalDebugStatusBuilder.build(
			llmResult: parsed!,
			llmCandidates: candidates,
			activation: visibleActivation,
			situational: situational
		)
		check("debug_line_present", debug.logLine.contains("Generated proposal status"))

		let ok = failures.isEmpty
		print("[DynamicOnlyProposal] selftest ok=\(ok) failures=\(failures.joined(separator: ";"))")
		return ok
	}
}

private struct StubDynamicOnlyLLMClient: DynamicGeneratedProposalLLMGenerating {
	func generate(prompt: String, model: String) async throws -> String {
		"""
		{"shouldChimeIn":true,"reason":"ok","workflowAssessment":"research","proposalConfidence":0.8,"requiresVisualContext":false,"proposals":[{"title":"Map research tabs to implementation tasks","description":"From browser title metadata","intentType":"explain","workflowType":"research","expectedOutcome":"tasks","requiredContextTypes":["text_snippet"],"suggestedPrimitives":["answer_from_context"],"interruptionCost":0.2,"confidence":0.75}]}
		"""
	}
}

private struct DenyProposalModelGate: DynamicGeneratedProposalAvailabilityChecking {
	func isGenerationAvailable() async -> Bool { false }
}

private struct SelfTestAlwaysAvailableModelGate: DynamicGeneratedProposalAvailabilityChecking {
	func isGenerationAvailable() async -> Bool { true }
}
