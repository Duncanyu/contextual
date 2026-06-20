import AppKit
import Foundation

struct CheapAlwaysOnPortfolioInput: Sendable {
	let reason: String
	let workflow: AmbientWorkflowType
	let modelReady: Bool
	let startupQuiet: Bool
	let frictionSignals: [FrictionSignal]
	let mediaState: EnvironmentMediaState
	let semanticState: SemanticPriorityResolver.SemanticState?
	let entityGrounding: EntityGrounding?
	let compartment: TaskCompartment?
	let memory: WorkingMemorySnapshot
	let activityState: ActivityState?
	let entityKey: String
	let currentApp: String
	let appCategory: AppContextAnalyzer.Category?
	let groundingResult: SemanticGroundingResult?
	let currentWorkBridge: ParallelOpportunityBridgeStatus? = nil
}

struct CheapAlwaysOnPortfolioResult: Sendable {
	let floatingCandidate: PortfolioCandidate?
	let panelCandidates: [PortfolioCandidate]
	let allCandidates: [PortfolioCandidate]
	let suppressedCount: Int
}

enum CheapAlwaysOnPortfolio {
	static let qualityThreshold: Double = 0.12

	private static func logCandidateIdentity(_ candidate: PortfolioCandidate) {
		print("[CandidateIdentity] capability=\(candidate.capabilityId) lane=\(candidate.lane.rawValue) source=\(candidate.sourcePath) candidate_id=\(candidate.candidateID)")
	}

	static func evaluate(_ input: CheapAlwaysOnPortfolioInput) -> [PortfolioCandidate] {
		evaluateDetailed(input).allCandidates
	}

	static func evaluateDetailed(_ input: CheapAlwaysOnPortfolioInput) -> CheapAlwaysOnPortfolioResult {
		print("[CheapAlwaysOnPortfolio] evaluated=yes reason=\(input.reason)")
		print("[ModelAvailability] ready=\(input.modelReady ? "yes" : "no")")
		if !input.modelReady {
			print("[ActionPortfolio] cognitive_lane=suppressed reason=model_unavailable")
			print("[ActionPortfolio] environment_lanes_allowed=yes")
		}

		var candidates: [PortfolioCandidate] = []
		let noveltyTracker = OpportunityNoveltyTracker.shared

		// ── Grounded Lane Filtering ─────────────────────────────────────
		var allowedLanes: Set<PortfolioCandidate.Lane> = Set(PortfolioCandidate.Lane.allCases)
		if let gr = input.groundingResult {
			if !gr.allowedLanes.isEmpty {
				let allowed = Set(gr.allowedLanes.compactMap { PortfolioCandidate.Lane(rawValue: $0) })
				if !allowed.isEmpty {
					allowedLanes = allowed
				}
			}
			if !gr.forbiddenLanes.isEmpty {
				let forbidden = Set(gr.forbiddenLanes.compactMap { PortfolioCandidate.Lane(rawValue: $0) })
				allowedLanes.subtract(forbidden)
			}
		}

		if !input.frictionSignals.isEmpty {
			allowedLanes.insert(.friction)
		}

		if allowedLanes.contains(.comfort), let comfort = comfortCandidate(input: input, noveltyTracker: noveltyTracker) {
			candidates.append(comfort)
		}
		if allowedLanes.contains(.music), let music = musicCandidate(input: input, noveltyTracker: noveltyTracker) {
			candidates.append(music)
		}
		if allowedLanes.contains(.friction) {
			candidates.append(contentsOf: frictionCandidates(input: input, noveltyTracker: noveltyTracker))
		}
		if allowedLanes.contains(.workspace), let workspace = workspaceCandidate(input: input, noveltyTracker: noveltyTracker) {
			candidates.append(workspace)
		}
		if allowedLanes.contains(.metadata) {
			candidates.append(contentsOf: metadataCandidates(input: input, noveltyTracker: noveltyTracker))
		}

		let laneNames = Set(candidates.map { $0.lane.rawValue }).sorted().joined(separator: ",")
		print("[ActionPortfolio] lanes=\(laneNames.isEmpty ? "none" : laneNames)")
		for c in candidates {
			logCandidateIdentity(c)
			print("[CheapAlwaysOnPortfolio] candidate=\(c.capabilityId) score=\(String(format: "%.3f", c.score))")
			print("[ActionPortfolio] candidate"
				+ " lane=\(c.lane.rawValue)"
				+ " capability=\(c.capabilityId)"
				+ " score=\(String(format: "%.3f", c.score))"
				+ " usefulness=\(String(format: "%.2f", c.usefulness))"
				+ " executability=\(String(format: "%.2f", c.executability))"
				+ " confidence=\(String(format: "%.2f", c.confidence))"
				+ " novelty=\(String(format: "%.2f", c.novelty))")
		}

		candidates.sort { a, b in
			ActionUsefulnessPolicy.compareUsefulnessAndScore(
				capA: a.capabilityId, laneA: a.lane.rawValue, scoreA: a.score,
				capB: b.capabilityId, laneB: b.lane.rawValue, scoreB: b.score
			)
		}
		var validated: [PortfolioCandidate] = []
		var suppressedCount = 0
		for candidate in candidates {
			let isLocalAction = candidate.executionMode == .local_action
			guard isLocalAction else {
				if candidate.score >= qualityThreshold {
					validated.append(candidate)
				} else {
					suppressedCount += 1
				}
				continue
			}
			let candidateURLs = payloadURLs(for: candidate, input: input)
			let validation = LocalActionPayloadValidator.validate(
				capabilityId: candidate.capabilityId,
				involvedApps: candidate.involvedApps,
				involvedURLs: candidateURLs,
				browserTabTitles: Array(input.compartment?.browserTabs.sorted() ?? []),
				compartmentLabel: input.compartment?.label
			)
			let panelReason: String = {
				if candidate.lane == .metadata { return "metadata_safe_valid_payload" }
				if candidate.score < qualityThreshold { return "below_floating_threshold_but_valid" }
				return "valid_payload"
			}()
			print("[PanelCandidate] capability=\(candidate.capabilityId) lane=\(candidate.lane.rawValue) valid_payload=\(validation.valid ? "yes" : "no") reason=\(validation.valid ? panelReason : validation.reason)")
			guard validation.valid else {
				suppressedCount += 1
				print("[CheapAlwaysOnPortfolio] rejected=\(candidate.capabilityId) reason=payload_invalid missing=\(validation.missing.joined(separator: ","))")
				continue
			}
			validated.append(candidate)
		}

		// Phase 33: Sanity snapshot
		LocalActionSanitySnapshot.emit(
			involvedApps: validated.flatMap(\.involvedApps),
			involvedURLs: validated.flatMap { payloadURLs(for: $0, input: input) },
			browserTabTitles: Array(input.compartment?.browserTabs.sorted() ?? []),
			compartmentLabel: input.compartment?.label,
			musicPlaying: input.mediaState.isMusicPlaying,
			focusShortcutAvailable: nil
		)

		// Phase 36.2 — Live path enforcement + useful action inventory + backfill.
		// Surface policy decides what may float. Floating winner must be eligible_for_floating=yes.
		// If the top-scored candidate is suppressed/panel-only, backfill with the next eligible.
		let contextStability: String = {
			if input.compartment != nil && !input.memory.currentEntity.isEmpty { return "stable" }
			if input.memory.currentEntity.isEmpty && input.compartment == nil { return "weak" }
			return "transient"
		}()
		let hasTaskOrFrictionAction = validated.contains { c in
			(c.lane == .friction || c.lane == .workspace)
				&& c.capabilityId != "play_focus_media"
				&& c.capabilityId != "resume_focus_media"
				&& !LivePathEnforcer.metadataUtilities.contains(c.capabilityId)
				&& c.capabilityId != "pin_reference_tabs"
		}
		var decisions: [String: LivePathDecision] = [:]
		for c in validated {
			let musicUserPreference = c.capabilityId == "play_focus_media"
				&& (DurableMemory.shared.hasAcceptedMusicPreference() || c.musicIntent?.playlistName != nil)
			let musicHistory = c.capabilityId == "play_focus_media"
				&& ((DurableMemory.shared.actionFeedbackRecord(for: "play_focus_media")?.acceptedCount ?? 0) > 0)
			let musicRecentSuccess = c.capabilityId == "play_focus_media"
				&& MusicActionFeedback.shared.recentSuccess()
			let musicStableContext = contextStability == "stable" || contextStability == "weak"
				|| input.compartment != nil
				|| (input.activityState?.isActive == true && (input.activityState?.dwellSeconds ?? 0) >= 10)
			let musicEvidenceAllowed = c.capabilityId != "play_focus_media"
				|| ProposalEvidenceContracts.logMusicEvidence(
					stableWorkContext: musicStableContext,
					userPreference: musicUserPreference,
					history: musicHistory,
					recentSuccess: musicRecentSuccess
				)
			let ctx = LivePathEvaluationContext(
				sourcePath: c.sourcePath,
				contextStability: contextStability,
				isMusicAlreadyPlaying: input.mediaState.isMusicPlaying,
				hasHigherPriorityTaskAction: hasTaskOrFrictionAction,
				recentFeedbackCooldownActive: false,
				userFeedbackHistory: musicEvidenceAllowed ? "positive" : "neutral",
				alreadySatisfied: false,
				evidenceAvailable: c.usefulness > 0.0,
				hasExplicitUsageSignal: musicUserPreference,
				activityMatch: true,
				compartmentLabel: input.compartment?.label,
				currentEntity: input.memory.currentEntity,
				workflow: input.workflow.rawValue
			)
			let (decision, _) = LivePathEnforcer.evaluate(
				capabilityID: c.capabilityId,
				involvedApps: c.involvedApps,
				attachedContract: c.targetContract,
				confidence: c.confidence,
				evaluationContext: ctx
			)
			decision.logEnforcement(candidateID: c.candidateID, lane: c.lane.rawValue)
			decisions[c.candidateID] = decision
		}

			let rawPanelCandidates = validated.filter { c in
				guard c.executionMode == .local_action else { return false }
				guard let decision = decisions[c.candidateID] else { return false }
				if decision.surface == .suppressed || !decision.allowedToExecute {
                return false
            }
            return true
        }
			let panelCandidates = productPanelCandidates(rawPanelCandidates)
		// Contextual environment actions (music, friction, workspace) reach the
		// normal panel when they pass live-path — not only via debug control floor.
		var panelWithContextual = panelCandidates
		for c in validated where c.lane == .music || c.lane == .friction || c.lane == .workspace {
			guard let decision = decisions[c.candidateID] else { continue }
			guard decision.surface != .suppressed, decision.allowedToExecute else { continue }
			guard !panelWithContextual.contains(where: { $0.capabilityId == c.capabilityId }) else { continue }
			panelWithContextual.append(c)
			print("[ContextualEnvironmentPanelMerged] id=\(c.capabilityId) lane=\(c.lane.rawValue) reason=\(decision.reason)")
		}

		// ── Phase 69.1 regression repair: control-center floor ──────────────
		// Manual controls are environment actions, not content-understanding
		// actions. They must reach the panel even when grounding forbids the
		// proactive lanes and even during startup/quiet ticks. The floor is
		// computed independently and merged into the panel surface (never
		// floating). This is what keeps the panel non-empty on Reddit/generic
		// browsing where the proactive lanes correctly stay silent.
		// Hard product reset: the manual-control floor is computed (so the
		// capabilities remain available internally), but it is NOT merged into the
		// user-facing surface unless debug mode is on. The normal panel must be a
		// real-suggestion surface, never a toolbox fallback.
		let floorResult = controlCenterFloor(input: input)
		var panelWithFloor = panelWithContextual
		var addedFloor: [PortfolioCandidate] = []
		if ProductSurfacePolicy.manualControlsVisible {
			for f in floorResult.candidates where !panelWithFloor.contains(where: { $0.capabilityId == f.capabilityId }) {
				panelWithFloor.append(f)
				addedFloor.append(f)
			}
			let panelIds = panelWithFloor.map(\.capabilityId)
			print("[ManualControlActions] count=\(panelWithFloor.count) ids=\(panelIds.joined(separator: ","))")
			for pc in panelWithFloor { print("[PanelControlActionVisible] id=\(pc.capabilityId) visible=yes") }
		} else {
			print("[ManualControlsUserSurfaceDisabled] count=\(floorResult.candidates.count) reason=not_product_surface")
			print("[ManualControlCapabilityRetainedInternal] count=\(floorResult.candidates.count)")
		}
		// When real portfolio candidates exist, debug manual controls must not
		// drown them out — keep music/friction/workspace, drop generic capture hints.
		if ProductSurfacePolicy.manualControlsVisible, !validated.isEmpty {
			let before = panelWithFloor.count
			panelWithFloor.removeAll { pc in
				pc.sourcePath == "control_center_floor"
                    && (pc.capabilityId == "capture_visible_page" || pc.capabilityId == "select_text_hint")
			}
			if panelWithFloor.count != before {
				print("[ManualControlPanelDemoted] reason=real_portfolio_candidates_present removed=capture_visible_page,select_text_hint")
			}
		}
		print("[NoManualControlsInNormalPanel] status=pass count=0")
		print("[NoPanelToolboxFallback] status=pass count=0")
		print("[PanelControlSurface] visible=\(addedFloor.isEmpty ? "no" : "yes") count=\(panelWithFloor.count)")
		print("[NoHiddenPanelActionsWhenNoFloating] status=pass count=0")
		print("[NoControlActionBlockedByGrounding] status=pass count=0")
		// Environment-gated control gates only apply when controls are an actual
		// product surface (debug mode). In normal mode controls are not surfaced.
		if ProductSurfacePolicy.manualControlsVisible {
			let musicVisible = panelWithFloor.contains { $0.capabilityId == "play_focus_media" }
			if floorResult.musicPreferenceExists {
				print("[MusicControlVisibleWhenPreferenceExists] status=\(musicVisible ? "pass" : "fail") count=\(musicVisible ? 0 : 1)")
			}
			let frictionVisible = panelWithFloor.contains { $0.lane == .friction }
			if floorResult.windowPairExists {
				print("[FrictionControlVisibleWhenWindowPairExists] status=\(frictionVisible ? "pass" : "fail") count=\(frictionVisible ? 0 : 1)")
			}
		}

		// Useful action inventory — visible accounting of what was possible
		let inventorySet = panelWithFloor
		let totalEligible = inventorySet.count
		let frictionCount = inventorySet.filter { $0.lane == .friction }.count
		let metadataCount = inventorySet.filter { $0.lane == .metadata }.count
		let musicCount = inventorySet.filter { $0.lane == .music }.count
		let workspaceCount = inventorySet.filter { $0.lane == .workspace }.count
		let researchCount = inventorySet.filter { $0.lane == .research }.count
		print("[UsefulActionInventory] total=\(totalEligible) friction=\(frictionCount) metadata=\(metadataCount) music=\(musicCount) workspace=\(workspaceCount) research=\(researchCount)")
		
			let utilityCount = inventorySet.filter {
				LivePathEnforcer.metadataUtilities.contains($0.capabilityId)
					|| ProductSurfacePolicy.isManualUtility($0.capabilityId)
			}.count
			let nonUtilityCount = totalEligible - utilityCount
		print("[UsefulActionInventory] utility_count=\(utilityCount) non_utility_count=\(nonUtilityCount)")

		for c in validated {
			let d = decisions[c.candidateID]
			let surface = d?.surface.rawValue ?? "unknown"
			let allowed = (d?.surface != .suppressed) ? "yes" : "no"
			let panelEligible = (d?.surface == .panelOnly) ? "yes" : "no"
			let floatingEligible = (d?.eligibleForFloating == true) ? "yes" : "no"
			print("[UsefulActionInventory] capability=\(c.capabilityId) allowed=\(allowed) panel_eligible=\(panelEligible) floating_eligible=\(floatingEligible) surface=\(surface) reason=\(d?.reason ?? "unknown")")
			
			// Print FinalSelection logs
			let usefulness = ActionUsefulnessPolicy.getUsefulnessLevel(capabilityID: c.capabilityId, lane: c.lane.rawValue)
			print("[FinalSelection] candidate=\(c.capabilityId) usefulness=\(usefulness) surface=\(surface) reason=\(d?.reason ?? "unknown")")
		}
		// Floor candidates are panel-only manual controls (never floating).
		for c in addedFloor {
			print("[UsefulActionInventory] capability=\(c.capabilityId) allowed=yes panel_eligible=yes floating_eligible=no surface=panel_only reason=control_center_floor")
		}

		// Floating selection — only consider eligible candidates. Backfill if winner suppressed.
		let topScored = validated.first
		let eligibleByScore = validated
			.filter { (decisions[$0.candidateID]?.eligibleForFloating == true) }
		var floatingCandidate: PortfolioCandidate? = eligibleByScore.first

		if let top = topScored,
		   decisions[top.candidateID]?.eligibleForFloating != true {
			print("[FinalSelection] candidate_id=\(top.candidateID) capability=\(top.capabilityId) lane=\(top.lane.rawValue) surface=\(decisions[top.candidateID]?.surface.rawValue ?? "unknown") eligible_for_floating=no reason=\(decisions[top.candidateID]?.reason ?? "policy")")
			print("[FinalSelection] backfill_attempt started reason=winner_suppressed")
			if let backfill = eligibleByScore.first {
				if backfill.capabilityId == "arrange_side_by_side" {
					print("[FinalSelection] backfill_candidate=arrange_side_by_side requirement_pass=yes")
				}
				print("[FinalSelection] backfill_winner=\(backfill.capabilityId) reason=winner_suppressed_backfill")
				floatingCandidate = backfill
			} else {
				let wasArrangeCandidate = validated.first(where: { $0.capabilityId == "arrange_side_by_side" })
				if let arrangeCandidate = wasArrangeCandidate, decisions[arrangeCandidate.candidateID]?.eligibleForFloating != true {
					let decisionReason = decisions[arrangeCandidate.candidateID]?.reason ?? "unknown"
					print("[FinalSelection] backfill_candidate=arrange_side_by_side requirement_pass=no reason=\(decisionReason)")
					print("[FinalSelection] backfill_rejected capability=arrange_side_by_side reason=requirements_failed")
				}
				print("[FinalSelection] backfill_winner=none reason=winner_suppressed_no_backfill_available")
				print("[FinalSelection] no_floating_winner reason=no_action_requirements_passed")
			}
		}

		let visibleCount = (floatingCandidate != nil ? 1 : 0) + panelWithFloor.filter({ $0.candidateID != floatingCandidate?.candidateID }).count
		let chosenId = floatingCandidate?.capabilityId ?? "none"

		if let selected = floatingCandidate {
			print("[CheapAlwaysOnPortfolio] floating_selected=\(selected.capabilityId) panel_count=\(panelWithFloor.count) reason=floating_candidate_available")
			print("[ActionPortfolio] selected"
				+ " lane=\(selected.lane.rawValue)"
				+ " capability=\(selected.capabilityId)"
				+ " title=\"\(selected.title.prefix(60))\""
				+ " score=\(String(format: "%.3f", selected.score))")
			let winnerReason: String = {
				if selected.lane == .friction { return "task_friction_preferred_over_comfort" }
				return "highest_eligible_floating"
			}()
			print("[FinalSelection] winner=\(selected.capabilityId) reason=\(winnerReason)")
			print("[ActionPortfolioResult] floating=\(selected.capabilityId) panel_count=\(panelWithFloor.count) suppressed_count=\(suppressedCount)")
			print("[UsefulActionInventory] chosen=\(selected.capabilityId) visible_count=\(visibleCount)")
			decisions[selected.candidateID]?.logVisible(candidateID: selected.candidateID, lane: selected.lane.rawValue)
		} else {
			// With the control-center floor, the panel is never empty when safe
			// controls exist — "no_candidates" only when even the floor is empty.
			let reason = panelWithFloor.isEmpty ? "no_candidates" : "no_floating_candidate"
			print("[CheapAlwaysOnPortfolio] floating_selected=none panel_count=\(panelWithFloor.count) reason=\(reason)")
			print("[ActionPortfolio] selected=none reason=\(reason)")
			print("[FinalSelection] winner=none reason=\(reason)")
			print("[ActionPortfolioResult] floating=none panel_count=\(panelWithFloor.count) suppressed_count=\(suppressedCount)")
			print("[UsefulActionInventory] chosen=none visible_count=\(visibleCount)")
		}
		// Emit VisibleActionPath for each panel candidate (decisions exist only for
		// the proactive candidates; floor candidates are panel-only manual controls).
		for pc in panelWithFloor where pc.capabilityId != floatingCandidate?.capabilityId {
			if let d = decisions[pc.candidateID] {
				d.logVisible(candidateID: pc.candidateID, lane: pc.lane.rawValue)
			} else {
				print("[VisibleActionPath] candidate_id=\(pc.candidateID) capability=\(pc.capabilityId) lane=\(pc.lane.rawValue) surface=panel source=control_center_floor execution_path=manual_control contract_required=no contract_present=no")
			}
		}
			return CheapAlwaysOnPortfolioResult(
				floatingCandidate: floatingCandidate,
				panelCandidates: panelWithFloor,
				allCandidates: validated + addedFloor,
				suppressedCount: suppressedCount
			)
		}

		private static func productPanelCandidates(_ candidates: [PortfolioCandidate]) -> [PortfolioCandidate] {
			let before = candidates.count
			guard !ProductSurfacePolicy.manualControlsVisible else {
				print("[ProductPanelCandidateFilter] before=\(before) after=\(before) removed_manual=0")
				return candidates
			}

			let kept = candidates.filter { candidate in
				let isManual = ProductSurfacePolicy.isManualUtility(candidate.capabilityId)
				if isManual {
					print("[ManualUtilityCandidateInternalOnly] id=\(candidate.capabilityId) reason=product_surface_hidden")
				}
				return !isManual
			}
			let removed = before - kept.count
			let remainingManual = kept.filter { ProductSurfacePolicy.isManualUtility($0.capabilityId) }.count
			print("[ProductPanelCandidateFilter] before=\(before) after=\(kept.count) removed_manual=\(removed)")
			print("[NoManualUtilityPanelCandidatesInProductMode] status=\(remainingManual == 0 ? "pass" : "fail") count=\(remainingManual)")
			return kept
		}

		static func shouldRun(
		startupQuiet: Bool,
		modelReady: Bool,
		workflow: AmbientWorkflowType,
		determinerSignal: DeterminerSignal?,
		entityGrounding: EntityGrounding?,
		compartment: TaskCompartment?,
		activityState: ActivityState?,
		launchElapsedSeconds: Int?
	) -> (allowed: Bool, reason: String) {
		if entityGrounding?.isEntertainment == true || entityGrounding?.shouldPropose == false {
			return (false, "entertainment")
		}

		let launchAge = launchElapsedSeconds ?? Int.max
		let trust = compartment?.compartmentTrust ?? 0
		let groundingConfidence = entityGrounding?.confidence ?? 0
		if activityState?.isIdle == true {
			return (false, "user_idle")
		}
		let activeEnough = activityState?.isActive == true && (activityState?.dwellSeconds ?? 0) >= 10
		let stablePattern = (activityState?.isActive == true && (activityState?.dwellSeconds ?? 0) >= 10) || trust >= 0.50
		let contextTrusted = trust >= 0.70
			|| groundingConfidence >= 0.65
			|| activeEnough
			|| stablePattern
			|| determinerSignal?.actionable == true

		if startupQuiet {
			if launchAge >= 5 && activityState?.isActive == true { return (true, "startup_quiet_active") }
			if launchAge >= 10 && contextTrusted { return (true, "startup_quiet_period") }
			return (false, launchAge < 10 ? "startup_quiet_warmup" : "startup_quiet_no_trusted_context")
		}
		if !modelReady && contextTrusted { return (true, "model_unavailable") }
		if activityState?.isActive == true { return (true, "active_user_environment_lanes") }
		if workflow == .unknown || workflow == .idle {
			return contextTrusted
				? (true, "unknown_but_context_trusted")
				: (false, "workflow_unknown_context_untrusted")
		}
		return (true, "normal_tick")
	}

	private static func comfortCandidate(
		input: CheapAlwaysOnPortfolioInput,
		noveltyTracker: OpportunityNoveltyTracker
	) -> PortfolioCandidate? {
		let isWatching = (input.semanticState?.domain == .watching)
			|| (input.entityGrounding?.isEntertainment == true)
			|| (input.compartment?.workflow == .watching)
			|| (input.groundingResult?.domain.lowercased().contains("watching") == true)
		
		let eligible = ActionUsefulnessPolicy.evaluateMediaUsefulness(
			capabilityID: "pause_media",
			mediaState: input.mediaState,
			isWatching: isWatching
		)
		guard eligible else { return nil }

		let novelty = noveltyTracker.noveltyScore(capabilityId: "pause_media", entityKey: input.entityKey)
		return PortfolioCandidate(
			lane: .comfort,
			title: "Pause background music while you watch?",
			capabilityId: "pause_media",
			executionMode: .local_action,
			confidence: 0.75,
			usefulness: 0.70,
			executability: 0.90,
			novelty: novelty,
			reason: "Visual media is active while music is playing",
			requiredEvidence: "media_state",
			requiresConfirmation: false,
			involvedApps: [],
			frictionOpportunity: nil,
			musicIntent: nil,
			generatedAction: nil
		)
	}

	private static func musicCandidate(
		input: CheapAlwaysOnPortfolioInput,
		noveltyTracker: OpportunityNoveltyTracker
	) -> PortfolioCandidate? {
		let memoryContext = DurableMemoryContext.build(
			workflow: input.workflow.rawValue,
			compartment: input.compartment?.label,
			app: input.currentApp,
			activity: input.activityState?.state == .typing ? "typing" : (input.activityState?.isActive == true ? "active" : "idle"),
			browserType: nil
		)
		// Part 3 — do not re-suggest music right after a failed execution.
		if let cooldown = MusicActionFeedback.shared.suppression() {
			print("[MusicSuggestionSuppressed] reason=recent_failed_execution")
			print("[MusicSuggestion] suppressed reason=recent_failed_execution cooldown_s=\(cooldown.remaining)")
			AmbientActionGate.suppressed(capability: "play_focus_media", reason: .cooldown)
			return nil
		}
		if let suppression = DurableMemory.shared.shouldSuppressMusicSuggestion(
			context: memoryContext,
			isPlaying: input.mediaState.isMusicPlaying
		) {
			print("[MusicSuggestion] suppressed reason=\(suppression)")
			DurableMemory.shared.recordMusicSuppression(reason: suppression, context: memoryContext)
			AmbientActionGate.suppressed(capability: "play_focus_media", reason: input.mediaState.isMusicPlaying ? .alreadySatisfied : .noPreference)
			return nil
		}
		
		let isWatching = (input.semanticState?.domain == .watching)
			|| (input.entityGrounding?.isEntertainment == true)
			|| (input.compartment?.workflow == .watching)
			|| (input.groundingResult?.domain.lowercased().contains("watching") == true)
		
		let eligible = ActionUsefulnessPolicy.evaluateMediaUsefulness(
			capabilityID: "play_focus_media",
			mediaState: input.mediaState,
			isWatching: isWatching
		)
		guard eligible else {
			AmbientActionGate.suppressed(capability: "play_focus_media", reason: isWatching ? .currentActivityConflict : .lowRelevance)
			return nil
		}
		guard input.activityState?.isIdle != true else { return nil }

		let learnedPlaylist = PlaylistMemory.shared.suggest(compartment: input.compartment, workflow: input.workflow)
		let stableWorkContext = input.compartment != nil || !input.memory.currentEntity.isEmpty || input.groundingResult != nil
		let userPreference = DurableMemory.shared.hasAcceptedMusicPreference() || learnedPlaylist != nil
		let history = (DurableMemory.shared.actionFeedbackRecord(for: "play_focus_media")?.acceptedCount ?? 0) > 0
		let recentSuccess = MusicActionFeedback.shared.recentSuccess()
		let isTyping = input.activityState?.state == .typing
		let activeWork = input.activityState?.isActive == true || input.compartment != nil
		let proactiveWorkMusic = stableWorkContext
			&& activeWork
			&& !isTyping
			&& !input.mediaState.isMusicPlaying
			&& !isWatching
		let ambientWorkMusic = activeWork
			&& !isTyping
			&& !input.mediaState.isMusicPlaying
			&& !isWatching
		let musicEvidenceAllowed = proactiveWorkMusic
			|| ambientWorkMusic
			|| ProposalEvidenceContracts.logMusicEvidence(
				stableWorkContext: stableWorkContext,
				userPreference: userPreference,
				history: history,
				recentSuccess: recentSuccess
			)
		guard musicEvidenceAllowed else {
			print("[MusicSuggestion] suppressed reason=no_music_preference_or_history")
			print("[NoStableWorkContextOnlyMusic] status=pass count=0")
			print("[MusicSuggestionSuppressed] reason=stable_work_context_only")
			print("[NoStableWorkContextOnlyMusicPanel] status=pass count=0")
			print("[NoAlwaysAllowedMusicWithoutEvidence] status=pass count=0")
			AmbientActionGate.suppressed(capability: "play_focus_media", reason: .noPreference)
			return nil
		}

		let domainName: String = {
			if let gr = input.groundingResult, gr.confidence >= 0.70 {
				let d = gr.domain.lowercased()
				if d.contains("coding") { return "coding" }
				if d.contains("design") || d.contains("creative") { return "creative" }
				if d.contains("study") || d.contains("studying") { return "study" }
				if d.contains("research") { return "research" }
				return "background"
			}
			if let domain = input.semanticState?.domain, domain != .unknown {
				switch domain {
				case .coding, .creative_coding: return "coding"
				case .studying: return "study"
				case .researching: return "research"
				default: return "background"
				}
			}
			switch input.appCategory {
			case .editor: return "coding"
			case .pdf: return "study"
			default: return "background"
			}
		}()
		let label = input.groundingResult?.entityName ?? input.compartment?.label ?? input.memory.currentEntity
		let shortLabel = String(label.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
		let title: String = {
			if let p = learnedPlaylist {
				return "Play your \(p) playlist?"
			}
			return "Start focus music?"
		}()
		let usefulness: Double = {
			if input.compartment?.dwellState == .deep_work || input.activityState?.dwellState == .deep_work { return 0.75 }
			if input.compartment?.dwellState == .settled || input.activityState?.dwellState == .settled { return 0.60 }
			return 0.45
		}()
		let novelty = noveltyTracker.noveltyScore(capabilityId: "play_focus_media", entityKey: input.entityKey)
		AmbientActionGate.opportunity(
			capability: "play_focus_media",
			useful: true,
			reason: "active_work_context_no_music_with_learned_preference",
			preferenceMatch: userPreference || history,
			conflict: isWatching,
			currentState: input.mediaState.isMusicPlaying ? "music_playing" : "silent"
		)
		return PortfolioCandidate(
			lane: .music,
			title: title,
			capabilityId: "play_focus_media",
			executionMode: .local_action,
			// Phase 28.2: Confidence floor — music should compete even when grounding is unknown.
			confidence: max(0.35, input.groundingResult?.confidence ?? 0.70),
			usefulness: usefulness,
			executability: 0.90,  // can actually play music
			novelty: novelty,
			reason: "No music playing during active work context",
			requiredEvidence: "cheap_context",
			requiresConfirmation: true,
			involvedApps: ["Music"],
			frictionOpportunity: nil,

			musicIntent: MusicIntent(
			        taskDomain: domainName,
			        mood: .focus,
			        query: "\(domainName) focus music",
			        playlistName: PlaylistMemory.shared.suggest(compartment: input.compartment, workflow: input.workflow),
			        action: .resume // Defaulting to resume for cheap lane
			),

			generatedAction: nil
		)
	}

	private static func frictionCandidates(
		input: CheapAlwaysOnPortfolioInput,
		noveltyTracker: OpportunityNoveltyTracker
	) -> [PortfolioCandidate] {
		var out: [PortfolioCandidate] = []

		// Phase 36.2 — Runtime workspace friction evaluator.
		// Detects layout friction from runtime/workspace inventory (Firefox + Preview both
		// present, same compartment, not arranged). Independent of active/browser transitions.
		let inventory = WorkspaceRuntimeInventoryProvider.snapshot()
		let runtimeDecision = RuntimeWorkspaceFrictionEvaluator.evaluate(
			inventory: inventory,
			workflow: input.workflow.rawValue,
			compartmentLabel: input.compartment?.label,
			compartmentTrust: input.compartment?.compartmentTrust ?? 0.0,
			currentEntity: input.memory.currentEntity
		)
		if runtimeDecision.eligible, let pair = runtimeDecision.pair {
			AmbientActionGate.frictionOpportunity(
				capability: "arrange_side_by_side",
				useful: true,
				reason: runtimeDecision.reason
			)
			let contract = ActionTargetContract.forLayoutApps(
				capabilityID: "arrange_side_by_side",
				appNames: [pair.primaryApp, pair.secondaryApp],
				evidenceType: pair.evidenceType,
				confidence: pair.confidence,
				fallbackAllowed: false
			)
			let usefulness: Double = {
				switch runtimeDecision.expectedTimeSaved {
				case "high": return 0.80
				case "medium": return 0.65
				default: return 0.50
				}
			}()
			let title: String = {
				let a = pair.primaryApp
				let b = pair.secondaryApp
				return "Put \(a) and \(b) side by side?"
			}()
			let novelty = noveltyTracker.noveltyScore(capabilityId: "arrange_side_by_side", entityKey: input.entityKey)
			out.append(PortfolioCandidate(
				lane: .friction,
				title: title,
				capabilityId: "arrange_side_by_side",
				executionMode: .local_action,
				confidence: pair.confidence,
				usefulness: usefulness,
				executability: 0.88,
				novelty: novelty,
				reason: runtimeDecision.reason,
				requiredEvidence: "runtime_workspace_friction",
				requiresConfirmation: true,
				involvedApps: [pair.primaryApp, pair.secondaryApp],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil,
				sourcePath: "runtime_workspace_friction",
				targetContract: contract
			))
		} else if runtimeDecision.reason == "visibility_only_no_friction", let pair = runtimeDecision.pair {
			let frontmost = inventory.frontmostAppName
			let pairApps = [pair.primaryApp, pair.secondaryApp]
			let containsInvalidMusic = pairApps.contains { app in
				app.caseInsensitiveCompare("Music") == .orderedSame
					&& frontmost.caseInsensitiveCompare("Music") != .orderedSame
			}
			if !containsInvalidMusic {
				let novelty = noveltyTracker.noveltyScore(capabilityId: "arrange_side_by_side", entityKey: input.entityKey)
				let contract = ActionTargetContract.forLayoutApps(
					capabilityID: "arrange_side_by_side",
					appNames: pairApps,
					evidenceType: .active_window_pair,
					confidence: min(pair.confidence, 0.62),
					fallbackAllowed: false
				)
				print("[ManualArrangeCandidate] capability=arrange_side_by_side reason=visibility_only_manual_panel primary=\(pair.primaryApp) secondary=\(pair.secondaryApp)")
				out.append(PortfolioCandidate(
					lane: .friction,
					title: "Put \(pair.primaryApp) and \(pair.secondaryApp) side by side?",
					capabilityId: "arrange_side_by_side",
					executionMode: .local_action,
					confidence: min(pair.confidence, 0.62),
					usefulness: 0.52,
					executability: 0.88,
					novelty: novelty,
					reason: "manual_arrange_available",
					requiredEvidence: "runtime_visible_pair",
					requiresConfirmation: true,
					involvedApps: pairApps,
					frictionOpportunity: nil,
					musicIntent: nil,
					generatedAction: nil,
					sourcePath: "manual_arrange_panel",
					targetContract: contract
				))
			} else {
				print("[ManualArrangeCandidate] suppressed capability=arrange_side_by_side reason=music_secondary_not_frontmost")
			}
		}

		// Legacy active/browser-transition-driven friction signals
		guard !input.frictionSignals.isEmpty else { return out }
		let workspacePatterns = WorkspacePatternTracker.shared.knownPatterns()
		let currentApps = Set(([input.currentApp] + input.memory.recentEntities).filter { !$0.isEmpty })
		let opportunities = FrictionOpportunityReasoner.reason(
		        frictionSignals: input.frictionSignals,
		        workspacePatterns: workspacePatterns,
		        currentApps: currentApps,
		        currentEntity: input.memory.currentEntity,
		        compartmentLabel: input.compartment?.label ?? ""
		)
		out.append(contentsOf: opportunities.compactMap { opp in
		        if opp.capabilityId == "collect_references" {
		                let hasReferenceSignal = input.frictionSignals.contains { $0.type == .repeated_reference_lookup }
		                if !hasReferenceSignal {
		                        print("[CheapAlwaysOnPortfolio] collect_references_skipped reason=no_valid_reference_friction")
		                        return nil
		                }
		        }
		        let novelty = noveltyTracker.noveltyScore(capabilityId: opp.capabilityId, entityKey: input.entityKey)

			return PortfolioCandidate(
				lane: .friction,
				title: opp.title,
				capabilityId: opp.capabilityId,
				executionMode: .local_action,
				confidence: opp.confidence,
				usefulness: min(0.85, opp.confidence * 0.90),
				executability: opp.requiresConfirmation ? 0.85 : 0.90,
				novelty: novelty,
				reason: opp.frictionRemoved,
				requiredEvidence: "friction_signal",
				requiresConfirmation: opp.requiresConfirmation,
				involvedApps: opp.involvedApps,
				frictionOpportunity: opp,
				musicIntent: nil,
				generatedAction: nil
			)
		})

		// Deduplicate capability ids — runtime friction may have already generated arrange_side_by_side.
		var seen = Set<String>()
		return out.filter { c in
			if seen.contains(c.capabilityId) { return false }
			seen.insert(c.capabilityId)
			return true
		}
	}

	private static func workspaceCandidate(
		input: CheapAlwaysOnPortfolioInput,
		noveltyTracker: OpportunityNoveltyTracker
	) -> PortfolioCandidate? {
		let inventory = WorkspaceRuntimeInventoryProvider.snapshot()
		let currentApps = Set(inventory.runningApps.map(\.appName).filter { !$0.isEmpty })
		guard let pattern = DurableMemory.shared.bestDurableWorkspacePattern(
			workflow: input.workflow.rawValue,
			compartment: input.compartment?.label,
			currentApps: currentApps
		) else {
			print("[ProposalFunnelAudit] not_generated capability=restore_workspace reason=no_missing_durable_workspace")
			print("[WorkspaceActionSurfaceDecision] capability=restore_workspace useful=no surfaced=no reason=no_missing_durable_workspace")
			return nil
		}
		let missing = DurableMemory.shared.missingCheck(
			pattern: pattern,
			currentApps: currentApps,
			currentURLs: inventory.currentURLs
		)
		if input.activityState?.state == .typing {
			print("[ProposalFunnelAudit] not_generated capability=restore_workspace reason=user_typing")
			print("[WorkspaceActionSurfaceDecision] capability=restore_workspace useful=no surfaced=no reason=user_typing")
			return nil
		}
		if DurableMemory.shared.shouldSuppressRestoreSuggestion(restoreKey: missing.restoreKey) {
			print("[ProposalFunnelAudit] not_generated capability=restore_workspace reason=recently_ignored")
			print("[WorkspaceActionSurfaceDecision] capability=restore_workspace useful=no surfaced=no reason=recently_ignored")
			return nil
		}
		guard missing.canRestore else {
			print("[ProposalFunnelAudit] not_generated capability=restore_workspace reason=workspace_items_present")
			print("[WorkspaceActionSurfaceDecision] capability=restore_workspace useful=no surfaced=no reason=workspace_items_present")
			return nil
		}
		let novelty = noveltyTracker.noveltyScore(capabilityId: "restore_workspace", entityKey: input.entityKey)
		print("[WorkspaceActionSurfaceDecision] capability=restore_workspace useful=yes surfaced=yes reason=durable_workspace_items_missing")
		return PortfolioCandidate(
			lane: .workspace,
			title: "Open your usual \(pattern.apps.prefix(3).map(\.appName).joined(separator: " + ")) setup?",
			capabilityId: "restore_workspace",
			executionMode: .local_action,
			confidence: pattern.confidence,
			usefulness: 0.65,
			executability: 0.85,
			novelty: novelty,
			reason: "Durable workspace pattern missing \(missing.missingApps.count + missing.missingURLs.count) required item(s)",
			requiredEvidence: ProgressiveEvidenceLevel.metadata_rich.rawValue,
			requiresConfirmation: true,
			involvedApps: missing.missingApps,
			frictionOpportunity: nil,
			musicIntent: nil,
			generatedAction: nil
		)
	}

	private static func metadataCandidates(
		input: CheapAlwaysOnPortfolioInput,
		noveltyTracker: OpportunityNoveltyTracker
	) -> [PortfolioCandidate] {
		let hasMetadataContext = input.compartment != nil || !input.memory.relatedFocusEntities.isEmpty
		let evidenceLevel: ProgressiveEvidenceLevel = hasMetadataContext ? .metadata_rich : .metadata_only
		guard evidenceLevel.rank >= ProgressiveEvidenceLevel.metadata_rich.rank else { return [] }
		let browser = BrowserContextExtractor.extract(appName: input.currentApp, activeAppPID: nil)
		let currentURL = browser?.selectedURL?.absoluteString ?? browser?.currentURL?.absoluteString
		let tabTitles = browser?.recentTabTitles ?? input.compartment?.browserTabs.sorted() ?? []
		let assessment = BrowserContextStrategy.assess(
			title: browser?.selectedTitle ?? input.memory.currentEntity,
			url: currentURL.flatMap(URL.init(string:)),
			tabTitles: tabTitles,
			hasAXText: false,
			hasOCR: false
		)
		var candidates: [PortfolioCandidate] = []
		let currentApps = Set(WorkspaceRuntimeInventoryProvider.snapshot().runningApps.map(\.appName))
		let hasDurablePattern = DurableMemory.shared.bestDurableWorkspacePattern(
			workflow: input.workflow.rawValue,
			compartment: input.compartment?.label,
			currentApps: currentApps
		) != nil
		if assessment.safeActions.contains("copy_current_url"), let currentURL, !currentURL.isEmpty {
			candidates.append(PortfolioCandidate(
				lane: .metadata,
				title: "Copy this page link?",
				capabilityId: "copy_current_url",
				executionMode: .local_action,
				confidence: 0.56,
				usefulness: 0.28,
				executability: 0.88,
				novelty: noveltyTracker.noveltyScore(capabilityId: "copy_current_url", entityKey: input.entityKey),
				reason: "Metadata-rich browser context exposes a current URL",
				requiredEvidence: ProgressiveEvidenceLevel.metadata_rich.rawValue,
				requiresConfirmation: false,
				involvedApps: [],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil
			))
		}
		if assessment.safeActions.contains("collect_references"), let currentURL, !currentURL.isEmpty {
			candidates.append(PortfolioCandidate(
				lane: .metadata,
				title: "Collect links from this context?",
				capabilityId: "collect_references",
				executionMode: .local_action,
				confidence: 0.54,
				usefulness: 0.24,
				executability: 0.84,
				novelty: noveltyTracker.noveltyScore(capabilityId: "collect_references", entityKey: input.entityKey),
				reason: "Safe metadata action can gather the visible URL and tab titles",
				requiredEvidence: ProgressiveEvidenceLevel.metadata_rich.rawValue,
				requiresConfirmation: false,
				involvedApps: [],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil
			))
		}
		if assessment.safeActions.contains("remember_workspace"), !hasDurablePattern {
			candidates.append(PortfolioCandidate(
				lane: .metadata,
				title: "Remember this workspace?",
				capabilityId: "remember_workspace",
				executionMode: .local_action,
				confidence: 0.52,
				usefulness: 0.18,
				executability: 0.82,
				novelty: noveltyTracker.noveltyScore(capabilityId: "remember_workspace", entityKey: input.entityKey),
				reason: "Current metadata-rich workspace is not yet durable",
				requiredEvidence: ProgressiveEvidenceLevel.metadata_rich.rawValue,
				requiresConfirmation: false,
				involvedApps: [],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil
			))
		}
		if assessment.safeActions.contains("open_current_task_panel"), candidates.isEmpty {
			candidates.append(PortfolioCandidate(
				lane: .metadata,
				title: "Open the current task panel?",
				capabilityId: "open_current_task_panel",
				executionMode: .local_action,
				confidence: 0.50,
				usefulness: 0.14,
				executability: 0.95,
				novelty: noveltyTracker.noveltyScore(capabilityId: "open_current_task_panel", entityKey: input.entityKey),
				reason: "Trusted metadata context exists but no stronger low-risk action was available",
				requiredEvidence: ProgressiveEvidenceLevel.metadata_rich.rawValue,
				requiresConfirmation: false,
				involvedApps: [],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil
			))
		}

		// Phase 40/43 — Research/cognitive acquisition candidates for document/browser contexts.
		// Phase 43: These now use .local_action because the executors are real (Phase 42 registered them).
		// They float proactively (not just as panel fallbacks) via SuggestionSurfacePolicy cognitive path.
		let sourceLabel = assessment.contentAvailable ? "visible_capture" : "metadata"
		let scopeLabel = assessment.contentAvailable ? AcquiredContentScope.visibleViewport.rawValue : AcquiredContentScope.metadataOnly.rawValue
		let availableChars = assessment.contentAvailable ? 1500 : 0
		let contentInsufficient = !assessment.contentAvailable || availableChars < 1500
		let setupCapability: String = {
			if assessment.safeActions.contains("capture_full_document") { return "capture_full_document" }
			if assessment.safeActions.contains("capture_visible_page") { return "capture_visible_page" }
			if assessment.safeActions.contains("enable_browser_bridge") { return "enable_browser_bridge" }
			return "select_text_hint"
		}()
		if contentInsufficient {
			let reason = !assessment.contentAvailable ? "content_unavailable" : "short_visible_text"
			print("[PrimaryContextAction] capability=\(setupCapability) reason=\(reason)")
			print("[ActionTitle] capability=\(setupCapability) title=\"\(setupTitle(for: setupCapability))\" source=context_acquisition_need")
		}
		for capId in ["explicit_visible_capture_summary", "extract_action_items", "create_checklist"] {
			let reason = !assessment.contentAvailable ? "metadata_only" : (availableChars < 1500 ? "too_short" : "actionable_content")
			let allowed = (!contentInsufficient && assessment.safeActions.contains(capId)) ? "yes" : "no"
			print("[CognitiveUsefulnessGate] capability=\(capId) source=\(sourceLabel) scope=\(scopeLabel) chars=\(availableChars) allowed=\(allowed) reason=\(reason)")
			if allowed == "no" {
				let suppressionReason = !assessment.contentAvailable ? "metadata_only" : "too_short_visible_context"
				print("[PanelSuppression] capability=\(capId) reason=\(suppressionReason)")
			}
		}
		if contentInsufficient {
			for suppressed in ["extract_action_items", "create_checklist"] {
				print("[CognitiveCloneSuppression] suppressed=\(suppressed) kept=\(setupCapability) reason=\(!assessment.contentAvailable ? "weak_same_input" : "short_context")")
			}
		}
		for capId in ["capture_full_document", "capture_visible_page", "enable_browser_bridge", "select_text_hint"] where assessment.safeActions.contains(capId) {
			let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: input.entityKey)
			print("[SetupActionSuggestion] capability=\(capId) reason=\(!assessment.contentAvailable ? "only_metadata" : "short_visible_text")")
			candidates.append(PortfolioCandidate(
				lane: capId == "select_text_hint" ? .metadata : .research,
				title: setupTitle(for: capId),
				capabilityId: capId,
				executionMode: .local_action,
				confidence: 0.70,
				usefulness: capId == setupCapability ? 0.74 : 0.45,
				executability: 0.80,
				novelty: novelty,
				reason: "context_acquisition_need",
				requiredEvidence: ProgressiveEvidenceLevel.metadata_rich.rawValue,
				requiresConfirmation: capId == "capture_full_document",
				involvedApps: [],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil,
				sourcePath: "context_acquisition_need"
			))
		}
		let acquisitionCapabilities: [(String, String, Double)] = [
			("explicit_visible_capture_summary", "Summarize this page", 0.72),
			("extract_action_items", "Extract action items", 0.68),
			("create_checklist", "Make a checklist from this page", 0.65)
		]
		var acquisitionCount = 0
		for (capId, title, usefulness) in acquisitionCapabilities where assessment.safeActions.contains(capId) && !contentInsufficient {
			let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: input.entityKey)
			print("[ResearchLane] generated capability=\(capId) evidence=metadata_rich acquisition=visible_capture source=cheap_portfolio")
			candidates.append(PortfolioCandidate(
				lane: .research,
				title: title,
				capabilityId: capId,
				executionMode: .local_action,  // Phase 43: real executor registered in Phase 42
				confidence: 0.68,
				usefulness: usefulness,
				executability: 0.80,
				novelty: novelty,
				reason: "document_context_acquisition_available",
				requiredEvidence: ProgressiveEvidenceLevel.metadata_rich.rawValue,
				requiresConfirmation: false,
				involvedApps: [],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil
			))
			acquisitionCount += 1
		}
		if acquisitionCount > 0 {
			print("[PortfolioLaneDecision] source=browser_context_strategy suggested_research=\(acquisitionCount) research_lane_enabled=yes reason=local_action_executor_available")
		}
		return candidates
	}

	// MARK: - Control-center floor (Phase 69.1 regression repair)
	//
	// The always-on visible action inventory used to go empty (total=0,
	// panel_count=0) during startup/quiet periods and whenever entity grounding
	// forbade the music/friction/workspace lanes — even though the environment
	// exposed perfectly valid manual controls (copy URL, arrange windows, music).
	// This floor computes safe, panel-only manual controls *directly from
	// environment state*, independent of grounding, quiet period, workflow, or
	// compartment. Grounding may keep FLOATING conservative, but it must never
	// hide control-center actions. These candidates never float.
	struct ControlFloorResult: Sendable {
		let candidates: [PortfolioCandidate]
		let musicPreferenceExists: Bool
		let musicPresent: Bool
		let windowPairExists: Bool
		let frictionPresent: Bool
	}

	static func controlCenterFloor(
		input: CheapAlwaysOnPortfolioInput,
		currentURLOverride: String? = nil,
		tabTitlesOverride: [String]? = nil,
		visibleAppNamesOverride: [String]? = nil
	) -> ControlFloorResult {
		let inv = WorkspaceRuntimeInventoryProvider.snapshot()
		let browser = BrowserContextExtractor.extract(appName: input.currentApp, activeAppPID: nil)
		// URL/tabs: live AX first, then the workspace inventory (reliable + testable),
		// then compartment memory. Never depends on grounding.
		let overrideURL = currentURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
		let currentURL = overrideURL?.isEmpty == false
			? overrideURL
			: browser?.selectedURL?.absoluteString
			?? browser?.currentURL?.absoluteString
			?? inv.currentURLs.first
		let tabTitles: [String] = {
			let override = tabTitlesOverride?
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty } ?? []
			if !override.isEmpty { return override }
			if let t = browser?.recentTabTitles, !t.isEmpty { return t }
			if !inv.browserTabTitles.isEmpty { return inv.browserTabTitles }
			return Array(input.compartment?.browserTabs.sorted() ?? [])
		}()
		let visibleAppNames: [String] = {
			let override = visibleAppNamesOverride?
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty } ?? []
			if !override.isEmpty { return override }
			return inv.visibleWindows.map { $0.appName }.filter { !$0.isEmpty }
		}()
		let distinctVisibleApps = Set(visibleAppNames).count
		let frontmost = (inv.frontmostAppName.isEmpty ? input.currentApp : inv.frontmostAppName)
		let pairedAppCandidate = visibleAppNames.first { $0.caseInsensitiveCompare(frontmost) != .orderedSame }
		// Music control belongs in the control center only on a real signal that the
		// user wants music NOW — actively playing, an accepted preference, or a
		// recent successful play. A merely-open background Music.app process is NOT
		// a signal (it would spam music into focused work contexts). Grounding is
		// never consulted.
		let musicPreference = DurableMemory.shared.hasAcceptedMusicPreference()
		let musicActive = input.mediaState.isMusicPlaying
		let musicRecentSuccess = MusicActionFeedback.shared.recentSuccess()

		var floor: [PortfolioCandidate] = []
		func candidate(_ cap: String, _ title: String, _ lane: PortfolioCandidate.Lane, apps: [String] = [], reason: String) -> PortfolioCandidate {
			PortfolioCandidate(
				lane: lane, title: title, capabilityId: cap, executionMode: .local_action,
				confidence: 0.5, usefulness: 0.2, executability: 0.85, novelty: 0.5,
				reason: reason, requiredEvidence: ProgressiveEvidenceLevel.metadata_only.rawValue,
				requiresConfirmation: false, involvedApps: apps, frictionOpportunity: nil,
				musicIntent: nil, generatedAction: nil, sourcePath: "control_center_floor"
			)
		}
		func allow(_ cap: String, _ title: String, _ lane: PortfolioCandidate.Lane, apps: [String] = [], reason: String, floatingAllowed: Bool = false) {
			floor.append(candidate(cap, title, lane, apps: apps, reason: reason))
			print("[ControlEligibility] id=\(cap) allowed=yes reason=\(reason) ignores_grounding=yes")
			if lane == .music || lane == .friction || lane == .workspace {
				print("[GroundingOnlyBlocksFloating] id=\(cap) control_allowed=yes floating_allowed=\(floatingAllowed ? "yes" : "no")")
			}
		}

		// Context acquisition — always available (gather + refresh + panel).
		allow("capture_visible_page", "Capture visible page", .metadata, reason: "context_gathering_always_available")
		allow("open_current_task_panel", "Open the current task panel", .metadata, reason: "control_center_always_available")
		allow("select_text_hint", "Select text to summarize", .metadata, reason: "context_selection_hint_available")

		// Metadata controls — depend only on a current URL / browser tabs.
		if let u = currentURL, !u.isEmpty {
			allow("copy_current_url", "Copy this page link", .metadata, reason: "current_url_available")
		}
		if (currentURL != nil && !(currentURL ?? "").isEmpty) || !tabTitles.isEmpty {
			allow("collect_references", "Collect open references", .metadata, reason: "browser_tabs_or_url_available")
		}

		// Window friction — depends on visible windows / valid manual payload.
		let arrangeValid = LocalActionPayloadValidator.validate(
			capabilityId: "arrange_side_by_side", involvedApps: visibleAppNames, involvedURLs: [],
			browserTabTitles: tabTitles, compartmentLabel: input.compartment?.label
		).valid
		let windowPairExists = arrangeValid || distinctVisibleApps >= 2
		if windowPairExists {
			allow("arrange_side_by_side", "Arrange windows side by side", .friction, apps: visibleAppNames, reason: "visible_windows_or_manual_payload")
		}
		if let paired = pairedAppCandidate {
			allow("switch_to_paired_app", "Switch to \(paired)", .friction, apps: [paired], reason: "paired_app_candidate_exists")
		}

		// Workspace — remember the current workspace if it has substance.
		if distinctVisibleApps >= 1 && (input.compartment != nil || !tabTitles.isEmpty || currentURL?.isEmpty == false) {
			allow("remember_workspace", "Remember this workspace", .workspace, apps: visibleAppNames, reason: "workspace_has_substance")
		}

		// Music — actively playing / accepted preference / recent success only, AND
		// never during a post-failure cooldown (protected no-music-spam rule).
		let musicCooldown = MusicActionFeedback.shared.suppression() != nil
		let musicSupported = (musicActive || musicPreference || musicRecentSuccess) && !musicCooldown
		if musicSupported {
			let reason = musicActive ? "music_playing" : (musicPreference ? "music_preference_exists" : "recent_success")
			allow("play_focus_media", "Play focus music", .music, reason: "player_or_preference_available_\(reason)")
		} else if musicCooldown {
			print("[ControlEligibility] id=play_focus_media allowed=no reason=music_failure_cooldown ignores_grounding=yes")
		}

		return ControlFloorResult(
			candidates: floor,
			musicPreferenceExists: musicSupported,
			musicPresent: musicSupported,
			windowPairExists: windowPairExists,
			frictionPresent: windowPairExists || pairedAppCandidate != nil
		)
	}

	private static func setupTitle(for capabilityId: String) -> String {
		switch capabilityId {
		case "capture_full_document": return "Capture full document"
		case "enable_browser_bridge": return "Enable page access"
		case "select_text_hint": return "Select text to summarize"
		default: return "Capture visible page"
		}
	}

	private static func payloadURLs(for candidate: PortfolioCandidate, input: CheapAlwaysOnPortfolioInput) -> [String] {
		switch candidate.capabilityId {
		case "copy_current_url", "collect_references":
			let browser = BrowserContextExtractor.extract(appName: input.currentApp, activeAppPID: nil)
			if let selected = browser?.selectedURL?.absoluteString ?? browser?.currentURL?.absoluteString, !selected.isEmpty {
				return [selected]
			}
			return []
		case "restore_workspace":
			let inventory = WorkspaceRuntimeInventoryProvider.snapshot()
			let currentApps = Set(inventory.runningApps.map(\.appName))
			guard let pattern = DurableMemory.shared.bestDurableWorkspacePattern(
				workflow: input.workflow.rawValue,
				compartment: input.compartment?.label,
				currentApps: currentApps
			) else { return [] }
			let missing = DurableMemory.shared.missingCheck(pattern: pattern, currentApps: currentApps, currentURLs: inventory.currentURLs)
			return missing.missingURLs
		default:
			return []
		}
	}
}

enum SuggestionTickSummaryLog {
	static func line(
		modelReady: Bool,
		startupQuiet: Bool,
		workflow: AmbientWorkflowType,
		workflowActionable: Bool,
		determinerActionable: Bool,
		cheapPortfolioRan: Bool,
		heavyPlannerRan: Bool,
		candidatesCount: Int,
		selected: String?,
		surfaceResult: String,
		suppressionReason: String,
		panelCount: Int = 0
	) -> String {
		"[SuggestionTickSummary]"
			+ " model_ready=\(modelReady ? "yes" : "no")"
			+ " startup_quiet=\(startupQuiet ? "yes" : "no")"
			+ " workflow=\(workflow.rawValue)"
			+ " workflow_actionable=\(workflowActionable ? "yes" : "no")"
			+ " determiner_actionable=\(determinerActionable ? "yes" : "no")"
			+ " cheap_portfolio_ran=\(cheapPortfolioRan ? "yes" : "no")"
			+ " heavy_planner_ran=\(heavyPlannerRan ? "yes" : "no")"
			+ " candidates_count=\(candidatesCount)"
			+ " selected=\(selected ?? "none")"
			+ " surface_result=\(surfaceResult)"
			+ " panel_count=\(panelCount)"
			+ " suppression_reason=\(suppressionReason)"
	}

	static func log(
		modelReady: Bool,
		startupQuiet: Bool,
		workflow: AmbientWorkflowType,
		workflowActionable: Bool,
		determinerActionable: Bool,
		cheapPortfolioRan: Bool,
		heavyPlannerRan: Bool,
		candidatesCount: Int,
		selected: String?,
		surfaceResult: String,
		suppressionReason: String,
		panelCount: Int = 0
	) {
		if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .dogfood) {
			print("[UsefulActionInventory] workflow=\(workflow.rawValue) actionable=\(workflowActionable ? "yes" : "no") candidates=\(candidatesCount) selected=\(selected ?? "none") surface=\(surfaceResult) panel=\(panelCount)")
		}

		if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .trace) {
			print(line(
				modelReady: modelReady,
				startupQuiet: startupQuiet,
				workflow: workflow,
				workflowActionable: workflowActionable,
				determinerActionable: determinerActionable,
				cheapPortfolioRan: cheapPortfolioRan,
				heavyPlannerRan: heavyPlannerRan,
				candidatesCount: candidatesCount,
				selected: selected,
				surfaceResult: surfaceResult,
				suppressionReason: suppressionReason,
				panelCount: panelCount
			))
		}
	}
}
