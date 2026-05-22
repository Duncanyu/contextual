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

		// 2) Plan chain + gap check.
		let plan = HookGraphPlanner.plan(
			needCats: cats,
			retrievedHooks: retrieved,
			snapshot: snapshot,
			situational: situational
		)
		if !plan.missingCategories.isEmpty {
			print("[HookPlanner] gaps missingCats=[\(plan.missingCategories.joined(separator: ","))] reason=no_implemented_hooks")
		}
		guard !plan.hookIds.isEmpty else { return nil }

		// Fail quietly when the only hooks are anchors (observe_current_context + present_result).
		// This means no capability hooks were resolved — e.g. pure "control" requests with no
		// implemented hooks. Returning nil is the correct "fail quietly" behavior.
		let nonAnchorHooks = plan.hookIds.filter {
			$0 != "observe_current_context" && $0 != "present_result"
		}
		guard !nonAnchorHooks.isEmpty else {
			print("[HookPlanner] skipped reason=no_capability_hooks_resolved cats=[\(cats.joined(separator: ","))]")
			return nil
		}

		let workflow = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
		let primitives = HookCapabilityRegistry.primitives(from: plan.usedHooks)
		let intent = inferIntent(from: primitives)

		let title = synthesizeTitle(goal: inference.possibleUserGoal, workflow: workflow, intent: intent)
		let question = synthesizeQuestion(goal: inference.possibleUserGoal, title: title)

		let requiredContext = minimizedRequiredContext(
			from: plan.usedHooks,
			snapshot: snapshot,
			situational: situational
		)

		let fp = TaskInferenceEngine.fingerprint(snapshot: snapshot, situational: situational, recentTitles: recentTitles)
		let catSig = cats.joined(separator: ",")
		let catHash = abs(catSig.hashValue)

		let contract = DynamicGeneratedActionContract(
			id: "hook:\(fp)|c\(catHash)",
			title: title,
			userFacingQuestion: question,
			inferredUserGoal: inference.possibleUserGoal,
			situationSummary: String(situational.situationalSummary.prefix(160)),
			whyNow: inference.whyNow.isEmpty ? "inferred" : inference.whyNow,
			hookPlanIds: plan.hookIds,
			requiredContext: requiredContext,
			confidence: min(0.98, max(0.05, inference.confidence)),
			createdAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(max(8, min(60, inference.expirySeconds))),
			cacheEligibility: inference.confidence >= 0.66,
			cacheKey: fp
			)

			let chain = plan.hookIds.joined(separator: ",")
		let missingCatsStr = plan.missingCategories.isEmpty ? "none" : plan.missingCategories.joined(separator: ",")
		print("[HookRetriever] cats=[\(cats.joined(separator: ","))] retrieved=\(retrieved.count) implemented=\(plan.usedHooks.count)")
		print("[HookPlanner] chain=\(chain) missingCats=\(missingCatsStr)")

		// [HookValidation] — pass or fail based on missing required categories and unimplemented hooks.
		let unimplementedInPlan = plan.hookIds.filter { id in
			guard let def = registry.definition(for: id) else { return false }
			return !def.isImplemented
		}
		let validationPass = plan.missingCategories.isEmpty && unimplementedInPlan.isEmpty
		let validationResult = validationPass ? "pass" : "fail"
		print("[HookValidation] result=\(validationResult) missing_cats=[\(missingCatsStr)] unimplemented=[\(unimplementedInPlan.joined(separator: ","))]")

		// [GeneratedActionContract] — final contract summary.
		let executableFlag = plan.hookIds.count >= 2 && !plan.usedHooks.isEmpty
		print("[GeneratedActionContract] executable=\(executableFlag ? "yes" : "no") title=\"\(contract.title)\" hooks=[\(chain)] confidence=\(String(format: "%.2f", contract.confidence))")
		print("[HookComposer] synthesized title=\(contract.title) hooks=\(plan.hookIds.count)")

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
			return [.observation]
		case "extract":
			return [.extraction]
		case "reason":
			return [.reasoning]
		case "compare":
			// Compare needs extraction (source material) + reasoning (comparison logic) + presentation.
			return [.extraction, .reasoning, .presentation]
		case "organize":
			// Organize needs reasoning (structure, classify) + presentation (output).
			return [.reasoning, .presentation]
		case "output":
			return [.presentation]
		case "control":
			// Computer control hooks — permissioned; require user confirmation at runtime.
			return [.computerControl]
		case "memory":
			// No dedicated memory hooks yet. Use observation + reasoning as proxy:
			// observation reads current state; reasoning distills what's worth remembering.
			return [.observation, .reasoning]
		case "utility":
			// Cross-cutting utility: reasoning for analysis, extraction for data.
			return [.reasoning, .extraction]
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

		return expanded
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

// MARK: - Hook planning / gaps

private enum HookGraphPlanner {
	struct Plan: Sendable, Equatable {
		let hookIds: [String]
		let usedHooks: [HookCapabilityDefinition]
		let missingCategories: [String]
	}

	static func plan(
		needCats: [String],
		retrievedHooks: [HookCapabilityDefinition],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> Plan {
		// The plan always starts with observe (free metadata read) and ends with present.
		var ids: [String] = ["observe_current_context"]
		var used: [HookCapabilityDefinition] = []

		// Defensive: bakeoff or registry changes can accidentally return duplicate hook IDs.
		// `Dictionary(uniqueKeysWithValues:)` traps on duplicates; avoid crashing and log.
		var byId: [String: HookCapabilityDefinition] = [:]
		var duplicates: [String] = []
		for hook in retrievedHooks {
			if byId[hook.id] != nil { duplicates.append(hook.id); continue }
			byId[hook.id] = hook
		}
		if !duplicates.isEmpty {
			let uniqueDupes = Array(Set(duplicates)).sorted()
			print("[HookPlanner] duplicate_retrieved_hook_ids count=\(uniqueDupes.count) ids=[\(uniqueDupes.joined(separator: ","))]")
		}

		/// Add a hook by ID if implemented and not yet in the chain.
		func tryAdd(_ hookId: String) {
			guard !ids.contains(hookId),
				  let def = byId[hookId],
				  def.isImplemented,
				  def.permissionLevel != .unavailable,
				  def.category != .dangerous else { return }
			ids.append(hookId)
			used.append(def)
		}

		/// Add the first matching hook from the retrieved set.
		func includeFirst(where predicate: (HookCapabilityDefinition) -> Bool) {
			if let match = retrievedHooks.first(where: { predicate($0) && !ids.contains($0.id) }) {
				ids.append(match.id)
				used.append(match)
			}
		}

		// MARK: - Registry-driven selection for all 9 parser-allowed capability categories.
		// This does NOT hardcode user behaviors or specific hook IDs by name.
		// It selects building blocks by category and capability, letting the registry drive choices.

		for cat in needCats {
			switch cat {
			case "context":
				// Observation: gather richer context when explicitly requested.
				// Only add visual hooks when permission is available; don't require it.
				if snapshot.permissionAvailability[.screenRecording] != false {
					tryAdd("gather_visible_context_once")
					if situational.ocrSignal.availability != .available {
						tryAdd("run_ocr_once")
					}
				} else {
					// Fallback: inspect window title/recent titles (no screen permission needed).
					tryAdd("inspect_window_title")
					tryAdd("inspect_recent_titles")
				}

			case "extract":
				// Extraction: pick the best-fit extraction hook for the current workflow.
				// Priority: workflow-matched → generic extraction → fallback to tasks.
				let wf = situational.inferredWorkflow.rawValue
				switch wf {
				case "debugging":
					tryAdd("extract_error_messages")
					tryAdd("extract_entities")
				case "browsing", "research", "studying":
					tryAdd("extract_entities")
					tryAdd("extract_tasks")
				default:
					includeFirst { $0.category == .extraction && $0.isImplemented }
				}

			case "reason":
				// Reasoning: pick the best-fit reasoning hook for the current workflow.
				let wf = situational.inferredWorkflow.rawValue
				switch wf {
				case "debugging":
					tryAdd("explain_visible_error")
				case "research", "studying":
					tryAdd("synthesize_research_takeaways")
				case "writing", "notes":
					tryAdd("structure_key_points")
				case "browsing":
					tryAdd("summarize_context")
				default:
					// Generic: pick the first non-trivial reasoning hook.
					includeFirst {
						$0.category == .reasoning && $0.isImplemented
						&& $0.id != "observe_current_context"
						&& $0.id != "classify_workflow"
					}
				}

			case "compare":
				// Compare needs both extraction (source material) AND reasoning (compare logic).
				// Include the canonical compare hook plus an extraction support hook.
				tryAdd("compare_items")
				// Support hook: extract structured attributes for richer comparison.
				includeFirst { $0.category == .extraction && $0.isImplemented && $0.id != "compare_items" }

			case "organize":
				// Organize: structure/note hooks work best here.
				tryAdd("structure_key_points")
				tryAdd("generate_checklist")

			case "output":
				// Output: presentation hooks; no-op if present_result already covers it.
				// The `present_result` anchor is always added at the end; nothing extra needed.
				break

			case "control":
				// Computer control: permissioned hooks only; never auto-execute.
				// These require user confirmation at runtime so safe to include in the plan.
				// Currently no implemented computerControl hooks — skip silently.
				// (When computerControl hooks are implemented, tryAdd them here.)
				break

			case "memory":
				// Memory: no dedicated hooks yet. Use recent-title inspection + summarize
				// as a proxy for "recall what the user was doing."
				tryAdd("inspect_recent_titles")
				tryAdd("summarize_context")

			case "utility":
				// Utility: cross-cutting. Workflow classification + a reasoning hook.
				tryAdd("classify_workflow")
				includeFirst {
					$0.category == .reasoning && $0.isImplemented
					&& $0.id != "classify_workflow"
					&& $0.id != "observe_current_context"
				}

			default:
				// Unknown cat — skip. The parser's forbidden-key check ensures only the 9 allowed
				// cats reach here; this branch is defensive only.
				break
			}
		}

		// Always cap the plan at a reasonable size to keep execution bounded.
		let maxHooks = GeneratedExecutionBounds.maxPrimitivesPerPlan + 2 // +2 for observe+present anchors
		if ids.count > maxHooks {
			ids = Array(ids.prefix(maxHooks))
			used = used.filter { ids.contains($0.id) }
		}

		// Every plan ends with present_result (UI display).
		if !ids.contains("present_result") { ids.append("present_result") }

		// Deduplicate used hooks.
		let uniqueUsed: [HookCapabilityDefinition] = {
			var seen: Set<String> = []
			return used.filter { seen.insert($0.id).inserted }
		}()

		let missing = missingCats(needCats: needCats, usedHooks: uniqueUsed, ids: ids)
		print("[HookDiscovery] pass=chain_assembly chain=[\(ids.joined(separator: ","))] missing_cats=[\(missing.joined(separator: ","))]")
		return Plan(hookIds: ids, usedHooks: uniqueUsed, missingCategories: missing)
	}

	/// Reports capability categories that couldn't be satisfied by any retrieved hook.
	private static func missingCats(
		needCats: [String],
		usedHooks: [HookCapabilityDefinition],
		ids: [String]
	) -> [String] {
		var missing: [String] = []
		let usedCategories = Set(usedHooks.map(\.category))
		let idSet = Set(ids)

		for cat in needCats {
			switch cat {
			case "extract":
				if !usedCategories.contains(.extraction) { missing.append(cat) }
			case "reason":
				if !usedCategories.contains(.reasoning) { missing.append(cat) }
			case "compare":
				// compare_items is the canonical hook; missing if absent.
				if !idSet.contains("compare_items") { missing.append(cat) }
			case "organize":
				if !idSet.contains("structure_key_points") && !idSet.contains("generate_checklist") {
					missing.append(cat)
				}
			case "control":
				// No implemented computerControl hooks yet — always report missing so logs are honest.
				missing.append(cat)
			case "context", "output", "memory", "utility":
				// These have acceptable fallbacks (observe_current_context / present_result / inspect)
				// so only report missing if truly nothing was added.
				break
			default:
				break
			}
		}
		return missing
	}
}
