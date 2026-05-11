import Foundation

// MARK: - Visible intelligence debug (T16.11; metadata-only; internal)

/// Compact snapshot of why visible intelligence surfaced or not (no raw user content).
struct VisibleIntelligenceDebugSummary: Equatable, Sendable {
	let isAvailable: Bool
	let topRankedAssistanceLine: String
	let generatedSurfacingLine: String
	let workflowInfluenceLine: String
	let suppressionLine: String
	let interactionUsefulnessLine: String
	let proposalContextLine: String
	let inlineAssistanceLine: String
	let screenSituationLine: String
	let reasonCodes: [String]
	let generatedAt: Date

	static let empty = VisibleIntelligenceDebugSummary(
		isAvailable: false,
		topRankedAssistanceLine: "",
		generatedSurfacingLine: "",
		workflowInfluenceLine: "",
		suppressionLine: "",
		interactionUsefulnessLine: "",
		proposalContextLine: "",
		inlineAssistanceLine: "",
		screenSituationLine: "",
		reasonCodes: [],
		generatedAt: Date(timeIntervalSince1970: 0)
	)

	var showsVisibleIntelligenceDebug: Bool {
		isAvailable
	}
}

struct VisibleIntelligenceDebugCapture: Equatable, Sendable {
	let proposalContext: ProposalContextSummary
	let inline: InlineAssistanceSnapshot
	let dynamicDisplay: DynamicActionDisplaySummary
	let richRanking: RichAssistanceRankingResult
	let workflow: WorkflowInferenceResult?
	let session: ContextualSessionState?
	let synthesis: IntentSynthesisResult?
	let suppression: IntentSuppressionDecision?
	let interactionSummaryLine: String
	let screenSituation: ScreenSituation?
	let workflowRanking: WorkflowAwareProposalRankingResult?

	static func fromSharedAppState(
		proposalContext: ProposalContextSummary,
		inline: InlineAssistanceSnapshot,
		dynamicDisplay: DynamicActionDisplaySummary,
		richRanking: RichAssistanceRankingResult
	) -> VisibleIntelligenceDebugCapture {
		VisibleIntelligenceDebugCapture(
			proposalContext: proposalContext,
			inline: inline,
			dynamicDisplay: dynamicDisplay,
			richRanking: richRanking,
			workflow: WorkflowInferenceEngine.shared.latestResult(),
			session: ContextualSessionTracker.shared.currentState(),
			synthesis: IntentSynthesisEngine.shared.latestResult(),
			suppression: DynamicIntentSuppressionEngine.shared.latestDecisionSnapshot(),
			interactionSummaryLine: GeneratedActionInteractionTracker.shared.debugSummaryLine(),
			screenSituation: ScreenSituationClassifier.latestClassificationSnapshot(),
			workflowRanking: WorkflowAwareProposalRanker.latestRankingSnapshot()
		)
	}
}

enum VisibleIntelligenceDebugSummaryBuilder {
	private static let maxLineLength = 118
	private static let maxReasonCodes = 8

	static func build(_ capture: VisibleIntelligenceDebugCapture, referenceTime: Date = Date()) -> VisibleIntelligenceDebugSummary {
		let topRanked = lineTopRanked(from: capture.richRanking)
		let genSurf = lineGeneratedSurfacing(from: capture.dynamicDisplay)
		let wfLine = lineWorkflowInfluence(
			workflow: capture.workflow,
			session: capture.session,
			richRanking: capture.richRanking,
			workflowRanking: capture.workflowRanking
		)
		let supLine = lineSuppression(synthesis: capture.synthesis, suppression: capture.suppression)
		let interactLine = clamp(capture.interactionSummaryLine)
		let proposalLine = lineProposalContext(capture.proposalContext)
		let inlineLine = lineInline(capture.inline)
		let screenLine = lineScreenSituation(capture.screenSituation)
		let codes = mergeReasonCodes(
			rich: capture.richRanking,
			suppression: capture.suppression,
			synthesis: capture.synthesis
		)

		let available = computeAvailable(
			topRanked: topRanked,
			genSurf: genSurf,
			wfLine: wfLine,
			supLine: supLine,
			proposalLine: proposalLine,
			inlineLine: inlineLine,
			screenLine: screenLine,
			reasonCodes: codes,
			capture: capture
		)

		return VisibleIntelligenceDebugSummary(
			isAvailable: available,
			topRankedAssistanceLine: sanitizeMetadata(topRanked),
			generatedSurfacingLine: sanitizeMetadata(genSurf),
			workflowInfluenceLine: sanitizeMetadata(wfLine),
			suppressionLine: sanitizeMetadata(supLine),
			interactionUsefulnessLine: sanitizeMetadata(interactLine),
			proposalContextLine: sanitizeMetadata(proposalLine),
			inlineAssistanceLine: sanitizeMetadata(inlineLine),
			screenSituationLine: sanitizeMetadata(screenLine),
			reasonCodes: Array(codes.prefix(maxReasonCodes)),
			generatedAt: referenceTime
		)
	}

	// MARK: - Lines

	private static func lineTopRanked(from rich: RichAssistanceRankingResult) -> String {
		guard let top = rich.candidates.first else { return "" }
		let idPart = top.stableKey
			.replacingOccurrences(of: "s:", with: "")
			.replacingOccurrences(of: "g:", with: "ga:")
			.replacingOccurrences(of: "p:", with: "plan:")
		return "Top: \(idPart) · \(top.prominence.rawValue) · \(top.type.rawValue)"
	}

	private static func lineGeneratedSurfacing(from d: DynamicActionDisplaySummary) -> String {
		let n = d.previewItems.count
		let blocked = d.blockedSkippedTotal
		guard n > 0 || blocked > 0 else { return "" }
		let topCat = d.previewItems.first?.category.rawValue ?? "none"
		let group = d.previewGroupLabel.map { sanitizeToken($0) } ?? "none"
		return "Generated: \(n) preview · cat=\(topCat) · group=\(group) · blocked=\(blocked) · preview_only"
	}

	private static func lineWorkflowInfluence(
		workflow: WorkflowInferenceResult?,
		session: ContextualSessionState?,
		richRanking: RichAssistanceRankingResult,
		workflowRanking: WorkflowAwareProposalRankingResult?
	) -> String {
		guard let wf = workflow else { return "" }
		let wfConf = confidenceBucket(wf.confidence)
		let cont = session.map { continuityBucket($0.continuityConfidence) } ?? "none"
		let stale = wf.isStale ? "stale" : "fresh"
		let wfTouch = richRanking.aggregateReasonCodes.contains("workflow_match")
			|| (workflowRanking?.reasonCodes.contains(.boostedExplainDebugging) ?? false)
		let touch = wfTouch ? "ranking_touch=y" : "ranking_touch=n"
		return "Workflow: \(wf.workflow.rawValue) · conf=\(wfConf) · continuity=\(cont) · \(stale) · \(touch)"
	}

	private static func lineSuppression(
		synthesis: IntentSynthesisResult?,
		suppression: IntentSuppressionDecision?
	) -> String {
		let sup = suppression ?? synthesis?.suppression
		guard let s = sup else {
			if let syn = synthesis, let sr = syn.skippedReason, !sr.isEmpty {
				return "Suppression: synth_skip=\(sanitizeToken(sr))"
			}
			return ""
		}
		let top = s.suppressed.first.map { "\($0.reason.rawValue)" } ?? "none"
		return "Suppression: allowed=\(s.allowed.count) suppressed=\(s.suppressed.count) top=\(top)"
	}

	private static func lineProposalContext(_ p: ProposalContextSummary) -> String {
		guard p.isAvailable else { return "" }
		let chipN = p.chips.count
		let gen = p.hasGeneratedInfluence ? "y" : "n"
		let intent = p.hasIntentAlignment ? "y" : "n"
		let chipPreview = p.chips.prefix(3).joined(separator: ",")
		return "Proposal ctx: chips=\(chipN) gen=\(gen) intent=\(intent) codes=\(clamp(chipPreview, 72))"
	}

	private static func lineInline(_ snap: InlineAssistanceSnapshot) -> String {
		let n = max(snap.candidateCount, snap.candidates.count)
		guard n > 0 else { return "" }
		let topPlace = snap.candidates.first?.placementHint.rawValue ?? snap.rows.first?.placementHint.rawValue ?? "none"
		let elig = snap.eligibility.reasonCodes.prefix(3).joined(separator: ",")
		return "Inline: count=\(n) top_place=\(topPlace) eligibility=\(clamp(elig, 64))"
	}

	private static func lineScreenSituation(_ s: ScreenSituation?) -> String {
		guard let s else { return "" }
		let sigCount = s.supportedBy.count
		return "Screen: kind=\(s.kind.rawValue) conf=\(s.confidenceBucket) style=\(s.responseStyle.rawValue) signals=\(sigCount)"
	}

	// MARK: - Availability + reasons

	private static func computeAvailable(
		topRanked: String,
		genSurf: String,
		wfLine: String,
		supLine: String,
		proposalLine: String,
		inlineLine: String,
		screenLine: String,
		reasonCodes: [String],
		capture: VisibleIntelligenceDebugCapture
	) -> Bool {
		if !reasonCodes.isEmpty { return true }
		if capture.richRanking.candidates.isEmpty == false { return true }
		if capture.dynamicDisplay.previewItems.isEmpty == false { return true }
		if capture.dynamicDisplay.blockedSkippedTotal > 0 { return true }
		if capture.inline.candidateCount > 0 { return true }
		if capture.proposalContext.isAvailable { return true }
		if capture.suppression?.suppressed.isEmpty == false { return true }
		if let syn = capture.synthesis, syn.suppression?.suppressed.isEmpty == false { return true }
		if let syn = capture.synthesis, syn.intents.isEmpty == false { return true }
		if interactionLineShowsActivity(capture.interactionSummaryLine) { return true }
		if capture.workflow.map({ !$0.isStale && $0.workflow != .unknown }) == true { return true }
		if capture.screenSituation != nil { return true }
		if !topRanked.isEmpty || !genSurf.isEmpty || !wfLine.isEmpty || !supLine.isEmpty { return true }
		if !proposalLine.isEmpty { return true }
		if !inlineLine.isEmpty { return true }
		if !screenLine.isEmpty { return true }
		return false
	}

	private static func interactionLineShowsActivity(_ line: String) -> Bool {
		guard !line.isEmpty else { return false }
		// `GeneratedActionInteractionTracker.debugSummaryLine()` format: events=N ...
		if let r = line.range(of: "events=") {
			let tail = line[r.upperBound...]
			let digits = tail.prefix(while: { $0.isNumber })
			if let n = Int(digits), n > 0 { return true }
		}
		if let r = line.range(of: "ignored=") {
			let tail = line[r.upperBound...]
			let digits = tail.prefix(while: { $0.isNumber })
			if let n = Int(digits), n > 0 { return true }
		}
		if let r = line.range(of: "proxies=") {
			let tail = line[r.upperBound...]
			let digits = tail.prefix(while: { $0.isNumber })
			if let n = Int(digits), n > 0 { return true }
		}
		return false
	}

	private static func mergeReasonCodes(
		rich: RichAssistanceRankingResult,
		suppression: IntentSuppressionDecision?,
		synthesis: IntentSynthesisResult?
	) -> [String] {
		var out: [String] = []
		var seen = Set<String>()
		for c in rich.aggregateReasonCodes {
			if seen.insert(c).inserted { out.append(c) }
		}
		let sup = suppression ?? synthesis?.suppression
		if let s = sup {
			for r in s.reasonCodes.map(\.rawValue) {
				if seen.insert(r).inserted { out.append(r) }
				if out.count >= maxReasonCodes { break }
			}
		}
		return out
	}

	// MARK: - Sanitization

	static func sanitizeMetadata(_ s: String) -> String {
		var t = clamp(s, maxLineLength)
		if t.contains("://") {
			t = "[redacted_url_like]"
		}
		return t
	}

	private static func sanitizeToken(_ s: String) -> String {
		let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.contains("://") { return "redacted" }
		return clamp(trimmed, 48)
	}

	private static func clamp(_ s: String, _ max: Int = maxLineLength) -> String {
		guard s.count > max else { return s }
		return String(s.prefix(max))
	}

	private static func confidenceBucket(_ c: Double) -> String {
		let x = min(1.0, max(0.0, c))
		if x >= 0.68 { return "high" }
		if x >= 0.48 { return "medium" }
		if x > 0 { return "low" }
		return "unknown"
	}

	private static func continuityBucket(_ c: Double) -> String {
		if c >= 0.62 { return "strong" }
		if c >= 0.42 { return "medium" }
		if c > 0 { return "weak" }
		return "unknown"
	}
}

// MARK: - Logging (metadata-only)

enum VisibleIntelligenceDebugLogger {
	private static var lastSig: String?
	private static var lastAt: Date?

	static func logIfNeeded(_ summary: VisibleIntelligenceDebugSummary) {
		let now = Date()
		if summary.isAvailable {
			let top = summary.topRankedAssistanceLine.isEmpty ? "none" : sanitizeForLog(summary.topRankedAssistanceLine)
			let gen = summary.generatedSurfacingLine.isEmpty ? "none" : sanitizeForLog(summary.generatedSurfacingLine)
			let wf = summary.workflowInfluenceLine.isEmpty ? "none" : sanitizeForLog(summary.workflowInfluenceLine)
			let sig = "\(top)|\(gen)|\(wf)"
			if sig == lastSig, let lastAt, now.timeIntervalSince(lastAt) < 1.9 { return }
			lastSig = sig
			lastAt = now
			print("[VisibleIntelligenceDebug] updated top=\(top) generated=\(gen) workflow=\(wf)")
		} else {
			let sig = "hidden"
			if sig == lastSig, let lastAt, now.timeIntervalSince(lastAt) < 2.1 { return }
			lastSig = sig
			lastAt = now
			print("[VisibleIntelligenceDebug] hidden reason=no_visible_state")
		}
	}

	private static func sanitizeForLog(_ s: String) -> String {
		var t = String(s.prefix(96))
		if t.contains("://") { t = "redacted" }
		return t
	}
}

// MARK: - Self-test

extension VisibleIntelligenceDebugSummaryBuilder {
	static func runSelfTest() -> Bool {
		print("[VisibleIntelligenceDebug] selftest starting")
		var failures: [String] = []
		func a(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let t0 = Date(timeIntervalSince1970: 2_150_000_000)
		let gaRow = DynamicActionDisplayModel(
			id: UUID(),
			title: "Preview",
			shortDescription: "meta",
			category: .debugging,
			assistanceCategoryReason: .intent,
			workflowLabel: "debugging",
			confidenceBucket: "high",
			safetyBadge: .safeReadOnly,
			reviewRequired: false,
			primitiveLabels: ["explain"],
			reasonChips: ["preview_only"],
			interruptionCostBucket: "low",
			sourceIntentType: SynthesizedIntentType.explainLikelyError.rawValue,
			source: .generatedAction,
			isExecutable: false,
			isPreviewOnly: true
		)
		let dyn = DynamicActionDisplaySummary(
			previewItems: [gaRow],
			blockedDebugLines: ["blocked id=abcdef01 intent=explain_likely_error codes=network_not_allowed"],
			blockedSkippedTotal: 1,
			previewGroupLabel: "Debugging https://evil.example/path"
		)

		let topCand = RichAssistanceCandidate(
			stableKey: "s:explain_text",
			type: .staticAction,
			score: 0.9,
			prominence: .primary,
			placement: .availableActions,
			reasonCodes: ["static_base_relevance", "workflow_match"],
			isExecutable: true
		)
		let rich = RichAssistanceRankingResult(
			candidates: [topCand],
			suppressedCount: 0,
			hiddenCount: 1,
			aggregateReasonCodes: ["workflow_match", "generated_confidence"],
			debugLine: "rank_meta",
			usefulnessInfluenceSummary: "events=2 ignored=0 expanded=1 proxies=1 topCat=debugging dismissCat=none"
		)

		let intent = SynthesizedIntent(
			id: UUID(),
			type: .explainLikelyError,
			title: "Explain",
			description: "D",
			confidence: 0.8,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.3,
			freshness: 0.9,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["r"]
		)
		let suppressedIntent = SynthesizedIntent(
			id: UUID(),
			type: .summarizeCurrentArticle,
			title: "Sum",
			description: "X",
			confidence: 0.6,
			workflow: .research,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.4,
			freshness: 0.8,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: []
		)
		let sup = IntentSuppressionDecision(
			rawIntents: [intent, suppressedIntent],
			allowed: [intent],
			suppressed: [IntentSuppressionEntry(intentType: .summarizeCurrentArticle, reason: .repeatedIntent)],
			reasonCodes: [.repeatedIntent]
		)
		let syn = IntentSynthesisResult(
			intents: [intent],
			suppressedReason: nil,
			skippedReason: nil,
			synthesizedAt: t0,
			suppression: sup
		)

		let wf = WorkflowInferenceResult(
			workflow: .debugging,
			confidence: 0.77,
			contributingSignals: ["editor"],
			inferredAt: t0,
			isStale: false,
			summaryHint: nil,
			sourceFusedId: nil
		)
		let session = ContextualSessionState(
			continuityScore: 0.5,
			continuityConfidence: 0.55,
			patternConfidence: 0.5,
			dominantWorkflow: .debugging,
			activeTrajectorySummary: "debugging",
			contributingSignals: [.workflowStreak],
			updatedAt: t0,
			isStale: false
		)

		let chip = InlineAssistanceChipModel(
			candidateId: UUID(),
			shortLabel: "Explain",
			surfaceType: .explainChip,
			placementHint: .assistantPanelOnly,
			categoryRaw: "debugging",
			safetyBadgeRaw: "safeReadOnly"
		)
		let inline = InlineAssistanceSnapshot(
			candidates: [chip],
			rows: [],
			eligibility: InlineAssistanceEligibility(allowsCandidates: true, reasonCodes: ["ok"])
		)

		let proposal = ProposalContextSummary(
			isAvailable: true,
			contextSubtitle: "debugging · confidence high",
			chips: ["debugging", "confidence_high", "assist_debugging"],
			whyLine: "Suggested from workflow context.",
			explainHint: nil,
			hasGeneratedInfluence: true,
			hasIntentAlignment: true
		)

		let situation = ScreenSituation(
			kind: .terminalOrLog,
			confidenceBucket: "medium",
			responseStyle: .terminalLogInvestigate,
			supportedBy: [.ocrContent, .workflowAligned],
			cautionLevel: "low",
			shouldUseWorkflow: true,
			shouldMentionLimitedEvidence: false,
			shouldSuppressMetadataNarration: true,
			visualEvidenceConflicting: false,
			shouldSkipLocalAI: true,
			deterministicUserReply: "do not leak this body in debug summary"
		)

		let wfRank = WorkflowAwareProposalRankingResult(
			adjustedScores: [ActionRelevanceScore(actionId: "explain_text", score: 0.8, reason: "t")],
			rankedGeneratedActionIds: [],
			primaryCategory: .staticAction,
			suggestedStaticPrimary: "explain_text",
			confidence: 0.8,
			interruptionCost: 0.3,
			reasonCodes: [.boostedExplainDebugging],
			adjustment: WorkflowProposalAdjustment(scoreDeltasByActionId: [:], reasonCodes: [])
		)

		let cap = VisibleIntelligenceDebugCapture(
			proposalContext: proposal,
			inline: inline,
			dynamicDisplay: dyn,
			richRanking: rich,
			workflow: wf,
			session: session,
			synthesis: syn,
			suppression: sup,
			interactionSummaryLine: "GA interaction: events=3 ignored=1 expanded=1 proxies=1 topCat=debugging lastDismissCat=none",
			screenSituation: situation,
			workflowRanking: wfRank
		)

		let full = build(cap, referenceTime: t0)
		a("available", full.isAvailable)
		a("top_rank", full.topRankedAssistanceLine.contains("explain_text"))
		a("gen_surf", full.generatedSurfacingLine.contains("1 preview") && full.generatedSurfacingLine.contains("blocked=1"))
		a("wf", full.workflowInfluenceLine.contains("debugging"))
		a("sup", full.suppressionLine.contains("suppressed=1"))
		a("interact", full.interactionUsefulnessLine.contains("proxies=1"))
		a("proposal", full.proposalContextLine.contains("gen=y"))
		a("inline", full.inlineAssistanceLine.contains("count=1") && full.inlineAssistanceLine.contains("assistantPanelOnly"))
		a("screen", full.screenSituationLine.contains("terminalOrLog"))
		a("url_redacted_surf", !full.generatedSurfacingLine.contains("://"))
		a("reasons", full.reasonCodes.contains("workflow_match"))
		a("bounded_reasons", full.reasonCodes.count <= 8)

		let joined = [
			full.topRankedAssistanceLine,
			full.generatedSurfacingLine,
			full.workflowInfluenceLine,
			full.suppressionLine,
			full.interactionUsefulnessLine,
			full.proposalContextLine,
			full.inlineAssistanceLine,
			full.screenSituationLine
		].joined()
		a("no_url", !joined.contains("://"))
		a("no_leak_det_reply", !joined.contains("do not leak"))

		let emptyCap = VisibleIntelligenceDebugCapture(
			proposalContext: .unavailable,
			inline: .empty,
			dynamicDisplay: .empty,
			richRanking: .empty,
			workflow: nil,
			session: nil,
			synthesis: nil,
			suppression: nil,
			interactionSummaryLine: "",
			screenSituation: nil,
			workflowRanking: nil
		)
		let empty = build(emptyCap, referenceTime: t0)
		a("empty_hides", empty.isAvailable == false)

		let ok = failures.isEmpty
		print("[VisibleIntelligenceDebug] selftest summary ok=\(ok) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}
