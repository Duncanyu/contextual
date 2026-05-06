import AppKit

enum ActionInputCapture {
	private static let maxChars = 24_000

	static func primaryText(for context: ContextModel, minimumLength: Int) -> String? {
		if context.selectedTextAvailable && context.selectedTextLength >= minimumLength {
			if let s = fetchSelectedTextFromFocusedElement(), s.count >= minimumLength {
				return trim(s)
			}
		}
		if context.clipboardTextAvailable && context.clipboardTextLength >= minimumLength {
			if let s = NSPasteboard.general.string(forType: .string), s.count >= minimumLength {
				return trim(s)
			}
		}
		return nil
	}

	private static func trim(_ s: String) -> String {
		if s.count <= maxChars { return s }
		let idx = s.index(s.startIndex, offsetBy: maxChars)
		return String(s[..<idx])
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
