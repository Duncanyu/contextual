import Foundation

enum ContextDebugStage: String, Sendable {
	case capability
	case source
	case budget
	case freshness
	case fusion
	case snapshot
	case visual
	case ax
	case typing
	case pointer
	case adaptive
}

enum ContextDebugEvent: String, Sendable {
	case registered
	case updated
	case collected
	case skipped
	case invalidated
	case stale
	case expired
	case allowed
	case denied
	case deferred
	case fused
	case primary_selected
	case conflict
	case selftest
	case recorded
	case decayed
}

/// Central metadata-only logger for rich context infrastructure.
/// - Never logs raw user content.
/// - Dedupes identical lines within a short window to reduce spam.
final class ContextDebugLogger {
	static let shared = ContextDebugLogger()

	private let lock = NSLock()
	private var lastBySignature: [String: Date] = [:]

	/// Dedupe window for identical log lines.
	private let throttleSeconds: TimeInterval = 1.5

	private init() {}

	func log(
		stage: ContextDebugStage,
		event: ContextDebugEvent,
		source: String? = nil,
		reason: String? = nil,
		cost: ContextCollectionCost? = nil,
		privacy: ContextPrivacySensitivity? = nil,
		latency: ContextLatencyCategory? = nil,
		permission: ContextPermissionState? = nil,
		mode: ContextCollectionMode? = nil,
		freshness: Double? = nil,
		label: ContextFreshnessLabel? = nil,
		confidence: Double? = nil,
		score: Double? = nil,
		conflict: Double? = nil,
		meta: [String: String]? = nil
	) {
		var parts: [String] = []
		parts.append("[ContextDebug]")
		parts.append("stage=\(stage.rawValue)")
		parts.append("event=\(event.rawValue)")
		if let source { parts.append("source=\(source)") }
		if let reason { parts.append("reason=\(reason)") }
		if let cost { parts.append("cost=\(cost.rawValue)") }
		if let privacy { parts.append("privacy=\(privacy.rawValue)") }
		if let latency { parts.append("latency=\(latency.rawValue)") }
		if let permission { parts.append("permission=\(permission.rawValue)") }
		if let mode { parts.append("mode=\(mode.rawValue)") }
		if let freshness { parts.append("freshness=\(fmt(freshness))") }
		if let label { parts.append("label=\(label.rawValue)") }
		if let confidence { parts.append("confidence=\(fmt(confidence))") }
		if let score { parts.append("score=\(fmt(score))") }
		if let conflict { parts.append("conflict=\(fmt(conflict))") }
		if let meta, !meta.isEmpty {
			let stable = meta.keys.sorted().map { "\($0)=\(meta[$0]!)" }.joined(separator: ",")
			parts.append("meta=\(stable)")
		}

		let line = parts.joined(separator: " ")
		if shouldSuppress(line: line) { return }
		print(line)
	}

	private func fmt(_ x: Double) -> String {
		String(format: "%.2f", x)
	}

	private func shouldSuppress(line: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let now = Date()
		if let last = lastBySignature[line], now.timeIntervalSince(last) < throttleSeconds {
			return true
		}
		lastBySignature[line] = now
		// Avoid unbounded growth.
		if lastBySignature.count > 500 {
			lastBySignature = lastBySignature.filter { now.timeIntervalSince($0.value) < 30 }
		}
		return false
	}

	// MARK: - Self-test

	func selfTest() -> Bool {
		log(stage: .capability, event: .registered, source: "selectedText", cost: .cheap, privacy: .high, freshness: 0.96, confidence: 0.80)
		log(stage: .capability, event: .updated, source: "screenOCR", reason: "availability_changed", cost: .expensive, privacy: .high)
		log(stage: .source, event: .collected, source: "activeWindowSnapshot", cost: .medium, privacy: .high, freshness: 0.92)
		log(stage: .source, event: .skipped, source: "activeWindowSnapshot", reason: "permission_denied")
		log(stage: .budget, event: .denied, source: "screenVision", reason: "enough_text_context", score: 0.20)
		log(stage: .freshness, event: .stale, source: "clipboardText", freshness: 0.22, label: .stale)
		log(stage: .fusion, event: .primary_selected, source: "selectedText", freshness: 0.96, confidence: 0.91)
		log(stage: .fusion, event: .conflict, reason: "selection_clipboard_diverge", conflict: 0.35)

		// Throttle check: identical line should be suppressed.
		log(stage: .fusion, event: .conflict, reason: "selection_clipboard_diverge", conflict: 0.35)
		log(stage: .fusion, event: .conflict, reason: "selection_clipboard_diverge", conflict: 0.35)

		log(stage: .fusion, event: .selftest, reason: "ok")
		return true
	}

	/// Freshness log helper that avoids spamming by logging only when label changes.
	private var lastFreshnessLabelBySource: [String: ContextFreshnessLabel] = [:]

	func logFreshness(source: String, score: Double) {
		let label = ContextFreshnessPolicy.decayLabel(score: score)
		lock.lock()
		let prev = lastFreshnessLabelBySource[source]
		if prev == label {
			lock.unlock()
			return
		}
		lastFreshnessLabelBySource[source] = label
		lock.unlock()

		log(stage: .freshness, event: .decayed, source: source, freshness: score, label: label)
	}
}

/// Metadata-only runtime counter for passive dogfood sessions.
/// It is intentionally fed by existing diagnostic events and never stores raw
/// content, titles, screenshots, clipboard text, or model output.
final class PassiveDogfoodMonitor {
	static let shared = PassiveDogfoodMonitor()

	private let lock = NSLock()
	private let launchedAt = Date()
	private let enabled: Bool
	private var lastSummaryAt = Date.distantPast

	private var contextsSeen = 0
	private var naturalSuggestionsShown = 0
	private var naturalSuggestionsClicked = 0
	private var naturalResultsShown = 0
	private var clickedPopupUnmapped = 0
	private var clickedPopupStale = 0
	private var clickedPopupVanished = 0
	private var resultAutoDismissed = 0
	private var resultPersisted = 0
	private var lowQualityContextBlocked = 0
	private var staleContextRejected = 0
	private var backgroundContextRejected = 0
	private var hiddenAXRejected = 0
	private var ungroundedResultsBlocked = 0
	private var cardCutoff = 0
	private var slowUIEvents = 0
	private var manualSurfaceLeaks = 0
	private var falseWorkSuggestionsInUnrelatedContext = 0
	private var opportunityContextsSeen = 0
	private var correctQuiet = 0
	private var questionableQuiet = 0
	private var failureQuiet = 0
	private var candidateGeneratedButNotShown = 0
	private var candidateSelectedButNotShown = 0
	private var surfaceBlocked = 0
	private var cooldownBlocked = 0
	private var qualityBlocked = 0
	private var permissionBlocked = 0
	private var uiBlocked = 0
	private var zeroFrameFloatingSurfaces = 0
	private var offscreenFloatingSurfaces = 0
	private var visibilityProofFailures = 0
	private var internalFailMarkers = 0
	private var activeLogPath = "unknown"
	private var actionContextNeedRuns = 0
	private var acquisitionPlans = 0
	private var axChosen = 0
	private var ocrChosen = 0
	private var browserMetadataChosen = 0
	private var publicLookupChosen = 0
	private var selectedFocusChosen = 0
	private var lowQualityAXRejected = 0
	private var obviousExtractionRejected = 0
	private var visibleRestatementRejected = 0
	private var ambientCapabilityOpportunities = 0
	private var ambientCapabilitySuppressed = 0
	private var randomAmbientPrompts = 0
	private var wrongSourceResults = 0
	private var lowUsefulnessResultsShown = 0
	private var usefulActionBackedProposals = 0
	private var blockedResults = 0
	private var genericPanelTextSuggestions = 0
	private var panelOnlyProposals = 0
	private var productVisibleProposals = 0
	private var routerBackedUsefulProposals = 0
	private var routerBypassProposals = 0
	private var routerBypassCountedUseful = 0
	private var sourceIndependentDecisions = 0
	private var contentProposalsWithoutPlan = 0
	private var resultsWithoutSourceTrace = 0
	private var usefulProposalNotCounted = 0
	// Result-intent-first spine counters (result-intent → context-need → source plan).
	private var resultIntents = 0
	private var contextNeedPlans = 0
	private var sourceSelectionPlans = 0
	private var taskFamilyPolicies = 0
	private var sourceFallbacks = 0
	private var memorySupportUsed = 0
	private var frictionOpportunities = 0
	private var frictionActionsShown = 0
	private var ambientActionsShown = 0
	private var resultIntentsByFamily: [String: Int] = [:]

	private init() {
		enabled = !ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("CONTEXTUAL_RUN_") }
	}

	func setActiveLogPath(_ path: String) {
		update { activeLogPath = path }
	}

	func noteContextSeen() { update { contextsSeen += 1 } }
	func noteNaturalSuggestionShown() { update { naturalSuggestionsShown += 1 } }
	func noteNaturalSuggestionClicked() { update(forceSummary: true) { naturalSuggestionsClicked += 1 } }
	func noteNaturalResultShown() { update { naturalResultsShown += 1 } }
	func noteClickedPopupUnmapped() { update(forceSummary: true) { clickedPopupUnmapped += 1 } }
	func noteClickedPopupStale() { update(forceSummary: true) { clickedPopupStale += 1 } }
	func noteClickedPopupVanished() { update(forceSummary: true) { clickedPopupVanished += 1 } }
	func noteResultAutoDismissed() { update(forceSummary: true) { resultAutoDismissed += 1 } }
	func noteResultPersisted() { update { resultPersisted += 1 } }
	func noteLowQualityContextBlocked() { update { lowQualityContextBlocked += 1 } }
	func noteStaleContextRejected() { update { staleContextRejected += 1 } }
	func noteBackgroundContextRejected() { update { backgroundContextRejected += 1 } }
	func noteHiddenAXRejected() { update { hiddenAXRejected += 1 } }
	func noteUngroundedResultsBlocked() { update { ungroundedResultsBlocked += 1 } }
	func noteCardCutoff() { update(forceSummary: true) { cardCutoff += 1 } }
	func noteSlowUIEvent() { update(forceSummary: true) { slowUIEvents += 1 } }
	func noteManualSurfaceLeak() { update(forceSummary: true) { manualSurfaceLeaks += 1 } }
	func noteFalseWorkSuggestionInUnrelatedContext() { update(forceSummary: true) { falseWorkSuggestionsInUnrelatedContext += 1 } }
	func noteZeroFrameFloatingSurface() { update(forceSummary: true) { zeroFrameFloatingSurfaces += 1; uiBlocked += 1 } }
	func noteOffscreenFloatingSurface() { update(forceSummary: true) { offscreenFloatingSurfaces += 1; uiBlocked += 1 } }
	func noteVisibilityProofFailure() { update(forceSummary: true) { visibilityProofFailures += 1; uiBlocked += 1 } }
	func noteInternalFailMarker() { update(forceSummary: true) { internalFailMarkers += 1 } }
	func noteActionContextNeed() { update { actionContextNeedRuns += 1 } }
	func noteAcquisitionPlan() { update { acquisitionPlans += 1 } }
	func noteContextSourceChosen(_ source: String) {
		update {
			switch sanitize(source) {
			case "ax", "browser_ax", "visible_ax", "local_visible":
				axChosen += 1
			case "ocr", "full_frame_ocr", "ocr_capture":
				ocrChosen += 1
			case "browser_metadata", "metadata":
				browserMetadataChosen += 1
			case "public_lookup", "public_web", "public_page":
				publicLookupChosen += 1
			case "selected_focus", "selected_text", "selection":
				selectedFocusChosen += 1
			default:
				break
			}
		}
	}
	func noteContextSourceRejected(_ source: String, reason: String) {
		update {
			let safeSource = sanitize(source)
			let safeReason = sanitize(reason)
			if (safeSource.contains("ax") || safeSource == "local_visible") && (safeReason.contains("hidden") || safeReason.contains("low") || safeReason.contains("metadata") || safeReason.contains("too_broad")) {
				lowQualityAXRejected += 1
			}
		}
	}
	func noteLowValueProposalRejected(reason: String) {
		update {
			switch sanitize(reason) {
			case "obvious_extraction":
				obviousExtractionRejected += 1
			case "visible_restatement":
				visibleRestatementRejected += 1
			default:
				break
			}
		}
	}
	func noteUsefulActionBackedProposal() { update { usefulActionBackedProposals += 1 } }
	func noteUsefulProposalCounted(proposalID: String, routerBacked: Bool, reason: String) {
		update {
			_ = sanitize(proposalID)
			_ = sanitize(reason)
			if routerBacked { routerBackedUsefulProposals += 1 }
			usefulActionBackedProposals += 1
		}
	}
	func noteUsefulProposalNotCounted(proposalID: String, reason: String) {
		update {
			_ = sanitize(proposalID)
			_ = sanitize(reason)
			usefulProposalNotCounted += 1
		}
	}
	func noteProductVisibleProposal(routerBacked: Bool) {
		update {
			productVisibleProposals += 1
			if !routerBacked { routerBypassProposals += 1 }
		}
	}
	func noteRouterBypassProposal() { update { routerBypassProposals += 1 } }
	func noteRouterBypassCountedUseful() { update { routerBypassCountedUseful += 1 } }
	func noteSourceIndependentDecision() { update { sourceIndependentDecisions += 1 } }
	func noteContentProposalWithoutPlan() { update { contentProposalsWithoutPlan += 1 } }
	func noteResultWithSourceTrace() { update { } }
	func noteResultWithoutSourceTrace() { update { resultsWithoutSourceTrace += 1 } }
	func noteAmbientCapabilityOpportunity(useful: Bool, random: Bool = false) {
		update {
			ambientCapabilityOpportunities += 1
			if random { randomAmbientPrompts += 1 }
		}
	}
	func noteAmbientCapabilitySuppressed() { update { ambientCapabilitySuppressed += 1 } }
	func noteResultBlocked(reason: String) {
		update {
			_ = sanitize(reason)
			blockedResults += 1
		}
	}
	func noteResultUsefulness(useful: Bool) {
		update {
			if !useful { lowUsefulnessResultsShown += 1 }
		}
	}
	func noteGenericPanelTextSuggestion() { update { genericPanelTextSuggestions += 1 } }
	func notePanelOnlyProposal() { update { panelOnlyProposals += 1 } }

	// Result-intent-first spine telemetry.
	func noteResultIntent(family: String) {
		update {
			resultIntents += 1
			resultIntentsByFamily[sanitize(family), default: 0] += 1
		}
	}
	func noteContextNeedPlan() { update { contextNeedPlans += 1 } }
	func noteSourceSelectionPlan() { update { sourceSelectionPlans += 1 } }
	func noteTaskFamilyPolicy() { update { taskFamilyPolicies += 1 } }
	func noteSourceFallback() { update { sourceFallbacks += 1 } }
	func noteMemorySupportUsed() { update { memorySupportUsed += 1 } }
	func noteFrictionOpportunity() { update { frictionOpportunities += 1 } }
	func noteFrictionActionShown() { update { frictionActionsShown += 1 } }
	func noteAmbientActionShown() { update { ambientActionsShown += 1 } }
	func noteWrongSourceResult() { update(forceSummary: true) { wrongSourceResults += 1 } }

	func recordOpportunityAudit(
		contextID: String,
		frontmostType: String,
		contentAvailable: Bool,
		evidence: String,
		contextQuality: String,
		candidatesGenerated: Int,
		candidatesAfterQuality: Int,
		candidatesAfterSurfacePolicy: Int,
		selected: String?,
		surface: String,
		quietClassification: String,
		reason: String
	) {
		guard enabled else { return }
		lock.lock()
		opportunityContextsSeen += 1
		let safeReason = sanitize(reason)
		let rawQuiet = sanitize(quietClassification)
		let precise = isPreciseProductReason(safeReason)
		let safeQuiet = (rawQuiet == "questionable_quiet" || rawQuiet == "questionable") && precise
			? "correct_quiet"
			: rawQuiet
		switch safeQuiet {
		case "correct_quiet", "correct":
			correctQuiet += 1
		case "questionable_quiet", "questionable":
			questionableQuiet += 1
		case "failure_quiet", "failure":
			failureQuiet += 1
		default:
			break
		}
		if candidatesGenerated > 0 && selected == nil && surface == "none" && !precise {
			candidateGeneratedButNotShown += 1
		}
		if selected != nil && surface == "none" && !precise {
			candidateSelectedButNotShown += 1
		}
		noteBlockerLocked(reason: safeReason)
		print("[PassiveOpportunityAudit] context_id=\(sanitize(contextID)) frontmost_type=\(sanitize(frontmostType)) content_available=\(contentAvailable ? "yes" : "no") evidence=\(sanitize(evidence)) context_quality=\(sanitize(contextQuality)) candidates_generated=\(max(0, candidatesGenerated)) candidates_after_quality=\(max(0, candidatesAfterQuality)) candidates_after_surface_policy=\(max(0, candidatesAfterSurfacePolicy)) selected=\(selected.map(sanitize) ?? "none") surface=\(sanitize(surface)) quiet_classification=\(safeQuiet) reason=\(safeReason)")
		emitOpportunitySummaryLocked(force: false)
		lock.unlock()
	}

	func emitSummary(force: Bool = false) {
		guard enabled else { return }
		lock.lock()
		emitSummaryLocked(force: force)
		lock.unlock()
	}

	private func update(forceSummary: Bool = false, _ body: () -> Void) {
		guard enabled else { return }
		lock.lock()
		body()
		emitSummaryLocked(force: forceSummary)
		lock.unlock()
	}

	private func emitSummaryLocked(force: Bool) {
		let now = Date()
		guard force || now.timeIntervalSince(lastSummaryAt) >= 30 else { return }
		lastSummaryAt = now
		let failures = clickedPopupUnmapped
			+ clickedPopupStale
			+ clickedPopupVanished
			+ resultAutoDismissed
			+ cardCutoff
			+ slowUIEvents
			+ manualSurfaceLeaks
			+ falseWorkSuggestionsInUnrelatedContext
			+ zeroFrameFloatingSurfaces
			+ offscreenFloatingSurfaces
			+ visibilityProofFailures
			+ internalFailMarkers
		let hasClickCoverage = naturalSuggestionsClicked > 0
		let status = failures == 0 && hasClickCoverage ? "pass" : "fail"
		print("[PassiveDogfoodMonitorSummary] launch=granted_app duration_s=\(Int(now.timeIntervalSince(launchedAt))) contexts_seen=\(contextsSeen) natural_suggestions_shown=\(naturalSuggestionsShown) natural_suggestions_clicked=\(naturalSuggestionsClicked) natural_results_shown=\(naturalResultsShown) clicked_popup_unmapped=\(clickedPopupUnmapped) clicked_popup_stale=\(clickedPopupStale) clicked_popup_vanished=\(clickedPopupVanished) result_auto_dismissed=\(resultAutoDismissed) result_persisted=\(resultPersisted) low_quality_context_blocked=\(lowQualityContextBlocked) stale_context_rejected=\(staleContextRejected) background_context_rejected=\(backgroundContextRejected) hidden_ax_rejected=\(hiddenAXRejected) ungrounded_results_blocked=\(ungroundedResultsBlocked) card_cutoff=\(cardCutoff) slow_ui_events=\(slowUIEvents) manual_surface_leaks=\(manualSurfaceLeaks) false_work_suggestions_in_unrelated_context=\(falseWorkSuggestionsInUnrelatedContext) correct_quiet=\(correctQuiet) questionable_quiet=\(questionableQuiet) failure_quiet=\(failureQuiet) candidate_generated_but_not_shown=\(candidateGeneratedButNotShown) candidate_selected_but_not_shown=\(candidateSelectedButNotShown) zero_frame_floating_surfaces=\(zeroFrameFloatingSurfaces) offscreen_floating_surfaces=\(offscreenFloatingSurfaces) visibility_proof_failures=\(visibilityProofFailures) internal_fail_markers=\(internalFailMarkers) status=\(status)")
		emitContextStrategySummaryLocked(now: now)
		emitOpportunitySummaryLocked(force: true)
	}

	private func emitContextStrategySummaryLocked(now: Date) {
		let sourcesChosenTotal = axChosen
			+ ocrChosen
			+ browserMetadataChosen
			+ publicLookupChosen
			+ selectedFocusChosen
		let clickedWithoutResultPath = naturalSuggestionsClicked > 0 && (naturalResultsShown + blockedResults) == 0 ? 1 : 0
		let routerFailures = routerBypassProposals
			+ routerBypassCountedUseful
			+ contentProposalsWithoutPlan
			+ resultsWithoutSourceTrace
		let failures = randomAmbientPrompts
			+ wrongSourceResults
			+ lowUsefulnessResultsShown
			+ genericPanelTextSuggestions
			+ panelOnlyProposals
			+ clickedWithoutResultPath
			+ routerFailures
		let minimumContextCoverage = 10
		let preciseQuietCoverage = opportunityContextsSeen >= minimumContextCoverage
			&& correctQuiet == opportunityContextsSeen
			&& questionableQuiet == 0
			&& failureQuiet == 0
			&& candidateGeneratedButNotShown == 0
			&& candidateSelectedButNotShown == 0

		var incompleteReasons: [String] = []
		if contextsSeen < minimumContextCoverage {
			incompleteReasons.append("insufficient_contexts")
		}
		if productVisibleProposals > 0 && actionContextNeedRuns == 0 {
			incompleteReasons.append("no_action_context_need")
		}
		if productVisibleProposals > 0 && acquisitionPlans == 0 && sourceIndependentDecisions == 0 {
			incompleteReasons.append("no_acquisition_plan")
		}
		if productVisibleProposals > 0 && sourcesChosenTotal == 0 && sourceIndependentDecisions == 0 {
			incompleteReasons.append("no_source_chosen")
		}
		if usefulActionBackedProposals > routerBackedUsefulProposals {
			incompleteReasons.append("useful_exceeds_router_backed")
		}
		if usefulActionBackedProposals == 0 && productVisibleProposals == 0 && !preciseQuietCoverage {
			incompleteReasons.append("no_useful_proposal_or_complete_quiet_proof")
		}
		if clickedWithoutResultPath > 0 {
			incompleteReasons.append("clicked_proposal_without_result_path")
		}
		if productVisibleProposals == 0 && contextsSeen >= minimumContextCoverage {
			incompleteReasons.append("no_product_visible_proposals")
		}

		let noOpPass = usefulActionBackedProposals > 0
			&& (actionContextNeedRuns == 0
				|| (acquisitionPlans == 0 && sourceIndependentDecisions == 0)
				|| (sourcesChosenTotal == 0 && sourceIndependentDecisions == 0))
		print("[NoOpDogfoodPassBlocked] status=\(noOpPass ? "fail" : "pass") count=\(noOpPass ? 1 : 0)")

		let status: String
		if failures > 0 {
			status = "fail"
		} else if incompleteReasons.isEmpty {
			status = "pass"
		} else {
			status = "incomplete"
		}

		if !incompleteReasons.isEmpty {
			let reason = incompleteReasons.map(sanitize).joined(separator: ",")
			print("[DogfoodCoverageInsufficient] reason=\(reason)")
			print("[ContextStrategyProofIncomplete] reason=\(reason)")
		}

		let incomplete = incompleteReasons.isEmpty ? "none" : incompleteReasons.map(sanitize).joined(separator: ",")
		print("[ContextStrategyDogfoodSummary] launch=granted_app duration_s=\(Int(now.timeIntervalSince(launchedAt))) contexts_seen=\(contextsSeen) status=\(status) incomplete_reasons=\(incomplete) product_visible_proposals=\(productVisibleProposals) useful_action_backed_proposals=\(usefulActionBackedProposals) action_context_need_runs=\(actionContextNeedRuns) acquisition_plans=\(acquisitionPlans) source_independent_decisions=\(sourceIndependentDecisions) sources_chosen_total=\(sourcesChosenTotal) router_bypass_proposals=\(routerBypassProposals) router_bypass_counted_useful=\(routerBypassCountedUseful) content_proposals_without_plan=\(contentProposalsWithoutPlan) results_shown=\(naturalResultsShown) results_without_source_trace=\(resultsWithoutSourceTrace) blocked_results=\(blockedResults) ax_chosen=\(axChosen) ocr_chosen=\(ocrChosen) browser_metadata_chosen=\(browserMetadataChosen) public_lookup_chosen=\(publicLookupChosen) selected_focus_chosen=\(selectedFocusChosen) low_quality_ax_rejected=\(lowQualityAXRejected) obvious_extraction_rejected=\(obviousExtractionRejected) visible_restatement_rejected=\(visibleRestatementRejected) generic_panel_text_suggestions=\(genericPanelTextSuggestions) panel_only_proposals=\(panelOnlyProposals) wrong_source_results=\(wrongSourceResults) low_usefulness_results_shown=\(lowUsefulnessResultsShown) random_ambient_prompts=\(randomAmbientPrompts) registry_churn_crashes=0")
		emitResultSourceStrategySummaryLocked(now: now, sourcesChosenTotal: sourcesChosenTotal)
	}

	/// The user-facing result-source strategy summary (Part 7). Same counters as
	/// the context-strategy summary, surfaced under the spec's exact key with the
	/// result-intent-first spine fields and a strict pass/fail gate.
	private func emitResultSourceStrategySummaryLocked(now: Date, sourcesChosenTotal: Int) {
		// Hard failures: any wrong-source result, low-usefulness result shown, or
		// a random ambient action surfaced.
		let hardFailures = wrongSourceResults + lowUsefulnessResultsShown + randomAmbientPrompts
		// A result-producing proposal that ran without the intent/need/source spine.
		let resultsShown = naturalResultsShown
		let spineGap = (resultsShown > 0 && resultIntents == 0)
			|| (resultsShown > 0 && contextNeedPlans == 0)
			|| (resultsShown > 0 && sourceSelectionPlans == 0)
		let logDiscoverable = activeLogPath != "unknown" && activeLogPath != "stdout"

		let status: String
		if hardFailures > 0 || spineGap {
			status = "fail"
		} else if contextsSeen < 10 {
			status = "incomplete"
		} else {
			status = "pass"
		}
		let familyBreakdown = resultIntentsByFamily.isEmpty
			? "none"
			: resultIntentsByFamily.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "|")
		print("[ResultSourceStrategyDogfoodSummary] launch=granted_app duration_s=\(Int(now.timeIntervalSince(launchedAt))) contexts_seen=\(contextsSeen) active_log_discoverable=\(logDiscoverable ? "yes" : "no") result_intents=\(resultIntents) context_need_plans=\(contextNeedPlans) source_selection_plans=\(sourceSelectionPlans) task_family_policies=\(taskFamilyPolicies) result_intent_families=\(familyBreakdown) ax_chosen=\(axChosen) ocr_chosen=\(ocrChosen) browser_metadata_chosen=\(browserMetadataChosen) public_lookup_chosen=\(publicLookupChosen) selected_focus_chosen=\(selectedFocusChosen) memory_support_used=\(memorySupportUsed) source_fallbacks=\(sourceFallbacks) wrong_source_results=\(wrongSourceResults) obvious_restatement_rejected=\(visibleRestatementRejected + obviousExtractionRejected) low_usefulness_results_shown=\(lowUsefulnessResultsShown) ambient_action_opportunities=\(ambientCapabilityOpportunities) ambient_actions_shown=\(ambientActionsShown) random_ambient_actions=\(randomAmbientPrompts) friction_opportunities=\(frictionOpportunities) friction_actions_shown=\(frictionActionsShown) results_without_source_trace=\(resultsWithoutSourceTrace) status=\(status)")
	}

	private func emitOpportunitySummaryLocked(force: Bool) {
		let now = Date()
		guard force || now.timeIntervalSince(lastSummaryAt) < 0.01 || opportunityContextsSeen == 1 else { return }
		let failures = failureQuiet
			+ candidateGeneratedButNotShown
			+ candidateSelectedButNotShown
			+ zeroFrameFloatingSurfaces
			+ offscreenFloatingSurfaces
			+ visibilityProofFailures
			+ internalFailMarkers
		let status = failures == 0 && questionableQuiet == 0 ? "pass" : "fail"
		print("[PassiveOpportunityStarvationSummary] contexts_seen=\(opportunityContextsSeen) correct_quiet=\(correctQuiet) questionable_quiet=\(questionableQuiet) failure_quiet=\(failureQuiet) candidate_generated_but_not_shown=\(candidateGeneratedButNotShown) candidate_selected_but_not_shown=\(candidateSelectedButNotShown) surface_blocked=\(surfaceBlocked) cooldown_blocked=\(cooldownBlocked) quality_blocked=\(qualityBlocked) permission_blocked=\(permissionBlocked) ui_blocked=\(uiBlocked) status=\(status)")
	}

	private func noteBlockerLocked(reason: String) {
		if reason.contains("permission") || reason.contains("not_authorized") {
			permissionBlocked += 1
		}
		if reason.contains("cooldown") || reason.contains("recently_shown") || reason.contains("fatigue") {
			cooldownBlocked += 1
		}
		if reason.contains("quality") || reason.contains("low_quality") || reason.contains("metadata") || reason.contains("visible_text_not_available") {
			qualityBlocked += 1
		}
		if reason.contains("surface") || reason.contains("panel") || reason.contains("floating") || reason.contains("duplicate_of_open") {
			surfaceBlocked += 1
		}
		if reason.contains("ui") || reason.contains("window") || reason.contains("render") || reason.contains("off_screen") || reason.contains("invalid_frame") || reason.contains("not_attached") {
			uiBlocked += 1
		}
	}

	private func isPreciseProductReason(_ reason: String) -> Bool {
		let exact: Set<String> = [
			"none",
			"contract_candidate_floatable",
			"contract_candidate",
			"current_focus_content_unavailable",
			"permission_missing_accessibility",
			"permission_missing_screen_recording",
			"model_unavailable",
			"startup_quiet_period",
			"arbiter_denied",
			"visible_action_suppressed_pre_render",
			"visible_action_suppressed_pre_accept",
			"similar_result_already_visible",
			"duplicate_of_open_popup_result",
			"duplicate_of_open_panel_result",
			"paused",
			"floating_already_present",
			"result_popup_present",
			"recently_shown"
		]
		if exact.contains(reason) { return true }
		let prefixes = [
			"no_actionable_content_type_",
			"visible_text_not_available_for_",
			"no_contract_for_content_type_",
			"frontmost_",
			"deferred_",
			"cooldown_",
			"quality_",
			"permission_",
			"duplicate_of_open_"
		]
		return prefixes.contains { reason.hasPrefix($0) }
	}

	private func sanitize(_ value: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.:"))
		let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
		let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
		return sanitized.isEmpty ? "none" : sanitized
	}
}
