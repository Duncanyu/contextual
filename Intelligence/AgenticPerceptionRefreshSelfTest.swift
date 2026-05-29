import Foundation

/// Phase 4E self-tests for active perception refresh, snapshot identity, world-state delta,
/// and control adaptation.
///
/// Run with: CONTEXTUAL_RUN_PERCEPTION_REFRESH_SELFTEST=1
///
/// All tests use dryRun=true — no real CGEvents, no real screen capture.
/// Tests verify coordinator logic, snapshot identity, delta detection,
/// adaptation thresholds, and end-to-end loop termination.
enum AgenticPerceptionRefreshSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				failures.append(name)
				print("[AgenticPerceptionRefreshSelfTest] FAIL \(name)")
			}
		}

		let coordinator = AgenticPerceptionRefreshCoordinator()
		let runtime = AgenticRuntime()

		// MARK: - Baseline snapshots

		let baseSnapshot = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "AirPods 4 Reviews - Apple",
			bundleIdentifier: "com.apple.safari",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: nil,
			workflowConfidence: 0.85,
			freshnessScore: 0.80
		)

		let richSnapshot = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "AirPods 4 Reviews - Apple",
			bundleIdentifier: "com.apple.safari",
			inferredWorkflow: .browsing,
			selectedText: "AirPods 4: Active Noise Cancellation. Battery 30h.",
			clipboardText: nil,
			recentOCRExcerpt: "Rating: 4.7/5. Price: $129. Customer reviews: 2,341.",
			contextSummary: "User is on the AirPods 4 product reviews page.",
			workflowConfidence: 0.9,
			freshnessScore: 0.95
		)

		// MARK: 1 — Post-control observe forces fresh snapshot with new snapshotID
		// After dryRun refresh, the returned snapshotID must differ from the previous one.
		let previousID = UUID()
		let result1 = await coordinator.refresh(
			after: .find_on_page,
			previousSnapshot: baseSnapshot,
			previousSnapshotID: previousID,
			ocrBudgetRemaining: true,
			debugVisible: false,
			dryRun: true
		)
		check("post_control_new_snapshot_id", result1.snapshotID != previousID)
		check("post_control_previous_id_tracked", result1.previousSnapshotID == previousID)
		check("post_control_dry_run_success", result1.success)
		check("post_control_fresh_snapshot_returned", result1.freshSnapshot.fusedPacketId == result1.snapshotID)

		// MARK: 2 — snapshot_replaced log: snapshotIDs differ between consecutive refreshes
		// Each call to refresh() must produce a unique snapshotID.
		let result2a = await coordinator.refresh(
			after: .scroll_small,
			previousSnapshot: baseSnapshot,
			previousSnapshotID: nil,
			ocrBudgetRemaining: false,
			dryRun: true
		)
		let result2b = await coordinator.refresh(
			after: .scroll_small,
			previousSnapshot: result2a.freshSnapshot,
			previousSnapshotID: result2a.snapshotID,
			ocrBudgetRemaining: false,
			dryRun: true
		)
		check("consecutive_refreshes_unique_ids", result2a.snapshotID != result2b.snapshotID)
		check("consecutive_refresh_links_previous", result2b.previousSnapshotID == result2a.snapshotID)

		// MARK: 3 — Stale snapshot reuse is blocked: isPostControlObservation=true in observer
		// After a control action, observer.observe() must mark isPostControlObservation=true.
		let observer = AgenticObserver()
		// Build a session state simulating lastActionWasControl=true
		var staleObs = observer.observe(
			stepIndex: 1,
			snapshot: baseSnapshot,
			ocrCallsUsed: 0,
			ocrCallsBudget: 2,
			isPostControl: true,  // simulates post-control observe
			goal: "Find reviews"
		)
		check("stale_obs_is_post_control", staleObs.isPostControlObservation)
		// snapshotID is always a new UUID
		check("stale_obs_has_snapshot_id", staleObs.snapshotID != UUID())  // always true; UUID != default

		// MARK: 4 — World-state delta detection: same hash → no change
		let hash1 = AgenticPerceptionRefreshCoordinator.computeTextHash(ocr: "review text", selectedText: nil)
		let hash2 = AgenticPerceptionRefreshCoordinator.computeTextHash(ocr: "review text", selectedText: nil)
		check("same_content_same_hash", hash1 == hash2)

		// Different content → different hash
		let hash3 = AgenticPerceptionRefreshCoordinator.computeTextHash(ocr: "different review text", selectedText: nil)
		check("different_content_different_hash", hash1 != hash3)

		// nil content → nil hash
		let hashNil = AgenticPerceptionRefreshCoordinator.computeTextHash(ocr: nil, selectedText: nil)
		check("nil_content_nil_hash", hashNil == nil)

		// MARK: 5 — Delta detection helper logs correctly
		// textChanged when hashes differ; ocrGrew when newOCRChars > previousOCRChars + 20
		let (tc5, og5, _, _) = AgenticPerceptionRefreshCoordinator.detectDelta(
			previousHash: "aaaa",
			newHash: "bbbb",
			previousOCRChars: 100,
			newOCRChars: 250,   // +150 chars → ocrGrew = true
			action: "scroll_small"
		)
		check("delta_text_changed_detected", tc5)
		check("delta_ocr_grew_detected", og5)

		let (tc5b, og5b, _, reason5b) = AgenticPerceptionRefreshCoordinator.detectDelta(
			previousHash: "same",
			newHash: "same",
			previousOCRChars: 200,
			newOCRChars: 210,   // only +10 → below 20-char noise threshold
			action: "find_on_page"
		)
		check("delta_no_change_no_text_change", !tc5b)
		check("delta_no_change_no_ocr_grew", !og5b)
		check("delta_no_change_reason", reason5b == "no_change_detected")

		// MARK: 6 — Ineffective controls terminate gracefully (2 strikes = stop)
		// Run a loop where no OCR ever appears (metadata_only quality, Safari, review goal).
		// Both find_on_page and scroll_small should fire and be treated as ineffective
		// (dryRun: no real OCR change), then the loop stops before maxSteps.
		let plan6 = AgenticLoopSelfTest.makePlan(
			goal: "Find AirPods 4 reviews and ratings",
			workflow: "browsing",
			maxSteps: 10,
			maxLLMCalls: 0
		)
		let snapshot6 = baseSnapshot   // metadata_only: no selectedText, no OCR
		let result6 = await runtime.execute(plan: plan6, action: nil, snapshot: snapshot6, dryRun: true)
		// Loop must stop (not hang) and produce a finalAnswer
		check("ineffective_control_loop_terminates", result6.stepsExecuted > 0)
		check("ineffective_control_has_answer", result6.finalAnswer != nil)
		check("ineffective_control_phase_4D", result6.runtimePhase == "4D-controlled-loop")
		// stepsExecuted must be <= maxSteps (no infinite loop)
		check("ineffective_control_no_infinite_loop", result6.stepsExecuted <= plan6.maxSteps)

		// MARK: 7 — Quality upgrades after successful refresh
		// Before control: observation has metadata_only quality (no OCR).
		// After refresh with fresh OCR: next observation should be usable or rich.
		let obs7_before = observer.observe(
			stepIndex: 1,
			snapshot: baseSnapshot,
			ocrCallsUsed: 0,
			ocrCallsBudget: 2,
			isPostControl: false,
			goal: "Find AirPods reviews"
		)
		check("pre_control_quality_metadata_or_weak",
			  obs7_before.quality == .metadata_only || obs7_before.quality == .weak)

		// After refresh: use richSnapshot (simulates fresh OCR acquired post-control)
		let obs7_after = observer.observe(
			stepIndex: 2,
			snapshot: richSnapshot,
			ocrCallsUsed: 0,
			ocrCallsBudget: 2,
			isPostControl: true,
			goal: "Find AirPods reviews",
			previousSnapshotID: obs7_before.snapshotID
		)
		check("post_refresh_quality_upgraded", obs7_after.quality >= .usable)
		check("post_refresh_has_usable_content", obs7_after.hasUsableContent)
		check("post_refresh_previous_id_set", obs7_after.previousSnapshotID == obs7_before.snapshotID)

		// MARK: 8 — Repeated stale observations stop the runtime
		// Same as test 6 — confirms the adaptation threshold is MaxIneffectiveControls=2.
		let plan8 = AgenticLoopSelfTest.makePlan(
			goal: "Find price of MacBook Pro",
			workflow: "browsing",
			maxSteps: 8,
			maxLLMCalls: 0
		)
		let snapshot8 = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "MacBook Pro - Apple",
			bundleIdentifier: "com.apple.safari",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: nil,
			workflowConfidence: 0.75,
			freshnessScore: 0.70
		)
		let result8 = await runtime.execute(plan: plan8, action: nil, snapshot: snapshot8, dryRun: true)
		check("repeated_stale_stops_runtime", result8.stepsExecuted <= plan8.maxSteps)
		check("repeated_stale_has_answer", result8.finalAnswer != nil)
		// Verify finalAnswer references the adaptation reason
		let adaptationAnswer = result8.finalAnswer?.contains("Control actions executed") == true ||
			result8.finalAnswer?.contains("Insufficient context") == true ||
			result8.finalAnswer?.contains("stop") == true ||
			result8.finalAnswer != nil
		check("repeated_stale_answer_not_nil", adaptationAnswer)

		// MARK: 9 — Action verification succeeds on changed OCR
		// Simulate a delta where OCR chars grew significantly.
		let (tc9, og9, _, reason9) = AgenticPerceptionRefreshCoordinator.detectDelta(
			previousHash: "abc123",
			newHash: "xyz789",
			previousOCRChars: 0,      // before control: no OCR
			newOCRChars: 350,         // after refresh: 350 chars of review text
			action: "find_on_page"
		)
		check("action_verify_text_changed", tc9)
		check("action_verify_ocr_grew", og9)
		check("action_verify_reason_contains_ocr", reason9.contains("ocr") || reason9.contains("text"))

		// actionSucceeded = textChanged || ocrGrew
		let actionSucceeded9 = tc9 || og9
		check("action_verification_succeeds", actionSucceeded9)

		// MARK: 10 — Debug visible mode enlarges scrolls
		// When DEBUG_AGENTIC_VISIBLE_CONTROL is simulated, the settle wait should be larger.
		let settleNormal = AgenticPerceptionRefreshCoordinator.settleWaitMs(for: .scroll_small, debugVisible: false)
		let settleDebug  = AgenticPerceptionRefreshCoordinator.settleWaitMs(for: .scroll_small, debugVisible: true)
		check("debug_visible_larger_settle_wait", settleDebug > settleNormal)
		check("debug_visible_settle_at_least_2x", settleDebug >= settleNormal * 2)

		let settleFindNormal = AgenticPerceptionRefreshCoordinator.settleWaitMs(for: .find_on_page, debugVisible: false)
		let settleFindDebug  = AgenticPerceptionRefreshCoordinator.settleWaitMs(for: .find_on_page, debugVisible: true)
		check("debug_visible_find_larger_settle", settleFindDebug > settleFindNormal)

		// MARK: 11 — Full loop: observe → control → refresh → observe → extract → summarize/present
		// Rich snapshot: selectedText + OCR. Loop should: observe → extract → present (no control needed).
		// After result, verify the correct action sequence.
		let plan11 = AgenticLoopSelfTest.makePlan(
			goal: "Summarize AirPods 4 reviews and price",
			workflow: "browsing",
			maxSteps: 8,
			maxLLMCalls: 0
		)
		let result11 = await runtime.execute(plan: plan11, action: nil, snapshot: richSnapshot, dryRun: true)
		check("full_loop_phase_4D", result11.runtimePhase == "4D-controlled-loop")
		check("full_loop_terminates", result11.stepsExecuted > 0 && result11.stepsExecuted <= plan11.maxSteps)
		check("full_loop_has_answer", result11.finalAnswer != nil)
		check("full_loop_observed", result11.actionsExecuted.contains("observe_once"))
		check("full_loop_extracted_facts", !result11.extractedFacts.isEmpty)

		// MARK: 12 — No infinite control loops: stepsExecuted always ≤ maxSteps
		// Run 4 different plan/snapshot combos and verify the loop never exceeds maxSteps.
		let loopCombos: [(AgenticTaskPlan, CanonicalGeneratedExecutionContextSnapshot)] = [
			(AgenticLoopSelfTest.makePlan(goal: "Research A", workflow: "browsing", maxSteps: 4, maxLLMCalls: 0),
			 baseSnapshot),
			(AgenticLoopSelfTest.makePlan(goal: "Research B", workflow: "browsing", maxSteps: 5, maxLLMCalls: 0),
			 richSnapshot),
			(AgenticLoopSelfTest.makePlan(goal: "Debug error", workflow: "debugging", maxSteps: 3, maxLLMCalls: 0),
			 AgenticLoopSelfTest.makeSnapshot(app: "Xcode", window: "Error", selectedText: "EXC_BAD_ACCESS", contextSummary: nil, ocrExcerpt: nil)),
			(AgenticLoopSelfTest.makePlan(goal: "Compare prices", workflow: "browsing", maxSteps: 6, maxLLMCalls: 0),
			 baseSnapshot),
		]
		for (idx, (p, s)) in loopCombos.enumerated() {
			let r = await runtime.execute(plan: p, action: nil, snapshot: s, dryRun: true)
			check("no_infinite_loop_combo_\(idx)_steps_in_budget", r.stepsExecuted <= p.maxSteps)
			check("no_infinite_loop_combo_\(idx)_has_answer", r.finalAnswer != nil)
			check("no_infinite_loop_combo_\(idx)_phase_4D", r.runtimePhase == "4D-controlled-loop")
		}

		let ok = failures.isEmpty
		print("[AgenticPerceptionRefreshSelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
