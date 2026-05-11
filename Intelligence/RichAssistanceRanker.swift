import Foundation

// MARK: - Types (T16.10 unified assistance ranking; metadata-only)

enum RichAssistanceCandidateType: String, Hashable, Sendable, Codable, CaseIterable {
	case staticAction = "static_action"
	case generatedAction = "generated_action"
	case generatedPlan = "generated_plan"
	case inlineCandidate = "inline_candidate"
	case proposal = "proposal"
	case unknown = "unknown"
}

enum RichAssistanceProminence: String, Hashable, Sendable, Codable, CaseIterable {
	case primary = "primary"
	case secondary = "secondary"
	case preview = "preview"
	case suppressed = "suppressed"
	case hidden = "hidden"
}

enum RichAssistancePlacement: String, Hashable, Sendable, Codable, CaseIterable {
	case availableActions = "available_actions"
	case generatedPreview = "generated_preview"
	case proposalCard = "proposal_card"
	case inlineCandidate = "inline_candidate"
	case debugOnly = "debug_only"
	case none = "none"
}

/// Metadata-only reason tokens (no raw context).
enum RichAssistanceRankingReason: String, Hashable, Sendable, Codable, CaseIterable {
	case staticBaseRelevance = "static_base_relevance"
	case generatedConfidence = "generated_confidence"
	case workflowMatch = "workflow_match"
	case sessionContinuity = "session_continuity"
	case contextFresh = "context_fresh"
	case conflictPenalty = "conflict_penalty"
	case interruptionDampen = "interruption_dampen"
	case safetyBlocked = "safety_blocked"
	case reviewRequired = "review_required"
	case recentDismissal = "recent_dismissal"
	case acceptedProxyBoost = "accepted_proxy_boost"
	case ignoredPenalty = "ignored_penalty"
	case weakContextFallback = "weak_context_fallback"
	case stalePenalty = "stale_penalty"
	case contextualConfidence = "contextual_confidence"
}

struct RichAssistanceCandidate: Equatable, Sendable, Identifiable {
	var id: String { stableKey }
	let stableKey: String
	let type: RichAssistanceCandidateType
	let score: Double
	let prominence: RichAssistanceProminence
	let placement: RichAssistancePlacement
	let reasonCodes: [String]
	/// `true` only for static assistance; generated paths stay false (preview-only phase).
	let isExecutable: Bool

	func withProminence(_ p: RichAssistanceProminence) -> RichAssistanceCandidate {
		RichAssistanceCandidate(
			stableKey: stableKey,
			type: type,
			score: score,
			prominence: p,
			placement: placement,
			reasonCodes: reasonCodes,
			isExecutable: isExecutable
		)
	}
}

struct RichAssistanceRankingResult: Equatable, Sendable {
	let candidates: [RichAssistanceCandidate]
	let suppressedCount: Int
	let hiddenCount: Int
	let aggregateReasonCodes: [String]
	/// Single bounded line for debug UI (no raw content).
	let debugLine: String
	let usefulnessInfluenceSummary: String

	static let empty = RichAssistanceRankingResult(
		candidates: [],
		suppressedCount: 0,
		hiddenCount: 0,
		aggregateReasonCodes: [],
		debugLine: "",
		usefulnessInfluenceSummary: ""
	)
}

struct RichAssistanceRankingInput: Equatable, Sendable {
	let referenceTime: Date
	let staticActionIds: [String]
	/// Optional precomputed static scores keyed by action id (e.g. from `ActionRelevanceScorer`).
	let staticBaseScores: [String: Double]
	let workflowProposalRanking: WorkflowAwareProposalRankingResult?
	let generatedActions: [GeneratedAction]
	let generatedPlans: [GeneratedActionPlan]
	let workflowInference: WorkflowInferenceResult?
	let session: ContextualSessionState?
	let fused: FusedContextPacket?
	let timing: ProposalTimingDecision
	let proposalPrimaryActionId: String?
	let inlineDismissalKeys: [String]
	let interactionSnapshot: GeneratedActionInteractionSnapshot?
}

/// Live preview context: canonical fused packet + timing gate outcome.
struct RichAssistancePreviewContext: Equatable, Sendable {
	let fused: FusedContextPacket?
	let timing: ProposalTimingDecision

	static func live(isActionExecuting: Bool) -> RichAssistancePreviewContext {
		let fused = CanonicalContextState.shared.current()
		let typing = TypingActivitySource.shared.currentContext()
		let pointer = PointerActivitySource.shared.currentContext()
		let strongSel = (fused?.hasSelectedText == true)
			&& ((fused?.textLength ?? 0) >= TriggerEngine.selectedTextMinCharacterCount)
		let isSelPrimary = fused.map { $0.primaryTextSource == .selectedText } ?? false
		let timing = ProposalTimingGate.evaluate(
			isManualInvocation: false,
			isActionExecuting: isActionExecuting,
			hasStrongSelectedText: strongSel,
			isSelectedTextPrimary: isSelPrimary,
			canonicalFreshness: fused?.freshnessScore,
			canonicalConfidence: fused?.confidence,
			typing: typing,
			pointer: pointer,
			proposalStrengthHint: nil
		)
		return RichAssistancePreviewContext(fused: fused, timing: timing)
	}
}

// MARK: - Ranker

enum RichAssistanceRanker {
	private static let lock = NSLock()
	private static var latestUnified: RichAssistanceRankingResult = .empty

	private static let maxReasonsPerCandidate = 8
	private static let maxAggregateReasons = 8
	private static let maxPreviewPlacementLogs = 3

	private static var lastRankLogSig: String?
	private static var lastRankLogAt: Date?

	static func latestUnifiedRanking() -> RichAssistanceRankingResult {
		lock.lock()
		defer { lock.unlock() }
		return latestUnified
	}

	static func resetLatestForTests() {
		lock.lock()
		latestUnified = .empty
		lock.unlock()
	}

	// MARK: Preview sort scores (used by `DynamicActionDisplayBuilder`)

	static func previewSortScoreGeneratedAction(
		_ a: GeneratedAction,
		inferredWorkflow: InferredWorkflow,
		wfConfidence: Double,
		session: ContextualSessionState?,
		previewContext: RichAssistancePreviewContext,
		referenceTime: Date
	) -> Double {
		var reasons: [String] = []
		return scoreGeneratedActionForPreview(
			a,
			inferredWorkflow: inferredWorkflow,
			wfConfidence: wfConfidence,
			session: session,
			previewContext: previewContext,
			referenceTime: referenceTime,
			reasons: &reasons
		)
	}

	static func previewSortScorePlan(
		_ p: GeneratedActionPlan,
		inferredWorkflow: InferredWorkflow,
		wfConfidence: Double,
		session: ContextualSessionState?,
		previewContext: RichAssistancePreviewContext,
		referenceTime: Date
	) -> Double {
		var reasons: [String] = []
		return scoreGeneratedPlanForPreview(
			p,
			inferredWorkflow: inferredWorkflow,
			wfConfidence: wfConfidence,
			session: session,
			previewContext: previewContext,
			referenceTime: referenceTime,
			reasons: &reasons
		)
	}

	// MARK: Unified rank

	static func rankUnified(input: RichAssistanceRankingInput) -> RichAssistanceRankingResult {
		let wfType = input.workflowInference?.workflow ?? .unknown
		let wfConf = input.workflowInference.map { min(1.0, max(0.0, $0.confidence)) } ?? 0.0
		let previewCtx = RichAssistancePreviewContext(fused: input.fused, timing: input.timing)
		let interactionSnap = input.interactionSnapshot ?? GeneratedActionInteractionTracker.shared.snapshot(referenceTime: input.referenceTime)

		var out: [RichAssistanceCandidate] = []
		var hidden = 0
		var suppressed = 0
		var aggReasonBuckets: [String: Int] = [:]

		func bumpReasons(_ codes: [String]) {
			for c in codes { aggReasonBuckets[c, default: 0] += 1 }
		}

		// Static
		for sid in input.staticActionIds {
			var rs: [String] = []
			let sc = staticUnifiedScore(
				actionId: sid,
				fused: input.fused,
				wfRank: input.workflowProposalRanking,
				declaredBase: input.staticBaseScores[sid],
				reasons: &rs
			)
			bumpReasons(rs)
			out.append(RichAssistanceCandidate(
				stableKey: "s:\(sid)",
				type: .staticAction,
				score: sc,
				prominence: .secondary,
				placement: .availableActions,
				reasonCodes: capReasons(rs),
				isExecutable: true
			))
		}

		// Generated actions
		for a in input.generatedActions {
			let safety = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(a)
			if safety.safetyLevel == .blocked || !safety.allowed {
				hidden += 1
				bumpReasons([RichAssistanceRankingReason.safetyBlocked.rawValue])
				print("[RichAssistanceRank] hidden reason=safety_blocked type=generated_action intent=\(a.intentType.rawValue)")
				continue
			}
			var rs: [String] = []
			var sc = scoreGeneratedActionForPreview(
				a,
				inferredWorkflow: wfType,
				wfConfidence: wfConf,
				session: input.session,
				previewContext: previewCtx,
				referenceTime: input.referenceTime,
				reasons: &rs
			)
			applyInteractionReasonTags(action: a, snapshot: interactionSnap, reasons: &rs)
			let weakCtx = isWeakAssistiveContext(fused: input.fused, wfType: wfType, wfConfidence: wfConf)
			if weakCtx {
				sc *= 0.48
				rs.append(RichAssistanceRankingReason.weakContextFallback.rawValue)
			}
			let prom: RichAssistanceProminence
			let placement: RichAssistancePlacement
			if sc < -0.5e9 {
				prom = .hidden
				placement = .none
				hidden += 1
			} else if weakCtx && sc < 2.1 {
				prom = .suppressed
				placement = .none
				suppressed += 1
			} else {
				prom = .preview
				placement = .generatedPreview
			}
			if safety.requiresUserReview || safety.safetyLevel == .reviewRequired {
				rs.append(RichAssistanceRankingReason.reviewRequired.rawValue)
			}
			bumpReasons(rs)
			out.append(RichAssistanceCandidate(
				stableKey: "g:\(String(a.id.uuidString.prefix(8)))",
				type: .generatedAction,
				score: sc,
				prominence: prom,
				placement: placement,
				reasonCodes: capReasons(rs),
				isExecutable: false
			))
		}

		// Plans
		for p in input.generatedPlans {
			let safety = GeneratedActionSafetyPolicy.evaluatePlanSnapshotForDebug(p)
			if safety.safetyLevel == .blocked || !safety.allowed {
				hidden += 1
				bumpReasons([RichAssistanceRankingReason.safetyBlocked.rawValue])
				print("[RichAssistanceRank] hidden reason=safety_blocked type=generated_plan intent=\(p.intentType.rawValue)")
				continue
			}
			var rs: [String] = []
			var sc = scoreGeneratedPlanForPreview(
				p,
				inferredWorkflow: wfType,
				wfConfidence: wfConf,
				session: input.session,
				previewContext: previewCtx,
				referenceTime: input.referenceTime,
				reasons: &rs
			)
			let weakCtx = isWeakAssistiveContext(fused: input.fused, wfType: wfType, wfConfidence: wfConf)
			if weakCtx {
				sc *= 0.48
				rs.append(RichAssistanceRankingReason.weakContextFallback.rawValue)
			}
			let prom: RichAssistanceProminence = (weakCtx && sc < 1.95) ? .suppressed : .preview
			let placement: RichAssistancePlacement = prom == .suppressed ? .none : .generatedPreview
			if prom == .suppressed { suppressed += 1 }
			if safety.requiresUserReview || safety.safetyLevel == .reviewRequired {
				rs.append(RichAssistanceRankingReason.reviewRequired.rawValue)
			}
			bumpReasons(rs)
			out.append(RichAssistanceCandidate(
				stableKey: "p:\(String(p.id.uuidString.prefix(8)))",
				type: .generatedPlan,
				score: sc,
				prominence: prom,
				placement: placement,
				reasonCodes: capReasons(rs),
				isExecutable: false
			))
		}

		// Proposal card (metadata only)
		if let pid = input.proposalPrimaryActionId, !pid.isEmpty {
			var rs: [String] = [RichAssistanceRankingReason.staticBaseRelevance.rawValue]
			let sc = 0.68
			bumpReasons(rs)
			out.append(RichAssistanceCandidate(
				stableKey: "pr:\(pid)",
				type: .proposal,
				score: sc,
				prominence: .secondary,
				placement: .proposalCard,
				reasonCodes: capReasons(rs),
				isExecutable: false
			))
		}

		// Inline rows (internal ordering only)
		for key in input.inlineDismissalKeys {
			var rs: [String] = [RichAssistanceRankingReason.staticBaseRelevance.rawValue]
			let sc = 0.44
			bumpReasons(rs)
			out.append(RichAssistanceCandidate(
				stableKey: "i:\(key)",
				type: .inlineCandidate,
				score: sc,
				prominence: .preview,
				placement: .inlineCandidate,
				reasonCodes: capReasons(rs),
				isExecutable: false
			))
		}

		out.sort { $0.score > $1.score }

		// Only static assistance may be `primary`; generated/plan stay preview-tier at most.
		let staticCandidates = out.filter { $0.type == .staticAction }
		if let bestStatic = staticCandidates.max(by: { $0.score < $1.score }), bestStatic.score >= 0.76 {
			let winnerKey = bestStatic.stableKey
			out = out.map { c in
				guard c.type == .staticAction else { return c }
				return c.withProminence(c.stableKey == winnerKey ? .primary : .secondary)
			}
		} else {
			out = out.map { c in
				guard c.type == .staticAction else { return c }
				return c.withProminence(.secondary)
			}
		}

		let topAgg = aggReasonBuckets.sorted { $0.value > $1.value }.prefix(maxAggregateReasons).map(\.key)
		let staticN = out.filter { $0.type == .staticAction }.count
		let genN = out.filter { $0.type == .generatedAction || $0.type == .generatedPlan }.count
		let primaryKey = out.first(where: { $0.prominence == .primary })?.stableKey ?? out.first?.stableKey
		let useLine = "events=\(interactionSnap.recentEventCount) ignored=\(interactionSnap.ignoredCount) proxies=\(interactionSnap.acceptedProxyCount) dismissCat=\(interactionSnap.recentDismissedCategory ?? "none")"

		let dbg = "rich_rank count=\(out.count) static=\(staticN) generated=\(genN) suppressed=\(suppressed) hidden=\(hidden) primary=\(primaryKey ?? "nil") topReasons=\(topAgg.prefix(5).joined(separator: ","))"

		let result = RichAssistanceRankingResult(
			candidates: out,
			suppressedCount: suppressed,
			hiddenCount: hidden,
			aggregateReasonCodes: Array(topAgg),
			debugLine: dbg,
			usefulnessInfluenceSummary: useLine
		)

		lock.lock()
		latestUnified = result
		lock.unlock()

		logRankSummaryIfNeeded(result: result, topReasons: topAgg)
		logPlacementsIfNeeded(candidates: out)

		return result
	}

	// MARK: - Scoring helpers

	private static func staticUnifiedScore(
		actionId: String,
		fused: FusedContextPacket?,
		wfRank: WorkflowAwareProposalRankingResult?,
		declaredBase: Double?,
		reasons: inout [String]
	) -> Double {
		var score = declaredBase ?? 0.52
		if let adj = wfRank?.adjustedScores.first(where: { $0.actionId == actionId }) {
			score = max(score, adj.score)
			reasons.append(RichAssistanceRankingReason.staticBaseRelevance.rawValue)
		}
		if actionId == "explain_text" {
			if let f = fused, f.hasSelectedText, f.textLength >= TriggerEngine.selectedTextMinCharacterCount {
				score = max(score, 0.88)
				reasons.append(RichAssistanceRankingReason.staticBaseRelevance.rawValue)
			}
		}
		if let f = fused {
			score += 0.04 * min(1.0, max(0.0, f.confidence)) * 0.35
			reasons.append(RichAssistanceRankingReason.contextualConfidence.rawValue)
		}
		return score
	}

	private static func isWeakAssistiveContext(fused: FusedContextPacket?, wfType: InferredWorkflow, wfConfidence: Double) -> Bool {
		if fused?.isStale == true { return true }
		guard let f = fused else { return true }
		if f.freshnessScore < 0.22 && f.confidence < 0.34 { return true }
		if wfType == .unknown && wfConfidence < 0.12 && f.confidence < 0.30 { return true }
		return false
	}

	private static func scoreGeneratedActionForPreview(
		_ a: GeneratedAction,
		inferredWorkflow: InferredWorkflow,
		wfConfidence: Double,
		session: ContextualSessionState?,
		previewContext: RichAssistancePreviewContext,
		referenceTime: Date,
		reasons: inout [String]
	) -> Double {
		let safety = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(a)
		guard safety.allowed, safety.safetyLevel != .blocked else {
			reasons.append(RichAssistanceRankingReason.safetyBlocked.rawValue)
			return -1e9
		}
		if !(safety.requiresUserReview || safety.safetyLevel == .reviewRequired) {
			reasons.append(RichAssistanceRankingReason.generatedConfidence.rawValue)
		} else {
			reasons.append(RichAssistanceRankingReason.reviewRequired.rawValue)
		}

		var s = 0.0
		if !(safety.requiresUserReview || safety.safetyLevel == .reviewRequired) { s += 4.0 } else { s += 2.35 }

		let wfC = min(1.0, max(0.0, wfConfidence))
		let wfMatch: Double
		if inferredWorkflow != .unknown {
			let align = (a.workflow == inferredWorkflow) ? 1.0 : 0.24
			wfMatch = align * wfC + a.workflowRelevance * (0.52 + 0.48 * (1.0 - wfC))
			reasons.append(RichAssistanceRankingReason.workflowMatch.rawValue)
		} else {
			wfMatch = a.workflowRelevance * 0.46
		}
		s += wfMatch * 2.15
		s += GeneratedAssistanceCategoryMapper.sortBoostForAction(a, inferredWorkflow: inferredWorkflow)
		s += a.confidence * 1.32
		reasons.append(RichAssistanceRankingReason.generatedConfidence.rawValue)

		let ttl = max(30.0, a.expiresAt.timeIntervalSince(a.createdAt))
		s += max(0.0, min(1.0, a.expiresAt.timeIntervalSinceNow / ttl)) * 0.52
		s += (1.0 - min(1.0, a.interruptionCost)) * 0.3
		if a.interruptionCost > 0.72 {
			s -= 0.08
			reasons.append(RichAssistanceRankingReason.interruptionDampen.rawValue)
		}

		if let ses = session, !ses.isStale, ses.dominantWorkflow == a.workflow, ses.dominantWorkflow != .unknown {
			s += 0.1 * ses.continuityScore
			reasons.append(RichAssistanceRankingReason.sessionContinuity.rawValue)
		}

		s += GeneratedActionInteractionTracker.shared.sortAdjustment(forAction: a, referenceTime: referenceTime)

		applyFusedAndTimingModifiers(fused: previewContext.fused, timing: previewContext.timing, score: &s, reasons: &reasons)

		if a.isStale {
			s -= 0.32
			reasons.append(RichAssistanceRankingReason.stalePenalty.rawValue)
		}

		return s
	}

	private static func scoreGeneratedPlanForPreview(
		_ p: GeneratedActionPlan,
		inferredWorkflow: InferredWorkflow,
		wfConfidence: Double,
		session: ContextualSessionState?,
		previewContext: RichAssistancePreviewContext,
		referenceTime: Date,
		reasons: inout [String]
	) -> Double {
		let safety = GeneratedActionSafetyPolicy.evaluatePlanSnapshotForDebug(p)
		guard safety.allowed, safety.safetyLevel != .blocked else {
			reasons.append(RichAssistanceRankingReason.safetyBlocked.rawValue)
			return -1e9
		}
		if !(safety.requiresUserReview || safety.safetyLevel == .reviewRequired) {
			reasons.append(RichAssistanceRankingReason.generatedConfidence.rawValue)
		} else {
			reasons.append(RichAssistanceRankingReason.reviewRequired.rawValue)
		}

		var s = 0.05
		if !(safety.requiresUserReview || safety.safetyLevel == .reviewRequired) { s += 3.85 } else { s += 2.2 }

		let wfC = min(1.0, max(0.0, wfConfidence))
		let wfMatch: Double
		if inferredWorkflow != .unknown {
			let align = (p.workflow == inferredWorkflow) ? 1.0 : 0.22
			wfMatch = align * wfC + 0.55 * (0.52 + 0.48 * (1.0 - wfC))
			reasons.append(RichAssistanceRankingReason.workflowMatch.rawValue)
		} else {
			wfMatch = 0.42
		}
		s += wfMatch * 1.95
		s += GeneratedAssistanceCategoryMapper.sortBoostForPlan(p, inferredWorkflow: inferredWorkflow)
		s += p.confidence * 1.25
		reasons.append(RichAssistanceRankingReason.generatedConfidence.rawValue)

		let ttl = max(30.0, p.expiresAt.timeIntervalSince(p.createdAt))
		s += max(0.0, min(1.0, p.expiresAt.timeIntervalSinceNow / ttl)) * 0.48
		if let ses = session, !ses.isStale, ses.dominantWorkflow == p.workflow, ses.dominantWorkflow != .unknown {
			s += 0.09 * ses.continuityScore
			reasons.append(RichAssistanceRankingReason.sessionContinuity.rawValue)
		}

		s += GeneratedActionInteractionTracker.shared.sortAdjustment(forPlan: p, referenceTime: referenceTime)

		applyFusedAndTimingModifiers(fused: previewContext.fused, timing: previewContext.timing, score: &s, reasons: &reasons)

		if p.isStale {
			s -= 0.28
			reasons.append(RichAssistanceRankingReason.stalePenalty.rawValue)
		}

		return s
	}

	private static func applyFusedAndTimingModifiers(
		fused: FusedContextPacket?,
		timing: ProposalTimingDecision,
		score: inout Double,
		reasons: inout [String]
	) {
		if let f = fused {
			if f.freshnessScore >= 0.55, !f.isStale {
				score += 0.10
				reasons.append(RichAssistanceRankingReason.contextFresh.rawValue)
			}
			let conflict = min(1.0, max(0.0, f.conflictScore))
			score -= conflict * 0.28
			if conflict > 0.45 {
				reasons.append(RichAssistanceRankingReason.conflictPenalty.rawValue)
			}
			if f.isStale || f.freshnessScore < 0.18 {
				score *= 0.58
				reasons.append(RichAssistanceRankingReason.weakContextFallback.rawValue)
			}
		}

		switch timing.outcome {
		case .suppress:
			let strongSel = (fused?.hasSelectedText == true)
				&& ((fused?.textLength ?? 0) >= TriggerEngine.selectedTextMinCharacterCount)
				&& (fused?.primaryTextSource == .selectedText)
			if !strongSel {
				score *= 0.82
				reasons.append(RichAssistanceRankingReason.interruptionDampen.rawValue)
			}
		case .deferred:
			score -= 0.05
			reasons.append(RichAssistanceRankingReason.interruptionDampen.rawValue)
		case .allow:
			break
		}
	}

	private static func applyInteractionReasonTags(
		action: GeneratedAction,
		snapshot: GeneratedActionInteractionSnapshot,
		reasons: inout [String]
	) {
		let catRaw = GeneratedAssistanceCategoryMapper.mapAction(action).category.rawValue
		if let dis = snapshot.recentDismissedCategory, dis == catRaw {
			reasons.append(RichAssistanceRankingReason.recentDismissal.rawValue)
		}
		if snapshot.acceptedProxyCount > 0, let top = snapshot.topUsefulCategory, top == catRaw {
			reasons.append(RichAssistanceRankingReason.acceptedProxyBoost.rawValue)
		}
		if snapshot.ignoredCount >= 3 {
			reasons.append(RichAssistanceRankingReason.ignoredPenalty.rawValue)
		}
	}

	private static func capReasons(_ r: [String]) -> [String] {
		var seen = Set<String>()
		var out: [String] = []
		for x in r where !x.isEmpty {
			if seen.insert(x).inserted {
				out.append(x)
				if out.count >= maxReasonsPerCandidate { break }
			}
		}
		return out
	}

	private static func logRankSummaryIfNeeded(result: RichAssistanceRankingResult, topReasons: [String]) {
		let now = Date()
		let sig = "\(result.candidates.count)|\(result.suppressedCount)|\(result.hiddenCount)|\(topReasons.prefix(3).joined(separator: ","))"
		if sig == lastRankLogSig, let lastRankLogAt, now.timeIntervalSince(lastRankLogAt) < 1.85 { return }
		lastRankLogSig = sig
		lastRankLogAt = now
		let primary = result.candidates.first(where: { $0.prominence == .primary })?.stableKey ?? result.candidates.first?.stableKey ?? "nil"
		let reasonJoined = topReasons.prefix(4).joined(separator: ",")
		print("[RichAssistanceRank] ranked count=\(result.candidates.count) primary=\(primary) reason=\(reasonJoined.isEmpty ? "none" : reasonJoined)")
		if result.suppressedCount > 0 {
			print("[RichAssistanceRank] suppressed count=\(result.suppressedCount) reason=weak_context")
		}
	}

	private static func logPlacementsIfNeeded(candidates: [RichAssistanceCandidate]) {
		var n = 0
		for c in candidates where c.placement == .generatedPreview || c.placement == .inlineCandidate {
			guard n < maxPreviewPlacementLogs else { break }
			print("[RichAssistanceRank] placement candidate=\(c.stableKey) placement=\(c.placement.rawValue) prominence=\(c.prominence.rawValue)")
			n += 1
		}
	}
}

// MARK: - Self-test

extension RichAssistanceRanker {
	static func runSelfTest() -> Bool {
		print("[RichAssistanceRank] selftest starting")
		var failures: [String] = []
		func a(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let t0 = Date(timeIntervalSince1970: 2_140_000_000)
		resetLatestForTests()
		GeneratedActionInteractionTracker.shared.reset()

		func fusedPacket(
			hasSelection: Bool,
			textLen: Int,
			fresh: Double,
			conf: Double,
			conflict: Double,
			stale: Bool,
			primarySel: Bool
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: t0,
				primarySource: hasSelection ? .selectedText : .none,
				availableSources: [.selectedText],
				staleSources: stale ? [.selectedText] : [],
				appName: "App",
				bundleIdentifier: "test.bundle",
				windowTitleAvailable: false,
				primaryTextSource: primarySel ? .selectedText : .clipboardText,
				textAvailability: hasSelection,
				textLength: textLen,
				lineCount: 4,
				hasSelectedText: hasSelection,
				hasClipboardText: false,
				hasOCRText: false,
				hasAXText: false,
				hasWindowSnapshot: false,
				hasVisualDescriptor: false,
				hasTypingActivity: false,
				hasPointerActivity: false,
				visualKinds: [],
				uiStructureHints: [],
				typingState: nil,
				pointerState: nil,
				confidence: conf,
				freshnessScore: fresh,
				conflictScore: conflict,
				isStale: stale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["selftest"],
				debugSummaryMetadata: ["selftest": "1"]
			)
		}

		let wfDebug = WorkflowInferenceResult(
			workflow: .debugging,
			confidence: 0.82,
			contributingSignals: ["t"],
			inferredAt: t0,
			isStale: false,
			summaryHint: nil,
			sourceFusedId: nil
		)
		let sessionMatch = ContextualSessionState(
			continuityScore: 0.62,
			continuityConfidence: 0.55,
			patternConfidence: 0.6,
			dominantWorkflow: .debugging,
			activeTrajectorySummary: "debugging",
			contributingSignals: [.workflowStreak],
			updatedAt: t0,
			isStale: false
		)

		let intentExplain = SynthesizedIntent(
			id: UUID(),
			type: .explainLikelyError,
			title: "Explain",
			description: "Explain the issue",
			confidence: 0.86,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			supportingSignals: ["e"],
			interruptionCost: 0.25,
			freshness: 0.9,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["rule"]
		)
		guard case .produced(let gaExplain) = GeneratedActionFactory.materialize(from: intentExplain, referenceTime: t0, source: .selfTest) else {
			a("materialize_explain", false)
			let ok = failures.isEmpty
			print("[RichAssistanceRank] selftest summary ok=\(ok) detail=\(failures.joined(separator: ";"))")
			return ok
		}

		let intentBrowse = SynthesizedIntent(
			id: UUID(),
			type: .summarizeCurrentArticle,
			title: "Summarize",
			description: "Summarize page",
			confidence: 0.72,
			workflow: .research,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.5,
			freshness: 0.8,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["r"]
		)
		guard case .produced(let gaBrowse) = GeneratedActionFactory.materialize(from: intentBrowse, referenceTime: t0, source: .selfTest) else {
			a("materialize_browse", false)
			let ok = failures.isEmpty
			print("[RichAssistanceRank] selftest summary ok=\(ok) detail=\(failures.joined(separator: ";"))")
			return ok
		}

		let blockedProfile = GeneratedActionSafetyProfile(
			requiresUserApproval: false,
			canRunAutomatically: false,
			readsContextOnly: true,
			writesExternalState: false,
			executesCode: false,
			usesNetwork: true,
			usesShell: false,
			usesBrowserAutomation: false,
			touchesFileSystem: false,
			requiresAppControl: false,
			requiresPrivilegedAction: false
		)
		let gaBlocked = GeneratedAction(
			id: UUID(),
			title: "Net",
			description: "Call",
			intentType: .explainLikelyError,
			confidence: 0.9,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			primitives: [.explain],
			interruptionCost: 0.2,
			workflowRelevance: 0.9,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["x"],
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: false,
			safetyProfile: blockedProfile,
			explainabilitySummary: "meta",
			source: .selfTest,
			structuredExplainability: nil
		)

		let gaReview = GeneratedAction(
			id: UUID(),
			title: "Draft",
			description: "Draft fix",
			intentType: .draftReply,
			confidence: 0.77,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			primitives: [.draft],
			interruptionCost: 0.4,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["d"],
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: false,
			safetyProfile: .profile(for: [.draft]),
			explainabilitySummary: "meta",
			source: .selfTest,
			structuredExplainability: nil
		)

		let strongFused = fusedPacket(hasSelection: true, textLen: 120, fresh: 0.78, conf: 0.8, conflict: 0.05, stale: false, primarySel: true)
		let weakFused = fusedPacket(hasSelection: false, textLen: 4, fresh: 0.1, conf: 0.2, conflict: 0.05, stale: true, primarySel: false)
		let conflictFused = fusedPacket(hasSelection: true, textLen: 80, fresh: 0.7, conf: 0.65, conflict: 0.92, stale: false, primarySel: true)

		let timingAllow = ProposalTimingDecision(outcome: .allow, reason: "test", suggestedRetryAfter: nil)
		let timingSuppress = ProposalTimingDecision(outcome: .suppress, reason: "weak_context_deferred", suggestedRetryAfter: nil)

		let wfRank = WorkflowAwareProposalRankingResult(
			adjustedScores: [
				ActionRelevanceScore(actionId: "explain_text", score: 0.81, reason: "wf"),
				ActionRelevanceScore(actionId: "summarize_text", score: 0.5, reason: "wf")
			],
			rankedGeneratedActionIds: [gaExplain.id.uuidString],
			primaryCategory: .staticAction,
			suggestedStaticPrimary: "explain_text",
			confidence: 0.8,
			interruptionCost: 0.3,
			reasonCodes: [.boostedExplainDebugging],
			adjustment: WorkflowProposalAdjustment(scoreDeltasByActionId: [:], reasonCodes: [])
		)

		// Strong static explain remains primary
		let inStrong = RichAssistanceRankingInput(
			referenceTime: t0,
			staticActionIds: ["summarize_text", "explain_text"],
			staticBaseScores: [:],
			workflowProposalRanking: wfRank,
			generatedActions: [gaExplain, gaBrowse],
			generatedPlans: [],
			workflowInference: wfDebug,
			session: sessionMatch,
			fused: strongFused,
			timing: timingAllow,
			proposalPrimaryActionId: "explain_text",
			inlineDismissalKeys: ["chip1"],
			interactionSnapshot: nil
		)
		let rStrong = rankUnified(input: inStrong)
		let explainCand = rStrong.candidates.first { $0.stableKey == "s:explain_text" }
		a("static_primary", (explainCand?.prominence == .primary) == true)
		let genTop = rStrong.candidates.filter { $0.type == .generatedAction }.max(by: { $0.score < $1.score })
		a("gen_preview_only", genTop?.isExecutable == false && genTop?.placement == .generatedPreview)

		// Blocked hidden
		let inBlocked = RichAssistanceRankingInput(
			referenceTime: t0,
			staticActionIds: ["explain_text"],
			staticBaseScores: [:],
			workflowProposalRanking: nil,
			generatedActions: [gaBlocked, gaExplain],
			generatedPlans: [],
			workflowInference: wfDebug,
			session: sessionMatch,
			fused: strongFused,
			timing: timingAllow,
			proposalPrimaryActionId: nil,
			inlineDismissalKeys: [],
			interactionSnapshot: nil
		)
		let rBlocked = rankUnified(input: inBlocked)
		a("blocked_hidden", rBlocked.hiddenCount >= 1 && rBlocked.candidates.filter { $0.type == .generatedAction }.count == 1)

		// Review required still preview path
		let inReview = RichAssistanceRankingInput(
			referenceTime: t0,
			staticActionIds: [],
			staticBaseScores: [:],
			workflowProposalRanking: nil,
			generatedActions: [gaReview],
			generatedPlans: [],
			workflowInference: wfDebug,
			session: sessionMatch,
			fused: strongFused,
			timing: timingAllow,
			proposalPrimaryActionId: nil,
			inlineDismissalKeys: [],
			interactionSnapshot: nil
		)
		let rRev = rankUnified(input: inReview)
		let revCand = rRev.candidates.first { $0.type == .generatedAction }
		a("review_preview", revCand?.placement == .generatedPreview && revCand?.reasonCodes.contains(RichAssistanceRankingReason.reviewRequired.rawValue) == true)

		// Weak context suppresses generated prominence (score path)
		let inWeak = RichAssistanceRankingInput(
			referenceTime: t0,
			staticActionIds: ["summarize_text", "explain_text"],
			staticBaseScores: ["summarize_text": 0.51, "explain_text": 0.53],
			workflowProposalRanking: nil,
			generatedActions: [gaExplain],
			generatedPlans: [],
			workflowInference: WorkflowInferenceResult(
				workflow: .unknown,
				confidence: 0.05,
				contributingSignals: [],
				inferredAt: t0,
				isStale: false,
				summaryHint: nil,
				sourceFusedId: nil
			),
			session: nil,
			fused: weakFused,
			timing: timingAllow,
			proposalPrimaryActionId: nil,
			inlineDismissalKeys: [],
			interactionSnapshot: nil
		)
		let rWeak = rankUnified(input: inWeak)
		let staticOrder = rWeak.candidates.filter { $0.type == .staticAction }.sorted { $0.score > $1.score }.map(\.stableKey)
		a("weak_static_order", staticOrder.first == "s:explain_text" || staticOrder.first == "s:summarize_text")

		// Session / workflow boost: debugging GA scores higher than browse under wfDebug
		let ctxPrev = RichAssistancePreviewContext(fused: strongFused, timing: timingAllow)
		let sDebug = previewSortScoreGeneratedAction(gaExplain, inferredWorkflow: .debugging, wfConfidence: 0.82, session: sessionMatch, previewContext: ctxPrev, referenceTime: t0)
		let sBrowse = previewSortScoreGeneratedAction(gaBrowse, inferredWorkflow: .debugging, wfConfidence: 0.82, session: sessionMatch, previewContext: ctxPrev, referenceTime: t0)
		a("wf_boost_debug", sDebug > sBrowse)

		// Interruption / timing dampen without breaking sort API
		let ctxSuppress = RichAssistancePreviewContext(fused: weakFused, timing: timingSuppress)
		let sSup = previewSortScoreGeneratedAction(gaExplain, inferredWorkflow: .debugging, wfConfidence: 0.82, session: nil, previewContext: ctxSuppress, referenceTime: t0)
		a("interruption_dampen", sSup < sDebug)

		// Conflict lowers vs low-conflict
		let ctxConflict = RichAssistancePreviewContext(fused: conflictFused, timing: timingAllow)
		let sConf = previewSortScoreGeneratedAction(gaExplain, inferredWorkflow: .debugging, wfConfidence: 0.82, session: sessionMatch, previewContext: ctxConflict, referenceTime: t0)
		a("conflict_lower", sConf < sDebug)

		// Dismissal / usefulness / proxy tags via unified rank + interaction snapshot
		let dismissCat = GeneratedAssistanceCategoryMapper.mapAction(gaExplain).category.rawValue
		let snapDismiss = GeneratedActionInteractionSnapshot(
			recentEventCount: 3,
			topUsefulCategory: dismissCat,
			recentDismissedCategory: dismissCat,
			ignoredCount: 4,
			acceptedProxyCount: 2,
			expandedCount: 0
		)
		let inInteract = RichAssistanceRankingInput(
			referenceTime: t0,
			staticActionIds: [],
			staticBaseScores: [:],
			workflowProposalRanking: nil,
			generatedActions: [gaExplain],
			generatedPlans: [],
			workflowInference: wfDebug,
			session: sessionMatch,
			fused: strongFused,
			timing: timingAllow,
			proposalPrimaryActionId: nil,
			inlineDismissalKeys: [],
			interactionSnapshot: snapDismiss
		)
		let rInteract = rankUnified(input: inInteract)
		let gaRow = rInteract.candidates.first { $0.type == .generatedAction }
		a("dismiss_reason", gaRow?.reasonCodes.contains(RichAssistanceRankingReason.recentDismissal.rawValue) == true)
		a("ignored_penalty_tag", gaRow?.reasonCodes.contains(RichAssistanceRankingReason.ignoredPenalty.rawValue) == true)
		a("proxy_boost_tag", gaRow?.reasonCodes.contains(RichAssistanceRankingReason.acceptedProxyBoost.rawValue) == true)

		// Stale generated action picks up stale_penalty in preview scoring path
		let gaStale = GeneratedAction(
			id: UUID(),
			title: gaExplain.title,
			description: gaExplain.description,
			intentType: gaExplain.intentType,
			confidence: gaExplain.confidence,
			workflow: gaExplain.workflow,
			requiredContext: gaExplain.requiredContext,
			primitives: gaExplain.primitives,
			interruptionCost: gaExplain.interruptionCost,
			workflowRelevance: gaExplain.workflowRelevance,
			sourceIntentId: gaExplain.sourceIntentId,
			sourceReasonCodes: gaExplain.sourceReasonCodes,
			createdAt: t0,
			expiresAt: t0.addingTimeInterval(120),
			isStale: true,
			safetyProfile: gaExplain.safetyProfile,
			explainabilitySummary: gaExplain.explainabilitySummary,
			source: .selfTest,
			structuredExplainability: nil
		)
		var staleRs: [String] = []
		let staleScore = scoreGeneratedActionForPreview(
			gaStale,
			inferredWorkflow: .debugging,
			wfConfidence: 0.82,
			session: sessionMatch,
			previewContext: ctxPrev,
			referenceTime: t0,
			reasons: &staleRs
		)
		a("stale_penalty", staleRs.contains(RichAssistanceRankingReason.stalePenalty.rawValue) && staleScore < previewSortScoreGeneratedAction(gaExplain, inferredWorkflow: .debugging, wfConfidence: 0.82, session: sessionMatch, previewContext: ctxPrev, referenceTime: t0))

		// Placement bounded: inline + proposal use known placements
		let placements = Set(rStrong.candidates.map(\.placement))
		a("placements_bounded", placements.isSubset(of: Set(RichAssistancePlacement.allCases)))

		// No executable generated
		a("no_exec_gen", rStrong.candidates.filter { $0.type == .generatedAction || $0.type == .generatedPlan }.allSatisfy { !$0.isExecutable })

		let ok = failures.isEmpty
		print("[RichAssistanceRank] selftest summary ok=\(ok) detail=\(failures.joined(separator: ";"))")
		resetLatestForTests()
		GeneratedActionInteractionTracker.shared.reset()
		return ok
	}
}
