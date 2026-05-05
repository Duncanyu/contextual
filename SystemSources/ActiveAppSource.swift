import AppKit

final class ActiveAppSource: SystemSource {
	private let onEvent: (SourceEvent) -> Void
	private var observer: Any?

	private var lastBundleIdentifier: String?

	init(onEvent: @escaping (SourceEvent) -> Void) {
		self.onEvent = onEvent
	}

	func start() {
		emitCurrentFrontmostAppIfNeeded()

		observer = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didActivateApplicationNotification,
			object: nil,
			queue: .main
		) { [weak self] notification in
			guard let self else { return }
			guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
				return
			}

			self.emit(app: app)
		}
	}

	func stop() {
		if let observer {
			NSWorkspace.shared.notificationCenter.removeObserver(observer)
			self.observer = nil
		}
	}

	private func emitCurrentFrontmostAppIfNeeded() {
		guard let app = NSWorkspace.shared.frontmostApplication else { return }
		emit(app: app)
	}

	private func emit(app: NSRunningApplication) {
		let bundleIdentifier = app.bundleIdentifier ?? "unknown"
		guard bundleIdentifier != lastBundleIdentifier else { return }
		lastBundleIdentifier = bundleIdentifier

		onEvent(
			.sourceChanged(
				.activeAppChanged(
					bundleIdentifier: bundleIdentifier,
					name: app.localizedName
				)
			)
		)
	}
}

