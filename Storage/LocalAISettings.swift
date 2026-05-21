import Foundation

/// Persistent user preferences for local AI (no prompts or model outputs stored).
final class LocalAISettings {
	static let shared = LocalAISettings()

	private let defaults: UserDefaults
	private enum Key {
		static let localAIEnabled = "com.contextual.localAI.enabled"
		static let autoStartOllama = "com.contextual.localAI.autoStartOllama"
		static let modelName = "com.contextual.localAI.modelName"
		/// Persisted task inference model override — set by ModelAuditManager when it selects
		/// a faster inference model than the base planner model. Survives app restarts so we
		/// don't fall back to phi3 while the audit cooldown is still active.
		static let taskInferenceModel = "com.contextual.localAI.taskInferenceModel"
		/// Persisted timestamp for the last successful model audit. Prevents re-auditing on
		/// every app launch (which can pause live task inference via the audit gate).
		static let taskInferenceLastAuditAt = "com.contextual.localAI.taskInferenceLastAuditAt"
	}

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		if defaults.object(forKey: Key.modelName) == nil {
			defaults.set("phi3", forKey: Key.modelName)
		}
	}

	var localAIEnabled: Bool {
		get { defaults.bool(forKey: Key.localAIEnabled) }
		set { defaults.set(newValue, forKey: Key.localAIEnabled) }
	}

	var autoStartOllama: Bool {
		get { defaults.bool(forKey: Key.autoStartOllama) }
		set { defaults.set(newValue, forKey: Key.autoStartOllama) }
	}

	/// Base model name (planner + executor tier). Defaults to phi3.
	var modelName: String {
		get { defaults.string(forKey: Key.modelName) ?? "phi3" }
		set { defaults.set(newValue, forKey: Key.modelName) }
	}

	/// Override for the task inference tier — persisted by the model audit so a fast
	/// model (e.g. qwen2.5:0.5b) survives across launches without re-benchmarking.
	/// `nil` means "use `modelName`" (no fast model selected yet).
	/// The sentinel value `"none"` means the audit ran but found no viable model.
	var taskInferenceModel: String? {
		get { defaults.string(forKey: Key.taskInferenceModel) }
		set {
			if let v = newValue {
				defaults.set(v, forKey: Key.taskInferenceModel)
			} else {
				defaults.removeObject(forKey: Key.taskInferenceModel)
			}
		}
	}

	/// When true, the audit determined streaming is unreliable for the selected model
	/// and batch mode (POST /api/generate with stream:false) should be used instead.
	var taskInferenceBatchMode: Bool {
		get { defaults.bool(forKey: "com.contextual.localAI.taskInferenceBatchMode") }
		set { defaults.set(newValue, forKey: "com.contextual.localAI.taskInferenceBatchMode") }
	}

	/// Last time the model audit ran (persisted). Used for cooldown across app restarts.
	var taskInferenceLastAuditAt: Date? {
		get { defaults.object(forKey: Key.taskInferenceLastAuditAt) as? Date }
		set {
			if let v = newValue {
				defaults.set(v, forKey: Key.taskInferenceLastAuditAt)
			} else {
				defaults.removeObject(forKey: Key.taskInferenceLastAuditAt)
			}
		}
	}

	/// Effective task inference model: persisted override if set, otherwise base model.
	/// Returns `nil` when the sentinel "none" is stored (explicitly no viable model).
	var effectiveTaskInferenceModel: String? {
		let v = taskInferenceModel
		if v == "none" { return nil }
		return v ?? modelName
	}
}
