import Foundation

// MARK: - Product assistance categories (T16.5; metadata-only; preview-only assistance)

/// Coarse, reusable buckets for generated (non-executable) assistance surfacing.
enum GeneratedAssistanceCategory: String, Hashable, Sendable, Codable, CaseIterable {
	case debugging
	case research
	case writing
	case review
	case organization
	case comparison
	case utility
	case unknown

	/// Short label for preview capsule / chips (no raw context).
	var userFacingLabel: String {
		switch self {
		case .debugging: return "Debugging"
		case .research: return "Research"
		case .writing: return "Writing"
		case .review: return "Review"
		case .organization: return "Organization"
		case .comparison: return "Comparison"
		case .utility: return "Utility"
		case .unknown: return "Contextual"
		}
	}

	/// Section subtitle when all visible previews share this category, or for utility/unknown.
	var suggestionsGroupSubtitle: String {
		switch self {
		case .debugging: return "Debugging suggestions"
		case .research: return "Research suggestions"
		case .writing: return "Writing suggestions"
		case .review: return "Review suggestions"
		case .organization: return "Organization suggestions"
		case .comparison: return "Comparison suggestions"
		case .utility, .unknown: return "Contextual suggestions"
		}
	}
}

enum GeneratedAssistanceCategoryReason: String, Hashable, Sendable, Codable, CaseIterable {
	case intent
	case workflow
	case primitive
	case planRule
	case weakSignal
	case fallback
}

struct GeneratedAssistanceCategoryMapping: Equatable, Sendable {
	let category: GeneratedAssistanceCategory
	let reason: GeneratedAssistanceCategoryReason
}

struct GeneratedAssistanceCategorySummary: Equatable, Sendable {
	let counts: [String: Int]
	let topCategoryRaw: String?

	var formattedCounts: String {
		counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ")
	}
}

// MARK: - Mapper

enum GeneratedAssistanceCategoryMapper {
	private static var lastMappedLogSig: String?
	private static var lastMappedLogAt: Date?
	private static var lastGroupedLogSig: String?
	private static var lastGroupedLogAt: Date?
	private static var lastSummaryLogSig: String?
	private static var lastSummaryLogAt: Date?

	static func mapAction(_ a: GeneratedAction) -> GeneratedAssistanceCategoryMapping {
		let m = mapActionCore(a)
		logMappedIfNeeded(subject: "action", ref: String(a.id.uuidString.prefix(8)), intent: a.intentType.rawValue, mapping: m)
		return m
	}

	static func mapPlan(_ p: GeneratedActionPlan) -> GeneratedAssistanceCategoryMapping {
		let m = mapPlanCore(p)
		logMappedIfNeeded(subject: "plan", ref: String(p.id.uuidString.prefix(8)), intent: p.intentType.rawValue, mapping: m)
		return m
	}

	/// Category for proposal context when a generated action materially aligns with a static primary (metadata-only).
	static func categoryForPrimaryStaticAction(primaryActionId: String, actions: [GeneratedAction]) -> GeneratedAssistanceCategory? {
		let match = actions
			.filter { !$0.isStale }
			.filter { ga in ga.primitives.contains { staticActionId(for: $0) == primaryActionId } }
			.max(by: { $0.confidence < $1.confidence })
		guard let m = match else { return nil }
		let cat = mapActionCore(m).category
		return cat == .unknown ? nil : cat
	}

	/// Counts for non-blocked generated actions/plans (same policy as preview; metadata-only).
	static func summaryForDebug(actions: [GeneratedAction], plans: [GeneratedActionPlan]) -> GeneratedAssistanceCategorySummary {
		var counts: [String: Int] = [:]
		for a in actions {
			let d = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(a)
			guard d.allowed, d.safetyLevel != .blocked else { continue }
			let raw = mapActionCore(a).category.rawValue
			counts[raw, default: 0] += 1
		}
		for p in plans {
			let d = GeneratedActionSafetyPolicy.evaluatePlanSnapshotForDebug(p)
			guard d.allowed, d.safetyLevel != .blocked else { continue }
			let raw = mapPlanCore(p).category.rawValue
			counts[raw, default: 0] += 1
		}
		let top = counts.max(by: { $0.value < $1.value })?.key
		let summary = GeneratedAssistanceCategorySummary(counts: counts, topCategoryRaw: top)
		logSummaryIfNeeded(summary)
		return summary
	}

	static func previewSectionSubtitle(for items: [DynamicActionDisplayModel]) -> String? {
		guard !items.isEmpty else { return nil }
		let distinct = Set(items.map(\.category))
		if distinct.count == 1, let only = distinct.first {
			return only.suggestionsGroupSubtitle
		}
		return "Contextual suggestions"
	}

	static func logGroupedIfNeeded(label: String, count: Int) {
		let sig = "\(label)|\(count)"
		let now = Date()
		if lastGroupedLogSig == sig, let t = lastGroupedLogAt, now.timeIntervalSince(t) < 1.8 { return }
		lastGroupedLogSig = sig
		lastGroupedLogAt = now
		print("[AssistanceCategory] grouped label=\(label) count=\(count)")
	}

	// MARK: - Core mapping

	private static func mapActionCore(_ a: GeneratedAction) -> GeneratedAssistanceCategoryMapping {
		if a.intentType == .unknown, a.confidence < 0.42 {
			return GeneratedAssistanceCategoryMapping(category: .unknown, reason: .weakSignal)
		}

		switch a.intentType {
		case .explainLikelyError, .identifyPossibleBugSource, .explainScreenContext:
			return GeneratedAssistanceCategoryMapping(category: .debugging, reason: .intent)
		case .summarizeCurrentArticle:
			return GeneratedAssistanceCategoryMapping(category: .research, reason: .intent)
		case .explainApiResponse:
			return GeneratedAssistanceCategoryMapping(category: .research, reason: .intent)
		case .extractActionItems:
			return GeneratedAssistanceCategoryMapping(category: .organization, reason: .intent)
		case .turnNotesIntoChecklist:
			return GeneratedAssistanceCategoryMapping(category: .organization, reason: .intent)
		case .compareSelectedSnippets:
			return GeneratedAssistanceCategoryMapping(category: .comparison, reason: .intent)
		case .summarizeCodeChange:
			return GeneratedAssistanceCategoryMapping(category: .review, reason: .intent)
		case .draftReply:
			return GeneratedAssistanceCategoryMapping(category: .writing, reason: .intent)
		case .reviewSelectedText:
			if a.workflow == .reviewing {
				return GeneratedAssistanceCategoryMapping(category: .review, reason: .intent)
			}
			if a.workflow == .writing {
				return GeneratedAssistanceCategoryMapping(category: .writing, reason: .intent)
			}
			return GeneratedAssistanceCategoryMapping(category: .review, reason: .intent)
		case .unknown:
			break
		}

		let prim = Set(a.primitives)
		if prim.contains(.compare) {
			return GeneratedAssistanceCategoryMapping(category: .comparison, reason: .primitive)
		}
		if prim.contains(.extract) || prim.contains(.checklist) || prim.contains(.structure) {
			return GeneratedAssistanceCategoryMapping(category: .organization, reason: .primitive)
		}

		switch a.workflow {
		case .debugging:
			return GeneratedAssistanceCategoryMapping(category: .debugging, reason: .workflow)
		case .research:
			return GeneratedAssistanceCategoryMapping(category: .research, reason: .workflow)
		case .writing:
			return GeneratedAssistanceCategoryMapping(category: .writing, reason: .workflow)
		case .reviewing:
			return GeneratedAssistanceCategoryMapping(category: .review, reason: .workflow)
		case .browsing, .editing, .unknown:
			break
		}

		return GeneratedAssistanceCategoryMapping(category: .utility, reason: .fallback)
	}

	private static func mapPlanCore(_ p: GeneratedActionPlan) -> GeneratedAssistanceCategoryMapping {
		switch p.compositionRule {
		case .compareThenExplain, .compareThenClassify:
			return GeneratedAssistanceCategoryMapping(category: .comparison, reason: .planRule)
		case .extractThenChecklist, .classifyThenExtract:
			return GeneratedAssistanceCategoryMapping(category: .organization, reason: .planRule)
		default:
			break
		}
		let prim = Set(p.steps.map(\.primitive))
		if prim.contains(.compare) {
			return GeneratedAssistanceCategoryMapping(category: .comparison, reason: .primitive)
		}
		if prim.contains(.extract) || prim.contains(.checklist) {
			return GeneratedAssistanceCategoryMapping(category: .organization, reason: .primitive)
		}

		let pseudo = GeneratedAction(
			id: p.generatedActionId,
			title: "",
			description: "",
			intentType: p.intentType,
			confidence: p.confidence,
			workflow: p.workflow,
			requiredContext: p.requiredContext,
			primitives: p.steps.map(\.primitive),
			interruptionCost: 0.4,
			workflowRelevance: 0.5,
			sourceIntentId: p.generatedActionId,
			sourceReasonCodes: p.sourceReasonCodes,
			createdAt: p.createdAt,
			expiresAt: p.expiresAt,
			isStale: p.isStale,
			safetyProfile: p.safetyProfile,
			explainabilitySummary: "",
			source: .synthesizedIntent,
			structuredExplainability: p.structuredExplainability
		)
		return mapActionCore(pseudo)
	}

	private static func staticActionId(for p: GeneratedActionPrimitive) -> String? {
		switch p {
		case .explain, .classify: return "explain_text"
		case .summarize: return "summarize_text"
		case .rewrite, .draft, .review, .checklist: return "rewrite_text"
		case .compare, .extract, .structure: return nil
		}
	}

	private static func logMappedIfNeeded(subject: String, ref: String, intent: String, mapping: GeneratedAssistanceCategoryMapping) {
		let sig = "\(subject)|\(ref)|\(mapping.category.rawValue)|\(mapping.reason.rawValue)"
		let now = Date()
		if lastMappedLogSig == sig, let t = lastMappedLogAt, now.timeIntervalSince(t) < 1.6 { return }
		lastMappedLogSig = sig
		lastMappedLogAt = now
		print("[AssistanceCategory] mapped \(subject)=\(ref) category=\(mapping.category.rawValue) reason=\(mapping.reason.rawValue) intent=\(intent)")
	}

	private static func logSummaryIfNeeded(_ s: GeneratedAssistanceCategorySummary) {
		let top = s.topCategoryRaw ?? "none"
		let sig = "\(top)|\(s.formattedCounts)"
		let now = Date()
		if lastSummaryLogSig == sig, let t = lastSummaryLogAt, now.timeIntervalSince(t) < 2.0 { return }
		lastSummaryLogSig = sig
		lastSummaryLogAt = now
		print("[AssistanceCategory] summary top=\(top) detail=\(s.formattedCounts)")
	}

	private static func categoryAlignmentBoost(category: GeneratedAssistanceCategory, workflow: InferredWorkflow) -> Double {
		switch (category, workflow) {
		case (.debugging, .debugging): return 0.18
		case (.research, .research): return 0.18
		case (.writing, .writing): return 0.18
		case (.review, .reviewing): return 0.18
		case (.organization, _), (.comparison, _): return 0.06
		default: return 0.0
		}
	}

	static func sortBoostForAction(_ a: GeneratedAction, inferredWorkflow: InferredWorkflow) -> Double {
		categoryAlignmentBoost(category: mapActionCore(a).category, workflow: inferredWorkflow)
	}

	static func sortBoostForPlan(_ p: GeneratedActionPlan, inferredWorkflow: InferredWorkflow) -> Double {
		categoryAlignmentBoost(category: mapPlanCore(p).category, workflow: inferredWorkflow)
	}
}

// MARK: - Self-test

extension GeneratedAssistanceCategoryMapper {
	static func runSelfTest() -> Bool {
		print("[AssistanceCategory] selftest starting")
		var failures: [String] = []
		func a(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}
		let t0 = Date(timeIntervalSince1970: 2_080_000_000)

		func ga(
			_ type: SynthesizedIntentType,
			_ wf: InferredWorkflow,
			_ prim: [GeneratedActionPrimitive],
			_ conf: Double = 0.7
		) -> GeneratedAction {
			GeneratedAction(
				id: UUID(),
				title: "T",
				description: "D",
				intentType: type,
				confidence: conf,
				workflow: wf,
				requiredContext: [.textSnippet],
				primitives: prim,
				interruptionCost: 0.4,
				workflowRelevance: 0.6,
				sourceIntentId: UUID(),
				sourceReasonCodes: [],
				createdAt: t0,
				expiresAt: t0.addingTimeInterval(120),
				isStale: false,
				safetyProfile: .profile(for: Set(prim)),
				explainabilitySummary: "x",
				source: .selfTest,
				structuredExplainability: nil
			)
		}

		a("explain_debug", mapAction(ga(.explainLikelyError, .debugging, [.explain])).category == .debugging)
		a("article_research", mapAction(ga(.summarizeCurrentArticle, .research, [.summarize])).category == .research)
		a("draft_write", mapAction(ga(.draftReply, .writing, [.draft])).category == .writing)
		a("code_rev", mapAction(ga(.summarizeCodeChange, .reviewing, [.summarize])).category == .review)
		a("extract_org", mapAction(ga(.extractActionItems, .unknown, [.extract])).category == .organization)
		a("checklist_org", mapAction(ga(.turnNotesIntoChecklist, .writing, [.checklist])).category == .organization)
		a("compare_cmp", mapAction(ga(.compareSelectedSnippets, .unknown, [.compare])).category == .comparison)
		a("weak_unknown", mapAction(ga(.unknown, .unknown, [.explain], 0.35)).category == .unknown)

		let stepCompare = GeneratedActionPlanStep(
			stepIndex: 0,
			primitive: .compare,
			purpose: "c",
			inputRole: .sourceContext,
			outputRole: .comparison,
			dependsOnStepIndexes: [],
			confidence: 0.7,
			safetyNotes: "n"
		)
		let planCmp = GeneratedActionPlan(
			id: UUID(),
			generatedActionId: UUID(),
			intentType: .compareSelectedSnippets,
			workflow: .research,
			steps: [stepCompare],
			confidence: 0.66,
			requiredContext: [.textSnippet],
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: false,
			sourceReasonCodes: [],
			safetyProfile: .profile(for: [.compare]),
			explanation: "e",
			isExecutable: false,
			compositionRule: .compareThenExplain,
			structuredExplainability: nil
		)
		a("plan_compare", mapPlan(planCmp).category == .comparison)

		let dbgModels = [
			DynamicActionDisplayModel(
				id: UUID(), title: "A", shortDescription: "d", category: .debugging,
				assistanceCategoryReason: .intent, workflowLabel: "debugging", confidenceBucket: "high",
				safetyBadge: .safeReadOnly, reviewRequired: false, primitiveLabels: [], reasonChips: [],
				interruptionCostBucket: "low", sourceIntentType: "x", source: .generatedAction,
				isExecutable: false, isPreviewOnly: true,
				executionCandidateId: nil
			),
			DynamicActionDisplayModel(
				id: UUID(), title: "B", shortDescription: "d", category: .debugging,
				assistanceCategoryReason: .intent, workflowLabel: "debugging", confidenceBucket: "high",
				safetyBadge: .safeReadOnly, reviewRequired: false, primitiveLabels: [], reasonChips: [],
				interruptionCostBucket: "low", sourceIntentType: "x", source: .generatedAction,
				isExecutable: false, isPreviewOnly: true, executionCandidateId: nil
			)
		]
		a("group_homog", previewSectionSubtitle(for: dbgModels) == "Debugging suggestions")

		let mixModels = [
			dbgModels[0],
			DynamicActionDisplayModel(
				id: UUID(), title: "W", shortDescription: "d", category: .writing,
				assistanceCategoryReason: .intent, workflowLabel: "writing", confidenceBucket: "high",
				safetyBadge: .safeReadOnly, reviewRequired: false, primitiveLabels: [], reasonChips: [],
				interruptionCostBucket: "low", sourceIntentType: "draft_reply", source: .generatedAction,
				isExecutable: false, isPreviewOnly: true, executionCandidateId: nil
			)
		]
		a("group_mixed", previewSectionSubtitle(for: mixModels) == "Contextual suggestions")

		let explainGA = ga(.explainLikelyError, .debugging, [.explain])
		a("proposal_cat", categoryForPrimaryStaticAction(primaryActionId: "explain_text", actions: [explainGA]) == .debugging)

		var blockedProf = GeneratedActionSafetyProfile.profile(for: [.explain])
		blockedProf.usesShell = true
		let blockedGA = GeneratedAction(
			id: UUID(),
			title: "B",
			description: "B",
			intentType: .explainLikelyError,
			confidence: 0.7,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			primitives: [.explain],
			interruptionCost: 0.4,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: [],
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: false,
			safetyProfile: blockedProf,
			explainabilitySummary: "x",
			source: .selfTest,
			structuredExplainability: nil
		)
		let sumDbg = summaryForDebug(actions: [blockedGA, explainGA], plans: [])
		a("summary_skips_blocked", sumDbg.counts["debugging"] == 1 && sumDbg.counts.values.reduce(0, +) == 1)

		let ok = failures.isEmpty
		print("[AssistanceCategory] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}
