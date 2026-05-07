import AppKit

enum ActionInputCapture {
	private static let maxChars = 24_000

	static func primaryText(for context: ContextModel, minimumLength: Int, preference: InputSourceChoice = .automatic) -> String? {
		switch preference {
		case .automatic:
			if let s = textFromSelected(context, minimumLength: minimumLength) { return trim(s) }
			if let s = textFromClipboard(minimumLength: minimumLength) { return trim(s) }
			if let s = textFromOCR(context, minimumLength: minimumLength) { return trim(s) }
			return nil
		case .selectedText:
			guard let s = textFromSelected(context, minimumLength: minimumLength) else { return nil }
			return trim(s)
		case .clipboard:
			guard let s = textFromClipboard(minimumLength: minimumLength) else { return nil }
			return trim(s)
		case .screenOCR:
			guard let s = textFromOCR(context, minimumLength: minimumLength) else { return nil }
			return trim(s)
		}
	}

	private static func trim(_ s: String) -> String {
		if s.count <= maxChars { return s }
		let idx = s.index(s.startIndex, offsetBy: maxChars)
		return String(s[..<idx])
	}

	private static func textFromSelected(_ context: ContextModel, minimumLength: Int) -> String? {
		guard context.selectedTextAvailable && context.selectedTextLength >= minimumLength else { return nil }
		guard let s = fetchSelectedTextFromFocusedElement(), s.count >= minimumLength else { return nil }
		return s
	}

	private static func textFromClipboard(minimumLength: Int) -> String? {
		guard let s = NSPasteboard.general.string(forType: .string), s.count >= minimumLength else { return nil }
		return s
	}

	private static func textFromOCR(_ context: ContextModel, minimumLength: Int) -> String? {
		guard context.screenOCRAvailable && context.screenOCRTextLength >= minimumLength else { return nil }
		guard let s = context.screenOCRText, s.count >= minimumLength else { return nil }
		return s
	}

	private static func fetchSelectedTextFromFocusedElement() -> String? {
		guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
		let pid = app.processIdentifier
		let appAX = AXUIElementCreateApplication(pid)

		var focusedElement: CFTypeRef?
		let focusedResult = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedElement)
		guard focusedResult == .success, let focusedElement else { return nil }
		let focusedElementAX = focusedElement as! AXUIElement

		var selectedTextValue: CFTypeRef?
		let selectedResult = AXUIElementCopyAttributeValue(focusedElementAX, kAXSelectedTextAttribute as CFString, &selectedTextValue)
		guard selectedResult == .success else { return nil }

		return selectedTextValue as? String
	}
}
