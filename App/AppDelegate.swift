import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private let appState = AppState()
	private var menuBarController: MenuBarController?
	private var sourceManager: SourceManager?
	private let contextBuilder = ContextBuilder()

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
		menuBarController = MenuBarController(appState: appState)

		let manager = SourceManager { event in
			self.contextBuilder.handle(event)
			self.appState.debugContext = self.contextBuilder.model
			self.logContextModel(self.contextBuilder.model)

			switch event {
			case .sourceChanged(.clipboardTextChanged(let text)):
				let length = text?.count ?? 0
				let exists = (text?.isEmpty == false)
				print("[SourceEvent] clipboardTextChanged exists=\(exists) length=\(length)")
			case .sourceChanged(.selectedTextChanged(let text)):
				let length = text?.count ?? 0
				let exists = (text?.isEmpty == false)
				print("[SourceEvent] selectedTextChanged exists=\(exists) length=\(length)")
			default:
				print("[SourceEvent]", event)
			}
		}
		self.sourceManager = manager
		manager.start()
		appState.debugContext = contextBuilder.model
	}

	func applicationWillTerminate(_ notification: Notification) {
		sourceManager?.stop()
	}

	private func logContextModel(_ model: ContextModel) {
		print(
			"[ContextModel]",
			"app=\(model.activeAppName ?? "nil")",
			"bundle=\(model.activeAppBundleIdentifier ?? "nil")",
			"windowTitle=\(model.activeWindowTitle != nil)",
			"clipboard=(available:\(model.clipboardTextAvailable) length:\(model.clipboardTextLength))",
			"selection=(available:\(model.selectedTextAvailable) length:\(model.selectedTextLength))",
			"lastTrigger=\(model.lastSourceTrigger?.rawValue ?? "nil")",
			"recentApps=\(model.recentAppNames)",
			"recentTriggers=\(model.recentTriggers)"
		)
	}
}

