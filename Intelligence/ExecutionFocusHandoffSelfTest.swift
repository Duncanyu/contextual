import Foundation

/// Phase 4M self-test: validates the execution-focus handoff contract +
/// the runtime guards that protect against keyboard/scroll events being
/// delivered to the wrong frontmost app.
///
/// Run with: `CONTEXTUAL_RUN_EXECUTION_FOCUS_HANDOFF_SELFTEST=1`
///
/// All checks are deterministic and run without real screen recording,
/// AX permission, or a live browser. Stubs simulate the frontmost-app probe
/// and the assistant-UI bridge.
enum ExecutionFocusHandoffSelfTest {

	// MARK: - Stubs
	//
	// All stub protocol methods are `@MainActor` to match the protocol's
	// MainActor-isolated requirements. The self-test runner itself is invoked
	// from a `@MainActor` Task in AppDelegate, so stubs run on main with no
	// hops or `assumeIsolated` traps.

	/// Records every frontmost lookup and lets the test drive what's returned.
	@MainActor
	final class StubFrontmostProvider: ExecutionFocusFrontmostProvider {
		var sequence: [String?]
		private(set) var calls: Int = 0
		init(sequence: [String?]) { self.sequence = sequence }
		func currentFrontmostBundleIdentifier() -> String? {
			defer { calls += 1 }
			if calls < sequence.count { return sequence[calls] }
			return sequence.last ?? nil
		}
	}

	/// Records every activate call.
	@MainActor
	final class StubActivator: ExecutionFocusActivator {
		private(set) var requested: [String] = []
		let succeed: Bool
		init(succeed: Bool = true) { self.succeed = succeed }
		func activateApp(bundleIdentifier: String) -> Bool {
			requested.append(bundleIdentifier)
			return succeed
		}
	}

	/// Records hide/restore calls.
	@MainActor
	final class StubAssistantUI: ExecutionFocusAssistantUI {
		private(set) var hideCount = 0
		private(set) var restoreCount = 0
		private(set) var lastHideReason: String?
		private(set) var lastRestoreReason: String?
		func hideAssistantUI(reason: String) {
			hideCount += 1
			lastHideReason = reason
		}
		func restoreAssistantUI(reason: String) {
			restoreCount += 1
			lastRestoreReason = reason
		}
	}

	// MARK: - Runner

	@MainActor
	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[ExecutionFocusHandoffSelfTest] FAIL \(name)")
			}
		}

		let assistantBundle = "com.contextual.app"
		let targetBundle = "org.mozilla.firefox"
		let anchor = TargetWindowAnchor(
			bundleIdentifier: targetBundle,
			appName: "Firefox",
			windowTitle: "Anker Laptop Power Bank - Amazon",
			contextFingerprint: TargetWindowAnchor.fingerprint(
				bundleIdentifier: targetBundle,
				windowTitle: "Anker Laptop Power Bank - Amazon",
				workflow: .browsing
			),
			createdAt: Date(),
			sourceCandidateId: "test-candidate"
		)

		// MARK: 1 — Hide is called before activation, with execution_start reason

		do {
			let ui = StubAssistantUI()
			let frontmost = StubFrontmostProvider(sequence: [assistantBundle, targetBundle])
			let activator = StubActivator(succeed: true)
			let handoff = ExecutionFocusHandoff(
				frontmostProvider: frontmost,
				activator: activator,
				assistantUI: ui,
				assistantBundleIdentifier: assistantBundle,
				settleMs: ExecutionFocusHandoff.minSettleMs
			)
			let outcome = await handoff.prepare(targetAnchor: anchor)
			check("ui_hidden_before_runtime", ui.hideCount == 1)
			check("ui_hide_reason_execution_start", ui.lastHideReason == "execution_start")
			check("ui_not_restored_yet", ui.restoreCount == 0)
			check("target_activation_requested_when_assistant_frontmost",
				  activator.requested == [targetBundle])
			check("outcome_matched_when_target_frontmost_after_activate", outcome.matched)
			check("outcome_control_allowed_when_matched", outcome.controlAllowed)

			handoff.finalize(outcome: outcome)
			check("ui_restored_after_runtime", ui.restoreCount == 1)
			check("ui_restore_reason_execution_complete", ui.lastRestoreReason == "execution_complete")
		}

		// MARK: 2 — Activation skipped when target is ALREADY frontmost

		do {
			let ui = StubAssistantUI()
			let frontmost = StubFrontmostProvider(sequence: [targetBundle, targetBundle])
			let activator = StubActivator(succeed: true)
			let handoff = ExecutionFocusHandoff(
				frontmostProvider: frontmost,
				activator: activator,
				assistantUI: ui,
				assistantBundleIdentifier: assistantBundle,
				settleMs: ExecutionFocusHandoff.minSettleMs
			)
			let outcome = await handoff.prepare(targetAnchor: anchor)
			check("no_activation_when_already_frontmost", activator.requested.isEmpty)
			check("matched_when_already_frontmost", outcome.matched)
			check("control_allowed_when_already_frontmost", outcome.controlAllowed)
		}

		// MARK: 3 — Frontmost mismatch blocks control

		do {
			let ui = StubAssistantUI()
			// Frontmost stays on assistant even after activate request → mismatch.
			let frontmost = StubFrontmostProvider(sequence: [assistantBundle, assistantBundle])
			let activator = StubActivator(succeed: false)
			let handoff = ExecutionFocusHandoff(
				frontmostProvider: frontmost,
				activator: activator,
				assistantUI: ui,
				assistantBundleIdentifier: assistantBundle,
				settleMs: ExecutionFocusHandoff.minSettleMs
			)
			let outcome = await handoff.prepare(targetAnchor: anchor)
			check("mismatch_blocks_control_allowed", outcome.controlAllowed == false)
			check("mismatch_outcome_not_matched", outcome.matched == false)
		}

		// MARK: 4 — No-anchor case is unanchored / control allowed default

		do {
			let ui = StubAssistantUI()
			let frontmost = StubFrontmostProvider(sequence: ["com.example.other"])
			let activator = StubActivator()
			let handoff = ExecutionFocusHandoff(
				frontmostProvider: frontmost,
				activator: activator,
				assistantUI: ui,
				assistantBundleIdentifier: assistantBundle,
				settleMs: ExecutionFocusHandoff.minSettleMs
			)
			let outcome = await handoff.prepare(targetAnchor: nil)
			check("no_anchor_no_activation", activator.requested.isEmpty)
			check("no_anchor_matched_default_true", outcome.matched)
			check("no_anchor_control_allowed_default", outcome.controlAllowed)
		}

		// MARK: 5 — Settle delay is clamped into the spec range (150–300ms)

		do {
			let belowMin = ExecutionFocusHandoff(
				frontmostProvider: StubFrontmostProvider(sequence: [assistantBundle, targetBundle]),
				activator: StubActivator(),
				assistantUI: StubAssistantUI(),
				assistantBundleIdentifier: assistantBundle,
				settleMs: 1
			)
			check("settle_clamped_to_min", belowMin.settleMs == ExecutionFocusHandoff.minSettleMs)
			let aboveMax = ExecutionFocusHandoff(
				frontmostProvider: StubFrontmostProvider(sequence: [assistantBundle, targetBundle]),
				activator: StubActivator(),
				assistantUI: StubAssistantUI(),
				assistantBundleIdentifier: assistantBundle,
				settleMs: 999_999
			)
			check("settle_clamped_to_max", aboveMax.settleMs == ExecutionFocusHandoff.maxSettleMs)
		}

		// MARK: 6 — AgenticControlPolicy blocks scroll/find on frontmost mismatch

		do {
			let policy = AgenticControlPolicy()
				let mismatchCtx = AgenticControlPolicyContext(
					action: .scroll_small,
					bundleIdentifier: targetBundle,
					windowTitle: "Anker Laptop Power Bank - Amazon",
					activeApp: "Firefox",
					workflow: "browsing",
					stepIndex: 1,
					maxSteps: 5,
					priorActions: [],
					scrollsUsed: 0,
					findsUsed: 0,
					ocrCallsUsed: 0,
					ocrCallsBudget: 2,
					maxScrolls: 2,
					maxFinds: 1,
					dryRun: true,
					expectedTargetBundle: targetBundle,
					currentFrontmostBundle: assistantBundle
				)
			let r1 = policy.evaluate(mismatchCtx)
			check("policy_blocks_on_frontmost_mismatch", r1.allowed == false)
			check("policy_reason_frontmost_mismatch", r1.reason == "frontmost_mismatch")

				let matchCtx = AgenticControlPolicyContext(
					action: .scroll_small,
					bundleIdentifier: targetBundle,
					windowTitle: "Anker Laptop Power Bank - Amazon",
					activeApp: "Firefox",
					workflow: "browsing",
					stepIndex: 1,
					maxSteps: 5,
					priorActions: [],
					scrollsUsed: 0,
					findsUsed: 0,
					ocrCallsUsed: 0,
					ocrCallsBudget: 2,
					maxScrolls: 2,
					maxFinds: 1,
					dryRun: true,
					expectedTargetBundle: targetBundle,
					currentFrontmostBundle: targetBundle
				)
			let r2 = policy.evaluate(matchCtx)
			check("policy_allows_on_frontmost_match", r2.allowed)

			// And: when no expected/actual is provided, legacy behavior — guard inactive.
				let legacyCtx = AgenticControlPolicyContext(
					action: .find_on_page,
					bundleIdentifier: targetBundle,
					windowTitle: "Anker Laptop Power Bank - Amazon",
					activeApp: "Firefox",
					workflow: "browsing",
					stepIndex: 1,
					maxSteps: 5,
					priorActions: [],
					scrollsUsed: 0,
					findsUsed: 0,
					ocrCallsUsed: 0,
					ocrCallsBudget: 2,
					maxScrolls: 2,
					maxFinds: 1,
					dryRun: true
				)
			let r3 = policy.evaluate(legacyCtx)
			check("policy_legacy_path_unchanged_when_guard_inactive", r3.allowed)
		}

		// MARK: 7 — Priming OCR does NOT consume the loop OCR budget

		do {
			// We can't run the full actor loop here without spinning up real
			// services, but we CAN inspect the contract directly: after priming,
			// session.ocrCallsUsed must still be 0 so the first observe_once does
			// not hit "ocr_skipped reason=budget_exhausted".
			let initial = CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "Firefox",
				windowTitle: "Anker Laptop Power Bank - Amazon",
				bundleIdentifier: targetBundle,
				inferredWorkflow: .browsing,
				recentOCRExcerpt: nil,
				contextSummary: nil,
				workflowConfidence: 0.7,
				availableContextTypes: [],
				generatedAt: Date(),
				freshnessScore: 0.45
			)
			let coordinator = AgenticPerceptionRefreshCoordinator()
			let priming = await coordinator.initialCapture(
				previousSnapshot: initial,
				previousSnapshotID: nil,
				ocrBudgetRemaining: true,
				dryRun: true
			)
			check("priming_returns_success_in_dry_run", priming.success)
			check("priming_produces_fresh_ocr_in_dry_run", priming.freshOCR != nil)
			// The runtime is responsible for not incrementing the loop budget; the
			// coordinator itself simply returns the priming result. We assert that
			// the priming result carries the freshOCR that would otherwise have
			// caused the previous code to increment session.ocrCallsUsed.
			let observer = AgenticObserver()
			let obs = observer.observe(
				stepIndex: 1,
				snapshot: priming.freshSnapshot,
				ocrCallsUsed: 0,           // loop budget intact after priming
				ocrCallsBudget: 1,         // tight budget proves the fix
				isPostControl: false,
				goal: "test",
				previousSnapshotID: nil
			)
			check("first_observe_uses_ocr_when_budget_intact", obs.ocrExcerpt != nil)
		}

		// MARK: 8 — Assistant chrome lines are filtered from OCR

		do {
			let ocr = """
			Processing Review Anker Laptop Charger details...
			Open
			Execute
			Controlled Interactions
			Anker Laptop Power Bank, 25,000mAh 165W USB-C Portable Charger
			$129.99
			4.7 out of 5 stars
			"""
			let result = AssistantChromeFilter.filterOCR(
				ocr,
				targetBundleIdentifier: targetBundle,
				assistantBundleIdentifier: assistantBundle
			)
			let kept = result.filteredText
			check("chrome_processing_review_suppressed",
				  !kept.localizedCaseInsensitiveContains("processing review"))
			check("chrome_open_button_suppressed",
				  !kept.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "open" }))
			check("chrome_execute_button_suppressed",
				  !kept.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "execute" }))
			check("chrome_controlled_interactions_suppressed",
				  !kept.localizedCaseInsensitiveContains("controlled interactions"))
			check("real_product_title_kept",
				  kept.contains("Anker Laptop Power Bank, 25,000mAh"))
			check("real_price_kept", kept.contains("$129.99"))
			check("real_rating_kept", kept.contains("4.7 out of 5 stars"))
		}

		// MARK: 9 — When the target IS the assistant, do NOT filter assistant chrome

		do {
			let ocr = """
			Generated Execution
			Anker Laptop Power Bank
			"""
			let result = AssistantChromeFilter.filterOCR(
				ocr,
				targetBundleIdentifier: assistantBundle, // legitimate assistant target
				assistantBundleIdentifier: assistantBundle
			)
			check("no_filter_when_target_is_assistant",
				  result.filteredText.contains("Generated Execution"))
		}

		let ok = failures.isEmpty
		print("[ExecutionFocusHandoffSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
