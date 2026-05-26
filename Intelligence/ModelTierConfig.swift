import Foundation

// MARK: - Tier enum

/// The three explicit model tiers. All may point to the same model initially, but the
/// architecture separates them so latency and capability can be tuned independently.
enum ModelTier: String, Sendable {
	/// Ultra-fast; tiny JSON output; hot-path only. Streaming exits early on JSON close; hard cap 6s.
	case taskInference = "task_inference"
	/// Richer hook planning; not required for the initial proposal surface.
	case planner
	/// Heavy post-approval synthesis and result wording.
	case executor

	/// Emit a [ModelTier] log line for this tier.
	func log(model: String) {
		print("[ModelTier] \(rawValue) model=\(model)")
	}
}

// MARK: - Config

/// Immutable snapshot of which model name is assigned to each tier.
struct ModelTierConfig: Sendable, Equatable {
	let taskInferenceModel: String
	let plannerModel: String
	let executionModel: String

	/// All three tiers point to `base` model — the default before an audit runs.
	static func uniform(_ base: String) -> ModelTierConfig {
		ModelTierConfig(
			taskInferenceModel: base,
			plannerModel: base,
			executionModel: base
		)
	}

	/// Build from persistent settings plus an optional audit-selected override for task inference.
	///
	/// Priority: explicit `auditSelected` > `settings.taskInferenceModel` (persisted) > `settings.modelName`.
	/// This ensures a previously-selected fast model (e.g. phi4-mini) is restored on launch
	/// without waiting for the 1-hour audit cooldown to expire.
	/// Sentinel stored in `taskInferenceModel` when the audit found no viable model.
	static let noViableModel = "none"

	static func from(settings: LocalAISettings, auditSelected: String? = nil) -> ModelTierConfig {
		let base = settings.modelName
		// Priority: explicit auditSelected > persisted effectiveTaskInferenceModel > base model.
		// `effectiveTaskInferenceModel` returns nil when the sentinel "none" is stored, preserving
		// the "no viable model" state across the auditSelected fallback chain.
		let inferenceModel = auditSelected ?? settings.effectiveTaskInferenceModel ?? Self.noViableModel
		return ModelTierConfig(
			taskInferenceModel: inferenceModel,
			plannerModel: base,
			executionModel: base
		)
	}
}

// MARK: - Active config holder

/// Shared, thread-safe active tier configuration.
/// Updated when settings change or the model audit selects a better inference model.
final class ActiveModelTierConfig: @unchecked Sendable {
	static let shared = ActiveModelTierConfig()

	private let lock = NSLock()
	/// Initialise from persisted settings so a previously-selected fast task inference model
	/// (e.g. phi4-mini) is active immediately on launch, before the audit re-runs.
	private var _config: ModelTierConfig = .from(settings: LocalAISettings.shared)

	private init() {}

	var config: ModelTierConfig {
		lock.withLock { _config }
	}

	func update(_ new: ModelTierConfig) {
		lock.withLock { _config = new }
		ModelTier.taskInference.log(model: new.taskInferenceModel)
		ModelTier.planner.log(model: new.plannerModel)
		ModelTier.executor.log(model: new.executionModel)
	}

	var taskInferenceModel: String { config.taskInferenceModel }
	var plannerModel: String { config.plannerModel }
	var executionModel: String { config.executionModel }
}

private extension NSLock {
	func withLock<T>(_ body: () throws -> T) rethrows -> T {
		lock()
		defer { unlock() }
		return try body()
	}
}
