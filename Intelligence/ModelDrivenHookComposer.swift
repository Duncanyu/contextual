import Foundation

enum ModelDrivenHookComposer {
	static func compose(
		inference: TaskInferenceResult,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		recentTitles: [String],
		registry: HookCapabilityRegistry = .shared,
		referenceTime: Date = Date()
	) -> HookComposedProposal? {
		guard inference.shouldChime else { return nil }
		guard inference.confidence >= 0.42 else { return nil }

		let resolved = registry.resolveNeededCapabilities(inference.neededCapabilities)
		let implementedCaps = resolved.resolved.filter(\.isImplemented)
		let unknownCaps = resolved.unknown
		let unimplemented = resolved.resolved.filter { !$0.isImplemented }.map(\.id)
		let dangerousCaps = resolved.resolved.filter { $0.permissionLevel == .unavailable }.map(\.id)

		// Log unavailable hooks immediately — honesty about what can't execute.
		if !unknownCaps.isEmpty {
			print("[HookComposer] unavailable_hooks=[\(unknownCaps.joined(separator: ","))] reason=unknown_id")
		}
		if !unimplemented.isEmpty {
			print("[HookComposer] unavailable_hooks=[\(unimplemented.joined(separator: ","))] reason=not_implemented")
		}
		if !dangerousCaps.isEmpty {
			print("[HookComposer] unavailable_hooks=[\(dangerousCaps.joined(separator: ","))] reason=permanently_blocked")
		}

		// Avoid surfacing "ask for missing context" or dangerous hooks as primary proposals.
		let nonInternalCaps = implementedCaps.filter {
			$0.id != "ask_user_for_missing_context" && $0.permissionLevel != .unavailable
		}
		guard !nonInternalCaps.isEmpty else {
			print("[HookComposer] skipped reason=no_implemented_caps requested=[\(inference.neededCapabilities.joined(separator: ","))]")
			return nil
		}

		let hookIds: [String] = {
			var ids: [String] = []
			ids.append("observe_current_context")
			ids.append(contentsOf: nonInternalCaps.map(\.id))
			ids.append("present_result")
			var seen: Set<String> = []
			return ids.filter { seen.insert($0).inserted }
		}()

		let primitives = HookCapabilityRegistry.primitives(from: nonInternalCaps)
		let intent = inferIntent(from: primitives)
		let workflow = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)

		let title = synthesizeTitle(inference: inference, workflow: workflow, intent: intent)
		let question = synthesizeQuestion(inference: inference, title: title)

		let requiredContext = requiredContextTypes(from: nonInternalCaps, snapshot: snapshot, situational: situational)
		let whyNow = inference.whyNow.isEmpty ? "inferred" : inference.whyNow
		let cacheKeyBase = TaskInferenceEngine.fingerprint(
			snapshot: snapshot,
			situational: situational,
			recentTitles: recentTitles
		)
		let capSig = nonInternalCaps.map(\.id).joined(separator: ",")
		let capHash = abs(capSig.hashValue)
		let cacheKey = cacheKeyBase

		let contract = DynamicGeneratedActionContract(
			id: "hook:\(cacheKeyBase)|h\(capHash)",
			title: title,
			userFacingQuestion: question,
			inferredUserGoal: inference.possibleUserGoal.isEmpty ? inference.inferredTaskType : inference.possibleUserGoal,
			situationSummary: String(situational.situationalSummary.prefix(160)),
			whyNow: whyNow,
			hookPlanIds: hookIds,
			requiredContext: requiredContext,
			confidence: min(0.98, max(0.05, inference.confidence)),
			createdAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(max(8, min(60, inference.expirySeconds))),
			cacheEligibility: inference.confidence >= 0.66,
			cacheKey: cacheKey
		)

		if ProposalLoggingFlags.verboseProposalLogsEnabled {
			let unknownPart = unknownCaps.isEmpty ? "" : " unknown=\(unknownCaps.joined(separator: ","))"
			let unimplPart = unimplemented.isEmpty ? "" : " unimplemented=\(unimplemented.joined(separator: ","))"
			print("[HookComposer] chain=\(hookIds.joined(separator: ","))\(unknownPart)\(unimplPart)")
			print("[HookComposer] synthesized title=\(contract.title) question=\(contract.userFacingQuestion)")
		} else {
			let unavailableCount = unknownCaps.count + unimplemented.count
			print("[HookComposer] synthesized title=\(contract.title) hooks=\(hookIds.count) unavailable=\(unavailableCount)")
		}

		let proposal = ValidatedDynamicGeneratedProposal(
			id: contract.id,
			title: contract.title,
			description: contract.userFacingQuestion,
			workflowType: workflow,
			intentType: intent,
			expectedOutcome: contract.inferredUserGoal,
			requiredContextTypes: contract.requiredContext,
			suggestedPrimitives: primitives,
			interruptionCost: interruptionCost(workflow: workflow, confidence: contract.confidence, risk: inference.interruptionRisk),
			confidence: contract.confidence,
			usefulnessHint: "hook_composer_model"
		)

		return HookComposedProposal(contract: contract, proposal: proposal)
	}

	// MARK: - Title / question synthesis (no hardcoded behavior templates)

	private static func synthesizeTitle(
		inference: TaskInferenceResult,
		workflow: WorkflowType,
		intent: IntentType
	) -> String {
		let verb = inference.suggestedActionVerb.trimmingCharacters(in: .whitespacesAndNewlines)
		let obj = inference.suggestedObject.trimmingCharacters(in: .whitespacesAndNewlines)
		if !verb.isEmpty, !obj.isEmpty {
			return capitalizeFirst("\(verb) \(obj)", max: 64)
		}
		if !verb.isEmpty {
			return capitalizeFirst(verb, max: 64)
		}
		if !inference.possibleUserGoal.isEmpty {
			return capitalizeFirst(inference.possibleUserGoal, max: 64)
		}
		// Last resort (deterministic, not a behavior pattern): use workflow/intent labels.
		if workflow != .unknown, intent != .unknown {
			return "Help with \(workflow.rawValue) (\(intent.rawValue))"
		}
		return "Help with the current context"
	}

	private static func synthesizeQuestion(inference: TaskInferenceResult, title: String) -> String {
		// Prefer model-generated question (compact prompt 'q' field) — most natural.
		let modelQ = inference.userFacingQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
		if !modelQ.isEmpty, modelQ.contains("?") {
			return String(modelQ.prefix(120))
		}
		let verb = inference.suggestedActionVerb.trimmingCharacters(in: .whitespacesAndNewlines)
		let obj = inference.suggestedObject.trimmingCharacters(in: .whitespacesAndNewlines)
		if !verb.isEmpty, !obj.isEmpty {
			return "Want me to \(verb) \(obj)?"
		}
		if !inference.inferredTaskType.isEmpty {
			return "Want help with \(sanitizeSentence(inference.inferredTaskType))?"
		}
		return "Want help with this?"
	}

	private static func sanitizeSentence(_ s: String) -> String {
		let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return "this" }
		return String(trimmed.prefix(80)).replacingOccurrences(of: "\n", with: " ")
	}

	private static func capitalizeFirst(_ s: String, max: Int) -> String {
		let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return "Help" }
		let capped = String(trimmed.prefix(max))
		return capped.prefix(1).uppercased() + capped.dropFirst()
	}

	// MARK: - Mapping helpers

	private static func inferIntent(from primitives: [ExecutionPrimitive]) -> IntentType {
		if primitives.contains(.compareContexts) { return .compare }
		if primitives.contains(.explainError) { return .explain }
		if primitives.contains(.extractActionItems) { return .extract }
		if primitives.contains(.organizeInformation) { return .organize }
		if primitives.contains(.synthesizeResearchSummary) { return .synthesize }
		if primitives.contains(.structureNotes) { return .structure }
		if primitives.contains(.classifyWorkflow) { return .classify }
		if primitives.contains(.answerFromContext) { return .answer }
		if primitives.contains(.generateChecklist) { return .organize }
		if primitives.contains(.summarizeContext) { return .summarize }
		return .unknown
	}

	private static func requiredContextTypes(
		from capabilities: [HookCapabilityDefinition],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> [ContextRequirementType] {
		// Keep required types minimal: they should represent truly impossible-to-run constraints,
		// not soft preferences. In particular, don't require workflowContext for unknown workflows.
		var required: Set<ContextRequirementType> = []
		for cap in capabilities {
			for type in cap.requiredContextTypes where type != .none {
				required.insert(type)
			}
		}

		// If no text is present, avoid requiring textSnippet unless we already have OCR/selected/clipboard.
		let hasText = !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			|| !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			|| !(snapshot.clipboardText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		if !hasText {
			required.remove(.textSnippet)
			required.remove(.selectedText)
			required.remove(.errorContext)
			required.remove(.notesContext)
		}

		// Workflow context should not be strictly required if workflow is unknown.
		if situational.inferredWorkflow == .unknown {
			required.remove(.workflowContext)
		}

		// .multiSource (e.g. from compare_items) means "ideally needs content from multiple pages",
		// but the hook plan includes observe_current_context which gathers what is available now.
		// Don't gate the proposal on this — let execution handle missing multi-source gracefully.
		required.remove(.multiSource)

		if required.isEmpty { return [.none] }
		return Array(required)
	}

	private static func interruptionCost(workflow: WorkflowType, confidence: Double, risk: Double) -> Double {
		let base: Double
		switch workflow {
		case .debugging: base = 0.28
		case .research, .browsing, .studying: base = 0.24
		default: base = 0.20
		}
		let riskPenalty = max(0, min(0.25, risk)) * 0.18
		let confBoost = max(0, (confidence - 0.70)) * 0.12
		return max(0.08, min(0.70, base + riskPenalty - confBoost))
	}
}
