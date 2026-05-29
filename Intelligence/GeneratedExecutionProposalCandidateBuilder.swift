import Foundation

/// Builds generated execution proposal candidates from pipeline models (no runtime execution).
enum GeneratedExecutionProposalCandidateBuilder {

	static let minimumConfidence: Double = 0.46

	static func build(
		from generatedActions: [GeneratedAction],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date = Date()
	) -> [GeneratedExecutionProposalCandidate] {
		generatedActions.compactMap { action in
			buildCandidate(from: action, snapshot: snapshot, referenceTime: referenceTime)
		}
	}

	static func buildReusable(
		from records: [ReusableGeneratedActionRecord],
		referenceTime: Date = Date()
	) -> [GeneratedExecutionProposalCandidate] {
		records
			.filter { $0.reuseEligibility == .eligible && !$0.isExpired }
			.map { record in
				let fallback = reusableTitleAndDescriptionIfNeeded(record: record)
				let execution = executionAction(from: record, referenceTime: referenceTime)
				return GeneratedExecutionProposalCandidate(
					id: "reuse:\(record.actionTemplateId)",
					title: fallback.title,
					description: fallback.description,
					source: .reusableGenerated,
					workflowType: record.workflowType,
					intentType: record.intentType,
					confidence: record.averageConfidence,
					interruptionCost: 0.24,
					explainabilitySummary: "reusable_template|\(record.primitiveSignature)",
					expectedOutputSummary: "Reuse prior successful generated output pattern.",
					requiredContextTypes: record.requiredContextTypes,
					targetAnchor: nil,
					executionAction: execution,
					generatedActionId: nil,
					primitiveSignature: record.primitiveSignature,
					isExecutableGeneratedProposal: true
				)
			}
	}

	// MARK: - Private

	private static func buildCandidate(
		from action: GeneratedAction,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> GeneratedExecutionProposalCandidate? {
		if action.isStale || action.confidence < minimumConfidence { return nil }

		let primitives = executionPrimitives(from: action.primitives)
		guard !primitives.isEmpty else { return nil }

		let requiresVision = action.requiredContext.contains(.fusedVisual)
			|| action.requiredContext.contains(.screenCapture)
		let requiresOCR = action.requiredContext.contains(.screenCapture)
		let requiredTypes = mapRequiredContext(action.requiredContext)

		let plan = ExecutionPlan(
			primitives: primitives,
			estimatedCost: 0.25 + Double(primitives.count) * 0.08,
			estimatedRuntime: TimeInterval(8 + primitives.count * 6),
			requiresVision: requiresVision,
			requiresOCR: requiresOCR,
			requiresUserIntent: true,
			requiredPermissions: requiresVision || requiresOCR ? [.screenRecording] : [.none],
			fallbackBehavior: .degradeToSummary,
			executionBudget: .conservative,
			planConfidence: action.confidence
		)

		let wf = WorkflowExecutionMapper.workflowType(from: action.workflow)
		let intent = WorkflowExecutionMapper.intentType(from: action.intentType)
		let expected = expectedOutputSummary(for: action.intentType, primitives: primitives)

		let targetAnchor = buildTargetAnchorIfPossible(
			snapshot: snapshot,
			referenceTime: referenceTime,
			sourceCandidateId: action.id.uuidString
		)
		if let anchor = targetAnchor {
			print("[TargetAnchorTrace] stage=candidate_created anchor_nil=no")
			print("[TargetAnchorTrace] bundle=\(anchor.bundleIdentifier)")
			print("[TargetAnchorTrace] title=\"\(anchor.windowTitle.prefix(80))\"")
		} else {
			print("[TargetAnchorTrace] stage=candidate_created anchor_nil=yes")
			if let bundle = snapshot.bundleIdentifier,
			   !bundle.isEmpty,
			   bundle != Bundle.main.bundleIdentifier,
			   !snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				print("[TargetAnchorTrace] error=anchor_lost_at_candidate_creation")
			}
		}

		let execution = GeneratedExecutionAction(
			title: action.title,
			description: action.description,
			workflowType: wf,
			intentType: intent,
			confidence: action.confidence,
			interruptionCost: action.interruptionCost,
			requiredContextTypes: requiredTypes,
			executionPlan: plan,
			explainabilitySummary: action.explainabilitySummary,
			generationSource: .generatedAction,
			targetAnchor: targetAnchor,
			createdAt: referenceTime,
			expirationDate: min(action.expiresAt, referenceTime.addingTimeInterval(180)),
			isReusable: false,
			reuseScore: action.workflowRelevance
		)

		return GeneratedExecutionProposalCandidate(
			id: action.id.uuidString,
			title: action.title,
			description: action.description,
			source: .generatedExecution,
			workflowType: wf,
			intentType: intent,
			confidence: action.confidence,
			interruptionCost: action.interruptionCost,
			explainabilitySummary: action.explainabilitySummary,
			expectedOutputSummary: expected,
			requiredContextTypes: requiredTypes,
			targetAnchor: targetAnchor,
			executionAction: execution,
			generatedActionId: action.id,
			primitiveSignature: action.primitives.map(\.rawValue).sorted().joined(separator: ","),
			isExecutableGeneratedProposal: true
		)
	}

	private static func buildTargetAnchorIfPossible(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date,
		sourceCandidateId: String
	) -> TargetWindowAnchor? {
		guard let bundle = snapshot.bundleIdentifier, !bundle.isEmpty else { return nil }
		if bundle == Bundle.main.bundleIdentifier { return nil }
		let title = snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !title.isEmpty else { return nil }
		let fp = TargetWindowAnchor.fingerprint(
			bundleIdentifier: bundle,
			windowTitle: snapshot.windowTitle,
			workflow: .unknown
		)
		return TargetWindowAnchor(
			bundleIdentifier: bundle,
			appName: snapshot.activeApp,
			windowTitle: snapshot.windowTitle,
			contextFingerprint: fp,
			createdAt: referenceTime,
			sourceCandidateId: sourceCandidateId
		)
	}

	static func executionAction(
		from record: ReusableGeneratedActionRecord,
		referenceTime: Date
	) -> GeneratedExecutionAction {
		let primitives: [ExecutionPrimitive] = record.primitiveSignature
			.split(separator: ",")
			.compactMap { ExecutionPrimitive(rawValue: String($0)) }
		let requiresVisual = record.metadata["requires_visual"] == "1"
		let requiresOCR = record.metadata["requires_ocr"] == "1"
		let executionBudget: ExecutionBudget = {
			guard requiresVisual || requiresOCR else { return .conservative }
			// User-initiated reusable execution may perform a single bounded visual peek.
			// Keep CPU/concurrency conservative; explicitly allow vision/OCR for this plan.
			return ExecutionBudget(
				maxCPUPercent: 35,
				maxConcurrentTasks: 1,
				maxExecutionTime: 45,
				allowsVision: requiresVisual,
				allowsOCR: requiresOCR,
				allowsLLM: true,
				allowsBackgroundWork: false,
				thermalStateSensitivity: 0.6,
				budgetPriority: .userInitiated
			)
		}()
		let fallback = reusableTitleAndDescriptionIfNeeded(record: record)
		let plan = ExecutionPlan(
			primitives: primitives.isEmpty ? [.summarizeContext] : primitives,
			estimatedCost: requiresVisual || requiresOCR ? 0.28 : 0.2,
			estimatedRuntime: requiresVisual || requiresOCR ? 18 : 12,
			requiresVision: requiresVisual,
			requiresOCR: requiresOCR,
			requiresUserIntent: true,
			requiredPermissions: (requiresVisual || requiresOCR) ? [.screenRecording] : [.none],
			fallbackBehavior: .degradeToSummary,
			executionBudget: executionBudget,
			planConfidence: record.averageConfidence
		)
		return GeneratedExecutionAction(
			title: fallback.title,
			description: fallback.description,
			workflowType: record.workflowType,
			intentType: record.intentType,
			confidence: record.averageConfidence,
			interruptionCost: 0.22,
			requiredContextTypes: record.requiredContextTypes,
			executionPlan: plan,
			explainabilitySummary: "reusable|\(record.actionTemplateId)",
			generationSource: .reuseCache,
			createdAt: referenceTime,
			expirationDate: record.expiresAt,
			isReusable: true,
			reuseScore: record.usefulnessScore
		)
	}

	private struct ReusableTitleFallback {
		let title: String
		let description: String
		let usedFallbackTitle: Bool
		let reason: String
	}

	private static func reusableTitleAndDescriptionIfNeeded(
		record: ReusableGeneratedActionRecord
	) -> ReusableTitleFallback {
		let rawTitle = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
		let rawDescription = record.description.trimmingCharacters(in: .whitespacesAndNewlines)
		let titleNeedsRepair = GeneratedProposalTitleSynthesizer.needsRepair(
			title: rawTitle,
			templateId: record.actionTemplateId
		)
		let descMissing = rawDescription.isEmpty || rawDescription == "Reusable generated execution template"

		guard titleNeedsRepair || descMissing else {
			return ReusableTitleFallback(
				title: record.title,
				description: record.description,
				usedFallbackTitle: false,
				reason: "none"
			)
		}

		let synthesized = GeneratedProposalTitleSynthesizer.synthesize(
			workflowType: record.workflowType,
			intentType: record.intentType,
			primitiveSignature: record.primitiveSignature,
			requiredContextTypes: record.requiredContextTypes,
			metadata: record.metadata
		)
		let title = titleNeedsRepair ? synthesized.title : record.title
		let description = descMissing ? synthesized.description : record.description
		let reason = titleNeedsRepair ? "repaired_title" : "placeholder_description"
		if titleNeedsRepair {
			print(
				"[GeneratedProposalTitle] repaired record=\(record.actionTemplateId.prefix(80)) reason=\(reason)"
			)
		}
		return ReusableTitleFallback(
			title: title,
			description: description,
			usedFallbackTitle: titleNeedsRepair,
			reason: reason
		)
	}

	static func executionPrimitives(from generated: [GeneratedActionPrimitive]) -> [ExecutionPrimitive] {
		var out: [ExecutionPrimitive] = []
		for primitive in generated {
			switch primitive {
			case .summarize: out.append(.summarizeContext)
			case .explain: out.append(.answerFromContext)
			case .extract: out.append(.extractActionItems)
			case .structure: out.append(.structureNotes)
			case .checklist: out.append(.generateChecklist)
			case .compare: out.append(.compareContexts)
			case .classify: out.append(.classifyWorkflow)
			case .draft, .rewrite, .review:
				continue
			}
		}
		return Array(out.prefix(GeneratedExecutionBounds.maxPrimitivesPerPlan))
	}

	private static func mapRequiredContext(_ contexts: [GeneratedActionRequiredContext]) -> [ContextRequirementType] {
		contexts.compactMap { ctx in
			switch ctx {
			case .textSnippet: .textSnippet
			case .fusedVisual: .fusedVisual
			case .screenCapture: .screenCapture
			case .multiSource: .multiSource
			case .none: nil
			}
		}
	}

	private static func expectedOutputSummary(
		for intent: SynthesizedIntentType,
		primitives: [ExecutionPrimitive]
	) -> String {
		let codes = primitives.map(\.rawValue).joined(separator: ",")
		return "intent=\(intent.rawValue)|primitives=\(codes)"
	}
}
