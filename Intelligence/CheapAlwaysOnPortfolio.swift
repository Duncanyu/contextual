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
}

enum CheapAlwaysOnPortfolio {
	static let qualityThreshold: Double = 0.12

	static func evaluate(_ input: CheapAlwaysOnPortfolioInput) -> [PortfolioCandidate] {
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

		let laneNames = Set(candidates.map { $0.lane.rawValue }).sorted().joined(separator: ",")
		print("[ActionPortfolio] lanes=\(laneNames.isEmpty ? "none" : laneNames)")
		for c in candidates {
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

		let viable = candidates
			.filter { $0.score >= qualityThreshold }
			.sorted { $0.score > $1.score }

		if let selected = viable.first {
			print("[CheapAlwaysOnPortfolio] selected=\(selected.capabilityId)")
			print("[ActionPortfolio] selected"
				+ " lane=\(selected.lane.rawValue)"
				+ " capability=\(selected.capabilityId)"
				+ " title=\"\(selected.title.prefix(60))\""
				+ " score=\(String(format: "%.3f", selected.score))")
		} else {
			print("[CheapAlwaysOnPortfolio] selected=none reason=no_candidates")
			print("[ActionPortfolio] selected=none reason=no_viable_candidates")
		}
		return viable
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
		let activeEnough = activityState?.isActive == true && (activityState?.dwellSeconds ?? 0) >= 20
		let stablePattern = (activityState?.isActive == true && (activityState?.dwellSeconds ?? 0) >= 20) || trust >= 0.50
		let contextTrusted = trust >= 0.70
			|| groundingConfidence >= 0.65
			|| activeEnough
			|| stablePattern
			|| determinerSignal?.actionable == true

		if startupQuiet {
			if launchAge >= 10 && contextTrusted { return (true, "startup_quiet_period") }
			return (false, launchAge < 10 ? "startup_quiet_warmup" : "startup_quiet_no_trusted_context")
		}
		if !modelReady && contextTrusted { return (true, "model_unavailable") }
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
		guard input.mediaState.isMusicPlaying else { return nil }
		guard input.mediaState.visualMediaKind == .youtubeVideo
			|| input.mediaState.visualMediaKind == .movieOrShow
			|| input.mediaState.visualMediaKind == .genericVideo else { return nil }
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
		guard !input.mediaState.isMusicPlaying else { return nil }
		guard input.mediaState.visualMediaKind == .none else { return nil }
		guard input.activityState?.isActive == true || input.compartment != nil || !input.memory.currentEntity.isEmpty || input.groundingResult != nil else { return nil }
		
		let isWatching = (input.semanticState?.domain == .watching)
			|| (input.entityGrounding?.isEntertainment == true)
			|| (input.compartment?.workflow == .watching)
			|| (input.groundingResult?.domain.lowercased().contains("watching") == true)
		if isWatching { return nil }

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
		let learnedPlaylist = PlaylistMemory.shared.suggest(compartment: input.compartment, workflow: input.workflow)
		let label = input.groundingResult?.entityName ?? input.compartment?.label ?? input.memory.currentEntity
		let shortLabel = String(label.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
		let title: String = {
			if let p = learnedPlaylist {
				if shortLabel.isEmpty { return "Play your \(p) playlist?" }
				return "Play your \(p) playlist while you work on \(shortLabel)?"
			}
			return "Resume your music?"
		}()
		let usefulness: Double = {
			if input.compartment?.dwellState == .deep_work || input.activityState?.dwellState == .deep_work { return 0.75 }
			if input.compartment?.dwellState == .settled || input.activityState?.dwellState == .settled { return 0.60 }
			return 0.45
		}()
		let novelty = noveltyTracker.noveltyScore(capabilityId: "play_focus_media", entityKey: input.entityKey)
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
		guard !input.frictionSignals.isEmpty else { return [] }
		let workspacePatterns = WorkspacePatternTracker.shared.knownPatterns()
		let currentApps = Set(([input.currentApp] + input.memory.recentEntities).filter { !$0.isEmpty })
		let opportunities = FrictionOpportunityReasoner.reason(
		        frictionSignals: input.frictionSignals,
		        workspacePatterns: workspacePatterns,
		        currentApps: currentApps,
		        currentEntity: input.memory.currentEntity,
		        compartmentLabel: input.compartment?.label ?? ""
		)
		return opportunities.compactMap { opp in
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
		}
	}

	private static func workspaceCandidate(
		input: CheapAlwaysOnPortfolioInput,
		noveltyTracker: OpportunityNoveltyTracker
	) -> PortfolioCandidate? {
		let patterns = WorkspacePatternTracker.shared.knownPatterns()
		guard let pattern = patterns.first(where: { $0.frequency >= 2 }) else { return nil }
		let currentApps = Set(([input.currentApp] + input.memory.recentEntities).filter { !$0.isEmpty })
		let missing = WorkspacePatternTracker.shared.missingApps(from: pattern, currentApps: currentApps)
		guard !missing.isEmpty else { return nil }
		let novelty = noveltyTracker.noveltyScore(capabilityId: "restore_workspace", entityKey: input.entityKey)
		return PortfolioCandidate(
			lane: .workspace,
			title: "Open your usual \(pattern.label) setup?",
			capabilityId: "restore_workspace",
			executionMode: .local_action,
			confidence: min(0.85, Double(pattern.frequency) * 0.15 + 0.30),
			usefulness: 0.65,
			executability: 0.85,
			novelty: novelty,
			reason: "Workspace pattern seen \(pattern.frequency)x, missing \(missing.count) app(s)",
			requiredEvidence: "workspace_memory",
			requiresConfirmation: true,
			involvedApps: missing,
			frictionOpportunity: nil,
			musicIntent: nil,
			generatedAction: nil
		)
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
		suppressionReason: String
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
		suppressionReason: String
	) {
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
			suppressionReason: suppressionReason
		))
	}
}
