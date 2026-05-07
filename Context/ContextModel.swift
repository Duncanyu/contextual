import CoreGraphics
import Foundation

/// User-selected input channel for text-based actions (`automatic` follows selection → clipboard → screen OCR).
enum InputSourceChoice: String, CaseIterable, Identifiable, Sendable, Equatable {
	case automatic
	case selectedText
	case clipboard
	case screenOCR

	var id: String { rawValue }

	var pickerTitle: String {
		switch self {
		case .automatic:
			return "Automatic"
		case .selectedText:
			return "Selected text"
		case .clipboard:
			return "Clipboard"
		case .screenOCR:
			return "Screen text"
		}
	}

	/// Short label for “Using: …” copy (matches panel wording).
	var usingLabel: String {
		switch self {
		case .automatic:
			return "Automatic"
		case .selectedText:
			return "Selected text"
		case .clipboard:
			return "Clipboard"
		case .screenOCR:
			return "Screen text"
		}
	}
}

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

	/// Snapshot of user input preference for action execution (set by app lifecycle per invocation; not sourced from SystemSources).
	var actionInputSourcePreference: InputSourceChoice = .automatic

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

		self.actionInputSourcePreference = .automatic
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

