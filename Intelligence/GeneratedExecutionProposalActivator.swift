import Foundation

/// Activates generated execution proposals for live UI via unified ranking (T18.3).
enum GeneratedExecutionProposalActivator {

	static let generatedProposalIdPrefix = "generated_exec:"
	static let maxPanelGeneratedVisible = 2
	static let floatingStrongScoreThreshold = 0.78
	static let panelMediumScoreThreshold = 0.52
	static let preSuppressConfidenceThreshold = 0.44

	static func generatedProposalActionId(for candidateId: String) -> String {
		"\(generatedProposalIdPrefix)\(candidateId)"
	}

	static func activateProposals(
		input: GeneratedExecutionProposalActivationInput
	) -> GeneratedExecutionProposalActivationResult {
		let referenceTime = input.referenceTime
		var preSuppressedGenerated = 0
		var preSuppressedStatic = 0

		var candidates: [GeneratedExecutionProposalCandidate] = []

		if !input.suppressStaticProposalFallback {
			for actionId in input.staticActionIds {
				let score = input.staticRelevanceScores.first(where: { $0.actionId == actionId })?.score ?? 0.55
				candidates.append(
					GeneratedExecutionProposalCandidate(
						id: actionId,
						title: staticTitle(actionId),
						description: "static_action",
						source: .staticAction,
						workflowType: staticWorkflow(actionId),
						intentType: staticIntent(actionId),
						confidence: min(1, max(0.35, score)),
						interruptionCost: actionId == ScreenAnalyzeAction.analyzeScreenId ? 0.42 : 0.18,
						explainabilitySummary: "static_fallback",
						expectedOutputSummary: "Deterministic static action result.",
						requiredContextTypes: staticRequiredContext(actionId),
						executionAction: nil,
						generatedActionId: nil,
						primitiveSignature: nil,
						isExecutableGeneratedProposal: false
					)
				)
			}
		}

		if input.useLLMGeneratedCandidatesOnly {
			for exec in input.generatedExecutionCandidates {
				if let reason = preSuppressReason(candidate: exec, input: input) {
					preSuppressedGenerated += 1
					logSuppressed(id: exec.id, reason: reason)
					continue
				}
				candidates.append(exec)
			}
		} else {
			for generated in input.generatedActions where !generated.isStale {
				if let built = GeneratedExecutionProposalCandidateBuilder.build(
					from: [generated],
					snapshot: input.snapshot,
					referenceTime: referenceTime
				).first {
					if let reason = preSuppressReason(candidate: built, input: input) {
						preSuppressedGenerated += 1
						logSuppressed(id: built.id, reason: reason)
						continue
					}
					candidates.append(built)
				}
			}

			for exec in input.generatedExecutionCandidates {
				if candidates.contains(where: { $0.id == exec.id }) { continue }
				if let reason = preSuppressReason(candidate: exec, input: input) {
					preSuppressedGenerated += 1
					logSuppressed(id: exec.id, reason: reason)
					continue
				}
				candidates.append(exec)
			}
		}

		let reusableCandidates = GeneratedExecutionProposalCandidateBuilder.buildReusable(
			from: input.reusableRecords,
			referenceTime: referenceTime
		)
		print("[GeneratedProposalActivation] reusable_candidates count=\(reusableCandidates.count) input_records=\(input.reusableRecords.count) workflow=\(input.snapshot.inferredWorkflow.rawValue) freshness=\(String(format: "%.2f", input.snapshot.freshnessScore)) workflow_conf=\(String(format: "%.2f", input.snapshot.workflowConfidence))")
		for reusable in reusableCandidates {
			if let reason = preSuppressReason(candidate: reusable, input: input) {
				preSuppressedGenerated += 1
				logSuppressed(id: reusable.id, reason: reason)
				continue
			}
			print("[GeneratedProposalActivation] reusable_passed_presuppress id=\(String(reusable.id.prefix(40))) title=\(reusable.title)")
			candidates.append(reusable)
		}

		let rankables = candidates.map { UnifiedActionRankingAdapter.fromProposalCandidate($0) }
		let fusedStale = input.snapshot.packetIsStale
		var rankingContext = UnifiedActionRankingAdapter.context(
			workflow: input.workflow,
			session: input.session,
			fusedStale: fusedStale,
			referenceTime: referenceTime
		)
		rankingContext = UnifiedActionRankingContext(
			activeWorkflow: rankingContext.activeWorkflow,
			continuityScore: rankingContext.continuityScore,
			workflowConfidence: max(rankingContext.workflowConfidence, input.snapshot.workflowConfidence),
			contextIsStale: rankingContext.contextIsStale || input.snapshot.freshnessScore < 0.32,
			referenceTime: referenceTime,
			lowConfidenceGeneratedThreshold: preSuppressConfidenceThreshold,
			maxGeneratedRatioInTopWindow: 0.55,
			topWindowSize: 6,
			staticCompetitivenessBoost: 0.06
		)

		let ranking = UnifiedActionRanker.rank(
			actions: rankables,
			context: rankingContext,
			emitLog: true
		)

		let timing = evaluateTiming(
			input: input,
			ranking: ranking,
			referenceTime: referenceTime
		)

		if timing.outcome == .suppressAll {
			logTiming(decision: timing, allowed: false)
			return GeneratedExecutionProposalActivationResult(
				visibleProposals: [],
				visibleStaticActionIds: input.suppressStaticProposalFallback ? [] : input.staticActionIds,
				suppressedGeneratedCount: preSuppressedGenerated + ranking.suppressedCount,
				suppressedStaticCount: preSuppressedStatic,
				topSourceType: ranking.rankedActions.first?.action.sourceType,
				rankingSummary: ranking.rankingReasonSummary,
				timingDecision: timing,
				warnings: ranking.warnings,
				createdAt: referenceTime,
				floatingGeneratedProposalId: nil
			)
		}

		var visibleGenerated: [GeneratedExecutionProposalPanelItem] = []
		var visibleStaticIds: [String] = []
		var rankingSuppressedGenerated = 0
		var floatingId: String?

		for ranked in ranking.rankedActions {
			let action = ranked.action
			let suppressed = ranked.rankingExplanationCodes.contains("suppressed_low_confidence")
				|| ranked.rankingExplanationCodes.contains("suppressed_low_usefulness")

			if action.sourceType == .staticAction {
				if suppressed {
					preSuppressedStatic += 1
				} else {
					visibleStaticIds.append(action.id)
				}
				continue
			}

			if suppressed {
				rankingSuppressedGenerated += 1
				continue
			}

			guard let candidate = candidates.first(where: { $0.id == action.id }) else { continue }

			let score = ranked.components.finalScore
			let panelEligible = timing.allowsPanelGenerated
				&& score >= panelMediumScoreThreshold
				&& visibleGenerated.count < maxPanelGeneratedVisible

			if panelEligible {
				visibleGenerated.append(GeneratedExecutionProposalPanelItem(from: candidate, rankScore: score))
			} else {
				rankingSuppressedGenerated += 1
			}

			if floatingId == nil,
			   timing.allowsFloatingGenerated,
			   score >= floatingStrongScoreThreshold,
			   candidate.isGeneratedFamily
			{
				floatingId = generatedProposalActionId(for: candidate.id)
			}
		}

		if visibleStaticIds.isEmpty, !input.suppressStaticProposalFallback {
			visibleStaticIds = input.staticActionIds
		}

		let topSource = ranking.rankedActions.first?.action.sourceType
		logActivation(
			considered: candidates.filter(\.isGeneratedFamily).count,
			visibleGenerated: visibleGenerated.count,
			visibleStatic: visibleStaticIds.count,
			topSource: topSource,
			timing: timing
		)

		return GeneratedExecutionProposalActivationResult(
			visibleProposals: visibleGenerated,
			visibleStaticActionIds: visibleStaticIds,
			suppressedGeneratedCount: preSuppressedGenerated + rankingSuppressedGenerated,
			suppressedStaticCount: preSuppressedStatic,
			topSourceType: topSource,
			rankingSummary: ranking.rankingReasonSummary,
			timingDecision: timing,
			warnings: ranking.warnings,
			createdAt: referenceTime,
			floatingGeneratedProposalId: floatingId
		)
	}

	// MARK: - Pre-suppression

	private static func preSuppressReason(
		candidate: GeneratedExecutionProposalCandidate,
		input: GeneratedExecutionProposalActivationInput
	) -> String? {
		guard candidate.isGeneratedFamily else { return nil }

		if candidate.confidence < preSuppressConfidenceThreshold {
			return "low_confidence"
		}

		if input.snapshot.freshnessScore < 0.28, input.snapshot.workflowConfidence < 0.35 {
			return "low_freshness"
		}

		// Reusable / library-sourced templates work on workflow metadata — a stale clipboard is
		// irrelevant to them and must not suppress a valid library hit (T18.3.6C).
		if candidate.source != .reusableGenerated,
		   clipboardOnlyStaleContext(snapshot: input.snapshot, referenceTime: input.referenceTime)
		{
			return "stale_clipboard_only"
		}

		if !contextSatisfied(candidate: candidate, snapshot: input.snapshot) {
			return "missing_required_context"
		}

		let wf = WorkflowExecutionMapper.workflowType(from: input.snapshot.inferredWorkflow)
		if wf != .unknown,
		   candidate.workflowType != .unknown,
		   wf != candidate.workflowType,
		   candidate.confidence < 0.62
		{
			return "workflow_mismatch"
		}

		if candidate.interruptionCost > 0.72, candidate.confidence < 0.7 {
			return "high_interruption"
		}

		if let sig = candidate.primitiveSignature,
		   input.history.recentlySuppressedSignatures.contains(sig)
		{
			return "recent_suppressed_signature"
		}

		if input.history.recentlyDismissedCandidateIds.contains(candidate.id)
			|| input.history.recentlyDismissedCandidateIds.contains(generatedProposalActionId(for: candidate.id))
		{
			return "recently_dismissed"
		}

		return nil
	}

	private static func clipboardOnlyStaleContext(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> Bool {
		let hasSelection = !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		if hasSelection { return false }

		let suppression = GeneratedExecutionClipboardFreshnessPolicy.evaluate(
			snapshot: snapshot,
			referenceTime: referenceTime
		)
		let hasClipboard = !(snapshot.clipboardText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasOCR = !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

		return hasClipboard && !suppression.includeClipboard && !hasOCR
	}

	private static func contextSatisfied(
		candidate: GeneratedExecutionProposalCandidate,
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> Bool {
		let required = Set(candidate.requiredContextTypes.filter { $0 != .none })
		if required.isEmpty {
			print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=[] path=trivial passed=true")
			return true
		}

		// MARK: Reusable / library-sourced candidates (T18.3.6C)
		// The template library already verified context requirements at retrieval time using the
		// situational context (which correctly infers workflow from browser title heuristics etc.).
		// Rebuilding via GeneratedExecutionContextBridge here uses the raw canonical snapshot which
		// may have inferredWorkflow=.unknown even when the situational context resolved .browsing.
		// For reusable candidates only check hard physical constraints that absolutely require
		// live sensor data: text presence for selectedText/textSnippet, visual for fusedVisual.
		// Trust the library's retrieval decision for .workflowContext and .errorContext.
		if candidate.source == .reusableGenerated {
			var passed = true
			if required.contains(.selectedText) || required.contains(.textSnippet) {
				let hasText = !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
					|| !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				if !hasText { passed = false }
			}
			if passed, required.contains(.fusedVisual) || required.contains(.screenCapture) {
				if !snapshot.visualContextAvailability.hasUsableVisual { passed = false }
			}
			print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).sorted().joined(separator: ",")) path=reusable_trust_library passed=\(passed)")
			return passed
		}

		// MARK: LLM-generated candidates — rebuild via bridge for full context check
		if let execution = candidate.executionAction {
			let bridge = GeneratedExecutionContextBridge()
			let ctx = bridge.buildContext(from: snapshot, action: execution)
			let passed = ctx.satisfies(required: Array(required))
			let available = ctx.availableContextTypes.map(\.rawValue).sorted().joined(separator: ",")
			let missing = required.filter { !ctx.availableContextTypes.contains($0) }.map(\.rawValue).sorted().joined(separator: ",")
			print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).sorted().joined(separator: ",")) path=bridge available=\(available) missing=\(missing.isEmpty ? "none" : missing) hasText=\(ctx.hasUsableText) passed=\(passed)")
			return passed
		}

		if required.contains(.textSnippet) || required.contains(.selectedText) {
			let hasText = !(snapshot.selectedText ?? "").isEmpty
				|| !(snapshot.recentOCRExcerpt ?? "").isEmpty
			if !hasText {
				print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).sorted().joined(separator: ",")) path=simple passed=false reason=no_text")
				return false
			}
		}
		if required.contains(.fusedVisual) || required.contains(.screenCapture) {
			if !snapshot.visualContextAvailability.hasUsableVisual {
				print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).sorted().joined(separator: ",")) path=simple passed=false reason=no_visual")
				return false
			}
		}
		print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).sorted().joined(separator: ",")) path=simple passed=true")
		return true
	}

	// MARK: - Timing

	private static func evaluateTiming(
		input: GeneratedExecutionProposalActivationInput,
		ranking: UnifiedActionRankingResult,
		referenceTime: Date
	) -> GeneratedExecutionProposalTimingDecision {
		if input.isActionExecuting {
			return GeneratedExecutionProposalTimingDecision(
				outcome: .deferProposal,
				reason: "action_executing",
				allowsFloatingGenerated: false,
				allowsPanelGenerated: false
			)
		}

		if input.snapshot.packetIsStale, input.snapshot.freshnessScore < 0.25 {
			return .suppressAll
		}

		let topGenerated = ranking.rankedActions.first(where: { $0.action.isGeneratedFamily })
		let topScore = topGenerated?.components.finalScore ?? 0

		if let dismissedAt = input.history.lastDismissedAt,
		   referenceTime.timeIntervalSince(dismissedAt) < 45
		{
			return GeneratedExecutionProposalTimingDecision(
				outcome: .allowPanel,
				reason: "post_dismiss_cooldown_panel_only",
				allowsFloatingGenerated: false,
				allowsPanelGenerated: topScore >= panelMediumScoreThreshold
			)
		}

		let allowsFloating = topScore >= floatingStrongScoreThreshold
			&& input.snapshot.workflowConfidence >= 0.45
			&& !input.snapshot.packetIsStale

		let allowsPanel = topScore >= panelMediumScoreThreshold
			|| input.isManualInvocation

		// T18.3.6C: Explicit timing decision log so suppression reason is always visible.
		print("[GeneratedProposalActivation] timing_score topScore=\(String(format: "%.3f", topScore)) panel_threshold=\(panelMediumScoreThreshold) float_threshold=\(floatingStrongScoreThreshold) allows_panel=\(topScore >= panelMediumScoreThreshold) allows_float=\(allowsFloating) is_manual=\(input.isManualInvocation) wf_conf=\(String(format: "%.2f", input.snapshot.workflowConfidence)) freshness=\(String(format: "%.2f", input.snapshot.freshnessScore)) stale=\(input.snapshot.packetIsStale)")

		let outcome: GeneratedProposalTimingOutcome
		if allowsFloating {
			outcome = .allowFloating
		} else if allowsPanel {
			outcome = .allowPanel
		} else {
			outcome = .deferProposal
		}

		return GeneratedExecutionProposalTimingDecision(
			outcome: outcome,
			reason: "freshness=\(String(format: "%.2f", input.snapshot.freshnessScore))|wf=\(String(format: "%.2f", input.snapshot.workflowConfidence))",
			allowsFloatingGenerated: allowsFloating,
			allowsPanelGenerated: allowsPanel
		)
	}

	// MARK: - Static traits

	private static func staticTitle(_ actionId: String) -> String {
		switch actionId {
		case ExplainAction.explainTextId: "Explain"
		case SummarizeAction.summarizeTextId: "Summarize"
		case RewriteAction.rewriteTextId: "Rewrite"
		case ScreenAnalyzeAction.analyzeScreenId: "Analyze screen"
		default: actionId
		}
	}

	private static func staticWorkflow(_ actionId: String) -> WorkflowType {
		switch actionId {
		case ExplainAction.explainTextId, ScreenAnalyzeAction.analyzeScreenId: .debugging
		case SummarizeAction.summarizeTextId: .research
		case RewriteAction.rewriteTextId: .writing
		default: .unknown
		}
	}

	private static func staticIntent(_ actionId: String) -> IntentType {
		switch actionId {
		case ExplainAction.explainTextId, ScreenAnalyzeAction.analyzeScreenId: .explain
		case SummarizeAction.summarizeTextId: .summarize
		case RewriteAction.rewriteTextId: .structure
		default: .unknown
		}
	}

	private static func staticRequiredContext(_ actionId: String) -> [ContextRequirementType] {
		switch actionId {
		case ScreenAnalyzeAction.analyzeScreenId: [.fusedVisual, .screenCapture]
		default: [.textSnippet]
		}
	}

	// MARK: - Logging

	private static func logSuppressed(id: String, reason: String) {
		print("[GeneratedProposalActivation] generated_proposal_suppressed id=\(id.prefix(8)) reason=\(reason)")
	}

	private static func logTiming(decision: GeneratedExecutionProposalTimingDecision, allowed: Bool) {
		print(
			"[GeneratedProposalActivation] timing_decision allowed=\(allowed) outcome=\(decision.outcome.rawValue) reason=\(decision.reason)"
		)
	}

	private static func logActivation(
		considered: Int,
		visibleGenerated: Int,
		visibleStatic: Int,
		topSource: UnifiedActionSourceType?,
		timing: GeneratedExecutionProposalTimingDecision
	) {
		let ratio = visibleStatic > 0
			? String(format: "%.2f", Double(visibleGenerated) / Double(max(1, visibleGenerated + visibleStatic)))
			: "0"
		print(
			"[GeneratedProposalActivation] considered=\(considered) visible_generated=\(visibleGenerated) visible_static=\(visibleStatic) ratio=\(ratio) top=\(topSource?.rawValue ?? "none") timing=\(timing.outcome.rawValue)"
		)
	}
}
