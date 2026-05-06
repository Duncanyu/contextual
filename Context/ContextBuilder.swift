import Foundation

final class ContextBuilder {
	private(set) var model: ContextModel
	private var session: SessionState

	init(initialModel: ContextModel = ContextModel(), session: SessionState = SessionState()) {
		self.model = initialModel
		self.session = session
	}

	func handle(_ event: SourceEvent) {
		switch event {
		case .sourceChanged(let change):
			apply(change)
		case .screenCaptured(let payload):
			model.screenCaptureAvailable = true
			model.screenCaptureType = "manual"
			model.screenCaptureImage = payload.image
			model.screenCaptureCapturedAt = payload.timestamp
			model.screenOCRAvailable = false
			model.screenOCRText = nil
			model.screenOCRLineCount = 0
			model.screenOCRCapturedAt = nil
			model.lastSourceTrigger = .screenCaptured
			model.updatedAt = Date()
			session.recordTrigger(.screenCaptured)
		}
	}

	private func apply(_ change: SourceChange) {
		switch change {
		case .activeAppChanged(let bundleIdentifier, let name):
			model.activeAppBundleIdentifier = bundleIdentifier
			model.activeAppName = name
			model.lastSourceTrigger = .activeAppChanged
			model.updatedAt = Date()
			session.recordActiveApp(name: name, bundleIdentifier: bundleIdentifier)
			session.recordTrigger(.activeAppChanged)

		case .windowTitleChanged(_, _, let title):
			model.activeWindowTitle = title
			model.lastSourceTrigger = .windowTitleChanged
			model.updatedAt = Date()
			session.recordTrigger(.windowTitleChanged)

		case .clipboardTextChanged(let text):
			model.clipboardTextAvailable = (text?.isEmpty == false)
			model.clipboardTextLength = text?.count ?? 0
			model.lastSourceTrigger = .clipboardTextChanged
			model.updatedAt = Date()
			session.recordTrigger(.clipboardTextChanged)

		case .selectedTextChanged(let text):
			model.selectedTextAvailable = (text?.isEmpty == false)
			model.selectedTextLength = text?.count ?? 0
			model.lastSourceTrigger = .selectedTextChanged
			model.updatedAt = Date()
			session.recordTrigger(.selectedTextChanged)

		case .manualTriggerRequested:
			model.lastSourceTrigger = .manualTriggerRequested
			model.updatedAt = Date()
			session.recordTrigger(.manualTriggerRequested)

		case .screenOCRCompleted(let text, let lineCount, let capturedAt):
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			let hasText = !trimmed.isEmpty
			model.screenOCRAvailable = hasText
			model.screenOCRText = hasText ? trimmed : nil
			model.screenOCRLineCount = hasText ? lineCount : 0
			model.screenOCRCapturedAt = capturedAt
			model.lastSourceTrigger = .screenOCRCompleted
			model.updatedAt = Date()
			let chars = trimmed.utf8.count
			print("[OCR] context updated chars=\(chars) lines=\(lineCount)")
			session.recordTrigger(.screenOCRCompleted)
		}

		model.recentAppNames = session.recentAppLabels
		model.recentTriggers = session.recentTriggerLabels
	}
}

