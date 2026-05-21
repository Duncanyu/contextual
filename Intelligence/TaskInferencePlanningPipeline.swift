import Foundation

/// Deterministic planning pipeline:
/// - Input: `TaskInferenceResult` (goal + capability categories; no hook ids).
/// - Retrieves hooks by category.
/// - Plans a bounded executable hook chain.
/// - Emits `DynamicGeneratedActionContract` + `ValidatedDynamicGeneratedProposal`.
///
/// No large model calls. No hardcoded user behavior labels. Hooks are the building blocks.
enum TaskInferencePlanningPipeline {

	struct PlanningOutput: Sendable, Equatable {
		let contract: DynamicGeneratedActionContract
		let proposal: ValidatedDynamicGeneratedProposal
	}

	static func compose(
		inference: TaskInferenceResult,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		recentTitles: [String],
		registry: HookCapabilityRegistry = .shared,
		referenceTime: Date = Date()
	) async -> PlanningOutput? {
		guard inference.shouldChime else { return nil }
		guard inference.confidence >= 0.42 else { return nil }

		let cats = normalizeCats(inference.neededCapabilityCategories)
		guard !cats.isEmpty else {
			print("[HookPlanner] skipped reason=no_needCats")
			return nil
		}

		// 1) Retrieve hooks by category (not a global top-k list).
		async let retrievedAsync: [HookCapabilityDefinition] = HookCategoryRetriever.retrieveAsync(
			needCats: cats,
			snapshot: snapshot,
			situational: situational,
			registry: registry
		)
		async let safetyAsync: HookPlanningSafetyEvaluation = HookPlanningSafetyChecker.evaluateAsync(
			needCats: cats,
			snapshot: snapshot,
			situational: situational
		)

		let retrieved = await retrievedAsync
		let safety = await safetyAsync
		if safety.shouldAbort {
			print("[HookPlanner] skipped reason=\(safety.abortReason ?? "safety_abort")")
			return nil
		}

		// 2) Plan chain + gap check.
		let plan = HookGraphPlanner.plan(
			needCats: cats,
			retrievedHooks: retrieved,
			snapshot: snapshot,
			situational: situational
		)
		if !plan.missingCategories.isEmpty {
			print("[HookPlanner] gaps missingCats=[\(plan.missingCategories.joined(separator: ","))] reason=no_implemented_hooks")
		}
		guard !plan.hookIds.isEmpty else { return nil }

		let workflow = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
		let primitives = HookCapabilityRegistry.primitives(from: plan.usedHooks)
		let intent = inferIntent(from: primitives)

		let title = synthesizeTitle(goal: inference.possibleUserGoal, workflow: workflow, intent: intent)
		let question = synthesizeQuestion(goal: inference.possibleUserGoal, title: title)

		let requiredContext = minimizedRequiredContext(
			from: plan.usedHooks,
			snapshot: snapshot,
			situational: situational
		)

		let fp = TaskInferenceEngine.fingerprint(snapshot: snapshot, situational: situational, recentTitles: recentTitles)
		let catSig = cats.joined(separator: ",")
		let catHash = abs(catSig.hashValue)

		let contract = DynamicGeneratedActionContract(
			id: "hook:\(fp)|c\(catHash)",
			title: title,
			userFacingQuestion: question,
			inferredUserGoal: inference.possibleUserGoal,
			situationSummary: String(situational.situationalSummary.prefix(160)),
			whyNow: inference.whyNow.isEmpty ? "inferred" : inference.whyNow,
			hookPlanIds: plan.hookIds,
			requiredContext: requiredContext,
			confidence: min(0.98, max(0.05, inference.confidence)),
			createdAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(max(8, min(60, inference.expirySeconds))),
			cacheEligibility: inference.confidence >= 0.66,
			cacheKey: fp
			)

			let chain = plan.hookIds.joined(separator: ",")
			let missingCats = plan.missingCategories.isEmpty ? "none" : plan.missingCategories.joined(separator: ",")
			print("[HookRetriever] cats=[\(cats.joined(separator: ","))] retrieved=\(retrieved.count) implemented=\(plan.usedHooks.count)")
			print("[HookPlanner] chain=\(chain) missingCats=\(missingCats)")
			print("[HookComposer] synthesized title=\(contract.title) hooks=\(plan.hookIds.count)")

		let proposal = ValidatedDynamicGeneratedProposal(
			id: contract.id,
			title: contract.title,
			description: contract.userFacingQuestion,
			workflowType: workflow,
			intentType: intent,
			expectedOutcome: contract.inferredUserGoal,
			requiredContextTypes: contract.requiredContext,
			suggestedPrimitives: primitives,
			interruptionCost: interruptionCost(workflow: workflow, confidence: contract.confidence),
			confidence: contract.confidence,
			usefulnessHint: "hook_composer_model"
		)

		return PlanningOutput(contract: contract, proposal: proposal)
	}

	// MARK: - Helpers

	private static func normalizeCats(_ raw: [String]) -> [String] {
		var seen: Set<String> = []
		return raw
			.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.filter { seen.insert($0).inserted }
			.prefix(8)
			.map { $0 }
	}

	private static func inferIntent(from primitives: [ExecutionPrimitive]) -> IntentType {
		if primitives.contains(.compareContexts) { return .compare }
		if primitives.contains(.explainError) { return .explain }
		if primitives.contains(.extractActionItems) { return .extract }
		if primitives.contains(.organizeInformation) { return .organize }
		if primitives.contains(.synthesizeResearchSummary) { return .synthesize }
		if primitives.contains(.structureNotes) { return .structure }
		if primitives.contains(.classifyWorkflow) { return .classify }
		if primitives.contains(.answerFromContext) { return .answer }
		if primitives.contains(.summarizeContext) { return .summarize }
		return .unknown
	}

	private static func synthesizeTitle(goal: String, workflow: WorkflowType, intent: IntentType) -> String {
		let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
		if !g.isEmpty {
			let capped = String(g.prefix(64))
			return capped.prefix(1).uppercased() + capped.dropFirst()
		}
		if workflow != .unknown, intent != .unknown {
			return "Help with \(workflow.rawValue) (\(intent.rawValue))"
		}
		return "Help with the current context"
	}

	private static func synthesizeQuestion(goal: String, title: String) -> String {
		let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
		if !g.isEmpty {
			return "Want me to help with: \(String(g.prefix(90)))?"
		}
		return "Want help with this?"
	}

	private static func minimizedRequiredContext(
		from hooks: [HookCapabilityDefinition],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> [ContextRequirementType] {
		var required: Set<ContextRequirementType> = []
		for hook in hooks {
			for type in hook.requiredContextTypes where type != .none {
				required.insert(type)
			}
		}

		// Allow execution-time gathering: don't require screen capture/visual for visibility if we can gather it.
		if required.contains(.screenCapture) || required.contains(.fusedVisual) {
			let screenAllowed = snapshot.permissionAvailability[.screenRecording] != false
			if !screenAllowed {
				// Hard requirement only when permission is denied — otherwise let it surface.
			} else {
				required.remove(.screenCapture)
				required.remove(.fusedVisual)
			}
		}

		if situational.inferredWorkflow == .unknown {
			required.remove(.workflowContext)
		}

		required.remove(.multiSource)
		if required.isEmpty { return [.none] }
		return Array(required)
	}

	private static func interruptionCost(workflow: WorkflowType, confidence: Double) -> Double {
		let base: Double
		switch workflow {
		case .debugging: base = 0.28
		case .research, .browsing, .studying: base = 0.24
		default: base = 0.20
		}
		let confBoost = max(0, (confidence - 0.70)) * 0.12
		return max(0.08, min(0.70, base - confBoost))
	}
}

// MARK: - Hook retrieval

private enum HookCategoryRetriever {
	static func retrieve(
		needCats: [String],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		registry: HookCapabilityRegistry
	) -> [HookCapabilityDefinition] {
		var wanted: Set<HookCategory> = []
		for cat in needCats {
			switch cat {
			case "context": wanted.insert(.observation)
			case "extract": wanted.insert(.extraction)
			case "reason":  wanted.insert(.reasoning)
			case "output":  wanted.insert(.presentation)
			case "compare": wanted.formUnion([.extraction, .reasoning, .presentation])
			case "organize": wanted.formUnion([.extraction, .reasoning, .presentation])
			case "debug": wanted.formUnion([.extraction, .reasoning, .presentation])
			case "study": wanted.formUnion([.extraction, .reasoning, .presentation])
			default: break
			}
		}
		if wanted.isEmpty {
			wanted = [.reasoning, .presentation]
		}

		let all = registry.all
			.filter { wanted.contains($0.category) }
			.filter { $0.permissionLevel != .unavailable && $0.category != .dangerous }

		// Prefer implemented hooks.
		let implemented = all.filter(\.isImplemented)
		if !implemented.isEmpty { return implemented }
		return all
	}

	static func retrieveAsync(
		needCats: [String],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		registry: HookCapabilityRegistry
	) async -> [HookCapabilityDefinition] {
		retrieve(needCats: needCats, snapshot: snapshot, situational: situational, registry: registry)
	}
}

private struct HookPlanningSafetyEvaluation: Sendable, Equatable {
	let shouldAbort: Bool
	let abortReason: String?
}

private enum HookPlanningSafetyChecker {
	static func evaluateAsync(
		needCats: [String],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) async -> HookPlanningSafetyEvaluation {
		// Placeholder for future: e.g. deny "computer_control" unless user explicitly invoked.
		_ = needCats
		_ = snapshot
		_ = situational
		return HookPlanningSafetyEvaluation(shouldAbort: false, abortReason: nil)
	}
}

// MARK: - Hook planning / gaps

private enum HookGraphPlanner {
	struct Plan: Sendable, Equatable {
		let hookIds: [String]
		let usedHooks: [HookCapabilityDefinition]
		let missingCategories: [String]
	}

	static func plan(
		needCats: [String],
		retrievedHooks: [HookCapabilityDefinition],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> Plan {
		var ids: [String] = ["observe_current_context"]
		var used: [HookCapabilityDefinition] = []

		func add(_ hookId: String) {
			guard !ids.contains(hookId) else { return }
			ids.append(hookId)
		}

		// Context collection is allowed during execution; include only when explicitly requested.
		if needCats.contains("context") {
			if snapshot.permissionAvailability[.screenRecording] != false {
				add("gather_visible_context_once")
				if situational.ocrSignal.availability != .available {
					add("run_ocr_once")
				}
			}
		}

		// Retrieve candidate hooks by category.
		let byId = Dictionary(uniqueKeysWithValues: retrievedHooks.map { ($0.id, $0) })

		func includeFirst(where predicate: (HookCapabilityDefinition) -> Bool) {
			if let match = retrievedHooks.first(where: predicate) {
				add(match.id)
				used.append(match)
			}
		}

		// Minimal mapping from categories to hook candidates. This does NOT hardcode user behaviors;
		// it only selects bounded building blocks to satisfy the requested capability categories.
		if needCats.contains("extract") {
			includeFirst { $0.category == .extraction && $0.isImplemented }
		}
		if needCats.contains("compare") {
			if byId["compare_items"]?.isImplemented == true { add("compare_items"); used.append(byId["compare_items"]!) }
			if byId["extract_product_attributes"]?.isImplemented == true { add("extract_product_attributes"); used.append(byId["extract_product_attributes"]!) }
		}
		if needCats.contains("debug") {
			if byId["explain_visible_error"]?.isImplemented == true { add("explain_visible_error"); used.append(byId["explain_visible_error"]!) }
			if byId["extract_error_messages"]?.isImplemented == true { add("extract_error_messages"); used.append(byId["extract_error_messages"]!) }
		}
		if needCats.contains("reason") {
			includeFirst { $0.category == .reasoning && $0.isImplemented && $0.id != "observe_current_context" }
		}

		// Always ensure some presentable output.
		add("present_result")

		// Resolve used hook definitions (for primitive mapping).
		let resolved = ids.compactMap { byId[$0] }.filter { $0.id != "observe_current_context" && $0.id != "present_result" }
		let uniqueUsed: [HookCapabilityDefinition] = {
			var seen: Set<String> = []
			return (used + resolved).filter { seen.insert($0.id).inserted }
		}()

		let missing = missingCats(needCats: needCats, usedHooks: uniqueUsed)
		return Plan(hookIds: ids, usedHooks: uniqueUsed, missingCategories: missing)
	}

	private static func missingCats(needCats: [String], usedHooks: [HookCapabilityDefinition]) -> [String] {
		var missing: [String] = []
		let catsUsed = Set(usedHooks.map(\.category))
		for cat in needCats {
			switch cat {
			case "extract":
				if !catsUsed.contains(.extraction) { missing.append(cat) }
			case "reason":
				if !catsUsed.contains(.reasoning) { missing.append(cat) }
			case "output":
				break
			default:
				break
			}
		}
		return missing
	}
}
