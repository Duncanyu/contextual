import Foundation

// MARK: - PortfolioCandidate

/// Phase 26.2 — A candidate action from one of the evaluation lanes.
/// All lanes produce PortfolioCandidates which are ranked together.
struct PortfolioCandidate: Sendable {
    enum Lane: String, Sendable, CaseIterable {
        case music
        case workspace
        case friction
        case research
        case cognitive
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

    /// Composite ranking score: executable, useful, confident, novel actions win.
    var score: Double {
        usefulness * executability * confidence * novelty
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
				lifecycleAudit: lifecycleAudit,
                funnelAudit: funnelAudit
            ) {
                candidates.append(workspaceCandidate)
            }
        } else {
			lifecycleAudit?.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: "lane_forbidden_by_grounding")
            funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: true, reason: "lane_forbidden_by_grounding")
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
			lifecycleAudit?.noteGenerated(
				candidate: lifecycleName(for: c.capabilityId, title: c.title),
				bucket: lifecycleBucket(for: c)
			)
            print("[ActionPortfolio] candidate"
                + " lane=\(c.lane.rawValue)"
                + " capability=\(c.capabilityId)"
                + " score=\(String(format: "%.3f", c.score))"
                + " usefulness=\(String(format: "%.2f", c.usefulness))"
                + " executability=\(String(format: "%.2f", c.executability))"
                + " confidence=\(String(format: "%.2f", c.confidence))"
                + " novelty=\(String(format: "%.2f", c.novelty))")
        }

        // ── Rank by composite score ─────────────────────────────────────
        candidates.sort { $0.score > $1.score }

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

        if let selected = viable.first {
            print("[ActionPortfolio] selected"
                + " lane=\(selected.lane.rawValue)"
                + " capability=\(selected.capabilityId)"
                + " title=\"\(selected.title.prefix(60))\""
                + " score=\(String(format: "%.3f", selected.score))")
            
            for v in viable {
                if v.capabilityId == selected.capabilityId {
                    funnelAudit?.recordSelection(v.capabilityId, lane: v.lane.rawValue, survived: true, reason: "portfolio_winner")
                } else {
                    funnelAudit?.recordSelection(v.capabilityId, lane: v.lane.rawValue, survived: false, reason: "lost_to_\(selected.capabilityId)")
                }
            }
        } else {
            print("[ActionPortfolio] selected=none reason=no_viable_candidates")
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

        return viable
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
        // Don't suggest music if already playing or watching video
        guard !mediaState.isMusicPlaying else {
			lifecycleAudit?.noteNotGenerated(candidate: "play_focus_media", bucket: "music", reason: "music_already_playing")
            print("[MusicAudit]\n"
                + "eligible=no\n"
                + "reason=music_already_playing\n"
                + "\n"
                + "media_playing=yes\n"
                + "\n"
                + "playlist_memory_match=no\n"
                + "playlist=none\n"
                + "\n"
                + "candidate_generated=no")
            funnelAudit?.record(capabilityId: "play_focus_media", lane: "music", isSuppressed: true, reason: "music_already_playing")
			return nil
		}
        if mediaState.visualMediaKind != .none {
			lifecycleAudit?.noteNotGenerated(candidate: "play_focus_media", bucket: "music", reason: "visual_media_active")
            print("[MusicAudit]\n"
                + "eligible=no\n"
                + "reason=visual_media_active\n"
                + "\n"
                + "media_playing=no\n"
                + "\n"
                + "playlist_memory_match=no\n"
                + "playlist=none\n"
                + "\n"
                + "candidate_generated=no")
            funnelAudit?.record(capabilityId: "play_focus_media", lane: "music", isSuppressed: true, reason: "visual_media_active")
			return nil
		}

        // Phase 26.4 — Suppress music lane when domain/grounding is watching or entertainment
        let isWatching = (semanticState?.domain == .watching)
            || (entityGrounding?.isEntertainment == true)
            || (compartment?.workflow == .watching)
            || (groundingResult?.domain.lowercased().contains("watching") == true)
            || (groundingResult?.domain.lowercased().contains("entertainment") == true)
        if isWatching {
			lifecycleAudit?.noteNotGenerated(candidate: "play_focus_media", bucket: "music", reason: "watching_or_entertainment")
            print("[MusicLane] suppressed reason=watching_or_entertainment")
            print("[MusicAudit]\n"
                + "eligible=no\n"
                + "reason=watching_or_entertainment\n"
                + "\n"
                + "media_playing=no\n"
                + "\n"
                + "playlist_memory_match=no\n"
                + "playlist=none\n"
                + "\n"
                + "candidate_generated=no")
            funnelAudit?.record(capabilityId: "play_focus_media", lane: "music", isSuppressed: true, reason: "watching_or_entertainment")
            return nil
        }

        // Need some work context (not idle/empty)
        guard !memory.currentEntity.isEmpty || compartment != nil || groundingResult != nil else {
			lifecycleAudit?.noteNotGenerated(candidate: "play_focus_media", bucket: "music", reason: "no_work_context")
            print("[MusicAudit]\n"
                + "eligible=no\n"
                + "reason=no_work_context\n"
                + "\n"
                + "media_playing=no\n"
                + "\n"
                + "playlist_memory_match=no\n"
                + "playlist=none\n"
                + "\n"
                + "candidate_generated=no")
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
            if canPlayDirectly { return .resume }
            return .search
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

        print("[MusicIntent] domain_source=\(domain.source)")
        print("[MusicIntent] selected_domain=\(domain.name)")
        print("[MusicTitle] title=\"\(title)\"")
        print("[MusicActionIdentity] title_action=\(action.rawValue) executor_action=\(action.rawValue) ok=yes")

        print("[MusicAudit]\n"
            + "eligible=yes\n"
            + "reason=none\n"
            + "\n"
            + "media_playing=no\n"
            + "\n"
            + "playlist_memory_match=\(playlist != nil ? "yes" : "no")\n"
            + "playlist=\(playlist ?? "none")\n"
            + "\n"
            + "candidate_generated=yes\n"
            + "action=\(action.rawValue)"
        )
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
        return "Search Apple Music for \(domain.name) music?"
    }

    // MARK: - Friction lane

    private static func evaluateFrictionLane(
        frictionSignals: [FrictionSignal],
        memory: WorkingMemorySnapshot,
        entityKey: String,
        noveltyTracker: OpportunityNoveltyTracker,
		lifecycleAudit: CandidateLifecycleAudit? = nil,
        funnelAudit: ProposalFunnelAudit? = nil
    ) -> [PortfolioCandidate] {
        guard !frictionSignals.isEmpty else {
			lifecycleAudit?.noteNotGenerated(candidate: "friction_lane", bucket: "friction", reason: "no_friction_signal")
            for capId in ["collect_references", "pin_reference_tabs", "arrange_side_by_side", "resume_focus_media", "extract_and_organize", "precompute_answer"] {
                funnelAudit?.record(capabilityId: capId, lane: "friction", isSuppressed: true, reason: "no_friction_signal")
            }
			return []
		}

        let currentApps: Set<String> = Set([memory.currentEntity])
        let workspacePatterns = WorkspacePatternTracker.shared.knownPatterns()
        let frictionOpps = FrictionOpportunityReasoner.reason(
            frictionSignals: frictionSignals,
            workspacePatterns: workspacePatterns,
            currentApps: currentApps,
            currentEntity: memory.currentEntity,
            compartmentLabel: ""
        )

        let mapped = frictionOpps.map { opp -> PortfolioCandidate in
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
        for m in mapped {
            funnelAudit?.record(capabilityId: m.capabilityId, lane: "friction", isSuppressed: false, reason: "generated")
        }
        return mapped
    }

    // MARK: - Workspace lane

    private static func evaluateWorkspaceLane(
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        entityKey: String,
        noveltyTracker: OpportunityNoveltyTracker,
		lifecycleAudit: CandidateLifecycleAudit? = nil,
        funnelAudit: ProposalFunnelAudit? = nil
    ) -> PortfolioCandidate? {
        let patterns = WorkspacePatternTracker.shared.knownPatterns()
        guard let pattern = patterns.first, pattern.frequency >= 2 else {
			lifecycleAudit?.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: "insufficient_history")
            funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: true, reason: "insufficient_history")
			return nil
		}

        let currentApps: Set<String> = Set([memory.currentEntity])
        let missing = WorkspacePatternTracker.shared.missingApps(from: pattern, currentApps: currentApps)
        guard !missing.isEmpty else {
			lifecycleAudit?.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: "workspace_already_restored")
            funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: true, reason: "workspace_already_restored")
			return nil
		}

        let title = "Open your usual \(pattern.label) setup?"
        let novelty = noveltyTracker.noveltyScore(capabilityId: "restore_workspace", entityKey: entityKey)

        funnelAudit?.record(capabilityId: "restore_workspace", lane: "workspace", isSuppressed: false, reason: "generated")

        return PortfolioCandidate(
            lane: .workspace,
            title: title,
            capabilityId: "restore_workspace",
            executionMode: .local_action,
            confidence: min(0.85, Double(pattern.frequency) * 0.15 + 0.30),
            usefulness: 0.65,
            executability: 0.85,
            novelty: novelty,
            reason: "Workspace pattern seen \(pattern.frequency)x, missing \(missing.count) app(s)",
            requiredEvidence: "none",
            requiresConfirmation: true,
            involvedApps: missing,
            frictionOpportunity: nil,
            musicIntent: nil,
            generatedAction: nil
        )
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

        let domain = semanticState?.domain ?? .unknown
        let entityType = entityGrounding?.entityType ?? semanticState?.entityType ?? .unknown
        let hasRealContent = evidenceQuality != "title_only"
        let isEditorContext = evidenceQuality == "editor_context"
        let hasSources = memory.relatedFocusEntities.count >= 2 || evidenceQuality == "browser_context"
        let hasComparison = memory.comparisonCandidates.count >= 2
        let entity = memory.currentEntity

        let errorTerms: Set<String> = ["error","exception","crash","failed","bug",
                                        "issue","broken","stack","trace","warning","undefined"]
        let hasErrors = !Set(memory.repeatedConcepts.map { $0.lowercased() }).intersection(errorTerms).isEmpty

        // Phase 26.4 — Gating check
        let isEntertainment = (entityGrounding?.isEntertainment == true)
            || (semanticState?.entityType == .tv_show || semanticState?.entityType == .youtube_video || semanticState?.entityType == .streaming_site)
        let isNewTab = memory.currentEntity.lowercased().contains("new tab") || memory.currentEntity.lowercased().contains("blank")
        let hasRealEvidence = evidenceQuality == "selection" || evidenceQuality == "ax_content" || evidenceQuality == "ocr" || (evidenceQuality == "browser_context" && hasSources)
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
            print("[CognitiveLane] suppressed reason=coding_title_only_too_weak")
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
            print("[CognitiveLane] suppressed reason=insufficient_evidence_title_only")
            for capId in allCognitiveCapIds {
                funnelAudit?.record(capabilityId: capId, lane: "cognitive", isSuppressed: true, reason: "insufficient_evidence_title_only")
            }
            return results
        }

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
                executability: 0.60,
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

        // Comparison: compare when multiple candidates
        if hasComparison {
            let capId = "compare_options"
            let novelty = noveltyTracker.noveltyScore(capabilityId: capId, entityKey: entityKey)
            let compareTitle = Self.comparisonTitle(candidates: memory.comparisonCandidates, entity: entity)
            results.append(PortfolioCandidate(
                lane: .research,
                title: compareTitle,
                capabilityId: capId,
                executionMode: .preview_only,
                confidence: 0.75,
                usefulness: 0.75,
                executability: 0.60,
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
            print("[CognitiveLane] eligible=yes reason=editor_deep_dwell capability=plan_next_steps")
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
            print("[CognitiveLane] eligible=yes reason=editor_revisited_files capability=suggest_refactor")
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
}

// MARK: - ProposalFunnelAudit

public final class ProposalFunnelAudit: Sendable {
    public init() {}
    public func recordNotGenerated(_ capId: String, lane: String, reason: String) {
        print("[ProposalFunnelAudit] not_generated capability=\(capId) lane=\(lane) reason=\(reason)")
    }
    public func recordGenerated(_ capId: String, lane: String, reason: String) {
        print("[ProposalFunnelAudit] generated capability=\(capId) lane=\(lane) reason=\(reason)")
    }
    public func recordRanking(_ capId: String, lane: String, survived: Bool, reason: String) {
        print("[ProposalFunnelAudit] ranking capability=\(capId) lane=\(lane) survived=\(survived) reason=\(reason)")
    }
    public func recordSelection(_ capId: String, lane: String, survived: Bool, reason: String) {
        print("[ProposalFunnelAudit] selection capability=\(capId) lane=\(lane) survived=\(survived) reason=\(reason)")
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

