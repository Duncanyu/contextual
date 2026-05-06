import Foundation

import CoreGraphics

struct ScreenCapturePayload {
	let image: CGImage
	let timestamp: Date
	let source: String
}

enum SourceEvent {
	case sourceChanged(SourceChange)
	case screenCaptured(ScreenCapturePayload)
}

enum SourceChange {
	case activeAppChanged(bundleIdentifier: String, name: String?)
	case windowTitleChanged(bundleIdentifier: String, appName: String?, title: String?)
	case clipboardTextChanged(text: String?)
	case selectedTextChanged(text: String?)
	case screenOCRCompleted(text: String, lineCount: Int, capturedAt: Date)
	case manualTriggerRequested
}

