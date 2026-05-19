import Foundation

/// Supplies `GeneratedExecutionContext` from a canonical snapshot via the bridge (no reactive gathering).
struct BridgedGeneratedExecutionContextProvider: GeneratedExecutionContextProvider, Sendable {
	private let snapshot: CanonicalGeneratedExecutionContextSnapshot
	private let bridge: GeneratedExecutionContextBridge
	private let optionalVisualResult: BoundedVisualContextResult?

	init(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		bridge: GeneratedExecutionContextBridge = GeneratedExecutionContextBridge(),
		optionalVisualResult: BoundedVisualContextResult? = nil
	) {
		self.snapshot = snapshot
		self.bridge = bridge
		self.optionalVisualResult = optionalVisualResult
	}

	func gatherContext(for action: GeneratedExecutionAction) async throws -> GeneratedExecutionContext {
		var context = bridge.buildContext(from: snapshot, action: action)
		if let visual = optionalVisualResult,
		   visual.status == .completed || visual.status == .partial {
			context = context.merging(visual: visual)
		}
		if context.isExpired {
			throw GeneratedExecutionRuntimeError.executionUnavailable
		}
		if !context.satisfies(required: action.requiredContextTypes) {
			throw GeneratedExecutionRuntimeError.missingRequiredContext
		}
		return context
	}

	/// Ensures provider does not rebuild snapshots or recurse into context pipelines.
	static func runSelfTest() -> Bool {
		let now = Date()
		let snapshot = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Test",
			selectedText: "hello",
			availableContextTypes: [.textSnippet, .selectedText],
			generatedAt: now,
			freshnessScore: 0.8
		)
		let provider = BridgedGeneratedExecutionContextProvider(snapshot: snapshot)
		let plan = ExecutionPlan(
			primitives: [.summarizeContext],
			estimatedCost: 0.2,
			estimatedRuntime: 5,
			requiresVision: false,
			requiresOCR: false,
			requiresUserIntent: false,
			requiredPermissions: [.none],
			fallbackBehavior: .failFast,
			executionBudget: .conservative,
			planConfidence: 0.7
		)
		let action = GeneratedExecutionAction(
			title: "Bridge provider test",
			description: "Test",
			workflowType: .writing,
			intentType: .summarize,
			confidence: 0.7,
			interruptionCost: 0.2,
			requiredContextTypes: [.textSnippet],
			executionPlan: plan,
			explainabilitySummary: "bridge_self_test",
			generationSource: .selfTest,
			createdAt: now,
			expirationDate: now.addingTimeInterval(300),
			isReusable: false,
			reuseScore: 0
		)
		let sem = DispatchSemaphore(value: 0)
		var ok = false
		Task.detached {
			do {
				let ctx = try await provider.gatherContext(for: action)
				ok = ctx.primarySourceText == "hello"
			} catch {
				ok = false
			}
			sem.signal()
		}
		sem.wait()
		return ok
	}
}
