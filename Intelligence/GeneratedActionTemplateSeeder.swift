import Foundation

// MARK: - Seed version

/// Increment to trigger re-seeding with new templates on next launch.
/// Previously seeded records that still exist are preserved (idempotent inserts).
enum GeneratedActionTemplateSeedVersion {
	static let current = 1
}

// MARK: - Seeder

/// Seeds built-in reusable generated action templates into the persistence store (T18.3.6).
///
/// Design rules:
/// - Templates are workflow-specific and use existing ExecutionPrimitive codes.
/// - They are NOT summarize / explain / rewrite static actions.
/// - seeded records start as `.eligible` with high usefulness so they surface immediately.
/// - `seedIfNeeded` is idempotent: calling it on every launch is safe.
/// - No LLM is called. No background loops are created.
actor GeneratedActionTemplateSeeder {

	static let shared = GeneratedActionTemplateSeeder()

	// MARK: - Public API

	/// Seeds built-in templates into `manager`. Safe to call on every launch — inserts only
	/// templates not already present. Logs outcome with [TemplateSeeder] prefix.
	func seedIfNeeded(
		into manager: GeneratedActionPersistenceManager,
		referenceTime: Date = Date()
	) async {
		print("[TemplateSeeder] seed_started version=\(GeneratedActionTemplateSeedVersion.current)")
		let templates = Self.builtInTemplates(referenceTime: referenceTime)
		var inserted = 0
		for template in templates {
			let isNew = await manager.insertSeedRecordIfMissing(template)
			if isNew { inserted += 1 }
		}
		print("[TemplateSeeder] seed_finished inserted=\(inserted) total=\(templates.count) version=\(GeneratedActionTemplateSeedVersion.current)")
	}

	/// Returns a deterministic template for a prewarm request if one exists in the built-in catalog.
	/// Used by `GeneratedActionTemplatePrewarmConsumer` to satisfy queued requests without LLM calls.
	func deterministicTemplate(
		for request: GeneratedActionTemplatePrewarmRequest,
		referenceTime: Date
	) -> ReusableGeneratedActionRecord? {
		let catalog = Self.builtInTemplates(referenceTime: referenceTime)
		// Exact match first: same workflow AND intent
		if let exact = catalog.first(where: {
			$0.workflowType == request.workflowType && $0.intentType == request.intentType
		}) {
			return exact
		}
		// Workflow-only match: same workflow, any intent
		if let workflowMatch = catalog.first(where: {
			$0.workflowType == request.workflowType
		}) {
			return workflowMatch
		}
		// Generic fallback: .unknown workflow template
		return catalog.first(where: { $0.workflowType == .unknown })
	}

	// MARK: - Built-in catalog

	/// The canonical seed set (v1). All templates:
	/// - Use bounded ExecutionPrimitive codes
	/// - Are NOT static summarize/explain/rewrite actions
	/// - Start eligible with conservative stats so they survive eligibility re-scoring
	static func builtInTemplates(referenceTime: Date) -> [ReusableGeneratedActionRecord] {
		let expiry = referenceTime.addingTimeInterval(90 * 24 * 60 * 60) // 90 days
		return [

			// MARK: Debugging / Xcode

			makeTemplate(
				id: "debugging|explain|explain_error|selected_text,error_context|v1",
				title: "Trace the likely issue from this error or code",
				description: "Identify the root cause from selected error text or code context",
				workflow: .debugging,
				intent: .explain,
				primitive: ExecutionPrimitive.explainError.rawValue,
				contextTypes: [.selectedText, .errorContext],
				expiry: expiry,
				referenceTime: referenceTime
			),

			makeTemplate(
				id: "debugging|extract|generate_checklist|workflow_context|v1",
				title: "Create a debugging checklist for this context",
				description: "Generate a structured checklist of things to verify given the current workflow",
				workflow: .debugging,
				intent: .extract,
				primitive: ExecutionPrimitive.generateChecklist.rawValue,
				contextTypes: [.workflowContext],
				expiry: expiry,
				referenceTime: referenceTime
			),

			makeTemplate(
				id: "debugging|answer|answer_from_context|text_snippet|v1",
				title: "Identify what is missing to debug this",
				description: "Determine what additional context or information is needed to make progress",
				workflow: .debugging,
				intent: .answer,
				primitive: ExecutionPrimitive.answerFromContext.rawValue,
				contextTypes: [.textSnippet],
				expiry: expiry,
				referenceTime: referenceTime
			),

			// MARK: Research / Reading

			makeTemplate(
				id: "research|extract|extract_action_items|workflow_context|v1",
				title: "Extract useful research questions from this context",
				description: "Generate focused research questions based on the current page or text",
				workflow: .research,
				intent: .extract,
				primitive: ExecutionPrimitive.extractActionItems.rawValue,
				contextTypes: [.workflowContext],
				expiry: expiry,
				referenceTime: referenceTime
			),

			makeTemplate(
				id: "research|review|synthesize_research_summary|workflow_context|v1",
				title: "Create a source-review checklist for this content",
				description: "Evaluate the current source for credibility, depth, and relevance",
				workflow: .research,
				intent: .review,
				primitive: ExecutionPrimitive.synthesizeResearchSummary.rawValue,
				contextTypes: [.workflowContext],
				expiry: expiry,
				referenceTime: referenceTime
			),

			// MARK: Browsing / Browser

			makeTemplate(
				id: "browsing|organize|organize_information|workflow_context|v1",
				title: "Prepare a comparison plan for this page or topic",
				description: "Organize available information from this page into a structured comparison",
				workflow: .browsing,
				intent: .organize,
				primitive: ExecutionPrimitive.organizeInformation.rawValue,
				contextTypes: [.workflowContext],
				expiry: expiry,
				referenceTime: referenceTime
			),

			makeTemplate(
				id: "browsing|extract|extract_action_items|workflow_context|v1",
				title: "Extract key signals from this page context",
				description: "Identify notable points, requirements, or action items visible in this browser context",
				workflow: .browsing,
				intent: .extract,
				primitive: ExecutionPrimitive.extractActionItems.rawValue,
				contextTypes: [.workflowContext],
				expiry: expiry,
				referenceTime: referenceTime
			),

			// MARK: Studying / Learning

			makeTemplate(
				id: "studying|structure|generate_study_notes|workflow_context|v1",
				title: "Create study notes from this learning context",
				description: "Generate structured notes from visible text, slides, or study material",
				workflow: .studying,
				intent: .structure,
				primitive: ExecutionPrimitive.generateStudyNotes.rawValue,
				contextTypes: [.workflowContext],
				expiry: expiry,
				referenceTime: referenceTime
			),

			makeTemplate(
				id: "studying|extract|generate_checklist|workflow_context|v1",
				title: "Generate a topic checklist from this learning material",
				description: "Identify key topics and open questions to study further",
				workflow: .studying,
				intent: .extract,
				primitive: ExecutionPrimitive.generateChecklist.rawValue,
				contextTypes: [.workflowContext],
				expiry: expiry,
				referenceTime: referenceTime
			),

			// MARK: Writing / Editing

			makeTemplate(
				id: "writing|organize|organize_information|text_snippet|v1",
				title: "Organize the structure of this text or document",
				description: "Rearrange or outline the current writing into a clearer structure",
				workflow: .writing,
				intent: .organize,
				primitive: ExecutionPrimitive.organizeInformation.rawValue,
				contextTypes: [.textSnippet],
				expiry: expiry,
				referenceTime: referenceTime
			),

			// MARK: Generic / Metadata-only (workflow-agnostic)

			makeTemplate(
				id: "unknown|classify|classify_workflow|workflow_context|v1",
				title: "Classify this workflow to surface better actions",
				description: "Determine the current task type to enable more specific assistance",
				workflow: .unknown,
				intent: .classify,
				primitive: ExecutionPrimitive.classifyWorkflow.rawValue,
				contextTypes: [.workflowContext],
				expiry: expiry,
				referenceTime: referenceTime
			),

			makeTemplate(
				id: "unknown|answer|answer_from_context|none|v1",
				title: "Identify what context is needed to surface a useful action",
				description: "Analyze available signals to determine what additional context would help",
				workflow: .unknown,
				intent: .answer,
				primitive: ExecutionPrimitive.answerFromContext.rawValue,
				contextTypes: [.none],
				expiry: expiry,
				referenceTime: referenceTime
			),
		]
	}

	// MARK: - Factory

	private static func makeTemplate(
		id: String,
		title: String,
		description: String,
		workflow: WorkflowType,
		intent: IntentType,
		primitive: String,
		contextTypes: [ContextRequirementType],
		expiry: Date,
		referenceTime: Date,
		usefulnessScore: Double = 0.65
	) -> ReusableGeneratedActionRecord {
		// Seed with non-zero stats so eligibility formula survives re-scoring:
		// successRate = 3/3 = 1.0 > 0.55, acceptedCount=3 >= 1, score=0.65 >= 0.52.
		ReusableGeneratedActionRecord(
			actionTemplateId: id,
			title: title,
			description: description,
			workflowType: workflow,
			intentType: intent,
			primitiveSignature: primitive,
			requiredContextTypes: contextTypes,
			createdAt: referenceTime,
			lastUsedAt: referenceTime,
			expiresAt: expiry,
			acceptedCount: 3,
			dismissedCount: 0,
			executedCount: 3,
			successfulExecutionCount: 3,
			failedExecutionCount: 0,
			repeatedUseCount: 2,
			usefulnessScore: usefulnessScore,
			averageConfidence: 0.72,
			reuseEligibility: .eligible,
			metadata: ["source": "seed_v\(GeneratedActionTemplateSeedVersion.current)"]
		)
	}
}
