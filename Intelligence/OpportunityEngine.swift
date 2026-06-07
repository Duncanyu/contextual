import AppKit
import Foundation

// MARK: - Need

/// The intermediate layer between observed activity and generated opportunity.
public enum Need: String, Sendable, Equatable, CaseIterable, Codable {
    case recall          // test/practice what was just studied
    case organization    // structure information into a useful form
    case explanation     // understand something in the context
    case debugging       // find and fix an error or performance issue
    case planning        // figure out what to do next
    case testing         // verify that something works correctly
    case comparison      // evaluate options against each other
    case synthesis       // combine multiple sources into unified notes
    case summarization   // condense material into a digest
    case drafting        // write or respond to something
    case architecture    // design the structure of a system/project
    case nextSteps       // last-resort fallback — only when nothing else qualifies
}

// MARK: - Opportunity

/// Phase 22 — A structured action opportunity produced by OpportunityEngine.
public struct Opportunity: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let capabilityId: String
    public let confidence: Double
    public let reason: String
    public let requiredEvidence: String
    public let actionability: Double
    public let inferredNeed: Need
    public let requiresConfirmation: Bool
    public let auxiliaryCapabilityIds: [String]
	public let involvedApps: [String]
	public let involvedURLs: [String]
	public let browserTabTitles: [String]
	let generatedAction: GeneratedActionProposal?
	// Phase 28.3: Carry MusicIntent through the full pipeline so click routing can use it.
	public let musicIntent: MusicIntent?

	init(
		id: String,
		title: String,
		capabilityId: String,
		confidence: Double,
		reason: String,
		requiredEvidence: String,
		actionability: Double,
		inferredNeed: Need,
		requiresConfirmation: Bool,
		auxiliaryCapabilityIds: [String],
		involvedApps: [String] = [],
		involvedURLs: [String] = [],
		browserTabTitles: [String] = [],
		generatedAction: GeneratedActionProposal? = nil,
		musicIntent: MusicIntent? = nil
	) {
		self.id = id
		self.title = title
		self.capabilityId = capabilityId
		self.confidence = confidence
		self.reason = reason
		self.requiredEvidence = requiredEvidence
		self.actionability = actionability
		self.inferredNeed = inferredNeed
		self.requiresConfirmation = requiresConfirmation
		self.auxiliaryCapabilityIds = auxiliaryCapabilityIds
		self.involvedApps = involvedApps
		self.involvedURLs = involvedURLs
		self.browserTabTitles = browserTabTitles
		self.generatedAction = generatedAction
		self.musicIntent = musicIntent
	}
}

// MARK: - OpportunityValidator

public enum OpportunityValidator {

    private static let observationalPrefixes: [String] = [
        "looks like you're", "looks like you are",
        "you seem to be", "you are currently", "you're currently",
        "i noticed", "it looks like", "i see that", "i can see",
        "you appear to be", "it appears you", "it seems you"
    ]

    private static let requiredActionVerbs: Set<String> = [
        "create", "generate", "explain", "compare", "organize", "draft",
        "open", "play", "start", "summarize", "extract", "diagnose",
        "improve", "rewrite", "plan", "check", "find", "make", "build",
        "analyze", "review", "synthesize", "help", "show", "identify",
        "suggest", "debug",
        // Phase 26 — friction-reduction verbs
        "put", "pin", "reopen", "restore", "resume", "collect", "arrange",
        "pre-load", "copy", "switch", "enable",
    ]

    public static func validate(_ title: String) -> Bool {
        let lower = title.lowercased()

        if let prefix = observationalPrefixes.first(where: { lower.hasPrefix($0) }) {
            print("[OpportunityValidator] rejected reason=observation_only prefix=\"\(prefix)\"")
            return false
        }

        let tokens = lower
            .components(separatedBy: CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters))
            .filter { !$0.isEmpty }

        guard tokens.contains(where: { requiredActionVerbs.contains($0) }) else {
            print("[OpportunityValidator] rejected reason=no_action_verb title=\"\(title.prefix(60))\"")
            return false
        }

        print("[OpportunityValidator] accepted title=\"\(title.prefix(60))\"")
        return true
    }
}

// MARK: - CandidateLifecycleAudit

final class CandidateLifecycleAudit {

	struct Record {
		let candidate: String
		let bucket: String
		var generated: Bool
		var rejected: Bool
		var selected: Bool
		var reason: String
		var score: Double?
	}

	private var records: [String: Record] = [:]
	private var order: [String] = []
	private let label: String
	private var domain: String = "unknown"
	private var workflow: String = "unknown"
	private var evidenceQuality: String = "unknown"
	private var selectedCandidate: String?
	private var selectedLane: String?
	private var visible: Bool = true

	init(label: String) {
		self.label = label
	}

	func updateContext(domain: String, workflow: String, evidenceQuality: String) {
		self.domain = domain
		self.workflow = workflow
		self.evidenceQuality = evidenceQuality
	}

	func setVisibility(_ visible: Bool) {
		self.visible = visible
	}

	func noteGenerated(candidate: String, bucket: String, score: Double? = nil, reason: String = "generated") {
		upsert(candidate: candidate, bucket: bucket) {
			$0.generated = true
			if let s = score { $0.score = s }
			if $0.reason.isEmpty || $0.reason == "not_generated" {
				$0.reason = reason
			}
		}
	}

	func noteNotGenerated(candidate: String, bucket: String, reason: String) {
		upsert(candidate: candidate, bucket: bucket) {
			$0.generated = false
			$0.rejected = false
			$0.selected = false
			$0.reason = reason
		}
	}

	func noteRejected(candidate: String, bucket: String, score: Double? = nil, reason: String) {
		upsert(candidate: candidate, bucket: bucket) {
			$0.generated = true
			$0.rejected = true
			$0.selected = false
			$0.reason = reason
			if let s = score { $0.score = s }
		}
	}

	func noteSelected(candidate: String, bucket: String, score: Double? = nil) {
		self.selectedCandidate = candidate
		self.selectedLane = bucket
		upsert(candidate: candidate, bucket: bucket) {
			$0.generated = true
			$0.rejected = false
			$0.selected = true
			$0.reason = "selected"
			if let s = score { $0.score = s }
		}
	}

	func closeSelection(selectedCandidate: String?) {
		let loserReason = selectedCandidate.map { "lost_to_\($0)" } ?? "survived_unselected"
		for key in order {
			guard var record = records[key] else { continue }
			guard record.generated, !record.rejected, !record.selected else { continue }
			record.reason = loserReason
			records[key] = record
		}
	}

	func emit() {
		for key in order {
			guard let record = records[key] else { continue }
			print("\n[CandidateLifecycle]")
			print("candidate=\(record.candidate)")
			print("lane=\(record.bucket)")
			print("generated=\(record.generated ? "yes" : "no")")
			if record.generated {
				print("rejected=\(record.rejected ? "yes" : "no")")
				print("selected=\(record.selected ? "yes" : "no")")
				if let s = record.score {
					print("score=\(String(format: "%.3f", s))")
				}
			}
			print("reason=\(record.reason)")
		}

		let generated = records.values.filter(\.generated).count
		let rejected = records.values.filter(\.rejected).count
		let survived = records.values.filter { $0.generated && !$0.rejected }.count
		
		print("\n[TickAudit]")
		print("grounding_domain=\(domain)")
		print("workflow=\(workflow)")
		print("evidence_quality=\(evidenceQuality)")
		print("generated=\(generated)")
		print("rejected=\(rejected)")
		print("survived=\(survived)")
		print("selected_candidate=\(selectedCandidate ?? "none")")
		print("selected_lane=\(selectedLane ?? "none")")
		print("visible=\(visible ? "yes" : "no")")

		let breakdown = bucketBreakdownSummary()
		if !breakdown.isEmpty {
			print("\nBreakdown:\n\(breakdown)")
		}
	}

	private func bucketBreakdownSummary() -> String {
		var bucketStates: [String: String] = [:]
		func priority(for state: String) -> Int {
			if state == "selected" { return 4 }
			if state.hasPrefix("rejected_") { return 3 }
			if state == "generated" { return 2 }
			return 1
		}

		for key in order {
			guard let record = records[key] else { continue }
			let state: String
			if record.selected {
				state = "selected"
			} else if record.rejected {
				state = "rejected_\(record.reason)"
			} else if !record.generated && !record.reason.isEmpty && record.reason != "not_generated" {
				// Phase 28: Treat specific "not generated" reasons as rejections in the breakdown
				state = "rejected_\(record.reason)"
			} else if record.generated {
				state = "generated"
			} else {
				state = "not_generated"
			}

			let existing = bucketStates[record.bucket]
			if existing == nil || priority(for: state) >= priority(for: existing!) {
				bucketStates[record.bucket] = state
			}
		}

		return bucketStates.keys.sorted().compactMap { bucket in
			guard let state = bucketStates[bucket] else { return nil }
			return "\(bucket)=\(state)"
		}.joined(separator: "\n")
	}

	private func upsert(candidate: String, bucket: String, mutate: (inout Record) -> Void) {
		if records[candidate] == nil {
			records[candidate] = Record(
				candidate: candidate,
				bucket: bucket,
				generated: false,
				rejected: false,
				selected: false,
				reason: ""
			)
			order.append(candidate)
		}
		guard var record = records[candidate] else { return }
		mutate(&record)
		records[candidate] = record
	}
}

// MARK: - OpportunityEngine

/// Phase 22.2 — Converts ambient signals into ranked, novelty-aware action opportunities.
///
/// Pipeline:
///   SemanticPriorityResolver → situation → OpportunityReasoner → validation
///   → OpportunityNoveltyTracker (mark shown) → ranked list
///
/// Design constraints:
/// - Zero model calls. Fully deterministic.
/// - create_next_steps is capped at score 0.25 — only surfaces if nothing specific qualifies.
/// - All titles must pass OpportunityValidator.
/// - Novelty tracker prevents repeating the same action on every refresh.
public enum OpportunityEngine {

    // MARK: - Public entry point

    /// Evaluates all available signals and returns a ranked, novelty-aware opportunity list.
    ///
    /// - Parameters:
    ///   - entityGrounding: Classification from EntityGroundingLayer (nil = legacy path).
    ///   - semanticState: Priority-resolved domain/mode/entityType from SemanticPriorityResolver.
    ///   - entityKey: Cache key for the novelty tracker. Defaults to memory.currentEntity.
    static func evaluate(
        determinerSignal: DeterminerSignal,
        activityState: ActivityState?,
        compartment: TaskCompartment?,
        memory: WorkingMemorySnapshot,
        evidenceQuality: String,
        entityGrounding: EntityGrounding? = nil,
        semanticState: SemanticPriorityResolver.SemanticState? = nil,
        entityKey: String? = nil,
        frictionSignals: [FrictionSignal] = [],
        mediaState: EnvironmentMediaState? = nil,
        appCategory: AppContextAnalyzer.Category? = nil,
        groundingResult: SemanticGroundingResult? = nil
    ) async -> [Opportunity] {
		let lifecycleAudit = CandidateLifecycleAudit(label: "opportunity_engine")
		var selectedLifecycleCandidate: String?
		let funnelAudit = ProposalFunnelAudit()
		defer {
			lifecycleAudit.closeSelection(selectedCandidate: selectedLifecycleCandidate)
			lifecycleAudit.emit()
		}

        // Canonical domain/mode/type — SemanticPriorityResolver wins over raw determiner
        let domain = semanticState?.domain ?? determinerSignal.inferredDomain
        let mode   = semanticState?.mode   ?? determinerSignal.inferredMode
        let resolvedEntityType = semanticState?.entityType
            ?? entityGrounding?.entityType
            ?? .unknown

		lifecycleAudit.updateContext(
			domain: domain.rawValue,
			workflow: (compartment?.workflow ?? .unknown).rawValue,
			evidenceQuality: evidenceQuality
		)

        let entityLabel = memory.currentEntity.isEmpty
            ? (compartment?.label ?? "")
            : memory.currentEntity

        // ── Entertainment / no-propose gate ──────────────────────────────────
        if let grounding = entityGrounding {
            print("[OpportunityEngine] grounding_type=\(grounding.entityType.rawValue)"
                + " grounding_confidence=\(String(format: "%.2f", grounding.confidence))"
                + " grounding_should_propose=\(grounding.shouldPropose)")

            if grounding.isEntertainment {
				lifecycleAudit.setVisibility(false)
				noteAllNotGenerated(lifecycleAudit, reason: "entertainment")
                print("[EntertainmentPolicy] suppressed entity_type=\(grounding.entityType.rawValue)"
                    + " entity=\"\(entityLabel.prefix(60))\"")
                print("[OpportunityEngine] suppressed reason=entertainment"
                    + " entity_type=\(grounding.entityType.rawValue)")
                print("[OpportunityEngine] top_opportunity=none")
                funnelAudit.emit()
                return []
            }

            if !grounding.shouldPropose {
				lifecycleAudit.setVisibility(false)
				noteAllNotGenerated(lifecycleAudit, reason: "grounding_no_propose")
                print("[OpportunityEngine] suppressed reason=grounding_no_propose"
                    + " entity_type=\(grounding.entityType.rawValue)")
                print("[OpportunityEngine] top_opportunity=none")
                funnelAudit.emit()
                return []
            }
        }

		// Phase 28: Seed all mandatory lanes to ensure they appear in TickAudit
		seedMandatoryLanes(lifecycleAudit)

        print("[OpportunityEngine] evaluated=yes domain=\(domain.rawValue)"
            + " mode=\(mode.rawValue)"
            + " entity_type=\(resolvedEntityType.rawValue)")

        let concepts = Set(memory.repeatedConcepts.map { $0.lowercased() })
        let errorTerms: Set<String> = ["error","exception","crash","failed","bug",
                                        "issue","broken","stack","trace","warning","undefined"]
        let resolvedKey = entityKey ?? entityLabel

        // ── Phase 26.2: ActionPortfolioEngine — evaluate all lanes ────────
        // No single lane monopolizes. Music, friction, workspace, research,
        // cognitive are all evaluated and ranked by composite score.
        let portfolioCandidates = await ActionPortfolioEngine.evaluate(
            frictionSignals: frictionSignals,
            mediaState: mediaState ?? EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "default", detectionAvailable: false),
            semanticState: semanticState,
            entityGrounding: entityGrounding,
            compartment: compartment,
            memory: memory,
            evidenceQuality: evidenceQuality,
            entityKey: resolvedKey,
            appCategory: appCategory,
            groundingResult: groundingResult,
			lifecycleAudit: lifecycleAudit,
            funnelAudit: funnelAudit
        )

        // If the portfolio has a winner, convert it to an Opportunity and return.
        // The portfolio winner is already ranked by score = usefulness * executability * confidence * novelty.
        if let winner = portfolioCandidates.first {
            let portfolioOpp = Opportunity(
                id: "opp:portfolio:\(winner.capabilityId):\(UUID().uuidString.prefix(6))",
                title: winner.title,
                capabilityId: winner.capabilityId,
                confidence: min(0.95, winner.confidence),
                reason: winner.reason,
                requiredEvidence: winner.requiredEvidence,
                actionability: winner.executability,
                inferredNeed: .planning,
                requiresConfirmation: winner.requiresConfirmation,
                auxiliaryCapabilityIds: [],
                involvedApps: winner.involvedApps,
                involvedURLs: supportingURLs(for: winner, compartment: compartment, memory: memory),
                browserTabTitles: supportingBrowserTabTitles(for: winner, compartment: compartment, memory: memory),
                generatedAction: winner.generatedAction,
                musicIntent: winner.musicIntent
            )

            print("[OpportunityEngine] portfolio_winner"
                + " lane=\(winner.lane.rawValue)"
                + " capability=\(winner.capabilityId)"
                + " score=\(String(format: "%.3f", winner.score))")
            print("[OpportunityEngine] top_opportunity capability=\(winner.capabilityId)"
                + " confidence=\(String(format: "%.2f", portfolioOpp.confidence))"
                + " need=\(winner.lane.rawValue)")
            print("[OpportunityEngine] top_title=\"\(winner.title.prefix(60))\"")
			let winnerLifecycleName = lifecycleName(for: winner.capabilityId, fallbackTitle: winner.title)
			selectedLifecycleCandidate = winnerLifecycleName

            OpportunityNoveltyTracker.shared.markShown(
                capabilityId: winner.capabilityId,
                entityKey: resolvedKey
            )

            // If the portfolio winner is from an executable lane (music/friction/workspace),
            // skip the GeneratedActionGenerator pipeline entirely.
            let executableLanes: Set<PortfolioCandidate.Lane> = [.music, .friction, .workspace, .metadata]
            if executableLanes.contains(winner.lane) {
				lifecycleAudit.noteSelected(
					candidate: winnerLifecycleName,
					bucket: lifecycleBucket(for: winner),
					score: winner.score
				)
				lifecycleAudit.noteNotGenerated(candidate: "generated_action", bucket: "generated_action", reason: "deterministic_portfolio_winner")
                print("[OpportunityBudget] deterministic=yes opportunities_count=1")
                funnelAudit.emit()
                return [portfolioOpp]
            }
        }

        let input = GeneratedActionInput(
            currentEntity: entityLabel,
            relatedEntities: memory.relatedFocusEntities + memory.comparisonCandidates,
            activeTerms: memory.repeatedConcepts,
            activeCompartmentLabel: compartment?.label,
            activeCompartmentWorkflow: compartment?.workflow,
            evidenceQuality: evidenceQuality,
            activeApplication: "",
            domain: domain,
            mode: mode,
            entityType: resolvedEntityType,
            hasErrorTerms: !concepts.intersection(errorTerms).isEmpty,
            hasMultipleSources: memory.relatedFocusEntities.count >= 2
                              || evidenceQuality == "browser_context",
            hasComparisonCandidates: memory.comparisonCandidates.count >= 2,
            confidenceSeed: max(
                semanticState?.entityConfidence ?? 0,
                entityGrounding?.confidence ?? 0,
                memory.workingMemoryTrust
            )
        )

        let generatedResult = GeneratedActionGenerator.generateDetailed(input: input)
        let generatedActions = generatedResult.actions
        var validated: [Opportunity] = []
		if generatedActions.isEmpty {
			if generatedResult.blockedForEvidence {
				lifecycleAudit.noteNotGenerated(candidate: "generated_action", bucket: "generated_action", reason: "content_primitive_requires_visible_content")
				print("[ProposalFunnelAudit] not_generated capability=generated_action reason=content_primitive_requires_visible_content")
				print("[OpportunityEngine] suppressed capability=generated_action reason=content_unavailable_metadata_only")
			} else {
				lifecycleAudit.noteNotGenerated(candidate: "generated_action", bucket: "generated_action", reason: "generator_returned_empty")
			}
		}

        let hasRealContent = EvidenceQualityModel.level(from: evidenceQuality).rank >= ProgressiveEvidenceLevel.visible_content.rank
        for action in generatedActions {
			let candidateName = lifecycleName(forGeneratedTitle: action.title)
			lifecycleAudit.noteGenerated(candidate: candidateName, bucket: "generated_action", score: action.confidence)
            let validation = ActionValidator.validate(action)
            guard validation.accepted else {
				lifecycleAudit.noteRejected(
					candidate: candidateName,
					bucket: "generated_action",
					score: action.confidence,
					reason: validation.rejectedReason ?? "validation_rejected"
				)
				continue
			}
            guard let composition = PrimitiveComposer.compose(
				action,
				evidenceQuality: evidenceQuality
			) else {
				lifecycleAudit.noteRejected(
					candidate: candidateName, 
					bucket: "generated_action", 
					score: action.confidence,
					reason: "primitive_composition_failed"
				)
                print("[OpportunityEngine] suppressed reason=primitive_composition_failed")
                continue
            }
            let composed = composition.action

            // Phase 26.2 — ProposalQualityFilter: reject keyword-list reviews, generic title reviews, title-only checklists
            let capId = composition.intentType.rawValue
			let quality = ProposalQualityFilter.acceptanceResult(
                title: composed.title,
                capabilityId: capId,
                evidenceQuality: evidenceQuality,
                hasRealContent: hasRealContent
            )
            guard quality.accepted else {
				lifecycleAudit.noteRejected(
					candidate: candidateName,
					bucket: "generated_action",
					score: composed.confidence,
					reason: quality.reason ?? "proposal_quality_rejected"
				)
				continue
			}

            let need = need(for: composed, intent: composition.intentType)
            validated.append(Opportunity(
                id: "opp:generated:\(composed.id)",
                title: composed.title,
                capabilityId: "generated_action",
                confidence: composed.confidence,
                reason: composed.reasoning,
                requiredEvidence: evidenceQuality,
                actionability: min(0.95, composition.confidence),
                inferredNeed: need,
                requiresConfirmation: false,
                auxiliaryCapabilityIds: [],
                generatedAction: composed
            ))
        }

        // Phase 28.2: Compare portfolio cognitive/research winner against best generated action.
        // Don't unconditionally prefer portfolio — let the higher score win.
        if let winner = portfolioCandidates.first,
           (winner.lane == .cognitive || winner.lane == .research) {

            let bestGenerated = validated.first
            let portfolioScore = winner.score
            let generatedScore = bestGenerated?.confidence ?? 0

            print("[SelectionAudit]")
            print("portfolio_winner=\(winner.capabilityId) score=\(String(format: "%.3f", portfolioScore))")
            if let gen = bestGenerated {
                print("generated_action=\(gen.title.prefix(60)) score=\(String(format: "%.3f", generatedScore))")
            } else {
                print("generated_action=none score=0.000")
            }

            if generatedScore > portfolioScore, let gen = bestGenerated {
                // Generated action wins
                print("winner=generated_action")
                let topName = lifecycleName(forGeneratedTitle: gen.title)
                selectedLifecycleCandidate = topName
                lifecycleAudit.noteSelected(candidate: topName, bucket: "generated_action", score: gen.confidence)

                let winnerName = lifecycleName(for: winner.capabilityId, fallbackTitle: winner.title)
                lifecycleAudit.noteGenerated(candidate: winnerName, bucket: lifecycleBucket(for: winner), score: winner.score, reason: "lost_to_generated_action")

                // Fall through to the generated action return path below
            } else {
                // Portfolio cognitive winner still wins
                print("winner=\(winner.capabilityId)")
                let portfolioOpp = Opportunity(
                    id: "opp:portfolio:\(winner.capabilityId):\(UUID().uuidString.prefix(6))",
                    title: winner.title,
                    capabilityId: winner.capabilityId,
                    confidence: min(0.95, winner.confidence),
                    reason: winner.reason,
                    requiredEvidence: winner.requiredEvidence,
                    actionability: winner.executability,
                    inferredNeed: .planning,
                    requiresConfirmation: winner.requiresConfirmation,
                    auxiliaryCapabilityIds: [],
                    involvedApps: winner.involvedApps,
                    involvedURLs: supportingURLs(for: winner, compartment: compartment, memory: memory),
                    browserTabTitles: supportingBrowserTabTitles(for: winner, compartment: compartment, memory: memory),
                    generatedAction: winner.generatedAction,
                    musicIntent: winner.musicIntent
                )
                print("[OpportunityEngine] portfolio_cognitive_winner capability=\(winner.capabilityId)")
                OpportunityNoveltyTracker.shared.markShown(
                    capabilityId: winner.capabilityId,
                    entityKey: resolvedKey
                )
                let winnerName = lifecycleName(for: winner.capabilityId, fallbackTitle: winner.title)
                selectedLifecycleCandidate = winnerName
                lifecycleAudit.noteSelected(
                    candidate: winnerName,
                    bucket: lifecycleBucket(for: winner),
                    score: winner.score
                )
                print("[OpportunityBudget] deterministic=yes opportunities_count=1")
                funnelAudit.emit()
                return [portfolioOpp]
            }
        }

        if validated.isEmpty {
			lifecycleAudit.setVisibility(false)
			lifecycleAudit.noteRejected(candidate: "generated_action", bucket: "generated_action", reason: "no_validated_generated_action")
            print("[OpportunityEngine] suppressed reason=no_generated_action")
            print("[OpportunityEngine] top_opportunity=none")
            funnelAudit.emit()
            return []
        }

        // ── Log and mark shown ────────────────────────────────────────────────
        if let top = validated.first {
			let topCandidateName = lifecycleName(forGeneratedTitle: top.title)
			selectedLifecycleCandidate = topCandidateName
			lifecycleAudit.noteSelected(
				candidate: topCandidateName, 
				bucket: "generated_action",
				score: top.confidence
			)
            print("[OpportunityEngine] top_opportunity action=generated_action"
                + " confidence=\(String(format: "%.2f", top.confidence))"
                + " need=\(top.inferredNeed.rawValue)")
            print("[OpportunityEngine] top_title=\"\(top.title)\"")
            OpportunityNoveltyTracker.shared.markShown(
                capabilityId: top.generatedAction?.id ?? top.title,
                entityKey: resolvedKey
            )
        }

        print("[OpportunityBudget] deterministic=yes opportunities_count=\(validated.count)")
        funnelAudit.emit()
        return validated
    }

    // MARK: - Title builder (action-verb first, entity-aware)

    /// Produces an action-verb-first title for the given capability.
    static func title(forCapabilityId capId: String, entity: String) -> String {
        let short = String(entity.prefix(38)).trimmingCharacters(in: .whitespaces)
        let e = short.isEmpty ? nil : short

        switch capId {
        // Study
        case "generate_quiz":
            return e.map { "Generate practice questions for \($0)" }
                   ?? "Generate practice questions for this material"
        case "create_review_plan":
            return e.map { "Create a review plan for \($0)" }
                   ?? "Create a review plan for this material"
        case "create_study_outline":
            return e.map { "Create a study outline for \($0)" }
                   ?? "Create a study outline for this material"
        case "create_flashcards":
            return e.map { "Create flashcards for \($0)" }
                   ?? "Create flashcards for this topic"
        case "extract_key_terms":
            return "Extract the key terms and definitions here"
        case "make_study_schedule":
            return e.map { "Create a study schedule for \($0)" }
                   ?? "Create a study schedule for this material"
        case "explain_topic":
            return e.map { "Explain the key concepts in \($0)" }
                   ?? "Explain the key concepts here"
        // Game / creative code
        case "generate_test_checklist":
            return e.map { "Create a testing checklist for \($0)" }
                   ?? "Create a testing checklist for this project"
        case "create_game_design_checklist":
            return e.map { "Create a game design checklist for \($0)" }
                   ?? "Create a game design checklist"
        case "create_controls_polish_checklist":
            return "Create a controls and polish checklist"
        case "create_asset_sound_checklist":
            return "Create an asset and sound review checklist"
        case "create_bug_reproduction_plan":
            return "Create a bug reproduction plan"
        case "suggest_next_feature":
            return e.map { "Suggest the next feature to build in \($0)" }
                   ?? "Suggest the next feature to build"
        // Code
        case "diagnose_error":
            return "Diagnose the current error"
        case "debug_performance":
            return e.map { "Find performance issues in \($0)" }
                   ?? "Find performance issues in this project"
        case "explain_code_context":
            return e.map { "Explain the code structure of \($0)" }
                   ?? "Explain the code structure here"
        case "suggest_refactor_plan":
            return "Suggest a refactoring plan for the current code"
        // Research
        case "synthesize_sources":
            return "Synthesize the sources you've opened into notes"
        case "extract_open_questions":
            return "Extract the open questions from this research"
        case "create_research_outline":
            return "Create a research outline from what you've read"
        case "summarize_reference":
            return e.map { "Summarize \($0)" }
                   ?? "Summarize this reference"
        // Shopping
        case "compare_options":
            return "Compare the options you're viewing"
        case "decision_matrix":
            return "Build a decision matrix for this comparison"
        case "compare_rental_options":
            return "Compare the rental posts you're viewing?"
        case "draft_listing_ad":
            return "Draft a rental listing from the details you have?"
        case "create_listing_checklist":
            return "Draft a checklist for your rental ad?"
        case "extract_pricing_guidance":
            return "Extract pricing guidance from these threads?"
        case "identify_missing_listing_details":
            return "List missing details for the room posting?"
        case "create_questions_to_ask_landlord":
            return "Create questions to ask the landlord?"
        case "compare_listing_platforms":
            return "Compare listing platforms for this search?"
        case "summarize_thread":
            return "Summarize what these renters are saying?"
        case "synthesize_advice":
            return "Compare the rental advice from these posts?"
        case "summarize_context":
            return "Summarize the current context"
        // Communication
        case "draft_reply":
            return "Draft a reply to this message"
        case "extract_action_items":
            return "Extract action items from this thread"
        // Fallback (capped, rare)
        case "create_next_steps":
            return e.map { "Create next steps for \($0)" }
                   ?? "Create next steps for the current task"
        // Legacy / misc
        case "create_checklist":
            return e.map { "Create a checklist for \($0)" }
                   ?? "Create a checklist for this session"
        case "improve_project":
            return e.map { "Improve \($0)" }
                   ?? "Improve this project"
        case "explain_context":
            return "Explain the key concepts here"
        // Phase 26 — friction-reduction capabilities
        case "restore_workspace":
            return e.map { "Open your usual \($0) setup?" }
                   ?? "Restore your usual workspace?"
        case "arrange_side_by_side":
            if let e = e {
                return "Put \(e) beside the other open tab?"
            }
            return "Put the apps you keep switching between side by side?"
        case "switch_to_paired_app":
            return e.map { "Switch back to \($0)?" }
                   ?? "Switch back to the other app you keep revisiting?"
        case "pin_reference_tabs":
            return "Collect the tabs you keep switching between?"
        case "restore_research_tabs":
            return "Restore the tabs you keep switching between?"
        case "split_research_setup":
            return "Put these research windows side by side?"
        case "collect_references":
            return "Collect the references you keep looking up?"
        case "resume_focus_media":
            return "Resume the playlist you usually use here?"
        case "extract_and_organize":
            return "Extract the content you keep copying between apps?"
        case "precompute_answer":
            return "Pre-load the answer you keep asking for?"
        default:
            return "Help with the current task"
        }
    }

    // MARK: - Helpers

    private static func make(
        capId: String,
        need: Need,
        entity: String,
        confidence: Double,
        evidence: String,
        actionability: Double = 0.80,
        requiresConfirmation: Bool = false,
        aux: [String] = []
    ) -> Opportunity {
        Opportunity(
            id: "opp:\(need.rawValue):\(capId):\(UUID().uuidString.prefix(6))",
            title: title(forCapabilityId: capId, entity: entity),
            capabilityId: capId,
            confidence: min(0.95, confidence),
            reason: need.rawValue,
            requiredEvidence: evidence,
            actionability: actionability,
            inferredNeed: need,
            requiresConfirmation: requiresConfirmation,
            auxiliaryCapabilityIds: aux,
			generatedAction: nil
        )
    }

    private static func makeFallback(entity: String, evidenceQuality: String) -> Opportunity {
        print("[OpportunityEngine] fallback=create_next_steps reason=legacy_no_grounding")
        return Opportunity(
            id: "opp:nextSteps:create_next_steps:fallback",
            title: title(forCapabilityId: "create_next_steps", entity: entity),
            capabilityId: "create_next_steps",
            confidence: 0.35,
            reason: "safe_fallback_no_grounding",
            requiredEvidence: "title_only",
            actionability: 0.75,
            inferredNeed: .nextSteps,
            requiresConfirmation: false,
            auxiliaryCapabilityIds: [],
			generatedAction: nil
        )
    }

	private static func supportingWorkspacePattern(
		for candidate: PortfolioCandidate,
		compartment: TaskCompartment?,
		memory: WorkingMemorySnapshot
	) -> WorkspacePattern? {
		let patterns = WorkspacePatternTracker.shared.knownPatterns()
		guard !patterns.isEmpty else { return nil }

		let appHints = Set(candidate.involvedApps.map { $0.lowercased() })
		let tabHints = Set((compartment?.browserTabs ?? []).map { $0.lowercased() })
		let relatedHints = Set((memory.relatedFocusEntities + memory.comparisonCandidates).map { $0.lowercased() })

		return patterns.max { lhs, rhs in
			patternSupportScore(lhs, appHints: appHints, tabHints: tabHints, relatedHints: relatedHints)
				< patternSupportScore(rhs, appHints: appHints, tabHints: tabHints, relatedHints: relatedHints)
		}
	}

	private static func patternSupportScore(
		_ pattern: WorkspacePattern,
		appHints: Set<String>,
		tabHints: Set<String>,
		relatedHints: Set<String>
	) -> Int {
		let patternApps = Set(pattern.apps.map { $0.lowercased() })
		let patternTabs = Set(pattern.tabTitles.map { $0.lowercased() })
		let appOverlap = patternApps.intersection(appHints).count * 4
		let tabOverlap = patternTabs.intersection(tabHints).count * 3
		let relatedOverlap = patternTabs.intersection(relatedHints).count * 2
		let urlScore = min(pattern.urls.count, 4)
		return appOverlap + tabOverlap + relatedOverlap + urlScore + pattern.frequency
	}

	private static func supportingURLs(
		for candidate: PortfolioCandidate,
		compartment: TaskCompartment?,
		memory: WorkingMemorySnapshot
	) -> [String] {
		switch candidate.capabilityId {
		case "restore_workspace", "restore_research_tabs", "split_research_setup":
			let pattern = supportingWorkspacePattern(for: candidate, compartment: compartment, memory: memory)
			return Array((pattern?.urls ?? []).prefix(8))
		case "copy_current_url", "collect_references", "remember_workspace":
			if let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName,
			   let browser = BrowserContextExtractor.extract(appName: frontmost, activeAppPID: nil),
			   let url = browser.selectedURL?.absoluteString ?? browser.currentURL?.absoluteString,
			   !url.isEmpty {
				return [url]
			}
			let pattern = supportingWorkspacePattern(for: candidate, compartment: compartment, memory: memory)
			return Array((pattern?.urls ?? []).prefix(8))
		default:
			return []
		}
	}

	private static func supportingBrowserTabTitles(
		for candidate: PortfolioCandidate,
		compartment: TaskCompartment?,
		memory: WorkingMemorySnapshot
	) -> [String] {
		var titles = compartment?.browserTabs.sorted() ?? []
		if titles.isEmpty {
			titles = memory.relatedFocusEntities
		}
		if let pattern = supportingWorkspacePattern(for: candidate, compartment: compartment, memory: memory) {
			let merged = Array(Set(titles + pattern.tabTitles)).sorted()
			return Array(merged.prefix(10))
		}
		return Array(titles.prefix(10))
	}

	private static func need(for action: GeneratedActionProposal, intent: IntentType) -> Need {
		switch intent {
		case .compare: return .comparison
		case .extract: return .organization
		case .explain: return action.workflow == .debugging ? .debugging : .explanation
		case .organize, .structure: return .organization
		case .synthesize: return .synthesis
		case .summarize: return .summarization
		case .answer: return action.workflow == .studying ? .recall : .explanation
		default:
			switch action.workflow {
			case .debugging: return .debugging
			case .studying: return .recall
			case .research: return .synthesis
			case .comparing: return .comparison
			default: return .planning
			}
		}
	}

	private static func lifecycleName(for capabilityId: String, fallbackTitle: String) -> String {
		// Phase 28.2: Preserve actual capabilityId — never remap identities.
		// synthesize_sources stays synthesize_sources, not collect_references.
		// collect_references only appears when FrictionOpportunityReasoner explicitly emits it.
		let trimmed = capabilityId.trimmingCharacters(in: .whitespacesAndNewlines)
		if !trimmed.isEmpty {
			print("[CandidateIdentity] portfolio_capability=\(trimmed) lifecycle_candidate=\(trimmed) ok=yes")
			return trimmed
		}
		let fallback = lifecycleName(forGeneratedTitle: fallbackTitle)
		print("[CandidateIdentity] portfolio_capability=(empty) lifecycle_candidate=\(fallback) ok=fallback")
		return fallback
	}

	private static func lifecycleName(forGeneratedTitle title: String) -> String {
		let normalized = title
			.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
			.joined(separator: "_")
		return normalized.isEmpty ? "generated_action" : normalized
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

	// Phase 28.2: Use actual capabilityIds as lifecycle names — no aliases.
	// collect_references only appears when friction lane actually emits it.
	private static func seedMandatoryLanes(_ audit: CandidateLifecycleAudit) {
		audit.noteNotGenerated(candidate: "play_focus_media", bucket: "music", reason: "not_generated")
		audit.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: "not_generated")
		audit.noteNotGenerated(candidate: "synthesize_sources", bucket: "research", reason: "not_generated")
		audit.noteNotGenerated(candidate: "compare_options", bucket: "comparison", reason: "not_generated")
		audit.noteNotGenerated(candidate: "review_architecture", bucket: "coding", reason: "not_generated")
		audit.noteNotGenerated(candidate: "generated_action", bucket: "generated_action", reason: "not_generated")
	}

	private static func noteAllNotGenerated(_ audit: CandidateLifecycleAudit, reason: String) {
		audit.noteNotGenerated(candidate: "play_focus_media", bucket: "music", reason: reason)
		audit.noteNotGenerated(candidate: "restore_workspace", bucket: "workspace", reason: reason)
		audit.noteNotGenerated(candidate: "synthesize_sources", bucket: "research", reason: reason)
		audit.noteNotGenerated(candidate: "compare_options", bucket: "comparison", reason: reason)
		audit.noteNotGenerated(candidate: "review_architecture", bucket: "coding", reason: reason)
		audit.noteNotGenerated(candidate: "generated_action", bucket: "generated_action", reason: reason)
	}
}
