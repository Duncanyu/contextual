import Foundation

/// Phase 17 stability guardrails (T17.10). Debug/env only — never call from app launch or SwiftUI body.
enum Phase17StabilitySelfTest {

	/// Run with `CONTEXTUAL_RUN_PHASE17_STABILITY_SELFTEST=1`. Synchronous; uses `Task.detached` (no main-runloop deadlock).
	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let sem = DispatchSemaphore(value: 0)
		Task.detached {
			let runtime = GeneratedExecutionRuntime()
			let probe = await runtime.phase17StabilityProbe()
			check("runtime_no_visual_scheduler", !probe.hasVisualScheduler)
			check("runtime_no_persistence", !probe.hasPersistenceManager)

			let nullProviderResult = try? await NullBoundedVisualContextProvider().collectVisualContext(
				request: BoundedVisualContextRequest(
					reason: "stability_probe",
					workflowType: .unknown,
					intentType: .unknown
				)
			)
			check("null_provider_unavailable", nullProviderResult?.status == .unavailable)

			let nullVisual = await VisualContextScheduler(provider: NullBoundedVisualContextProvider())
			let nullResult = await nullVisual.collect(
				request: BoundedVisualContextRequest(
					reason: "stability_probe",
					workflowType: .unknown,
					intentType: .unknown,
					budget: ExecutionBudget(allowsVision: true, allowsOCR: true)
				)
			)
			check(
				"null_scheduler_no_capture",
				nullResult.status == .unavailable || nullResult.status == .budgetDenied
			)
			sem.signal()
		}
		sem.wait()

		check("unified_ranker", UnifiedActionRanker.runSelfTest())
		check("result_presenter", GeneratedExecutionResultPresenter.runSelfTest())

		#if DEBUG
		UnifiedActionRankingDebug.resetCacheForTests()
		#endif

		let ok = failures.isEmpty
		print("[Phase17Stability] selftest ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}
