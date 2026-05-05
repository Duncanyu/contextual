import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private let appState = AppState()
	private var menuBarController: MenuBarController?
	private var sourceManager: SourceManager?

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
		menuBarController = MenuBarController(appState: appState)

		let manager = SourceManager { event in
			switch event {
			case .sourceChanged(.clipboardTextChanged(let text)):
				let length = text?.count ?? 0
				let exists = (text?.isEmpty == false)
				print("[SourceEvent] clipboardTextChanged exists=\(exists) length=\(length)")
			default:
				print("[SourceEvent]", event)
			}
		}
		self.sourceManager = manager
		manager.start()
	}

	func applicationWillTerminate(_ notification: Notification) {
		sourceManager?.stop()
	}
}

