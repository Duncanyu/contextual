import Foundation

/// UI-facing workflow bucket for generated action previews (metadata-only).
enum DynamicActionDisplayCategory: String, Hashable, Sendable, Codable, CaseIterable {
	case debugging
	case writing
	case research
	case reviewing
	case browsing
	case editing
	case utility
	case unknown
}

/// Policy-facing badge for preview rows (blocked never appears in `previewItems`).
enum DynamicActionDisplaySafetyBadge: String, Hashable, Sendable, Codable, CaseIterable {
	case safeReadOnly
	case reviewRequired
	case previewOnly
}

enum DynamicActionDisplaySource: String, Hashable, Sendable, Codable, CaseIterable {
	case generatedAction = "generated_action"
	case generatedPlan = "generated_plan"
}

/// Non-executable, preview-only display payload for future UX (no raw user content).
struct DynamicActionDisplayModel: Equatable, Sendable, Identifiable {
	let id: UUID
	let title: String
	let shortDescription: String
	let category: DynamicActionDisplayCategory
	let workflowLabel: String
	let confidenceBucket: String
	let safetyBadge: DynamicActionDisplaySafetyBadge
	let reviewRequired: Bool
	let primitiveLabels: [String]
	let reasonChips: [String]
	let interruptionCostBucket: String
	let sourceIntentType: String
	let source: DynamicActionDisplaySource
	/// Always `false` in this phase (non-executable data).
	let isExecutable: Bool
	/// Always `true` in this phase (preview-only).
	let isPreviewOnly: Bool
}

/// Bounded preview list plus optional blocked-only debug lines (metadata-only).
struct DynamicActionDisplaySummary: Equatable, Sendable {
	let previewItems: [DynamicActionDisplayModel]
	let blockedDebugLines: [String]
	/// Count of actions/plans omitted from preview due to blocked safety (metadata-only).
	let blockedSkippedTotal: Int

	static let empty = DynamicActionDisplaySummary(previewItems: [], blockedDebugLines: [], blockedSkippedTotal: 0)

	var showsGeneratedPreview: Bool {
		!previewItems.isEmpty || !blockedDebugLines.isEmpty
	}
}

enum DynamicActionDisplayBuilder {
	static let maxTitleLengthForTests = 52
	private static let maxTitle = 52
	private static let maxDescription = 96
	private static let maxPrimitives = 4
	private static let maxChips = 8
	private static let maxPreviewRows = 4
	private static let maxBlockedLines = 4

	private static var lastBlockedSkipLogSig: String?
	private static var lastBlockedSkipLogAt: Date?

	static func build(
		actions: [GeneratedAction]? = nil,
		plans: [GeneratedActionPlan]? = nil,
		workflow: WorkflowInferenceResult? = nil,
		session: ContextualSessionState? = nil
	) -> DynamicActionDisplaySummary {
		let acts = actions ?? GeneratedActionEngine.shared.latestActions()
		let pls = plans ?? GeneratedActionEngine.shared.currentPlans()
		_ = workflow ?? WorkflowInferenceEngine.shared.latestResult()
		_ = session ?? ContextualSessionTracker.shared.currentState()

		var preview: [DynamicActionDisplayModel] = []
		var blockedLines: [String] = []
		var blockedSkipCount = 0

		for a in acts {
			let d = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(a)
			if d.safetyLevel == .blocked || !d.allowed {
				blockedSkipCount += 1
				if blockedLines.count < maxBlockedLines {
					let codes = d.reasonCodes.map(\.rawValue).sorted().prefix(4).joined(separator: ",")
					let sid = String(a.id.uuidString.prefix(8))
					blockedLines.append("blocked id=\(sid) intent=\(a.intentType.rawValue) codes=\(codes.isEmpty ? "none" : codes)")
				}
				continue
			}
			if preview.count >= maxPreviewRows { break }
			preview.append(mapAction(a, safety: d))
		}

		for p in pls where preview.count < maxPreviewRows {
			let d = GeneratedActionSafetyPolicy.evaluatePlanSnapshotForDebug(p)
			if d.safetyLevel == .blocked || !d.allowed {
				blockedSkipCount += 1
				if blockedLines.count < maxBlockedLines {
					let codes = d.reasonCodes.map(\.rawValue).sorted().prefix(4).joined(separator: ",")
					let pid = String(p.id.uuidString.prefix(8))
					blockedLines.append("blocked_plan id=\(pid) intent=\(p.intentType.rawValue) codes=\(codes.isEmpty ? "none" : codes)")
				}
				continue
			}
			preview.append(mapPlan(p, safety: d))
		}

		logBlockedSkipsAggregateIfNeeded(total: blockedSkipCount)

		return DynamicActionDisplaySummary(previewItems: preview, blockedDebugLines: blockedLines, blockedSkippedTotal: blockedSkipCount)
	}

	private static func logBlockedSkipsAggregateIfNeeded(total: Int) {
		guard total > 0 else { return }
		let now = Date()
		let sig = "agg|\(total)"
		if lastBlockedSkipLogSig == sig, let t = lastBlockedSkipLogAt, now.timeIntervalSince(t) < 1.8 { return }
		lastBlockedSkipLogSig = sig
		lastBlockedSkipLogAt = now
		print("[DynamicActionUX] skipped reason=blocked_action count=\(total)")
	}

	private static func mapAction(_ a: GeneratedAction, safety: GeneratedActionSafetyDecision) -> DynamicActionDisplayModel {
		let badge: DynamicActionDisplaySafetyBadge =
			(safety.requiresUserReview || safety.safetyLevel == .reviewRequired) ? .reviewRequired : .safeReadOnly
		let chips = reasonChips(for: a.structuredExplainability, sourceCodes: a.sourceReasonCodes)
		return DynamicActionDisplayModel(
			id: a.id,
			title: clamp(a.title, maxTitle),
			shortDescription: clamp(a.description, maxDescription),
			category: category(workflow: a.workflow, intent: a.intentType),
			workflowLabel: a.workflow.rawValue,
			confidenceBucket: confidenceBucket(a.confidence),
			safetyBadge: badge,
			reviewRequired: safety.requiresUserReview || safety.safetyLevel == .reviewRequired,
			primitiveLabels: Array(a.primitives.map(\.rawValue).prefix(maxPrimitives)),
			reasonChips: chips,
			interruptionCostBucket: interruptionBucket(a.interruptionCost),
			sourceIntentType: a.intentType.rawValue,
			source: .generatedAction,
			isExecutable: false,
			isPreviewOnly: true
		)
	}

	private static func mapPlan(_ p: GeneratedActionPlan, safety: GeneratedActionSafetyDecision) -> DynamicActionDisplayModel {
		let badge: DynamicActionDisplaySafetyBadge =
			(safety.requiresUserReview || safety.safetyLevel == .reviewRequired) ? .reviewRequired : .safeReadOnly
		let prim = p.steps.map(\.primitive.rawValue)
		let chips = reasonChips(for: p.structuredExplainability, sourceCodes: p.sourceReasonCodes)
		let title = clamp("Plan · \(p.compositionRule.rawValue)", maxTitle)
		let desc = clamp("steps=\(p.steps.count)|intent=\(p.intentType.rawValue)", maxDescription)
		return DynamicActionDisplayModel(
			id: p.id,
			title: title,
			shortDescription: desc,
			category: category(workflow: p.workflow, intent: p.intentType),
			workflowLabel: p.workflow.rawValue,
			confidenceBucket: confidenceBucket(p.confidence),
			safetyBadge: badge,
			reviewRequired: safety.requiresUserReview || safety.safetyLevel == .reviewRequired,
			primitiveLabels: Array(prim.prefix(maxPrimitives)),
			reasonChips: chips,
			interruptionCostBucket: "low",
			sourceIntentType: p.intentType.rawValue,
			source: .generatedPlan,
			isExecutable: false,
			isPreviewOnly: true
		)
	}

	private static func reasonChips(for explanation: GeneratedActionExplanation?, sourceCodes: [String]) -> [String] {
		var chips: [String] = ["preview_only"]
		if let e = explanation {
			for r in e.templateReasons.prefix(4) {
				chips.append(r.rawValue)
			}
			for c in e.sourceReasonCodes.prefix(3) where !c.isEmpty {
				let t = sanitizeChip(c)
				if !t.isEmpty { chips.append(t) }
			}
		}
		for c in sourceCodes.prefix(4) where !c.isEmpty {
			let t = sanitizeChip(c)
			if !chips.contains(t), !t.isEmpty { chips.append(t) }
		}
		return Array(chips.prefix(maxChips))
	}

	private static func sanitizeChip(_ s: String) -> String {
		var out = ""
		for ch in s.prefix(48) {
			if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == ":") {
				out.append(ch)
			} else if ch == " " {
				out.append("_")
			}
		}
		while out.contains("__") {
			out = out.replacingOccurrences(of: "__", with: "_")
		}
		return clamp(String(out.prefix(32)), 32)
	}

	private static func category(workflow: InferredWorkflow, intent: SynthesizedIntentType) -> DynamicActionDisplayCategory {
		switch workflow {
		case .debugging: return .debugging
		case .writing: return .writing
		case .research: return .research
		case .reviewing: return .reviewing
		case .browsing: return .browsing
		case .editing: return .editing
		case .unknown:
			switch intent {
			case .extractActionItems, .compareSelectedSnippets, .turnNotesIntoChecklist:
				return .utility
			case .summarizeCurrentArticle, .explainApiResponse:
				return .research
			case .draftReply, .reviewSelectedText:
				return .writing
			case .explainLikelyError, .identifyPossibleBugSource:
				return .debugging
			default:
				return .unknown
			}
		}
	}

	private static func confidenceBucket(_ c: Double) -> String {
		if c >= 0.68 { return "high" }
		if c >= 0.52 { return "medium" }
		if c > 0 { return "low" }
		return "unknown"
	}

	private static func interruptionBucket(_ c: Double) -> String {
		if c < 0.35 { return "low" }
		if c < 0.58 { return "medium" }
		return "high"
	}

	private static func clamp(_ s: String, _ n: Int) -> String {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.count > n else { return t }
		return String(t.prefix(n))
	}
}

// MARK: - Self-test

extension DynamicActionDisplayBuilder {
	static func runSelfTest() -> Bool {
		print("[DynamicActionUX] selftest starting")
		var failures: [String] = []
		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let t0 = Date(timeIntervalSince1970: 2_070_000_000)
		let wf = WorkflowInferenceResult(
			workflow: .research,
			confidence: 0.7,
			contributingSignals: ["t"],
			inferredAt: t0,
			isStale: false,
			summaryHint: nil,
			sourceFusedId: nil
		)
		let session = ContextualSessionState(
			continuityScore: 0.5,
			continuityConfidence: 0.5,
			patternConfidence: 0.5,
			dominantWorkflow: .research,
			activeTrajectorySummary: "r",
			contributingSignals: [],
			updatedAt: t0,
			isStale: false
		)

		let explainIntent = SynthesizedIntent(
			id: UUID(),
			type: .explainLikelyError,
			title: "Explain likely error",
			description: "Template description for debugging context.",
			confidence: 0.72,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			supportingSignals: ["x"],
			interruptionCost: 0.33,
			freshness: 0.8,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["rule_debugging_base"]
		)
		guard case .produced(let safeAct) = GeneratedActionFactory.materialize(from: explainIntent, referenceTime: t0, source: .selfTest) else {
			assertCase("safe_materialize", false)
			let ok0 = failures.isEmpty
			print("[DynamicActionUX] selftest summary ok=\(ok0) detail=\(failures.joined(separator: ";"))")
			return ok0
		}
		let safeSnap = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(safeAct)
		let safeExpl = GeneratedActionExplanationBuilder.buildForAction(action: safeAct, safety: safeSnap, referenceTime: t0, fusedOverride: nil)
		let safeWith = safeAct.withStructuredExplainability(safeExpl)

		let draftIntent = SynthesizedIntent(
			id: UUID(),
			type: .draftReply,
			title: "Draft reply",
			description: "Template draft description text.",
			confidence: 0.74,
			workflow: .writing,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.4,
			freshness: 0.8,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["rule"]
		)
		guard case .produced(let revAct) = GeneratedActionFactory.materialize(from: draftIntent, referenceTime: t0, source: .selfTest) else {
			assertCase("draft_materialize", false)
			let ok1 = failures.isEmpty
			print("[DynamicActionUX] selftest summary ok=\(ok1) detail=\(failures.joined(separator: ";"))")
			return ok1
		}
		let revSnap = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(revAct)
		let revExpl = GeneratedActionExplanationBuilder.buildForAction(action: revAct, safety: revSnap, referenceTime: t0, fusedOverride: nil)
		let revWith = revAct.withStructuredExplainability(revExpl)

		var badProf = GeneratedActionSafetyProfile.profile(for: [.explain])
		badProf.usesShell = true
		let blockedAct = GeneratedAction(
			id: UUID(),
			title: "Blocked action title",
			description: "Blocked description",
			intentType: .explainLikelyError,
			confidence: 0.7,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			primitives: [.explain],
			interruptionCost: 0.4,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["t"],
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: false,
			safetyProfile: badProf,
			explainabilitySummary: "intent_type=explain|primitives=explain",
			source: .selfTest,
			structuredExplainability: nil
		)

		var planList: [GeneratedActionPlan] = []
		if case .accepted(let pl) = GeneratedActionPlanBuilder.build(from: safeWith, referenceTime: t0) {
			planList = [pl]
		}

		let sum = build(actions: [safeWith, revWith, blockedAct], plans: planList, workflow: wf, session: session)
		assertCase("preview_count", sum.previewItems.count >= 2 && sum.previewItems.count <= 4)
		assertCase("blocked_hidden", !sum.previewItems.contains { $0.id == blockedAct.id })
		assertCase("blocked_debug", sum.blockedDebugLines.contains(where: { $0.contains("blocked") }))
		assertCase("blocked_total", sum.blockedSkippedTotal >= 1)

		let safeRow = sum.previewItems.first { $0.id == safeWith.id }
		assertCase("safe_badge", safeRow?.safetyBadge == .safeReadOnly)
		assertCase("safe_review_flag", safeRow?.reviewRequired == false)
		assertCase("safe_category", safeRow?.category == .debugging)
		assertCase("safe_conf", safeRow?.confidenceBucket == "high" || safeRow?.confidenceBucket == "medium")
		assertCase("prims", !(safeRow?.primitiveLabels.isEmpty ?? true))
		assertCase("preview_flags", (safeRow?.isExecutable == false) && (safeRow?.isPreviewOnly == true))
		assertCase("title_bounds", (safeRow?.title.count ?? 0) <= maxTitleLengthForTests + 2)
		assertCase("chips_preview", safeRow?.reasonChips.contains("preview_only") == true)
		assertCase("explain_chips", (safeRow?.reasonChips.count ?? 0) > 1)

		let revRow = sum.previewItems.first { $0.id == revWith.id }
		assertCase("rev_badge", revRow?.safetyBadge == .reviewRequired || (revRow?.reviewRequired == true))

		if let planRow = sum.previewItems.first(where: { $0.source == DynamicActionDisplaySource.generatedPlan }) {
			assertCase("plan_prims", !planRow.primitiveLabels.isEmpty)
			assertCase("plan_exec", planRow.isExecutable == false && planRow.isPreviewOnly == true)
		}

		let joined = (sum.previewItems.map { $0.title + $0.shortDescription + $0.reasonChips.joined() }).joined()
		assertCase("no_url", !joined.contains("://"))

		let empty = build(actions: [], plans: [], workflow: nil, session: nil)
		assertCase("empty", !empty.showsGeneratedPreview)

		let utilAct = GeneratedAction(
			id: UUID(),
			title: "Extract items",
			description: "Metadata-only extract preview.",
			intentType: .extractActionItems,
			confidence: 0.63,
			workflow: .unknown,
			requiredContext: [.textSnippet],
			primitives: [.extract],
			interruptionCost: 0.35,
			workflowRelevance: 0.5,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["rule"],
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: false,
			safetyProfile: .profile(for: [.extract]),
			explainabilitySummary: "intent_type=extract|primitives=extract",
			source: .selfTest,
			structuredExplainability: nil
		)
		let utilSnap = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(utilAct)
		guard utilSnap.allowed, utilSnap.safetyLevel != .blocked else {
			assertCase("util_safe", false)
			let ok2 = failures.isEmpty
			print("[DynamicActionUX] selftest summary ok=\(ok2) detail=\(failures.joined(separator: ";"))")
			return ok2
		}
		let utilSum = build(actions: [utilAct], plans: [], workflow: nil, session: nil)
		assertCase("utility_category", utilSum.previewItems.first?.category == .utility)

		let ok = failures.isEmpty
		print("[DynamicActionUX] selftest summary ok=\(ok) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}
