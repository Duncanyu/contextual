import Foundation

/// Drains the prewarm queue and creates deterministic templates for queued requests (T18.3.6).
///
/// Design rules:
/// - Option A only: deterministic template creation from built-in catalog. No LLM calls.
/// - Skips requests already satisfied by an existing library template.
/// - Safe to call at startup or after a library miss. Never called from the live hot path.
/// - Does NOT create background loops.
actor GeneratedActionTemplatePrewarmConsumer {

	static let shared = GeneratedActionTemplatePrewarmConsumer()

	/// Drains `queue` and creates deterministic templates for any unsatisfied requests.
	/// Newly created templates are inserted into `manager` via `insertSeedRecordIfMissing`.
	func consume(
		from queue: GeneratedActionTemplatePrewarmQueue,
		seeder: GeneratedActionTemplateSeeder,
		manager: GeneratedActionPersistenceManager,
		referenceTime: Date = Date()
	) async {
		let requests = await queue.drain()
		guard !requests.isEmpty else { return }

		print("[TemplatePrewarm] consumer_started count=\(requests.count)")
		var created = 0
		var satisfied = 0

		for request in requests {
			// Check if the library can already satisfy this workflow/intent.
			let existing = await manager.reusableActions(
				for: request.workflowType,
				intentType: request.intentType,
				availableContextTypes: request.availableContextTypes
			)
			if !existing.isEmpty {
				print("[TemplatePrewarm] already_satisfied workflow=\(request.workflowType.rawValue) intent=\(request.intentType.rawValue)")
				satisfied += 1
				continue
			}

			// Look up a deterministic template from the built-in catalog.
			guard let template = await seeder.deterministicTemplate(for: request, referenceTime: referenceTime) else {
				print("[TemplatePrewarm] no_deterministic_template workflow=\(request.workflowType.rawValue) intent=\(request.intentType.rawValue)")
				continue
			}

			let inserted = await manager.insertSeedRecordIfMissing(template)
			if inserted {
				print("[TemplatePrewarm] deterministic_template_created workflow=\(request.workflowType.rawValue) intent=\(request.intentType.rawValue) id=\(template.actionTemplateId)")
				created += 1
			} else {
				satisfied += 1
			}
		}

		print("[TemplatePrewarm] consumer_finished created=\(created) satisfied=\(satisfied) total_requests=\(requests.count)")
	}
}
