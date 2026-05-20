import Foundation

/// T18.2 sparse visual peek self-tests (not wired to app launch).
enum SparseVisualPeekSelfTest {

	static func run() async -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let gate = SparseVisualPeekGate()
		await gate.resetForTests()
		let now = Date()
		let bridge = GeneratedExecutionContextBridge()

		let strongSelection = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Xcode",
			inferredWorkflow: .debugging,
			selectedText: String(repeating: "x", count: 40),
			generatedAt: now,
			freshnessScore: 0.8,
			sourceMetadata: CanonicalExecutionSourceMetadata(selectedTextCapturedAt: now)
		)
		let denySelection = SparseVisualPeekPolicy.shouldRequestVisualPeek(
			snapshot: strongSelection,
			gateEvaluation: SparseVisualPeekGateEvaluation(shouldDeny: false, denyReason: nil)
		)
		check(
			"strong_selection_denies",
			!denySelection.shouldPeek
				&& denySelection.denyReason == SparseVisualPeekDenyReason.selectedTextSufficient
		)

		let weakWorkflow = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			inferredWorkflow: .browsing,
			clipboardText: "stale copy",
			workflowConfidence: 0.2,
			permissionAvailability: [.screenRecording: true],
			generatedAt: now,
			freshnessScore: 0.25,
			sourceMetadata: CanonicalExecutionSourceMetadata(
				clipboardCapturedAt: now.addingTimeInterval(-180)
			),
			packetIsStale: true
		)
		let allowWeak = SparseVisualPeekPolicy.shouldRequestVisualPeek(
			snapshot: weakWorkflow,
			gateEvaluation: SparseVisualPeekGateEvaluation(shouldDeny: false, denyReason: nil)
		)
		check("weak_workflow_allows", allowWeak.shouldPeek)

		let freshVisualSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Finder",
			inferredWorkflow: .browsing,
			visualContextAvailability: GeneratedExecutionVisualContextAvailability(
				hasVisualDescriptor: true,
				visualSummaryExcerpt: "recent",
				visualCapturedAt: now,
				visualExpiresAt: now.addingTimeInterval(60)
			),
			permissionAvailability: [.screenRecording: true],
			generatedAt: now,
			freshnessScore: 0.3
		)
		let gateFresh = await gate.evaluate(snapshot: freshVisualSnap, referenceTime: now)
		check(
			"fresh_visual_gate_denies",
			gateFresh.shouldDeny
				&& gateFresh.denyReason == SparseVisualPeekDenyReason.recentVisualContextStillFresh
		)

		let ocrPlan = ExecutionPlan(
			primitives: [.summarizeContext],
			estimatedCost: 0.3,
			estimatedRuntime: 10,
			requiresVision: false,
			requiresOCR: true,
			requiresUserIntent: false,
			requiredPermissions: [.screenRecording],
			fallbackBehavior: .failFast,
			executionBudget: ExecutionBudget(allowsVision: true, allowsOCR: true),
			planConfidence: 0.7
		)
		let ocrAction = GeneratedExecutionAction(
			title: "OCR test",
			description: "test",
			workflowType: .debugging,
			intentType: .explain,
			confidence: 0.7,
			interruptionCost: 0.2,
			requiredContextTypes: [.fusedVisual],
			executionPlan: ocrPlan,
			explainabilitySummary: "test",
			generationSource: .selfTest,
			createdAt: now,
			expirationDate: now.addingTimeInterval(120),
			isReusable: false,
			reuseScore: 0
		)
		let weakSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "App",
			inferredWorkflow: .unknown,
			permissionAvailability: [.screenRecording: true],
			generatedAt: now,
			freshnessScore: 0.2
		)
		let ocrAllow = SparseVisualPeekPolicy.shouldRequestVisualPeek(
			snapshot: weakSnap,
			action: ocrAction,
			gateEvaluation: SparseVisualPeekGateEvaluation(shouldDeny: false, denyReason: nil)
		)
		check(
			"action_requires_ocr_allows",
			ocrAllow.shouldPeek
				&& ocrAllow.allowReason == SparseVisualPeekAllowReason.actionRequiresVisionOrOCR
		)

		let budgetDenyPlan = ExecutionPlan(
			primitives: [.summarizeContext],
			estimatedCost: 0.3,
			estimatedRuntime: 10,
			requiresVision: true,
			requiresOCR: true,
			requiresUserIntent: false,
			requiredPermissions: [.none],
			fallbackBehavior: .failFast,
			executionBudget: ExecutionBudget(allowsVision: false, allowsOCR: false),
			planConfidence: 0.7
		)
		let budgetDenyAction = GeneratedExecutionAction(
			title: "Budget deny",
			description: "test",
			workflowType: .debugging,
			intentType: .explain,
			confidence: 0.7,
			interruptionCost: 0.2,
			requiredContextTypes: [],
			executionPlan: budgetDenyPlan,
			explainabilitySummary: "test",
			generationSource: .selfTest,
			createdAt: now,
			expirationDate: now.addingTimeInterval(120),
			isReusable: false,
			reuseScore: 0
		)
		let budgetDeny = SparseVisualPeekPolicy.shouldRequestVisualPeek(
			snapshot: weakSnap,
			action: budgetDenyAction,
			gateEvaluation: SparseVisualPeekGateEvaluation(shouldDeny: false, denyReason: nil)
		)
		check(
			"budget_denies",
			!budgetDeny.shouldPeek && budgetDeny.denyReason == SparseVisualPeekDenyReason.budgetLikelyDenied
		)

		let noSchedulerRuntime = GeneratedExecutionRuntime(canonicalSnapshot: weakSnap)
		let probe = await noSchedulerRuntime.phase18SparseVisualPeekProbe()
		check("nil_scheduler_no_peek", !probe.attemptedPeek && !probe.hasScheduler)

		let scheduler = VisualContextScheduler(provider: NullBoundedVisualContextProvider())
		let withScheduler = GeneratedExecutionRuntime(
			visualContextScheduler: scheduler,
			canonicalSnapshot: weakSnap
		)
		let probe2 = await withScheduler.phase18SparseVisualPeekProbe()
		check("scheduler_injected", probe2.hasScheduler)

		let visualResult = BoundedVisualContextResult(
			requestId: UUID(),
			status: .completed,
			capturedAt: now,
			sourceSummary: "stub",
			ocrExcerpt: "screen line",
			visualSummary: "layout hint",
			visualTags: ["stub"],
			expiresAt: now.addingTimeInterval(30)
		)
		let base = bridge.buildContext(from: weakSnap)
		let merged = base.merging(visual: visualResult)
		check(
			"visual_merges",
			merged.hasActiveVisualContext && merged.ocrTextExcerpt == "screen line"
		)

		let det1 = SparseVisualPeekPolicy.shouldRequestVisualPeek(
			snapshot: weakWorkflow,
			gateEvaluation: SparseVisualPeekGateEvaluation(shouldDeny: false, denyReason: nil),
			referenceTime: now
		)
		let det2 = SparseVisualPeekPolicy.shouldRequestVisualPeek(
			snapshot: weakWorkflow,
			gateEvaluation: SparseVisualPeekGateEvaluation(shouldDeny: false, denyReason: nil),
			referenceTime: now
		)
		check("decision_deterministic", det1 == det2)


		// MARK: Runtime handoff — visual peek only on explicit visual-required execution

		let countingProvider = SparseVisualPeekCountingProvider(capturedAt: now)
		let countingScheduler = VisualContextScheduler(provider: countingProvider)
		let visualRuntime = GeneratedExecutionRuntime(
			visualContextScheduler: countingScheduler,
			canonicalSnapshot: weakSnap
		)
		let visualAction = GeneratedExecutionAction(
			title: "Visual peek action",
			description: "test",
			workflowType: .browsing,
			intentType: .structure,
			confidence: 0.7,
			interruptionCost: 0.2,
			requiredContextTypes: [.none],
			executionPlan: ExecutionPlan(
				primitives: [.summarizeContext],
				estimatedCost: 0.2,
				estimatedRuntime: 5,
				requiresVision: true,
				requiresOCR: true,
				requiresUserIntent: true,
				requiredPermissions: [.screenRecording],
				fallbackBehavior: .failFast,
				executionBudget: ExecutionBudget(allowsVision: true, allowsOCR: true),
				planConfidence: 0.7
			),
			explainabilitySummary: "test",
			generationSource: .selfTest,
			createdAt: now,
			expirationDate: now.addingTimeInterval(60),
			isReusable: false,
			reuseScore: 0
		)
		let outcome = await visualRuntime.start(action: visualAction)
		let callCount = await countingProvider.callCount
		check("runtime_visual_peek_called_once", callCount == 1)
		if case .completed(let res) = outcome {
			check("runtime_visual_meta_performed", res.executionMetadata["visual_enrichment_performed"] == "1")
		} else {
			check("runtime_visual_outcome_completed", false)
		}

		// Second execution within cooldown should not collect visual again.
		await visualRuntime.reset()
		_ = await visualRuntime.start(action: visualAction)
		let callCount2 = await countingProvider.callCount
		check("runtime_visual_peek_cooldown_blocks_second", callCount2 == 1)
		await gate.resetForTests()
		await gate.recordPeekCompleted(at: now)
		let cooldown = await gate.evaluate(snapshot: weakWorkflow, referenceTime: now.addingTimeInterval(5))
		check(
			"cooldown_active",
			cooldown.shouldDeny && cooldown.denyReason == SparseVisualPeekDenyReason.cooldownWindowActive
		)

		let ok = failures.isEmpty
		print("[SparseVisualPeek] selftest ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}


private actor SparseVisualPeekCountingProvider: BoundedVisualContextProvider {
	private let capturedAt: Date
	private(set) var callCount: Int = 0

	init(capturedAt: Date) {
		self.capturedAt = capturedAt
	}

	func collectVisualContext(request: BoundedVisualContextRequest) async throws -> BoundedVisualContextResult {
		callCount += 1
		return BoundedVisualContextResult(
			requestId: request.id,
			status: .completed,
			capturedAt: capturedAt,
			sourceSummary: "counting",
			ocrExcerpt: "visible text",
			visualSummary: "summary",
			visualTags: ["stub"],
			expiresAt: request.expiresAt
		)
	}
}
