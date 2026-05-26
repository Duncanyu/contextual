import Foundation

/// Phase 4R self-test for:
/// - grounded evidence preservation when text overlaps the runtime goal
/// - terminal-step control guard (no control action when no observation budget remains)
/// - partial grounded success answers preserve extracted facts
///
/// Run with: `CONTEXTUAL_RUN_RUNTIME_GROUNDING_PRESERVATION_SELFTEST=1`
enum RuntimeGroundingPreservationSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[RuntimeGroundingPreservationSelfTest] FAIL \(name)")
			}
		}

		// MARK: 1 — GeneratedChromeFilter preserves grounded overlap when corroborated by window title / AX.

		do {
			let goal = "Anker Prime USB C Charger Block"
			let support = GeneratedChromeFilter.GroundingSupport(
				windowTitle: "Anker Prime USB C Charger Block — product page",
				axText: "Heading: Anker Prime USB C Charger Block\nBody: 140W MAX"
			)
			let r = GeneratedChromeFilter.shouldSuppress(line: goal, runtimeGoal: goal, proposalTitle: nil, groundingSupport: support)
			check("chrome_preserves_grounded_overlap", r.suppressed == false)
		}

		// MARK: 2 — GeneratedChromeFilter still suppresses ungrounded overlap.

		do {
			let goal = "Anker Prime USB C Charger Block"
			let support = GeneratedChromeFilter.GroundingSupport(
				windowTitle: "Mozilla Firefox",
				axText: "Contextual Assistance\nRuntime Phase"
			)
			let r = GeneratedChromeFilter.shouldSuppress(line: goal, runtimeGoal: goal, proposalTitle: nil, groundingSupport: support)
			check("chrome_suppresses_ungrounded_overlap", r.suppressed == true)
		}

		// MARK: 3 — Terminal-step control guard blocks control when no observation budget remains.

		do {
			let policy = AgenticControlPolicy()
			let ctx = AgenticControlPolicyContext(
				action: .find_on_page,
				bundleIdentifier: "org.mozilla.firefox",
				windowTitle: "Some product page",
				activeApp: "Firefox",
				workflow: "browsing",
				stepIndex: 5,
				maxSteps: 5,            // terminal
				priorActions: [],
				scrollsUsed: 0,
				findsUsed: 0,
				ocrCallsUsed: 2,
				ocrCallsBudget: 2,      // no perception budget
				maxScrolls: 2,
				maxFinds: 1,
				dryRun: true
			)
			let r = policy.evaluate(ctx)
			check("terminal_guard_blocks_find", r.allowed == false)
			check("terminal_guard_reason", r.reason == "terminal_step_no_observation_budget")
		}

		// MARK: 4 — Partial grounded success answer preserves extracted facts when controls failed.

		do {
			let runtime = AgenticRuntime()
			let session = AgenticSessionState(
				planId: "test",
				goal: "Review product details",
				workflow: "browsing",
				stepIndex: 1,
				maxSteps: 5,
				llmCallsUsed: 0,
				ocrCallsUsed: 0,
				scrollsUsed: 1,
				findsUsed: 1,
				maxScrolls: 2,
				maxFinds: 1,
				startedAt: Date(),
				observations: [],
				extractedFacts: [],
				finalAnswer: nil,
				stopReason: .partial_evidence_budget_exhausted,
				actionsExecuted: ["scroll_small", "find_on_page"],
				forceObserveNext: false,
				lastActionWasControl: true,
				blockedActions: [],
				controlDecisionLog: [],
				ineffectiveControlCount: 2,
				failedControlActions: ["find_on_page"],
				worldStateTransitions: [],
				discoveredEntities: [],
				lastObservationSnapshotID: nil,
				lastObservationTextHash: nil,
				screenStateGraph: nil,
				groundedTargets: [],
				primaryGroundedTarget: nil,
				semanticEntities: [
					GroundedSemanticEntity(
						id: "pt",
						type: .productTitle,
						text: "Anker Prime USB C Charger Block",
						normalizedValue: "anker prime usb c charger block",
						confidence: 0.8,
						sourceNodeId: "n1",
						role: .heading,
						tags: ["product"]
					),
					GroundedSemanticEntity(
						id: "spec",
						type: .specification,
						text: "140W",
						normalizedValue: "140w",
						confidence: 0.8,
						sourceNodeId: "n2",
						role: .bodyText,
						tags: ["spec"]
					),
				],
				structuredFacts: [],
				semanticReadiness: nil,
				evidenceRequirements: [],
				evidenceState: nil,
				evidenceObservations: []
			)
			let answer = runtime.buildPremiumAnswerTestBridge(session: session)
			check("partial_answer_contains_product", answer.contains("Anker Prime USB C Charger Block"))
			check("partial_answer_mentions_controls", answer.lowercased().contains("navigation attempts") || answer.lowercased().contains("scroll") || answer.lowercased().contains("find"))
		}

		let ok = failures.isEmpty
		print("[RuntimeGroundingPreservationSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
