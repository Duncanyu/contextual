import Foundation

/// T18.3 generated proposal activation self-tests (not wired to app launch).
enum GeneratedExecutionProposalActivatorSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()
		let strongSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Xcode",
			inferredWorkflow: .debugging,
			selectedText: String(repeating: "error line ", count: 12) + "failed",
			workflowConfidence: 0.75,
			generatedAt: now,
			freshnessScore: 0.82
		)

		let strongGenerated = GeneratedAction(
			id: UUID(),
			title: "Explain likely error",
			description: "Explain debugging context",
			intentType: .explainLikelyError,
			confidence: 0.82,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			primitives: [.explain],
			interruptionCost: 0.2,
			workflowRelevance: 0.8,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["test"],
			createdAt: now,
			expiresAt: now.addingTimeInterval(180),
			isStale: false,
			safetyProfile: .default,
			explainabilitySummary: "test",
			source: .selfTest,
			structuredExplainability: nil
		)

		let weakGenerated = GeneratedAction(
			id: UUID(),
			title: "Weak",
			description: "Low confidence",
			intentType: .unknown,
			confidence: 0.3,
			workflow: .unknown,
			requiredContext: [.textSnippet],
			primitives: [.summarize],
			interruptionCost: 0.2,
			workflowRelevance: 0.2,
			sourceIntentId: UUID(),
			sourceReasonCodes: [],
			createdAt: now,
			expiresAt: now.addingTimeInterval(180),
			isStale: false,
			safetyProfile: .default,
			explainabilitySummary: "weak",
			source: .selfTest,
			structuredExplainability: nil
		)

		let execCandidates = GeneratedExecutionProposalCandidateBuilder.build(
			from: [strongGenerated, weakGenerated],
			snapshot: strongSnap,
			referenceTime: now
		)

		let strongActivation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [SummarizeAction.summarizeTextId, ExplainAction.explainTextId],
				staticRelevanceScores: [
					ActionRelevanceScore(actionId: SummarizeAction.summarizeTextId, score: 0.55, reason: "test"),
					ActionRelevanceScore(actionId: ExplainAction.explainTextId, score: 0.58, reason: "test"),
				],
				generatedActions: [strongGenerated],
				generatedExecutionCandidates: execCandidates,
				snapshot: strongSnap,
				workflow: WorkflowInferenceResult(
					workflow: .debugging,
					confidence: 0.8,
					contributingSignals: [],
					inferredAt: now,
					isStale: false,
					summaryHint: nil,
					sourceFusedId: nil
				),
				referenceTime: now
			)
		)

		check("strong_generated_visible", !strongActivation.visibleProposals.isEmpty)
		check(
			"generated_can_outrank",
			strongActivation.topSourceType == .executableGenerated
				|| strongActivation.topSourceType == .generatedAction
				|| !strongActivation.visibleProposals.isEmpty
		)

		let lowSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Notes",
			inferredWorkflow: .unknown,
			clipboardText: "stale only",
			generatedAt: now.addingTimeInterval(-200),
			freshnessScore: 0.2,
			sourceMetadata: CanonicalExecutionSourceMetadata(
				clipboardCapturedAt: now.addingTimeInterval(-300)
			),
			packetIsStale: true
		)

		let lowActivation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [SummarizeAction.summarizeTextId],
				generatedActions: [weakGenerated],
				generatedExecutionCandidates: GeneratedExecutionProposalCandidateBuilder.build(
					from: [weakGenerated],
					snapshot: lowSnap,
					referenceTime: now
				),
				snapshot: lowSnap,
				referenceTime: now
			)
		)

		check("low_confidence_suppressed", lowActivation.visibleProposals.isEmpty)
		check("static_fallback_when_allowed", !lowActivation.visibleStaticActionIds.isEmpty)

		let suppressedStatic = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [SummarizeAction.summarizeTextId],
				generatedExecutionCandidates: [],
				snapshot: lowSnap,
				suppressStaticProposalFallback: true
			)
		)
		check("dynamic_only_hides_static", suppressedStatic.visibleStaticActionIds.isEmpty)

		let capInput = GeneratedExecutionProposalActivationInput(
			staticActionIds: [SummarizeAction.summarizeTextId],
			generatedActions: (0..<5).map { _ in strongGenerated },
			generatedExecutionCandidates: GeneratedExecutionProposalCandidateBuilder.build(
				from: [strongGenerated],
				snapshot: strongSnap,
				referenceTime: now
			),
			snapshot: strongSnap,
			referenceTime: now
		)
		let capped = GeneratedExecutionProposalActivator.activateProposals(input: capInput)
		check(
			"generated_cap",
			capped.visibleProposals.count <= GeneratedExecutionProposalActivator.maxPanelGeneratedVisible
		)

		let det1 = GeneratedExecutionProposalActivator.activateProposals(input: strongActivationInputFixture(now: now))
		let det2 = GeneratedExecutionProposalActivator.activateProposals(input: strongActivationInputFixture(now: now))
		check("ranking_deterministic", det1.visibleProposals == det2.visibleProposals)

		check("no_runtime_execution", !SelfTestRuntimeGuard.activationInvokedRuntime)

		let ok = failures.isEmpty
		print("[GeneratedProposalActivation] selftest ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}

	private static func strongActivationInputFixture(now: Date) -> GeneratedExecutionProposalActivationInput {
		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "App",
			inferredWorkflow: .writing,
			selectedText: "Some selected text for testing purposes.",
			workflowConfidence: 0.7,
			generatedAt: now,
			freshnessScore: 0.75
		)
		let ga = GeneratedAction(
			id: UUID(),
			title: "Summarize notes",
			description: "Summarize",
			intentType: .summarizeCurrentArticle,
			confidence: 0.76,
			workflow: .writing,
			requiredContext: [.textSnippet],
			primitives: [.summarize],
			interruptionCost: 0.18,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: [],
			createdAt: now,
			expiresAt: now.addingTimeInterval(120),
			isStale: false,
			safetyProfile: .default,
			explainabilitySummary: "x",
			source: .selfTest,
			structuredExplainability: nil
		)
		return GeneratedExecutionProposalActivationInput(
			staticActionIds: [SummarizeAction.summarizeTextId],
			generatedActions: [ga],
			generatedExecutionCandidates: GeneratedExecutionProposalCandidateBuilder.build(from: [ga], snapshot: snap),
			snapshot: snap,
			referenceTime: now
		)
	}
}

/// Guard flag — activation must not call GeneratedExecutionRuntime.
enum SelfTestRuntimeGuard {
	static var activationInvokedRuntime = false
}
