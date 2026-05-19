import Foundation

/// Shapes execution plans from workflow profiles (no execution, no AI).
struct WorkflowExecutionPlanner: Sendable {

	/// Primitives with deterministic runners in T17.3 (others filtered with warnings).
	static let implementedPrimitives: Set<ExecutionPrimitive> = [
		.summarizeContext, .extractActionItems, .generateChecklist, .explainError,
		.structureNotes, .answerFromContext,
	]

	func shape(
		action: GeneratedExecutionAction,
		context: GeneratedExecutionContext,
		profile: WorkflowExecutionProfile? = nil
	) -> WorkflowExecutionPlanResult {
		let workflow = resolvedWorkflow(action: action, context: context)
		let resolvedProfile = profile ?? WorkflowExecutionProfileProvider.profile(for: workflow)
		let original = action.executionPlan

		guard !original.primitives.isEmpty else {
			return fallbackResult(
				action: action,
				profile: resolvedProfile,
				reason: "empty_original_plan"
			)
		}

		var warnings: [String] = []
		var primitives = original.primitives

		if resolvedProfile.preferredIntentTypes.contains(action.intentType) {
			for preferred in resolvedProfile.preferredPrimitives where !primitives.contains(preferred) {
				primitives.insert(preferred, at: 0)
			}
			warnings.append("intent_aligned_primitives")
		}

		primitives = reorder(primitives, by: resolvedProfile.preferredPrimitives)
		let avoided = Set(resolvedProfile.avoidedPrimitives)
		primitives = primitives.filter { !avoided.contains($0) }
		if primitives.count < original.primitives.count {
			warnings.append("avoided_primitives_removed")
		}

		let (supported, unsupportedRemoved) = filterImplemented(primitives)
		primitives = supported
		if unsupportedRemoved > 0 {
			warnings.append("unsupported_primitives_filtered")
		}

		if primitives.isEmpty {
			return fallbackResult(
				action: action,
				profile: resolvedProfile,
				reason: "no_supported_primitives_after_shape",
				extraWarnings: warnings
			)
		}

		primitives = Array(primitives.prefix(GeneratedExecutionBounds.maxPrimitivesPerPlan))

		let shapedConfidence = Self.clampConfidence(
			action.confidence * resolvedProfile.confidenceMultiplier,
			context: context,
			profile: resolvedProfile,
			warnings: warnings
		)

		var budget = original.executionBudget
		budget.budgetPriority = Self.safeBudgetPriority(
			current: budget.budgetPriority,
			suggested: resolvedProfile.defaultBudgetPriority
		)

		let shapedPlan = ExecutionPlan(
			id: original.id,
			primitives: primitives,
			estimatedCost: original.estimatedCost,
			estimatedRuntime: original.estimatedRuntime,
			requiresVision: original.requiresVision,
			requiresOCR: original.requiresOCR,
			requiresUserIntent: original.requiresUserIntent,
			requiredPermissions: original.requiredPermissions,
			fallbackBehavior: original.fallbackBehavior,
			executionBudget: budget,
			planConfidence: min(1.0, max(0, original.planConfidence * resolvedProfile.confidenceMultiplier))
		)

		logPlanning(
			workflow: workflow,
			profile: resolvedProfile,
			primitives: primitives,
			warnings: warnings,
			fallback: false
		)

		return WorkflowExecutionPlanResult(
			plan: shapedPlan,
			profile: resolvedProfile,
			planningWarnings: warnings,
			usedFallback: false,
			shapedConfidence: shapedConfidence,
			compositionStyle: resolvedProfile.resultCompositionStyle
		)
	}

	// MARK: - Internals

	private func resolvedWorkflow(
		action: GeneratedExecutionAction,
		context: GeneratedExecutionContext
	) -> WorkflowType {
		if context.workflowType != .unknown { return context.workflowType }
		return action.workflowType
	}

	private func reorder(_ primitives: [ExecutionPrimitive], by preferred: [ExecutionPrimitive]) -> [ExecutionPrimitive] {
		let rank: [ExecutionPrimitive: Int] = Dictionary(
			uniqueKeysWithValues: preferred.enumerated().map { ($0.element, $0.offset) }
		)
		return primitives.sorted { lhs, rhs in
			let l = rank[lhs] ?? Int.max
			let r = rank[rhs] ?? Int.max
			if l != r { return l < r }
			return lhs.rawValue < rhs.rawValue
		}
	}

	private func filterImplemented(_ primitives: [ExecutionPrimitive]) -> ([ExecutionPrimitive], Int) {
		var seen = Set<ExecutionPrimitive>()
		var out: [ExecutionPrimitive] = []
		var removed = 0
		for p in primitives {
			guard Self.implementedPrimitives.contains(p) else {
				removed += 1
				continue
			}
			if seen.insert(p).inserted {
				out.append(p)
			}
		}
		return (out, removed)
	}

	private func fallbackResult(
		action: GeneratedExecutionAction,
		profile: WorkflowExecutionProfile,
		reason: String,
		extraWarnings: [String] = []
	) -> WorkflowExecutionPlanResult {
		var warnings = extraWarnings
		warnings.append("planner_fallback:\(reason)")

		let (supported, _) = filterImplemented(action.executionPlan.primitives)
		let primitives: [ExecutionPrimitive]
		if supported.isEmpty {
			primitives = [.summarizeContext]
			warnings.append("planner_default_primitive")
		} else {
			primitives = Array(supported.prefix(GeneratedExecutionBounds.maxPrimitivesPerPlan))
		}

		let source = action.executionPlan
		let plan = ExecutionPlan(
			id: source.id,
			primitives: primitives,
			estimatedCost: source.estimatedCost,
			estimatedRuntime: source.estimatedRuntime,
			requiresVision: source.requiresVision,
			requiresOCR: source.requiresOCR,
			requiresUserIntent: source.requiresUserIntent,
			requiredPermissions: source.requiredPermissions,
			fallbackBehavior: source.fallbackBehavior,
			executionBudget: source.executionBudget,
			planConfidence: source.planConfidence
		)

		logPlanning(
			workflow: profile.workflowType,
			profile: profile,
			primitives: primitives,
			warnings: warnings,
			fallback: true
		)

		return WorkflowExecutionPlanResult(
			plan: plan,
			profile: profile,
			planningWarnings: warnings,
			usedFallback: true,
			shapedConfidence: Self.clampConfidence(
				action.confidence * 0.92,
				context: nil,
				profile: profile,
				warnings: warnings
			),
			compositionStyle: profile.resultCompositionStyle
		)
	}

	private static func safeBudgetPriority(current: BudgetPriority, suggested: BudgetPriority) -> BudgetPriority {
		switch current {
		case .userInitiated:
			return .userInitiated
		case .high:
			return suggested == .low ? .normal : current
		case .normal:
			return suggested
		case .low:
			return .low
		}
	}

	static func clampConfidence(
		_ base: Double,
		context: GeneratedExecutionContext?,
		profile: WorkflowExecutionProfile,
		warnings: [String]
	) -> Double {
		var value = base
		if let context, profile.requiresFreshContext, context.isExpired {
			value *= 0.85
		}
		if let context, !context.hasUsableText {
			value *= 0.8
		}
		if warnings.contains(where: { $0.hasPrefix("planner_fallback") }) {
			value *= 0.92
		}
		if !warnings.isEmpty {
			value *= 0.97
		}
		return min(1.0, max(0.05, value))
	}

	private func logPlanning(
		workflow: WorkflowType,
		profile: WorkflowExecutionProfile,
		primitives: [ExecutionPrimitive],
		warnings: [String],
		fallback: Bool
	) {
		var meta = IntelligenceDebugMeta(
			reason: workflow.rawValue,
			layer: "workflow_execution_planner",
			detail: profile.resultCompositionStyle.rawValue
		)
		meta.type = fallback ? "fallback" : "shaped"
		meta.actions = primitives.count
		if !warnings.isEmpty {
			meta.score = String(warnings.count)
		}
		IntelligenceDebugLogger.log(stage: .execution, event: "workflow_plan_shaped", meta: meta)
	}
}

// MARK: - Self-test

extension WorkflowExecutionPlanner {
	static func runSelfTest() -> Bool {
		let planner = WorkflowExecutionPlanner()
		let context = PlannerSelfTestFixtures.context(workflow: .debugging)
		let debugAction = PlannerSelfTestFixtures.action(
			workflow: .debugging,
			intent: .explain,
			primitives: [.summarizeContext]
		)
		let debugShape = planner.shape(action: debugAction, context: context)
		guard debugShape.plan.primitives.contains(.explainError),
		      debugShape.plan.primitives.first == .explainError else { return false }

		let researchAction = PlannerSelfTestFixtures.action(
			workflow: .research,
			intent: .compare,
			primitives: [.explainError, .summarizeContext]
		)
		let researchShape = planner.shape(action: researchAction, context: PlannerSelfTestFixtures.context(workflow: .research))
		guard !researchShape.plan.primitives.contains(.explainError),
		      researchShape.plan.primitives.contains(.summarizeContext) else { return false }

		let writingShape = planner.shape(
			action: PlannerSelfTestFixtures.action(workflow: .writing, intent: .structure, primitives: [.explainError]),
			context: PlannerSelfTestFixtures.context(workflow: .writing)
		)
		guard !writingShape.plan.primitives.contains(.explainError) else { return false }

		let capped = PlannerSelfTestFixtures.action(
			workflow: .research,
			intent: .summarize,
			primitives: [
				.summarizeContext, .extractActionItems, .generateChecklist,
				.explainError, .answerFromContext, .structureNotes, .compareContexts,
			]
		)
		guard planner.shape(action: capped, context: context).plan.primitives.count
			<= GeneratedExecutionBounds.maxPrimitivesPerPlan else { return false }

		let conf = WorkflowExecutionPlanner.clampConfidence(1.5, context: context, profile: debugShape.profile, warnings: [])
		guard conf <= 1.0 else { return false }

		let fallback = planner.shape(
			action: PlannerSelfTestFixtures.action(workflow: .unknown, intent: .unknown, primitives: []),
			context: context
		)
		guard fallback.usedFallback, !fallback.plan.primitives.isEmpty else { return false }

		let composed = GeneratedExecutionResultSynthesizer.synthesize(
			action: debugAction,
			outputs: [PlannerSelfTestFixtures.sampleOutput(primitive: .explainError)],
			warnings: [],
			startedAt: Date(),
			completedAt: Date(),
			status: .success,
			profile: debugShape.profile,
			planningWarnings: [],
			shapedConfidence: 0.8
		)
		guard composed.generatedSections.contains(where: { $0.title == "Likely Cause" }) else { return false }

		let researchComposed = GeneratedExecutionResultSynthesizer.synthesize(
			action: researchAction,
			outputs: [PlannerSelfTestFixtures.sampleOutput(primitive: .summarizeContext, title: "Summary")],
			warnings: [],
			startedAt: Date(),
			completedAt: Date(),
			status: .success,
			profile: researchShape.profile,
			planningWarnings: [],
			shapedConfidence: 0.7
		)
		guard researchComposed.generatedSections.contains(where: { $0.title == "Key Points" }) else { return false }

		return true
	}
}

private enum PlannerSelfTestFixtures {
	static func context(workflow: WorkflowType) -> GeneratedExecutionContext {
		let now = Date()
		return GeneratedExecutionContext(
			sourceType: "self_test",
			appName: "Contextual",
			windowTitle: "Test",
			workflowType: workflow,
			intentType: .summarize,
			selectedTextExcerpt: "sample line",
			availableContextTypes: [.textSnippet],
			createdAt: now,
			expirationDate: now.addingTimeInterval(120)
		)
	}

	static func action(
		workflow: WorkflowType,
		intent: IntentType,
		primitives: [ExecutionPrimitive]
	) -> GeneratedExecutionAction {
		let plan = ExecutionPlan(
			primitives: primitives,
			estimatedCost: 0.3,
			estimatedRuntime: 10,
			requiresVision: false,
			requiresOCR: false,
			requiresUserIntent: false,
			requiredPermissions: [.none],
			fallbackBehavior: .failFast,
			executionBudget: .conservative,
			planConfidence: 0.7
		)
		let now = Date()
		return GeneratedExecutionAction(
			title: "Test",
			description: "Test",
			workflowType: workflow,
			intentType: intent,
			confidence: 0.7,
			interruptionCost: 0.2,
			requiredContextTypes: [.textSnippet],
			executionPlan: plan,
			explainabilitySummary: "test",
			generationSource: .selfTest,
			createdAt: now,
			expirationDate: now.addingTimeInterval(120),
			isReusable: false,
			reuseScore: 0
		)
	}

	static func sampleOutput(primitive: ExecutionPrimitive, title: String = "Output") -> ExecutionPrimitiveOutput {
		ExecutionPrimitiveOutput(
			primitive: primitive,
			title: title,
			content: "body",
			confidence: 0.75
		)
	}
}
