import AppKit

final class WindowTitleSource: SystemSource {
	private let onEvent: (SourceEvent) -> Void

	private var activationObserver: Any?
	private var pollTimer: Timer?

	private var lastEmittedTitle: String?
	private var lastFrontmostPid: pid_t?
	private var didLogMissingPermission: Bool = false

	init(onEvent: @escaping (SourceEvent) -> Void) {
		self.onEvent = onEvent
	}

	func start() {
		activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didActivateApplicationNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.pollOnce()
		}

		pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
			self?.pollOnce()
		}

		pollOnce()
	}

	func stop() {
		if let activationObserver {
			NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
			self.activationObserver = nil
		}

		pollTimer?.invalidate()
		pollTimer = nil
	}

	private func pollOnce() {
		guard isAccessibilityTrusted() else {
			if !didLogMissingPermission {
				didLogMissingPermission = true
				print("[WindowTitleSource] Accessibility permission not granted. Window titles will not be available.")
			}
			return
		}

		didLogMissingPermission = false

		guard let app = NSWorkspace.shared.frontmostApplication else { return }
		let pid = app.processIdentifier

		let title = fetchFocusedWindowTitle(forPid: pid)

		if pid != lastFrontmostPid {
			lastFrontmostPid = pid
			lastEmittedTitle = nil
		}

		guard title != lastEmittedTitle else { return }
		lastEmittedTitle = title

		onEvent(
			.sourceChanged(
				.windowTitleChanged(
					bundleIdentifier: app.bundleIdentifier ?? "unknown",
					appName: app.localizedName,
					title: title
				)
			)
		)
	}

	private func isAccessibilityTrusted() -> Bool {
		let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
		return AXIsProcessTrustedWithOptions(options)
	}

	private func fetchFocusedWindowTitle(forPid pid: pid_t) -> String? {
		let appAX = AXUIElementCreateApplication(pid)

		var focusedWindow: CFTypeRef?
		let focusedResult = AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &focusedWindow)
		guard focusedResult == .success, let focusedWindowAX = focusedWindow else { return nil }

		var titleValue: CFTypeRef?
		let titleResult = AXUIElementCopyAttributeValue(focusedWindowAX as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
		guard titleResult == .success else { return nil }

		return titleValue as? String
	}
}

