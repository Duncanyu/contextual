import Foundation

/// Phase 4H regression self-test: verifies execution-start perception priming and control-policy safety.
///
/// Run with: `CONTEXTUAL_RUN_PERSISTENT_GROUNDED_RUNTIME_SELFTEST=1`
///
/// Notes:
/// - Uses `dryRun=true` for perception priming so this can run without Screen Recording permission.
/// - Does not execute the full AgenticRuntime loop (which may call a local model); instead it validates
///   the priming + observation contract directly.
enum PersistentGroundedRuntimeSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[PersistentGroundedRuntimeSelfTest] FAIL \(name)")
			}
		}

		let now = Date()

		// MARK: 1 — Priming adds OCR + AX (dryRun) when snapshot lacks OCR

		let initial = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Anker Laptop Power Bank - Amazon",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			recentOCRExcerpt: nil,
			contextSummary: nil,
			workflowConfidence: 0.7,
			availableContextTypes: [],
			generatedAt: now,
			freshnessScore: 0.45
		)

		let coordinator = AgenticPerceptionRefreshCoordinator()
		let primed = await coordinator.initialCapture(
			previousSnapshot: initial,
			previousSnapshotID: nil,
			ocrBudgetRemaining: true,
			dryRun: true
		)

		check("priming_success", primed.success)
		check("priming_ocr_present", !(primed.freshSnapshot.recentOCRExcerpt ?? "").isEmpty)
		check("priming_ax_present_in_summary", (primed.freshSnapshot.contextSummary ?? "").contains("ax="))

		// MARK: 2 — First observe uses OCR after priming

		let observer = AgenticObserver()
		let obs = observer.observe(
			stepIndex: 1,
			snapshot: primed.freshSnapshot,
			ocrCallsUsed: 0,
			ocrCallsBudget: 2,
			isPostControl: false,
			goal: "test",
			previousSnapshotID: nil
		)
		check("observe_uses_ocr_after_priming", !(obs.ocrExcerpt ?? "").isEmpty)

		// MARK: 3 — Power bank does NOT trigger high-risk context (tokenized guard)

		let policy = AgenticControlPolicy()
			let safeCtx = AgenticControlPolicyContext(
				action: .scroll_small,
				bundleIdentifier: "org.mozilla.firefox",
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
		let safeResult = policy.evaluate(safeCtx)
		check("power_bank_not_high_risk", safeResult.allowed)

		// MARK: 4 — Real banking/payment/login contexts still trigger high risk

		let blockedTitles: [String] = [
			"Bank account login",
			"Online banking - Sign in",
			"Checkout - payment and billing",
			"Verify your password",
			"Credit card payment",
		]
		for title in blockedTitles {
			let sig = title.replacingOccurrences(of: " ", with: "_")
				let ctx = AgenticControlPolicyContext(
					action: .find_on_page,
					bundleIdentifier: "org.mozilla.firefox",
					windowTitle: title,
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
			let res = policy.evaluate(ctx)
			check("high_risk_blocked_\(sig)", res.allowed == false)
		}

		// MARK: 5 — Hook catalog reset remains active (no hooks installed)

		check("hook_catalog_empty", HookCapabilityRegistry.shared.all.isEmpty)

		let ok = failures.isEmpty
		print("[PersistentGroundedRuntimeSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
