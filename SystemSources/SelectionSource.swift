import AppKit
import CryptoKit

final class SelectionSource: SystemSource {
	private let onEvent: (SourceEvent) -> Void

	private var pollTimer: Timer?

	private var lastFingerprint: String?
	private var didLogMissingPermission: Bool = false

	init(onEvent: @escaping (SourceEvent) -> Void) {
		self.onEvent = onEvent
	}

	func start() {
		pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
			self?.pollOnce()
		}
		pollOnce()
	}

	func stop() {
		pollTimer?.invalidate()
		pollTimer = nil
	}

	private func pollOnce() {
		guard isAccessibilityTrusted() else {
			if !didLogMissingPermission {
				didLogMissingPermission = true
				print("[SelectionSource] Accessibility permission not granted. Selected text will not be available.")
			}
			return
		}
		didLogMissingPermission = false

		guard let app = NSWorkspace.shared.frontmostApplication else { return }
		let pid = app.processIdentifier

		let selectedText = fetchSelectedText(forPid: pid)
		let fingerprint = fingerprintForText(selectedText)

		guard fingerprint != lastFingerprint else { return }
		lastFingerprint = fingerprint

		onEvent(.sourceChanged(.selectedTextChanged(text: selectedText)))
	}

	private func isAccessibilityTrusted() -> Bool {
		let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
		return AXIsProcessTrustedWithOptions(options)
	}

	private func fetchSelectedText(forPid pid: pid_t) -> String? {
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

	private func fingerprintForText(_ text: String?) -> String? {
		guard let text else { return nil }
		let digest = SHA256.hash(data: Data(text.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}
}

