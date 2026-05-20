import Foundation

// MARK: - Request

/// A deferred request for the large model to design new action templates (T18.3.5).
///
/// Created when the library misses in the live path. Never executed synchronously.
/// Consumed by a separate async or manual mechanism — never by the live proposal cycle.
struct GeneratedActionTemplatePrewarmRequest: Equatable, Sendable {
	let id: UUID
	let workflowType: WorkflowType
	let intentType: IntentType
	let availableContextTypes: [ContextRequirementType]
	let missReason: TemplateLibraryMissReason
	let requestedAt: Date
	let appName: String
	let decisionConfidence: Double

	init(
		id: UUID = UUID(),
		workflowType: WorkflowType,
		intentType: IntentType,
		availableContextTypes: [ContextRequirementType],
		missReason: TemplateLibraryMissReason,
		requestedAt: Date = Date(),
		appName: String,
		decisionConfidence: Double
	) {
		self.id = id
		self.workflowType = workflowType
		self.intentType = intentType
		self.availableContextTypes = availableContextTypes
		self.missReason = missReason
		self.requestedAt = requestedAt
		self.appName = String(appName.prefix(64))
		self.decisionConfidence = min(1.0, max(0.0, decisionConfidence))
	}
}

// MARK: - Queue

/// Bounded queue of pending template prewarm requests (T18.3.5).
///
/// The live proposal path enqueues here on a library miss. Consumption is manual/async
/// (not part of the proposal cycle), ensuring the live path is never blocked by LLM latency.
///
/// Deduplicates by (workflowType, intentType) so repeated misses don't flood the queue.
/// Evicts oldest requests when the cap is reached.
actor GeneratedActionTemplatePrewarmQueue {

	static let shared = GeneratedActionTemplatePrewarmQueue()

	private(set) var pending: [GeneratedActionTemplatePrewarmRequest] = []
	private let maxPending: Int

	init(maxPending: Int = 10) {
		self.maxPending = maxPending
	}

	// MARK: - Public API

	/// Enqueues a request, deduplicating by (workflowType, intentType).
	/// Silently drops oldest if capacity is full.
	func enqueue(_ request: GeneratedActionTemplatePrewarmRequest) {
		let isDuplicate = pending.contains {
			$0.workflowType == request.workflowType && $0.intentType == request.intentType
		}
		guard !isDuplicate else {
			log(event: "prewarm_deduplicated",
				workflow: request.workflowType.rawValue,
				intent: request.intentType.rawValue,
				pending: pending.count)
			return
		}

		if pending.count >= maxPending {
			pending.removeFirst()
		}
		pending.append(request)
		log(event: "prewarm_enqueued",
			workflow: request.workflowType.rawValue,
			intent: request.intentType.rawValue,
			pending: pending.count)
	}

	/// Removes and returns the oldest pending request, or nil if empty.
	func dequeue() -> GeneratedActionTemplatePrewarmRequest? {
		guard !pending.isEmpty else { return nil }
		let request = pending.removeFirst()
		log(event: "prewarm_dequeued",
			workflow: request.workflowType.rawValue,
			intent: request.intentType.rawValue,
			pending: pending.count)
		return request
	}

	/// Removes and returns all pending requests (e.g. for batch processing).
	func drain() -> [GeneratedActionTemplatePrewarmRequest] {
		let all = pending
		pending = []
		if !all.isEmpty {
			print("[TemplatePrewarm] prewarm_drained count=\(all.count)")
		}
		return all
	}

	/// Current count of pending requests.
	var pendingCount: Int { pending.count }

	// MARK: - Logging

	private func log(event: String, workflow: String, intent: String, pending: Int) {
		print("[TemplatePrewarm] \(event) workflow=\(workflow) intent=\(intent) pending=\(pending)")
	}
}
