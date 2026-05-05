import Foundation

struct ContextModel: Equatable {
	var activeAppName: String?
	var activeAppBundleIdentifier: String?
	var activeWindowTitle: String?

	var clipboardTextAvailable: Bool
	var clipboardTextLength: Int

	var selectedTextAvailable: Bool
	var selectedTextLength: Int

	var lastSourceTrigger: LastSourceTrigger?
	var updatedAt: Date

	/// Rolling session history (most recent last), max 5.
	var recentAppNames: [String]
	/// Rolling source trigger ids (most recent last), max 5.
	var recentTriggers: [String]

	init() {
		self.activeAppName = nil
		self.activeAppBundleIdentifier = nil
		self.activeWindowTitle = nil

		self.clipboardTextAvailable = false
		self.clipboardTextLength = 0

		self.selectedTextAvailable = false
		self.selectedTextLength = 0

		self.lastSourceTrigger = nil
		self.updatedAt = Date()

		self.recentAppNames = []
		self.recentTriggers = []
	}
}

enum LastSourceTrigger: String, Equatable {
	case activeAppChanged
	case windowTitleChanged
	case clipboardTextChanged
	case selectedTextChanged
	case manualTriggerRequested
}

