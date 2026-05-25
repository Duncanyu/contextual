import Foundation

/// Maps validated LLM proposals into execution proposal candidates (T18.3.1).
enum DynamicGeneratedProposalCandidateMapper {

	static func candidates(
		from result: DynamicGeneratedProposalResult,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		budget: ExecutionBudget,
		referenceTime: Date = Date()
	) -> [GeneratedExecutionProposalCandidate] {
		let att = ProposalAttemptScope.currentId ?? "none"
		print("[ProposalAttempt] id=\(att) contract_created count=\(result.hookContracts.count)")

		guard result.shouldChimeIn else {
			print("[ProposalActivationBridge] synthesized_count=\(result.proposals.count) contract_count=\(result.hookContracts.count) should_chime=false activation_candidate_count=0 suppression_reason=should_chime_false source_pipeline=\(result.reason)")
			return []
		}

		// Phase 4F — Intent Grounding / Proposal Sanity Filter.
		// Extract semantic anchors from the current snapshot and reject proposals that are
		// semantically misaligned before they become visible to the user.
		let extractor = AgenticIntentGroundingExtractor()
		let grounding = extractor.extract(from: snapshot)
		let sanityFilter = AgenticProposalSanityFilter()
		let groundedProposals = sanityFilter.filter(
			proposals: result.proposals,
			grounding: grounding,
			snapshot: snapshot
		)
		let sanityRejected = result.proposals.count - groundedProposals.count
		if sanityRejected > 0 {
			print("[ProposalActivationBridge] sanity_filter_rejected=\(sanityRejected) passed=\(groundedProposals.count) total=\(result.proposals.count) domain=\(grounding.dominantTopic)")
		}

		// Build a proposal-id → execution-mode map from the accompanying hook contracts.
		// Hook-composer proposals carry a contract whose hookPlanIds determine the mode.
		let contractModeMap: [String: HookExecutionMode] = Dictionary(
			uniqueKeysWithValues: result.hookContracts.map { ($0.id, $0.executionMode) }
		)

		let mapped = groundedProposals.compactMap { proposal in
			mapCandidate(
				proposal: proposal,
				snapshot: snapshot,
				budget: budget,
				requiresVisual: result.requiresVisualContext,
				referenceTime: referenceTime,
				executionMode: contractModeMap[proposal.id] ?? .one_shot
			)
		}

		// Per-proposal trace (over grounded proposals only — rejected ones already logged above)
		for proposal in groundedProposals {
			let mapped_ok = mapped.contains(where: { $0.id == proposal.id })
			let isHookComposer = proposal.usefulnessHint.hasPrefix("hook_composer")
			let proposalType = isHookComposer ? "hook_composer" : "llm_dynamic"
			let suppressionReason: String
			if !mapped_ok {
				let prims = proposal.suggestedPrimitives
				suppressionReason = prims.isEmpty && !isHookComposer ? "primitives_empty_non_hook" : "map_returned_nil"
			} else {
				suppressionReason = "none"
			}
			print("[ProposalActivationBridge] proposal_id=\(proposal.id.prefix(60)) proposal_type=\(proposalType) hint=\(proposal.usefulnessHint) primitives=\(proposal.suggestedPrimitives.count) mapped=\(mapped_ok) suppression_reason=\(suppressionReason) source_pipeline=\(result.reason)")
		}

		let droppedByMap = groundedProposals.count - mapped.count
		let suppressionSummary: String
		if sanityRejected > 0 && droppedByMap > 0 {
			suppressionSummary = "sanity_rejected_\(sanityRejected)+map_nil_\(droppedByMap)"
		} else if sanityRejected > 0 {
			suppressionSummary = "sanity_rejected_\(sanityRejected)"
		} else if droppedByMap > 0 {
			suppressionSummary = "map_returned_nil_for_\(droppedByMap)"
		} else {
			suppressionSummary = "none"
		}
		print("[ProposalActivationBridge] synthesized_count=\(result.proposals.count) grounded_count=\(groundedProposals.count) contract_count=\(result.hookContracts.count) should_chime=\(result.shouldChimeIn) activation_candidate_count=\(mapped.count) suppression_reason=\(suppressionSummary) source_pipeline=\(result.reason)")

		return mapped
	}

	private static func mapCandidate(
		proposal: ValidatedDynamicGeneratedProposal,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		budget: ExecutionBudget,
		requiresVisual: Bool,
		referenceTime: Date,
		executionMode: HookExecutionMode = .one_shot
	) -> GeneratedExecutionProposalCandidate? {
		let primitives = proposal.suggestedPrimitives

		// usefulnessHint variants:
		//   "hook_composer_model"   — legacy fixed-chain, live LLM
		//   "hook_composer_cache"   — legacy fixed-chain, from cache
		//   "hook_composer_agentic" — intent-first agentic path (primitives empty; runtime decides)
		// All use hasPrefix("hook_composer") to unify treatment.
		let isHookComposer = proposal.usefulnessHint.hasPrefix("hook_composer")
		let isAgentic = proposal.usefulnessHint == "hook_composer_agentic"

		// Non-hookComposer proposals must have primitives — they drive the fixed executor.
		// HookComposer / agentic proposals are allowed through with empty primitives:
		// the runtime (or the bounded agentic executor) selects the actual execution steps.
		if !isHookComposer {
			guard !primitives.isEmpty else {
				print("[ProposalActivationBridge] mapCandidate_rejected id=\(proposal.id.prefix(60)) reason=primitives_empty_non_hook hint=\(proposal.usefulnessHint)")
				return nil
			}
		}

		let requiresVision = requiresVisual
			|| proposal.requiredContextTypes.contains(.fusedVisual)
			|| proposal.requiredContextTypes.contains(.screenCapture)
		let requiresOCR = proposal.requiredContextTypes.contains(.screenCapture)

		let plan = ExecutionPlan(
			primitives: primitives,
			estimatedCost: isAgentic ? 0.35 : 0.28 + Double(primitives.count) * 0.07,
			estimatedRuntime: isAgentic ? 20 : TimeInterval(10 + primitives.count * 7),
			requiresVision: requiresVision,
			requiresOCR: requiresOCR,
			requiresUserIntent: true,
			requiredPermissions: requiresVision || requiresOCR ? [.screenRecording] : [.none],
			fallbackBehavior: .degradeToSummary,
			executionBudget: budget,
			planConfidence: proposal.confidence
		)

		let sourceTag = isHookComposer ? "hook_composer" : "llm_dynamic"
		let primSigPart = primitives.isEmpty
			? "agentic:\(proposal.workflowType.rawValue):\(proposal.intentType.rawValue)"
			: primitives.map(\.rawValue).joined(separator: ",")
		let explainability = "\(sourceTag)|\(proposal.usefulnessHint)|primitives=\(primSigPart)|contract=\(proposal.id.prefix(60))"
		let generationSource: GenerationSource = isHookComposer ? .hookComposer : .generatedAction

		let execution = GeneratedExecutionAction(
			title: proposal.title,
			description: proposal.description,
			workflowType: proposal.workflowType,
			intentType: proposal.intentType,
			confidence: proposal.confidence,
			interruptionCost: proposal.interruptionCost,
			requiredContextTypes: proposal.requiredContextTypes,
			executionPlan: plan,
			explainabilitySummary: explainability,
			generationSource: generationSource,
			createdAt: referenceTime,
			expirationDate: referenceTime.addingTimeInterval(180),
			isReusable: false,
			reuseScore: snapshot.workflowConfidence
		)

		let candidateSource: GeneratedExecutionProposalSource = isHookComposer ? .hookComposer : .generatedExecution
		// Non-empty primitive signature — avoids collisions with the empty-string suppression set.
		let primSig: String? = primSigPart.isEmpty ? nil : primSigPart

		print("[ProposalActivationBridge] mapCandidate_ok id=\(proposal.id.prefix(60)) source=\(candidateSource.rawValue) hint=\(proposal.usefulnessHint) primitives=\(primitives.count) agentic=\(isAgentic) confidence=\(String(format: "%.2f", proposal.confidence))")

		var candidate = GeneratedExecutionProposalCandidate(
			id: proposal.id,
			title: proposal.title,
			description: proposal.description,
			source: candidateSource,
			workflowType: proposal.workflowType,
			intentType: proposal.intentType,
			confidence: proposal.confidence,
			interruptionCost: proposal.interruptionCost,
			explainabilitySummary: explainability,
			expectedOutputSummary: proposal.expectedOutcome,
			requiredContextTypes: proposal.requiredContextTypes,
			executionAction: execution,
			generatedActionId: nil,
			primitiveSignature: primSig,
			isExecutableGeneratedProposal: true,
			executionMode: executionMode
		)
		// Carry the AgenticTaskPlan so the execution router can direct to AgenticRuntime.
		candidate.agenticPlan = proposal.agenticPlan
		return candidate
	}
}
