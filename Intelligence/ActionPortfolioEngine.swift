import AppKit
import Foundation

// MARK: - PortfolioCandidate

/// Phase 26.2 — A candidate action from one of the evaluation lanes.
/// All lanes produce PortfolioCandidates which are ranked together.
struct PortfolioCandidate: Sendable {
    enum Lane: String, Sendable, CaseIterable {
        case music
        case workspace
        case metadata
        case friction
        case research
        case cognitive
        case comfort
    }

	enum Family: String, Sendable, CaseIterable {
		case media
		case research
		case writing
		case coding
		case communication
		case workspace
		case utility
		case comfort
	}

    let lane: Lane
    let title: String
    let capabilityId: String
    let executionMode: ExecutionMode
    let confidence: Double        // 0..1 — how confident the signal is
    let usefulness: Double        // 0..1 — how useful this action would be right now
    let executability: Double     // 0..1 — can this actually execute (1=yes, 0.3=preview only)
    let novelty: Double           // 0..1 — how fresh (not recently shown)
    let reason: String
    let requiredEvidence: String
    let requiresConfirmation: Bool
    let involvedApps: [String]
    let frictionOpportunity: FrictionOpportunityReasoner.FrictionOpportunity?
    let musicIntent: MusicIntent?
    let generatedAction: GeneratedActionProposal?
    let sourcePath: String
    let targetContract: ActionTargetContract?

	init(
		lane: Lane,
		title: String,
		capabilityId: String,
		executionMode: ExecutionMode,
		confidence: Double,
		usefulness: Double,
		executability: Double,
		novelty: Double,
		reason: String,
		requiredEvidence: String,
		requiresConfirmation: Bool,
		involvedApps: [String],
		frictionOpportunity: FrictionOpportunityReasoner.FrictionOpportunity?,
		musicIntent: MusicIntent?,
		generatedAction: GeneratedActionProposal?,
		sourcePath: String = "portfolio",
		targetContract: ActionTargetContract? = nil
	) {
		self.lane = lane
		self.title = title
		self.capabilityId = capabilityId
		self.executionMode = executionMode
		self.confidence = confidence
		self.usefulness = usefulness
		self.executability = executability
		self.novelty = novelty
		self.reason = reason
		self.requiredEvidence = requiredEvidence
		self.requiresConfirmation = requiresConfirmation
		self.involvedApps = involvedApps
		self.frictionOpportunity = frictionOpportunity
		self.musicIntent = musicIntent
		self.generatedAction = generatedAction
		self.sourcePath = sourcePath
		self.targetContract = targetContract
	}

	var family: Family {
		switch capabilityId {
		case "play_focus_media", "pause_media", "resume_focus_media":
			return .media
		case "collect_references", "pin_reference_tabs", "restore_research_tabs", "extract_and_organize", "explicit_visible_capture_summary", "summarize_visible_content":
			return .research
		case "rewrite_text", "draft_reply":
			return .writing
		case "diagnose_error", "suggest_refactor", "plan_next_steps":
			return .coding
		case "summarize_thread":
			return .communication
		case "restore_workspace", "remember_workspace", "arrange_side_by_side", "switch_to_paired_app", "split_research_setup":
			return .workspace
		case "copy_current_url", "copy_all_related_links", "open_current_task_panel":
			return .utility
		case "enable_reduce_interruptions", "start_focus_timer":
			return .comfort
		default:
			switch lane {
			case .research, .cognitive: return .research
			case .music: return .media
			case .workspace: return .workspace
			case .comfort: return .comfort
			default: return .utility
			}
		}
	}

	var hookChain: [String] {
		switch capabilityId {
		case "play_focus_media":
			if musicIntent?.action == .playPlaylist {
				return ["lookup_playlist_memory", "play_playlist", "verify_playing"]
			}
			if musicIntent?.action == .resume {
				return ["detect_player", "resume_player", "verify_playing"]
			}
			return ["detect_player", "play_first_local_playlist", "verify_playing"]
		case "restore_workspace":
			return ["load_workspace_pattern", "open_missing_apps", "verify_workspace"]
		case "arrange_side_by_side":
			return ["detect_app_pair", "propose_layout", "move_windows", "verify_layout"]
		case "switch_to_paired_app":
			return ["detect_app_pair", "activate_target_app", "raise_target_window", "verify_focus"]
		case "collect_references":
			return ["gather_browser_context", "format_reference_list", "copy_to_clipboard"]
		case "pin_reference_tabs":
			return ["gather_repeated_tabs", "prepare_tab_list", "copy_to_clipboard"]
		case "restore_research_tabs":
			return ["load_workspace_pattern", "open_saved_urls", "verify_urls_opened"]
		case "split_research_setup":
			return ["load_workspace_pattern", "open_url_new_window", "move_windows", "verify_layout"]
		case "resume_focus_media":
			return ["detect_player", "resume_player", "verify_playing"]
		case "compare_rental_options":
			return ["browser_tabs_context", "extract_listing_details", "compare_table", "present_summary"]
		case "draft_listing_ad":
			return ["browser_context", "infer_listing_details", "draft_text", "present_editable_result"]
		case "create_listing_checklist":
			return ["browser_context", "extract_listing_fields", "generate_checklist", "present_editable_result"]
		case "extract_pricing_guidance":
			return ["browser_tabs_context", "extract_price_mentions", "summarize_pricing_guidance", "present_summary"]
		case "identify_missing_listing_details":
			return ["browser_context", "extract_listing_fields", "detect_missing_fields", "present_checklist"]
		case "create_questions_to_ask_landlord":
			return ["browser_context", "extract_listing_details", "draft_questions", "present_editable_result"]
		case "compare_listing_platforms":
			return ["browser_tabs_context", "extract_platform_differences", "compare_table", "present_summary"]
		case "summarize_thread":
			return ["browser_context", "extract_thread_points", "summarize_thread", "present_summary"]
		case "synthesize_advice":
			return ["browser_tabs_context", "extract_advice_points", "synthesize_advice", "present_summary"]
		default:
			if lane == .research || lane == .cognitive {
				return ["gather_context", "generate_text", "present_artifact"]
			}
			return ["gather_context", "present_result"]
		}
	}

	var expectedResult: String {
		switch family {
		case .media: return "Controls music and background media."
		case .research: return "Produces a grounded artifact or comparison from the current context."
		case .writing: return "Drafts or improves text based on context."
		case .coding: return "Assists with coding, errors, and refactoring."
		case .communication: return "Summarizes or drafts messages."
		case .workspace: return "Arranges windows or manages your workspace."
		case .utility: return "Quick utilities like copying URLs."
		case .comfort: return "Reduces distractions and improves focus."
		}
	}

	var failureMode: String {
		switch family {
		case .media: return "No suitable media player detected."
		case .research, .writing, .coding, .communication: return "Insufficient context to produce a grounded result."
		case .workspace: return "No related windows or apps found to arrange."
		case .utility: return "No relevant metadata available."
		case .comfort: return "No active distractions detected."
		}
	}

    /// Composite ranking score: executable, useful, confident, novel actions win.
    var score: Double {
        usefulness * executability * confidence * novelty
    }

	var candidateID: String {
		let contractPart = targetContract?.contractID ?? "no_contract"
		let titleHash = Self.stableHash(title)
		let appsHash = Self.stableHash(involvedApps.joined(separator: "|"))
		return "\(capabilityId)|\(lane.rawValue)|\(sourcePath)|\(contractPart)|\(titleHash)|\(appsHash)"
	}

	private static func stableHash(_ text: String) -> String {
		var hash: UInt64 = 0xcbf29ce484222325
		for byte in text.utf8 {
			hash ^= UInt64(byte)
			hash &*= 0x100000001b3
		}
		return String(hash, radix: 16, uppercase: true)
	}
}

// MARK: - ActionPortfolioEngine

/// Phase 26.2 — Evaluates multiple lanes and picks the best action.
///
/// Lanes:
///   - music: play/resume music when working and no music is playing
///   - workspace: restore learned workspace patterns
///   - friction: reduce detected friction (app switching, tab cycling, etc.)
///   - research: synthesize, compare, collect from real sources
///   - cognitive: text-based help (quiz, checklist, explain) — needs content evidence
///   - comfort: pause media, suppress (watching context)
///
/// Ranking: score = usefulness * executability * confidence * novelty
///
/// Rules:
///   - Executable actions get priority over text when similarly useful
///   - Friction does not automatically win
///   - Music can win when user is working and no music is playing
///   - Cognitive wins only with enough content evidence
///   - Workspace wins only with real learned workspace
///   - Suppress if no candidate exceeds quality threshold (0.12)
///
/// Required logs: [ActionPortfolio]
enum ActionPortfolioEngine {

    static let qualityThreshold: Double = 0.12

	private static func logCandidateIdentity(_ candidate: PortfolioCandidate) {
		print("[CandidateIdentity] capability=\(candidate.capabilityId) lane=\(candidate.lane.rawValue) source=\(candidate.sourcePath) candidate_id=\(candidate.candidateID)")
	}

	private static func logDuplicateCapabilities(_ candidates: [PortfolioCandidate], context: String) {
		let duplicates = Dictionary(grouping: candidates, by: \.capabilityId)
			.filter { $0.value.count > 1 }
		for (capability, grouped) in duplicates {
			let lanes = grouped.map(\.lane.rawValue).sorted().joined(separator: ",")
			let kept = grouped.map(\.candidateID).sorted().joined(separator: ",")
			print("[CrashGuard] duplicate_key_prevented key=\(capability) context=\(context)")
			print("[CandidateDedup] duplicate capability=\(capability) lanes=\(lanes) policy=grouped kept=\(kept) dropped=none")
		}
	}

    // MARK: - Public API

    /// Evaluate all lanes and return ranked candidates.
    /// The caller should use the first result (if any) as the selected action.
    static func evaluate(
        frictionSignals: [FrictionSignal],
        mediaState: EnvironmentMediaState,
        semanticState: SemanticPriorityResolver.SemanticState?,
        entityGrounding: EntityGrounding?,
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        evidenceQuality: String,
        entityKey: String,
        appCategory: AppContextAnalyzer.Category? = nil,
        groundingResult: SemanticGroundingResult? = nil,
        activityState: ActivityState? = nil,
        lifecycleAudit: CandidateLifecycleAudit? = nil,
        funnelAudit: ProposalFunnelAudit? = nil
    ) async -> [PortfolioCandidate] {
        var candidates: [PortfolioCandidate] = []
        let noveltyTracker = OpportunityNoveltyTracker.shared

        // ── Grounded Lane Filtering ─────────────────────────────────────
        var allowedLanes: Set<PortfolioCandidate.Lane> = Set(PortfolioCandidate.Lane.allCases)
        if let gr = groundingResult {
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

        // ── Music lane ──────────────────────────────────────────────────
        if allowedLanes.contains(.music) {
            if let musicCandidate = await evaluateMusicLane(
                mediaState: mediaState,
                semanticState: semanticState,
                entityGrounding: entityGrounding,
                compartment: compartment,
                memory: memory,
                entityKey: entityKey,
                noveltyTracker: noveltyTracker,
                groundingResult: groundingResult,
                                lifecycleAudit: lifecycleAudit,
                funnelAudit: funnelAudit
            ) {
                candidates.append(musicCandidate)
            }

        } else {
			lifecycleAudit?.noteNotGenerated(candidate: "play_focus_media", bucket: "music", reason: "lane_forbidden_by_grounding")
            funnelAudit?.record(capabilityId: "play_focus_media", lane: "music", isSuppressed: true, reason: "lane_forbidden_by_grounding")
        }

        // ── Friction lane ───────────────────────────────────────────────
        if allowedLanes.contains(.friction) {
            let frictionCandidates = evaluateFrictionLane(
                frictionSignals: frictionSignals,
                memory: memory,
                compartment: compartment,
                entityKey: entityKey,
                noveltyTracker: noveltyTracker,
				lifecycleAudit: lifecycleAudit,
                funnelAudit: funnelAudit
            )
            candidates.append(contentsOf: frictionCandidates)
        } else {
			lifecycleAudit?.noteNotGenerated(candidate: "friction_lane", bucket: "friction", reason: "lane_forbidden_by_grounding")
            for capId in ["collect_references", "pin_reference_tabs", "arrange_side_by_side", "resume_focus_media", "extract_and_organize", "precompute_answer"] {
                funnelAudit?.record(capabilityId: capId, lane: "friction", isSuppressed: true, reason: "lane_forbidden_by_grounding")
            }
        }

        // ── Workspace lane ──────────────────────────────────────────────
        if allowedLanes.contains(.workspace) {
            if let workspaceCandidate = evaluateWorkspaceLane(
                compartment: compartment,
                memory: memory,
                entityKey: entityKey,
                noveltyTracker: noveltyTracker,
                activityState: activityState,
				lifecycleAudit: lifecycleAudit,
                funnelAudit: funnelAudit
            ) {
                candidates.append(workspaceCandidate)
            }
        } else {
			lifecycleAudit?.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: "lane_forbidden_by_grounding")
            funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: true, reason: "lane_forbidden_by_grounding")
        }

        // Phase 35.4: Metadata lane is always evaluated — not gated by grounding lanes.
        // Metadata-safe actions (copy_current_url, collect_references) are always panel-eligible
        // if evidence exists. Grounding gates are for cognitive/entertainment domains, not metadata.
        do {
            let metadataCandidates = evaluateMetadataLane(
                compartment: compartment,
                memory: memory,
                evidenceQuality: evidenceQuality,
                entityKey: entityKey,
                noveltyTracker: noveltyTracker,
                lifecycleAudit: lifecycleAudit,
                funnelAudit: funnelAudit
            )
            candidates.append(contentsOf: metadataCandidates)
        }

        // ── Cognitive / Research lane ────────────────────────────────────
        if allowedLanes.contains(.cognitive) || allowedLanes.contains(.research) {
            let cognitiveCandidates = evaluateCognitiveLane(
                semanticState: semanticState,
                entityGrounding: entityGrounding,
                compartment: compartment,
                memory: memory,
                evidenceQuality: evidenceQuality,
                entityKey: entityKey,
                appCategory: appCategory,
                noveltyTracker: noveltyTracker,
				lifecycleAudit: lifecycleAudit,
                funnelAudit: funnelAudit
            )
            candidates.append(contentsOf: cognitiveCandidates.filter { allowedLanes.contains($0.lane) })
        } else {
			lifecycleAudit?.noteNotGenerated(candidate: "synthesize_sources", bucket: "research", reason: "lane_forbidden_by_grounding")
			lifecycleAudit?.noteNotGenerated(candidate: "review_architecture", bucket: "coding", reason: "lane_forbidden_by_grounding")
            for capId in ["synthesize_sources", "compare_options", "decision_matrix", "generate_quiz", "create_review_plan", "diagnose_error", "create_checklist", "create_next_steps"] {
                funnelAudit?.record(capabilityId: capId, lane: "cognitive", isSuppressed: true, reason: "lane_forbidden_by_grounding")
            }
        }

        // ── Log all candidates ──────────────────────────────────────────
        let laneNames = Set(candidates.map { $0.lane.rawValue }).sorted().joined(separator: ",")
        print("[ActionPortfolio] lanes=\(laneNames.isEmpty ? "none" : laneNames)")

        for c in candidates {
			logCandidateIdentity(c)
			lifecycleAudit?.noteGenerated(
				candidate: lifecycleName(for: c.capabilityId, title: c.title),
				bucket: lifecycleBucket(for: c)
			)
            print("[ActionPortfolio] candidate"
                + " lane=\(c.lane.rawValue)"
                + " family=\(c.family.rawValue)"
                + " capability=\(c.capabilityId)"
                + " score=\(String(format: "%.3f", c.score))"
                + " usefulness=\(String(format: "%.2f", c.usefulness))"
                + " executability=\(String(format: "%.2f", c.executability))"
                + " confidence=\(String(format: "%.2f", c.confidence))"
                + " novelty=\(String(format: "%.2f", c.novelty))")
			print("[ActionHooks] candidate=\(c.capabilityId)"
				+ " family=\(c.family.rawValue)"
				+ " hook_chain=\(c.hookChain.joined(separator: "->"))"
				+ " expected_result=\"\(c.expectedResult)\""
				+ " failure_mode=\"\(c.failureMode)\"")
        }

        // ── Rank by composite score and usefulness ──────────────────────
        candidates.sort { a, b in
			ActionUsefulnessPolicy.compareUsefulnessAndScore(
				capA: a.capabilityId, laneA: a.lane.rawValue, scoreA: a.score,
				capB: b.capabilityId, laneB: b.lane.rawValue, scoreB: b.score
			)
		}

        // ── Suppress below threshold ────────────────────────────────────
        let viable = candidates.filter { $0.score >= qualityThreshold }
        let suppressed = candidates.filter { $0.score < qualityThreshold }

        for s in suppressed {
			lifecycleAudit?.noteRejected(
				candidate: lifecycleName(for: s.capabilityId, title: s.title),
				bucket: lifecycleBucket(for: s),
				reason: "below_quality_threshold"
			)
            print("[ActionPortfolio] suppressed"
                + " lane=\(s.lane.rawValue)"
                + " capability=\(s.capabilityId)"
                + " reason=below_quality_threshold"
                + " score=\(String(format: "%.3f", s.score))")
            funnelAudit?.recordRanking(s.capabilityId, lane: s.lane.rawValue, survived: false, reason: "below_quality_threshold_score_\(String(format: "%.3f", s.score))")
            funnelAudit?.recordSelection(s.capabilityId, lane: s.lane.rawValue, survived: false, reason: "suppressed_by_ranking")
        }

        for v in viable {
            funnelAudit?.recordRanking(v.capabilityId, lane: v.lane.rawValue, survived: true, reason: "score_\(String(format: "%.3f", v.score))")
        }

		let panelCandidates = candidates.filter { $0.executionMode == .local_action }
		for candidate in panelCandidates {
			let panelReason: String = {
				if candidate.lane == .metadata { return "metadata_safe_valid_payload" }
				if candidate.score < qualityThreshold { return "below_floating_threshold_but_valid" }
				return "valid_payload"
			}()
			print("[PanelCandidate] capability=\(candidate.capabilityId) lane=\(candidate.lane.rawValue) valid_payload=yes reason=\(panelReason)")
		}

		let preGateFamilyWinners = familyWinners(from: viable)
		for family in PortfolioCandidate.Family.allCases {
			if let winner = preGateFamilyWinners[family] {
				print("[FamilyWinner] family=\(family.rawValue) candidate=\(winner.capabilityId) title=\"\(winner.title.prefix(60))\" score=\(String(format: "%.3f", winner.score))")
			} else {
				print("[FamilyWinner] family=\(family.rawValue) candidate=none")
			}
		}

		// Phase 36.1 — Live path enforcement gate.
		// Surface policy decides what may float. Family winner by score alone is not sufficient.
		let contextStability: String = {
			if compartment != nil && !memory.currentEntity.isEmpty { return "stable" }
			if memory.currentEntity.isEmpty && compartment == nil { return "weak" }
			return "transient"
		}()
		let hasHigherPriorityTaskAction = viable.contains { c in
			let isTaskFamily = (c.family == .workspace || c.family == .media || c.family == .writing || c.family == .coding)
			let isNotExcludedMedia = c.capabilityId != "play_focus_media" && c.capabilityId != "resume_focus_media"
			let isNotMetadata = !LivePathEnforcer.metadataUtilities.contains(c.capabilityId)
			let isNotPinTabs = c.capabilityId != "pin_reference_tabs"
			let isHighQuality = c.score >= qualityThreshold
			return isTaskFamily && isNotExcludedMedia && isNotMetadata && isNotPinTabs && isHighQuality
		}
		logDuplicateCapabilities(viable, context: "action_portfolio_live_path")
		let enforcedSurface: [String: LivePathDecision] = Dictionary(uniqueKeysWithValues: viable.map { c in
			let ctx = LivePathEvaluationContext(
				sourcePath: c.sourcePath,
				contextStability: contextStability,
				isMusicAlreadyPlaying: mediaState.isMusicPlaying,
				hasHigherPriorityTaskAction: hasHigherPriorityTaskAction,
				recentFeedbackCooldownActive: false,
				userFeedbackHistory: "neutral",
				alreadySatisfied: false,
				evidenceAvailable: c.usefulness > 0.0,
				hasExplicitUsageSignal: false,
				activityMatch: true,
				compartmentLabel: compartment?.label,
				currentEntity: memory.currentEntity,
				workflow: compartment?.workflow.rawValue ?? ""
			)
			let (decision, _) = LivePathEnforcer.evaluate(
				capabilityID: c.capabilityId,
				involvedApps: c.involvedApps,
				attachedContract: c.targetContract,
				confidence: c.confidence,
				evaluationContext: ctx
			)
			decision.logEnforcement(candidateID: c.candidateID, lane: c.lane.rawValue)
			return (c.candidateID, decision)
		})

		let floatingEligible = viable.filter { c in
			(enforcedSurface[c.candidateID]?.eligibleForFloating ?? false)
		}
		
		// Log FinalSelection for each candidate
		for c in viable {
			let decision = enforcedSurface[c.candidateID]
			let surface = decision?.surface.rawValue ?? "unknown"
			let usefulness = ActionUsefulnessPolicy.getUsefulnessLevel(capabilityID: c.capabilityId, lane: c.lane.rawValue)
			let reason = decision?.reason ?? "unknown"
			print("[FinalSelection] candidate=\(c.capabilityId) usefulness=\(usefulness) surface=\(surface) reason=\(reason)")
		}

		let postGateFamilyWinners = familyWinners(from: floatingEligible)
		let finalCandidates = orderedCandidatesForFinalSelection(viable: floatingEligible, familyWinners: postGateFamilyWinners)

		var selectedCandidate: PortfolioCandidate? = finalCandidates.first
		let topScored = viable.first
		
		if let top = topScored,
		   enforcedSurface[top.candidateID]?.eligibleForFloating != true {
			print("[FinalSelection] candidate_id=\(top.candidateID) capability=\(top.capabilityId) lane=\(top.lane.rawValue) surface=\(enforcedSurface[top.candidateID]?.surface.rawValue ?? "unknown") eligible_for_floating=no reason=\(enforcedSurface[top.candidateID]?.reason ?? "policy")")
			print("[FinalSelection] backfill_attempt started reason=winner_suppressed")
			if let backfill = finalCandidates.first {
				if backfill.capabilityId == "arrange_side_by_side" {
					print("[FinalSelection] backfill_candidate=arrange_side_by_side requirement_pass=yes")
				}
				print("[FinalSelection] backfill_winner=\(backfill.capabilityId) reason=winner_suppressed_backfill")
				selectedCandidate = backfill
			} else {
				let wasArrangeCandidate = viable.first(where: { $0.capabilityId == "arrange_side_by_side" })
				if let arrangeCandidate = wasArrangeCandidate, enforcedSurface[arrangeCandidate.candidateID]?.eligibleForFloating != true {
					let decisionReason = enforcedSurface[arrangeCandidate.candidateID]?.reason ?? "unknown"
					print("[FinalSelection] backfill_candidate=arrange_side_by_side requirement_pass=no reason=\(decisionReason)")
					print("[FinalSelection] backfill_rejected capability=arrange_side_by_side reason=requirements_failed")
				}
				print("[FinalSelection] backfill_winner=none reason=winner_suppressed_no_backfill_available")
				print("[FinalSelection] no_floating_winner reason=no_action_requirements_passed")
			}
		}

		let visibleCount = (selectedCandidate != nil ? 1 : 0) + panelCandidates.filter({ $0.candidateID != selectedCandidate?.candidateID }).count
		let totalEligible = viable.count
		let utilityCount = viable.filter { LivePathEnforcer.metadataUtilities.contains($0.capabilityId) }.count
		let nonUtilityCount = totalEligible - utilityCount
		print("[UsefulActionInventory] total=\(totalEligible) utility_count=\(utilityCount) non_utility_count=\(nonUtilityCount)")

        if let selected = selectedCandidate {
            print("[ActionPortfolio] selected"
                + " lane=\(selected.lane.rawValue)"
                + " family=\(selected.family.rawValue)"
                + " capability=\(selected.capabilityId)"
                + " title=\"\(selected.title.prefix(60))\""
                + " score=\(String(format: "%.3f", selected.score))")
			print("[FinalSelection] winner=\(selected.capabilityId)"
				+ " family=\(selected.family.rawValue)"
				+ " reason=highest_family_winner_score")
			print("[FinalSelection] candidate_id=\(selected.candidateID) capability=\(selected.capabilityId) lane=\(selected.lane.rawValue) surface=\(enforcedSurface[selected.candidateID]?.surface.rawValue ?? "unknown") eligible_for_floating=\(enforcedSurface[selected.candidateID]?.eligibleForFloating == true ? "yes" : "no")")
            
            for v in viable {
                if v.capabilityId == selected.capabilityId {
                    funnelAudit?.recordSelection(v.capabilityId, lane: v.lane.rawValue, survived: true, reason: "portfolio_winner")
                } else {
                    funnelAudit?.recordSelection(v.capabilityId, lane: v.lane.rawValue, survived: false, reason: "lost_to_\(selected.capabilityId)")
                }
			}
			print("[ActionPortfolioResult] floating=\(selected.capabilityId) panel_count=\(panelCandidates.count) suppressed_count=\(suppressed.count)")
			print("[UsefulActionInventory] chosen=\(selected.capabilityId) visible_count=\(visibleCount)")
			enforcedSurface[selected.candidateID]?.logVisible(candidateID: selected.candidateID, lane: selected.lane.rawValue)
        } else {
            print("[ActionPortfolio] selected=none reason=no_viable_floating_candidates")
			print("[FinalSelection] winner=none reason=no_viable_floating_candidates")
			print("[ActionPortfolioResult] floating=none panel_count=\(panelCandidates.count) suppressed_count=\(suppressed.count)")
			print("[UsefulActionInventory] chosen=none visible_count=\(visibleCount)")
        }
		// Emit VisibleActionPath for every panel candidate so dogfood logs show the live path.
		for pc in panelCandidates {
			enforcedSurface[pc.candidateID]?.logVisible(candidateID: pc.candidateID, lane: pc.lane.rawValue)
		}

        // ── Selection Audit ─────────────────────────────────────────────
        let allSorted = candidates
        let c1 = allSorted.count > 0 ? "\(allSorted[0].capabilityId) (\(allSorted[0].title))" : "none"
        let s1 = allSorted.count > 0 ? String(format: "%.3f", allSorted[0].score) : "0.000"
        let c2 = allSorted.count > 1 ? "\(allSorted[1].capabilityId) (\(allSorted[1].title))" : "none"
        let s2 = allSorted.count > 1 ? String(format: "%.3f", allSorted[1].score) : "0.000"
        let c3 = allSorted.count > 2 ? "\(allSorted[2].capabilityId) (\(allSorted[2].title))" : "none"
        let s3 = allSorted.count > 2 ? String(format: "%.3f", allSorted[2].score) : "0.000"
        let winner = viable.first?.capabilityId ?? "none"

        print("[SelectionAudit]\n"
            + "candidate_1=\(c1)\n"
            + "score=\(s1)\n"
            + "\n"
            + "candidate_2=\(c2)\n"
            + "score=\(s2)\n"
            + "\n"
            + "candidate_3=\(c3)\n"
            + "score=\(s3)\n"
            + "\n"
            + "winner=\(winner)")

        return finalCandidates
    }

    // MARK: - Music lane

    private static func evaluateMusicLane(
        mediaState: EnvironmentMediaState,
        semanticState: SemanticPriorityResolver.SemanticState?,
        entityGrounding: EntityGrounding?,
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        entityKey: String,
        noveltyTracker: OpportunityNoveltyTracker,
        groundingResult: SemanticGroundingResult? = nil,
        lifecycleAudit: CandidateLifecycleAudit? = nil,
        funnelAudit: ProposalFunnelAudit? = nil
    ) async -> PortfolioCandidate? {
        let isWatching = (semanticState?.domain == .watching)
            || (entityGrounding?.isEntertainment == true)
            || (compartment?.workflow == .watching)
            || (groundingResult?.domain.lowercased().contains("watching") == true)
            || (groundingResult?.domain.lowercased().contains("entertainment") == true)

        let eligible = ActionUsefulnessPolicy.evaluateMediaUsefulness(
            capabilityID: "play_focus_media",
            mediaState: mediaState,
            isWatching: isWatching
        )
        guard eligible else {
			lifecycleAudit?.noteNotGenerated(candidate: "play_focus_media", bucket: "music", reason: "foreground_media_or_playing")
            if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .debug) {
                print("[MusicAudit] eligible=no reason=foreground_media_or_playing media_playing=no candidate_generated=no")
            }
            funnelAudit?.record(capabilityId: "play_focus_media", lane: "music", isSuppressed: true, reason: "foreground_media_or_playing")
			return nil
		}

        // Need some work context (not idle/empty)
        guard !memory.currentEntity.isEmpty || compartment != nil || groundingResult != nil else {
			lifecycleAudit?.noteNotGenerated(candidate: "play_focus_media", bucket: "music", reason: "no_work_context")
            if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .debug) {
                print("[MusicAudit] eligible=no reason=no_work_context media_playing=no candidate_generated=no")
            }
            funnelAudit?.record(capabilityId: "play_focus_media", lane: "music", isSuppressed: true, reason: "no_work_context")
			return nil
		}

        let domain = resolveMusicDomain(
            semanticState: semanticState,
            entityGrounding: entityGrounding,
            compartment: compartment,
            groundingResult: groundingResult
        )

        let playlist = PlaylistMemory.shared.suggest(compartment: compartment, workflow: compartment?.workflow ?? .unknown)
        let canPlayDirectly = await MusicExecutor.checkLocalPlaylist(query: playlist ?? domain.query)

        let title = musicTitle(
            domain: domain,
            compartment: compartment,
            memory: memory,
            groundingResult: groundingResult,
            canPlayDirectly: canPlayDirectly
        )
        let novelty = noveltyTracker.noveltyScore(capabilityId: "play_focus_media", entityKey: entityKey)
		if novelty < 0.20 {
			lifecycleAudit?.noteRejected(candidate: "play_focus_media", bucket: "music", reason: "recently_dismissed")
			print("[MusicLane] rejected reason=recently_dismissed")
			return nil
		}

        let action: MusicIntent.Action = {
            if playlist != nil { return .playPlaylist }
            return .resume
        }()

        // Phase 28.2: Search actions are low priority — user doesn't want Apple Music search opening.
        // Resume and play_playlist are high value. Search is last resort but still above threshold.
        let usefulness: Double = {
            if action == .search { return 0.25 } // Low — search rarely wins but still viable
            if compartment?.dwellState == .deep_work { return 0.75 }
            if compartment?.dwellSeconds ?? 0 > 120 { return 0.60 }
            if groundingResult?.confidence ?? 0 >= 0.80 { return 0.55 }
            return 0.40
        }()

        if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .trace) {
            print("[MusicIntent] domain_source=\(domain.source) selected_domain=\(domain.name)")
            print("[MusicTitle] title=\"\(title)\"")
            print("[MusicActionIdentity] title_action=\(action.rawValue) executor_action=\(action.rawValue) ok=yes")
        }

        if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .debug) {
            print("[MusicAudit] eligible=yes reason=none media_playing=no playlist_memory_match=\(playlist != nil ? "yes" : "no") playlist=\(playlist ?? "none") candidate_generated=yes action=\(action.rawValue)")
        }
        funnelAudit?.record(capabilityId: "play_focus_media", lane: "music", isSuppressed: false, reason: "generated")

        let involvedApps: [String] = {
            // Determine likely player app based on what's installed or default
            return ["Music"] // Defaulting to Music.app for now
        }()

        return PortfolioCandidate(
            lane: .music,
            title: title,
            capabilityId: "play_focus_media",
            executionMode: .local_action,
            // Phase 28.2: Confidence floor for music. If grounding is unknown/0, music
            // still has baseline confidence when user is active and no media is playing.
            confidence: max(0.35, groundingResult?.confidence ?? 0.70),
            usefulness: usefulness,
            executability: 0.90,  // can actually play music
            novelty: novelty,
            reason: "No music playing during work context",
            requiredEvidence: "none",
            requiresConfirmation: true,
            involvedApps: involvedApps,
            frictionOpportunity: nil,
            musicIntent: MusicIntent(
                taskDomain: domain.name,
                mood: domain.mood,
                query: domain.query,
                playlistName: playlist,
                action: action
            ),
            generatedAction: nil
        )
    }

    struct MusicDomain {
        let name: String
        let mood: MusicIntent.Mood
        let query: String
        let source: String
    }

    /// Resolve music domain from entity grounding > compartment > workflow inference.
    /// Prevents "focus focus" by never using "focus" as domain when mood is also focus.
    static func resolveMusicDomain(
        semanticState: SemanticPriorityResolver.SemanticState?,
        entityGrounding: EntityGrounding?,
        compartment: TaskCompartment?,
        groundingResult: SemanticGroundingResult? = nil
    ) -> MusicDomain {

        let mood: MusicIntent.Mood = {
            if compartment?.dwellState == .deep_work { return .deepWork }
            return .focus
        }()

        // Priority 0: Semantic grounding result (new grounded engine)
        if let gr = groundingResult, gr.confidence >= 0.70 {
            let domain = domainName(fromGrounded: gr.domain)
            return MusicDomain(
                name: domain, mood: mood,
                query: "\(domain) \(mood == .deepWork ? "deep work" : "instrumental") music",
                source: "semantic_grounding"
            )
        }

        // Priority 1: Entity grounding
        if let grounding = entityGrounding, grounding.confidence >= 0.50 {
            let domain = domainName(for: grounding.entityType)
            return MusicDomain(
                name: domain, mood: mood,
                query: "\(domain) \(mood == .deepWork ? "deep work" : "instrumental") music",
                source: "entity_grounding"
            )
        }

        // Priority 2: Active compartment
        if let comp = compartment, !comp.label.isEmpty {
            let compWorkflow = comp.workflow
            if compWorkflow != .unknown && compWorkflow != .idle {
                let domain = domainName(for: compWorkflow)
                return MusicDomain(
                    name: domain, mood: mood,
                    query: "\(domain) \(mood == .deepWork ? "deep work" : "instrumental") music",
                    source: "active_compartment"
                )
            }
        }

        // Priority 3: Semantic state
        if let ss = semanticState {
            let domain = domainName(for: ss.domain)
            return MusicDomain(
                name: domain, mood: mood,
                query: "\(domain) \(mood == .deepWork ? "deep work" : "instrumental") music",
                source: "semantic_state"
            )
        }

        // Fallback: generic instrumental
        return MusicDomain(
            name: "instrumental", mood: mood,
            query: "instrumental \(mood == .deepWork ? "deep work" : "focus") music",
            source: "fallback"
        )
    }

    private static func domainName(fromGrounded domain: String) -> String {
        let d = domain.lowercased()
        if d.contains("coding") { return "coding" }
        if d.contains("design") || d.contains("creative") { return "creative" }
        if d.contains("study") || d.contains("studying") { return "study" }
        if d.contains("research") { return "research" }
        return "background"
    }

    /// Map entity type → music domain string (never "focus")
    private static func domainName(for entityType: EntityGrounding.EntityType) -> String {
        switch entityType {
        case .game:              return "creative coding"
        case .code_project:      return "coding"
        case .course_material:   return "study"
        case .document:          return "research"
        case .music_app:         return "music"
        default:                 return "instrumental"
        }
    }

    private static func domainName(for workflow: AmbientWorkflowType) -> String {
        switch workflow {
        case .coding, .debugging:    return "coding"
        case .designing:             return "creative"
        case .studying:              return "study"
        case .researching:           return "research"
        default:                     return "background"
        }
    }

    private static func domainName(for domain: DeterminerSignal.Domain) -> String {
        switch domain {
        case .coding, .creative_coding: return "coding"
        case .studying:                 return "study"
        case .researching:              return "research"
        case .shopping:                 return "browsing"
        default:                        return "background"
        }
    }

    private static func musicTitle(
        domain: MusicDomain,
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        groundingResult: SemanticGroundingResult? = nil,
        canPlayDirectly: Bool
    ) -> String {
        let learned = PlaylistMemory.shared.suggest(compartment: compartment, workflow: compartment?.workflow ?? .unknown)
        if let p = learned {
            let label = groundingResult?.entityName ?? compartment?.label ?? memory.currentEntity
            let shortLabel = String(label.prefix(40)).trimmingCharacters(in: .whitespaces)
            if !shortLabel.isEmpty {
                return "Play your \(p) playlist while you work on \(shortLabel)?"
            }
            return "Play your \(p) playlist?"
        }
        if canPlayDirectly {
            return "Resume your music?"
        }
        return "Play a local playlist?"
    }

    // MARK: - Friction lane

    private static func evaluateFrictionLane(
        frictionSignals: [FrictionSignal],
        memory: WorkingMemorySnapshot,
        compartment: TaskCompartment?,
        entityKey: String,
        noveltyTracker: OpportunityNoveltyTracker,
        lifecycleAudit: CandidateLifecycleAudit? = nil,
        funnelAudit: ProposalFunnelAudit? = nil
    ) -> [PortfolioCandidate] {
		let workspaceHistory = WorkspacePatternTracker.shared.knownPatterns().count
		let tabSwitchPattern = memory.comparisonCandidates.count
		let appPairPattern = Set(memory.relatedFocusEntities.prefix(2)).count
		var heuristicCandidates: [PortfolioCandidate] = []
        if frictionSignals.isEmpty {
			heuristicCandidates = heuristicFrictionCandidates(
				memory: memory,
				compartment: compartment,
				entityKey: entityKey,
				noveltyTracker: noveltyTracker
			)
			if heuristicCandidates.isEmpty {
				lifecycleAudit?.noteNotGenerated(candidate: "friction_lane", bucket: "friction", reason: "no_friction_signal")
				for capId in ["collect_references", "pin_reference_tabs", "arrange_side_by_side", "resume_focus_media", "extract_and_organize", "precompute_answer"] {
					funnelAudit?.record(capabilityId: capId, lane: "friction", isSuppressed: true, reason: "no_friction_signal")
				}
				print("[FrictionSuggestionFamily] workspace_history=\(workspaceHistory) tab_switch_pattern=\(tabSwitchPattern) app_pair_pattern=\(appPairPattern) candidates=none selected=none")
				return []
			}
		}

        let currentApps: Set<String> = Set([memory.currentEntity])
        let workspacePatterns = WorkspacePatternTracker.shared.knownPatterns()
		let explicitCandidates: [PortfolioCandidate] = FrictionOpportunityReasoner.reason(
			frictionSignals: frictionSignals,
			workspacePatterns: workspacePatterns,
			currentApps: currentApps,
			currentEntity: memory.currentEntity,
			compartmentLabel: ""
		).map { opp -> PortfolioCandidate in
            let novelty = noveltyTracker.noveltyScore(capabilityId: opp.capabilityId, entityKey: entityKey)

            // Friction usefulness scales with confidence
            let usefulness = min(0.90, opp.confidence * 0.95)

            // Environment actions are fully executable; text fallbacks are less so
            let executability: Double = opp.requiresConfirmation ? 0.85 : 0.90

            return PortfolioCandidate(
                lane: .friction,
                title: opp.title,
                capabilityId: opp.capabilityId,
                executionMode: .local_action,
                confidence: opp.confidence,
                usefulness: usefulness,
                executability: executability,
                novelty: novelty,
                reason: opp.frictionRemoved,
                requiredEvidence: "none",
                requiresConfirmation: opp.requiresConfirmation,
                involvedApps: opp.involvedApps,
                frictionOpportunity: opp,
                musicIntent: nil,
                generatedAction: nil
            )
        }
		let mapped = explicitCandidates + heuristicCandidates
        for m in mapped {
            funnelAudit?.record(capabilityId: m.capabilityId, lane: "friction", isSuppressed: false, reason: "generated")
        }
		let candidateList = mapped.map(\.capabilityId).joined(separator: ",")
		let selectedId = mapped.sorted { $0.score > $1.score }.first?.capabilityId ?? "none"
		print("[FrictionSuggestionFamily] workspace_history=\(workspaceHistory) tab_switch_pattern=\(tabSwitchPattern) app_pair_pattern=\(appPairPattern) candidates=\(candidateList.isEmpty ? "none" : candidateList) selected=\(selectedId)")
        return mapped
    }

    // MARK: - Workspace lane

    private static func evaluateWorkspaceLane(
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        entityKey: String,
        noveltyTracker: OpportunityNoveltyTracker,
        activityState: ActivityState? = nil,
		lifecycleAudit: CandidateLifecycleAudit? = nil,
        funnelAudit: ProposalFunnelAudit? = nil
    ) -> PortfolioCandidate? {
        let inventory = WorkspaceRuntimeInventoryProvider.snapshot()
        let currentApps: Set<String> = Set(inventory.runningApps.map(\.appName).filter { !$0.isEmpty })
        guard let pattern = DurableMemory.shared.bestDurableWorkspacePattern(
            workflow: compartment?.workflow.rawValue ?? "unknown",
            compartment: compartment?.label,
            currentApps: currentApps
        ) else {
			lifecycleAudit?.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: "insufficient_history")
            print("[ProposalFunnelAudit] not_generated capability=restore_workspace reason=no_missing_durable_workspace")
            funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: true, reason: "insufficient_history")
			return nil
		}
        let missing = DurableMemory.shared.missingCheck(pattern: pattern, currentApps: currentApps, currentURLs: inventory.currentURLs)
        if activityState?.state == .typing {
            lifecycleAudit?.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: "user_typing")
            print("[ProposalFunnelAudit] not_generated capability=restore_workspace reason=user_typing")
            funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: true, reason: "user_typing")
            print("[WorkspaceRestoreGate] can_restore=no reason=user_typing")
            return nil
        }
        if DurableMemory.shared.shouldSuppressRestoreSuggestion(restoreKey: missing.restoreKey) {
            lifecycleAudit?.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: "recently_ignored")
            print("[ProposalFunnelAudit] not_generated capability=restore_workspace reason=recently_ignored")
            funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: true, reason: "recently_ignored")
            return nil
        }
        guard missing.canRestore else {
			lifecycleAudit?.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: missing.reason == "items_present_backgrounded" ? "workspace_items_backgrounded" : "workspace_already_restored")
            print("[ProposalFunnelAudit] not_generated capability=restore_workspace reason=workspace_items_present")
            funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: true, reason: missing.reason)
			return nil
		}

        let title = "Open your usual \(pattern.apps.prefix(3).map(\.appName).joined(separator: " + ")) setup?"
        let novelty = noveltyTracker.noveltyScore(capabilityId: "restore_workspace", entityKey: entityKey)

        print("[ProposalFunnelAudit] generated capability=restore_workspace reason=missing_durable_items")
        funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: false, reason: "generated")

        return PortfolioCandidate(
            lane: .workspace,
            title: title,
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

    private static func evaluateMetadataLane(
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        evidenceQuality: String,
        entityKey: String,
        noveltyTracker: OpportunityNoveltyTracker,
        lifecycleAudit: CandidateLifecycleAudit? = nil,
        funnelAudit: ProposalFunnelAudit? = nil
    ) -> [PortfolioCandidate] {
        let evidenceLevel = EvidenceQualityModel.level(from: evidenceQuality)
        guard evidenceLevel.rank >= ProgressiveEvidenceLevel.metadata_rich.rank else {
            for capabilityId in ["copy_current_url", "collect_references", "remember_workspace", "open_current_task_panel"] {
                lifecycleAudit?.noteNotGenerated(candidate: capabilityId, bucket: "metadata", reason: "insufficient_context")
                funnelAudit?.record(capabilityId: capabilityId, lane: "metadata", isSuppressed: true, reason: "insufficient_context")
            }
            return []
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let browserContext = BrowserContextExtractor.extract(appName: frontmostApp, activeAppPID: nil)
        let currentURL = browserContext?.selectedURL?.absoluteString ?? browserContext?.currentURL?.absoluteString
        let tabTitles = browserContext?.recentTabTitles ?? compartment?.browserTabs.sorted() ?? []
        let browserAssessment = BrowserContextStrategy.assess(
            title: browserContext?.selectedTitle ?? memory.currentEntity,
            url: currentURL.flatMap(URL.init(string:)),
            tabTitles: tabTitles,
            hasAXText: false,
            hasOCR: false
        )

        var candidates: [PortfolioCandidate] = []
        let currentApps = Set(WorkspaceRuntimeInventoryProvider.snapshot().runningApps.map(\.appName))
        let hasDurablePattern = DurableMemory.shared.bestDurableWorkspacePattern(
            workflow: compartment?.workflow.rawValue ?? "unknown",
            compartment: compartment?.label,
            currentApps: currentApps
        ) != nil

        func appendMetadataCandidate(
            capabilityId: String,
            title: String,
            usefulness: Double,
            reason: String,
            requiresConfirmation: Bool = false
        ) {
            let eligibility = ActionRegistry.evaluate(
                capabilityId: capabilityId,
                currentEvidence: evidenceLevel,
                hasURLs: currentURL != nil,
                hasSelection: false
            )
            guard eligibility.eligible else {
                lifecycleAudit?.noteNotGenerated(candidate: capabilityId, bucket: "metadata", reason: eligibility.reason)
                funnelAudit?.record(capabilityId: capabilityId, lane: "metadata", isSuppressed: true, reason: eligibility.reason)
                return
            }
            lifecycleAudit?.noteGenerated(candidate: capabilityId, bucket: "metadata", reason: "generated")
            funnelAudit?.record(capabilityId: capabilityId, lane: "metadata", isSuppressed: false, reason: "generated")
            candidates.append(PortfolioCandidate(
                lane: .metadata,
                title: title,
                capabilityId: capabilityId,
                executionMode: capabilityId == "open_current_task_panel" ? .local_action : .local_action,
                confidence: 0.56,
                usefulness: usefulness,
                executability: 0.88,
                novelty: noveltyTracker.noveltyScore(capabilityId: capabilityId, entityKey: entityKey),
                reason: reason,
                requiredEvidence: ProgressiveEvidenceLevel.metadata_rich.rawValue,
                requiresConfirmation: requiresConfirmation,
                involvedApps: [],
                frictionOpportunity: nil,
                musicIntent: nil,
                generatedAction: nil
            ))
            print("[ActionPortfolio] candidate lane=metadata capability=\(capabilityId)")
        }

        if browserAssessment.safeActions.contains("copy_current_url"), let currentURL, !currentURL.isEmpty {
            appendMetadataCandidate(
                capabilityId: "copy_current_url",
                title: "Copy this page link?",
                usefulness: 0.30,
                reason: "Current browser URL is available from metadata-safe context"
            )
        } else {
            lifecycleAudit?.noteNotGenerated(candidate: "copy_current_url", bucket: "metadata", reason: "missing_current_url")
        }

        if browserAssessment.safeActions.contains("collect_references"), let currentURL, !currentURL.isEmpty {
            appendMetadataCandidate(
                capabilityId: "collect_references",
                title: "Collect links from this context?",
                usefulness: 0.26,
                reason: "Metadata-rich browser context exposes at least one URL"
            )
        } else {
            lifecycleAudit?.noteNotGenerated(candidate: "collect_references", bucket: "metadata", reason: "missing_url_context")
        }

        if browserAssessment.safeActions.contains("remember_workspace"), !hasDurablePattern {
            appendMetadataCandidate(
                capabilityId: "remember_workspace",
                title: "Remember this workspace?",
                usefulness: 0.20,
                reason: "Current metadata-rich context is not yet durable"
            )
        } else {
            lifecycleAudit?.noteNotGenerated(candidate: "remember_workspace", bucket: "metadata", reason: hasDurablePattern ? "already_durable" : "not_metadata_safe")
        }

        if browserAssessment.safeActions.contains("open_current_task_panel"), candidates.isEmpty {
            appendMetadataCandidate(
                capabilityId: "open_current_task_panel",
                title: "Open the current task panel?",
                usefulness: 0.16,
                reason: "Trusted metadata context exists but no stronger direct metadata action is available"
            )
        } else if !browserAssessment.safeActions.contains("open_current_task_panel") {
            lifecycleAudit?.noteNotGenerated(candidate: "open_current_task_panel", bucket: "metadata", reason: "not_metadata_safe")
        } else {
            lifecycleAudit?.noteNotGenerated(candidate: "open_current_task_panel", bucket: "metadata", reason: "stronger_metadata_action_exists")
        }

        return candidates
    }

    // MARK: - Cognitive / Research lane

    private static func evaluateCognitiveLane(
        semanticState: SemanticPriorityResolver.SemanticState?,
        entityGrounding: EntityGrounding?,
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        evidenceQuality: String,
        entityKey: String,
        appCategory: AppContextAnalyzer.Category?,
        noveltyTracker: OpportunityNoveltyTracker,
		lifecycleAudit: CandidateLifecycleAudit? = nil,
        funnelAudit: ProposalFunnelAudit? = nil
    ) -> [PortfolioCandidate] {
        var results: [PortfolioCandidate] = []
        let evidenceLevel = EvidenceQualityModel.level(from: evidenceQuality)

        let domain = semanticState?.domain ?? .unknown
        let entityType = entityGrounding?.entityType ?? semanticState?.entityType ?? .unknown
        let hasRealContent = evidenceLevel.rank >= ProgressiveEvidenceLevel.visible_content.rank
        let isEditorContext = evidenceQuality == "editor_context"
        let hasSources = memory.relatedFocusEntities.count >= 2 || evidenceLevel.rank >= ProgressiveEvidenceLevel.metadata_rich.rank
        let hasComparison = memory.comparisonCandidates.count >= 2
        let entity = memory.currentEntity

        let errorTerms: Set<String> = ["error","exception","crash","failed","bug",
                                        "issue","broken","stack","trace","warning","undefined"]
        let hasErrors = !Set(memory.repeatedConcepts.map { $0.lowercased() }).intersection(errorTerms).isEmpty

        // Phase 26.4 — Gating check
        let isEntertainment = (entityGrounding?.isEntertainment == true)
            || (semanticState?.entityType == .tv_show || semanticState?.entityType == .youtube_video || semanticState?.entityType == .streaming_site)
        let isNewTab = memory.currentEntity.lowercased().contains("new tab") || memory.currentEntity.lowercased().contains("blank")
        let hasRealEvidence = evidenceLevel.rank >= ProgressiveEvidenceLevel.visible_content.rank || isEditorContext
        let isErrorContext = hasErrors && (hasRealContent || isEditorContext)

        let isCoding = (domain == .coding || domain == .creative_coding)

        let allCognitiveCapIds = ["review_architecture", "plan_next_steps", "suggest_refactor", "synthesize_sources", "compare_options", "diagnose_error", "generate_quiz"]

        // Phase 27.3 — Editor context: coding contexts produce workflow-level
        // actions (architecture review, planning, refactoring) without requiring
        // file-content evidence. They do NOT produce file-content actions
        // (explain exact code, quiz, diagnose without error terms).
        if isCoding && isEditorContext && !isEntertainment && !isNewTab {
            let editorCandidates = evaluateEditorCodingLane(
                compartment: compartment,
                memory: memory,
                evidenceQuality: evidenceQuality,
                entityKey: entityKey,
                hasErrors: hasErrors,
                noveltyTracker: noveltyTracker,
				lifecycleAudit: lifecycleAudit,
                funnelAudit: funnelAudit
            )
            results.append(contentsOf: editorCandidates)
            if !editorCandidates.isEmpty {
                print("[CognitiveLane] editor_context_candidates=\(editorCandidates.count)")
            }
        }

        // Hard suppress for coding with only title_only (no editor_context upgrade)
        if isCoding && !hasRealEvidence && !isEditorContext && !hasComparison && !isErrorContext {
			lifecycleAudit?.noteRejected(candidate: "review_architecture", bucket: "coding", reason: "title_only")
            print("[CognitiveLane] suppressed reason=evidence_level_requires_content evidence_level=\(evidenceLevel.rawValue)")
            for capId in allCognitiveCapIds {
                funnelAudit?.record(capabilityId: capId, lane: "cognitive", isSuppressed: true, reason: "coding_title_only_too_weak")
            }
            return results
        }

        if isEntertainment || isNewTab {
			lifecycleAudit?.noteRejected(candidate: "synthesize_sources", bucket: "research", reason: "entertainment_or_blank")
			lifecycleAudit?.noteRejected(candidate: "review_architecture", bucket: "coding", reason: "entertainment_or_blank")
            print("[CognitiveLane] suppressed reason=entertainment_or_blank")
            for capId in allCognitiveCapIds {
                funnelAudit?.record(capabilityId: capId, lane: "cognitive", isSuppressed: true, reason: "entertainment_or_blank")
            }
            return results
        }

        if !hasRealEvidence && !isEditorContext && !isErrorContext {
			lifecycleAudit?.noteRejected(candidate: "synthesize_sources", bucket: "research", reason: "title_only")
            print("[CognitiveLane] suppressed reason=evidence_level_requires_content evidence_level=\(evidenceLevel.rawValue)")
            for capId in allCognitiveCapIds {
                funnelAudit?.record(capabilityId: capId, lane: "cognitive", isSuppressed: true, reason: "insufficient_evidence_title_only")
            }
            return results
        }

		let rentalCandidates = rentalResearchCandidates(
			memory: memory,
			evidenceQuality: evidenceQuality,
			entityKey: entityKey,
			noveltyTracker: noveltyTracker
		)
		if !rentalCandidates.isEmpty {
			results.append(contentsOf: rentalCandidates)
			for candidate in rentalCandidates {
				funnelAudit?.record(capabilityId: candidate.capabilityId, lane: "research", isSuppressed: false, reason: "generated")
			}
			let candidateIds = rentalCandidates.map(\.capabilityId).joined(separator: ",")
			let selectedId = rentalCandidates.sorted { $0.score > $1.score }.first?.capabilityId ?? "none"
			print("[TextSuggestionFamily] domain=rental_research candidates=\(candidateIds) selected=\(selectedId)")
		}

        // Text action executability scales with evidence quality
        let textExecutability: Double = {
            switch evidenceLevel {
            case .none, .metadata_only: return 0.28
            case .metadata_rich: return 0.40
            case .visible_content: return 0.60
            case .selected_content: return 0.70
            case .full_content: return 0.80
            }
        }()
        print("[TextActionGrounding] grounded_facts_estimate=\(evidenceLevel.rank >= ProgressiveEvidenceLevel.visible_content.rank ? 1 : 0) priority=\(textExecutability < 0.50 ? "low" : "normal")")

        // Research: synthesize when multiple real sources
        // Phase 28.2: Entity-aware research titles — never use generic "collect references" wording
        if hasSources && hasRealContent {
            let capId = "synthesize_sources"
            let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: entityKey)
            let researchTitle = Self.researchTitle(entity: entity, sources: memory.relatedFocusEntities, hasComparison: hasComparison)
            results.append(PortfolioCandidate(
                lane: .research,
                title: researchTitle,
                capabilityId: capId,
                executionMode: .preview_only,
                confidence: 0.75,
                usefulness: 0.80,
                executability: textExecutability,
                novelty: novelty,
                reason: "Multiple sources open with real content",
                requiredEvidence: evidenceQuality,
                requiresConfirmation: false,
                involvedApps: [],
                frictionOpportunity: nil,
                musicIntent: nil,
                generatedAction: nil
            ))
            print("[CognitiveLane] eligible=yes reason=multiple_sources_real_content capability=synthesize_sources")
            funnelAudit?.record(capabilityId: "synthesize_sources", lane: "research", isSuppressed: false, reason: "generated")
        } else {
			lifecycleAudit?.noteNotGenerated(candidate: "synthesize_sources", bucket: "research", reason: "no_sources")
            funnelAudit?.record(capabilityId: "synthesize_sources", lane: "research", isSuppressed: true, reason: "no_sources")
        }

        // Promote related/stale/tab entities to comparison candidates when they share terms
        let compartmentTabs = (compartment?.browserTabs ?? []).filter {
            $0 != memory.currentEntity && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let staleWithSharedTerms = memory.staleEntities.filter { stale in
            shareSignificantTerms(memory.currentEntity, [stale])
        }
        let allCompanions = (memory.relatedFocusEntities + compartmentTabs + staleWithSharedTerms)
            .reduce(into: [String]()) { result, item in
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !result.contains(trimmed) && trimmed != memory.currentEntity {
                    result.append(trimmed)
                }
            }
        let effectiveHasComparison = hasComparison || (
            allCompanions.count >= 1
            && !memory.currentEntity.isEmpty
            && shareSignificantTerms(memory.currentEntity, allCompanions)
        )
        let effectiveComparisonCandidates: [String] = {
            if hasComparison { return memory.comparisonCandidates }
            if effectiveHasComparison {
                return ([memory.currentEntity] + allCompanions).filter { !$0.isEmpty }
            }
            return []
        }()

        // Comparison: compare when multiple candidates
        if effectiveHasComparison {
            let capId = "compare_options"
            let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: entityKey)
            let compareTitle = Self.comparisonTitle(candidates: effectiveComparisonCandidates, entity: entity)
            results.append(PortfolioCandidate(
                lane: .research,
                title: compareTitle,
                capabilityId: capId,
                executionMode: .preview_only,
                confidence: 0.75,
                usefulness: 0.75,
                executability: textExecutability,
                novelty: novelty,
                reason: "Multiple comparison candidates detected",
                requiredEvidence: evidenceQuality,
                requiresConfirmation: false,
                involvedApps: [],
                frictionOpportunity: nil,
                musicIntent: nil,
                generatedAction: nil
            ))
            print("[CognitiveLane] eligible=yes reason=comparison_candidates capability=compare_options")
            funnelAudit?.record(capabilityId: "compare_options", lane: "research", isSuppressed: false, reason: "generated")
        } else {
			lifecycleAudit?.noteNotGenerated(candidate: "compare_options", bucket: "research", reason: "insufficient_comparison_candidates")
            funnelAudit?.record(capabilityId: "compare_options", lane: "research", isSuppressed: true, reason: "insufficient_comparison_candidates")
        }

        func shareSignificantTerms(_ entity: String, _ related: [String]) -> Bool {
            let entityTokens = Set(entity.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
            for rel in related {
                let relTokens = Set(rel.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
                if entityTokens.intersection(relTokens).count >= 2 { return true }
            }
            return false
        }

        // Diagnose: error terms present
        if hasErrors && (hasRealContent || isEditorContext) {
            let capId = "diagnose_error"
            let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: entityKey)
            results.append(PortfolioCandidate(
                lane: .cognitive,
                title: "Diagnose the current error",
                capabilityId: capId,
                executionMode: .preview_only,
                confidence: 0.80,
                usefulness: 0.85,
                executability: 0.55,
                novelty: novelty,
                reason: "Error terms detected in editor context",
                requiredEvidence: evidenceQuality,
                requiresConfirmation: false,
                involvedApps: [],
                frictionOpportunity: nil,
                musicIntent: nil,
                generatedAction: nil
            ))
            print("[CognitiveLane] eligible=yes reason=error_terms capability=diagnose_error")
            funnelAudit?.record(capabilityId: "diagnose_error", lane: "cognitive", isSuppressed: false, reason: "generated")
        } else {
			lifecycleAudit?.noteNotGenerated(candidate: "diagnose_error", bucket: "coding", reason: "no_error_context")
            funnelAudit?.record(capabilityId: "diagnose_error", lane: "cognitive", isSuppressed: true, reason: "no_error_context")
        }

        // Study actions: only with real content (not editor_context)
        if hasRealContent && !isEditorContext && (domain == .studying || entityType == .course_material) {
            let capId = "generate_quiz"
            let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: entityKey)
            results.append(PortfolioCandidate(
                lane: .cognitive,
                title: "Generate practice questions for \(String(entity.prefix(38)))",
                capabilityId: capId,
                executionMode: .preview_only,
                confidence: 0.70,
                usefulness: 0.70,
                executability: 0.55,
                novelty: novelty,
                reason: "Study material with real content",
                requiredEvidence: evidenceQuality,
                requiresConfirmation: false,
                involvedApps: [],
                frictionOpportunity: nil,
                musicIntent: nil,
                generatedAction: nil
            ))
            print("[CognitiveLane] eligible=yes reason=study_material_real_content capability=generate_quiz")
            funnelAudit?.record(capabilityId: "generate_quiz", lane: "cognitive", isSuppressed: false, reason: "generated")
        } else if domain == .studying || entityType == .course_material {
			lifecycleAudit?.noteNotGenerated(candidate: "generate_quiz", bucket: "coding", reason: "no_real_study_content")
            funnelAudit?.record(capabilityId: "generate_quiz", lane: "cognitive", isSuppressed: true, reason: "no_real_study_content")
        } else {
            funnelAudit?.record(capabilityId: "generate_quiz", lane: "cognitive", isSuppressed: true, reason: "not_studying_workflow")
        }

        if results.isEmpty {
            print("[CognitiveLane] selected=none")
        }

        return results
    }

    // MARK: - Editor coding lane (Phase 27.3)

    /// Produces workflow-level coding actions that don't require file contents.
    /// These actions use grounded context: project name, file names, compartment
    /// history, dwell duration — not AX text or OCR.
    private static func evaluateEditorCodingLane(
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        evidenceQuality: String,
        entityKey: String,
        hasErrors: Bool,
        noveltyTracker: OpportunityNoveltyTracker,
		lifecycleAudit: CandidateLifecycleAudit? = nil,
        funnelAudit: ProposalFunnelAudit? = nil
    ) -> [PortfolioCandidate] {
        var results: [PortfolioCandidate] = []
        let entity = memory.currentEntity
        let entityShort = String(entity.prefix(40)).trimmingCharacters(in: .whitespaces)
        let recentFiles = memory.recentEntities.prefix(6)
        let dwellMinutes = (compartment?.dwellSeconds ?? 0) / 60.0

        // Architecture review: when navigating multiple files
        if recentFiles.count >= 3 {
            let capId = "review_architecture"
            let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: entityKey)
            let title = entityShort.isEmpty
                ? "Review how the recent files connect together?"
                : "Review the architecture around \(entityShort)?"
            results.append(PortfolioCandidate(
                lane: .cognitive,
                title: title,
                capabilityId: capId,
                executionMode: .preview_only,
                confidence: 0.72,
                usefulness: 0.65,
                executability: 0.50,
                novelty: novelty,
                reason: "Editor context with \(recentFiles.count) recent files",
                requiredEvidence: evidenceQuality,
                requiresConfirmation: false,
                involvedApps: [],
                frictionOpportunity: nil,
                musicIntent: nil,
                generatedAction: nil
            ))
            print("[CognitiveLane] eligible=yes reason=editor_multi_file capability=review_architecture")
            funnelAudit?.record(capabilityId: "review_architecture", lane: "cognitive", isSuppressed: false, reason: "generated")
        } else {
            funnelAudit?.record(capabilityId: "review_architecture", lane: "cognitive", isSuppressed: true, reason: "insufficient_recent_files")
        }

        // Planning: when deep in a compartment
        if dwellMinutes >= 5, let comp = compartment {
            let capId = "plan_next_steps"
            let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: entityKey)
            let label = comp.label.isEmpty ? entityShort : String(comp.label.prefix(40))
            let title = label.isEmpty
                ? "Plan the next implementation steps?"
                : "Plan the next steps for \(label)?"
            results.append(PortfolioCandidate(
                lane: .cognitive,
                title: title,
                capabilityId: capId,
                executionMode: .preview_only,
                confidence: 0.68,
                usefulness: 0.60,
                executability: 0.50,
                novelty: novelty,
                reason: "Deep dwell \(String(format: "%.0f", dwellMinutes))m in coding compartment",
                requiredEvidence: evidenceQuality,
                requiresConfirmation: false,
                involvedApps: [],
                frictionOpportunity: nil,
                musicIntent: nil,
                generatedAction: nil
            ))
            if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .dogfood) {
                print("[CognitiveLane] eligible=yes reason=editor_deep_dwell capability=plan_next_steps")
            }
            funnelAudit?.record(capabilityId: "plan_next_steps", lane: "cognitive", isSuppressed: false, reason: "generated")
        } else {
            funnelAudit?.record(capabilityId: "plan_next_steps", lane: "cognitive", isSuppressed: true, reason: "insufficient_dwell_time")
        }

        // Refactor suggestion: when revisiting same files
        let revisitedFiles = recentFiles.filter { file in
            memory.repeatedConcepts.contains(where: { file.lowercased().contains($0.lowercased()) })
        }
        if revisitedFiles.count >= 2 {
            let capId = "suggest_refactor"
            let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: entityKey)
            let title = "Look for duplicated patterns across the recent files?"
            results.append(PortfolioCandidate(
                lane: .cognitive,
                title: title,
                capabilityId: capId,
                executionMode: .preview_only,
                confidence: 0.65,
                usefulness: 0.55,
                executability: 0.45,
                novelty: novelty,
                reason: "Revisited files with shared concepts",
                requiredEvidence: evidenceQuality,
                requiresConfirmation: false,
                involvedApps: [],
                frictionOpportunity: nil,
                musicIntent: nil,
                generatedAction: nil
            ))
            if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .dogfood) {
                print("[CognitiveLane] eligible=yes reason=editor_revisited_files capability=suggest_refactor")
            }
            funnelAudit?.record(capabilityId: "suggest_refactor", lane: "cognitive", isSuppressed: false, reason: "generated")
        } else {
            funnelAudit?.record(capabilityId: "suggest_refactor", lane: "cognitive", isSuppressed: true, reason: "insufficient_revisited_files")
        }

		if results.isEmpty {
			lifecycleAudit?.noteNotGenerated(candidate: "review_architecture", bucket: "coding", reason: "editor_context_insufficient_structure")
		}

        return results
    }

	// Phase 28.2: No identity remapping — return actual capabilityId.
	private static func lifecycleName(for capabilityId: String, title: String) -> String {
		let trimmed = capabilityId.trimmingCharacters(in: .whitespacesAndNewlines)
		if !trimmed.isEmpty { return trimmed }
		let normalized = title
			.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
			.joined(separator: "_")
		return normalized.isEmpty ? "candidate" : normalized
	}

	private static func lifecycleBucket(for candidate: PortfolioCandidate) -> String {
		switch candidate.lane {
		case .music: return "music"
		case .workspace: return "workspace"
		case .metadata: return "metadata"
		case .friction: return "friction"
		case .research: return "research"
		case .cognitive: return "coding"
		case .comfort: return "comfort"
		}
	}

	// MARK: - Entity-aware research titles (Phase 28.2)

	/// Produce a research title grounded in the current entity/sources.
	/// Never use "collect references" or generic "sources you've opened" phrasing.
	private static func researchTitle(entity: String, sources: [String], hasComparison: Bool) -> String {
		let short = String(entity.prefix(42)).trimmingCharacters(in: .whitespacesAndNewlines)
		if !short.isEmpty {
			// Use entity to ground the title
			let lower = short.lowercased()
			if lower.contains("reddit") || lower.contains("thread") || lower.contains("discussion") {
				return "Summarize the \(short) thread?"
			}
			if lower.contains("fix") || lower.contains("issue") || lower.contains("bug") || lower.contains("error") {
				return "Extract likely fixes from \(short)?"
			}
			if hasComparison {
				return "Compare the \(short) options?"
			}
			return "Summarize the key points from \(short)?"
		}
		// Fall back to source count
		if sources.count >= 3 {
			return "Summarize the \(sources.count) tabs you have open?"
		}
		return "Summarize what you've been reading?"
	}

	/// Produce a comparison title grounded in comparison candidates.
	private static func comparisonTitle(candidates: [String], entity: String) -> String {
		if candidates.count >= 2 {
			let c1 = String(candidates[0].prefix(28)).trimmingCharacters(in: .whitespacesAndNewlines)
			let c2 = String(candidates[1].prefix(28)).trimmingCharacters(in: .whitespacesAndNewlines)
			if !c1.isEmpty && !c2.isEmpty {
				return "Compare \(c1) and \(c2)?"
			}
		}
		let short = String(entity.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
		if !short.isEmpty {
			return "Compare the \(short) options?"
		}
		return "Compare the options you're viewing?"
	}

	private static func familyWinners(from viable: [PortfolioCandidate]) -> [PortfolioCandidate.Family: PortfolioCandidate] {
		var winners: [PortfolioCandidate.Family: PortfolioCandidate] = [:]
		for candidate in viable {
			if let existing = winners[candidate.family] {
				if candidate.score > existing.score {
					winners[candidate.family] = candidate
				}
			} else {
				winners[candidate.family] = candidate
			}
		}
		return winners
	}

    private static func logPanelInventory(_ candidates: [PortfolioCandidate], viable: [PortfolioCandidate]) {
        var surfacedCounts: [PortfolioCandidate.Family: Int] = [:]
        for c in candidates {
            surfacedCounts[c.family, default: 0] += 1
        }
        var candidateCounts: [PortfolioCandidate.Family: Int] = [:]
        for c in viable {
            candidateCounts[c.family, default: 0] += 1
        }
        
        let families: [PortfolioCandidate.Family] = [.media, .research, .writing, .coding, .communication, .workspace, .comfort]
        for family in families {
            let candidateCount = candidateCounts[family] ?? 0
            let surfaced = surfacedCounts[family] ?? 0
            let suppressed = candidateCount - surfaced
            
            if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .dogfood) {
                print("[UsefulActionInventory] family=\(family.rawValue) candidate_count=\(candidateCount) surfaced=\(surfaced) suppressed=\(suppressed)")
            }
            if LogControl.shared.shouldLog(category: .panel_inventory, level: .dogfood) {
                print("[PanelInventory] family=\(family.rawValue) count=\(surfaced)")
            }
        }
        
        if let dominant = surfacedCounts.max(by: { $0.value < $1.value }), dominant.value > 0 {
            let total = candidates.count
            let isDominant = Double(dominant.value) / Double(total) > 0.7 && total > 2
            if LogControl.shared.shouldLog(category: .panel_inventory, level: .dogfood) {
                print("[PanelInventory] dominant_family=\(dominant.key.rawValue) blocked=\(isDominant ? "yes" : "no") reason=\(isDominant ? "single_family_overdominance" : "diverse_portfolio")")
            }
        }
    }

	private static func orderedCandidatesForFinalSelection(
		viable: [PortfolioCandidate],
		familyWinners: [PortfolioCandidate.Family: PortfolioCandidate]
	) -> [PortfolioCandidate] {
		let winners = familyWinners.values.sorted { $0.score > $1.score }
		let winnerIds = Set(winners.map(\.candidateID))
		let remainder = viable.filter { !winnerIds.contains($0.candidateID) }.sorted { $0.score > $1.score }
		let final = winners + remainder
        logPanelInventory(final, viable: viable)
        return final
	}

	private static func heuristicFrictionCandidates(
		memory: WorkingMemorySnapshot,
		compartment: TaskCompartment?,
		entityKey: String,
		noveltyTracker: OpportunityNoveltyTracker
	) -> [PortfolioCandidate] {
		var candidates: [PortfolioCandidate] = []
		let related = memory.relatedFocusEntities.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		let hasComparisonTabs = memory.comparisonCandidates.count >= 2

		// Source 1: explicit comparison tabs or many related entities
		if hasComparisonTabs || related.count >= 3 {
			let title = arrangeSideBySideTitle(
				current: memory.currentEntity,
				related: related,
				comparison: memory.comparisonCandidates
			)
			candidates.append(PortfolioCandidate(
				lane: .friction,
				title: title,
				capabilityId: "arrange_side_by_side",
				executionMode: .local_action,
				confidence: hasComparisonTabs ? 0.66 : 0.54,
				usefulness: hasComparisonTabs ? 0.72 : 0.58,
				executability: 0.84,
				novelty: noveltyTracker.noveltyScore(capabilityId: "arrange_side_by_side", entityKey: entityKey),
				reason: hasComparisonTabs ? "Multiple related tabs open" : "Several related sources open",
				requiredEvidence: "browser_tabs",
				requiresConfirmation: true,
				involvedApps: [],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil
			))
			candidates.append(PortfolioCandidate(
				lane: .friction,
				title: "Put these research windows side by side?",
				capabilityId: "split_research_setup",
				executionMode: .local_action,
				confidence: hasComparisonTabs ? 0.62 : 0.50,
				usefulness: hasComparisonTabs ? 0.70 : 0.55,
				executability: 0.82,
				novelty: noveltyTracker.noveltyScore(capabilityId: "split_research_setup", entityKey: entityKey),
				reason: hasComparisonTabs ? "Multiple related tabs should be split into parallel windows" : "Several related sources are open in the same browser session",
				requiredEvidence: "browser_tabs",
				requiresConfirmation: true,
				involvedApps: [],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil
			))
		}

		// Source 2: compartment browser tabs or recent entities suggest workspace friction
		if candidates.isEmpty {
			let browserTabs = compartment?.browserTabs ?? []
			let staleEntities = memory.staleEntities
			let otherTabs = browserTabs.filter { $0 != memory.currentEntity && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			let otherStale = staleEntities.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

			let hasMultiTab = otherTabs.count >= 1 && !memory.currentEntity.isEmpty
			let hasStaleCompanion = !otherStale.isEmpty && !memory.currentEntity.isEmpty

			if hasMultiTab || hasStaleCompanion {
				let companionSources = otherTabs + otherStale
				let title = arrangeSideBySideTitle(
					current: memory.currentEntity,
					related: companionSources,
					comparison: memory.comparisonCandidates
				)
				candidates.append(PortfolioCandidate(
					lane: .friction,
					title: title,
					capabilityId: "arrange_side_by_side",
					executionMode: .local_action,
					confidence: hasMultiTab ? 0.52 : 0.46,
					usefulness: hasMultiTab ? 0.56 : 0.48,
					executability: 0.84,
					novelty: noveltyTracker.noveltyScore(capabilityId: "arrange_side_by_side", entityKey: entityKey),
					reason: hasMultiTab ? "Multiple browser tabs in same compartment" : "Stale companion entity in same compartment",
					requiredEvidence: "compartment_context",
					requiresConfirmation: true,
					involvedApps: [],
					frictionOpportunity: nil,
					musicIntent: nil,
					generatedAction: nil
				))
			}
		}

		return candidates
	}

	private static let staleEntityTerms: Set<String> = [
		"facebook", "file upload", "translate", "translator", "youtube",
		"truth or drink", "netflix", "tiktok", "instagram", "twitter"
	]

	private static func isStaleEntity(_ entity: String) -> Bool {
		let lower = entity.lowercased()
		return staleEntityTerms.contains(where: { lower.contains($0) })
	}

	private static func arrangeSideBySideTitle(current: String, related: [String], comparison: [String]) -> String {
		// Filter out stale/entertainment entities
		let cleanRelated = related.filter { !isStaleEntity($0) }
		let cleanComparison = comparison.filter { !isStaleEntity($0) }
		let staleCount = (related.count - cleanRelated.count) + (comparison.count - cleanComparison.count)

		// Try work pair first
		let workPair = WorkPairMemory.shared.bestPair()
		if let pair = workPair {
			let a = SuggestionTitleRewriter.semanticRoleLabel(title: pair.titleA, appName: pair.appA)
			let b = SuggestionTitleRewriter.semanticRoleLabel(title: pair.titleB, appName: pair.appB)
			if !a.isEmpty && !b.isEmpty {
				print("[SuggestionTitleContext] capability=arrange_side_by_side source=work_pair primary=\"\(a)\" secondary=\"\(b)\" excluded_stale=\(staleCount)")
				return "Put \(a) beside \(b)?"
			}
		}

		let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
		let shortCurrent = SuggestionTitleRewriter.semanticRoleLabel(title: current, appName: frontmostApp)
		let secondEntity: String? = {
			if cleanComparison.count >= 2 {
				let other = cleanComparison.first { $0 != current }
				if let other {
					let runtime = WorkspaceRuntimeInventoryProvider.snapshot()
					let appOther = runtime.visibleWindows.first { $0.title.lowercased().contains(other.lowercased()) || other.lowercased().contains($0.title.lowercased()) }?.appName ?? ""
					return SuggestionTitleRewriter.semanticRoleLabel(title: other, appName: appOther)
				}
			}
			if let first = cleanRelated.first {
				let runtime = WorkspaceRuntimeInventoryProvider.snapshot()
				let appFirst = runtime.visibleWindows.first { $0.title.lowercased().contains(first.lowercased()) || first.lowercased().contains($0.title.lowercased()) }?.appName ?? ""
				return SuggestionTitleRewriter.semanticRoleLabel(title: first, appName: appFirst)
			}
			return nil
		}()

		let source = secondEntity != nil ? "working_memory" : "generic"
		print("[SuggestionTitleContext] capability=arrange_side_by_side source=\(source) primary=\"\(shortCurrent)\" secondary=\"\(secondEntity ?? "none")\" excluded_stale=\(staleCount)")

		if let second = secondEntity, !shortCurrent.isEmpty, !second.isEmpty {
			return "Put \(shortCurrent) beside \(second)?"
		}
		if !shortCurrent.isEmpty {
			return "Put \(shortCurrent) side by side with the other tab?"
		}
		return "Put the tabs you're switching between side by side?"
	}

	private static func rentalResearchCandidates(
		memory: WorkingMemorySnapshot,
		evidenceQuality: String,
		entityKey: String,
		noveltyTracker: OpportunityNoveltyTracker
	) -> [PortfolioCandidate] {
		let terms = normalizedResearchTerms(memory.currentEntity, memory.repeatedConcepts + memory.relatedFocusEntities + memory.comparisonCandidates)
		let evidenceLevel = EvidenceQualityModel.level(from: evidenceQuality)
		guard isRentalResearchContext(entity: memory.currentEntity, terms: terms),
		      evidenceLevel.rank >= ProgressiveEvidenceLevel.metadata_rich.rank else {
			return []
		}

		let hasPricing = containsAny(terms, ["rent", "price", "pricing", "utilities", "deposit", "budget", "cost"])
		let hasListing = containsAny(terms, ["listing", "room", "sublet", "lease", "rental", "housing", "apartment", "roommate"])
		let hasAdvice = containsAny(terms, ["reddit", "thread", "advice", "student", "students", "tips", "landlord", "posting"])
		let hasPlatforms = containsAny(terms, ["facebook", "marketplace", "kijiji", "zillow", "craigslist", "platform"])

		var candidates: [PortfolioCandidate] = []
		if memory.comparisonCandidates.count >= 2 || hasListing {
			candidates.append(textCandidate(
				capabilityId: "compare_rental_options",
				title: "Compare the rental posts you're viewing?",
				confidence: 0.78,
				usefulness: 0.84,
				noveltyTracker: noveltyTracker,
				entityKey: entityKey,
				reason: "Multiple rental listings or advice sources detected",
				evidenceQuality: evidenceQuality
			))
		}
		if hasListing {
			candidates.append(textCandidate(
				capabilityId: "draft_listing_ad",
				title: "Draft a rental listing from the details you have?",
				confidence: 0.72,
				usefulness: 0.76,
				noveltyTracker: noveltyTracker,
				entityKey: entityKey,
				reason: "Listing details appear active in the current browser context",
				evidenceQuality: evidenceQuality
			))
			candidates.append(textCandidate(
				capabilityId: "create_listing_checklist",
				title: "Draft a checklist for your rental ad?",
				confidence: 0.74,
				usefulness: 0.79,
				noveltyTracker: noveltyTracker,
				entityKey: entityKey,
				reason: "Listing details suggest an ad-preparation workflow",
				evidenceQuality: evidenceQuality
			))
			candidates.append(textCandidate(
				capabilityId: "identify_missing_listing_details",
				title: "List missing details for the room posting?",
				confidence: 0.73,
				usefulness: 0.81,
				noveltyTracker: noveltyTracker,
				entityKey: entityKey,
				reason: "Listing-related context can be checked for omissions",
				evidenceQuality: evidenceQuality
			))
		}
		if hasPricing {
			candidates.append(textCandidate(
				capabilityId: "extract_pricing_guidance",
				title: "Extract pricing guidance from these threads?",
				confidence: 0.76,
				usefulness: 0.80,
				noveltyTracker: noveltyTracker,
				entityKey: entityKey,
				reason: "Price and rent evidence detected across current sources",
				evidenceQuality: evidenceQuality
			))
		}
		if hasAdvice {
			candidates.append(textCandidate(
				capabilityId: "create_questions_to_ask_landlord",
				title: "Create questions to ask the landlord?",
				confidence: 0.71,
				usefulness: 0.74,
				noveltyTracker: noveltyTracker,
				entityKey: entityKey,
				reason: "Advice-style discussion suggests follow-up questions",
				evidenceQuality: evidenceQuality
			))
			candidates.append(textCandidate(
				capabilityId: "summarize_thread",
				title: "Summarize what these renters are saying?",
				confidence: 0.67,
				usefulness: 0.68,
				noveltyTracker: noveltyTracker,
				entityKey: entityKey,
				reason: "Discussion-style context contains advice that can be summarized",
				evidenceQuality: evidenceQuality
			))
			candidates.append(textCandidate(
				capabilityId: "synthesize_advice",
				title: "Compare the rental advice from these posts?",
				confidence: 0.75,
				usefulness: 0.78,
				noveltyTracker: noveltyTracker,
				entityKey: entityKey,
				reason: "Multiple advice sources are open",
				evidenceQuality: evidenceQuality
			))
		}
		if hasPlatforms {
			candidates.append(textCandidate(
				capabilityId: "compare_listing_platforms",
				title: "Compare listing platforms for this search?",
				confidence: 0.70,
				usefulness: 0.72,
				noveltyTracker: noveltyTracker,
				entityKey: entityKey,
				reason: "Multiple listing platforms appear in the current context",
				evidenceQuality: evidenceQuality
			))
		}

		return candidates
	}

	private static func textCandidate(
		capabilityId: String,
		title: String,
		confidence: Double,
		usefulness: Double,
		noveltyTracker: OpportunityNoveltyTracker,
		entityKey: String,
		reason: String,
		evidenceQuality: String
	) -> PortfolioCandidate {
		let evidenceLevel = EvidenceQualityModel.level(from: evidenceQuality)
		let entry = ActionRegistry.entry(for: capabilityId)
		let eligibility = ActionRegistry.evaluate(
			capabilityId: capabilityId,
			currentEvidence: evidenceLevel,
			hasURLs: evidenceLevel.rank >= ProgressiveEvidenceLevel.metadata_rich.rank,
			hasSelection: evidenceLevel == .selected_content
		)
		if eligibility.eligible {
		    if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .debug) {
		        print("[CognitiveLane] allowed capability=\(capabilityId) evidence_level=\(evidenceLevel.rawValue) scope=\(entry.scope)")
		    }
		} else {
		    if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .debug) {
		        print("[CognitiveLane] suppressed reason=evidence_level_requires_content evidence_level=\(evidenceLevel.rawValue)")
		    }
		}

		let adjustedExecutability: Double = {
			guard eligibility.eligible else { return 0.0 }
			switch evidenceLevel {
			case .none, .metadata_only: return 0.30
			case .metadata_rich: return 0.42
			case .visible_content: return 0.62
			case .selected_content: return 0.72
			case .full_content: return 0.82
			}
		}()
		return PortfolioCandidate(
			lane: .research,
			title: title,
			capabilityId: capabilityId,
			executionMode: .preview_only,
			confidence: confidence,
			usefulness: usefulness,
			executability: adjustedExecutability,
			novelty: noveltyTracker.noveltyScore(capabilityId: capabilityId, entityKey: entityKey),
			reason: reason,
			requiredEvidence: entry.requiredEvidence.rawValue,
			requiresConfirmation: false,
			involvedApps: [],
			frictionOpportunity: nil,
			musicIntent: nil,
			generatedAction: nil
		)
	}

	private static func normalizedResearchTerms(_ entity: String, _ terms: [String]) -> [String] {
		([entity] + terms)
			.flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) }
			.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { $0.count >= 3 }
	}

	private static func isRentalResearchContext(entity: String, terms: [String]) -> Bool {
		let haystack = normalizedResearchTerms(entity, terms)
		let markers: Set<String> = ["rent", "rental", "room", "rooms", "lease", "landlord", "tenant", "listing", "housing", "apartment", "sublet", "roommate", "utilities", "deposit"]
		return !Set(haystack).intersection(markers).isEmpty
	}

	private static func containsAny(_ terms: [String], _ matches: [String]) -> Bool {
		let set = Set(terms)
		return matches.contains { set.contains($0) }
	}
}

// MARK: - ProposalFunnelAudit

public final class ProposalFunnelAudit: Sendable {
    public init() {}
    public func recordNotGenerated(_ capId: String, lane: String, reason: String) {
        if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .trace) {
            print("[ProposalFunnelAudit] not_generated capability=\(capId) lane=\(lane) reason=\(reason)")
        }
    }
    public func recordGenerated(_ capId: String, lane: String, reason: String) {
        if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .dogfood) {
            print("[ProposalFunnelAudit] generated capability=\(capId) lane=\(lane) reason=\(reason)")
        }
    }
    public func recordRanking(_ capId: String, lane: String, survived: Bool, reason: String) {
        if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .debug) {
            print("[ProposalFunnelAudit] ranking capability=\(capId) lane=\(lane) survived=\(survived) reason=\(reason)")
        }
    }
    public func recordSelection(_ capId: String, lane: String, survived: Bool, reason: String) {
        if LogControl.shared.shouldLog(category: .useful_action_inventory, level: .dogfood) {
            print("[ProposalFunnelAudit] selection capability=\(capId) lane=\(lane) survived=\(survived) reason=\(reason)")
        }
    }
    public func record(capabilityId: String, lane: String, isSuppressed: Bool = false, reason: String) {
        if isSuppressed {
            recordNotGenerated(capabilityId, lane: lane, reason: reason)
        } else {
            recordGenerated(capabilityId, lane: lane, reason: reason)
        }
    }
    public func emit() {
        // Placeholder for future aggregate emission logic if needed.
        // Currently each record method prints immediately.
    }
}
