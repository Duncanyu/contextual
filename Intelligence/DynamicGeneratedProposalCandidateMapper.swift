import Foundation

/// Maps validated LLM proposals into execution proposal candidates (T18.3.1).
enum DynamicGeneratedProposalCandidateMapper {

	static func candidates(
		from result: DynamicGeneratedProposalResult,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		budget: ExecutionBudget,
		referenceTime: Date = Date()
	) -> [GeneratedExecutionProposalCandidate] {
		let effectiveSnapshot = result.contextSnapshot ?? snapshot
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
		let grounding = extractor.extract(from: effectiveSnapshot)
		let sanityFilter = AgenticProposalSanityFilter()
		let groundedProposals = sanityFilter.filter(
			proposals: result.proposals,
			grounding: grounding,
			snapshot: effectiveSnapshot
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

		// Phase 4P — Isolate the snapshot once so all candidates are validated
		// against the same sanitized active context (clipboard / dev / log
		// artifacts excluded). Early stage validation that ran in the planner
		// now uses the same isolated context, so early ≠ activation rejections
		// can no longer disagree on the same title.
		let isolated = ProposalContextIsolationGate.isolate(snapshot: effectiveSnapshot)

		let mapped = groundedProposals.compactMap { proposal -> GeneratedExecutionProposalCandidate? in
			let validation = ProposalCapabilityValidator.validate(
				title: proposal.title,
				goal: proposal.expectedOutcome,
				isolated: isolated,
				stage: "activation"
			)
			guard validation.accepted else {
				print("[ProposalValidation] rejected stage=activation reason=unsupported_title title=\"\(proposal.title)\" detail=\(validation.reason)")
				return nil
			}

			let alignment = AgenticGoalAlignmentValidator.validate(
				title: proposal.title,
				goal: proposal.expectedOutcome,
				workflow: proposal.workflowType.rawValue,
				appName: effectiveSnapshot.activeApp,
				bundleId: effectiveSnapshot.bundleIdentifier ?? "",
				windowTitle: effectiveSnapshot.windowTitle,
				ocrExcerpt: effectiveSnapshot.recentOCRExcerpt,
				axExcerpt: nil
			)

			if alignment.status == .rejected {
				print("[ProposalValidation] rejected reason=goal_alignment_failed title=\"\(proposal.title)\" goal=\"\(proposal.expectedOutcome)\"")
				return nil
			}

			var finalProposal = proposal
			if alignment.status == .repaired {
				print("[ProposalValidation] repaired reason=redundant_search_to_extract_context original=\"\(proposal.expectedOutcome)\" repaired=\"\(alignment.alignedGoal)\"")
				// Phase 4Q — surface the capability-repair as a dedicated log family so
				// dogfood can see when a navigation/search candidate was internally
				// redirected to an in-envelope gather goal (visible title is preserved
				// when safe; the existing safety validator above rejects anything unsafe).
				let repairReason: String = {
					switch alignment.detectedIssue {
					case "redundant_search_current_context": return "unsupported_search_current_context"
					case "generic_summary_on_product_page": return "generic_summary_on_product_page"
					default: return alignment.detectedIssue.isEmpty ? "capability_aligned" : alignment.detectedIssue
					}
				}()
				print("[CapabilityRepair] applied=yes reason=\(repairReason)")
				print("[CapabilityRepair] original=\"\(proposal.expectedOutcome)\"")
				print("[CapabilityRepair] repaired_goal=\"\(alignment.alignedGoal)\"")
				print("[CapabilityRepair] visible_title_policy=preserve_if_safe_else_reject")
				var alignedPlan: AgenticTaskPlan? = nil
				if let originalPlan = proposal.agenticPlan {
					alignedPlan = AgenticTaskPlan(
						id: originalPlan.id,
						goal: alignment.alignedGoal,
						workflow: originalPlan.workflow,
						sourceProposalId: originalPlan.sourceProposalId,
						allowedActionFamilies: originalPlan.allowedActionFamilies,
						requiredObservations: originalPlan.requiredObservations,
						successCriteria: originalPlan.successCriteria,
						stopConditions: originalPlan.stopConditions,
						maxSteps: originalPlan.maxSteps,
						maxLLMCalls: originalPlan.maxLLMCalls,
						maxOCRCalls: originalPlan.maxOCRCalls,
						maxRuntimeSeconds: originalPlan.maxRuntimeSeconds,
						requiresPermission: originalPlan.requiresPermission,
						safetyLevel: originalPlan.safetyLevel,
						createdAt: originalPlan.createdAt
					)
				}
				finalProposal = ValidatedDynamicGeneratedProposal(
					id: proposal.id,
					title: proposal.title,
					description: proposal.description,
					workflowType: proposal.workflowType,
					intentType: proposal.intentType,
					expectedOutcome: alignment.alignedGoal,
					requiredContextTypes: proposal.requiredContextTypes,
					suggestedPrimitives: proposal.suggestedPrimitives,
					interruptionCost: proposal.interruptionCost,
					confidence: proposal.confidence,
					usefulnessHint: proposal.usefulnessHint,
					agenticPlan: alignedPlan
				)
			}

			return mapCandidate(
				proposal: finalProposal,
				snapshot: effectiveSnapshot,
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

		let targetAnchor: TargetWindowAnchor? = {
			guard let bundle = snapshot.bundleIdentifier else { return nil }
			let fp = TargetWindowAnchor.fingerprint(
				bundleIdentifier: bundle,
				windowTitle: snapshot.windowTitle,
				workflow: proposal.workflowType
			)
			return TargetWindowAnchor(
				bundleIdentifier: bundle,
				appName: snapshot.activeApp,
				windowTitle: snapshot.windowTitle,
				contextFingerprint: fp,
				createdAt: referenceTime,
				sourceCandidateId: proposal.id
			)
		}()

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
			targetAnchor: targetAnchor,
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
