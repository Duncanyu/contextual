import Foundation

/// Activates generated execution proposals for live UI via unified ranking (T18.3).
enum GeneratedExecutionProposalActivator {

	static let generatedProposalIdPrefix = "generated_exec:"
	static let maxPanelGeneratedVisible = 2
	/// T16.X: lowered from 0.78 → 0.58. Chime policy is now the primary floating gate.
	/// The old 0.78 wall blocked all seeded templates (confidence ≈ 0.72) from ever floating.
	static let floatingStrongScoreThreshold = 0.58
	static let panelMediumScoreThreshold = 0.52
	static let panelGeneratedScoreThreshold = 0.40
	static let preSuppressConfidenceThreshold = 0.44
	/// Minimum confidence for an executable hook-composer contract to bypass score-based
	/// panel suppression (Task 1 dogfood visibility fix).
	static let executableHookContractPanelMinConfidence: Double = 0.70

	/// Returns true when the candidate qualifies as an executable hook-composer contract
	/// eligible for panel display regardless of unified ranking score.
	/// Agentic (intent-first) proposals use a lower confidence floor because they are
	/// synthesized from a higher-level inference pass rather than validated hook chains.
	static func isExecutableHookContractOverride(_ candidate: GeneratedExecutionProposalCandidate) -> Bool {
		guard candidate.source == .hookComposer, candidate.isExecutableGeneratedProposal else { return false }
		let isAgentic = (candidate.explainabilitySummary ?? "").contains("hook_composer_agentic")
		// Agentic intent-first proposals use a lower confidence floor (0.50) since they skip
		// the full hook-chain validation pass. Legacy fixed-chain contracts keep the 0.70 floor.
		let minConf: Double = isAgentic ? 0.50 : executableHookContractPanelMinConfidence
		return candidate.confidence >= minConf
	}

	static func generatedProposalActionId(for candidateId: String) -> String {
		"\(generatedProposalIdPrefix)\(candidateId)"
	}

	static func activateProposals(
		input: GeneratedExecutionProposalActivationInput
	) -> GeneratedExecutionProposalActivationResult {
		let att = ProposalAttemptScope.currentId ?? "none"
		print("[ProposalAttempt] id=\(att) activation_started candidates=\(input.generatedExecutionCandidates.count)")

		// [ProposalActivationBridge] entry summary — shows what arrived from the mapper.
		let bridgeSourcePipeline = input.generatedExecutionCandidates.first.map {
			($0.explainabilitySummary ?? "unknown").components(separatedBy: "|").first ?? "unknown"
		} ?? "empty"
		print("[ProposalActivationBridge] activation_entry synthesized_count=\(input.generatedExecutionCandidates.count) reusable_count=\(input.reusableRecords.count) source_pipeline=\(bridgeSourcePipeline) snapshot_freshness=\(String(format: "%.2f", input.snapshot.freshnessScore)) workflow_conf=\(String(format: "%.2f", input.snapshot.workflowConfidence)) stale=\(input.snapshot.packetIsStale)")

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
				var mutExec = exec
				if let reason = checkSoftProposalAndGetSuppression(candidate: &mutExec, input: input) {
					preSuppressedGenerated += 1
					logSuppressed(id: mutExec.id, reason: reason)
					continue
				}
				candidates.append(mutExec)
			}
		} else {
			for generated in input.generatedActions where !generated.isStale {
				if let built = GeneratedExecutionProposalCandidateBuilder.build(
					from: [generated],
					snapshot: input.snapshot,
					referenceTime: referenceTime
				).first {
					var mutBuilt = built
					if let reason = checkSoftProposalAndGetSuppression(candidate: &mutBuilt, input: input) {
						preSuppressedGenerated += 1
						logSuppressed(id: mutBuilt.id, reason: reason)
						continue
					}
					candidates.append(mutBuilt)
				}
			}

			for exec in input.generatedExecutionCandidates {
				if candidates.contains(where: { $0.id == exec.id }) { continue }
				var mutExec = exec
				if let reason = checkSoftProposalAndGetSuppression(candidate: &mutExec, input: input) {
					preSuppressedGenerated += 1
					logSuppressed(id: mutExec.id, reason: reason)
					continue
				}
				candidates.append(mutExec)
			}
		}

		let reusableCandidates = GeneratedExecutionProposalCandidateBuilder.buildReusable(
			from: input.reusableRecords,
			referenceTime: referenceTime
		)

		// workflowResolution needed for promotion; compute it first using the raw reusableCandidates.
		let workflowResolution = resolveEffectiveWorkflow(input: input, reusableCandidates: reusableCandidates)
		print(
			"[GeneratedProposalActivation] reusable_candidates count=\(reusableCandidates.count) input_records=\(input.reusableRecords.count) effective_workflow=\(workflowResolution.workflow.rawValue) wf_source=\(workflowResolution.source) freshness=\(String(format: "%.2f", input.snapshot.freshnessScore)) canonical_workflow=\(input.snapshot.inferredWorkflow.rawValue) canonical_conf=\(String(format: "%.2f", input.snapshot.workflowConfidence))"
		)

		// Part A — Apply generic penalty / rich boost before ranking so richer templates win.
		let promotedReusable = applyProposalPromotion(to: reusableCandidates, effectiveWorkflow: workflowResolution.workflow)

		// [GeneratedProposalDebug] Part 1 — Per-candidate trace (verbose only).
		if ProposalLoggingFlags.verboseProposalLogsEnabled {
			for c in promotedReusable.prefix(8) {
				let prim = c.primitiveSignature ?? "?"
				print("[GeneratedProposalDebug] candidate id=\(c.id.prefix(50)) primitive=\(prim) workflow=\(c.workflowType.rawValue) title=\"\(c.title.prefix(60))\" confidence=\(String(format: "%.2f", c.confidence))")
			}
		}
		// [GeneratedProposalDebug] Part 3 — Diversity summary before pre-suppression.
		let diagUniquePrims = Set(promotedReusable.compactMap { $0.primitiveSignature }).count
		let diagUniqueTitles = Set(promotedReusable.map { $0.title }).count
		let diagUniqueWfs = Set(promotedReusable.map { $0.workflowType.rawValue }).count
		let diagPrimFreq = Dictionary(grouping: promotedReusable.compactMap { $0.primitiveSignature }, by: { $0 })
			.mapValues { $0.count }
			.sorted { $0.value > $1.value }
			.prefix(5)
			.map { "\($0.key):\($0.value)" }
			.joined(separator: ",")
		print("[GeneratedProposalDebug] diversity candidate_count=\(promotedReusable.count) unique_primitives=\(diagUniquePrims) unique_titles=\(diagUniqueTitles) unique_workflows=\(diagUniqueWfs) top_primitives=[\(diagPrimFreq)]")
		let promotedTopTitles = promotedReusable
			.sorted { $0.confidence > $1.confidence }
			.prefix(3)
			.map { "\"\($0.title.prefix(40))\"" }
			.joined(separator: ", ")
		print("[GeneratedProposalPromotion] final_top_titles=[\(promotedTopTitles)]")

		var reusablePassed = 0
		for reusable in promotedReusable {
			var mutReusable = reusable
			if let reason = checkSoftProposalAndGetSuppression(candidate: &mutReusable, input: input) {
				preSuppressedGenerated += 1
				logSuppressed(id: mutReusable.id, reason: reason)
				continue
			}
			reusablePassed += 1
			if ProposalLoggingFlags.verboseProposalLogsEnabled {
				print("[GeneratedProposalActivation] reusable_passed_presuppress id=\(String(mutReusable.id.prefix(40))) title=\(mutReusable.title)")
			}
			candidates.append(mutReusable)
		}
		let topTitles = promotedReusable
			.prefix(2)
			.map(\.title)
			.joined(separator: "|")
		print(
			"[GeneratedProposalActivation] summary reusable_total=\(promotedReusable.count) reusable_passed=\(reusablePassed) pre_suppressed_generated=\(preSuppressedGenerated) top_titles=\(topTitles)"
		)

		// [GeneratedProposalDebug] Part 2 — Fallback dominance check after pre-suppression.
		let diagFallbackPrefixes = ["Prepare a next step", "Identify what context", "Extract key signals",
		                            "Gather sparse visual", "Take a bounded", "Gather context from"]
		let diagPassedReusable = candidates.filter { $0.source == .reusableGenerated }
		let diagFallbackCount = diagPassedReusable.filter { c in diagFallbackPrefixes.contains(where: { c.title.hasPrefix($0) }) }.count
		let diagRichCount = diagPassedReusable.filter { c in !diagFallbackPrefixes.contains(where: { c.title.hasPrefix($0) }) }.count
		let diagRatio = diagPassedReusable.isEmpty ? "n/a" : String(format: "%.2f", Double(diagRichCount) / Double(diagPassedReusable.count))
		print("[GeneratedProposalDebug] fallback_dominance passed_reusable=\(diagPassedReusable.count) rich=\(diagRichCount) generic_fallback=\(diagFallbackCount) rich_ratio=\(diagRatio)")

		let rankables = candidates.map { UnifiedActionRankingAdapter.fromProposalCandidate($0) }
		let fusedStale = input.snapshot.packetIsStale
		var rankingContext = UnifiedActionRankingAdapter.context(
			workflow: input.workflow,
			session: input.session,
			fusedStale: fusedStale,
			referenceTime: referenceTime
		)
		// If the workflow inference engine is unknown/weak, prefer the effective workflow derived from
		// canonical snapshot or template-library records (T18.3.10B).
		if rankingContext.activeWorkflow == .unknown || rankingContext.workflowConfidence < 0.35 {
			rankingContext = UnifiedActionRankingContext(
				activeWorkflow: workflowResolution.workflow,
				continuityScore: rankingContext.continuityScore,
				workflowConfidence: max(rankingContext.workflowConfidence, workflowResolution.confidence),
				contextIsStale: rankingContext.contextIsStale,
				referenceTime: referenceTime,
				lowConfidenceGeneratedThreshold: rankingContext.lowConfidenceGeneratedThreshold,
				maxGeneratedRatioInTopWindow: rankingContext.maxGeneratedRatioInTopWindow,
				topWindowSize: rankingContext.topWindowSize,
				staticCompetitivenessBoost: rankingContext.staticCompetitivenessBoost
			)
		}
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

		// [GeneratedProposalDebug] Part 4a — Post-ranking score trace (verbose only).
		if ProposalLoggingFlags.verboseProposalLogsEnabled {
			for ranked in ranking.rankedActions.prefix(6) where ranked.action.isGeneratedFamily {
				let rScore = ranked.components.finalScore
				let panelOk = rScore >= panelGeneratedScoreThreshold
				let floatOk = rScore >= floatingStrongScoreThreshold
				let codes = ranked.rankingExplanationCodes.prefix(3).joined(separator: ",")
				print("[GeneratedProposalDebug] ranked_candidate id=\(ranked.action.id.prefix(40)) score=\(String(format: "%.3f", rScore)) panel=\(panelOk ? "yes" : "NO") float=\(floatOk ? "yes" : "NO") gap_to_float=\(String(format: "%.3f", floatingStrongScoreThreshold - rScore)) codes=\(codes.isEmpty ? "none" : codes)")
			}
		}

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
				floatingGeneratedProposalId: nil,
				isPolicySuppressed: false
			)
		}

		var visibleGenerated: [GeneratedExecutionProposalPanelItem] = []
		var visibleStaticIds: [String] = []
		var rankingSuppressedGenerated = 0
		var floatingId: String?

		for ranked in ranking.rankedActions {
			let action = ranked.action
			
			// Find the candidate first to check its confidence for the dogfood/debug override
			let candidate = candidates.first(where: { $0.id == action.id })
			let isHighConfidenceLLM = candidate != nil && candidate!.isGeneratedFamily && candidate!.confidence >= 0.8

			var suppressed = ranked.rankingExplanationCodes.contains("suppressed_low_confidence")
				|| ranked.rankingExplanationCodes.contains("suppressed_low_usefulness")

			if isHighConfidenceLLM {
				// Dogfooding/debug mode override: high-confidence LLM candidates bypass ranking suppression
				suppressed = false
			}

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

			guard let candidate = candidate else { continue }

			let score = ranked.components.finalScore
			var panelEligible = false
			var panelAllowedReason: String? = nil

			if candidate.isGeneratedFamily {
				let isHighConfidenceLLM = candidate.confidence >= 0.8
				let isHookContract = Self.isExecutableHookContractOverride(candidate)
				let allowsPanelGenerated = timing.allowsPanelGenerated && score >= panelGeneratedScoreThreshold

				if candidate.isSoftProposal {
					panelEligible = true
					panelAllowedReason = "passes_safety_low_confidence"
				} else if isHookContract {
					// Executable hook contracts bypass score threshold — always show in panel.
					panelEligible = true
					panelAllowedReason = "executable_hook_contract"
				} else if isHighConfidenceLLM {
					panelEligible = true
					panelAllowedReason = "llm_success_high_confidence"
				} else if candidate.isExecutableGeneratedProposal {
					// T18.3.4: Any safe, grounded, executable generated proposal should be visible in the panel.
					panelEligible = true
					panelAllowedReason = "safe_grounded_generated"
				} else if allowsPanelGenerated {
					panelEligible = true
					panelAllowedReason = "score_above_lower_threshold"
				}
			} else {
				panelEligible = timing.allowsPanelGenerated && score >= panelMediumScoreThreshold
			}

			if panelEligible && visibleGenerated.count < maxPanelGeneratedVisible {
				visibleGenerated.append(GeneratedExecutionProposalPanelItem(from: candidate, rankScore: score))
				if let reason = panelAllowedReason {
					if reason == "passes_safety_low_confidence" {
						print("[GeneratedProposalActivation] soft_visible=yes reason=passes_safety_low_confidence")
					} else {
						print("[GeneratedProposalActivation] panel_visibility_allowed reason=\(reason)")
					}
				}
			} else {
				rankingSuppressedGenerated += 1
			}

			if floatingId == nil,
			   timing.allowsFloatingGenerated,
			   score >= floatingStrongScoreThreshold,
			   candidate.isGeneratedFamily,
			   !candidate.isSoftProposal
			{
				// Phase 4U: don't float stale candidates when the context/fingerprint
				// no longer matches the candidate's grounded target anchor.
				if let anchor = candidate.executionAction?.targetAnchor,
				   let bundle = input.snapshot.bundleIdentifier {
					let currentFp = TargetWindowAnchor.fingerprint(
						bundleIdentifier: bundle,
						windowTitle: input.snapshot.windowTitle,
						workflow: candidate.workflowType
					)
					if anchor.contextFingerprint != currentFp {
						print("[GeneratedProposalActivation] dropped reason=stale_context_after_planner")
						// Keep panel eligibility unchanged; only block floating.
					} else {
						floatingId = generatedProposalActionId(for: candidate.id)
					}
				} else {
					floatingId = generatedProposalActionId(for: candidate.id)
				}
			} else if floatingId == nil, candidate.isGeneratedFamily, score < floatingStrongScoreThreshold {
				print("[GeneratedProposalActivation] floating_visibility_blocked reason=score_below_threshold")
			}
		}

		if visibleStaticIds.isEmpty, !input.suppressStaticProposalFallback {
			visibleStaticIds = input.staticActionIds
		}

		// [FloatingSuggestionDebug] Part 4c — floatingGeneratedProposalId gate result.
		// If nil despite timing.allowsFloatingGenerated=true, the 0.78 score threshold is the wall.
		let diagTopGenScore = ranking.rankedActions.first(where: { $0.action.isGeneratedFamily })?.components.finalScore ?? 0
		if let fid = floatingId {
			print("[FloatingSuggestionDebug] floating_id_set id=\(fid.prefix(50)) top_gen_score=\(String(format: "%.3f", diagTopGenScore))")
		} else if timing.allowsFloatingGenerated {
			print("[FloatingSuggestionDebug] floating_id_nil timing=allows top_gen_score=\(String(format: "%.3f", diagTopGenScore)) threshold=\(floatingStrongScoreThreshold) reason=score_below_float_threshold")
		} else {
			print("[FloatingSuggestionDebug] floating_id_nil timing=blocks top_gen_score=\(String(format: "%.3f", diagTopGenScore)) timing_outcome=\(timing.outcome.rawValue)")
		}

		let topSource = ranking.rankedActions.first?.action.sourceType
		let hasFastShell = candidates.contains(where: { $0.id.hasPrefix("fast_shell:") })
		logActivation(
			considered: candidates.filter(\.isGeneratedFamily).count,
			visibleGenerated: visibleGenerated.count,
			visibleStatic: visibleStaticIds.count,
			topSource: topSource,
			timing: timing,
			isFastShell: hasFastShell
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
			floatingGeneratedProposalId: floatingId,
			isPolicySuppressed: false
		)
	}

	private struct EffectiveWorkflowResolution {
		let workflow: WorkflowType
		let confidence: Double
		let source: String
	}

	private static func resolveEffectiveWorkflow(
		input: GeneratedExecutionProposalActivationInput,
		reusableCandidates: [GeneratedExecutionProposalCandidate]
	) -> EffectiveWorkflowResolution {
		// 1) Workflow engine (if available)
		if let wf = input.workflow {
			let mapped = WorkflowExecutionMapper.workflowType(from: wf.workflow)
			if mapped != .unknown, wf.confidence >= 0.35 {
				return EffectiveWorkflowResolution(
					workflow: mapped,
					confidence: wf.confidence,
					source: "workflow_engine"
				)
			}
		}

		// 2) Canonical snapshot
		let snapMapped = WorkflowExecutionMapper.workflowType(from: input.snapshot.inferredWorkflow)
		if snapMapped != .unknown, input.snapshot.workflowConfidence >= 0.35 {
			return EffectiveWorkflowResolution(
				workflow: snapMapped,
				confidence: input.snapshot.workflowConfidence,
				source: "canonical"
			)
		}

		// 3) Template-library records (reusable candidates)
		if let best = reusableCandidates
			.filter({ $0.workflowType != .unknown })
			.max(by: { $0.confidence < $1.confidence })
		{
			return EffectiveWorkflowResolution(
				workflow: best.workflowType,
				confidence: max(0.42, min(0.75, best.confidence)),
				source: "template_library"
			)
		}

		return EffectiveWorkflowResolution(workflow: .unknown, confidence: 0, source: "fallback")
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

		// Reusable/library and hook-composer candidates don't depend on clipboard freshness.
		// Hook-composer actions gather context at execution time — stale clipboard is irrelevant.
		if candidate.source != .reusableGenerated, candidate.source != .hookComposer,
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

	private static func checkSoftProposalAndGetSuppression(
		candidate: inout GeneratedExecutionProposalCandidate,
		input: GeneratedExecutionProposalActivationInput
	) -> String? {
		let required = Set(candidate.requiredContextTypes.filter { $0 != .none })
		if required.contains(.screenCapture) || required.contains(.fusedVisual) {
			let hasOCR = !(input.snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			let hasVisual = input.snapshot.visualContextAvailability.hasUsableVisual
			if hasOCR || hasVisual {
				candidate.isSoftProposal = true
				if !candidate.softReasons.contains("missing_visual_descriptor") {
					candidate.softReasons.append("missing_visual_descriptor")
				}
			}
		}

		if candidate.isSoftProposal {
			// Soft proposals bypass normal pre-suppressions, only blocked by dismissed history
			if input.history.recentlyDismissedCandidateIds.contains(candidate.id)
				|| input.history.recentlyDismissedCandidateIds.contains(generatedProposalActionId(for: candidate.id))
			{
				return "recently_dismissed"
			}
			return nil
		}

		return preSuppressReason(candidate: candidate, input: input)
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

		return hasClipboard && !suppression.includeClipboard
	}

	private static func truthfulContextSource(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		strictSelectionNotRequired: Bool
	) -> String {
		var sources: [String] = []
		let hasSelection = !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasOCR = !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasTitle = !snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasVisual = snapshot.visualContextAvailability.hasUsableVisual

		if hasSelection {
			sources.append("selection")
		}
		if hasOCR {
			sources.append("ocr")
		}
		if hasTitle {
			sources.append("title")
		}
		if hasVisual {
			sources.append("visual")
		}

		if sources.isEmpty {
			return "metadata"
		} else {
			return sources.joined(separator: "/")
		}
	}

	private static func requiresStrictSelection(_ title: String) -> Bool {
		let lower = title.lowercased()
		return lower.contains("selected") || lower.contains("selection") || lower.contains("highlighted")
	}

	private static func contextSatisfied(
		candidate: GeneratedExecutionProposalCandidate,
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> Bool {
		let required = Set(candidate.requiredContextTypes.filter { $0 != .none })
		if required.isEmpty {
			if ProposalLoggingFlags.verboseProposalLogsEnabled {
				print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=[] path=trivial passed=true")
			}
			return true
		}

		// Helper to check if strict selection is NOT required
		let strictSelectionNotRequired = !requiresStrictSelection(candidate.title)
		
		// Context availability checks
		let hasTitle = !snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasOCR = !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasVisual = snapshot.visualContextAvailability.hasUsableVisual
		let hasSomeContext = hasTitle || hasOCR || hasVisual

		let performCheck: () -> Bool = {
			// MARK: Reusable / library-sourced candidates (T18.3.6C)
			if candidate.source == .reusableGenerated || candidate.source == .hookComposer {
				let pathLabel = candidate.source == .hookComposer ? "hook_composer_lenient" : "reusable_trust_library"
				var passed = true
				if required.contains(.selectedText) || required.contains(.textSnippet) {
					let hasText = !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
						|| !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
					if !hasText {
						if strictSelectionNotRequired && hasSomeContext {
							passed = true
						} else {
							passed = false
						}
					}
				}
				if passed, required.contains(.fusedVisual) || required.contains(.screenCapture) {
					if snapshot.visualContextAvailability.hasUsableVisual {
						// ok
					} else if candidate.source == .hookComposer,
							  let plan = candidate.executionAction?.executionPlan,
							  (plan.requiresVision || plan.requiresOCR)
					{
						let screenAllowed = snapshot.permissionAvailability[.screenRecording] != false
						if !screenAllowed { passed = false }
					} else {
						passed = false
					}
				}
				if ProposalLoggingFlags.verboseProposalLogsEnabled {
					print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).sorted().joined(separator: ",")) path=\(pathLabel) passed=\(passed)")
				} else if candidate.source == .hookComposer {
					let req = required.map(\.rawValue).sorted().joined(separator: ",")
					let reason = passed ? "context_can_be_gathered" : "missing_required_context"
					print("[GeneratedProposalActivation] hook_candidate_\(passed ? "allowed" : "suppressed") reason=\(reason) id=\(String(candidate.id.prefix(60))) required=\(req)")
				}
				return passed
			}

			// MARK: LLM-generated candidates — rebuild via bridge for full context check
			if let execution = candidate.executionAction {
				let bridge = GeneratedExecutionContextBridge()
				let ctx = bridge.buildContext(from: snapshot, action: execution)
				var passed = ctx.satisfies(required: Array(required))
				if !passed && (required.contains(.textSnippet) || required.contains(.selectedText)) {
					let hasText = !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
						|| !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
					if !hasText && strictSelectionNotRequired && hasSomeContext {
						passed = true
					}
				}
				let available = ctx.availableContextTypes.map(\.rawValue).sorted().joined(separator: ",")
				let missing = required.filter { !ctx.availableContextTypes.contains($0) }.map(\.rawValue).sorted().joined(separator: ",")
				if ProposalLoggingFlags.verboseProposalLogsEnabled {
					print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).sorted().joined(separator: ",")) path=bridge available=\(available) missing=\(missing.isEmpty ? "none" : missing) hasText=\(ctx.hasUsableText) passed=\(passed)")
				}
				return passed
			}

			if required.contains(.textSnippet) || required.contains(.selectedText) {
				let hasText = !(snapshot.selectedText ?? "").isEmpty
					|| !(snapshot.recentOCRExcerpt ?? "").isEmpty
				if !hasText {
					if strictSelectionNotRequired && hasSomeContext {
						// passed
					} else {
						if ProposalLoggingFlags.verboseProposalLogsEnabled {
							print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).joined(separator: ",")) path=simple passed=false reason=no_text")
						}
						return false
					}
				}
			}
			if required.contains(.fusedVisual) || required.contains(.screenCapture) {
				if !snapshot.visualContextAvailability.hasUsableVisual {
					if ProposalLoggingFlags.verboseProposalLogsEnabled {
						print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).joined(separator: ",")) path=simple passed=false reason=no_visual")
					}
					return false
				}
			}
			if ProposalLoggingFlags.verboseProposalLogsEnabled {
				print("[GeneratedProposalActivation] context_validation template=\(String(candidate.id.prefix(40))) required=\(required.map(\.rawValue).joined(separator: ",")) path=simple passed=true")
			}
			return true
		}

		let passed = performCheck()
		if passed {
			let src = truthfulContextSource(snapshot: snapshot, strictSelectionNotRequired: strictSelectionNotRequired)
			print("[GeneratedProposalActivation] context_requirement=passed source=\(src)")
		}
		return passed
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
				allowsPanelGenerated: topScore >= panelGeneratedScoreThreshold
			)
		}

		// Float requires: score above threshold + non-stale context.
		// workflowConfidence floor is relaxed (0.35) when earlier surfacing is active —
		// the agentic runtime can operate on browser context without strong workflow inference.
		let wfConfFloor: Double = AgenticPivot.useEarlierProposalSurfacing ? 0.35 : 0.45

		// Bypass panel score threshold for executable hook-composer contracts.
		// Uses a 0.50 floor (lower than the per-candidate 0.70) because the timing check
		// runs before per-candidate mode inspection. The candidate-level isExecutableHookContractOverride
		// applies the correct floor (0.70 for legacy chains, 0.50 for agentic intent-first).
		// Here we just need to know "is there at least one hookComposer candidate worth showing".
		let hasExecutableHookContract = ranking.rankedActions.contains {
			$0.action.metadata["proposalSource"] == GeneratedExecutionProposalSource.hookComposer.rawValue
			&& $0.action.metadata["executable"] == "1"
			&& $0.action.confidence >= 0.50
		}

		let isActionWorthy = FastVisibilityQualityGate.isActionWorthy(title: input.snapshot.windowTitle, appName: input.snapshot.activeApp)
		let hasStrongOCR = (input.snapshot.recentOCRExcerpt?.count ?? 0) >= 100
		var proposalRecoveryModeActive = isActionWorthy && hasStrongOCR
		if proposalRecoveryModeActive {
			let isStrong = RouterGroundingHeuristic.isStrongActionablePageContext(
				title: input.snapshot.windowTitle,
				appName: input.snapshot.activeApp,
				ocrExcerpt: input.snapshot.recentOCRExcerpt
			)
			if !isStrong {
				proposalRecoveryModeActive = false
				print("[ProposalRecoveryMode] active=no reason=weak_or_mixed_browser_context")
			}
		}

		let activePanelThreshold = proposalRecoveryModeActive ? panelGeneratedScoreThreshold * 0.5 : panelGeneratedScoreThreshold
		let activeFloatingThreshold = proposalRecoveryModeActive ? floatingStrongScoreThreshold * 0.5 : floatingStrongScoreThreshold

		// Wait for the panel timer
		let allowsPanel = topScore >= activePanelThreshold
			|| input.isManualInvocation
			|| hasExecutableHookContract

		// [FloatingSuggestionDebug] Part 4b — Float gate: shows score vs threshold and blocking condition.
		// If passes=NO and gap_to_threshold is small, the 0.78 floor is the blocker.
		let floatGapStr = String(format: "%.3f", activeFloatingThreshold - topScore)
		let floatBlockReason: String = {
			if topScore < activeFloatingThreshold { return "score_below_\(activeFloatingThreshold)" }
			if input.snapshot.workflowConfidence < wfConfFloor { return "wf_conf_\(String(format: "%.2f", input.snapshot.workflowConfidence))_below_\(wfConfFloor)" }
			if input.snapshot.packetIsStale { return "packet_stale" }
			return "none"
		}()
		let allowsFloating = topScore >= activeFloatingThreshold && floatBlockReason == "none"

		print("[FloatingSuggestionDebug] float_gate top_score=\(String(format: "%.3f", topScore)) threshold=\(activeFloatingThreshold) gap=\(floatGapStr) passes=\(allowsFloating) block_reason=\(floatBlockReason) recovery_mode=\(proposalRecoveryModeActive)")

		// T18.3.6C: Explicit timing decision log so suppression reason is always visible.
		print("[GeneratedProposalActivation] timing_score topScore=\(String(format: "%.3f", topScore)) panel_threshold=\(activePanelThreshold) float_threshold=\(activeFloatingThreshold) allows_panel=\(allowsPanel) allows_float=\(allowsFloating) is_manual=\(input.isManualInvocation) wf_conf=\(String(format: "%.2f", input.snapshot.workflowConfidence)) freshness=\(String(format: "%.2f", input.snapshot.freshnessScore)) stale=\(input.snapshot.packetIsStale)")

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

	// MARK: - Proposal promotion (Part A)

	/// Applies score adjustments so rich, workflow-specific proposals outrank generic fallbacks.
	///
	/// Rules:
	/// - `.unknown` workflow → penalty (generic catch-all template)
	/// - Specific title pattern known to be generic → additional penalty
	/// - Workflow matches effective workflow → boost
	///
	/// Adjustments are applied to `confidence` which flows through to `UnifiedActionRankingAdapter`.
	private static func applyProposalPromotion(
		to candidates: [GeneratedExecutionProposalCandidate],
		effectiveWorkflow: WorkflowType
	) -> [GeneratedExecutionProposalCandidate] {
		// Titles that are known generic last-resort patterns regardless of workflow.
		let extraGenericPrefixes: [String] = [
			"Classify the current workflow",
			"Identify what context is needed",
			"Take a bounded visual peek",
		]
		return candidates.map { c in
			let isUnknownWorkflow = c.workflowType == .unknown
			let isExtraGeneric = extraGenericPrefixes.contains(where: { c.title.hasPrefix($0) })
			let isWorkflowAligned = effectiveWorkflow != .unknown
				&& c.workflowType == effectiveWorkflow
				&& c.workflowType != .unknown

			var delta: Double = 0
			var reason = ""

			if isUnknownWorkflow {
				delta -= 0.10
				reason = "unknown_workflow"
			}
			if isExtraGeneric {
				delta -= 0.06   // cumulative with unknown_workflow penalty
				reason = reason.isEmpty ? "generic_title" : "\(reason)+generic_title"
			}
			if isWorkflowAligned, delta == 0 {
				delta += 0.06
				reason = "workflow_aligned"
			}

			guard delta != 0 else { return c }

			let newConf = min(1.0, max(0, c.confidence + delta))
			if delta < 0 {
				print("[GeneratedProposalPromotion] generic_penalty id=\(c.id.prefix(40)) title=\"\(c.title.prefix(50))\" reason=\(reason) delta=\(String(format: "%.2f", delta))")
			} else {
				print("[GeneratedProposalPromotion] rich_boost id=\(c.id.prefix(40)) title=\"\(c.title.prefix(50))\" reason=\(reason) delta=+\(String(format: "%.2f", delta))")
			}
			return GeneratedExecutionProposalCandidate(
				id: c.id,
				title: c.title,
				description: c.description,
				source: c.source,
				workflowType: c.workflowType,
				intentType: c.intentType,
				confidence: newConf,
				interruptionCost: c.interruptionCost,
				explainabilitySummary: c.explainabilitySummary,
				expectedOutputSummary: c.expectedOutputSummary,
				requiredContextTypes: c.requiredContextTypes,
				executionAction: c.executionAction,
				generatedActionId: c.generatedActionId,
				primitiveSignature: c.primitiveSignature,
				isExecutableGeneratedProposal: c.isExecutableGeneratedProposal
			)
		}
	}

	// MARK: - Logging

	private static func logSuppressed(id: String, reason: String) {
		print("[GeneratedProposalActivation] generated_proposal_suppressed id=\(id.prefix(8)) reason=\(reason)")
		print("[ProposalActivationBridge] pre_suppress_drop proposal_id=\(id.prefix(60)) suppression_reason=\(reason)")
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
		timing: GeneratedExecutionProposalTimingDecision,
		isFastShell: Bool = false
	) {
		let ratio = visibleStatic > 0
			? String(format: "%.2f", Double(visibleGenerated) / Double(max(1, visibleGenerated + visibleStatic)))
			: "0"
		print(
			"[GeneratedProposalActivation] considered=\(considered) visible_generated=\(visibleGenerated) visible_static=\(visibleStatic) ratio=\(ratio) top=\(topSource?.rawValue ?? "none") timing=\(timing.outcome.rawValue)"
		)
		let sourceLabel = isFastShell && visibleGenerated > 0 ? " source=fast_shell" : ""
		print("[GeneratedProposalActivation] visible_generated=\(visibleGenerated)\(sourceLabel)")
		// [ProposalActivationBridge] final outcome — single authoritative line for pipeline tracing.
		let suppressionReason: String = {
			if visibleGenerated > 0 { return "none" }
			if timing.outcome == .suppressAll { return "timing_suppress_all" }
			if timing.outcome == .deferProposal { return "timing_defer" }
			if considered == 0 { return "no_candidates_reached_activator" }
			return "ranking_or_score_suppressed"
		}()
		print("[ProposalActivationBridge] activation_complete activation_candidate_count=\(considered) visible_generated=\(visibleGenerated) suppression_reason=\(suppressionReason) timing_outcome=\(timing.outcome.rawValue) allows_panel=\(timing.allowsPanelGenerated) allows_float=\(timing.allowsFloatingGenerated)")
	}
}
