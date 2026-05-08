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

	/// Dedupes identical `[TES]` suppression/allow logs during rapid context polling.
	private var lastTESLogSignature: String?
	private var lastTESLogAt: Date?

	private var lastProposalGateLogSignature: String?
	private var lastProposalGateLogAt: Date?
	private var lastActionRelevanceLogSignature: String?
	private var lastActionRelevanceLogAt: Date?
	private var lastProposalRankingLogSignature: String?
	private var lastProposalRankingLogAt: Date?
	private var lastSuggestionStrengthLogSignature: String?
	private var lastSuggestionStrengthLogAt: Date?

	/// Invalidates in-flight async `updateAvailableActions` when newer context arrives (T12.6).
	private var contextPipelineGeneration: UInt64 = 0
	private let intelligenceProposalSelector = IntelligenceProposalSelector()

	private var lastPipelineActiveAppKey: String?

	func applicationDidFinishLaunching(_ notification: Notification) {
		ModelManager.shared.noteAppLaunch()
		NSApp.setActivationPolicy(.accessory)

		// Self-test hook (no UI, no continuous polling).
		// Run the app with `CONTEXTUAL_RUN_AX_SELFTEST=1` to execute once and exit.
		let env = ProcessInfo.processInfo.environment
		if env["CONTEXTUAL_RUN_AX_SELFTEST"] == "1" {
			print("[AXContent] selftest starting")
			let ok = AXWindowContentSource.shared._selfTest()
			print("[AXContent] selftest finished ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
				NSApp.terminate(nil)
			}
		}

		// Typing activity DEBUG self-test (metadata-only; uses synthetic events to be non-interactive).
		// Run the app with `CONTEXTUAL_RUN_TYPING_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_TYPING_SELFTEST"] == "1" {
			print("[TypingActivity] selftest starting")
			let src = TypingActivitySource.shared
			src.reset()
			src.startMonitoring()

			func logSnapshot(_ label: String) {
				let ctx = src.currentContext()
				let s = String(format: "%.2f", ctx.estimatedEditingActivity)
				let idle = String(format: "%.1f", ctx.idleDuration)
				print("[TypingActivity] selftest \(label) state=\(ctx.typingState.rawValue) intensity=\(ctx.burstIntensity.rawValue) events=\(ctx.recentEventCount) active=\(ctx.isTypingActive) idle=\(idle)s activity=\(s)")
			}

			logSnapshot("initial")

			for _ in 0..<6 { src.recordSyntheticKeyEventForTesting() }
			logSnapshot("after_6")
			for _ in 0..<10 { src.recordSyntheticKeyEventForTesting() }
			logSnapshot("after_16")

			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
				logSnapshot("after_wait_1s")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
				logSnapshot("after_wait_3s")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
				logSnapshot("after_wait_6s")
				src.stopMonitoring()
				print("[TypingActivity] selftest finished")
				NSApp.terminate(nil)
			}
		}

		syncLocalAIFromStorage()
		wireLocalAIHandlers()
		menuBarController = MenuBarController(appState: appState)
		floatingSuggestionController = FloatingSuggestionWindowController(appState: appState)

		appState.onRevealAssistantPanel = { [weak self] in
			self?.menuBarController?.revealPopoverIfNeeded()
		}

		menuBarController?.onPopoverDidShow = { [weak self] in
			self?.appState.dismissFloatingSuggestion(reason: .panelOpen)
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
		if s.localAIEnabled {
			appState.modelRuntimeState = .checking
		}
	}

	private func wireLocalAIHandlers() {
		appState.onEnableLocalAI = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.localAIEnabled = true
			self.appState.localAIEnabled = true
			self.appState.modelRuntimeState = .checking
			self.scheduleLocalAIPrepare()
		}

		appState.onDisableLocalAI = { [weak self] in
			guard let self else { return }
			LocalAISettings.shared.localAIEnabled = false
			self.appState.localAIEnabled = false
			self.appState.modelRuntimeState = .unavailable
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
						uiState.modelRuntimeState = .unavailable
					}
					return
				}
				await ModelManager.shared.prepareLocalAIIfEnabled(
					settings: LocalAISettings.shared,
					allowModelPull: true,
					updateState: { runtimeState in
						DispatchQueue.main.async {
							uiState.modelRuntimeState = runtimeState
						}
					}
				)
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
						uiState.modelRuntimeState = .unavailable
					}
					return
				}
				await ModelManager.shared.prepareLocalAIIfEnabled(
					settings: LocalAISettings.shared,
					allowModelPull: true,
					updateState: { runtimeState in
						DispatchQueue.main.async {
							uiState.modelRuntimeState = runtimeState
						}
					}
				)
			}
		}

		appState.onOpenOllamaDownload = {
			if let url = URL(string: "https://ollama.com/download") {
				NSWorkspace.shared.open(url)
			}
		}

		appState.onPullLocalAIModel = { [weak self] in
			guard let self else { return }
			let uiState = self.appState
			Task.detached(priority: .utility) {
				await ModelManager.shared.pullConfiguredModel { runtimeState in
					DispatchQueue.main.async {
						uiState.modelRuntimeState = runtimeState
					}
				}
			}
		}
	}

	private func scheduleLocalAIPrepare() {
		let uiState = appState
		appState.modelRuntimeState = .checking
		Task.detached(priority: .utility) {
			let graceNanos = UInt64(4 * 1_000_000_000)
			try? await Task.sleep(nanoseconds: graceNanos)
			await ModelManager.shared.prepareLocalAIIfEnabled(
				settings: LocalAISettings.shared,
				allowModelPull: false,
				updateState: { runtimeState in
					DispatchQueue.main.async {
						uiState.modelRuntimeState = runtimeState
					}
				}
			)
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

		if case .sourceChanged(.selectedTextChanged(let text)) = event {
			let len = text?.count ?? 0
			if len > TriggerEngine.selectedTextMinCharacterCount {
				resetStaleInputSourceAfterNewSelection(context: contextBuilder.model)
			}
		}

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

	/// T12.10: After manual/OCR, user may leave “Screen text” selected — new real selection should resume automatic resolution.
	private func resetStaleInputSourceAfterNewSelection(context: ContextModel) {
		if appState.selectedInputSourceChoice == .screenOCR {
			appState.selectedInputSourceChoice = .automatic
			appState.floatingSuggestionLifecycle.clearAllForInputChannelReset()
			print("[InputSource] reset_stale_source reason=new_selection prev=screen_ocr")
		}
	}

	private func processUpdatedContextAfterPipeline() {
		appState.debugContext = contextBuilder.model
		logContextModel(contextBuilder.model)

		let context = contextBuilder.model
		let bid = context.activeAppBundleIdentifier ?? ""
		if !bid.isEmpty {
			if let prev = lastPipelineActiveAppKey, prev != bid {
				appState.redundancyMemory.pruneEntriesOlderThan(seconds: 12 * 60)
				print("[ContextPipeline] redundancy_prune reason=active_app_change")
			}
			lastPipelineActiveAppKey = bid
		}

		contextPipelineGeneration += 1
		let generation = contextPipelineGeneration
		if let packet = triggerEngine.evaluate(context) {
			logTriggerPacket(packet, context: context)
			Task { self.updateAvailableActions(from: packet, context: context, generation: generation) }
		} else {
			preserveOrClearAvailableActions(reason: "no trigger packet")
		}
	}

	private func updateAvailableActions(from packet: TriggerPacket, context: ContextModel, generation: UInt64) {
		let decision = ReasoningEngine.shared.evaluate(context: context, triggerPacket: packet)
		let primary = decision.primaryActionId ?? "none"
		print("[ReasoningEngine] decision surface=\(decision.shouldSurface) primary=\(primary) confidence=\(decision.confidence) reason=\(decision.reason)")

		guard decision.shouldSurface else {
			preserveOrClearAvailableActions(reason: "reasoning shouldSurface=false")
			return
		}

		let proposalGateResult = ProposalGenerationGate.evaluate(context: context)

		// Compute features + type once for relevance scoring (no AI, metadata only).
		let sourceText = ActionInputCapture.primaryText(for: context, minimumLength: 0, preference: .automatic) ?? ""
		let features = FeatureExtractor.extract(from: sourceText)
		let contextType = ContextClassifier.classify(features: features, text: sourceText)

		let relevanceBase = ActionRelevanceScorer.scoreActions(
			candidateActionIds: decision.rankedActionIds,
			contextType: contextType,
			features: features
		)

		// Apply session-only redundancy tuning (T11.7) using the existing privacy-safe lifecycle key.
		let rawSimilarity = FloatingSimilarityText.material(
			for: context,
			triggerType: packet.triggerType,
			inputPreference: appState.effectiveInputSource(for: context)
		)
		let profile = ContentSimilarityProfile.make(from: rawSimilarity)
		let relevance = relevanceBase.map { r -> ActionRelevanceScore in
			let key = appState.floatingSuggestionLifecycle.exactKey(
				triggerType: packet.triggerType,
				primaryActionId: r.actionId,
				profile: profile
			)
			let adj = appState.redundancyMemory.adjustment(for: key, actionId: r.actionId)
			let adjusted = min(1.0, max(0.0, r.score + adj.scoreDelta))
			let reason = adj.scoreDelta == 0 ? r.reason : "\(r.reason)+mem(\(adj.reason))"
			return ActionRelevanceScore(actionId: r.actionId, score: adjusted, reason: reason)
		}

		let rankedIds = relevance.map(\.actionId)
		logActionRelevanceIfNeeded(ranked: relevance, topId: rankedIds.first)

		guard let ranking = ProposalRanker.rank(relevance: relevance, reasoningPrimary: decision.primaryActionId) else {
			preserveOrClearAvailableActions(reason: "proposal ranking unavailable")
			return
		}
		logProposalRankingIfNeeded(ranking)

		if ranking.tieResolved {
			print("[ProposalRanking] tie resolved primary=\(ranking.primaryActionId)")
		}

		// If everything is weak, avoid creating a proposal (Available Actions still show).
		let shouldGenerateProposalByRelevance = ranking.topScore >= 0.50

		let overriddenDecision = ReasoningDecision(
			shouldSurface: decision.shouldSurface,
			primaryActionId: ranking.primaryActionId,
			rankedActionIds: rankedIds.isEmpty ? decision.rankedActionIds : rankedIds,
			reason: decision.reason,
			confidence: decision.confidence
		)

		var proposal: ActionProposal?
		var strength: SuggestionStrengthResult?
		if packet.triggerType == .manualInvocation {
			proposal = ProposalGenerator.shared.generate(
				context: context,
				triggerPacket: packet,
				decision: overriddenDecision,
				inputSourcePreference: appState.selectedInputSourceChoice
			)
		} else {
			logProposalGateIfNeeded(allowed: proposalGateResult.shouldGenerate, reason: proposalGateResult.reason)
			if proposalGateResult.shouldGenerate, shouldGenerateProposalByRelevance {
				proposal = ProposalGenerator.shared.generate(
					context: context,
					triggerPacket: packet,
					decision: overriddenDecision,
					inputSourcePreference: appState.selectedInputSourceChoice
				)
			}
		}

		if let p = proposal {
			let s = SuggestionStrengthEvaluator.evaluate(
				proposal: p,
				ranking: ranking,
				contextType: contextType,
				features: features
			)
			strength = s
			logSuggestionStrengthIfNeeded(s)
			if s.strength == .weak {
				proposal = nil
			}
		}

		var proposalKey: String?
		if let p = proposal {
			proposalKey = "\(packet.triggerType.rawValue)|\(p.primaryActionId)|\(Self.proposalContentStamp(profile))"
		}

		var evalContext = context
		evalContext.actionInputSourcePreference = appState.selectedInputSourceChoice
		let mapped = actionRouter.matchingActions(for: packet).filter { $0.canExecute(context: evalContext) }
		let orderedIds = overriddenDecision.rankedActionIds.isEmpty ? decision.rankedActionIds : overriddenDecision.rankedActionIds
		let indexById = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($0.element, $0.offset) })
		var ordered = mapped.sorted { a, b in
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

		if packet.triggerType != .manualInvocation, let key = finalProposalKey {
			if let dismissedAt = appState.lastDismissedProposalAt,
			   appState.lastDismissedProposalKey == key,
			   Date().timeIntervalSince(dismissedAt) < 120 {
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=dismissed")
				finalProposal = nil
				finalProposalKey = nil
			} else if let acceptedAt = appState.lastAcceptedProposalAt,
					  appState.lastAcceptedProposalKey == key,
					  Date().timeIntervalSince(acceptedAt) < 10 {
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=accepted")
				finalProposal = nil
				finalProposalKey = nil
			}
		}

		guard generation == contextPipelineGeneration else { return }

		publishReasonedActions(
			ordered: ordered,
			finalProposal: finalProposal,
			finalProposalKey: finalProposalKey,
			strength: strength,
			packet: packet,
			context: context,
			generation: generation,
			proposalGateAllows: proposalGateResult.shouldGenerate
		)

		// T12.6 / T12.6.5: async refinement (cache → micro → LLM) must not block heuristic publish above.
		if let fp = finalProposal,
		   let st = strength,
		   st.strength == .medium || st.strength == .strong,
		   proposalGateResult.shouldGenerate,
		   !ordered.isEmpty,
		   generation == contextPipelineGeneration
		{
			let llmIds = Self.llmCandidateActionIds(from: ordered)
			if !llmIds.isEmpty {
				let gen = generation
				let snapOrdered = ordered
				let snapProposalKey = finalProposalKey
				Task { @MainActor in
					await self.applyIntelligenceRefinement(
						generation: gen,
						packet: packet,
						context: context,
						sourceText: sourceText,
						contextType: contextType,
						features: features,
						strengthResult: st,
						overriddenDecision: overriddenDecision,
						proposalGateAllowed: proposalGateResult.shouldGenerate,
						orderedSnapshot: snapOrdered,
						heuristicProposal: fp,
						heuristicProposalKey: snapProposalKey,
						contentProfile: profile,
						llmIds: llmIds
					)
				}
			}
		}
	}

	private func publishReasonedActions(
		ordered: [any ActionProtocol],
		finalProposal: ActionProposal?,
		finalProposalKey: String?,
		strength: SuggestionStrengthResult?,
		packet: TriggerPacket,
		context: ContextModel,
		generation: UInt64,
		proposalGateAllows: Bool
	) {
		guard generation == contextPipelineGeneration else { return }

		appState.availableActions = ordered
		appState.currentProposal = finalProposal
		appState.currentProposalKey = finalProposalKey
		lastReasonedActions = ordered
		lastReasonedActionsAt = Date()
		lastReasonedTriggerType = packet.triggerType
		lastReasonedProposal = finalProposal
		lastReasonedProposalKey = finalProposalKey
		print("[AvailableActions] cached actions count=\(ordered.count) trigger=\(packet.triggerType.rawValue)")

		if let p = finalProposal, let s = strength, s.strength == .strong {
			maybeShowFloatingSuggestion(
				proposal: p,
				suggestionStrength: s.strength,
				context: context,
				packet: packet,
				proposalGateAllows: proposalGateAllows
			)
		}
	}

	private func applyIntelligenceRefinement(
		generation: UInt64,
		packet: TriggerPacket,
		context: ContextModel,
		sourceText: String,
		contextType: ContextType,
		features: ContextFeatures,
		strengthResult: SuggestionStrengthResult,
		overriddenDecision: ReasoningDecision,
		proposalGateAllowed: Bool,
		orderedSnapshot: [any ActionProtocol],
		heuristicProposal: ActionProposal,
		heuristicProposalKey: String?,
		contentProfile: ContentSimilarityProfile,
		llmIds: [String]
	) async {
		guard proposalGateAllowed else { return }
		guard generation == contextPipelineGeneration else {
			print("[IntelligenceSelection] stale_result_discarded")
			print("[IntelligenceFallback] reason=stale_context layer=selector")
			IntelligenceDebugLogger.log(
				stage: .selection,
				event: "stale_discarded",
				meta: IntelligenceDebugMeta(reason: "stale_context", layer: "selector")
			)
			return
		}

		let primaryBefore = heuristicProposal.primaryActionId
		let intel = await intelligenceProposalSelector.run(
			context: context,
			triggerPacket: packet,
			sourceText: sourceText,
			contextType: contextType,
			features: features,
			suggestionStrength: strengthResult.strength,
			candidateLLMActionIds: llmIds,
			heuristicPrimaryActionId: primaryBefore,
			inputPreference: appState.selectedInputSourceChoice,
			isActionExecuting: appState.isActionExecuting
		)

		guard generation == contextPipelineGeneration else {
			print("[IntelligenceSelection] stale_result_discarded")
			print("[IntelligenceFallback] reason=stale_context layer=selector")
			IntelligenceDebugLogger.log(
				stage: .selection,
				event: "stale_discarded",
				meta: IntelligenceDebugMeta(reason: "stale_context", layer: "selector")
			)
			return
		}

		if case .unchanged = intel.outcome, intel.intelligenceTitle == nil {
			return
		}

		var ordered = orderedSnapshot
		var finalProposal: ActionProposal? = heuristicProposal
		var finalProposalKey: String? = heuristicProposalKey

		switch intel.outcome {
		case .unchanged:
			if let t = intel.intelligenceTitle {
				finalProposal = ProposalGenerator.shared.generate(
					context: context,
					triggerPacket: packet,
					decision: overriddenDecision,
					inputSourcePreference: appState.selectedInputSourceChoice,
					intelligenceTitleOverride: t
				)
				if let p = finalProposal {
					finalProposalKey = "\(packet.triggerType.rawValue)|\(p.primaryActionId)|\(Self.proposalContentStamp(contentProfile))"
				} else {
					finalProposalKey = nil
				}
			}
		case .suppressProposal:
			finalProposal = nil
			finalProposalKey = nil
		case .overridePrimary(let newId):
			let fullRanked = Self.rankedIdsPlacingPrimary(newId, orderedIds: ordered.map(\.id), textPool: llmIds)
			let regenDecision = ReasoningDecision(
				shouldSurface: overriddenDecision.shouldSurface,
				primaryActionId: newId,
				rankedActionIds: fullRanked,
				reason: overriddenDecision.reason,
				confidence: overriddenDecision.confidence
			)
			finalProposal = ProposalGenerator.shared.generate(
				context: context,
				triggerPacket: packet,
				decision: regenDecision,
				inputSourcePreference: appState.selectedInputSourceChoice,
				intelligenceTitleOverride: intel.intelligenceTitle
			)
			if let p = finalProposal {
				finalProposalKey = "\(packet.triggerType.rawValue)|\(p.primaryActionId)|\(Self.proposalContentStamp(contentProfile))"
			} else {
				finalProposalKey = nil
			}
			ordered = Self.resortActions(ordered, rankedIds: fullRanked)
			print("[IntelligenceSelection] proposal overridden primary=\(newId)")
		}

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

		if packet.triggerType != .manualInvocation, let key = finalProposalKey {
			if let dismissedAt = appState.lastDismissedProposalAt,
			   appState.lastDismissedProposalKey == key,
			   Date().timeIntervalSince(dismissedAt) < 120 {
				finalProposal = nil
				finalProposalKey = nil
			} else if let acceptedAt = appState.lastAcceptedProposalAt,
					  appState.lastAcceptedProposalKey == key,
					  Date().timeIntervalSince(acceptedAt) < 10 {
				finalProposal = nil
				finalProposalKey = nil
			}
		}

		guard generation == contextPipelineGeneration else {
			print("[IntelligenceSelection] stale_result_discarded")
			print("[IntelligenceFallback] reason=stale_context layer=selector")
			IntelligenceDebugLogger.log(
				stage: .selection,
				event: "stale_discarded",
				meta: IntelligenceDebugMeta(reason: "stale_context", layer: "selector")
			)
			return
		}

		publishReasonedActions(
			ordered: ordered,
			finalProposal: finalProposal,
			finalProposalKey: finalProposalKey,
			strength: strengthResult,
			packet: packet,
			context: context,
			generation: generation,
			proposalGateAllows: proposalGateAllowed
		)
	}

	private static let intelligenceTextActionIds: Set<String> = ["summarize_text", "explain_text", "rewrite_text"]

	private static func llmCandidateActionIds(from ordered: [any ActionProtocol]) -> [String] {
		ordered.map(\.id).filter { intelligenceTextActionIds.contains($0) }
	}

	private static func resortActions(_ actions: [any ActionProtocol], rankedIds: [String]) -> [any ActionProtocol] {
		let indexById = Dictionary(uniqueKeysWithValues: rankedIds.enumerated().map { ($0.element, $0.offset) })
		return actions.sorted { a, b in
			let ia = indexById[a.id] ?? Int.max
			let ib = indexById[b.id] ?? Int.max
			if ia != ib { return ia < ib }
			return a.id < b.id
		}
	}

	private static func proposalContentStamp(_ profile: ContentSimilarityProfile) -> String {
		let ph = String(profile.prefixHash, radix: 16)
		let sh = String(profile.suffixHash, radix: 16)
		return "\(profile.lengthBucket)|\(ph)|\(sh)"
	}

	private static func rankedIdsPlacingPrimary(_ primary: String, orderedIds: [String], textPool: [String]) -> [String] {
		var reordered: [String] = []
		if textPool.contains(primary) {
			reordered.append(primary)
			reordered.append(contentsOf: textPool.filter { $0 != primary })
		} else {
			reordered.append(primary)
			reordered.append(contentsOf: textPool.filter { $0 != primary })
		}
		let extras = orderedIds.filter { !intelligenceTextActionIds.contains($0) }
		return reordered + extras
	}

	private func logProposalGateIfNeeded(allowed: Bool, reason: String) {
		let sig = "\(allowed)|\(reason)"
		let now = Date()
		if let prev = lastProposalGateLogSignature, prev == sig, let t = lastProposalGateLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastProposalGateLogSignature = sig
		lastProposalGateLogAt = now
		if allowed {
			print("[ProposalGate] allowed reason=\(reason)")
		} else {
			print("[ProposalGate] blocked reason=\(reason)")
		}
	}

	private func logActionRelevanceIfNeeded(ranked: [ActionRelevanceScore], topId: String?) {
		guard !ranked.isEmpty else { return }
		let parts = ranked.prefix(6).map { r in
			let s = String(format: "%.2f", r.score)
			return "\(r.actionId)=\(s)"
		}
		let top = topId ?? "none"
		let sig = parts.joined(separator: "|") + "|top=\(top)"
		let now = Date()
		if let prev = lastActionRelevanceLogSignature, prev == sig, let t = lastActionRelevanceLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastActionRelevanceLogSignature = sig
		lastActionRelevanceLogAt = now
		print("[ActionRelevance] ranked \(parts.joined(separator: " ")) top=\(top)")
	}

	private func logProposalRankingIfNeeded(_ ranking: RankedProposalDecision) {
		let top = String(format: "%.2f", ranking.topScore)
		let secondary = ranking.secondaryActionIds.prefix(4).joined(separator: ",")
		let sig = "\(ranking.primaryActionId)|\(secondary)|\(top)|\(ranking.reason)"
		let now = Date()
		if let prev = lastProposalRankingLogSignature, prev == sig, let t = lastProposalRankingLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastProposalRankingLogSignature = sig
		lastProposalRankingLogAt = now
		print("[ProposalRanking] primary=\(ranking.primaryActionId) secondary=[\(secondary)] topScore=\(top) reason=\(ranking.reason)")
	}

	private func logSuggestionStrengthIfNeeded(_ s: SuggestionStrengthResult) {
		let score = String(format: "%.2f", s.score)
		let sig = "\(s.strength.rawValue)|\(score)|\(s.reason)"
		let now = Date()
		if let prev = lastSuggestionStrengthLogSignature, prev == sig, let t = lastSuggestionStrengthLogAt, now.timeIntervalSince(t) < 2.0 {
			return
		}
		lastSuggestionStrengthLogSignature = sig
		lastSuggestionStrengthLogAt = now
		print("[SuggestionStrength] strength=\(s.strength.rawValue) score=\(score) reason=\(s.reason)")
	}

	private func maybeShowFloatingSuggestion(
		proposal: ActionProposal,
		suggestionStrength: SuggestionStrength,
		context: ContextModel,
		packet: TriggerPacket,
		proposalGateAllows: Bool
	) {
		let resolvedInput = appState.effectiveInputSource(for: context)
		let rawSimilarity = FloatingSimilarityText.material(
			for: context,
			triggerType: packet.triggerType,
			inputPreference: resolvedInput
		)
		let profile = ContentSimilarityProfile.make(from: rawSimilarity)
		let life = appState.floatingSuggestionLifecycle.shouldSuppressNewFloating(
			triggerType: packet.triggerType,
			primaryActionId: proposal.primaryActionId,
			profile: profile
		)
		if life.suppressed, let r = life.reason {
			appState.floatingSuggestionLifecycle.logSuppressedIfNeeded(state: r, safeKey: life.safeKey)
			return
		}

		let tes = TriggerEligibilityEvaluator.evaluate(
			proposal: proposal,
			suggestionStrength: suggestionStrength,
			context: context,
			triggerType: packet.triggerType,
			isPaused: appState.isPaused,
			isPopoverOpen: menuBarController?.isPopoverShown ?? false,
			isFloatingVisible: appState.isFloatingSuggestionVisible,
			isActionExecuting: appState.isActionExecuting,
			inputSourceChoice: resolvedInput,
			proposalGateAllows: proposalGateAllows
		)

		let scoreLabel = String(format: "%.2f", tes.score)
		let sig = "\(tes.shouldShow)|\(tes.reason)|\(scoreLabel)|\(packet.triggerType.rawValue)|\(proposal.primaryActionId)"
		let now = Date()
		let shouldLogTES: Bool
		if let prev = lastTESLogSignature, prev == sig, let t = lastTESLogAt, now.timeIntervalSince(t) < 2.5 {
			shouldLogTES = false
		} else {
			shouldLogTES = true
			lastTESLogSignature = sig
			lastTESLogAt = now
		}

		if tes.shouldShow {
			if shouldLogTES {
				print("[TES] allow reason=\(tes.reason) score=\(scoreLabel)")
			}
			if let existing = appState.floatingSuggestion, existing == proposal, appState.isFloatingSuggestionVisible {
				return
			}
			let exactKey = appState.floatingSuggestionLifecycle.exactKey(
				triggerType: packet.triggerType,
				primaryActionId: proposal.primaryActionId,
				profile: profile
			)
			let safeKey = appState.floatingSuggestionLifecycle.safeLogKey(
				triggerType: packet.triggerType,
				primaryActionId: proposal.primaryActionId,
				profile: profile
			)
			let bind = ActiveFloatingLifecycleBinding(
				exactKey: exactKey,
				safeKey: safeKey,
				profile: profile,
				primaryActionId: proposal.primaryActionId
			)
			appState.showFloatingSuggestion(proposal, lifecycle: bind)
		} else if shouldLogTES {
			print("[TES] suppressed reason=\(tes.reason) score=\(scoreLabel)")
		}
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
