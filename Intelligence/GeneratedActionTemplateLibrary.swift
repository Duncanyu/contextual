import Foundation

// MARK: - Miss reason

/// Why a library lookup returned no matching templates (T18.3.5).
enum TemplateLibraryMissReason: String, Sendable, Equatable {
	/// The library contains no records at all (cold start / first run).
	case libraryEmpty = "library_empty"
	/// Records exist but none have reached reuse-eligible status.
	case noEligibleTemplates = "no_eligible_templates"
	/// Eligible templates exist but none match the current workflow, intent, or available context.
	case noMatchForContext = "no_match_for_context"
}

// MARK: - Result

/// Outcome of a synchronous-equivalent library lookup (T18.3.5).
enum GeneratedActionTemplateLibraryResult: Sendable {
	/// One or more eligible templates matched — surface immediately; no LLM needed.
	case found([ReusableGeneratedActionRecord])
	/// No match — large model generation should be queued, not run in the live path.
	case empty(reason: TemplateLibraryMissReason)

	var hasMatch: Bool {
		if case .found(let records) = self { return !records.isEmpty }
		return false
	}

	var records: [ReusableGeneratedActionRecord] {
		if case .found(let records) = self { return records }
		return []
	}

	var missReason: TemplateLibraryMissReason? {
		if case .empty(let reason) = self { return reason }
		return nil
	}
}

// MARK: - Protocol

/// Injectable abstraction for the template library (enables test stubs).
protocol GeneratedActionTemplateLibraryProviding: Sendable {
	func retrieve(
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) async -> GeneratedActionTemplateLibraryResult

	func enqueuePrewarm(
		situational: SituationalContextSnapshot,
		decision: AgenticProposalDecision,
		referenceTime: Date
	) async
}

// MARK: - Actor

/// Fast library lookup for reusable generated action templates (T18.3.5).
///
/// Responsibilities:
/// - Translate SituationalContextSnapshot → persistence query keys (workflow, intent, context types).
/// - Return matching eligible templates instantly from in-memory state.
/// - Never call the large LLM. Never block the live proposal path.
/// - Enqueue prewarm requests when the library misses, for deferred async design.
actor GeneratedActionTemplateLibrary: GeneratedActionTemplateLibraryProviding {

	static let shared = GeneratedActionTemplateLibrary()

	private let manager: GeneratedActionPersistenceManager
	private let prewarmQueue: GeneratedActionTemplatePrewarmQueue

	init(
		manager: GeneratedActionPersistenceManager = GeneratedActionPersistenceManager(),
		prewarmQueue: GeneratedActionTemplatePrewarmQueue = .shared
	) {
		self.manager = manager
		self.prewarmQueue = prewarmQueue
	}

	// MARK: - Public API

	/// Returns matching templates instantly. Never calls the large LLM.
	func retrieve(
		situational: SituationalContextSnapshot,
		referenceTime: Date = Date()
	) async -> GeneratedActionTemplateLibraryResult {
		let workflowType = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
		let intentType = intentType(from: situational.inferredIntent)
		let contextTypes = availableContextTypes(from: situational)

		print("[TemplateLibrary] retrieve_started workflow=\(workflowType.rawValue) intent=\(intentType.rawValue) context_types=\(contextTypes.map(\.rawValue).joined(separator: ","))")

		let allRecords = await manager.snapshot()
		guard !allRecords.isEmpty else {
			let reason = TemplateLibraryMissReason.libraryEmpty
			log(event: "library_miss", reason: reason.rawValue,
				workflow: workflowType.rawValue, intent: intentType.rawValue)
			print("[TemplateLibrary] retrieve_finished result=miss reason=\(reason.rawValue)")
			return .empty(reason: reason)
		}

		let anyEligible = allRecords.contains { $0.reuseEligibility == .eligible && !$0.isExpired }
		guard anyEligible else {
			let reason = TemplateLibraryMissReason.noEligibleTemplates
			log(event: "library_miss", reason: reason.rawValue,
				workflow: workflowType.rawValue, intent: intentType.rawValue)
			print("[TemplateLibrary] retrieve_finished result=miss reason=\(reason.rawValue)")
			return .empty(reason: reason)
		}

		let matches = await manager.reusableActions(
			for: workflowType,
			intentType: intentType,
			availableContextTypes: contextTypes
		)

		guard !matches.isEmpty else {
			let reason = TemplateLibraryMissReason.noMatchForContext
			log(event: "library_miss", reason: reason.rawValue,
				workflow: workflowType.rawValue, intent: intentType.rawValue)
			print("[TemplateLibrary] retrieve_finished result=miss reason=\(reason.rawValue)")
			return .empty(reason: reason)
		}

		log(event: "library_hit", reason: "matched=\(matches.count)",
			workflow: workflowType.rawValue, intent: intentType.rawValue)
		print("[TemplateLibrary] retrieve_finished result=hit count=\(matches.count) workflow=\(workflowType.rawValue)")
		return .found(matches)
	}

	/// Enqueues a deferred template design request for the large model (not executed in live path).
	func enqueuePrewarm(
		situational: SituationalContextSnapshot,
		decision: AgenticProposalDecision,
		referenceTime: Date = Date()
	) async {
		let workflowType = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
		let intentType = intentType(from: situational.inferredIntent)
		let contextTypes = availableContextTypes(from: situational)
		let missReason = TemplateLibraryMissReason.noMatchForContext

		let request = GeneratedActionTemplatePrewarmRequest(
			workflowType: workflowType,
			intentType: intentType,
			availableContextTypes: contextTypes,
			missReason: missReason,
			requestedAt: referenceTime,
			appName: situational.activeAppName,
			decisionConfidence: decision.confidence
		)
		await prewarmQueue.enqueue(request)
	}

	// MARK: - Type mapping

	private func intentType(from synthesized: SynthesizedIntentType?) -> IntentType {
		guard let synthesized else { return .unknown }
		return WorkflowExecutionMapper.intentType(from: synthesized)
	}

	/// Maps available situational signals to the context-requirement codes the library indexes by.
	private func availableContextTypes(from situational: SituationalContextSnapshot) -> [ContextRequirementType] {
		var types: [ContextRequirementType] = []
		if situational.selectedTextSignal.availability == .available {
			types += [.textSnippet, .selectedText]
		}
		if situational.clipboardSignal.availability == .available {
			types.append(.textSnippet)
		}
		if situational.ocrSignal.availability == .available {
			types.append(.fusedVisual)
		}
		if situational.visualSignal.availability == .available {
			types += [.fusedVisual, .screenCapture]
		}
		if situational.inferredWorkflow != .unknown {
			types.append(.workflowContext)
		}
		if situational.inferredWorkflow == .debugging {
			types.append(.errorContext)
		}
		if types.isEmpty {
			types.append(.none)
		}
		// Deduplicate while preserving order.
		var seen = Set<ContextRequirementType>()
		return types.filter { seen.insert($0).inserted }
	}

	// MARK: - Logging

	private func log(event: String, reason: String, workflow: String, intent: String) {
		print("[TemplateLibrary] \(event) reason=\(reason) workflow=\(workflow) intent=\(intent)")
	}
}
