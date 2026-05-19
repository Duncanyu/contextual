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
				let execution = executionAction(from: record, referenceTime: referenceTime)
				return GeneratedExecutionProposalCandidate(
					id: "reuse:\(record.actionTemplateId)",
					title: record.title,
					description: record.description,
					source: .reusableGenerated,
					workflowType: record.workflowType,
					intentType: record.intentType,
					confidence: record.averageConfidence,
					interruptionCost: 0.24,
					explainabilitySummary: "reusable_template|\(record.primitiveSignature)",
					expectedOutputSummary: "Reuse prior successful generated output pattern.",
					requiredContextTypes: record.requiredContextTypes,
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
			executionAction: execution,
			generatedActionId: action.id,
			primitiveSignature: action.primitives.map(\.rawValue).sorted().joined(separator: ","),
			isExecutableGeneratedProposal: true
		)
	}

	private static func executionAction(
		from record: ReusableGeneratedActionRecord,
		referenceTime: Date
	) -> GeneratedExecutionAction {
		let primitives: [ExecutionPrimitive] = record.primitiveSignature
			.split(separator: ",")
			.compactMap { ExecutionPrimitive(rawValue: String($0)) }
		let plan = ExecutionPlan(
			primitives: primitives.isEmpty ? [.summarizeContext] : primitives,
			estimatedCost: 0.2,
			estimatedRuntime: 12,
			requiresVision: false,
			requiresOCR: false,
			requiresUserIntent: true,
			requiredPermissions: [.none],
			fallbackBehavior: .degradeToSummary,
			executionBudget: .conservative,
			planConfidence: record.averageConfidence
		)
		return GeneratedExecutionAction(
			title: record.title,
			description: record.description,
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
