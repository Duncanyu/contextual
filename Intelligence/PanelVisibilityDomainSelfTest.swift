// PanelVisibilityDomainSelfTest.swift
// Pure-logic self-test for Task 1 (panel visibility override) and Task 2 (domain filtering).
// No LLM calls — deterministic.
//
// Triggered by: CONTEXTUAL_RUN_PANEL_DOMAIN_SELFTEST=1
//
// Expected output:
//   [PanelVisibilityDomainSelfTest] started
//   [PanelVisibilityDomainSelfTest] case=domain_debugging_removes_shopping result=pass
//   [PanelVisibilityDomainSelfTest] case=domain_browsing_keeps_shopping result=pass
//   [PanelVisibilityDomainSelfTest] case=domain_unknown_passes_all result=pass
//   [PanelVisibilityDomainSelfTest] case=panel_override_high_confidence result=pass
//   [PanelVisibilityDomainSelfTest] case=panel_override_low_confidence_blocked result=pass
//   [PanelVisibilityDomainSelfTest] case=panel_override_non_hook_composer_blocked result=pass
//   [PanelVisibilityDomainSelfTest] ok=true failures=0

import Foundation

@MainActor
enum PanelVisibilityDomainSelfTest {

    static func run() {
        print("[PanelVisibilityDomainSelfTest] started")

        var failures = 0
        let registry = HookCapabilityRegistry.shared
        let allHooks = registry.all

        func check(name: String, ok: Bool, reason: String = "") {
            if ok {
                print("[PanelVisibilityDomainSelfTest] case=\(name) result=pass")
            } else {
                print("[PanelVisibilityDomainSelfTest] case=\(name) result=fail reason=\(reason.isEmpty ? "assertion_failed" : reason)")
                failures += 1
            }
        }

        // ── Domain filter tests ────────────────────────────────────────────────

        // Case 1: debugging workflow removes shopping-specific hooks
        let debugFiltered = HookDomainFilter.filter(
            candidates: allHooks,
            workflow: .debugging,
            app: "Xcode"
        )
        let shoppingIds = HookDomainFilter.shoppingOnlyHookIds
        let debugHasShoppingHook = debugFiltered.contains { shoppingIds.contains($0.id) }
        check(
            name: "domain_debugging_removes_shopping",
            ok: !debugHasShoppingHook,
            reason: "shopping hook found in debugging workflow candidates: \(debugFiltered.filter { shoppingIds.contains($0.id) }.map(\.id).joined(separator: ","))"
        )

        // Case 2: browsing workflow keeps shopping-specific hooks
        let browseFiltered = HookDomainFilter.filter(
            candidates: allHooks,
            workflow: .browsing,
            app: "Safari"
        )
        let browseHasProductSpecs = browseFiltered.contains { $0.id == "extract_product_specs" }
        check(
            name: "domain_browsing_keeps_shopping",
            ok: browseHasProductSpecs,
            reason: "extract_product_specs not found in browsing workflow candidates"
        )

        // Case 3: unknown workflow passes all hooks through (conservative)
        let unknownFiltered = HookDomainFilter.filter(
            candidates: allHooks,
            workflow: .unknown,
            app: "SelfTest"
        )
        check(
            name: "domain_unknown_passes_all",
            ok: unknownFiltered.count == allHooks.count,
            reason: "unknown workflow filtered some hooks (expected pass-through): before=\(allHooks.count) after=\(unknownFiltered.count)"
        )

        // ── Panel visibility override tests ───────────────────────────────────

        // Case 4: executable hook contract with confidence ≥ 0.70 → override should trigger
        let highConfHookProposal = makeCandidate(
            source: .hookComposer,
            isExecutable: true,
            confidence: 0.72
        )
        check(
            name: "panel_override_high_confidence",
            ok: GeneratedExecutionProposalActivator.isExecutableHookContractOverride(highConfHookProposal),
            reason: "expected override to trigger for hookComposer+executable+confidence=0.72"
        )

        // Case 5: hook contract below confidence threshold → override must NOT trigger
        let lowConfHookProposal = makeCandidate(
            source: .hookComposer,
            isExecutable: true,
            confidence: 0.55  // below 0.70 threshold
        )
        check(
            name: "panel_override_low_confidence_blocked",
            ok: !GeneratedExecutionProposalActivator.isExecutableHookContractOverride(lowConfHookProposal),
            reason: "override should not trigger for confidence=0.55"
        )

        // Case 6: non-hookComposer source (reusable) → override must NOT trigger
        let reusableProposal = makeCandidate(
            source: .reusableGenerated,
            isExecutable: true,
            confidence: 0.80
        )
        check(
            name: "panel_override_non_hook_composer_blocked",
            ok: !GeneratedExecutionProposalActivator.isExecutableHookContractOverride(reusableProposal),
            reason: "override should not trigger for source=reusableGenerated"
        )

        print("[PanelVisibilityDomainSelfTest] ok=\(failures == 0) failures=\(failures)")
    }

	// T18.6B — Smart persistence tests.
	static func runPersistenceTests() async {
		print("[ProposalPersistenceSelfTest] started")
		var failures = 0

		func check(_ name: String, _ ok: Bool) {
			if ok {
				print("[ProposalPersistenceSelfTest] case=\(name) result=pass")
			} else {
				print("[ProposalPersistenceSelfTest] case=\(name) result=fail")
				failures += 1
			}
		}

		let appState = AppState()
		let now = Date()

		// 1. Setup initial successful proposal
		let candidate1 = GeneratedExecutionProposalCandidate(
			id: "hook:test_1",
			title: "Test Proposal",
			description: "Subtitle",
			source: .hookComposer,
			workflowType: .browsing,
			intentType: .summarize,
			confidence: 0.8,
			interruptionCost: 0.2,
			explainabilitySummary: "Explain",
			expectedOutputSummary: "Output",
			requiredContextTypes: [],
			executionAction: nil,
			generatedActionId: nil,
			primitiveSignature: nil,
			isExecutableGeneratedProposal: true
		)
		let item = GeneratedExecutionProposalPanelItem(from: candidate1, rankScore: 0.6)

		let initialResult = GeneratedExecutionProposalActivationResult(
			visibleProposals: [item],
			visibleStaticActionIds: [],
			suppressedGeneratedCount: 0,
			suppressedStaticCount: 0,
			topSourceType: .executableGenerated,
			rankingSummary: "success",
			timingDecision: GeneratedExecutionProposalTimingDecision(
				outcome: .allowPanel,
				reason: "test",
				allowsFloatingGenerated: false,
				allowsPanelGenerated: true
			),
			warnings: [],
			createdAt: now,
			floatingGeneratedProposalId: nil,
			isPolicySuppressed: false
		)

		appState.applyGeneratedProposalActivation(initialResult)
		check("initial_storage", appState.activatedGeneratedProposals.count == 1)

		// 2. Scenario: transient failure (e.g. local_ai_not_ready)
		// This results in an empty visibleProposals list.
		let transientFailure = GeneratedExecutionProposalActivationResult(
			visibleProposals: [],
			visibleStaticActionIds: [],
			suppressedGeneratedCount: 0,
			suppressedStaticCount: 0,
			topSourceType: nil,
			rankingSummary: "local_ai_not_ready",
			timingDecision: .suppressAll,
			warnings: [],
			createdAt: now.addingTimeInterval(1),
			floatingGeneratedProposalId: nil,
			isPolicySuppressed: false
		)

		appState.applyGeneratedProposalActivation(transientFailure)
		check("persistence_during_transient_failure", appState.activatedGeneratedProposals.count == 1)

		// 3. Scenario: Policy suppression (e.g. repeated_low_novelty)
		let policySuppressed = GeneratedExecutionProposalActivationResult(
			visibleProposals: [item],
			visibleStaticActionIds: [],
			suppressedGeneratedCount: 1,
			suppressedStaticCount: 0,
			topSourceType: .executableGenerated,
			rankingSummary: "chime_suppressed:repeated_low_novelty",
			timingDecision: .suppressAll,
			warnings: ["chime_policy_suppressed"],
			createdAt: now.addingTimeInterval(2),
			floatingGeneratedProposalId: nil,
			isPolicySuppressed: true
		)

		appState.applyGeneratedProposalActivation(policySuppressed)
		check("persistence_during_policy_suppression", appState.activatedGeneratedProposals.count == 1)

		// 4. Scenario: Context invalidation (different app)
		appState.debugContext.activeAppBundleIdentifier = "com.apple.Safari"
		appState.debugContext.activeAppName = "Safari"
		
		let differentContext = GeneratedExecutionProposalActivationResult(
			visibleProposals: [],
			visibleStaticActionIds: [],
			suppressedGeneratedCount: 0,
			suppressedStaticCount: 0,
			topSourceType: nil,
			rankingSummary: "no_candidates",
			timingDecision: .suppressAll,
			warnings: [],
			createdAt: now.addingTimeInterval(3),
			floatingGeneratedProposalId: nil,
			isPolicySuppressed: false
		)

		appState.applyGeneratedProposalActivation(differentContext)
		check("invalidation_on_context_change", appState.activatedGeneratedProposals.isEmpty)

		// 5. Scenario: New successful replacement
		appState.applyGeneratedProposalActivation(initialResult) // Restore
		
		let candidate2 = GeneratedExecutionProposalCandidate(
			id: "hook:test_2",
			title: "New Proposal",
			description: "New",
			source: .hookComposer,
			workflowType: .browsing,
			intentType: .summarize,
			confidence: 0.9,
			interruptionCost: 0.1,
			explainabilitySummary: "Explain",
			expectedOutputSummary: "Output",
			requiredContextTypes: [],
			executionAction: nil,
			generatedActionId: nil,
			primitiveSignature: nil,
			isExecutableGeneratedProposal: true
		)
		let newItem = GeneratedExecutionProposalPanelItem(from: candidate2, rankScore: 0.7)

		let newSuccess = GeneratedExecutionProposalActivationResult(
			visibleProposals: [newItem],
			visibleStaticActionIds: [],
			suppressedGeneratedCount: 0,
			suppressedStaticCount: 0,
			topSourceType: .executableGenerated,
			rankingSummary: "success",
			timingDecision: GeneratedExecutionProposalTimingDecision(
				outcome: .allowPanel,
				reason: "test",
				allowsFloatingGenerated: false,
				allowsPanelGenerated: true
			),
			warnings: [],
			createdAt: now.addingTimeInterval(4),
			floatingGeneratedProposalId: nil,
			isPolicySuppressed: false
		)
		
		appState.applyGeneratedProposalActivation(newSuccess)
		check("replacement_on_new_success", appState.activatedGeneratedProposals.first?.id == "hook:test_2")

		print("[ProposalPersistenceSelfTest] ok=\(failures == 0) failures=\(failures)")
	}

    // MARK: - Helpers

    private static func makeCandidate(
        source: GeneratedExecutionProposalSource,
        isExecutable: Bool,
        confidence: Double
    ) -> GeneratedExecutionProposalCandidate {
        GeneratedExecutionProposalCandidate(
            id: "selftest_\(source.rawValue)_\(Int(confidence * 100))",
            title: "Self-test proposal",
            description: "self-test",
            source: source,
            workflowType: .browsing,
            intentType: .extract,
            confidence: confidence,
            interruptionCost: 0.18,
            explainabilitySummary: "selftest",
            expectedOutputSummary: "selftest output",
            requiredContextTypes: [],
            executionAction: nil,
            generatedActionId: nil,
            primitiveSignature: nil,
            isExecutableGeneratedProposal: isExecutable
        )
    }
}
