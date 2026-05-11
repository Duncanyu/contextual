import Foundation

/// Deterministic primitive compositions into non-executable plans (T15.5).
enum GeneratedActionPlanBuilder {
	private static let maxSteps = 3
	private static let minimumPlanActionConfidence: Double = 0.46

	static func build(from action: GeneratedAction, referenceTime: Date = Date()) -> GeneratedActionPlanValidationResult {
		if action.isStale {
			return .skipped(reason: "stale_action")
		}
		if action.confidence < minimumPlanActionConfidence {
			return .skipped(reason: "low_confidence_action")
		}
		if action.intentType == .unknown {
			return .skipped(reason: "unknown_intent")
		}

		let primitives = action.primitives
		guard !primitives.isEmpty, primitives.count <= 2 else {
			return .rejected(reasonCodes: ["invalid_primitive_combo", "primitive_count"])
		}

		guard let composition = resolveComposition(primitives: primitives) else {
			return .rejected(reasonCodes: ["invalid_primitive_combo"])
		}

		guard let steps = buildSteps(composition: composition, action: action) else {
			return .rejected(reasonCodes: ["invalid_primitive_combo", "step_build_failed"])
		}

		guard validateStepGraph(steps) else {
			return .rejected(reasonCodes: ["invalid_dependencies"])
		}

		let planConfidence = isPlanClamp01(steps.map(\.confidence).min() ?? action.confidence)
		let codes = action.sourceReasonCodes + ["composition_rule:\(composition.rule.rawValue)"]
		let explanation = "rule=\(composition.rule.rawValue)|steps=\(steps.count)|primitives=\(primitives.map(\.rawValue).sorted().joined(separator: ","))"

		let actionSafety = GeneratedActionSafetyPolicy.evaluate(action: action)
		let plan = GeneratedActionPlan(
			id: UUID(),
			generatedActionId: action.id,
			intentType: action.intentType,
			workflow: action.workflow,
			steps: steps,
			confidence: isPlanClamp01(planConfidence),
			requiredContext: action.requiredContext,
			createdAt: referenceTime,
			expiresAt: action.expiresAt,
			isStale: action.isStale,
			sourceReasonCodes: Array(Set(codes)).sorted(),
			safetyProfile: action.safetyProfile,
			explanation: explanation,
			isExecutable: false,
			compositionRule: composition.rule,
			structuredExplainability: nil
		)
		let safety = GeneratedActionSafetyPolicy.evaluate(plan: plan)
		guard safety.permitsStorage else {
			return .rejected(reasonCodes: safety.reasonCodes.map(\.rawValue))
		}
		let planStructured = GeneratedActionExplanationBuilder.buildForPlan(
			plan: plan,
			planSafety: safety,
			actionSafety: actionSafety,
			referenceTime: referenceTime
		)
		return .accepted(plan.withStructuredExplainability(planStructured))
	}

	// MARK: - Internals

	private struct Composition {
		let rule: PrimitiveCompositionRule
		let orderedPrimitives: [GeneratedActionPrimitive]
	}

	private static func resolveComposition(primitives: [GeneratedActionPrimitive]) -> Composition? {
		let set = Set(primitives)
		switch primitives.count {
		case 1:
			guard let p = primitives.first else { return nil }
			if p == .rewrite { return nil }
			return Composition(rule: .singlePrimitive, orderedPrimitives: [p])
		case 2:
			break
		default:
			return nil
		}

		let a = primitives[0], b = primitives[1]

		if set == [.summarize, .extract] {
			let ord: [GeneratedActionPrimitive] = a == .summarize ? [a, b] : [b, a]
			return Composition(rule: .summarizeThenExtract, orderedPrimitives: ord)
		}
		if set == [.explain, .compare] {
			let ord: [GeneratedActionPrimitive] = a == .compare ? [a, b] : [b, a]
			return Composition(rule: .compareThenExplain, orderedPrimitives: ord)
		}
		if set == [.structure, .summarize] {
			let ord: [GeneratedActionPrimitive] = a == .structure ? [a, b] : [b, a]
			return Composition(rule: .structureThenSummarize, orderedPrimitives: ord)
		}
		if set == [.classify, .extract] {
			let ord: [GeneratedActionPrimitive] = a == .classify ? [a, b] : [b, a]
			return Composition(rule: .classifyThenExtract, orderedPrimitives: ord)
		}
		if set == [.explain, .review] {
			let ord: [GeneratedActionPrimitive] = a == .review ? [a, b] : [b, a]
			return Composition(rule: .reviewThenExplain, orderedPrimitives: ord)
		}
		if set == [.extract, .checklist] {
			let ord: [GeneratedActionPrimitive] = a == .extract ? [a, b] : [b, a]
			return Composition(rule: .extractThenChecklist, orderedPrimitives: ord)
		}
		if set == [.draft, .review] {
			let ord: [GeneratedActionPrimitive] = a == .draft ? [a, b] : [b, a]
			return Composition(rule: .draftThenReview, orderedPrimitives: ord)
		}
		if set == [.explain, .classify] {
			let ord: [GeneratedActionPrimitive] = a == .classify ? [a, b] : [b, a]
			return Composition(rule: .classifyThenExplain, orderedPrimitives: ord)
		}
		if set == [.draft, .explain] {
			let ord: [GeneratedActionPrimitive] = a == .draft ? [a, b] : [b, a]
			return Composition(rule: .draftThenExplain, orderedPrimitives: ord)
		}
		if set == [.compare, .classify] {
			let ord: [GeneratedActionPrimitive] = a == .compare ? [a, b] : [b, a]
			return Composition(rule: .compareThenClassify, orderedPrimitives: ord)
		}
		return nil
	}

	private static func buildSteps(composition: Composition, action: GeneratedAction) -> [GeneratedActionPlanStep]? {
		let baseConf = isPlanClamp01(action.confidence)
		let ordered = composition.orderedPrimitives
		guard ordered.count <= maxSteps else { return nil }

		switch composition.rule {
		case .singlePrimitive:
			guard let p = ordered.first else { return nil }
			return [
				step(
					idx: 0,
					p,
					purpose: singlePurpose(p),
					input: .sourceContext,
					output: singleOutput(p),
					deps: [],
					conf: baseConf,
					notes: singleNotes(p)
				)
			]

		case .summarizeThenExtract:
			return [
				step(idx: 0, .summarize, purpose: "Condense visible material into a short internal summary.", input: .sourceContext, output: .summary, deps: [], conf: baseConf * 0.98, notes: "reads_context_only"),
				step(idx: 1, .extract, purpose: "Extract key points or action items from summarized content.", input: .summary, output: .extractedItems, deps: [0], conf: baseConf * 0.95, notes: "reads_context_only")
			]

		case .compareThenExplain:
			return [
				step(idx: 0, .compare, purpose: "Align snippets or signals for comparison.", input: .sourceContext, output: .comparison, deps: [], conf: baseConf * 0.97, notes: "reads_context_only"),
				step(idx: 1, .explain, purpose: "Explain differences or likely causes across compared snippets.", input: .comparison, output: .explanation, deps: [0], conf: baseConf * 0.94, notes: "reads_context_only")
			]

		case .structureThenSummarize:
			return [
				step(idx: 0, .structure, purpose: "Organize content into a stable outline.", input: .sourceContext, output: .structuredOutline, deps: [], conf: baseConf * 0.97, notes: "reads_context_only"),
				step(idx: 1, .summarize, purpose: "Summarize structured outline.", input: .structuredOutline, output: .summary, deps: [0], conf: baseConf * 0.95, notes: "reads_context_only")
			]

		case .classifyThenExtract:
			return [
				step(idx: 0, .classify, purpose: "Classify content type or theme.", input: .sourceContext, output: .classification, deps: [], conf: baseConf * 0.96, notes: "reads_context_only"),
				step(idx: 1, .extract, purpose: "Extract items relevant to classification.", input: .classification, output: .extractedItems, deps: [0], conf: baseConf * 0.94, notes: "reads_context_only")
			]

		case .reviewThenExplain:
			return [
				step(idx: 0, .review, purpose: "Review visible material for issues.", input: .sourceContext, output: .reviewNotes, deps: [], conf: baseConf * 0.97, notes: "reads_context_only"),
				step(idx: 1, .explain, purpose: "Explain issues found during review.", input: .reviewNotes, output: .explanation, deps: [0], conf: baseConf * 0.94, notes: "reads_context_only")
			]

		case .extractThenChecklist:
			return [
				step(idx: 0, .extract, purpose: "Extract candidate tasks from context.", input: .sourceContext, output: .extractedItems, deps: [], conf: baseConf * 0.97, notes: "reads_context_only"),
				step(idx: 1, .checklist, purpose: "Structure extracted tasks into checklist form.", input: .extractedItems, output: .checklistItems, deps: [0], conf: baseConf * 0.95, notes: "reads_context_only")
			]

		case .draftThenReview:
			return [
				step(idx: 0, .draft, purpose: "Draft a non-final response outline.", input: .sourceContext, output: .draftText, deps: [], conf: baseConf * 0.92, notes: "requires_user_approval|non_executable"),
				step(idx: 1, .review, purpose: "Review draft for clarity and risk before any execution phase.", input: .draftText, output: .reviewNotes, deps: [0], conf: baseConf * 0.90, notes: "requires_user_approval|reads_context_only")
			]

		case .classifyThenExplain:
			return [
				step(idx: 0, .classify, purpose: "Classify signals shaping the explanation.", input: .sourceContext, output: .classification, deps: [], conf: baseConf * 0.96, notes: "reads_context_only"),
				step(idx: 1, .explain, purpose: "Explain using classified context buckets.", input: .classification, output: .explanation, deps: [0], conf: baseConf * 0.94, notes: "reads_context_only")
			]

		case .draftThenExplain:
			return [
				step(idx: 0, .draft, purpose: "Draft explanatory outline.", input: .sourceContext, output: .draftText, deps: [], conf: baseConf * 0.92, notes: "requires_user_approval|non_executable"),
				step(idx: 1, .explain, purpose: "Explain draft rationale at high level.", input: .draftText, output: .explanation, deps: [0], conf: baseConf * 0.90, notes: "requires_user_approval|reads_context_only")
			]

		case .compareThenClassify:
			return [
				step(idx: 0, .compare, purpose: "Compare visible snippets.", input: .sourceContext, output: .comparison, deps: [], conf: baseConf * 0.96, notes: "reads_context_only"),
				step(idx: 1, .classify, purpose: "Classify comparison outcome.", input: .comparison, output: .classification, deps: [0], conf: baseConf * 0.94, notes: "reads_context_only")
			]
		}
	}

	private static func step(
		idx: Int,
		_ primitive: GeneratedActionPrimitive,
		purpose: String,
		input: PlanDataRole,
		output: PlanDataRole,
		deps: [Int],
		conf: Double,
		notes: String
	) -> GeneratedActionPlanStep {
		GeneratedActionPlanStep(
			stepIndex: idx,
			primitive: primitive,
			purpose: purpose,
			inputRole: input,
			outputRole: output,
			dependsOnStepIndexes: deps,
			confidence: conf,
			safetyNotes: notes
		)
	}

	private static func singlePurpose(_ p: GeneratedActionPrimitive) -> String {
		switch p {
		case .summarize: return "Summarize visible context."
		case .explain: return "Explain context at a high level."
		case .extract: return "Extract structured items."
		case .classify: return "Classify context shape."
		case .structure: return "Structure content outline."
		case .compare: return "Compare snippets."
		case .checklist: return "Produce checklist-shaped output."
		case .review: return "Review for issues."
		case .draft: return "Draft non-final text outline."
		case .rewrite: return "Rewrite outline."
		}
	}

	private static func singleOutput(_ p: GeneratedActionPrimitive) -> PlanDataRole {
		switch p {
		case .summarize: return .summary
		case .explain: return .explanation
		case .extract: return .extractedItems
		case .classify: return .classification
		case .structure: return .structuredOutline
		case .compare: return .comparison
		case .checklist: return .checklistItems
		case .review: return .reviewNotes
		case .draft: return .draftText
		case .rewrite: return .intermediate
		}
	}

	private static func singleNotes(_ p: GeneratedActionPrimitive) -> String {
		if p == .draft { return "requires_user_approval|non_executable" }
		return "reads_context_only"
	}

	fileprivate static func validateStepGraph(_ steps: [GeneratedActionPlanStep]) -> Bool {
		guard !steps.isEmpty, steps.count <= maxSteps else { return false }
		let indices = Set(steps.map(\.stepIndex))
		guard indices == Set(0..<steps.count) else { return false }
		for s in steps {
			for d in s.dependsOnStepIndexes {
				if d >= s.stepIndex { return false }
				if !indices.contains(d) { return false }
			}
		}
		return true
	}
}

private func isPlanClamp01(_ x: Double) -> Double {
	min(1.0, max(0.0, x))
}

// MARK: - DEBUG self-test

extension GeneratedActionPlanBuilder {
	static func runSelfTest() -> Bool {
		print("[ActionPlan] selftest starting")
		var failures: [String] = []
		let t0 = Date(timeIntervalSince1970: 2_040_000_000)
		let ttl: TimeInterval = 120

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func action(
			primitives: [GeneratedActionPrimitive],
			confidence: Double,
			stale: Bool,
			intent: SynthesizedIntentType = .summarizeCurrentArticle
		) -> GeneratedAction {
			let sp = GeneratedActionSafetyProfile.profile(for: Set(primitives))
			return GeneratedAction(
				id: UUID(),
				title: "T",
				description: "D",
				intentType: intent,
				confidence: confidence,
				workflow: .research,
				requiredContext: [.textSnippet],
				primitives: primitives,
				interruptionCost: 0.4,
				workflowRelevance: 0.7,
				sourceIntentId: UUID(),
				sourceReasonCodes: ["selftest"],
				createdAt: t0,
				expiresAt: t0.addingTimeInterval(ttl),
				isStale: stale,
				safetyProfile: sp,
				explainabilitySummary: "selftest",
				source: .selfTest,
				structuredExplainability: nil
			)
		}

		// summarize + extract
		let se = action(primitives: [.summarize, .extract], confidence: 0.7, stale: false, intent: .summarizeCurrentArticle)
		if case .accepted(let plan) = GeneratedActionPlanBuilder.build(from: se, referenceTime: t0) {
			assertCase("summarize_extract_steps", plan.steps.count == 2 && plan.steps[0].primitive == .summarize && plan.steps[1].primitive == .extract)
			assertCase("summarize_extract_dep", plan.steps[1].dependsOnStepIndexes == [0])
		} else {
			assertCase("summarize_extract", false)
		}

		// explain + compare
		let ec = action(primitives: [.explain, .compare], confidence: 0.68, stale: false, intent: .compareSelectedSnippets)
		if case .accepted(let plan) = GeneratedActionPlanBuilder.build(from: ec, referenceTime: t0) {
			assertCase("compare_explain_order", plan.steps[0].primitive == .compare && plan.steps[1].primitive == .explain)
			assertCase("compare_explain_dep", plan.steps[1].dependsOnStepIndexes == [0])
		} else {
			assertCase("explain_compare", false)
		}

		// structure + summarize
		let ss = action(primitives: [.structure, .summarize], confidence: 0.66, stale: false, intent: .summarizeCodeChange)
		if case .accepted(let plan) = GeneratedActionPlanBuilder.build(from: ss, referenceTime: t0) {
			assertCase("structure_summarize", plan.steps[0].primitive == .structure && plan.steps[1].primitive == .summarize && plan.steps[1].dependsOnStepIndexes == [0])
		} else {
			assertCase("structure_summarize_accept", false)
		}

		// classify + extract
		let ce = action(primitives: [.classify, .extract], confidence: 0.65, stale: false)
		if case .accepted(let plan) = GeneratedActionPlanBuilder.build(from: ce, referenceTime: t0) {
			assertCase("classify_extract", plan.steps[0].primitive == .classify && plan.steps[1].primitive == .extract)
		} else {
			assertCase("classify_extract_accept", false)
		}

		// extract + checklist
		let exc = action(primitives: [.extract, .checklist], confidence: 0.64, stale: false, intent: .extractActionItems)
		if case .accepted(let plan) = GeneratedActionPlanBuilder.build(from: exc, referenceTime: t0) {
			assertCase("extract_checklist", plan.steps[0].primitive == .extract && plan.steps[1].primitive == .checklist)
		} else {
			assertCase("extract_checklist_accept", false)
		}

		// draft + review
		let dr = action(primitives: [.draft, .review], confidence: 0.72, stale: false)
		if case .accepted(let plan) = GeneratedActionPlanBuilder.build(from: dr, referenceTime: t0) {
			assertCase("draft_review_order", plan.steps[0].primitive == .draft && plan.steps[1].primitive == .review)
			assertCase("draft_review_approval", plan.safetyProfile.requiresUserApproval && plan.isExecutable == false)
		} else {
			assertCase("draft_review", false)
		}

		// invalid combo
		let bad = action(primitives: [.rewrite, .summarize], confidence: 0.7, stale: false)
		if case .rejected = GeneratedActionPlanBuilder.build(from: bad, referenceTime: t0) {
			assertCase("invalid_combo_rejected", true)
		} else {
			assertCase("invalid_combo_rejected", false)
		}

		// stale action
		let staleA = action(primitives: [.summarize, .extract], confidence: 0.8, stale: true)
		if case .skipped(let r) = GeneratedActionPlanBuilder.build(from: staleA, referenceTime: t0) {
			assertCase("stale_skip", r == "stale_action")
		} else {
			assertCase("stale_skip", false)
		}

		// low confidence
		let low = action(primitives: [.summarize], confidence: 0.12, stale: false)
		if case .skipped(let r) = GeneratedActionPlanBuilder.build(from: low, referenceTime: t0) {
			assertCase("low_conf", r == "low_confidence_action")
		} else {
			assertCase("low_conf", false)
		}

		// dependency cycle impossible: graph validator rejects forward dep
		assertCase("invalid_dependency_rejected", GeneratedActionPlanBuilder.selfTestInvalidDependencyRejected())

		// max steps
		if case .accepted(let plan) = GeneratedActionPlanBuilder.build(from: se, referenceTime: t0) {
			assertCase("max_steps", plan.steps.count <= 3)
		}

		// safety forbids execution/network/shell
		if case .accepted(let plan) = GeneratedActionPlanBuilder.build(from: se, referenceTime: t0) {
			assertCase("safety_no_exec", !plan.safetyProfile.executesCode && !plan.safetyProfile.usesNetwork && !plan.safetyProfile.usesShell)
		}

		let ok = failures.isEmpty
		print("[ActionPlan] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}

	/// Self-dependency on a step must fail graph validation.
	static func selfTestInvalidDependencyRejected() -> Bool {
		let s0 = GeneratedActionPlanStep(
			stepIndex: 0,
			primitive: .summarize,
			purpose: "p",
			inputRole: .sourceContext,
			outputRole: .summary,
			dependsOnStepIndexes: [],
			confidence: 0.5,
			safetyNotes: "n"
		)
		let s1bad = GeneratedActionPlanStep(
			stepIndex: 1,
			primitive: .extract,
			purpose: "p",
			inputRole: .summary,
			outputRole: .extractedItems,
			dependsOnStepIndexes: [1],
			confidence: 0.5,
			safetyNotes: "n"
		)
		return !validateStepGraph([s0, s1bad])
	}
}
