import Foundation

/// Persistent user preferences for local AI (no prompts or model outputs stored).
final class LocalAISettings {
	static let shared = LocalAISettings()

	private let defaults: UserDefaults
	private enum Key {
		static let localAIEnabled = "com.contextual.localAI.enabled"
		static let autoStartOllama = "com.contextual.localAI.autoStartOllama"
		static let modelName = "com.contextual.localAI.modelName"
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

	var modelName: String {
		get { defaults.string(forKey: Key.modelName) ?? "phi3" }
		set { defaults.set(newValue, forKey: Key.modelName) }
	}
}
