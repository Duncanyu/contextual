import Foundation

/// Phase 4S — Verifies that a strong-title fast-visibility detection enqueues
/// a pending action-intent retry instead of producing an executable action.
///
/// Run with: `CONTEXTUAL_RUN_ACTION_INTENT_RETRY_SELFTEST=1`
///
/// Note: This is intentionally a logic-only self-test. It does not call Ollama.
enum ActionIntentRetrySelfTest {
	@MainActor
	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok {
				print("[ActionIntentRetrySelfTest] FAIL \(name)")
				failures.append(name)
			} else {
				print("[ActionIntentRetrySelfTest] PASS \(name)")
			}
		}

		let now = Date()
		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Anker Prime USB C Charger Block, 160W 3-Port GaN Charger",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: "Anker Prime USB C Charger Block 160W 3-Port GaN",
			contextSummary: "",
			workflowConfidence: 0.8,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.9
		)
		let situational = SituationalContextSynthesizer.synthesize(from: snap, referenceTime: now)

		// 1) Fast visibility must not generate an action result when warmup isn't ready.
		let res = await TaskInferenceEngine.shared.infer(
			snapshot: snap,
			situational: situational,
			recentTitles: [snap.windowTitle],
			history: nil,
			referenceTime: now,
			isWarmupReady: false
		)
		check("fast_visibility_no_task_inference_action", res == nil)

		// 2) Weak/generic titles should not be eligible for fast visibility.
		let weakSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Firefox",
			bundleIdentifier: "org.mozilla.firefox",
			inferredWorkflow: .browsing,
			selectedText: nil,
			clipboardText: nil,
			recentOCRExcerpt: nil,
			contextSummary: "",
			workflowConfidence: 0.2,
			availableContextTypes: [],
			permissionAvailability: [:],
			generatedAt: now,
			freshnessScore: 0.2
		)
		let weakSituational = SituationalContextSynthesizer.synthesize(from: weakSnap, referenceTime: now)
		let res2 = await TaskInferenceEngine.shared.infer(
			snapshot: weakSnap,
			situational: weakSituational,
			recentTitles: [weakSnap.windowTitle],
			history: nil,
			referenceTime: now,
			isWarmupReady: false
		)
		check("generic_title_does_not_generate_action", res2 == nil)

		// 3) Pending retry storage + pop on warmup readiness.
		do {
			LocalAISettings.shared.twoStageTaskInferenceEnabled = true
			let delegate = AppDelegate()
			delegate.debugSetContextPipelineGeneration(1)

			var ctx = ContextModel()
			ctx.activeAppName = "Firefox"
			ctx.activeAppBundleIdentifier = "org.mozilla.firefox"
			ctx.activeWindowTitle = snap.windowTitle
			ctx.updatedAt = now

			let packet = TriggerPacket(
				triggerType: .contextMetadataEligible,
				reason: "selftest",
				candidateActions: [],
				createdAt: now
			)

			delegate.storePendingActionIntentIfNeeded(
				packet: packet,
				context: ctx,
				snapshot: snap,
				situational: situational,
				generation: 1,
				fingerprint: "fp_test",
				title: snap.windowTitle,
				classification: .actionWorthy
			)
			check("pending_stored", delegate.debugHasPendingActionIntentRequest)

			delegate.debugSetTwoStageWarmupComplete(true)
			// The pending request must survive context-pipeline generation churn during warmup.
			delegate.debugSetContextPipelineGeneration(2)
			let popped = delegate.popPendingActionIntentIfReady(now: now, reason: "planner_became_ready")
			check("pending_popped_on_warmup", popped?.fingerprint == "fp_test")
			check("pending_cleared_after_pop", delegate.debugHasPendingActionIntentRequest == false)

			// Expiry path.
			delegate.storePendingActionIntentIfNeeded(
				packet: packet,
				context: ctx,
				snapshot: snap,
				situational: situational,
				generation: 1,
				fingerprint: "fp_expire",
				title: snap.windowTitle,
				classification: .actionWorthy
			)
			check("pending_stored_for_expiry", delegate.debugPendingActionIntentFingerprint == "fp_expire")
			delegate.expirePendingActionIntentIfNeeded(now: now.addingTimeInterval(60))
			check("pending_expires", delegate.debugHasPendingActionIntentRequest == false)

			// Bundle-change expiry (should not retry if app family changed).
			delegate.storePendingActionIntentIfNeeded(
				packet: packet,
				context: ctx,
				snapshot: snap,
				situational: situational,
				generation: 1,
				fingerprint: "fp_bundle_change",
				title: snap.windowTitle,
				classification: .actionWorthy
			)
			check("pending_stored_for_bundle_change", delegate.debugPendingActionIntentFingerprint == "fp_bundle_change")
			// Simulate a different active app in the context builder.
			delegate.debugSetActiveAppForSelfTest(
				bundleIdentifier: "com.apple.dt.Xcode",
				appName: "Xcode",
				windowTitle: "Contextual.xcodeproj"
			)
			let popped2 = delegate.popPendingActionIntentIfReady(now: now, reason: "planner_became_ready")
			check("pending_dropped_on_bundle_change", popped2 == nil && delegate.debugHasPendingActionIntentRequest == false)
		}

		let ok = failures.isEmpty
		print("[ActionIntentRetrySelfTest] ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ","))")
		return ok
	}
}
