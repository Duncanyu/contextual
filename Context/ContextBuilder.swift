import Foundation

final class ContextBuilder {
	private(set) var model: ContextModel

	init(initialModel: ContextModel = ContextModel()) {
		self.model = initialModel
	}

	func handle(_ event: SourceEvent) {
		switch event {
		case .sourceChanged(let change):
			apply(change)
		}
	}

	private func apply(_ change: SourceChange) {
		switch change {
		case .activeAppChanged(let bundleIdentifier, let name):
			model.activeAppBundleIdentifier = bundleIdentifier
			model.activeAppName = name
			model.lastSourceTrigger = .activeAppChanged
			model.updatedAt = Date()

		case .windowTitleChanged(_, _, let title):
			model.activeWindowTitle = title
			model.lastSourceTrigger = .windowTitleChanged
			model.updatedAt = Date()

		case .clipboardTextChanged(let text):
			model.clipboardTextAvailable = (text?.isEmpty == false)
			model.clipboardTextLength = text?.count ?? 0
			model.lastSourceTrigger = .clipboardTextChanged
			model.updatedAt = Date()

		case .selectedTextChanged(let text):
			model.selectedTextAvailable = (text?.isEmpty == false)
			model.selectedTextLength = text?.count ?? 0
			model.lastSourceTrigger = .selectedTextChanged
			model.updatedAt = Date()
		}
	}
}

