import AppKit

extension Notification.Name {
	static let contextualManualTrigger = Notification.Name("com.contextual.manualTrigger")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private let appState = AppState()
	private var menuBarController: MenuBarController?
	private var sourceManager: SourceManager?
	private let contextBuilder = ContextBuilder()
	private let triggerEngine = TriggerEngine()
	private let actionRouter = ActionRouter()
	private var manualTriggerObserver: NSObjectProtocol?

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
		menuBarController = MenuBarController(appState: appState)

		appState.requestManualInvocation = { [weak self] in
			self?.dispatchManualTriggerEvent()
		}

		appState.onInvokeActionById = { [weak self] actionId in
			self?.invokeStoredAction(actionId: actionId)
		}

		manualTriggerObserver = NotificationCenter.default.addObserver(
			forName: .contextualManualTrigger,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.dispatchManualTriggerEvent()
		}

		let manager = SourceManager { event in
			self.processSourceEvent(event)
		}
		self.sourceManager = manager
		manager.start()
		processUpdatedContextAfterPipeline()

		Task.detached(priority: .utility) {
			let mm = ModelManager.shared
			if mm.isRuntimeAvailable() {
				print("[ModelManager] Runtime detected")
				await mm.ensureModelAvailable()
			} else {
				print("[ModelManager] Ollama not installed")
			}
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		if let manualTriggerObserver {
			NotificationCenter.default.removeObserver(manualTriggerObserver)
		}
		sourceManager?.stop()
	}

	private func dispatchManualTriggerEvent() {
		processSourceEvent(.sourceChanged(.manualTriggerRequested))
	}

	private func processSourceEvent(_ event: SourceEvent) {
		contextBuilder.handle(event)
		processUpdatedContextAfterPipeline()
		switch event {
		case .sourceChanged(.clipboardTextChanged(let text)):
			let length = text?.count ?? 0
			let exists = (text?.isEmpty == false)
			print("[SourceEvent] clipboardTextChanged exists=\(exists) length=\(length)")
		case .sourceChanged(.selectedTextChanged(let text)):
			let length = text?.count ?? 0
			let exists = (text?.isEmpty == false)
			print("[SourceEvent] selectedTextChanged exists=\(exists) length=\(length)")
		case .sourceChanged(.manualTriggerRequested):
			print("[SourceEvent] manualTriggerRequested")
		default:
			print("[SourceEvent]", event)
		}
	}

	private func processUpdatedContextAfterPipeline() {
		appState.debugContext = contextBuilder.model
		logContextModel(contextBuilder.model)

		let context = contextBuilder.model
		if let packet = triggerEngine.evaluate(context) {
			logTriggerPacket(packet, context: context)
			updateAvailableActions(from: packet, context: context)
		} else {
			appState.availableActions = []
		}
	}

	private func updateAvailableActions(from packet: TriggerPacket, context: ContextModel) {
		let mapped = actionRouter.matchingActions(for: packet)
		appState.availableActions = mapped.filter { $0.canExecute(context: context) }
	}

	private func invokeStoredAction(actionId: String) {
		let context = contextBuilder.model
		guard let action = appState.availableActions.first(where: { $0.id == actionId }) else { return }
		guard action.canExecute(context: context) else {
			print("[ActionResult] No valid actions")
			return
		}
		let result = action.execute(context: context)
		print("[ActionResult]", result.outputText)
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

	private func logTriggerPacket(_ packet: TriggerPacket, context: ContextModel) {
		print(
			"[TriggerPacket]",
			"type=\(packet.triggerType.rawValue)",
			"reason=\(packet.reason)",
			"actions=\(packet.candidateActions)",
			"clipboardLength=\(context.clipboardTextLength)",
			"selectionLength=\(context.selectedTextLength)",
			"createdAt=\(packet.createdAt)"
		)
	}
}

