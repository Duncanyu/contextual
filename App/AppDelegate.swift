import AppKit

extension Notification.Name {
	static let contextualManualTrigger = Notification.Name("com.contextual.manualTrigger")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private let appState = AppState()
	private var menuBarController: MenuBarController?
	private var floatingSuggestionController: FloatingSuggestionWindowController?
	private var sourceManager: SourceManager?
	private let contextBuilder = ContextBuilder()
	private let triggerEngine = TriggerEngine()
	private let actionRouter = ActionRouter()
	private var manualTriggerObserver: NSObjectProtocol?

	private var lastFinishedActionKey: String?
	private var lastFinishedAt: Date?

	private var lastReasonedActions: [any ActionProtocol] = []
	private var lastReasonedActionsAt: Date?
	private var lastReasonedTriggerType: TriggerType?
	private let availableActionsCacheTTLSeconds: TimeInterval = 10

	private var lastReasonedProposal: ActionProposal?
	private var lastReasonedProposalKey: String?

	private var lastContextLogSignature: String?
	private var lastPreserveLogAt: Date?
	private var lastManualInvocationAt: Date?
	private var didLogManualGuard: Bool = false

	/// Minimum confidence to show the non-panel floating suggestion (T10.1).
	private let floatingSuggestionMinConfidence: Double = 0.75

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
		syncLocalAIFromStorage()
		wireLocalAIHandlers()
		menuBarController = MenuBarController(appState: appState)
		floatingSuggestionController = FloatingSuggestionWindowController(appState: appState)

		appState.onRevealAssistantPanel = { [weak self] in
			self?.menuBarController?.revealPopoverIfNeeded()
		}

		appState.requestManualInvocation = { [weak self] in
			self?.dispatchManualTriggerEvent()
			self?.menuBarController?.revealPopoverIfNeeded()
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
			self?.menuBarController?.revealPopoverIfNeeded()
		}

		let manager = SourceManager { event in
			self.processSourceEvent(event)
		}
		self.sourceManager = manager
		manager.start()
		processUpdatedContextAfterPipeline()

		if LocalAISettings.shared.localAIEnabled {
			scheduleLocalAIPrepare()
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		if let manualTriggerObserver {
			NotificationCenter.default.removeObserver(manualTriggerObserver)
		}
		sourceManager?.stop()
	}

	private func syncLocalAIFromStorage() {
		let s = LocalAISettings.shared
		appState.localAIEnabled = s.localAIEnabled
		appState.autoStartOllama = s.autoStartOllama
	}

	private func wireLocalAIHandlers() {
		appState.onEnableLocalAI = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.localAIEnabled = true
			self.appState.localAIEnabled = true
			self.scheduleLocalAIPrepare()
		}

		appState.onDisableLocalAI = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.localAIEnabled = false
			self.appState.localAIEnabled = false
			self.appState.modelRuntimeState = .notRunning
		}

		appState.onEnableAutoStartOllama = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.autoStartOllama = true
			self.appState.autoStartOllama = true
			let uiState = self.appState
			Task.detached(priority: .utility) {
				do {
					try await ModelManager.shared.startOllamaServer()
				} catch {
					await MainActor.run {
						uiState.modelRuntimeState = .error(error.localizedDescription)
					}
					return
				}
				await ModelManager.shared.prepareLocalAIIfEnabled(settings: LocalAISettings.shared) { runtimeState in
					DispatchQueue.main.async {
						uiState.modelRuntimeState = runtimeState
					}
				}
			}
		}

		appState.onDisableAutoStartOllama = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.autoStartOllama = false
			self.appState.autoStartOllama = false
		}

		appState.onStartOllamaNow = { [weak self] in
			guard let self else { return }
			let uiState = self.appState
			Task.detached(priority: .utility) {
				do {
					try await ModelManager.shared.startOllamaServer()
				} catch {
					await MainActor.run {
						uiState.modelRuntimeState = .error(error.localizedDescription)
					}
					return
				}
				await ModelManager.shared.prepareLocalAIIfEnabled(settings: LocalAISettings.shared) { runtimeState in
					DispatchQueue.main.async {
						uiState.modelRuntimeState = runtimeState
					}
				}
			}
		}

		appState.onOpenOllamaDownload = {
			if let url = URL(string: "https://ollama.com/download") {
				NSWorkspace.shared.open(url)
			}
		}
	}

	private func scheduleLocalAIPrepare() {
		let uiState = appState
		Task.detached(priority: .utility) {
			await ModelManager.shared.prepareLocalAIIfEnabled(settings: LocalAISettings.shared) { runtimeState in
				DispatchQueue.main.async {
					uiState.modelRuntimeState = runtimeState
				}
			}
		}
	}

	private func dispatchManualTriggerEvent() {
		let now = Date()
		if let last = lastManualInvocationAt, now.timeIntervalSince(last) < 0.75 {
			if !didLogManualGuard {
				didLogManualGuard = true
				print("[ManualTrigger] ignored duplicate within guard window")
			}
			return
		}
		didLogManualGuard = false
		lastManualInvocationAt = now

		sourceManager?.captureScreenNow()
		sourceManager?.refreshSelectionNow()
		processSourceEvent(.sourceChanged(.manualTriggerRequested))

		if let image = contextBuilder.model.screenCaptureImage {
			Task.detached(priority: .utility) { [weak self] in
				guard let self else { return }
				let result = await OCRProcessor.shared.recognizeText(from: image)
				await MainActor.run {
					self.processSourceEvent(
					.sourceChanged(.screenOCRCompleted(text: result.text, lineCount: result.lineCount, capturedAt: result.timestamp))
					)
				}
			}
		}
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
		case .sourceChanged(.screenOCRCompleted(let text, let lineCount, _)):
			print("[SourceEvent] screenOCRCompleted chars=\(text.utf8.count) lines=\(lineCount)")
		case .screenCaptured:
			print("[SourceEvent] screenCaptured")
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
			preserveOrClearAvailableActions(reason: "no trigger packet")
		}
	}

	private func updateAvailableActions(from packet: TriggerPacket, context: ContextModel) {
		let decision = ReasoningEngine.shared.evaluate(context: context, triggerPacket: packet)
		let primary = decision.primaryActionId ?? "none"
		print("[ReasoningEngine] decision surface=\(decision.shouldSurface) primary=\(primary) confidence=\(decision.confidence) reason=\(decision.reason)")

		guard decision.shouldSurface else {
			preserveOrClearAvailableActions(reason: "reasoning shouldSurface=false")
			return
		}

		var proposal = ProposalGenerator.shared.generate(context: context, triggerPacket: packet, decision: decision)
		var proposalKey: String?
		if let p = proposal {
			proposalKey = "\(packet.triggerType.rawValue)|\(p.primaryActionId)"
		}

		if packet.triggerType != .manualInvocation, let key = proposalKey {
			if let dismissedAt = appState.lastDismissedProposalAt,
			   appState.lastDismissedProposalKey == key,
			   Date().timeIntervalSince(dismissedAt) < 60 {
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=dismissed")
				proposal = nil
				proposalKey = nil
			} else if let acceptedAt = appState.lastAcceptedProposalAt,
					  appState.lastAcceptedProposalKey == key,
					  Date().timeIntervalSince(acceptedAt) < 10 {
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=accepted")
				proposal = nil
				proposalKey = nil
			}
		}

		var evalContext = context
		evalContext.actionInputSourcePreference = appState.selectedInputSourceChoice
		let mapped = actionRouter.matchingActions(for: packet).filter { $0.canExecute(context: evalContext) }
		let orderedIds = decision.rankedActionIds
		let indexById = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($0.element, $0.offset) })
		let ordered = mapped.sorted { a, b in
			let ia = indexById[a.id] ?? Int.max
			let ib = indexById[b.id] ?? Int.max
			if ia != ib { return ia < ib }
			return a.id < b.id
		}

		let didHaveAnalyze = lastReasonedActions.contains(where: { $0.id == ScreenAnalyzeAction.analyzeScreenId })
		let hasAnalyzeNow = ordered.contains(where: { $0.id == ScreenAnalyzeAction.analyzeScreenId })
		if hasAnalyzeNow && !didHaveAnalyze {
			print("[AvailableActions] added analyze_screen from OCR")
		}

		var finalProposal: ActionProposal? = proposal
		var finalProposalKey: String? = proposalKey

		if ordered.isEmpty {
			finalProposal = nil
			finalProposalKey = nil
		} else if let p = finalProposal {
			let primaryInActions = ordered.contains(where: { $0.id == p.primaryActionId })
			if !primaryInActions {
				finalProposal = nil
				finalProposalKey = nil
			} else if appState.isSuggestionOnCooldown(p, context: context) {
				finalProposal = nil
				finalProposalKey = nil
			}
		}

		appState.availableActions = ordered
		appState.currentProposal = finalProposal
		appState.currentProposalKey = finalProposalKey
		lastReasonedActions = ordered
		lastReasonedActionsAt = Date()
		lastReasonedTriggerType = packet.triggerType
		lastReasonedProposal = finalProposal
		lastReasonedProposalKey = finalProposalKey
		print("[AvailableActions] cached actions count=\(ordered.count) trigger=\(packet.triggerType.rawValue)")

		if let p = finalProposal {
			maybeShowFloatingSuggestion(proposal: p, context: context)
		}
	}

	private func maybeShowFloatingSuggestion(proposal: ActionProposal, context _: ContextModel) {
		guard proposal.confidence >= floatingSuggestionMinConfidence else { return }
		guard menuBarController?.isPopoverShown != true else { return }
		if let existing = appState.floatingSuggestion, existing == proposal, appState.isFloatingSuggestionVisible {
			return
		}
		appState.showFloatingSuggestion(proposal)
	}

	private func preserveOrClearAvailableActions(reason: String) {
		if appState.isActionExecuting {
			print("[AvailableActions] preserving actions during execution")
			return
		}

		guard let cachedAt = lastReasonedActionsAt else {
			if !appState.availableActions.isEmpty {
				appState.availableActions = []
				appState.currentProposal = nil
				appState.currentProposalKey = nil
				print("[AvailableActions] cleared cached actions reason=\(reason)")
			}
			return
		}

		let age = Date().timeIntervalSince(cachedAt)
		if age < availableActionsCacheTTLSeconds, !lastReasonedActions.isEmpty {
			appState.availableActions = lastReasonedActions
			if let p = lastReasonedProposal,
			   lastReasonedActions.contains(where: { $0.id == p.primaryActionId }),
			   !appState.isSuggestionOnCooldown(p, context: appState.debugContext) {
				appState.currentProposal = p
				appState.currentProposalKey = lastReasonedProposalKey
			} else {
				appState.currentProposal = nil
				appState.currentProposalKey = nil
			}
			let now = Date()
			if lastPreserveLogAt == nil || now.timeIntervalSince(lastPreserveLogAt!) > 2 {
				lastPreserveLogAt = now
				let rounded = String(format: "%.1f", age)
				print("[AvailableActions] preserving cached actions age=\(rounded)s")
			}
			return
		}

		appState.availableActions = []
		appState.currentProposal = nil
		appState.currentProposalKey = nil
		lastReasonedActions = []
		lastReasonedActionsAt = nil
		lastReasonedTriggerType = nil
		lastReasonedProposal = nil
		lastReasonedProposalKey = nil
		print("[AvailableActions] cleared cached actions reason=\(reason)")
	}

	private func invokeStoredAction(actionId: String) {
		var execContext = contextBuilder.model
		execContext.actionInputSourcePreference = appState.selectedInputSourceChoice
		guard let action = appState.availableActions.first(where: { $0.id == actionId }) else { return }
		guard action.canExecute(context: execContext) else {
			print("[ActionResult] No valid actions")
			return
		}

		if appState.isActionExecuting {
			print("[ActionExecution] Ignored duplicate action while execution is in progress")
			return
		}

		let inputFingerprint = Self.stableInputFingerprint(for: execContext)
		let invocationKey = "\(actionId)|\(inputFingerprint)"
		if let finishedAt = lastFinishedAt,
		   lastFinishedActionKey == invocationKey,
		   Date().timeIntervalSince(finishedAt) < 2 {
			print("[ActionExecution] Ignored duplicate action invocation within cooldown")
			return
		}

		appState.isActionExecuting = true
		appState.executingActionId = actionId
		appState.executingActionTitle = action.name
		appState.latestActionResult = nil
		appState.latestActionId = actionId
		appState.latestActionTimestamp = Date()
		print("[AppState] executing action=\(actionId)")
		print("[ActionExecution] Starting action \(actionId)")
		Task { @MainActor in
			defer {
				appState.isActionExecuting = false
				appState.executingActionId = nil
				appState.executingActionTitle = nil
				print("[AppState] execution finished action=\(actionId)")
				self.lastFinishedActionKey = invocationKey
				self.lastFinishedAt = Date()
				print("[ActionExecution] Cleared in-flight state")
			}
			let outcome = await Self.runActionWithSecondsTimeout(seconds: 45) {
				await action.execute(context: execContext)
			}
			switch outcome {
			case .completed(let result):
				print("[ActionResult]", result.outputText)
				appState.latestActionResult = result.outputText
				appState.latestActionTimestamp = Date()
				print("[ActionExecution] Finished action \(actionId)")
			case .timedOut:
				print("[ActionExecution] Action timed out")
				print("[ActionExecution] Failed action \(actionId): timed out")
				appState.latestActionResult = "This action timed out. Try again with less text or check that local AI is responding."
				appState.latestActionTimestamp = Date()
			}
		}
	}

	private enum ActionTimedOutcome<T> {
		case completed(T)
		case timedOut
	}

	private static func runActionWithSecondsTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> ActionTimedOutcome<T> {
		await withTaskGroup(of: ActionTimedOutcome<T>.self) { group in
			group.addTask {
				let value = await operation()
				return .completed(value)
			}
			group.addTask {
				let nanos = UInt64(seconds * 1_000_000_000)
				try? await Task.sleep(nanoseconds: nanos)
				return .timedOut
			}
			let first = await group.next()!
			group.cancelAll()
			return first
		}
	}

	private static func stableInputFingerprint(for context: ContextModel) -> UInt64 {
		if let text = ActionInputCapture.primaryText(for: context, minimumLength: 30, preference: context.actionInputSourcePreference) {
			var hash: UInt64 = 14_695_981_039_346_656_037
			for byte in text.utf8 {
				hash ^= UInt64(byte)
				hash &*= 1_099_511_628_211
			}
			return hash
		}
		return UInt64(context.clipboardTextLength)
			^ (UInt64(context.selectedTextLength) &<< 32)
			^ (UInt64(context.screenOCRTextLength) &<< 48)
	}

	private func logContextModel(_ model: ContextModel) {
		let sig = [
			model.activeAppName ?? "nil",
			model.activeAppBundleIdentifier ?? "nil",
			model.activeWindowTitle ?? "nil",
			"c:\(model.clipboardTextAvailable):\(model.clipboardTextLength)",
			"s:\(model.selectedTextAvailable):\(model.selectedTextLength)",
			model.lastSourceTrigger?.rawValue ?? "nil"
		].joined(separator: "|")

		if sig == lastContextLogSignature { return }
		lastContextLogSignature = sig

		print(
			"[ContextModel]",
			"app=\(model.activeAppName ?? "nil")",
			"bundle=\(model.activeAppBundleIdentifier ?? "nil")",
			"windowTitle=\(model.activeWindowTitle != nil)",
			"clipboard=(available:\(model.clipboardTextAvailable) length:\(model.clipboardTextLength))",
			"selection=(available:\(model.selectedTextAvailable) length:\(model.selectedTextLength))",
			"lastTrigger=\(model.lastSourceTrigger?.rawValue ?? "nil")"
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
