import Foundation

/// Deterministic planning pipeline:
/// - Input: `TaskInferenceResult` (goal + capability categories; no hook ids).
/// - Retrieves hooks by category.
/// - Plans a bounded executable hook chain.
/// - Emits `DynamicGeneratedActionContract` + `ValidatedDynamicGeneratedProposal`.
///
/// No large model calls. No hardcoded user behavior labels. Hooks are the building blocks.
enum TaskInferencePlanningPipeline {

	struct PlanningOutput: Sendable, Equatable {
		let contract: DynamicGeneratedActionContract
		let proposal: ValidatedDynamicGeneratedProposal
	}

	static func compose(
		inference: TaskInferenceResult,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		recentTitles: [String],
		registry: HookCapabilityRegistry = .shared,
		referenceTime: Date = Date()
	) async -> PlanningOutput? {
		guard inference.shouldChime else { return nil }
		guard inference.confidence >= 0.42 else { return nil }

		let cats = normalizeCats(inference.neededCapabilityCategories)

		// Entry banner — proves the hook-composition layer was reached.
		print("[HookCompositionPipeline] entering goal=\"\(String(inference.possibleUserGoal.prefix(60)))\" categories=[\(cats.joined(separator: ","))] confidence=\(String(format: "%.2f", inference.confidence))")

		guard !cats.isEmpty else {
			print("[HookCompositionPipeline] skipped reason=no_needCats")
			return nil
		}

		// Task 1 — Situational utility gate.
		// Evaluated before hook retrieval so we don't waste model budget on low-value chains.
		let utility = ProposalUtilityScorer.evaluate(
			goal: inference.possibleUserGoal,
			cats: cats,
			snapshot: snapshot,
			situational: situational
		)
		if utility.shouldReject {
			print("[HookCompositionPipeline] skipped reason=low_utility score=\(String(format: "%.2f", utility.score))")
			return nil
		}

		// 1) Retrieve hooks by category (not a global top-k list).
		async let retrievedAsync: [HookCapabilityDefinition] = HookCategoryRetriever.retrieveAsync(
			needCats: cats,
			snapshot: snapshot,
			situational: situational,
			registry: registry
		)
		async let safetyAsync: HookPlanningSafetyEvaluation = HookPlanningSafetyChecker.evaluateAsync(
			needCats: cats,
			snapshot: snapshot,
			situational: situational
		)

		let retrieved = await retrievedAsync
		let safety = await safetyAsync
		if safety.shouldAbort {
			print("[HookPlanner] skipped reason=\(safety.abortReason ?? "safety_abort")")
			return nil
		}
		if retrieved.isEmpty {
			print("[HookValidation] result=fail reason=no_hooks_available")
			print("[HookCompositionPipeline] skipped reason=no_valid_hooks")
			return nil
		}

		// 2) Multi-pass hook script discovery (Parts C + D + E).
		guard let planHookIds = await HookScriptDiscovery.buildChain(
			goal: inference.possibleUserGoal,
			candidates: retrieved,
			snapshot: snapshot,
			situational: situational
		) else {
			print("[HookValidation] result=fail reason=no_script_plan")
			print("[HookCompositionPipeline] skipped reason=no_script_plan")
			return nil
		}
		print("[HookPlanLLM] parsed chain=[\(planHookIds.joined(separator: ","))]")

		let initialInputs = HookChainIOValidator.initialInputs(from: snapshot)
		let validationResult = HookChainIOValidator.validate(
			hookIds: planHookIds,
			initialAvailableInputs: initialInputs,
			registry: registry
		)
		var finalHookIds = planHookIds
		if !validationResult.isValid {
			let failedHook = validationResult.failedHookId ?? "unknown"
			let missing = validationResult.missingInputs.map(\.rawValue).sorted().joined(separator: ",")
			print("[HookValidation] result=fail reason=io_contract_failed hook=\(failedHook) missing=[\(missing)]")
			
			if let repaired = HookChainRepairEngine.repair(originalHookIds: planHookIds, initialAvailableInputs: initialInputs, registry: registry) {
				finalHookIds = repaired
				print("[HookValidation] result=pass reason=io_contract_satisfied")
			} else {
				print("[HookCompositionPipeline] skipped reason=io_contract_failed")
				return nil
			}
		} else {
			print("[HookValidation] result=pass reason=io_contract_satisfied")
		}

		let usedHooks = finalHookIds.compactMap { registry.definition(for: $0) }

		guard !finalHookIds.isEmpty else {
			print("[HookValidation] result=fail reason=no_hooks_available")
			print("[HookCompositionPipeline] skipped reason=no_valid_hooks")
			return nil
		}

		// Fail quietly when the only hooks are anchors (observe_current_context + present_result).
		let nonAnchorHooks = finalHookIds.filter {
			$0 != "observe_current_context" && $0 != "present_result"
		}
		guard !nonAnchorHooks.isEmpty else {
			print("[HookPlanner] skipped reason=no_capability_hooks_resolved cats=[\(cats.joined(separator: ","))]")
			return nil
		}

		let workflow = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
		let primitives = HookCapabilityRegistry.primitives(from: usedHooks)
		let intent = inferIntent(from: primitives)

		let title = synthesizeTitle(goal: inference.possibleUserGoal, workflow: workflow, intent: intent)
		let question = synthesizeQuestion(goal: inference.possibleUserGoal, title: title)

		let requiredContext = minimizedRequiredContext(
			from: usedHooks,
			snapshot: snapshot,
			situational: situational
		)

		let fp = TaskInferenceEngine.fingerprint(snapshot: snapshot, situational: situational, recentTitles: recentTitles)
		let catSig = cats.joined(separator: ",")
		let catHash = abs(catSig.hashValue)

		// Blend utility score into contract confidence.
		// Boosted proposals get a small lift; accepted proposals use raw confidence.
		// This flows into rank scoring and the chime-in float decision.
		let blendedConfidence: Double = {
			switch utility.decision {
			case .boost:  return min(1.0, inference.confidence + utility.score * 0.12)
			case .accept: return inference.confidence
			case .reject: return inference.confidence  // shouldn't reach here
			}
		}()

		let contract = DynamicGeneratedActionContract(
			id: "hook:\(fp)|c\(catHash)",
			title: title,
			userFacingQuestion: question,
			inferredUserGoal: inference.possibleUserGoal,
			situationSummary: String(situational.situationalSummary.prefix(160)),
			whyNow: inference.whyNow.isEmpty ? "inferred" : inference.whyNow,
			hookPlanIds: finalHookIds,
			requiredContext: requiredContext,
			confidence: blendedConfidence,
			createdAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(max(8, min(60, inference.expirySeconds))),
			cacheEligibility: blendedConfidence >= 0.66,
			cacheKey: fp
		)

		let chain = finalHookIds.joined(separator: ",")
		print("[HookRetriever] cats=[\(cats.joined(separator: ","))] retrieved=\(retrieved.count) implemented=\(usedHooks.count)")
		print("[HookPlanner] chain=\(chain) missingCats=none")

		// [GeneratedActionContract] — final contract summary.
		let executableFlag = finalHookIds.count >= 2 && !usedHooks.isEmpty
		print("[GeneratedActionContract] executable=\(executableFlag ? "yes" : "no") source=llm_hook_plan title=\"\(contract.title)\" hooks=[\(chain)] confidence=\(String(format: "%.2f", contract.confidence))")
		print("[HookComposer] synthesized title=\(contract.title) hooks=\(finalHookIds.count)")

		let proposal = ValidatedDynamicGeneratedProposal(
			id: contract.id,
			title: contract.title,
			description: contract.userFacingQuestion,
			workflowType: workflow,
			intentType: intent,
			expectedOutcome: contract.inferredUserGoal,
			requiredContextTypes: contract.requiredContext,
			suggestedPrimitives: primitives,
			interruptionCost: interruptionCost(workflow: workflow, confidence: contract.confidence),
			confidence: contract.confidence,
			usefulnessHint: "hook_composer_model"
		)

		return PlanningOutput(contract: contract, proposal: proposal)
	}

	// MARK: - Helpers

	private static func normalizeCats(_ raw: [String]) -> [String] {
		var seen: Set<String> = []
		return raw
			.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			.filter { seen.insert($0).inserted }
			.prefix(8)
			.map { $0 }
	}

	private static func inferIntent(from primitives: [ExecutionPrimitive]) -> IntentType {
		if primitives.contains(.compareContexts) { return .compare }
		if primitives.contains(.explainError) { return .explain }
		if primitives.contains(.extractActionItems) { return .extract }
		if primitives.contains(.organizeInformation) { return .organize }
		if primitives.contains(.synthesizeResearchSummary) { return .synthesize }
		if primitives.contains(.structureNotes) { return .structure }
		if primitives.contains(.classifyWorkflow) { return .classify }
		if primitives.contains(.answerFromContext) { return .answer }
		if primitives.contains(.summarizeContext) { return .summarize }
		return .unknown
	}

	private static func synthesizeTitle(goal: String, workflow: WorkflowType, intent: IntentType) -> String {
		let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
		if !g.isEmpty {
			let capped = String(g.prefix(64))
			return capped.prefix(1).uppercased() + capped.dropFirst()
		}
		if workflow != .unknown, intent != .unknown {
			return "Help with \(workflow.rawValue) (\(intent.rawValue))"
		}
		return "Help with the current context"
	}

	private static func synthesizeQuestion(goal: String, title: String) -> String {
		let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
		if !g.isEmpty {
			return "Want me to help with: \(String(g.prefix(90)))?"
		}
		return "Want help with this?"
	}

	private static func minimizedRequiredContext(
		from hooks: [HookCapabilityDefinition],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> [ContextRequirementType] {
		var required: Set<ContextRequirementType> = []
		for hook in hooks {
			for type in hook.requiredContextTypes where type != .none {
				required.insert(type)
			}
		}

		// Allow execution-time gathering: don't require screen capture/visual for visibility if we can gather it.
		if required.contains(.screenCapture) || required.contains(.fusedVisual) {
			let screenAllowed = snapshot.permissionAvailability[.screenRecording] != false
			if !screenAllowed {
				// Hard requirement only when permission is denied — otherwise let it surface.
			} else {
				required.remove(.screenCapture)
				required.remove(.fusedVisual)
			}
		}

		if situational.inferredWorkflow == .unknown {
			required.remove(.workflowContext)
		}

		required.remove(.multiSource)
		if required.isEmpty { return [.none] }
		return Array(required)
	}

	private static func interruptionCost(workflow: WorkflowType, confidence: Double) -> Double {
		let base: Double
		switch workflow {
		case .debugging: base = 0.28
		case .research, .browsing, .studying: base = 0.24
		default: base = 0.20
		}
		let confBoost = max(0, (confidence - 0.70)) * 0.12
		return max(0.08, min(0.70, base - confBoost))
	}
}

// MARK: - Hook retrieval

private enum HookCategoryRetriever {
	/// Maps the 9 parser-allowed capability categories to HookCategory sets.
	/// Must exactly match the `allowedCats` set in TaskInferenceParser.buildResult and
	/// the `catsAllowed` string in TaskInferencePromptBuilder.
	/// DO NOT add `debug` or `study` — they are not in the parser's allowed set and qwen
	/// never outputs them. Adding them here would be dead code.
	static func hookCategories(for cat: String) -> Set<HookCategory> {
		switch cat {
		case "context":
			return [.sensing]
		case "extract":
			return [.extraction]
		case "reason":
			return [.reasoning, .transformation]
		case "compare":
			// Compare needs extraction (source material) + reasoning (comparison logic) + presentation.
			return [.extraction, .reasoning, .transformation, .presentation]
		case "organize":
			// Organize needs reasoning (structure, classify) + transformation + presentation (output).
			return [.reasoning, .transformation, .presentation]
		case "output":
			return [.presentation]
		case "control":
			// Computer control hooks — permissioned; require user confirmation at runtime.
			return [.app_control]
		case "memory":
			// No dedicated memory hooks yet. Use observation + reasoning as proxy:
			// observation reads current state; reasoning distills what's worth remembering.
			return [.sensing, .reasoning]
		case "utility":
			// Cross-cutting utility: reasoning for analysis, extraction for data.
			return [.reasoning, .extraction, .transformation]
		default:
			return []
		}
	}

	static func retrieve(
		needCats: [String],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		registry: HookCapabilityRegistry
	) -> [HookCapabilityDefinition] {
		// Pass 1: goal_decomposition — map capability categories to hook categories.
		print("[HookDiscovery] pass=goal_decomposition categories=[\(needCats.joined(separator: ","))]")
		var wanted: Set<HookCategory> = []
		for cat in needCats {
			wanted.formUnion(hookCategories(for: cat))
		}
		if wanted.isEmpty {
			// No recognized cats — fall back to reasoning + presentation as a safe default.
			wanted = [.reasoning, .presentation]
		}
		let wantedStr = wanted.map(\.rawValue).sorted().joined(separator: ",")
		print("[HookDiscovery] pass=goal_decomposition hook_categories=[\(wantedStr)]")

		// Pass 2: candidate_retrieval — filter registry by hook categories.
		let all = registry.all
			.filter { wanted.contains($0.category) }
			.filter { $0.permissionLevel != .unavailable && $0.category != .dangerous }

		// Prefer implemented hooks; fall back to unimplemented only if nothing else matched.
		let implemented = all.filter(\.isImplemented)
		let base = implemented.isEmpty ? all : implemented
		print("[HookDiscovery] pass=candidate_retrieval total_in_cats=\(all.count) implemented=\(implemented.count) selected=\(base.count)")

		// Pass 3: compatibility_filter — neighbor expansion via pairing hints.
		// For each retrieved hook, add its declared pairings if they're implemented and
		// not already included. This populates richer chains (e.g. compare → extract_product_attributes)
		// without any cat-specific hardcoding.
		var expanded = base
		let expandedIds = Set(base.map(\.id))
		var toAdd: [HookCapabilityDefinition] = []
		for hook in base {
			for neighborId in hook.pairsWellWithHookIds + hook.commonNextHookIds {
				guard !expandedIds.contains(neighborId) else { continue }
				if let neighbor = registry.definition(for: neighborId),
				   neighbor.isImplemented,
				   neighbor.permissionLevel != .unavailable,
				   neighbor.category != .dangerous {
					toAdd.append(neighbor)
				}
			}
		}
		// Cap expansion to avoid context bloat: max 4 neighbor additions.
		let capped = Array(toAdd.prefix(4))
		expanded += capped
		print("[HookDiscovery] pass=compatibility_filter kept=\(base.count) neighbors_added=\(capped.count) total=\(expanded.count)")

		// Pass 4: domain_filter — remove hooks that are incompatible with the current workflow.
		// This prevents product/shopping hooks from appearing in coding/debugging chains.
		let workflow = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
		let domainFiltered = HookDomainFilter.filter(candidates: expanded, workflow: workflow, app: snapshot.activeApp)
		print("[HookDiscovery] pass=domain_filter workflow=\(workflow.rawValue) before=\(expanded.count) after=\(domainFiltered.count)")

		return domainFiltered
	}

	static func retrieveAsync(
		needCats: [String],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		registry: HookCapabilityRegistry
	) async -> [HookCapabilityDefinition] {
		retrieve(needCats: needCats, snapshot: snapshot, situational: situational, registry: registry)
	}
}

private struct HookPlanningSafetyEvaluation: Sendable, Equatable {
	let shouldAbort: Bool
	let abortReason: String?
}

private enum HookPlanningSafetyChecker {
	static func evaluateAsync(
		needCats: [String],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) async -> HookPlanningSafetyEvaluation {
		// Placeholder for future: e.g. deny "computer_control" unless user explicitly invoked.
		_ = needCats
		_ = snapshot
		_ = situational
		return HookPlanningSafetyEvaluation(shouldAbort: false, abortReason: nil)
	}
}

// MARK: - Multi-pass hook script discovery (Parts C + D + E)

/// Builds a hook execution chain step by step, choosing one hook per pass.
/// Each step: determines available outputs, finds valid candidates, asks the model
/// for the next hook, validates, updates outputs. Stops when presentation reached or max steps hit.
///
/// Initial available outputs are seeded from the actual snapshot (Part E):
/// read_selected_text is excluded if no selection exists; OCR hooks excluded if screen permission denied.
enum HookScriptDiscovery {

    private static let model = "qwen2.5:1.5b"
    private static let numPredict = 150   // Accommodates the 'reason' string in the new JSON schema
    private static let temperature = 0.05
    private static let stepTimeoutSeconds: TimeInterval = 4.0
    private static let maxSteps = 8
    private static let maxChainLength = 8

    // MARK: - Entry point

    static func buildChain(
        goal: String,
        candidates: [HookCapabilityDefinition],
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        situational: SituationalContextSnapshot
    ) async -> [String]? {
        let isSelfTest = ProcessInfo.processInfo.environment["CONTEXTUAL_RUN_HOOK_SCRIPT_DISCOVERY_SELFTEST"] == "1"

        if isSelfTest {
            return executeMock(goal: goal, candidates: candidates, snapshot: snapshot)
        }

        let workflow = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
        return await buildChainLive(goal: goal, candidates: candidates, snapshot: snapshot, workflow: workflow)
    }

    /// Live entry point for self-tests that need real LLM calls (Part H).
    /// Pass the appropriate `workflow` so domain filtering applies correctly.
    static func buildChainForLiveTest(
        goal: String,
        candidates: [HookCapabilityDefinition],
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        workflow: WorkflowType = .unknown
    ) async -> [String]? {
        return await buildChainLive(goal: goal, candidates: candidates, snapshot: snapshot, workflow: workflow)
    }

    // MARK: - Live multi-pass builder

    private static func buildChainLive(
        goal: String,
        candidates: [HookCapabilityDefinition],
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        workflow: WorkflowType
    ) async -> [String]? {
        // Apply domain filter once before the loop — removes workflow-incompatible hooks.
        // buildChainForLiveTest passes candidates directly (not through HookCategoryRetriever),
        // so filtering here ensures the live-test path is also domain-correct.
        let domainFilteredCandidates = HookDomainFilter.filter(candidates: candidates, workflow: workflow, app: snapshot.activeApp)
        var available = seedInitialOutputs(snapshot: snapshot)
        var chain: [String] = []

        let att = ProposalAttemptScope.currentId ?? "none"
        print("[ProposalAttempt] id=\(att) hook_discovery_started")
        print("[HookScriptDiscovery] started goal=\"\(String(goal.prefix(60)))\"")

        for step in 1...maxSteps {
            // Stop if chain ends with presentation/app_control
            if let lastId = chain.last,
               let lastDef = domainFilteredCandidates.first(where: { $0.id == lastId }),
               lastDef.category == .presentation || lastDef.category == .app_control {
                break
            }

            // Determine valid next-hook candidates for this step
            var stepCandidates = candidatesForStep(
                all: domainFilteredCandidates,
                chain: chain,
                available: available,
                snapshot: snapshot,
                goal: goal
            )

            // T18.7.3 — Force presentation completion if presentable data exists.
            // If the step-level candidate filter removed presentation hooks (e.g. their IO
            // requires weren't fully satisfied yet), inject them directly from the full
            // domain-filtered list — presentable output is sufficient justification.
            let presentableOutputs: Set<HookIOKey> = [
                .table, .comparison_summary, .product_attributes, .summary_text, .key_claims, .final_result
            ]
            if !available.isDisjoint(with: presentableOutputs) {
                var presentationCandidates = stepCandidates.filter { $0.category == .presentation }
                if presentationCandidates.isEmpty {
                    // IO check removed them from stepCandidates — inject from full list.
                    let injected = domainFilteredCandidates.filter {
                        $0.category == .presentation && !chain.contains($0.id)
                    }
                    if !injected.isEmpty {
                        let ids = injected.map(\.id).joined(separator: ",")
                        print("[HookScriptDiscovery] injected_presentation_candidates ids=[\(ids)]")
                        presentationCandidates = injected
                    }
                }
                if !presentationCandidates.isEmpty {
                    let availablePresentable = available.intersection(presentableOutputs).map(\.rawValue).sorted().joined(separator: ",")
                    print("[HookScriptDiscovery] presentable_output_detected outputs=[\(availablePresentable)]")
                    let forcedIds = presentationCandidates.map(\.id).joined(separator: ",")
                    print("[HookScriptDiscovery] forcing_presentation_candidates ids=[\(forcedIds)]")
                    stepCandidates = presentationCandidates
                }
            }

            let availStr = available.map(\.rawValue).sorted().joined(separator: ",")
            let candIds = stepCandidates.map(\.id).joined(separator: ",")
            print("[HookScriptDiscovery] step=\(step) available=[\(availStr)] needed=[\(neededOutputs(chain: chain, candidates: domainFilteredCandidates))]")
            print("[HookScriptDiscovery] candidates step=\(step) count=\(stepCandidates.count) ids=[\(candIds)]")

            guard !stepCandidates.isEmpty else {
                print("[HookScriptDiscovery] failed reason=no_candidates step=\(step)")
                break
            }

            // Ask model for next hook
            guard let decision = await askNextHook(
                goal: goal,
                chain: chain,
                stepCandidates: stepCandidates,
                available: available,
                snapshot: snapshot,
                step: step
            ) else {
                print("[HookScriptDiscovery] failed reason=no_model_output step=\(step)")
                break
            }

            if decision.done == true {
                print("[HookScriptDiscoveryLLM] step=\(step) raw done=true reason=\"\(decision.reason ?? "")\"")
                break
            }

            // Task C: deterministic recovery when model returns next_hook=null but done=false.
            let hookId: String
            if let resolvedId = decision.next_hook {
                hookId = resolvedId
            } else {
                print("[HookScriptDiscovery] invalid_model_choice reason=next_hook_null_not_done step=\(step)")

                // Recovery rule 1: if chain has a capability hook and presentable output exists,
                // force the best presentation hook deterministically.
                let chainHasCapability = chain.contains { id in
                    guard let def = domainFilteredCandidates.first(where: { $0.id == id }) else { return false }
                    return def.category != .sensing && def.category != .presentation
                }
                let presentableOutputs: Set<HookIOKey> = [
                    .table, .comparison_summary, .product_attributes, .summary_text, .key_claims, .final_result
                ]
                var recoveredHook: HookCapabilityDefinition? = nil

                if chainHasCapability && !available.isDisjoint(with: presentableOutputs) {
                    let pCands = stepCandidates.filter { $0.category == .presentation }
                    if let best = pCands.first {
                        let ids = pCands.map(\.id).joined(separator: ",")
                        print("[HookScriptDiscovery] forcing_presentation_candidates ids=[\(ids)]")
                        recoveredHook = best
                    }
                }

                // Recovery rule 2: at step 1, pick highest-priority non-presentation candidate.
                if recoveredHook == nil {
                    let nonPres = stepCandidates.filter { $0.category != .presentation }
                    recoveredHook = nonPres.first(where: { $0.category == .extraction })
                                 ?? nonPres.first(where: { $0.category == .sensing })
                                 ?? nonPres.first(where: { $0.category == .reasoning })
                                 ?? nonPres.first
                }

                if let hook = recoveredHook {
                    print("[HookScriptDiscovery] deterministic_recovery step=\(step) hook=\(hook.id) reason=invalid_null_choice")
                    chain.append(hook.id)
                    for prod in hook.produces { available.insert(prod) }
                    let outStr = available.map(\.rawValue).sorted().joined(separator: ",")
                    print("[HookScriptDiscovery] outputs_after step=\(step) available=[\(outStr)]")
                    print("[HookScriptDiscovery] validation step=\(step) result=pass errors=[]")
                    if hook.category == .presentation || hook.category == .app_control { break }
                    continue
                }
                // No recovery possible — break the loop
                break
            }

            print("[HookScriptDiscoveryLLM] step=\(step) raw next_hook=\(hookId) reason=\"\(decision.reason ?? "")\"")

            // Validate: hook must be in candidates
            guard let hookDef = stepCandidates.first(where: { $0.id == hookId }) else {
                print("[HookScriptDiscovery] validation step=\(step) result=fail errors=[hook_not_in_candidates: \(hookId)]")
                // One repair: if model hallucinated, skip and let loop try again
                continue
            }

            // Safety check
            if hookDef.safety == .unsafe_disabled {
                print("[HookScriptDiscovery] excluded hook=\(hookId) reason=unsafe_disabled")
                continue
            }
            if hookDef.safety == .confirmation_required {
                print("[HookScriptDiscovery] excluded hook=\(hookId) reason=confirmation_required_in_automatic_mode")
                continue
            }

            // IO check: requires must be satisfied
            let unsatisfied = hookDef.requires.filter { !available.contains($0) }
            guard unsatisfied.isEmpty else {
                print("[HookScriptDiscovery] validation step=\(step) result=fail errors=[unsatisfied_requires: \(unsatisfied.map(\.rawValue).joined(separator: ","))]")
                continue
            }

            chain.append(hookId)
            for prod in hookDef.produces { available.insert(prod) }

            print("[HookScriptDiscovery] selected step=\(step) hook=\(hookId) reason=\"\(decision.reason ?? "")\"")
            let outStr = available.map(\.rawValue).sorted().joined(separator: ",")
            print("[HookScriptDiscovery] outputs_after step=\(step) available=[\(outStr)]")
            print("[HookScriptDiscovery] validation step=\(step) result=pass errors=[]")

            if chain.count >= maxChainLength { break }
        }

        guard !chain.isEmpty else {
            print("[HookScriptDiscovery] failed reason=empty_chain")
            return nil
        }

        // Chain must end with presentation or app_control.
        // If it doesn't (the loop exhausted steps or broke early after producing data),
        // attempt to repair by appending the best available presentation hook before failing.
        let lastId = chain.last!
        let lastDef = domainFilteredCandidates.first(where: { $0.id == lastId })
        if lastDef?.category != .presentation && lastDef?.category != .app_control {
            let presHooks = domainFilteredCandidates.filter {
                $0.category == .presentation && !chain.contains($0.id)
            }
            if let ph = presHooks.first {
                let ids = presHooks.map(\.id).joined(separator: ",")
                print("[HookScriptDiscovery] injected_presentation_candidates ids=[\(ids)]")
                chain.append(ph.id)
                // Fall through to the success log below.
            } else {
                print("[HookScriptDiscovery] failed reason=chain_missing_presentation chain=[\(chain.joined(separator: ","))]")
                return nil
            }
        }

        print("[HookScriptDiscovery] completed chain=[\(chain.joined(separator: ","))] reason=presentation_reached")
        return chain
    }

    // MARK: - Per-step candidate filter (Part E)

    private static func candidatesForStep(
        all: [HookCapabilityDefinition],
        chain: [String],
        available: Set<HookIOKey>,
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        goal: String = ""
    ) -> [HookCapabilityDefinition] {
        let chainSet = Set(chain)
        let chainHasCapabilityHook = chain.contains { id in
            guard let def = all.first(where: { $0.id == id }) else { return false }
            return def.category != .sensing
        }

        return all.filter { hook in
            // No repeats
            guard !chainSet.contains(hook.id) else { return false }
            // Only implemented hooks enter chains
            guard hook.lifecycleStatus == .implemented else { return false }
            // Block unsafe
            guard hook.safety != .unsafe_disabled else { return false }
            // Block confirmation_required in automatic mode
            guard hook.safety != .confirmation_required else { return false }

            // Part E: runtime availability checks
            if hook.id == "read_selected_text" {
                let hasSel = (snapshot.selectedText ?? "").isEmpty == false
                if !hasSel {
                    print("[HookPlanValidation] blocked hook=read_selected_text reason=selection_unavailable")
                    print("[HookScriptDiscovery] excluded hook=read_selected_text reason=unavailable_input_or_runtime")
                    return false
                }
            }

            // IO: requires must be ⊆ available
            let requiresSatisfied = hook.requires.allSatisfy { available.contains($0) }
            guard requiresSatisfied else { return false }

            // Presentation hooks: only available once chain has at least one capability hook
            if hook.category == .presentation {
                return chainHasCapabilityHook
            }

            // Task D: Generic capability fit check.
            // Hooks that are domain-specific (product, price, purchase) are only included
            // when the goal semantically matches that domain. This is computed from
            // token overlap between goal text and hook capability/whenToUse fields —
            // no hardcoded app/website names.
            if !goal.isEmpty {
                let (fitScore, fitReason) = hookGoalFit(hook: hook, goal: goal)
                if fitScore == 0.0 {
                    print("[HookCandidateFit] rejected hook=\(hook.id) reason=\(fitReason)")
                    return false
                }
                if fitScore < 1.0 {
                    print("[HookCandidateFit] hook=\(hook.id) score=\(String(format: "%.2f", fitScore)) reason=\(fitReason)")
                } else {
                    print("[HookCandidateFit] kept hook=\(hook.id) reason=\(fitReason)")
                }
            }

            return true
        }
    }

    // MARK: - Generic hook–goal fit (Task D)

    /// Computes how well a hook's capability aligns with the stated goal using token overlap.
    ///
    /// The key insight: hooks that operate in a specific content domain (product specs, prices,
    /// purchase tradeoffs) are only useful when the goal mentions that domain. This check is
    /// purely semantic — it uses the hook's own `capability` and `whenToUse` fields, not
    /// hardcoded app or website names.
    ///
    /// Returns (score, reason):
    ///   - score = 0.0  → reject (domain-specific hook with no matching goal signal)
    ///   - score = 1.0  → keep (generic hook, or domain-specific hook with matching goal)
    private static func hookGoalFit(hook: HookCapabilityDefinition, goal: String) -> (score: Double, reason: String) {
        // Tokenise the hook's capability descriptor and whenToUse into a set of meaningful words.
        let hookText = "\(hook.capability) \(hook.whenToUse)".lowercased()
        let hookTokens = tokenise(hookText)

        // Domain-specific tokens: if a hook's capability contains these, it is domain-restricted.
        // These tokens come from the hook definitions themselves, not from external sources.
        let domainSpecificTokens: Set<String> = ["product", "price", "purchase", "rating", "spec", "shop"]

        let hookDomainMarkers = hookTokens.intersection(domainSpecificTokens)

        // Hooks with no domain-specific tokens are generic — always pass.
        guard !hookDomainMarkers.isEmpty else {
            return (1.0, "capability_match")
        }

        // This is a domain-specific hook. Check if the goal has any of the same markers.
        let goalTokens = tokenise(goal.lowercased())
        let goalDomainOverlap = goalTokens.intersection(hookDomainMarkers)

        if goalDomainOverlap.isEmpty {
            // Goal has no domain signal that matches this hook's specialisation.
            return (0.0, "low_goal_fit")
        }

        return (1.0, "capability_match")
    }

    private static func tokenise(_ text: String) -> Set<String> {
        Set(
            text
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 3 }   // skip very short words ("the", "for", "and")
        )
    }

    // MARK: - Seed available outputs from snapshot (Part E)

    private static func seedInitialOutputs(snapshot: CanonicalGeneratedExecutionContextSnapshot) -> Set<HookIOKey> {
        var available: Set<HookIOKey> = [.current_context, .window_title, .app_identifier]
        // selected_text only if actually present
        if (snapshot.selectedText ?? "").isEmpty == false {
            available.insert(.selected_text)
        }
        // clipboard_text only if present
        if (snapshot.clipboardText ?? "").isEmpty == false {
            available.insert(.clipboard_text)
        }
        // ocr_text if already captured
        if (snapshot.recentOCRExcerpt ?? "").isEmpty == false {
            available.insert(.ocr_text)
        }
        // visual_summary if visual descriptor captured
        if snapshot.visualContextAvailability.visualSummaryExcerpt?.isEmpty == false {
            available.insert(.visual_summary)
        }
        return available
    }

    // MARK: - Needed outputs (for logging)

    private static func neededOutputs(chain: [String], candidates: [HookCapabilityDefinition]) -> String {
        // Heuristic: what outputs would be useful for the next step based on what's not yet produced
        let produced = chain.flatMap { id in candidates.first(where: { $0.id == id })?.produces ?? [] }
        let producedSet = Set(produced)
        let needed = candidates.flatMap(\.requires).filter { !producedSet.contains($0) }
        return Array(Set(needed)).prefix(4).map(\.rawValue).joined(separator: ",")
    }

    // MARK: - Per-step LLM call (Part D)

    private struct NextHookDecision: Decodable {
        let next_hook: String?
        let done: Bool?
        let reason: String?
        let confidence: Double
    }

    private static func buildStepSchema(candidateIds: [String]) -> [String: Any] {
        return [
            "type": "object",
            "properties": [
                "next_hook": [
                    "type": ["string", "null"],
                    "enum": candidateIds
                ] as [String: Any],
                "done": ["type": "boolean"],
                "reason": ["type": "string", "maxLength": 120] as [String: Any],
                "confidence": ["type": "number"] as [String: Any]
            ] as [String: Any],
            "required": ["done", "confidence"]
        ]
    }

    private static func buildStepPrompt(
        goal: String,
        chain: [String],
        stepCandidates: [HookCapabilityDefinition],
        available: Set<HookIOKey>,
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        step: Int
    ) -> String {
        let chainStr = chain.isEmpty ? "none" : chain.joined(separator: "→")
        let availStr = available.map(\.rawValue).sorted().joined(separator: ",")
        var lines: [String] = [
            "Pick the next hook for this chain.",
            "ctx app=\(snapshot.activeApp) title=\(String(snapshot.windowTitle.prefix(60)))",
            "goal: \(String(goal.prefix(100)))",
            "step: \(step)",
            "chain_so_far: [\(chainStr)]",
            "available_outputs: [\(availStr)]",
            "candidates:"
        ]
        for c in stepCandidates {
            let prod = c.produces.isEmpty ? "" : " →[\(c.produces.map(\.rawValue).joined(separator: ","))]"
            lines.append("- \(c.id)|\(c.category.rawValue)\(prod): \(c.description)")
        }
        lines.append("Pick next_hook from candidates above. Choose presentation hook when chain is sufficient.")
        return lines.joined(separator: "\n")
    }

    private enum StepTimeoutError: Error { case timeout }

    private static func askNextHook(
        goal: String,
        chain: [String],
        stepCandidates: [HookCapabilityDefinition],
        available: Set<HookIOKey>,
        snapshot: CanonicalGeneratedExecutionContextSnapshot,
        step: Int
    ) async -> NextHookDecision? {
        let prompt = buildStepPrompt(goal: goal, chain: chain, stepCandidates: stepCandidates, available: available, snapshot: snapshot, step: step)
        let schema = buildStepSchema(candidateIds: stepCandidates.map(\.id))

        do {
            let raw = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await LocalAIClient.shared.generateStreamingJSON(
                        prompt: prompt,
                        model: model,
                        numPredict: numPredict,
                        temperature: temperature,
                        purpose: "hook_script_step",
                        schema: schema
                    )
                }
                group.addTask {
                    let nanos = UInt64(stepTimeoutSeconds * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanos)
                    throw StepTimeoutError.timeout
                }
                guard let first = try await group.next() else { throw StepTimeoutError.timeout }
                group.cancelAll()
                return first
            }

            guard let data = raw.data(using: .utf8),
                  let decision = try? JSONDecoder().decode(NextHookDecision.self, from: data) else {

                // T18.7.1 — Diagnostic repair for truncated JSON, strictly gated.
                if ProcessInfo.processInfo.environment["CONTEXTUAL_ENABLE_HOOK_JSON_REPAIR"] == "1" {
                    if let hookMatch = raw.range(of: #""next_hook"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                        let extracted = String(raw[hookMatch])
                        if let valueRange = extracted.range(of: #"(?<=:)\s*"([^"]+)""#, options: .regularExpression) {
                            let hookId = String(extracted[valueRange])
                                .trimmingCharacters(in: .whitespaces)
                                .replacingOccurrences(of: "\"", with: "")

                            print("[HookScriptDiscovery] step=\(step) diagnostic_repair hook=\(hookId)")
                            return NextHookDecision(next_hook: hookId, done: false, reason: "diagnostic_repair", confidence: 0.5)
                        }
                    }
                }

                print("[HookScriptDiscovery] step=\(step) failed_to_decode raw=\"\(raw)\"")
                return nil
            }

            return decision
        } catch {
            print("[HookScriptDiscovery] step=\(step) timeout_or_error err=\(error)")
            return nil
        }
    }

    // MARK: - Mock (self-test only)

    static func executeMock(
        goal: String,
        candidates: [HookCapabilityDefinition],
        snapshot: CanonicalGeneratedExecutionContextSnapshot
    ) -> [String]? {
        let g = goal.lowercased()
        let hasSel = (snapshot.selectedText ?? "").isEmpty == false

        // selected_text_unavailable test: must not include read_selected_text
        if g.contains("no selected text") || g.contains("selected_text_unavailable") {
            if !hasSel {
                // Return a chain that works without selection
                let chain = ["observe_current_context", "run_ocr_once", "summarize_visible_page", "present_result"]
                return chain.allSatisfy { id in candidates.first(where: { $0.id == id }) != nil } ? chain : nil
            }
        }

        if g.contains("compare") {
            return ["observe_current_context", "extract_product_specs", "compare_product_specs", "present_recommendation"]
        }
        if g.contains("product detail") || g.contains("product specs") {
            return ["observe_current_context", "extract_product_specs", "present_table"]
        }
        if g.contains("summarize") || g.contains("visible page") {
            return ["observe_current_context", "run_ocr_once", "summarize_visible_page", "present_result"]
        }
        if g.contains("error") || g.contains("explain") {
            return ["observe_current_context", "extract_entities", "present_result"]
        }
        // no_valid_hooks: return nil
        if g.contains("no valid") || g.contains("impossible") {
            return nil
        }
        return ["observe_current_context", "summarize_visible_page", "present_result"]
    }
}

// MARK: - Hook planning / gaps

import Foundation

struct HookLLMPlanResult: Decodable, Sendable {
    let hook_chain: [String]
    let reason: String?   // Optional — not required by schema
    let confidence: Double
}

enum HookLLMPlanner {

    // MARK: - Configuration

    private static let model = "qwen2.5:1.5b"
    private static let numPredict = 120
    private static let temperature = 0.05
    private static let timeoutSeconds: TimeInterval = 6.0

    // MARK: - Public API

    static func proposeChain(
        actionTitle: String,
        inferredActivity: String,
        plannerEvidence: String,
        suggestedCategories: [String],
        requiredContext: [ContextRequirementType],
        candidateHooks: [HookCapabilityDefinition]
    ) async -> HookLLMPlanResult? {
        let isSelfTest = ProcessInfo.processInfo.environment["CONTEXTUAL_RUN_HOOK_PLAN_SELFTEST"] == "1"
        let mode = isSelfTest ? "mock" : "live"
        print("[HookPlanLLM] mode=\(mode) started candidates=\(candidateHooks.count)")

        // Mock execution for self-test
        if isSelfTest {
            return await executeMock(evidence: plannerEvidence, isRepair: false)
        }

        // Live execution via Ollama structured output
        return await callModel(
            prompt: buildPrompt(
                title: actionTitle,
                activity: inferredActivity,
                evidence: plannerEvidence,
                cats: suggestedCategories,
                ctx: requiredContext,
                candidates: candidateHooks
            ),
            candidateHooks: candidateHooks,
            label: "propose"
        )
    }

    static func repairChain(
        originalGoal: String,
        candidateHooks: [HookCapabilityDefinition],
        validationErrors: [String],
        invalidChain: [String]
    ) async -> HookLLMPlanResult? {
        print("[HookPlanRepair] started reason=validation_failed")

        if ProcessInfo.processInfo.environment["CONTEXTUAL_RUN_HOOK_PLAN_SELFTEST"] == "1" {
            let res = await executeMock(evidence: originalGoal, isRepair: true)
            print("[HookPlanRepair] result=\(res != nil ? "pass" : "fail")")
            return res
        }

        let result = await callModel(
            prompt: buildRepairPrompt(
                goal: originalGoal,
                invalidChain: invalidChain,
                errors: validationErrors,
                candidates: candidateHooks
            ),
            candidateHooks: candidateHooks,
            label: "repair"
        )
        print("[HookPlanRepair] result=\(result != nil ? "pass" : "fail")")
        return result
    }

    // MARK: - Live model call

    private static func callModel(
        prompt: String,
        candidateHooks: [HookCapabilityDefinition],
        label: String
    ) async -> HookLLMPlanResult? {
        print("[HookPlanLLMConfig] model=\(model) num_predict=\(numPredict) temperature=\(temperature) timeout_ms=\(Int(timeoutSeconds * 1000))")

        let candidateIds = candidateHooks.map(\.id)
        let schema = buildSchema(candidateIds: candidateIds)
        print("[StructuredOutput] hook_plan schema_enabled=yes")

        do {
            let raw = try await withHookPlanTimeout(seconds: timeoutSeconds) {
                try await LocalAIClient.shared.generateStreamingJSON(
                    prompt: prompt,
                    model: model,
                    numPredict: numPredict,
                    temperature: temperature,
                    purpose: "hook_plan",
                    schema: schema
                )
            }

            guard let data = raw.data(using: .utf8),
                  let result = try? JSONDecoder().decode(HookLLMPlanResult.self, from: data) else {
                print("[StructuredOutput] hook_plan valid_json=no label=\(label)")
                return nil
            }
            print("[StructuredOutput] hook_plan valid_json=yes label=\(label)")
            print("[HookPlanLLM] parsed chain=[\(result.hook_chain.joined(separator: ","))]")
            return result
        } catch {
            print("[HookPlanLLM] error label=\(label) err=\(error)")
            return nil
        }
    }

    // MARK: - Schema

    private static func buildSchema(candidateIds: [String]) -> [String: Any] {
        var itemSchema: [String: Any] = ["type": "string"]
        if !candidateIds.isEmpty {
            itemSchema["enum"] = candidateIds
        }
        let hookChainSchema: [String: Any] = [
            "type": "array",
            "items": itemSchema,
            "minItems": 1,
            "maxItems": 8
        ]
        return [
            "type": "object",
            "properties": [
                "hook_chain": hookChainSchema,
                "reason": ["type": "string", "maxLength": 160] as [String: Any],
                "confidence": ["type": "number"] as [String: Any]
            ] as [String: Any],
            "required": ["hook_chain", "confidence"]
        ]
    }

    // MARK: - Prompt builders

    private static func buildPrompt(
        title: String,
        activity: String,
        evidence: String,
        cats: [String],
        ctx: [ContextRequirementType],
        candidates: [HookCapabilityDefinition]
    ) -> String {
        var lines: [String] = [
            "Plan a hook execution chain for the user's current activity.",
            "goal: \(String((title + " " + evidence).prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines))",
            "activity: \(activity)",
            "cats: \(cats.joined(separator: ","))",
            "hooks:"
        ]
        for c in candidates {
            let req = c.requires.isEmpty ? "" : " req=\(c.requires.map(\.rawValue).joined(separator: "+"))"
            let prod = c.produces.isEmpty ? "" : " prod=\(c.produces.map(\.rawValue).joined(separator: "+"))"
            lines.append("- \(c.id)|\(c.capability)|\(c.safety.rawValue)|\(c.lifecycleStatus.rawValue)|\(c.cost.rawValue)\(req)\(prod)")
        }
        lines.append("Return hook_chain using only the IDs above. Start with observe_current_context if present. End with a presentation hook.")
        return lines.joined(separator: "\n")
    }

    private static func buildRepairPrompt(
        goal: String,
        invalidChain: [String],
        errors: [String],
        candidates: [HookCapabilityDefinition]
    ) -> String {
        var lines: [String] = [
            "Repair the invalid hook chain.",
            "goal: \(String(goal.prefix(120)))",
            "invalid_chain: [\(invalidChain.joined(separator: ","))]",
            "errors: \(errors.prefix(3).joined(separator: "; "))",
            "hooks:"
        ]
        for c in candidates {
            let req = c.requires.isEmpty ? "" : " req=\(c.requires.map(\.rawValue).joined(separator: "+"))"
            let prod = c.produces.isEmpty ? "" : " prod=\(c.produces.map(\.rawValue).joined(separator: "+"))"
            lines.append("- \(c.id)|\(c.capability)|\(c.safety.rawValue)|\(c.lifecycleStatus.rawValue)|\(c.cost.rawValue)\(req)\(prod)")
        }
        lines.append("Return a corrected hook_chain using only the IDs above. Fix the errors listed.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Timeout helper

    private enum HookPlanTimeoutError: Error { case timeout }

    private static func withHookPlanTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let nanos = UInt64(max(1.0, seconds) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw HookPlanTimeoutError.timeout
            }
            guard let first = try await group.next() else {
                throw HookPlanTimeoutError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Mock (self-test only)

    private static func executeMock(evidence: String, isRepair: Bool) async -> HookLLMPlanResult? {
        let e = evidence.lowercased()
        if e.contains("compare") {
            if isRepair {
                return HookLLMPlanResult(hook_chain: ["observe_current_context", "extract_product_attributes", "compare_items", "present_comparison"], reason: "Fixed IO", confidence: 0.9)
            }
            return HookLLMPlanResult(hook_chain: ["observe_current_context", "compare_items", "present_comparison"], reason: "Testing failure", confidence: 0.9)
        }
        if e.contains("explain") || e.contains("error") {
            return HookLLMPlanResult(hook_chain: ["observe_current_context", "extract_errors", "explain_error", "present_result"], reason: "Valid", confidence: 0.9)
        }
        if e.contains("email") {
            return HookLLMPlanResult(hook_chain: ["observe_current_context", "draft_email", "send_email", "present_result"], reason: "Should fail safety", confidence: 0.9)
        }
        if e.contains("control") || e.contains("click") {
            return HookLLMPlanResult(hook_chain: ["observe_current_context", "click_screen_coordinate"], reason: "Should fail safety", confidence: 0.9)
        }
        return nil
    }
}
import Foundation

struct HookPlanValidationResult: Sendable {
    let isValid: Bool
    let errors: [String]
}

enum HookPlanValidator {
    static func validate(
        chain: [String],
        candidates: [HookCapabilityDefinition],
        requiredContext: [ContextRequirementType],
        executionMode: String = "automatic",
        allowStubs: Bool = false
    ) -> HookPlanValidationResult {
        var errors: [String] = []
        var trackedData: Set<HookIOKey> = []
        
        // Initial context mapping to IO Keys (approximate, since ContextRequirementType and HookIOKey differ slightly, we assume required context types populate baseline IO keys)
        if requiredContext.contains(.screenCapture) || requiredContext.contains(.fusedVisual) {
            trackedData.insert(.visual_summary)
            trackedData.insert(.ocr_text)
            trackedData.insert(.window_title)
            trackedData.insert(.app_identifier)
        }
        if requiredContext.contains(.selectedText) {
            trackedData.insert(.selected_text)
        }
        
        // Track the presence of anchors
        if !chain.contains("observe_current_context") {
            // Not strictly an error but let's encourage it or just auto-add it in the pipeline
        }
        
        for (_, hookId) in chain.enumerated() {
            guard let def = candidates.first(where: { $0.id == hookId }) else {
                errors.append("Hook ID '\(hookId)' not found in candidates")
                continue
            }
            
            // 1. Lifecycle check
            if !allowStubs && (def.lifecycleStatus == .stub || def.lifecycleStatus == .metadata_only) {
                errors.append("Hook '\(hookId)' cannot be executed because status is \(def.lifecycleStatus.rawValue)")
            }
            
            // 2. Safety check
            if def.safety == .unsafe_disabled {
                errors.append("Hook '\(hookId)' is unsafe_disabled")
            }
            if def.safety == .confirmation_required && executionMode == "automatic" {
                errors.append("Hook '\(hookId)' requires confirmation but mode is automatic")
            }
            
            // 3. IO matching
            for req in def.requires {
                // If it's a special universal requirement or we already tracked it
                if !trackedData.contains(req) {
                    errors.append("Hook '\(hookId)' requires '\(req.rawValue)' which is not satisfied by context or previous hooks")
                }
            }
            
            // Add produced outputs
            for prod in def.produces {
                trackedData.insert(prod)
            }
        }
        
        // 4. End State Check (chain should typically present results or end logically)
        if let last = chain.last, let def = candidates.first(where: { $0.id == last }) {
            if def.category != .presentation && def.category != .app_control {
                // Warning only, or strict error? Let's make it a strict error to force presentation
                errors.append("Chain must end with a presentation or app_control hook, found \(def.category.rawValue)")
            }
        }
        
        if !errors.isEmpty {
            for err in errors {
                print("[HookPlanValidation] blocked hook=unknown reason=\(err)") // approximate log
            }
        }
        
        print("[HookPlanValidation] result=\(errors.isEmpty ? "pass" : "fail") errors=[\(errors.joined(separator: "; "))]")
        return HookPlanValidationResult(isValid: errors.isEmpty, errors: errors)
    }
}
import Foundation

enum HookPlanSelfTest {
    static func run() {
        print("[HookPlanSelfTest] started")
        
        var failures = 0
        let registry = HookCapabilityRegistry.shared
        let candidates = registry.all
        
        func verifyCase(name: String, result: HookPlanValidationResult, expectedValid: Bool) {
            let pass = (result.isValid == expectedValid)
            print("[HookPlanSelfTest] case=\(name) result=\(pass ? "pass" : "fail")")
            if !pass {
                failures += 1
                print(" -> Validation result: \(result.isValid) (expected \(expectedValid)) errors: \(result.errors)")
            }
        }
        
        // A. Compare products
        // Valid chain
        let resA_valid = HookPlanValidator.validate(
            chain: ["observe_current_context", "extract_product_attributes", "compare_items", "present_comparison"],
            candidates: candidates,
            requiredContext: [.screenCapture],
            allowStubs: true
        )
        verifyCase(name: "compare_products", result: resA_valid, expectedValid: true)
        
        // B. Explain code/error
        // Invalid chain: explain before extracting error
        let resB_invalid = HookPlanValidator.validate(
            chain: ["observe_current_context", "explain_error", "extract_errors", "present_result"],
            candidates: candidates,
            requiredContext: [.screenCapture],
            allowStubs: true
        )
        // Should fail because explain_error requires .error_trace or .code_snippet, which aren't produced yet.
        verifyCase(name: "explain_error", result: resB_invalid, expectedValid: false)
        
        // C. Draft email
        // Should fail safety if execution mode is automatic and send_email requires confirmation
        let resC = HookPlanValidator.validate(
            chain: ["observe_current_context", "draft_email", "send_email", "present_result"],
            candidates: candidates,
            requiredContext: [.screenCapture],
            executionMode: "automatic",
            allowStubs: true
        )
        verifyCase(name: "draft_email", result: resC, expectedValid: false)
        
        // D. App control blocked
        let resD = HookPlanValidator.validate(
            chain: ["observe_current_context", "click_screen_coordinate"],
            candidates: candidates,
            requiredContext: [.screenCapture],
            executionMode: "automatic",
            allowStubs: true
        )
        verifyCase(name: "app_control_blocked", result: resD, expectedValid: false)
        
        // E. No valid hooks - simulated in planner execution, just checking a bad chain
        let resE = HookPlanValidator.validate(
            chain: ["observe_current_context", "invalid_hook_id_123"],
            candidates: candidates,
            requiredContext: [.screenCapture]
        )
        verifyCase(name: "no_valid_hooks", result: resE, expectedValid: false)
        
        print("[HookPlanSelfTest] ok=\(failures == 0) failures=\(failures)")
    }
}
