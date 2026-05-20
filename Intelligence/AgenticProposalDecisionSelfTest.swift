import Foundation

/// T18.3.4 — Two-Stage Agentic Proposal Pipeline self-tests.
/// Verifies decision stage behavior: quiet/think/needs-context outcomes,
/// timeout fingerprint cooldown, static action suppression.
/// Not wired to app launch; run via self-test harness only.
enum AgenticProposalDecisionSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let engine = AgenticProposalDecisionEngine()
		let now = Date()

		// MARK: 1 — Weak browser metadata (no text, metadata-only source)
		// Expectation: decision is quiet or needsMoreContext; large LLM should NOT be called.

		let weakSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "Apple",
			generatedAt: now
		)
		let weakSituational = SituationalContextSynthesizer.synthesize(from: weakSnap, referenceTime: now)
		let weakDecision = await engine.decide(snapshot: weakSnap, situational: weakSituational, referenceTime: now)
		// Weak browser metadata with no text → should NOT ask large model to think.
		check("weak_browser_no_large_model", !weakDecision.shouldThink || weakDecision.needsMoreContext)
		check("weak_browser_decision_source_not_nil", !weakDecision.reason.isEmpty)

		// MARK: 2 — Fresh Xcode-like context (strong workflow signal)
		// Expectation: shouldThink may be true when workflow+metadata are present.

		let xcodeSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Xcode",
			windowTitle: "MyApp — ContentView.swift — fatal error: index out of range",
			generatedAt: now
		)
		let xcodeSituational = SituationalContextSynthesizer.synthesize(from: xcodeSnap, referenceTime: now)
		let xcodeDecision = await engine.decide(snapshot: xcodeSnap, situational: xcodeSituational, referenceTime: now)
		// With a rich window title (error pattern), metadata is non-empty → at minimum has metadata.
		check("xcode_decision_non_nil_reason", !xcodeDecision.reason.isEmpty)
		check("xcode_decision_source_valid", xcodeDecision.decisionSource == .heuristic || xcodeDecision.decisionSource == .microModel)

		// MARK: 3 — Low-value context (empty window title, unknown workflow)
		// Expectation: decision stays quiet (shouldThink=false, needsMoreContext=false).

		let emptySnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Finder",
			windowTitle: "",
			generatedAt: now
		)
		let emptySituational = SituationalContextSynthesizer.synthesize(from: emptySnap, referenceTime: now)
		let emptyDecision = await engine.decide(snapshot: emptySnap, situational: emptySituational, referenceTime: now)
		// Truly empty context should not trigger large model.
		check("empty_context_no_think", !emptyDecision.shouldThink || emptyDecision.needsMoreContext)

		// MARK: 4 — Decision source is always a known value

		for decision in [weakDecision, xcodeDecision, emptyDecision] {
			let validSources: [AgenticDecisionSource] = [.heuristic, .microModel, .inherited]
			check("decision_source_known_\(decision.reason)", validSources.contains(decision.decisionSource))
		}

		// MARK: 5 — Timeout fingerprint cooldown: second call within cooldown window returns quiet

		let timeoutSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Firefox",
			windowTitle: "Lecture slides",
			generatedAt: now
		)
		let timeoutSituational = SituationalContextSynthesizer.synthesize(from: timeoutSnap, referenceTime: now)
		let fp = AgenticProposalDecisionEngine.contextFingerprint(snapshot: timeoutSnap, situational: timeoutSituational)

		// Record a timeout for this fingerprint.
		await engine.recordTimeout(fingerprint: fp, at: now)

		// Immediately after recording, the engine should apply the cooldown.
		let cooldownDecision = await engine.decide(
			snapshot: timeoutSnap,
			situational: timeoutSituational,
			referenceTime: now.addingTimeInterval(5) // 5s later — still within 45s cooldown
		)
		check("timeout_cooldown_suppresses_think", !cooldownDecision.shouldThink)
		check("timeout_cooldown_reason", cooldownDecision.reason == "timeout_cooldown")

		// After the cooldown window (46s), the suppression should lift.
		let afterCooldown = await engine.decide(
			snapshot: timeoutSnap,
			situational: timeoutSituational,
			referenceTime: now.addingTimeInterval(46)
		)
		// After cooldown, the engine can consider thinking again (result depends on context quality).
		check("after_cooldown_reason_not_timeout", afterCooldown.reason != "timeout_cooldown")

		// MARK: 6 — Static actions are NOT resurrected

		let staticIds = ["summarize_text", "explain_text", "rewrite_text"]
		for id in staticIds {
			check("static_action_suppressed_\(id)", DynamicOnlyProposalMode.isGenericStaticAction(id))
		}
		check("dynamic_not_static", !DynamicOnlyProposalMode.isGenericStaticAction("llm_dynamic"))
		check("dynamic_mode_enabled", DynamicOnlyProposalMode.isEnabled)

		// MARK: 7 — Fingerprint is deterministic (same inputs produce same fingerprint)

		let fp1 = AgenticProposalDecisionEngine.contextFingerprint(snapshot: timeoutSnap, situational: timeoutSituational)
		let fp2 = AgenticProposalDecisionEngine.contextFingerprint(snapshot: timeoutSnap, situational: timeoutSituational)
		check("fingerprint_deterministic", fp1 == fp2)
		check("fingerprint_non_empty", !fp1.isEmpty)

		// MARK: 8 — AgenticProposalDecision factory helpers

		let quietDec = AgenticProposalDecision.quiet(reason: "test_quiet")
		check("quiet_factory_shouldThink", !quietDec.shouldThink)
		check("quiet_factory_needsMoreContext", !quietDec.needsMoreContext)
		check("quiet_factory_reason", quietDec.reason == "test_quiet")

		let needsCtx = AgenticProposalDecision.needsContext(kind: .visual, reason: "needs_visual")
		check("needsContext_factory_shouldThink", !needsCtx.shouldThink)
		check("needsContext_factory_needsMoreContext", needsCtx.needsMoreContext)
		check("needsContext_factory_kind", needsCtx.recommendedContextKind == .visual)

		// MARK: 9 — Decision-stage diag tags map to correct failure reasons

		let visualTag = "diag:decision_needs_more_context:visual"
		let visualReason = GeneratedProposalDebugStatusBuilder.failureReasonForTag_testOnly(visualTag)
		check("visual_tag_maps", visualReason == .visualContextRecommended)

		let cooldownTag = "diag:decision_timeout_cooldown"
		let cooldownReason = GeneratedProposalDebugStatusBuilder.failureReasonForTag_testOnly(cooldownTag)
		check("cooldown_tag_maps", cooldownReason == .contextChanged)

		let quietTag = "diag:decision_quiet"
		let quietReason = GeneratedProposalDebugStatusBuilder.failureReasonForTag_testOnly(quietTag)
		check("quiet_tag_maps", quietReason == .modelChoseNoChime)

		let contextTag = "diag:decision_needs_more_context:context"
		let contextReason = GeneratedProposalDebugStatusBuilder.failureReasonForTag_testOnly(contextTag)
		check("context_tag_maps", contextReason == .insufficientContext)

		let ok = failures.isEmpty
		print("[AgenticProposalDecisionSelfTest] selftest ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}
