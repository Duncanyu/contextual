import Foundation

/// Coarse capability buckets for policy checks (metadata-only; no execution binding).
enum GeneratedActionCapabilityScope: String, Hashable, Sendable, Codable, CaseIterable {
	case readContext = "read_context"
	case transformText = "transform_text"
	case draftText = "draft_text"
	case externalWrite = "external_write"
	case shell = "shell"
	case network = "network"
	case browserAutomation = "browser_automation"
	case appControl = "app_control"
	case fileSystem = "file_system"
	case privilegedAction = "privileged_action"
}

enum GeneratedActionSafetyLevel: String, Hashable, Sendable, Codable {
	case safeReadOnly = "safe_read_only"
	case reviewRequired = "review_required"
	case blocked = "blocked"
}

enum GeneratedActionReviewRequirement: String, Hashable, Sendable, Codable {
	case none = "none"
	case userReview = "user_review"
	case explicitApproval = "explicit_approval"
}

enum GeneratedActionSafetyReason: String, Hashable, Sendable, CaseIterable {
	case readContextOnly = "read_context_only"
	case draftOrRewrite = "draft_or_rewrite"
	case shellNotAllowed = "shell_not_allowed"
	case networkNotAllowed = "network_not_allowed"
	case browserAutomationNotAllowed = "browser_automation_not_allowed"
	case appControlNotAllowed = "app_control_not_allowed"
	case fileSystemNotAllowed = "file_system_not_allowed"
	case privilegedActionNotAllowed = "privileged_action_not_allowed"
	case externalWriteNotAllowed = "external_write_not_allowed"
	case autoExecutionNotAllowed = "auto_execution_not_allowed"
	case unknownIntentType = "unknown_intent_type"
	case invalidMetadata = "invalid_metadata"
	case stalePlan = "stale_plan"
	case tooManyPlanSteps = "too_many_plan_steps"
	case cyclicPlanDependencies = "cyclic_plan_dependencies"
	case lowConfidencePlanBlocked = "low_confidence_plan_blocked"
	case lowConfidencePlanReview = "low_confidence_plan_review"
	case planExecutableNotAllowed = "plan_executable_not_allowed"
	case unknownPrimitiveBlocked = "unknown_primitive"
}

struct GeneratedActionSafetyDecision: Equatable, Sendable {
	let allowed: Bool
	let safetyLevel: GeneratedActionSafetyLevel
	let requiresUserReview: Bool
	let requiresExplicitApproval: Bool
	let reasonCodes: [GeneratedActionSafetyReason]
	let blockedCapabilities: [GeneratedActionCapabilityScope]
	let reviewNotes: String
	/// Always `false` for generated actions in this phase.
	let canExecuteAutomatically: Bool

	var permitsStorage: Bool {
		safetyLevel != .blocked && allowed
	}
}

/// Central safety gate for generated actions and plans (non-executable phase; deterministic).
enum GeneratedActionSafetyPolicy {
	private static let maxTitleLength = 56
	private static let maxDescriptionLength = 200
	private static let maxExplainabilityLength = 512
	private static let maxPlanSteps = 3
	private static let minPlanConfidenceBlocked: Double = 0.40
	private static let minPlanConfidenceReview: Double = 0.48

	private static var lastLogSignature: String?
	private static var lastLogAt: Date?
	private static let logThrottleSeconds: TimeInterval = 2.0

	// MARK: - Public API

	static func evaluate(action: GeneratedAction) -> GeneratedActionSafetyDecision {
		let d = evaluateActionCore(action)
		logDecision(d, subject: "action", distinguisher: action.intentType.rawValue)
		return d
	}

	static func evaluate(plan: GeneratedActionPlan) -> GeneratedActionSafetyDecision {
		let d = evaluatePlanCore(plan)
		logDecision(d, subject: "plan", distinguisher: "\(plan.intentType.rawValue)|s=\(plan.steps.count)")
		return d
	}

	// MARK: - Action

	private static func evaluateActionCore(_ action: GeneratedAction) -> GeneratedActionSafetyDecision {
		var blockedCaps: [GeneratedActionCapabilityScope] = []
		var reasons: [GeneratedActionSafetyReason] = []
		func block(_ r: GeneratedActionSafetyReason, _ cap: GeneratedActionCapabilityScope? = nil) {
			reasons.append(r)
			if let c = cap { blockedCaps.append(c) }
		}

		let p = action.safetyProfile

		if p.canRunAutomatically {
			block(.autoExecutionNotAllowed)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "auto_execution_forbidden")
		}
		if p.usesShell {
			block(.shellNotAllowed, .shell)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "shell_blocked")
		}
		if p.usesNetwork {
			block(.networkNotAllowed, .network)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "network_blocked")
		}
		if p.usesBrowserAutomation {
			block(.browserAutomationNotAllowed, .browserAutomation)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "browser_automation_blocked")
		}
		if p.requiresAppControl {
			block(.appControlNotAllowed, .appControl)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "app_control_blocked")
		}
		if p.touchesFileSystem {
			block(.fileSystemNotAllowed, .fileSystem)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "file_system_blocked")
		}
		if p.requiresPrivilegedAction {
			block(.privilegedActionNotAllowed, .privilegedAction)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "privileged_action_blocked")
		}
		if p.writesExternalState {
			block(.externalWriteNotAllowed, .externalWrite)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "external_write_blocked")
		}
		if p.executesCode {
			block(.invalidMetadata, nil)
			return blockedDecision(reasons: reasons, blockedCaps: [.privilegedAction], notes: "code_execution_blocked")
		}

		if action.intentType == .unknown {
			block(.unknownIntentType)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "unknown_intent")
		}

		if !allowedSynthesizedIntentTypes.contains(action.intentType) {
			block(.unknownIntentType)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "intent_not_allowlisted")
		}

		if let meta = validateActionMetadata(action) {
			block(meta)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "invalid_metadata")
		}

		let primSet = Set(action.primitives)
		if primSet.isEmpty {
			block(.invalidMetadata)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "empty_primitives")
		}
		if !GeneratedActionFactory.validatePrimitives(action.primitives) {
			block(.unknownPrimitiveBlocked)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "invalid_primitive_shape")
		}

		let drafty = primSet.contains(.draft) || primSet.contains(.rewrite)
		if drafty {
			reasons.append(.draftOrRewrite)
			return GeneratedActionSafetyDecision(
				allowed: true,
				safetyLevel: .reviewRequired,
				requiresUserReview: true,
				requiresExplicitApproval: true,
				reasonCodes: uniqueReasons(reasons),
				blockedCapabilities: blockedCaps,
				reviewNotes: "draft_or_rewrite_requires_review",
				canExecuteAutomatically: false
			)
		}

		reasons.append(.readContextOnly)
		return GeneratedActionSafetyDecision(
			allowed: true,
			safetyLevel: .safeReadOnly,
			requiresUserReview: false,
			requiresExplicitApproval: false,
			reasonCodes: uniqueReasons(reasons),
			blockedCapabilities: [],
			reviewNotes: "read_context_transform_only",
			canExecuteAutomatically: false
		)
	}

	private static let allowedSynthesizedIntentTypes: Set<SynthesizedIntentType> = Set(
		SynthesizedIntentType.allCases.filter { $0 != .unknown }
	)

	private static func validateActionMetadata(_ action: GeneratedAction) -> GeneratedActionSafetyReason? {
		let t = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
		let d = action.description.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.isEmpty || d.isEmpty { return .invalidMetadata }
		if t.count > maxTitleLength || d.count > maxDescriptionLength { return .invalidMetadata }
		let ex = action.explainabilitySummary.trimmingCharacters(in: .whitespacesAndNewlines)
		if ex.isEmpty || ex.count > maxExplainabilityLength { return .invalidMetadata }
		if action.requiredContext.isEmpty { return .invalidMetadata }
		return nil
	}

	// MARK: - Plan

	private static func evaluatePlanCore(_ plan: GeneratedActionPlan) -> GeneratedActionSafetyDecision {
		var blockedCaps: [GeneratedActionCapabilityScope] = []
		var reasons: [GeneratedActionSafetyReason] = []
		func block(_ r: GeneratedActionSafetyReason, _ cap: GeneratedActionCapabilityScope? = nil) {
			reasons.append(r)
			if let c = cap { blockedCaps.append(c) }
		}

		if plan.isExecutable {
			block(.planExecutableNotAllowed)
			block(.autoExecutionNotAllowed)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "plan_executable_forbidden")
		}
		if plan.isStale {
			block(.stalePlan)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "stale_plan")
		}
		if plan.steps.count > maxPlanSteps {
			block(.tooManyPlanSteps)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "too_many_steps")
		}
		if !planDependencyGraphValid(plan.steps) {
			block(.cyclicPlanDependencies)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "invalid_step_graph")
		}

		let stepPrimitives = plan.steps.map(\.primitive)
		let embedded = evaluateActionCore(
			GeneratedAction(
				id: plan.generatedActionId,
				title: "t",
				description: "d",
				intentType: plan.intentType,
				confidence: plan.confidence,
				workflow: plan.workflow,
				requiredContext: plan.requiredContext,
				primitives: stepPrimitives,
				interruptionCost: 0,
				workflowRelevance: 0,
				sourceIntentId: plan.generatedActionId,
				sourceReasonCodes: plan.sourceReasonCodes,
				createdAt: plan.createdAt,
				expiresAt: plan.expiresAt,
				isStale: false,
				safetyProfile: plan.safetyProfile,
				explainabilitySummary: plan.explanation,
				source: .selfTest
			)
		)
		if embedded.safetyLevel == .blocked || !embedded.allowed {
			return blockedDecision(
				reasons: uniqueReasons(embedded.reasonCodes),
				blockedCaps: embedded.blockedCapabilities,
				notes: embedded.reviewNotes
			)
		}

		if plan.confidence < minPlanConfidenceBlocked {
			block(.lowConfidencePlanBlocked)
			return blockedDecision(reasons: reasons, blockedCaps: blockedCaps, notes: "low_plan_confidence")
		}
		if plan.confidence < minPlanConfidenceReview {
			reasons.append(.lowConfidencePlanReview)
			return GeneratedActionSafetyDecision(
				allowed: true,
				safetyLevel: .reviewRequired,
				requiresUserReview: true,
				requiresExplicitApproval: false,
				reasonCodes: uniqueReasons(reasons),
				blockedCapabilities: [],
				reviewNotes: "low_plan_confidence_review",
				canExecuteAutomatically: false
			)
		}

		if embedded.safetyLevel == .reviewRequired {
			return GeneratedActionSafetyDecision(
				allowed: true,
				safetyLevel: .reviewRequired,
				requiresUserReview: true,
				requiresExplicitApproval: embedded.requiresExplicitApproval,
				reasonCodes: uniqueReasons(embedded.reasonCodes + reasons),
				blockedCapabilities: [],
				reviewNotes: embedded.reviewNotes,
				canExecuteAutomatically: false
			)
		}

		reasons.append(.readContextOnly)
		return GeneratedActionSafetyDecision(
			allowed: true,
			safetyLevel: .safeReadOnly,
			requiresUserReview: false,
			requiresExplicitApproval: false,
			reasonCodes: uniqueReasons(reasons),
			blockedCapabilities: [],
			reviewNotes: "plan_read_only",
			canExecuteAutomatically: false
		)
	}

	private static func planDependencyGraphValid(_ steps: [GeneratedActionPlanStep]) -> Bool {
		guard !steps.isEmpty, steps.count <= maxPlanSteps else { return false }
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

	// MARK: - Builders / logging

	private static func blockedDecision(
		reasons: [GeneratedActionSafetyReason],
		blockedCaps: [GeneratedActionCapabilityScope],
		notes: String
	) -> GeneratedActionSafetyDecision {
		GeneratedActionSafetyDecision(
			allowed: false,
			safetyLevel: .blocked,
			requiresUserReview: false,
			requiresExplicitApproval: false,
			reasonCodes: uniqueReasons(reasons),
			blockedCapabilities: blockedCaps,
			reviewNotes: notes,
			canExecuteAutomatically: false
		)
	}

	private static func uniqueReasons(_ r: [GeneratedActionSafetyReason]) -> [GeneratedActionSafetyReason] {
		var seen = Set<GeneratedActionSafetyReason>()
		var out: [GeneratedActionSafetyReason] = []
		for x in r where seen.insert(x).inserted {
			out.append(x)
		}
		return out
	}

	private static func logDecision(_ d: GeneratedActionSafetyDecision, subject: String, distinguisher: String) {
		let primary: String
		if d.safetyLevel == .blocked {
			if d.reasonCodes.contains(.planExecutableNotAllowed) {
				primary = GeneratedActionSafetyReason.planExecutableNotAllowed.rawValue
			} else {
				primary = d.reasonCodes.sorted(by: { $0.rawValue < $1.rawValue }).first?.rawValue ?? "blocked"
			}
		} else if d.safetyLevel == .reviewRequired {
			primary = d.reasonCodes.contains(.draftOrRewrite) ? "draft_or_rewrite" : (d.reasonCodes.first { $0 == .lowConfidencePlanReview }?.rawValue ?? "review_required")
		} else {
			primary = "read_context_only"
		}
		let level = d.safetyLevel.rawValue
		let sig = "\(subject)|\(distinguisher)|\(d.safetyLevel.rawValue)|\(primary)"
		let now = Date()
		if lastLogSignature == sig, let t = lastLogAt, now.timeIntervalSince(t) < logThrottleSeconds {
			return
		}
		lastLogSignature = sig
		lastLogAt = now

		switch d.safetyLevel {
		case .blocked:
			print("[GeneratedActionSafety] blocked reason=\(primary)")
		case .reviewRequired:
			print("[GeneratedActionSafety] review_required reason=\(primary)")
		case .safeReadOnly:
			print("[GeneratedActionSafety] allowed level=\(level) reason=\(primary)")
		}
	}
}

// MARK: - DEBUG self-test

extension GeneratedActionSafetyPolicy {
	static func runSelfTest() -> Bool {
		print("[GeneratedActionSafety] selftest starting")
		var failures: [String] = []
		let t0 = Date(timeIntervalSince1970: 2_050_000_000)
		let ttl: TimeInterval = 120

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func baseProfile() -> GeneratedActionSafetyProfile {
			.profile(for: [.explain])
		}

		func action(
			primitives: [GeneratedActionPrimitive],
			intent: SynthesizedIntentType,
			confidence: Double,
			profile: GeneratedActionSafetyProfile,
			stale: Bool = false,
			explain: String = "intent_type=explain|primitives=explain"
		) -> GeneratedAction {
			GeneratedAction(
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
				safetyProfile: profile,
				explainabilitySummary: explain,
				source: .selfTest
			)
		}

		func plan(from action: GeneratedAction, steps: [GeneratedActionPlanStep], confidence: Double, executable: Bool = false, stale: Bool = false) -> GeneratedActionPlan {
			GeneratedActionPlan(
				id: UUID(),
				generatedActionId: action.id,
				intentType: action.intentType,
				workflow: action.workflow,
				steps: steps,
				confidence: confidence,
				requiredContext: action.requiredContext,
				createdAt: t0,
				expiresAt: action.expiresAt,
				isStale: stale,
				sourceReasonCodes: ["selftest"],
				safetyProfile: action.safetyProfile,
				explanation: "rule=single_primitive|steps=\(steps.count)|primitives=test",
				isExecutable: executable,
				compositionRule: .singlePrimitive
			)
		}

		let stepSummarize = GeneratedActionPlanStep(
			stepIndex: 0,
			primitive: .summarize,
			purpose: "p",
			inputRole: .sourceContext,
			outputRole: .summary,
			dependsOnStepIndexes: [],
			confidence: 0.65,
			safetyNotes: "reads_context_only"
		)

		let explainAct = action(primitives: [.explain, .classify], intent: .explainLikelyError, confidence: 0.7, profile: baseProfile())
		let dExplain = evaluate(action: explainAct)
		assertCase("explain_safe_readonly", dExplain.safetyLevel == .safeReadOnly && dExplain.canExecuteAutomatically == false && dExplain.permitsStorage)

		let sumAct = action(primitives: [.summarize], intent: .summarizeCurrentArticle, confidence: 0.66, profile: baseProfile())
		assertCase("summarize_safe", evaluate(action: sumAct).safetyLevel == .safeReadOnly)

		let seAct = action(primitives: [.summarize, .extract], intent: .summarizeCurrentArticle, confidence: 0.7, profile: baseProfile())

		let extAct = action(primitives: [.extract, .checklist], intent: .extractActionItems, confidence: 0.64, profile: baseProfile())
		assertCase("extract_safe", evaluate(action: extAct).safetyLevel == .safeReadOnly)

		let draftAct = action(primitives: [.draft, .explain], intent: .draftReply, confidence: 0.72, profile: .profile(for: [.draft, .explain]))
		let dDraft = evaluate(action: draftAct)
		assertCase("draft_review_required", dDraft.safetyLevel == .reviewRequired && dDraft.requiresUserReview)

		let rewriteAct = action(primitives: [.rewrite, .explain], intent: .reviewSelectedText, confidence: 0.7, profile: .profile(for: [.rewrite, .explain]))
		assertCase("rewrite_review_required", evaluate(action: rewriteAct).safetyLevel == .reviewRequired)

		var shellP = baseProfile()
		shellP.usesShell = true
		let shellAct = action(primitives: [.explain], intent: .explainLikelyError, confidence: 0.7, profile: shellP)
		assertCase("shell_blocked", !evaluate(action: shellAct).permitsStorage)

		var netP = baseProfile()
		netP.usesNetwork = true
		assertCase("network_blocked", !evaluate(action: action(primitives: [.explain], intent: .explainApiResponse, confidence: 0.7, profile: netP)).permitsStorage)

		var brP = baseProfile()
		brP.usesBrowserAutomation = true
		assertCase("browser_blocked", !evaluate(action: action(primitives: [.explain], intent: .explainLikelyError, confidence: 0.7, profile: brP)).permitsStorage)

		var extW = baseProfile()
		extW.writesExternalState = true
		assertCase("external_write_blocked", !evaluate(action: action(primitives: [.summarize], intent: .summarizeCurrentArticle, confidence: 0.7, profile: extW)).permitsStorage)

		var autoP = baseProfile()
		autoP.canRunAutomatically = true
		assertCase("auto_exec_blocked", !evaluate(action: action(primitives: [.summarize], intent: .summarizeCurrentArticle, confidence: 0.7, profile: autoP)).permitsStorage)

		let badPrim = action(primitives: [.explain, .summarize, .extract], intent: .explainLikelyError, confidence: 0.7, profile: baseProfile())
		assertCase("unknown_primitive_shape_blocked", !evaluate(action: badPrim).permitsStorage)

		let stalePlan = plan(from: sumAct, steps: [stepSummarize], confidence: 0.66, stale: true)
		assertCase("stale_plan_blocked", !evaluate(plan: stalePlan).permitsStorage)

		let lowPlan = plan(from: sumAct, steps: [stepSummarize], confidence: 0.32)
		assertCase("low_conf_plan_blocked", !evaluate(plan: lowPlan).permitsStorage)

		let reviewPlan = evaluate(plan: plan(from: sumAct, steps: [stepSummarize], confidence: 0.44))
		assertCase("low_conf_plan_review", reviewPlan.safetyLevel == .reviewRequired && reviewPlan.permitsStorage)

		let fourSteps = [
			GeneratedActionPlanStep(stepIndex: 0, primitive: .summarize, purpose: "a", inputRole: .sourceContext, outputRole: .summary, dependsOnStepIndexes: [], confidence: 0.5, safetyNotes: "n"),
			GeneratedActionPlanStep(stepIndex: 1, primitive: .extract, purpose: "b", inputRole: .summary, outputRole: .extractedItems, dependsOnStepIndexes: [0], confidence: 0.5, safetyNotes: "n"),
			GeneratedActionPlanStep(stepIndex: 2, primitive: .classify, purpose: "c", inputRole: .extractedItems, outputRole: .classification, dependsOnStepIndexes: [1], confidence: 0.5, safetyNotes: "n"),
			GeneratedActionPlanStep(stepIndex: 3, primitive: .explain, purpose: "d", inputRole: .classification, outputRole: .explanation, dependsOnStepIndexes: [2], confidence: 0.5, safetyNotes: "n")
		]
		assertCase("too_many_steps_blocked", !evaluate(plan: plan(from: sumAct, steps: fourSteps, confidence: 0.7)).permitsStorage)

		let execPlan = plan(from: sumAct, steps: [stepSummarize], confidence: 0.7, executable: true)
		assertCase("plan_executable_blocked", !evaluate(plan: execPlan).permitsStorage)

		var spBad = baseProfile()
		spBad.usesShell = true
		let badShellPlanAction = action(primitives: [.summarize], intent: .summarizeCurrentArticle, confidence: 0.66, profile: spBad)
		assertCase("unsafe_profile_plan_blocked", !evaluate(plan: plan(from: badShellPlanAction, steps: [stepSummarize], confidence: 0.66)).permitsStorage)

		let cyc0 = GeneratedActionPlanStep(stepIndex: 0, primitive: .summarize, purpose: "p", inputRole: .sourceContext, outputRole: .summary, dependsOnStepIndexes: [], confidence: 0.7, safetyNotes: "n")
		let cyc1 = GeneratedActionPlanStep(stepIndex: 1, primitive: .extract, purpose: "p", inputRole: .summary, outputRole: .extractedItems, dependsOnStepIndexes: [1], confidence: 0.65, safetyNotes: "n")
		assertCase("cyclic_plan_blocked", !evaluate(plan: plan(from: seAct, steps: [cyc0, cyc1], confidence: 0.66)).permitsStorage)

		GeneratedActionEngine.shared.reset()
		let articleIntent = SynthesizedIntent(
			id: UUID(),
			type: .summarizeCurrentArticle,
			title: "Article",
			description: "D",
			confidence: 0.66,
			workflow: .research,
			requiredContext: [.textSnippet],
			supportingSignals: ["st"],
			interruptionCost: 0.3,
			freshness: 0.8,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["st"]
		)
		GeneratedActionEngine.shared.record(from: [articleIntent], referenceTime: t0)
		let stored = GeneratedActionEngine.shared.latestActions()
		assertCase("engine_only_safe_actions", stored.allSatisfy { evaluate(action: $0).permitsStorage })
		assertCase("engine_plans_safe", GeneratedActionEngine.shared.currentPlans().allSatisfy { evaluate(plan: $0).permitsStorage })
		GeneratedActionEngine.shared.reset()

		if case .accepted(let builtPlan) = GeneratedActionPlanBuilder.build(from: seAct, referenceTime: t0) {
			assertCase("plan_builder_accepts_safe", evaluate(plan: builtPlan).permitsStorage)
		} else {
			assertCase("plan_builder_accepts_safe", false)
		}

		let ok = failures.isEmpty
		print("[GeneratedActionSafety] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}
