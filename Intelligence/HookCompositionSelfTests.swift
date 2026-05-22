import Foundation

/// Hook-Based Action Composition self-tests.
///
/// NOTE: The active foundational hook catalog is fully active by default.
/// These self-tests verify that composition successfully reaches discovery, maps categories
/// and outputs valid Dynamic Plans for Case A and Case B, while failing quietly on pure control cases.
///
/// Run with env var: `CONTEXTUAL_RUN_HOOK_COMPOSITION_SELFTEST=1`
///
/// Expected output:
///   [HookCompositionSelfTest] started
///   [HookAudit] total=...
///   [HookAudit] implemented=...
///   [HookAudit] placeholders=...
///   [HookAudit] by_category=...
///   [HookCompositionSelfTest] case=compare_products result=pass expected=non-nil
///   [HookCompositionSelfTest] case=explain_code result=pass expected=non-nil
///   [HookCompositionSelfTest] case=play_music result=pass expected=nil
///   [HookCompositionSelfTest] case=turn_on_dnd result=pass expected=nil
///   [HookCompositionSelfTest] ok=true failures=0
enum HookCompositionSelfTests {

	static func run() async -> Bool {
		print("[HookCompositionSelfTest] started")

		// Enable [HookAudit] so startup summary is visible during self-test.
		HookCapabilityRegistry.hookAuditEnabled = true
		// Accessing .shared triggers HookCapabilityRegistry.init(), which emits [HookAudit] lines.
		let registry = HookCapabilityRegistry.shared

		var failures: [String] = []

		// MARK: - Case A: Compare products (expects valid dynamic plan containing compare_items & extract_product_attributes, no extract_tasks)

		let caseAResult = await compositionResult(
			goal: "compare product prices and features",
			categories: ["compare", "extract"],
			workflow: .browsing,
			registry: registry
		)
		let caseAPassed = caseAResult != nil
		if !caseAPassed {
			failures.append("compare_products: result was nil")
			print("[HookCompositionSelfTest] FAIL compare_products: result was nil")
		} else if let ids = caseAResult?.contract.hookPlanIds {
			let hasCompare = ids.contains("compare_items")
			let hasAttr = ids.contains("extract_product_attributes")
			let leaksTasks = ids.contains("extract_tasks")
			if !hasCompare || !hasAttr || leaksTasks {
				failures.append("compare_products: invalid chain \(ids)")
				print("[HookCompositionSelfTest] FAIL compare_products: invalid chain \(ids)")
			}
		}
		if !failures.contains(where: { $0.hasPrefix("compare_products") }) {
			print("[HookCompositionSelfTest] case=compare_products result=pass expected=non-nil")
		}

		// MARK: - Case B: Explain code (expects valid dynamic plan containing explain_error or explain_code)

		let caseBResult = await compositionResult(
			goal: "explain the error in this code",
			categories: ["reason", "extract"],
			workflow: .debugging,
			registry: registry
		)
		let caseBPassed = caseBResult != nil
		if !caseBPassed {
			failures.append("explain_code: result was nil")
			print("[HookCompositionSelfTest] FAIL explain_code: result was nil")
		} else if let ids = caseBResult?.contract.hookPlanIds {
			let hasExplain = ids.contains("explain_error") || ids.contains("explain_code")
			if !hasExplain {
				failures.append("explain_code: invalid chain \(ids)")
				print("[HookCompositionSelfTest] FAIL explain_code: invalid chain \(ids)")
			}
		}
		if !failures.contains(where: { $0.hasPrefix("explain_code") }) {
			print("[HookCompositionSelfTest] case=explain_code result=pass expected=non-nil")
		}

		// MARK: - Case C: Play music (control-only → must fail quietly)

		let caseCResult = await compositionResult(
			goal: "play my study playlist",
			categories: ["control"],
			workflow: .unknown,
			registry: registry
		)
		let caseCPassed = caseCResult == nil
		if !caseCPassed { failures.append("play_music") }
		print("[HookCompositionSelfTest] case=play_music result=\(caseCPassed ? "pass" : "FAIL") expected=nil actual=\(caseCResult == nil ? "nil" : "non-nil")")

		// MARK: - Case D: Turn on Do Not Disturb (control-only → must fail quietly)

		let caseDResult = await compositionResult(
			goal: "turn on do not disturb",
			categories: ["control"],
			workflow: .unknown,
			registry: registry
		)
		let caseDPassed = caseDResult == nil
		if !caseDPassed { failures.append("turn_on_dnd") }
		print("[HookCompositionSelfTest] case=turn_on_dnd result=\(caseDPassed ? "pass" : "FAIL") expected=nil actual=\(caseDResult == nil ? "nil" : "non-nil")")

		// MARK: - Summary

		let ok = failures.isEmpty
		print("[HookCompositionSelfTest] ok=\(ok) failures=\(failures.count)")
		return ok
	}

	// MARK: - Manual compose probe (for CONTEXTUAL_DEBUG_COMPOSE_ACTION)

	/// Runs a single composition with the given goal and logs discovery passes.
	/// Triggered by `CONTEXTUAL_DEBUG_COMPOSE_ACTION="<goal>"`.
	/// The goal string is tokenized to infer plausible categories for testing.
	static func runManualCompose(goal: String) async {
		// Enable [HookAudit] for the debug session.
		HookCapabilityRegistry.hookAuditEnabled = true
		print("[HookCompositionDebug] manual_compose goal=\"\(goal)\"")

		let categories = inferCategoriesForDebug(goal: goal)
		print("[HookCompositionDebug] inferred_categories=[\(categories.joined(separator: ","))]")

		let result = await compositionResult(
			goal: goal,
			categories: categories,
			workflow: .unknown,
			registry: .shared
		)

		if let result {
			print("[HookCompositionDebug] result=non-nil executable=yes title=\"\(result.contract.title)\" chain=[\(result.contract.hookPlanIds.joined(separator: ","))] confidence=\(String(format: "%.2f", result.contract.confidence))")
		} else {
			print("[HookCompositionDebug] result=nil (no executable contract — fail quietly)")
		}
	}

	// MARK: - Helpers

	private static func compositionResult(
		goal: String,
		categories: [String],
		workflow: InferredWorkflow,
		registry: HookCapabilityRegistry
	) async -> TaskInferencePlanningPipeline.PlanningOutput? {
		let now = Date()
		let inference = TaskInferenceResult(
			shouldChime: true,
			possibleUserGoal: goal,
			confidence: 0.75,
			neededCapabilityCategories: categories,
			whyNow: "selftest",
			missingContext: [],
			expirySeconds: 30,
			createdAt: now,
			need: [],
			needReason: nil
		)

		let snap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "SelfTest",
			windowTitle: "HookCompositionSelfTest",
			inferredWorkflow: workflow,
			workflowConfidence: 0.8,
			generatedAt: now,
			freshnessScore: 0.8
		)
		let situational = SituationalContextSynthesizer.synthesize(from: snap, referenceTime: now)

		return await TaskInferencePlanningPipeline.compose(
			inference: inference,
			snapshot: snap,
			situational: situational,
			recentTitles: [],
			registry: registry,
			referenceTime: now
		)
	}

	/// Heuristic: infer plausible capability categories from a freeform goal string.
	/// Used only for the manual debug probe — not for production inference.
	private static func inferCategoriesForDebug(goal: String) -> [String] {
		let lower = goal.lowercased()
		var cats: [String] = []
		if lower.contains("compar") || lower.contains("vs") || lower.contains("versus") || lower.contains("differ") {
			cats.append("compare")
		}
		if lower.contains("explain") || lower.contains("why") || lower.contains("reason") || lower.contains("understand") || lower.contains("error") {
			cats.append("reason")
		}
		if lower.contains("extract") || lower.contains("find") || lower.contains("list") || lower.contains("show") || lower.contains("price") {
			cats.append("extract")
		}
		if lower.contains("summar") || lower.contains("overview") || lower.contains("brief") {
			cats.append("reason")
		}
		if lower.contains("organiz") || lower.contains("sort") || lower.contains("group") {
			cats.append("organize")
		}
		if lower.contains("play") || lower.contains("pause") || lower.contains("open") || lower.contains("launch") || lower.contains("turn on") || lower.contains("enable") {
			cats.append("control")
		}
		if cats.isEmpty {
			// Default: context + reason covers most generic goals.
			cats = ["context", "reason"]
		}
		return Array(Set(cats))
	}
}
