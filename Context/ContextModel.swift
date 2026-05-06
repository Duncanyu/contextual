import CoreGraphics
import Foundation

struct ContextModel {
	var activeAppName: String?
	var activeAppBundleIdentifier: String?
	var activeWindowTitle: String?

	var clipboardTextAvailable: Bool
	var clipboardTextLength: Int

	var selectedTextAvailable: Bool
	var selectedTextLength: Int

	var screenCaptureAvailable: Bool
	var screenCaptureType: String?
	var screenCaptureImage: CGImage?
	var screenCaptureCapturedAt: Date?

	var screenOCRAvailable: Bool
	var screenOCRText: String?
	/// Character count for OCR text (kept in sync in ContextBuilder; use for metadata without reading `screenOCRText`).
	var screenOCRTextLength: Int
	var screenOCRLineCount: Int
	var screenOCRCapturedAt: Date?

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

		self.screenCaptureAvailable = false
		self.screenCaptureType = nil
		self.screenCaptureImage = nil
		self.screenCaptureCapturedAt = nil

		self.screenOCRAvailable = false
		self.screenOCRText = nil
		self.screenOCRTextLength = 0
		self.screenOCRLineCount = 0
		self.screenOCRCapturedAt = nil

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
	case screenCaptured
	case screenOCRCompleted
}

