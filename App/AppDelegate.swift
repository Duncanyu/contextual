import AppKit

extension Notification.Name {
	static let contextualManualTrigger = Notification.Name("com.contextual.manualTrigger")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	/// TEMPORARY: Set to `true` to run the task-inference bakeoff harness on launch and exit.
	/// Keep `false` for normal app usage.
	private static let runTaskInferenceBakeoffOnLaunch = false
	private let appState = AppState()
	private var menuBarController: MenuBarController?
	private var floatingSuggestionController: FloatingSuggestionWindowController?
	private var sourceManager: SourceManager?
	private let contextBuilder = ContextBuilder()
	private let triggerEngine = TriggerEngine()
	private let actionRouter = ActionRouter()
	private var manualTriggerObserver: NSObjectProtocol?
	private var canonicalContextObserver: NSObjectProtocol?

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
	private var proposalTimingDeferredWorkItem: DispatchWorkItem?
	private var lastProposalTimingSignature: String?
	private var lastProposalTimingLogAt: Date?

	/// Holds the active generated execution runtime so cancel can reach it (T18.4).
	private var activeGeneratedExecutionRuntime: GeneratedExecutionRuntime?

	/// T18.6A — Tracks the previous context fingerprint components so we can detect meaningful
	/// context changes (page nav, app switch, workflow change) and log them.
	private struct ChimeInContextSnapshot: Equatable {
		let bundle: String      // bundle ID or app name slug
		let titlePrefix: String // first 40 chars of window title
		let workflow: String    // WorkflowType rawValue
		let hasOCR: Bool
		let hasSelectedText: Bool
	}
	private var lastChimeInContext: ChimeInContextSnapshot?

	func applicationDidFinishLaunching(_ notification: Notification) {
		ModelManager.shared.noteAppLaunch()
		NSApp.setActivationPolicy(.accessory)

		let env = ProcessInfo.processInfo.environment
		if Self.runTaskInferenceBakeoffOnLaunch {
			Task {
				let ok = await TaskInferenceBakeoff.runTwoStageProductionSimulation()
				print("[TaskInferenceBakeoff] launch run ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}
		if runPhase13SelfTestsIfRequested(environment: env) {
			return
		}

		// Hook-Based Action Composition self-tests (T18.5; async; metadata-only).
		// Run with `CONTEXTUAL_RUN_HOOK_COMPOSITION_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_HOOK_COMPOSITION_SELFTEST"] == "1" {
			Task {
				let ok = await HookCompositionSelfTests.run()
				print("[HookCompositionSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Manual hook composition debug probe.
		// Run with `CONTEXTUAL_DEBUG_COMPOSE_ACTION="Compare products"` (or any goal string).
		// Prints [HookAudit], [HookDiscovery], [HookValidation], [GeneratedActionContract] logs and exits.
		if let debugGoal = env["CONTEXTUAL_DEBUG_COMPOSE_ACTION"], !debugGoal.isEmpty {
			Task {
				await HookCompositionSelfTests.runManualCompose(goal: debugGoal)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Router direct probe: tests both batch and streaming paths against qwen2.5:0.5b
		// using the exact production router prompt format and prints [RouterProbe] results, then exits.
		// Use to isolate whether latency is a cold-start, a streaming path bug, or Ollama config.
		//
		// Correct command (use debug binary, not /Applications):
		//   CONTEXTUAL_DEBUG_ROUTER_DIRECT_PROBE=1 \
		//     /path/to/DerivedData/.../Debug/Contextual.app/Contents/MacOS/Contextual
		//
		// Expected output (warm model):
		//   [RouterProbe] path=batch  success=yes total_ms=<400   raw="...json..."
		//   [RouterProbe] path=streaming success=yes total_ms=<250 raw="{...}"
		//   [RouterProbe] finished
		if env["CONTEXTUAL_DEBUG_ROUTER_DIRECT_PROBE"] == "1" {
			Task {
				// Use the exact production router prompt format (matches TwoStageRouterPromptBuilder output).
				// The previous "JSON only. {...}\n" format caused the model to describe the JSON
				// rather than reproduce it. The multi-line instruction format below works correctly.
				let probeRouterPrompt = """
JSON only. One object: {"decision":"enough_context","request":[],"reason":"brief","confidence":0.9}
request values: "ocr","visual_descriptor","ax_window_text". If decision=enough_context, request=[].
enough_context: app+title are clear, OR selected/ocr/visual/ax is present. need_more_context: browser/media/game with no text. Never request context already present.
ctx app=Probe title=router-direct-probe wf=unknown ocr=no visual=no ax=no sel=no clip=no
"""
				let model = "qwen2.5:0.5b"
				print("[RouterProbe] started model=\(model) prompt_bytes=\(probeRouterPrompt.utf8.count)")

				// Path A: batch (stream:false — verifies model loads, ignores streaming code path)
				print("[RouterProbe] path=batch starting")
				let batchStart = Date()
				do {
					let raw = try await LocalAIClient.shared.generate(
						prompt: probeRouterPrompt,
						model: model,
						numPredict: 48,
						temperature: 0.10,
						purpose: nil,
						schema: nil
					)
					let ms = Int(Date().timeIntervalSince(batchStart) * 1000)
					let preview = String(raw.prefix(200)).replacingOccurrences(of: "\n", with: "↵")
					print("[RouterProbe] path=batch success=yes total_ms=\(ms) raw=\"\(preview)\"")
				} catch {
					let ms = Int(Date().timeIntervalSince(batchStart) * 1000)
					print("[RouterProbe] path=batch success=no total_ms=\(ms) error=\(error)")
				}

				// Path B: streaming (current production router path — emits [TwoStageRouterTiming] logs)
				print("[RouterProbe] path=streaming starting")
				let streamStart = Date()
				do {
					let raw = try await LocalAIClient.shared.generateStreamingJSON(
						prompt: probeRouterPrompt,
						model: model,
						numPredict: 48,
						temperature: 0.10,
						purpose: "task_inference_router",
						schema: nil
					)
					let ms = Int(Date().timeIntervalSince(streamStart) * 1000)
					let preview = String(raw.prefix(200)).replacingOccurrences(of: "\n", with: "↵")
					print("[RouterProbe] path=streaming success=yes total_ms=\(ms) raw=\"\(preview)\"")
				} catch {
					let ms = Int(Date().timeIntervalSince(streamStart) * 1000)
					print("[RouterProbe] path=streaming success=no total_ms=\(ms) error=\(error)")
				}

				print("[RouterProbe] finished")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return
		}

		// Phase 14: lightweight activity monitoring for proposal timing (metadata-only).
		TypingActivitySource.shared.startMonitoring()
		PointerActivitySource.shared.startMonitoring()

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
			Task { @MainActor in
				self?.dispatchManualTriggerEvent()
				self?.menuBarController?.revealPopoverIfNeeded()
			}
		}

		appState.onInvokeActionById = { [weak self] actionId in
			self?.invokeStoredAction(actionId: actionId)
		}

		appState.onInvokeGeneratedExecutionProposalById = { [weak self] candidateId in
			self?.invokeGeneratedExecutionProposal(candidateId: candidateId)
		}

		// T18.4: cancel wiring — routes UI cancel tap to actor-isolated runtime.
		appState.onCancelGeneratedExecution = { [weak self] in
			Task {
				await self?.activeGeneratedExecutionRuntime?.cancel()
			}
		}

		manualTriggerObserver = NotificationCenter.default.addObserver(
			forName: .contextualManualTrigger,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.dispatchManualTriggerEvent()
				self?.menuBarController?.revealPopoverIfNeeded()
			}
		}

		canonicalContextObserver = NotificationCenter.default.addObserver(
			forName: .contextualCanonicalContextUpdated,
			object: nil,
			queue: .main
		) { [weak self] _ in
			self?.appState.refreshContextAwarenessSummary()
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

		// T18.3.6: Seed built-in generated action templates and drain the prewarm queue.
		// Must run after manager/library init so the shared store is ready.
		// No LLM is called. This is fast and idempotent.
		Task {
			let manager = GeneratedActionPersistenceManager.shared
			let seeder = GeneratedActionTemplateSeeder.shared
			await seeder.seedIfNeeded(into: manager)
			await GeneratedActionTemplatePrewarmConsumer.shared.consume(
				from: GeneratedActionTemplatePrewarmQueue.shared,
				seeder: seeder,
				manager: manager
			)
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		if let manualTriggerObserver {
			NotificationCenter.default.removeObserver(manualTriggerObserver)
		}
		if let canonicalContextObserver {
			NotificationCenter.default.removeObserver(canonicalContextObserver)
		}
		sourceManager?.stop()
	}

	private func syncLocalAIFromStorage() {
		let s = LocalAISettings.shared
		appState.localAIEnabled = s.localAIEnabled
		appState.autoStartOllama = s.autoStartOllama
		appState.twoStageTaskInferenceEnabled = s.twoStageTaskInferenceEnabled
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
			Task.detached(priority: .utility) {
				await ModelAuditManager.shared.stopPeriodicKeepalive()
			}
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
						// After model becomes ready: refresh persisted model status immediately,
						// then run audit and warmup in background.
						if case .ready = runtimeState {
							Task { await uiState.refreshModelStatus() }
							Task.detached(priority: .utility) {
								let base = LocalAISettings.shared.modelName
								// Run parser + composer self-test on startup (no live AI — fast).
								let selfTestOk = await TaskInferenceSelfTest.run()
								if !selfTestOk {
									print("[TaskInferenceSelfTest] WARNING startup self-test failed — parser may reject model output")
								}
								if LocalAISettings.shared.twoStageTaskInferenceEnabled {
									print("[TwoStageInference] bypassing old single-stage audit, warmup, and keepalive because two-stage mode is ON")
									// Warm up router and planner models for two-stage inference.
									// Cold-start for qwen2.5:0.5b is ~8-10s (GGUF load from disk).
									// A startup warmup ensures the first router call responds in ~100ms.
									// Sequential to respect OLLAMA_NUM_PARALLEL=1 — router first.
									let routerModel = "qwen2.5:0.5b"
									let plannerModel = "qwen2.5:1.5b"
									print("[TwoStageWarmup] warming router=\(routerModel)")
									await ModelAuditManager.shared.runWarmupIfNeeded(model: routerModel)
									print("[TwoStageWarmup] warming planner=\(plannerModel)")
									await ModelAuditManager.shared.runWarmupIfNeeded(model: plannerModel)
									// Keep the router resident with a 4-minute keepalive ping loop.
									// Ollama's default idle unload TTL is 5 minutes; this prevents cold
									// re-loads during sustained dogfooding sessions.
									await ModelAuditManager.shared.startPeriodicKeepalive(model: routerModel)
									return
								}
								// Run model audit (discover + benchmark candidates).
								await ModelAuditManager.shared.runAuditIfNeeded(baseModel: base)
								await uiState.refreshModelAuditInfo()
								// Speculative warmup after audit selects the best model.
								let chosen = await ModelAuditManager.shared.selectedModel() ?? base
								await ModelAuditManager.shared.runWarmupIfNeeded(model: chosen)
								// Start keepalive loop to prevent Ollama from unloading the
								// model between inference bursts (default Ollama idle TTL = 5 min).
								await ModelAuditManager.shared.startPeriodicKeepalive(model: chosen)
							}
						}
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

		print("[ManualInvocation] screen_capture_skipped reason=normal_manual")
		print("[ScreenCapture] skipped reason=not_explicit_analyze_screen")
		sourceManager?.refreshSelectionNow()
		processSourceEvent(.sourceChanged(.manualTriggerRequested))
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
		appState.refreshContextAwarenessSummary()
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

		// T15.1: lightweight workflow inference (metadata-only, in-memory).
		WorkflowInferenceEngine.shared.recordAppBundle(bid.isEmpty ? nil : bid)
		WorkflowInferenceEngine.shared.evaluate(referenceTime: Date())

		// T15.2: session continuity (metadata-only, bounded, decaying).
		ContextualSessionTracker.shared.recordSample(
			inference: WorkflowInferenceEngine.shared.latestResult(),
			fused: CanonicalContextState.shared.current(),
			activeBundle: bid.isEmpty ? nil : bid,
			referenceTime: Date()
		)

		contextPipelineGeneration += 1
		let generation = contextPipelineGeneration
		let triggerPacket = triggerEngine.evaluate(context)

		// T15.3: structured intent concepts (non-executable, bounded, metadata-only).
		let synthesisText = ActionInputCapture.primaryText(for: context, minimumLength: 0, preference: .automatic) ?? ""
		let synthesisFeatures = FeatureExtractor.extract(from: synthesisText)
		var synthesisCandidateIds = triggerPacket?.candidateActions ?? []
		if synthesisCandidateIds.isEmpty, !appState.availableActions.isEmpty {
			synthesisCandidateIds = appState.availableActions.map { $0.id }
		}
		let intentRequest = IntentSynthesisRequest(
			workflowInference: WorkflowInferenceEngine.shared.latestResult(),
			sessionState: ContextualSessionTracker.shared.currentState(),
			fused: CanonicalContextState.shared.current(),
			features: synthesisFeatures,
			candidateActionIds: synthesisCandidateIds,
			triggerType: triggerPacket?.triggerType,
			lastSourceTrigger: context.lastSourceTrigger?.rawValue
		)
		IntentSynthesisEngine.shared.record(intentRequest, referenceTime: Date())

		if let packet = triggerPacket {
			logTriggerPacket(packet, context: context)
			Task { await self.updateAvailableActions(from: packet, context: context, generation: generation) }
		} else {
			if DynamicOnlyProposalMode.isEnabled {
				GeneratedProposalActivationDiagnostics.logSkip(
					phase: "skipped_before_situational_synthesis",
					detail: "no_trigger_packet last=\(context.lastSourceTrigger?.rawValue ?? "none")"
				)
			}
			preserveOrClearAvailableActions(reason: "no trigger packet")
		}
	}

	private func updateAvailableActions(from packet: TriggerPacket, context: ContextModel, generation: UInt64) async {
		let decision = ReasoningEngine.shared.evaluate(context: context, triggerPacket: packet)
		let primary = decision.primaryActionId ?? "none"
		print("[ReasoningEngine] decision surface=\(decision.shouldSurface) primary=\(primary) confidence=\(decision.confidence) reason=\(decision.reason)")

		guard decision.shouldSurface else {
			GeneratedProposalActivationDiagnostics.logSkip(
				phase: "skipped_before_situational_synthesis",
				detail: "reasoning_shouldSurface=false trigger=\(packet.triggerType.rawValue)"
			)
			preserveOrClearAvailableActions(reason: "reasoning shouldSurface=false")
			return
		}

		if DynamicOnlyProposalMode.isEnabled {
			await updateDynamicOnlyProposals(
				from: packet,
				context: context,
				generation: generation,
				decision: decision
			)
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

		let typingCtx = TypingActivitySource.shared.currentContext()
		let pointerCtx = PointerActivitySource.shared.currentContext()

		// Phase 14.4: rich context proposal selection (metadata-only; uses canonical fused context if present).
		let richAdj = RichContextProposalAdjuster.adjust(
			relevance: relevance,
			context: context,
			fused: CanonicalContextState.shared.current(),
			contextType: contextType,
			features: features,
			isManualInvocation: packet.triggerType == .manualInvocation
		)
		let richRelevance = richAdj.adjustedScores
		if richAdj.reasonCodes.contains("no_rich_context") {
			print("[RichProposal] kept reason=no_rich_context")
		} else if richAdj.reasonCodes.contains("rich_context_ignored_stale") {
			print("[RichProposal] ignored reason=rich_context_ignored_stale")
		} else if richAdj.shouldSuppressAutomaticProposal {
			print("[RichProposal] suppressed reason=form_context_suppress")
		} else if let r = richAdj.reasonCodes.first, r != "no_rich_adjustment" {
			print("[RichProposal] adjusted reason=\(r) primary=\(richAdj.adjustedPrimaryActionId ?? ranking.primaryActionId)")
		}

		let workflowRank = WorkflowAwareProposalRanker.adjust(
			baseRelevance: richRelevance,
			packet: packet,
			context: context,
			contextType: contextType,
			features: features,
			profile: profile,
			redundancyMemory: appState.redundancyMemory,
			lifecycle: appState.floatingSuggestionLifecycle,
			typing: typingCtx,
			pointer: pointerCtx,
			reasoningPrimary: decision.primaryActionId
		)

		guard let richRanking = ProposalRanker.rank(relevance: workflowRank.adjustedScores, reasoningPrimary: decision.primaryActionId) else {
			preserveOrClearAvailableActions(reason: "proposal ranking unavailable after rich adjust")
			return
		}

		// Phase 14: activity-aware proposal timing gate (Triggers layer; metadata-only).
		let canonical = CanonicalContextState.shared.current()
		let timing = ProposalTimingGate.evaluate(
			isManualInvocation: packet.triggerType == .manualInvocation,
			isActionExecuting: appState.isActionExecuting,
			hasStrongSelectedText: context.selectedTextAvailable && context.selectedTextLength >= TriggerEngine.selectedTextMinCharacterCount,
			isSelectedTextPrimary: packet.triggerType == .selectedTextEligible,
			canonicalFreshness: canonical?.freshnessScore,
			canonicalConfidence: canonical?.confidence,
			typing: typingCtx,
			pointer: pointerCtx,
			proposalStrengthHint: max(decision.confidence, richRanking.topScore)
		)
		logProposalTimingIfNeeded(decision: timing, typing: typingCtx, pointer: pointerCtx)

		// If everything is weak, avoid creating a proposal (Available Actions still show).
		let shouldGenerateProposalByRelevance = richRanking.topScore >= 0.50

		let proposalPromo = WorkflowAwareProposalRanker.proposalProminenceConfidenceDelta(
			primaryActionId: richRanking.primaryActionId,
			interruption01: workflowRank.interruptionCost
		)
		let proposalConfidence = min(0.95, decision.confidence + proposalPromo)

		let overriddenDecision = ReasoningDecision(
			shouldSurface: decision.shouldSurface,
			primaryActionId: richRanking.primaryActionId,
			rankedActionIds: rankedIds.isEmpty ? decision.rankedActionIds : [richRanking.primaryActionId] + richRanking.secondaryActionIds,
			reason: decision.reason,
			confidence: proposalConfidence
		)

		var proposal: ActionProposal?
		var strength: SuggestionStrengthResult?
		if (timing.outcome == .suppress || richAdj.shouldSuppressAutomaticProposal), packet.triggerType != .manualInvocation {
			proposal = nil
		} else if timing.outcome == .deferred, packet.triggerType != .manualInvocation {
			proposal = nil
			scheduleDeferredProposalRefreshIfNeeded(
				retryAfter: timing.suggestedRetryAfter ?? 1.2,
				originalGeneration: generation
			)
		} else if packet.triggerType == .manualInvocation {
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

		// Phase 14.5: context-aware action eligibility (metadata-only; no new collection).
		let eligibility = ContextAwareActionEligibility.evaluate(
			currentCandidateActionIds: ordered.map(\.id),
			triggerType: packet.triggerType,
			context: context,
			contextType: contextType,
			features: features,
			fused: CanonicalContextState.shared.current()
		)
		if eligibility.reasonCodes.contains("no_rich_context") {
			print("[ActionEligibility] kept reason=no_rich_context")
		} else if eligibility.reasonCodes.contains("rich_context_ignored_stale") {
			print("[ActionEligibility] ignored reason=rich_context_ignored_stale")
		} else if eligibility.reasonCodes.contains("form_actions_limited") {
			print("[ActionEligibility] limited reason=form_actions_limited")
		} else if let r = eligibility.reasonCodes.first, r != "no_rich_adjustment" {
			let actionsLabel = eligibility.eligibleActionIds.joined(separator: ",")
			print("[ActionEligibility] adjusted reason=\(r) actions=\(actionsLabel)")
		}

		let eligibleSet = Set(eligibility.eligibleActionIds)
		ordered = ordered.filter { eligibleSet.contains($0.id) }
		let indexByEligible = Dictionary(uniqueKeysWithValues: eligibility.eligibleActionIds.enumerated().map { ($0.element, $0.offset) })
		ordered.sort { a, b in
			let ia = indexByEligible[a.id] ?? Int.max
			let ib = indexByEligible[b.id] ?? Int.max
			if ia != ib { return ia < ib }
			return a.id < b.id
		}

		let didHaveAnalyze = lastReasonedActions.contains(where: { $0.id == ScreenAnalyzeAction.analyzeScreenId })
		let hasAnalyzeNow = ordered.contains(where: { $0.id == ScreenAnalyzeAction.analyzeScreenId })
		if hasAnalyzeNow && !didHaveAnalyze {
			if packet.triggerType == .manualInvocation, context.lastSourceTrigger == .manualTriggerRequested {
				print("[AvailableActions] added analyze_screen reason=manual_affordance")
			} else {
				print("[AvailableActions] added analyze_screen from OCR")
			}
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

		let proposalSnapshot = buildCanonicalSnapshotForProposalActivation(
			context: context,
			fused: canonical
		)
		// Feed latest snapshot to hook sandbox (debug only — no production side-effects).
		appState.updateLatestCanonicalSnapshot(proposalSnapshot)
		let activationHistory = GeneratedExecutionProposalActivationHistory.fromAppState(
			lastDismissedProposalActionId: appState.lastDismissedProposalActionId,
			lastDismissedProposalAt: appState.lastDismissedProposalAt
		)
		let proposalHistory = ProposalHistoryMetadata.fromActivationHistory(activationHistory)

		let llmResult = await DynamicGeneratedProposalEngine.shared.generateProposals(
			snapshot: proposalSnapshot,
			existingStaticActions: ordered.map(\.id),
			reusableActions: [],
			budget: .conservative,
			history: proposalHistory
		)
		// T18.3.6B: Explicit pipeline trace — log engine result and library record count before activator.
		print("[ProposalPipeline] engine_result status=\(llmResult.status.rawValue) library_records=\(llmResult.libraryRecords.count) should_chime=\(llmResult.shouldChimeIn) reason=\(llmResult.reason)")
		if !llmResult.libraryRecords.isEmpty {
			let titles = llmResult.libraryRecords.prefix(3).map(\.title).joined(separator: "|")
			print("[ProposalPipeline] library_records_detail count=\(llmResult.libraryRecords.count) top_titles=\(titles)")
		}
		// T18.3.10B: Preserve effective workflow through activation/ranking.
		do {
			let wfEngine = WorkflowInferenceEngine.shared.latestResult()
			let mappedEngine = wfEngine.map { WorkflowExecutionMapper.workflowType(from: $0.workflow) } ?? .unknown
			let engineConf = wfEngine?.confidence ?? 0
			let snapMapped = WorkflowExecutionMapper.workflowType(from: proposalSnapshot.inferredWorkflow)
			let snapConf = proposalSnapshot.workflowConfidence
			let libBest = llmResult.libraryRecords
				.filter { $0.workflowType != .unknown }
				.max(by: { $0.usefulnessScore < $1.usefulnessScore })
			let (effective, source): (WorkflowType, String) = {
				if mappedEngine != .unknown, engineConf >= 0.35 { return (mappedEngine, "workflow_engine") }
				if snapMapped != .unknown, snapConf >= 0.35 { return (snapMapped, "canonical") }
				if let libBest { return (libBest.workflowType, "template_library") }
				return (.unknown, "fallback")
			}()
			print("[ProposalPipeline] effective_workflow=\(effective.rawValue) source=\(source)")
		}

		let llmCandidates = DynamicGeneratedProposalCandidateMapper.candidates(
			from: llmResult,
			snapshot: proposalSnapshot,
			budget: .conservative
		)
		// Cache executable generated execution actions for user-click execution (non-reusable).
		appState.cacheGeneratedExecutionCandidateActions(llmCandidates)

		let reusableCandidatesForLog = GeneratedExecutionProposalCandidateBuilder.buildReusable(
			from: llmResult.libraryRecords,
			referenceTime: Date()
		)
		print("[ProposalPipeline] candidates_pre_activation llm=\(llmCandidates.count) reusable=\(reusableCandidatesForLog.count) total=\(llmCandidates.count + reusableCandidatesForLog.count)")
		if reusableCandidatesForLog.isEmpty && !llmResult.libraryRecords.isEmpty {
			print("[ProposalPipeline] WARNING reusable_candidates_empty despite library_records=\(llmResult.libraryRecords.count) — check eligibility/expiry filters in buildReusable")
		}

		let activation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: ordered.map(\.id),
				staticRelevanceScores: workflowRank.adjustedScores,
				generatedActions: [],
				generatedExecutionCandidates: llmCandidates,
				reusableRecords: llmResult.libraryRecords,
				snapshot: proposalSnapshot,
				history: activationHistory,
				workflow: WorkflowInferenceEngine.shared.latestResult(),
				session: ContextualSessionTracker.shared.currentState(),
				isManualInvocation: packet.triggerType == .manualInvocation,
				isActionExecuting: appState.isActionExecuting,
				useLLMGeneratedCandidatesOnly: true
			)
		)
		// T18.3.6B: Explicit activation trace.
		print("[ProposalPipeline] activation_result visible_generated=\(activation.visibleProposals.count) suppressed_generated=\(activation.suppressedGeneratedCount) timing=\(activation.timingDecision.outcome.rawValue) allows_panel=\(activation.timingDecision.allowsPanelGenerated)")

		let visibleStaticSet = Set(activation.visibleStaticActionIds)
		var panelStaticActions = ordered.filter { visibleStaticSet.contains($0.id) }
		if panelStaticActions.isEmpty {
			panelStaticActions = ordered
		}

		var publishedProposal = finalProposal
		var publishedProposalKey = finalProposalKey
		if publishedProposal == nil,
		   activation.timingDecision.allowsFloatingGenerated,
		   let floatingId = activation.floatingGeneratedProposalId,
		   let topGenerated = activation.visibleProposals.first
		{
			let question = topGenerated.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
			let headline: String
			if question.hasSuffix("?"), question.count <= 110 {
				headline = question
			} else {
				headline = "Try: \(topGenerated.title)?"
			}
			publishedProposal = ActionProposal(
				title: headline,
				sourceCaption: "Generated proposal",
				primaryActionId: floatingId,
				secondaryActionIds: [],
				confidence: topGenerated.confidence,
				reason: "generated_execution_proposal"
			)
			publishedProposalKey = "\(packet.triggerType.rawValue)|\(floatingId)|generated"
		}

		// T18.5: Apply chime-in policy before publishing (static-path).
		let chimeFilteredActivationStatic = applyChimeInPolicy(to: activation, packet: packet, snapshot: proposalSnapshot)
		if !chimeFilteredActivationStatic.timingDecision.allowsFloatingGenerated,
		   publishedProposal?.reason == "generated_execution_proposal"
		{
			publishedProposal = nil
			publishedProposalKey = nil
		}

		publishReasonedActions(
			ordered: panelStaticActions,
			finalProposal: publishedProposal,
			finalProposalKey: publishedProposalKey,
			strength: strength,
			packet: packet,
			context: context,
			generation: generation,
			proposalGateAllows: proposalGateResult.shouldGenerate,
			generatedProposalActivation: chimeFilteredActivationStatic
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
			// T18.3.5A: DynamicOnlyProposalMode replaces the Phase-12 IntelligenceProposalSelector
			// pipeline entirely. When enabled, skip applyIntelligenceRefinement — the new
			// DynamicGeneratedProposalEngine (decision → template library) handles all LLM work.
			if !llmIds.isEmpty && !DynamicOnlyProposalMode.isEnabled {
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

	private func buildCanonicalSnapshotForProposalActivation(
		context: ContextModel,
		fused: FusedContextPacket?
	) -> CanonicalGeneratedExecutionContextSnapshot {
		let selectedText = ActionInputCapture.primaryText(
			for: context,
			minimumLength: 0,
			preference: .selectedText
		)
		var clipboardText = ActionInputCapture.primaryText(
			for: context,
			minimumLength: 0,
			preference: .clipboard
		)
		var snapshot = CanonicalGeneratedExecutionContextSnapshotExporter.export(
			model: context,
			fused: fused,
			selectedText: selectedText,
			clipboardText: clipboardText,
			workflow: WorkflowInferenceEngine.shared.latestResult(),
			intent: IntentSynthesisEngine.shared.latestResult(),
			session: ContextualSessionTracker.shared.currentState(),
			permissionAvailability: [
				.screenRecording: WindowSnapshotSource.shared.hasScreenRecordingPermission(),
				.clipboard: true,
				.accessibility: true,
			]
		)
		let suppression = GeneratedExecutionClipboardFreshnessPolicy.evaluate(snapshot: snapshot)
		if !suppression.includeClipboard {
			clipboardText = nil
			snapshot = CanonicalGeneratedExecutionContextSnapshotExporter.export(
				model: context,
				fused: fused,
				selectedText: selectedText,
				clipboardText: nil,
				workflow: WorkflowInferenceEngine.shared.latestResult(),
				intent: IntentSynthesisEngine.shared.latestResult(),
				session: ContextualSessionTracker.shared.currentState(),
				permissionAvailability: [
					.screenRecording: WindowSnapshotSource.shared.hasScreenRecordingPermission(),
					.clipboard: true,
					.accessibility: true,
				]
			)
		}
		return snapshot
	}

	/// T18.3.2 — generated proposals only; no static summarize/explain/rewrite fallbacks.
	private func updateDynamicOnlyProposals(
		from packet: TriggerPacket,
		context: ContextModel,
		generation: UInt64,
		decision: ReasoningDecision
	) async {
		guard generation == contextPipelineGeneration else {
			GeneratedProposalActivationDiagnostics.logSkip(
				phase: "skipped_before_situational_synthesis",
				detail: "stale_generation"
			)
			return
		}

		let canonical = CanonicalContextState.shared.current()
		let proposalSnapshot = buildCanonicalSnapshotForProposalActivation(
			context: context,
			fused: canonical
		)
		// Feed latest snapshot to hook sandbox (debug only — no production side-effects).
		appState.updateLatestCanonicalSnapshot(proposalSnapshot)

		GeneratedProposalActivationDiagnostics.logAttemptStarted(
			triggerType: packet.triggerType.rawValue,
			fusedPacket: canonical != nil
		)

		let prepared = GeneratedProposalActivationBoundary.prepare(snapshot: proposalSnapshot)

		let activationHistory = GeneratedExecutionProposalActivationHistory.fromAppState(
			lastDismissedProposalActionId: appState.lastDismissedProposalActionId,
			lastDismissedProposalAt: appState.lastDismissedProposalAt
		)
		let proposalHistory = ProposalHistoryMetadata.fromActivationHistory(activationHistory)

		let llmResult = await DynamicGeneratedProposalEngine.shared.generateProposals(
			snapshot: prepared.snapshot,
			existingStaticActions: [],
			reusableActions: [],
			budget: .conservative,
			history: proposalHistory,
			situational: prepared.situational
		)
		// T18.3.6B: Explicit pipeline trace — log engine result and library record count before activator.
		print("[ProposalPipeline] engine_result status=\(llmResult.status.rawValue) library_records=\(llmResult.libraryRecords.count) should_chime=\(llmResult.shouldChimeIn) reason=\(llmResult.reason)")
		if !llmResult.libraryRecords.isEmpty {
			let titles = llmResult.libraryRecords.prefix(3).map(\.title).joined(separator: "|")
			print("[ProposalPipeline] library_records_detail count=\(llmResult.libraryRecords.count) top_titles=\(titles)")
		}
		// T18.3.10B: Preserve effective workflow through activation/ranking.
		do {
			let situationalMapped = WorkflowExecutionMapper.workflowType(from: prepared.situational.inferredWorkflow)
			let situationalConf = prepared.situational.workflowConfidence
			let wfEngine = WorkflowInferenceEngine.shared.latestResult()
			let mappedEngine = wfEngine.map { WorkflowExecutionMapper.workflowType(from: $0.workflow) } ?? .unknown
			let engineConf = wfEngine?.confidence ?? 0
			let snapMapped = WorkflowExecutionMapper.workflowType(from: prepared.snapshot.inferredWorkflow)
			let snapConf = prepared.snapshot.workflowConfidence
			let libBest = llmResult.libraryRecords
				.filter { $0.workflowType != .unknown }
				.max(by: { $0.usefulnessScore < $1.usefulnessScore })
			let (effective, source): (WorkflowType, String) = {
				if situationalMapped != .unknown, situationalConf >= 0.35 { return (situationalMapped, "situational") }
				if mappedEngine != .unknown, engineConf >= 0.35 { return (mappedEngine, "workflow_engine") }
				if snapMapped != .unknown, snapConf >= 0.35 { return (snapMapped, "canonical") }
				if let libBest { return (libBest.workflowType, "template_library") }
				return (.unknown, "fallback")
			}()
			print("[ProposalPipeline] effective_workflow=\(effective.rawValue) source=\(source)")
		}

		let llmCandidates = DynamicGeneratedProposalCandidateMapper.candidates(
			from: llmResult,
			snapshot: prepared.snapshot,
			budget: .conservative
		)
		// Cache executable generated execution actions for user-click execution (non-reusable).
		appState.cacheGeneratedExecutionCandidateActions(llmCandidates)

		let reusableCandidatesForLog2 = GeneratedExecutionProposalCandidateBuilder.buildReusable(
			from: llmResult.libraryRecords,
			referenceTime: Date()
		)
		print("[ProposalPipeline] candidates_pre_activation llm=\(llmCandidates.count) reusable=\(reusableCandidatesForLog2.count) total=\(llmCandidates.count + reusableCandidatesForLog2.count)")
		if reusableCandidatesForLog2.isEmpty && !llmResult.libraryRecords.isEmpty {
			print("[ProposalPipeline] WARNING reusable_candidates_empty despite library_records=\(llmResult.libraryRecords.count) — check eligibility/expiry filters in buildReusable")
		}

		let activation = GeneratedExecutionProposalActivator.activateProposals(
			input: GeneratedExecutionProposalActivationInput(
				staticActionIds: [],
				staticRelevanceScores: [],
				generatedActions: [],
				generatedExecutionCandidates: llmCandidates,
				reusableRecords: llmResult.libraryRecords,
				snapshot: prepared.snapshot,
				history: activationHistory,
				workflow: WorkflowInferenceEngine.shared.latestResult(),
				session: ContextualSessionTracker.shared.currentState(),
				isManualInvocation: packet.triggerType == .manualInvocation,
				isActionExecuting: appState.isActionExecuting,
				useLLMGeneratedCandidatesOnly: true,
				suppressStaticProposalFallback: true
			)
		)
		// T18.3.6B: Explicit activation trace.
		print("[ProposalPipeline] activation_result visible_generated=\(activation.visibleProposals.count) suppressed_generated=\(activation.suppressedGeneratedCount) timing=\(activation.timingDecision.outcome.rawValue) allows_panel=\(activation.timingDecision.allowsPanelGenerated)")

		let debugStatus = GeneratedProposalDebugStatusBuilder.build(
			llmResult: llmResult,
			llmCandidates: llmCandidates,
			activation: activation,
			situational: prepared.situational
		)
		print("[GeneratedProposal] \(debugStatus.logLine)")
		print(debugStatus.pipelineStatusLine)
		GeneratedProposalActivationDiagnostics.logOutcome(
			llmResult: llmResult,
			candidateCount: llmCandidates.count,
			visibleCount: activation.visibleProposals.count,
			situational: prepared.situational
		)

		var publishedProposal: ActionProposal?
		var publishedProposalKey: String?
		if activation.timingDecision.allowsFloatingGenerated,
		   let floatingId = activation.floatingGeneratedProposalId,
		   let topGenerated = activation.visibleProposals.first
		{
			let question = topGenerated.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
			let headline: String
			if question.hasSuffix("?"), question.count <= 110 {
				headline = question
			} else {
				headline = "Try: \(topGenerated.title)?"
			}
			publishedProposal = ActionProposal(
				title: headline,
				sourceCaption: "Generated proposal",
				primaryActionId: floatingId,
				secondaryActionIds: [],
				confidence: topGenerated.confidence,
				reason: "generated_execution_proposal"
			)
			publishedProposalKey = "\(packet.triggerType.rawValue)|\(floatingId)|generated"
			print("[FloatingSuggestionDebug] proposal_constructed title=\"\(topGenerated.title.prefix(60))\" floatingId=\(floatingId.prefix(40))")
		} else {
			// Log which condition blocked construction for diagnosis.
			let blockReason: String = {
				if !activation.timingDecision.allowsFloatingGenerated {
					return "timing_blocks_floating outcome=\(activation.timingDecision.outcome.rawValue)"
				}
				if activation.floatingGeneratedProposalId == nil {
					return "floating_id_nil visible_count=\(activation.visibleProposals.count)"
				}
				return "no_visible_proposals"
			}()
			print("[FloatingSuggestionDebug] proposal_not_constructed reason=\(blockReason) panel_proposals=\(activation.visibleProposals.count)")
		}

		if packet.triggerType != .manualInvocation, let key = publishedProposalKey {
			if let dismissedAt = appState.lastDismissedProposalAt,
			   appState.lastDismissedProposalKey == key,
			   Date().timeIntervalSince(dismissedAt) < 120
			{
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=dismissed")
				publishedProposal = nil
				publishedProposalKey = nil
			} else if let acceptedAt = appState.lastAcceptedProposalAt,
					  appState.lastAcceptedProposalKey == key,
					  Date().timeIntervalSince(acceptedAt) < 10
			{
				print("[ProposalCooldown] suppressed proposal key=\(key) reason=accepted")
				publishedProposal = nil
				publishedProposalKey = nil
			}
		}

		// T18.5: Apply chime-in policy before publishing.
		let chimeFilteredActivation = applyChimeInPolicy(to: activation, packet: packet, snapshot: proposalSnapshot)
		var chimeFilteredProposal: ActionProposal?
		var chimeFilteredProposalKey: String?
		if chimeFilteredActivation.timingDecision.allowsFloatingGenerated {
			chimeFilteredProposal = publishedProposal
			chimeFilteredProposalKey = publishedProposalKey
		} else if publishedProposal?.reason == "generated_execution_proposal" {
			print("[FloatingSuggestionDebug] proposal_chime_nulled chime_allows_float=no proposal_was=\(publishedProposal != nil ? "set" : "nil")")
			chimeFilteredProposal = nil
			chimeFilteredProposalKey = nil
		} else {
			chimeFilteredProposal = publishedProposal
			chimeFilteredProposalKey = publishedProposalKey
		}

		// Part B — Chime-driven floating fallback (T16.X).
		// If chime policy says floatingSuggestion but the activator's old gate blocked floatingId,
		// construct the proposal directly from the top visible panel proposal.
		// This eliminates the double-gate problem: chime policy is the single authority for floating.
		if chimeFilteredActivation.timingDecision.allowsFloatingGenerated,
		   chimeFilteredProposal == nil,
		   let topPanel = activation.visibleProposals.first
		{
			let chimeDrivenId = GeneratedExecutionProposalActivator.generatedProposalActionId(for: topPanel.id)
			chimeFilteredProposal = ActionProposal(
				title: "Try: \(topPanel.title)?",
				sourceCaption: "Generated proposal",
				primaryActionId: chimeDrivenId,
				secondaryActionIds: [],
				confidence: topPanel.confidence,
				reason: "generated_execution_proposal"
			)
			chimeFilteredProposalKey = "\(packet.triggerType.rawValue)|\(chimeDrivenId)|generated"
			print("[FloatingSuggestionDebug] proposal_constructed reason=chime_policy_floating title=\"\(topPanel.title.prefix(60))\"")
		}

		print("[FloatingSuggestionDebug] chime_result allows_float=\(chimeFilteredActivation.timingDecision.allowsFloatingGenerated) proposal_survives=\(chimeFilteredProposal != nil)")

		let toolActions = registeredToolActions(for: packet, context: context)
		publishDynamicOnlyReasonedActions(
			toolActions: toolActions,
			finalProposal: chimeFilteredProposal,
			finalProposalKey: chimeFilteredProposalKey,
			packet: packet,
			context: context,
			generation: generation,
			generatedProposalActivation: chimeFilteredActivation,
			debugStatus: debugStatus,
			decision: decision
		)
	}

	// MARK: - T18.5 — Chime-in policy

	/// Applies `ContextualChimeInPolicy` to the activation result (T18.5 + T18.6 + T18.6A).
	///
	/// T18.6A: Proposal novelty is now keyed on the full context fingerprint —
	/// bundle ID + window title prefix + workflow + OCR/text availability.
	/// This means the same template on different Reddit/YouTube pages has fully independent
	/// novelty entries (fresh on each page), while the same page+template decays normally.
	///
	/// Context changes are detected by comparing fingerprint components and logged explicitly.
	/// The interruption cost is derived from context-staleness so same-page repeats stay
	/// panel-only (no floating) while different-page proposals can float again.
	private func applyChimeInPolicy(
		to activation: GeneratedExecutionProposalActivationResult,
		packet: TriggerPacket,
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> GeneratedExecutionProposalActivationResult {
		guard !activation.visibleProposals.isEmpty else {
			// Nothing to filter — still publish empty visibility state.
			let emptyState = ProposalVisibilityState(
				generatedCount: 0,
				visibleCount: 0,
				suppressedCount: activation.suppressedGeneratedCount,
				suppressionReasons: ["no_candidates"],
				lastDecision: "suppress",
				lastNoveltyScore: nil,
				updatedAt: Date()
			)
			appState.applyProposalVisibilityState(emptyState)
			return activation
		}

		let now = Date()
		let workflow = WorkflowInferenceEngine.shared.latestResult()
		let wfType = workflow.map { WorkflowExecutionMapper.workflowType(from: $0.workflow) } ?? .unknown
		let wfConf = workflow.map { min(1.0, max(0.0, $0.confidence)) } ?? 0

		let hasSelectedText = !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let hasOCR = !(snapshot.recentOCRExcerpt ?? "").isEmpty
		let hasRichContext = hasSelectedText || hasOCR
		let topScore = activation.visibleProposals.first?.rankScore ?? 0
		let isManual = packet.triggerType == .manualInvocation

		// T18.6A — Full context fingerprint.
		// Uses bundle ID (stable across page loads), window title prefix (changes with page),
		// workflow, and source-availability flags. Same template → different page = different key.
		let bundle = snapshot.bundleIdentifier ?? String(snapshot.activeApp.lowercased().prefix(20))
		let titlePrefix = String(snapshot.windowTitle.prefix(40))
		let currentCtx = ChimeInContextSnapshot(
			bundle: bundle,
			titlePrefix: titlePrefix,
			workflow: wfType.rawValue,
			hasOCR: hasOCR,
			hasSelectedText: hasSelectedText
		)

		// Detect and log meaningful context changes.
		let contextChanged: Bool
		if let prev = lastChimeInContext, prev != currentCtx {
			contextChanged = true
			var changeReasons: [String] = []
			if prev.titlePrefix != currentCtx.titlePrefix { changeReasons.append("title_changed") }
			if prev.bundle != currentCtx.bundle       { changeReasons.append("app_changed") }
			if prev.workflow != currentCtx.workflow   { changeReasons.append("workflow_changed") }
			if prev.hasOCR != currentCtx.hasOCR       { changeReasons.append("ocr_changed") }
			if prev.hasSelectedText != currentCtx.hasSelectedText { changeReasons.append("selection_changed") }
			print("[ChimeInPolicy] context_changed=yes novelty_reset=yes reason=\(changeReasons.joined(separator: "|"))")
		} else {
			contextChanged = lastChimeInContext == nil // first call ever is not a "change"
		}
		lastChimeInContext = currentCtx

		// Build context-aware novelty key.
		// Format: "<templateId>|<bundle>|<titlePrefix>|<workflow>|<ocrFlag><textFlag>"
		// Same template, same page → same key (decays with repetition).
		// Same template, different page → different key (fresh novelty).
		let topId = activation.visibleProposals.first?.id ?? ""
		let ocrTextFlags = "\(hasOCR ? "1" : "0")\(hasSelectedText ? "1" : "0")"
		let contextualNoveltyKey = "\(topId)|\(bundle)|\(titlePrefix)|\(wfType.rawValue)|\(ocrTextFlags)"
		let novelty = ProposalNoveltyTracker.shared.noveltyScore(for: contextualNoveltyKey)

		// T18.6A — Derive interruption cost from context-staleness.
		// Same page + degraded novelty → higher cost (forces panel-only, no floating).
		// Context changed / fresh novelty → low cost (floating eligible).
		let derivedInterruptionCost: Double
		if !contextChanged && novelty < 0.60 {
			// Same page, already seen — calm: panel-only only, no floating interruption.
			derivedInterruptionCost = 0.55
		} else if contextChanged && novelty >= 0.70 {
			// Fresh context — low interruption cost, floating eligible.
			derivedInterruptionCost = 0.20
		} else {
			derivedInterruptionCost = 0.30
		}

		// Recent dismissal / accept intervals.
		let dismissalAge = appState.lastDismissedProposalAt.map { now.timeIntervalSince($0) }
		let acceptAge = appState.lastAcceptedProposalAt.map { now.timeIntervalSince($0) }

		let factors = ContextualChimeInFactors(
			isManualInvocation: isManual,
			workflowType: wfType,
			workflowConfidence: wfConf,
			hasRichContext: hasRichContext,
			proposalCount: activation.visibleProposals.count,
			topProposalScore: topScore,
			topInterruptionCost: derivedInterruptionCost,
			recentDismissalInSeconds: dismissalAge,
			recentAcceptInSeconds: acceptAge,
			noveltyScore: novelty,
			isActionExecuting: appState.isActionExecuting,
			isContextStale: snapshot.packetIsStale,
			visualContextWasRecentlyEnriched: false
		)

		var decision = ContextualChimeInPolicy.evaluate(factors: factors)

		// Decision quality log — explains utility, novelty, and interruption cost together.
		print("[ChimeInPolicy] decision_quality score=\(String(format: "%.2f", decision.score)) utility=\(String(format: "%.2f", topScore)) novelty=\(String(format: "%.2f", novelty)) interruption=\(String(format: "%.2f", derivedInterruptionCost)) context=\(contextChanged ? "changed" : "same") mode=\(decision.mode.rawValue)")

		// Resurfacing guarantee (T18.6): if silent ≥3 min and score is passable, allow panel-only.
		let wasFullySuppressed = !decision.shouldSurface
		if wasFullySuppressed && !factors.isActionExecuting {
			let lastVisible = appState.lastVisibleProposalAt ?? .distantPast
			let silenceDuration = now.timeIntervalSince(lastVisible)
			if silenceDuration >= 180 && topScore >= 0.38 {
				print("[ChimeInPolicy] resurfacing_guarantee triggered silence=\(Int(silenceDuration))s score=\(String(format: "%.2f", topScore)) original_reason=\(decision.reasons.first ?? "unknown")")
				decision = ContextualChimeInDecision(
					mode: .panelOnly,
					score: topScore,
					reasons: ["resurfacing_guarantee"],
					cooldownRecommendation: nil
				)
			} else {
				print("[ChimeInPolicy] suppressed helpful proposal silence=\(Int(silenceDuration))s reason=\(decision.reasons.first ?? "policy") novelty=\(String(format: "%.2f", novelty))")
			}
		}

		// Build visibility state for debug UI and pipeline log.
		let totalGenerated = activation.visibleProposals.count + activation.suppressedGeneratedCount
		let visibleAfterPolicy = decision.shouldSurface ? activation.visibleProposals.count : 0
		let suppressedByPolicy = decision.shouldSurface ? 0 : activation.visibleProposals.count
		let visibilityState = ProposalVisibilityState(
			generatedCount: totalGenerated,
			visibleCount: visibleAfterPolicy,
			suppressedCount: activation.suppressedGeneratedCount + suppressedByPolicy,
			suppressionReasons: decision.reasons,
			lastDecision: decision.mode.rawValue,
			lastNoveltyScore: novelty,
			updatedAt: now
		)
		appState.applyProposalVisibilityState(visibilityState)
		print("[ProposalPipeline] \(visibilityState.pipelineLogLine)")

		if !decision.shouldSurface {
			return GeneratedExecutionProposalActivationResult(
				visibleProposals: [],
				visibleStaticActionIds: activation.visibleStaticActionIds,
				suppressedGeneratedCount: activation.suppressedGeneratedCount + activation.visibleProposals.count,
				suppressedStaticCount: activation.suppressedStaticCount,
				topSourceType: activation.topSourceType,
				rankingSummary: "chime_suppressed:\(decision.reasons.first ?? "policy")",
				timingDecision: .suppressAll,
				warnings: activation.warnings + ["chime_policy_suppressed"],
				createdAt: activation.createdAt,
				floatingGeneratedProposalId: nil
			)
		}

		// Record visible proposals in novelty tracker using full context-aware key.
		for item in activation.visibleProposals.prefix(3) {
			let itemKey = "\(item.id)|\(bundle)|\(titlePrefix)|\(wfType.rawValue)|\(ocrTextFlags)"
			ProposalNoveltyTracker.shared.record(signature: itemKey)
		}

		// If panelOnly (policy decision or resurfacing guarantee), strip floating.
		if decision.mode == .panelOnly {
			return GeneratedExecutionProposalActivationResult(
				visibleProposals: activation.visibleProposals,
				visibleStaticActionIds: activation.visibleStaticActionIds,
				suppressedGeneratedCount: activation.suppressedGeneratedCount,
				suppressedStaticCount: activation.suppressedStaticCount,
				topSourceType: activation.topSourceType,
				rankingSummary: activation.rankingSummary,
				timingDecision: GeneratedExecutionProposalTimingDecision(
					outcome: .allowPanel,
					reason: "chime_panel_only",
					allowsFloatingGenerated: false,
					allowsPanelGenerated: true
				),
				warnings: activation.warnings,
				createdAt: activation.createdAt,
				floatingGeneratedProposalId: nil
			)
		}

		return activation
	}

	private func registeredToolActions(for packet: TriggerPacket, context: ContextModel) -> [any ActionProtocol] {
		var evalContext = context
		evalContext.actionInputSourcePreference = appState.selectedInputSourceChoice
		return actionRouter.matchingActions(for: packet).filter { action in
			!DynamicOnlyProposalMode.isGenericStaticAction(action.id) && action.canExecute(context: evalContext)
		}
	}

	private func publishDynamicOnlyReasonedActions(
		toolActions: [any ActionProtocol],
		finalProposal: ActionProposal?,
		finalProposalKey: String?,
		packet: TriggerPacket,
		context: ContextModel,
		generation: UInt64,
		generatedProposalActivation: GeneratedExecutionProposalActivationResult,
		debugStatus: GeneratedProposalDebugStatus,
		decision: ReasoningDecision
	) {
		guard generation == contextPipelineGeneration else { return }

		appState.applyGeneratedProposalActivation(generatedProposalActivation, debugStatus: debugStatus)
		appState.availableActions = []
		appState.registeredToolActions = toolActions
		appState.currentProposal = finalProposal
		appState.currentProposalKey = finalProposalKey
		appState.refreshProposalContext(for: finalProposal)
		lastReasonedActions = []
		lastReasonedActionsAt = Date()
		lastReasonedTriggerType = packet.triggerType
		lastReasonedProposal = finalProposal
		lastReasonedProposalKey = finalProposalKey
		print("[AvailableActions] dynamic_only visible_generated=\(generatedProposalActivation.visibleProposals.count) tools=\(toolActions.count) trigger=\(packet.triggerType.rawValue) reason=\(decision.reason)")

		if let p = finalProposal {
			maybeShowFloatingSuggestion(
				proposal: p,
				suggestionStrength: .strong,
				context: context,
				packet: packet,
				proposalGateAllows: true
			)
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
		proposalGateAllows: Bool,
		generatedProposalActivation: GeneratedExecutionProposalActivationResult
	) {
		guard generation == contextPipelineGeneration else { return }

		appState.applyGeneratedProposalActivation(generatedProposalActivation)
		appState.availableActions = ordered
		appState.currentProposal = finalProposal
		appState.currentProposalKey = finalProposalKey
		appState.refreshProposalContext(for: finalProposal)
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

	private func scheduleDeferredProposalRefreshIfNeeded(retryAfter: TimeInterval, originalGeneration: UInt64) {
		guard retryAfter > 0 else { return }
		proposalTimingDeferredWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			guard originalGeneration == self.contextPipelineGeneration else {
				print("[ProposalTiming] deferred_cancelled reason=context_changed")
				return
			}
			guard !self.appState.isActionExecuting else { return }

			let ctx = self.contextBuilder.model
			let stillHasSelection = ctx.selectedTextAvailable && ctx.selectedTextLength >= TriggerEngine.selectedTextMinCharacterCount
			if !stillHasSelection {
				print("[ProposalTiming] deferred_cancelled reason=context_changed")
				return
			}

			self.processUpdatedContextAfterPipeline()
			print("[ProposalTiming] deferred_shown reason=idle_after_burst")
		}
		proposalTimingDeferredWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + retryAfter, execute: work)
		print("[ProposalTiming] deferred_scheduled after=\(String(format: "%.1f", retryAfter))s")
	}

	private func logProposalTimingIfNeededCore(decision: ProposalTimingDecision, typing: TypingActivityContext, pointer: PointerActivityContext) {
		let now = Date()
		let sig = [
			decision.outcome.rawValue,
			decision.reason,
			typing.typingState.rawValue,
			typing.burstIntensity.rawValue,
			pointer.pointerState.rawValue,
			pointer.movementBurstIntensity.rawValue,
			pointer.clickBurstIntensity.rawValue
		].joined(separator: "|")

		if sig == lastProposalTimingSignature, let lastProposalTimingLogAt, now.timeIntervalSince(lastProposalTimingLogAt) < 1.5 {
			return
		}
		lastProposalTimingSignature = sig
		lastProposalTimingLogAt = now

		switch decision.outcome {
		case .allow:
			print("[ProposalTiming] allow reason=\(decision.reason) typing=\(typing.typingState.rawValue) pointer=\(pointer.pointerState.rawValue)")
		case .deferred:
			print("[ProposalTiming] defer reason=\(decision.reason) typing=\(typing.typingState.rawValue) pointer=\(pointer.pointerState.rawValue)")
		case .suppress:
			print("[ProposalTiming] suppress reason=\(decision.reason) typing=\(typing.typingState.rawValue) pointer=\(pointer.pointerState.rawValue)")
		}
	}

	private func logProposalTimingIfNeeded(decision: ProposalTimingDecision, typing: TypingActivityContext?, pointer: PointerActivityContext?) {
		guard let typing, let pointer else {
			// If monitoring is not running yet, avoid noisy logs.
			return
		}
		logProposalTimingIfNeededCore(decision: decision, typing: typing, pointer: pointer)
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
			proposalGateAllows: proposalGateAllowed,
			generatedProposalActivation: appState.generatedProposalActivationResult
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
				appState.refreshProposalContext(for: nil)
				print("[AvailableActions] cleared cached actions reason=\(reason)")
			}
			return
		}

		let age = Date().timeIntervalSince(cachedAt)
		if age < availableActionsCacheTTLSeconds, !lastReasonedActions.isEmpty {
			let liveContext = contextBuilder.model
			appState.availableActions = lastReasonedActions.filter { $0.canExecute(context: liveContext) }
			if let p = lastReasonedProposal,
			   lastReasonedActions.contains(where: { $0.id == p.primaryActionId }),
			   !appState.isSuggestionOnCooldown(p, context: appState.debugContext) {
				appState.currentProposal = p
				appState.currentProposalKey = lastReasonedProposalKey
				appState.refreshProposalContext(for: p)
			} else {
				appState.currentProposal = nil
				appState.currentProposalKey = nil
				appState.refreshProposalContext(for: nil)
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
		appState.refreshProposalContext(for: nil)
		lastReasonedActions = []
		lastReasonedActionsAt = nil
		lastReasonedTriggerType = nil
		lastReasonedProposal = nil
		lastReasonedProposalKey = nil
		print("[AvailableActions] cleared cached actions reason=\(reason)")
	}

	private func invokeGeneratedExecutionProposal(candidateId: String) {
		// T18.4: Execution-scoped generated execution — user-approved only, no auto-execution.
		if appState.isActionExecuting {
			print("[GeneratedProposalExecution] invoke_ignored reason=already_executing id=\(candidateId.prefix(12))")
			return
		}

		let actionId = GeneratedExecutionProposalActivator.generatedProposalActionId(for: candidateId)
		appState.isActionExecuting = true
		appState.executingActionId = actionId
		appState.executingActionTitle = "Generated execution"
		appState.latestActionResult = nil
		appState.latestGeneratedExecutionPresentation = nil
		appState.latestActionId = actionId
		appState.latestActionTimestamp = Date()
		appState.generatedExecutionPhaseLabel = "Preparing context…"
		print("[GeneratedProposalExecution] runtime_prepare id=\(candidateId.prefix(12))")

		Task { @MainActor in
			defer {
				self.appState.isActionExecuting = false
				self.appState.executingActionId = nil
				self.appState.executingActionTitle = nil
				self.appState.generatedExecutionPhaseLabel = nil
				self.activeGeneratedExecutionRuntime = nil
				print("[GeneratedProposalExecution] runtime_finished id=\(candidateId.prefix(12))")
			}

			let now = Date()
			let canonical = CanonicalContextState.shared.current()
			let snapshot = self.buildCanonicalSnapshotForProposalActivation(context: self.contextBuilder.model, fused: canonical)

			let action: GeneratedExecutionAction?
			var resolvedTemplateId: String?
			if candidateId.hasPrefix("reuse:") {
				let templateId = String(candidateId.dropFirst("reuse:".count))
				resolvedTemplateId = templateId
				let manager = GeneratedActionPersistenceManager.shared
				let record = await manager.record(templateId: templateId)
				if let record {
					let candidate = GeneratedExecutionProposalCandidateBuilder.buildReusable(from: [record], referenceTime: now).first
					action = candidate?.executionAction
					self.appState.executingActionTitle = candidate?.title ?? "Generated execution"
				} else {
					action = nil
				}
			} else {
				// Non-reusable synthesized candidates resolve via the ephemeral action cache populated
				// during proposal activation (hook composer / non-library candidates).
				action = self.appState.cachedGeneratedExecutionAction(candidateId: candidateId)
				if let action {
					self.appState.executingActionTitle = action.title
				}
			}

			guard let action else {
				print("[GeneratedProposalExecution] runtime_unavailable id=\(candidateId.prefix(12)) reason=missing_execution_action")
				// Surface a structured failure card rather than raw text.
				let failResult = ExecutionResult(
					actionId: UUID(),
					status: .failed,
					startedAt: now,
					completedAt: Date(),
					generatedContent: nil,
					generatedSections: [],
					warnings: ["missing_execution_action"],
					executionMetadata: ["runtimePhase": "unavailable"],
					confidence: 0,
					followUpSuggestions: []
				)
				self.appState.latestGeneratedExecutionPresentation = GeneratedExecutionResultPresenter.makePresentation(from: failResult, action: nil)
				print("[GeneratedExecutionResult] presented status=failed sections=0 reason=unavailable")
				return
			}

			let visualRequired = action.executionPlan.requiresVision || action.executionPlan.requiresOCR
			print(
				"[GeneratedProposalExecution] selected id=\(candidateId.prefix(12)) template=\(resolvedTemplateId ?? "unknown") visual_required=\(visualRequired ? "yes" : "no")"
			)

			// Visual enrichment is execution-scoped and optional: scheduler is injected only here.
			let provider = ScreenCaptureBoundedVisualContextProvider()
			let scheduler = VisualContextScheduler(provider: provider)
			let runtime = GeneratedExecutionRuntime(
				persistenceManager: GeneratedActionPersistenceManager.shared,
				visualContextScheduler: scheduler,
				canonicalSnapshot: snapshot
			)
			self.activeGeneratedExecutionRuntime = runtime

			self.appState.generatedExecutionPhaseLabel = visualRequired ? "Gathering visual context…" : "Gathering context…"
			print("[GeneratedExecutionRuntime] live_start id=\(candidateId.prefix(12)) workflow=\(action.workflowType.rawValue) primitives=\(action.executionPlan.primitives.count)")

			let outcome = await runtime.start(action: action)
			switch outcome {
			case .completed(let result):
				let status = result.status.rawValue
				let visual = result.executionMetadata["visual_enrichment_performed"] == "1" ? "yes" : "no"
				let visualDecision = result.executionMetadata["visual_enrichment_decision"] ?? "unknown"
				print("[GeneratedExecutionRuntime] live_completed id=\(candidateId.prefix(12)) status=\(status) visual=\(visual) decision=\(visualDecision)")
				let presentation = GeneratedExecutionResultPresenter.makePresentation(from: result, action: action)
				self.appState.latestGeneratedExecutionPresentation = presentation
				self.appState.latestActionId = actionId
				self.appState.latestActionTimestamp = Date()
				self.appState.latestActionResult = nil
				print("[GeneratedExecutionResult] presented status=\(status) sections=\(presentation.sections.count) followUps=\(presentation.followUpSuggestions.count)")
				// Cache hook-composed actions only after a successful execution (accelerator, not source of truth).
				if result.status == .success || result.status == .partialSuccess {
					await DynamicGeneratedProposalEngine.shared.recordSuccessfulDynamicActionExecution(
						candidateId: candidateId,
						action: action,
						referenceTime: Date()
					)
				}

			case .rejected(let reason):
				print("[GeneratedExecutionRuntime] live_completed id=\(candidateId.prefix(12)) status=rejected reason=\(reason.rawValue)")
				let failResult = ExecutionResult(
					actionId: action.id,
					status: .failed,
					startedAt: now,
					completedAt: Date(),
					generatedContent: nil,
					generatedSections: [],
					warnings: [reason.rawValue],
					executionMetadata: ["runtimePhase": "rejected"],
					confidence: action.confidence,
					followUpSuggestions: []
				)
				self.appState.latestGeneratedExecutionPresentation = GeneratedExecutionResultPresenter.makePresentation(from: failResult, action: action)
				self.appState.latestActionResult = nil
				print("[GeneratedExecutionResult] presented status=rejected sections=0")
			}
		}
	}

	private func invokeStoredAction(actionId: String) {
		if actionId == ScreenAnalyzeAction.analyzeScreenId {
			invokeAnalyzeScreenStoredAction()
			return
		}

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

	/// Screen capture + OCR only for explicit Analyze Screen (not normal manual assistant open).
	@MainActor
	private func runExplicitAnalyzeScreenCaptureAndOCR() async {
		print("[AnalyzeScreenRich] explicit_screen_analysis=true")
		print("[Phase14Tuning] fixed reason=manual_ocr_gate")
		sourceManager?.captureScreenNow()
		guard let image = contextBuilder.model.screenCaptureImage else {
			print("[ScreenCapture] post_capture_no_image reason=explicit_analyze_screen")
			return
		}
		let result = await OCRProcessor.shared.recognizeText(from: image)
		processSourceEvent(
			.sourceChanged(.screenOCRCompleted(text: result.text, lineCount: result.lineCount, capturedAt: result.timestamp))
		)
	}

	private func invokeAnalyzeScreenStoredAction() {
		let actionId = ScreenAnalyzeAction.analyzeScreenId
		var execContext = contextBuilder.model
		execContext.actionInputSourcePreference = appState.selectedInputSourceChoice
		guard appState.availableActions.contains(where: { $0.id == actionId }) else { return }
		guard ScreenAnalyzeAction().canExecute(context: execContext) else {
			print("[ActionResult] No valid actions")
			return
		}

		if appState.isActionExecuting {
			print("[ActionExecution] Ignored duplicate action while execution is in progress")
			return
		}

		appState.isActionExecuting = true
		appState.executingActionId = actionId
		appState.executingActionTitle = "Analyze Screen"
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
				print("[ActionExecution] Cleared in-flight state")
			}

			await self.runExplicitAnalyzeScreenCaptureAndOCR()

			var freshContext = self.contextBuilder.model
			freshContext.actionInputSourcePreference = self.appState.selectedInputSourceChoice
			guard ScreenAnalyzeAction().canExecute(context: freshContext) else {
				print("[ActionResult] Analyze Screen unavailable after capture (permissions or empty capture)")
				self.appState.latestActionResult = "Could not capture the screen for analysis. Check Screen Recording permission and try again."
				self.appState.latestActionTimestamp = Date()
				return
			}

			let inputFingerprint = Self.stableInputFingerprint(for: freshContext)
			let invocationKey = "\(actionId)|\(inputFingerprint)"
			if let finishedAt = self.lastFinishedAt,
			   self.lastFinishedActionKey == invocationKey,
			   Date().timeIntervalSince(finishedAt) < 2 {
				print("[ActionExecution] Ignored duplicate action invocation within cooldown")
				return
			}

			let outcome = await Self.runActionWithSecondsTimeout(seconds: 45) {
				await ScreenAnalyzeAction().execute(context: freshContext)
			}
			switch outcome {
			case .completed(let result):
				print("[ActionResult]", result.outputText)
				self.appState.latestActionResult = result.outputText
				self.appState.latestActionTimestamp = Date()
				self.lastFinishedActionKey = invocationKey
				self.lastFinishedAt = Date()
				print("[ActionExecution] Finished action \(actionId)")
			case .timedOut:
				print("[ActionExecution] Action timed out")
				print("[ActionExecution] Failed action \(actionId): timed out")
				self.appState.latestActionResult = "This action timed out. Try again with less text or check that local AI is responding."
				self.appState.latestActionTimestamp = Date()
				self.lastFinishedActionKey = invocationKey
				self.lastFinishedAt = Date()
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

	@discardableResult
	private func runPhase13SelfTestsIfRequested(environment env: [String: String]) -> Bool {
		// Phase 13 env-var self-tests should run once and exit without wiring the normal app pipeline.
		// This keeps verification runs clean and avoids incidental startup logs/side-effects.

		// Phase 14 tuning pass regression self-test (synthetic; no capture/OCR).
		// Run with `CONTEXTUAL_RUN_PHASE14_TUNING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_PHASE14_TUNING_SELFTEST"] == "1" {
			let ok = Phase14TuningSelfTest.run()
			print("[Phase14Tuning] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 15 tuning pass (synthetic; preview-only generated actions; metadata-only).
		// Run with `CONTEXTUAL_RUN_PHASE15_TUNING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_PHASE15_TUNING_SELFTEST"] == "1" {
			let ok = Phase15TuningSelfTest.run()
			print("[Phase15Tuning] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Visible generated actions panel rules (T16.1; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_VISIBLE_GENERATED_ACTIONS_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_VISIBLE_GENERATED_ACTIONS_SELFTEST"] == "1" {
			let ok = VisibleGeneratedActionPanelAdapter.runSelfTest()
			print("[VisibleGeneratedAction] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Inline assistance foundations (T16.6 + T18.6; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_INLINE_ASSISTANCE_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_INLINE_ASSISTANCE_SELFTEST"] == "1" {
			let builderOk = InlineAssistanceCandidateBuilder.runSelfTest()
			let policyOk  = InlineAssistanceEligibilityPolicy.runSelfTest()
			let ok = builderOk && policyOk
			print("[InlineAssistance] env selftest ok=\(ok) builder=\(builderOk) policy=\(policyOk)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated action interaction tracking (T16.9; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_GENERATED_ACTION_INTERACTION_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_GENERATED_ACTION_INTERACTION_SELFTEST"] == "1" {
			let ok = GeneratedActionInteractionTracker.runSelfTest()
			print("[GeneratedActionInteraction] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich assistance unified ranking (T16.10; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_RICH_ASSISTANCE_RANKING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_RICH_ASSISTANCE_RANKING_SELFTEST"] == "1" {
			let ok = RichAssistanceRanker.runSelfTest()
			print("[RichAssistanceRank] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Visible intelligence debug summary (T16.11; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_VISIBLE_INTELLIGENCE_DEBUG_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_VISIBLE_INTELLIGENCE_DEBUG_SELFTEST"] == "1" {
			let ok = VisibleIntelligenceDebugSummaryBuilder.runSelfTest()
			print("[VisibleIntelligenceDebug] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated assistance categories (T16.5; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_ASSISTANCE_CATEGORY_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_ASSISTANCE_CATEGORY_SELFTEST"] == "1" {
			let ok = GeneratedAssistanceCategoryMapper.runSelfTest()
			print("[AssistanceCategory] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Workflow inference engine self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_WORKFLOW_INFERENCE_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_WORKFLOW_INFERENCE_SELFTEST"] == "1" {
			let ok = WorkflowInferenceEngine.runSelfTest()
			print("[WorkflowInference] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Contextual session tracking self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_SESSION_TRACKING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_SESSION_TRACKING_SELFTEST"] == "1" {
			let ok = ContextualSessionTracker.runSelfTest()
			print("[SessionTracking] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Intent synthesis engine self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_INTENT_SYNTHESIS_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_INTENT_SYNTHESIS_SELFTEST"] == "1" {
			let ok = IntentSynthesisEngine.runSelfTest()
			print("[IntentSynthesis] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Dynamic intent suppression self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_INTENT_SUPPRESSION_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_INTENT_SUPPRESSION_SELFTEST"] == "1" {
			let ok = DynamicIntentSuppressionEngine.runSelfTest()
			print("[IntentSuppression] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated action model self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_GENERATED_ACTION_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_GENERATED_ACTION_SELFTEST"] == "1" {
			let ok = GeneratedActionEngine.runSelfTest()
			print("[GeneratedAction] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated action safety policy self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_GENERATED_ACTION_SAFETY_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_GENERATED_ACTION_SAFETY_SELFTEST"] == "1" {
			let ok = GeneratedActionSafetyPolicy.runSelfTest()
			print("[GeneratedActionSafety] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated action plan composition self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_ACTION_PLAN_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_ACTION_PLAN_SELFTEST"] == "1" {
			let ok = GeneratedActionPlanBuilder.runSelfTest()
			print("[ActionPlan] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Generated action explainability self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_ACTION_EXPLAINABILITY_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_ACTION_EXPLAINABILITY_SELFTEST"] == "1" {
			let ok = GeneratedActionExplanationBuilder.runSelfTest()
			print("[GeneratedActionExplainability] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Workflow-aware proposal ranking self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_WORKFLOW_PROPOSAL_RANKING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_WORKFLOW_PROPOSAL_RANKING_SELFTEST"] == "1" {
			let ok = WorkflowAwareProposalRanker.runSelfTest()
			print("[WorkflowProposalRank] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Workflow-sensitive action ordering (T16.3): bundled synthetic self-tests.
		// Run with `CONTEXTUAL_RUN_WORKFLOW_ACTION_ORDERING_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_WORKFLOW_ACTION_ORDERING_SELFTEST"] == "1" {
			let ok = WorkflowActionOrderingSelfTest.run()
			print("[WorkflowActionOrdering] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Proposal card context summary self-test (synthetic metadata-only).
		// Run with `CONTEXTUAL_RUN_PROPOSAL_CONTEXT_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_PROPOSAL_CONTEXT_SELFTEST"] == "1" {
			let ok = ProposalContextSummaryBuilder.runSelfTest()
			print("[ProposalContext] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Workflow continuity panel surfacing (T16.8; synthetic; metadata-only).
		// Run with `CONTEXTUAL_RUN_WORKFLOW_CONTINUITY_UI_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_WORKFLOW_CONTINUITY_UI_SELFTEST"] == "1" {
			let ok = WorkflowContinuityDisplayBuilder.runSelfTest()
			print("[WorkflowContinuityUI] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Canonical fused context state self-test (synthetic metadata-only).
		// Run the app with `CONTEXTUAL_RUN_CANONICAL_CONTEXT_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_CANONICAL_CONTEXT_SELFTEST"] == "1" {
			let ok = CanonicalContextState.shared.selfTest()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich context refresh pipeline self-test (synthetic/current metadata-only).
		// Run the app with `CONTEXTUAL_RUN_RICH_REFRESH_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_RICH_REFRESH_SELFTEST"] == "1" {
			Task {
				print("[RichContextRefresh] selftest starting")
				let model = ContextModel()
				let req = RichContextRefreshRequest(
					trigger: .debugSelfTest,
					reason: "selftest",
					includeWindowSnapshot: true,
					includeVisualDescriptor: true,
					includeAXContent: true,
					includeTypingActivity: true,
					includePointerActivity: true,
					allowExpensiveSources: true,
					currentContextModel: model,
					isActionExecuting: false,
					currentIntelligenceConfidence: 0.30
				)

				// Start one refresh and cancel it immediately to validate cancellation/stale protection.
				let pipeline = RichContextRefreshPipeline.shared
				let t = Task { await pipeline.refresh(req) }
				try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
				pipeline.cancelCurrent(reason: "selftest_cancel")
				let cancelledResult = await t.value
				print("[RichContextRefresh] selftest cancel wasCancelled=\(cancelledResult.wasCancelled)")

				// Now run a real refresh.
				let result = await pipeline.refresh(req)
				let collected = result.collectedSources.map(\.rawValue).joined(separator: ",")
				let skipped = result.skippedSources.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")
				print("[RichContextRefresh] selftest result ok=true cancelled=\(result.wasCancelled) collected=\(collected) skipped=\(skipped) updatedCanonical=\(result.updatedCanonicalState) primary=\(result.fusedPacket?.primarySource.rawValue ?? "nil")")
				NSApp.terminate(nil)
			}
			return true
		}

		// Rich proposal selection self-test (synthetic metadata-only; no collection).
		// Run the app with `CONTEXTUAL_RUN_RICH_PROPOSAL_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_RICH_PROPOSAL_SELFTEST"] == "1" {
			let ok = RichContextProposalSelfTest.run()
			print("[RichProposal] selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Action eligibility self-test (synthetic metadata-only; no collection).
		// Run the app with `CONTEXTUAL_RUN_ACTION_ELIGIBILITY_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_ACTION_ELIGIBILITY_SELFTEST"] == "1" {
			let ok = ContextAwareActionEligibility.selfTest()
			print("[ActionEligibility] selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Context confidence arbitration self-test (synthetic metadata-only; no collection).
		// Run the app with `CONTEXTUAL_RUN_ARBITRATION_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_ARBITRATION_SELFTEST"] == "1" {
			let ok = ContextConfidenceArbitrator.shared.selfTest()
			print("[ContextArbitration] selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Adaptive context sampling self-test (synthetic metadata-only; no collection).
		// Run the app with `CONTEXTUAL_RUN_ADAPTIVE_SAMPLING_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_ADAPTIVE_SAMPLING_SELFTEST"] == "1" {
			let ok = AdaptiveContextSampler.runSelfTest()
			print("[AdaptiveSampling] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Context awareness UI summary self-test (synthetic fused metadata only).
		// Run the app with `CONTEXTUAL_RUN_CONTEXT_AWARENESS_UI_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_CONTEXT_AWARENESS_UI_SELFTEST"] == "1" {
			let ok = ContextAwarenessSummaryBuilder.runSelfTest()
			print("[ContextAwarenessUI] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich context debug summary self-test (synthetic fused metadata only).
		// Run the app with `CONTEXTUAL_RUN_RICH_CONTEXT_DEBUG_UI_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_RICH_CONTEXT_DEBUG_UI_SELFTEST"] == "1" {
			let ok = RichContextDebugSummaryBuilder.runSelfTest()
			print("[RichContextDebugUI] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Dynamic intent debug summary self-test (synthetic metadata only).
		// Run the app with `CONTEXTUAL_RUN_DYNAMIC_INTENT_DEBUG_UI_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_DYNAMIC_INTENT_DEBUG_UI_SELFTEST"] == "1" {
			let ok = DynamicIntentDebugSummaryBuilder.runSelfTest()
			print("[DynamicIntentDebugUI] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Dynamic action UX display model self-test (synthetic metadata only).
		// Run the app with `CONTEXTUAL_RUN_DYNAMIC_ACTION_UX_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_DYNAMIC_ACTION_UX_SELFTEST"] == "1" {
			let ok = DynamicActionDisplayBuilder.runSelfTest()
			print("[DynamicActionUX] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Phase 17 stability guardrails (T17.10; metadata-only; no UI/capture).
		// Run with `CONTEXTUAL_RUN_PHASE17_STABILITY_SELFTEST=1`.
		if env["CONTEXTUAL_RUN_PHASE17_STABILITY_SELFTEST"] == "1" {
			let ok = Phase17StabilitySelfTest.run()
			print("[Phase17Stability] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Screen situation + Analyze Screen prompt jargon self-test (synthetic inputs only; no AI, no screenshots).
		// Run the app with `CONTEXTUAL_RUN_SCREEN_SITUATION_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_SCREEN_SITUATION_SELFTEST"] == "1" {
			let sOk = ScreenSituationClassifier.runSelfTest()
			let jOk = RichAnalyzeScreenPromptBuilder.runJargonSelfTest()
			let ok = sOk && jOk
			print("[ScreenSituation] env selftest ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich Analyze Screen pipeline self-test (prompt build only; no AI calls, no screenshots).
		// Run the app with `CONTEXTUAL_RUN_RICH_ANALYZE_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_RICH_ANALYZE_SELFTEST"] == "1" {
			var ctx = ContextModel()
			ctx.activeAppName = "Xcode"
			ctx.activeAppBundleIdentifier = "com.apple.dt.Xcode"
			let ocr = "Xcode\nBuild failed for target\nfunc foo() { return 1 }\n"
			let fused = FusedContextPacket(
				id: UUID(),
				createdAt: Date(),
				primarySource: .selectedText,
				availableSources: [.activeApp, .selectedText, .visualDescriptor],
				staleSources: [],
				appName: "Xcode",
				bundleIdentifier: "com.apple.dt.Xcode",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: true,
				textLength: 120,
				lineCount: 6,
				hasSelectedText: true,
				hasClipboardText: false,
				hasOCRText: true,
				hasAXText: true,
				hasWindowSnapshot: true,
				hasVisualDescriptor: true,
				hasTypingActivity: true,
				hasPointerActivity: true,
				visualKinds: [.editor, .dialog],
				uiStructureHints: ["ax_editor_like", "visual_dialog_like"],
				typingState: .idle,
				pointerState: .idle,
				confidence: 0.82,
				freshnessScore: 0.84,
				conflictScore: 0.10,
				isStale: false,
				suppressedSources: [],
				supportingSources: [.axText, .screenOCR],
				arbitrationReasons: ["selftest"],
				debugSummaryMetadata: ["selftest": "1"]
			)
			let meta: [String: String] = [
				"axFragments": "24",
				"axTextLen": "1200",
				"visualKinds": "editor",
				"visualConf": "0.82",
				"visualPanels": "2"
			]
			let built = RichAnalyzeScreenPromptBuilder.build(
				context: ctx,
				ocrText: ocr,
				ocrLineCount: 4,
				fused: fused,
				refreshMeta: meta
			)
			let containsImageLike = built.input.contains("CGImage") || built.input.contains("data:") || built.input.contains("base64")
			let ok = built.input.contains("## What you are doing")
				&& built.input.contains("## Situation profile")
				&& built.input.contains("## Visible text")
				&& RichAnalyzeScreenPromptBuilder.analyzePromptExcludesBannedTokens(built.input)
				&& built.situation.kind == .codeOrEditor
				&& !containsImageLike

			// Conflicting visual kinds + weak OCR must not enable workflow hints in the situation profile.
			let weakOCR = "YouTube\nSkip ads\n"
			let weakMeta: [String: String] = [
				"axFragments": "0",
				"axTextLen": "0",
				"visualKinds": "browser,editor,terminal,dialog",
				"visualConf": "0.35",
				"visualPanels": "1"
			]
			let weakBuilt = RichAnalyzeScreenPromptBuilder.build(
				context: ctx,
				ocrText: weakOCR,
				ocrLineCount: 2,
				fused: fused,
				refreshMeta: weakMeta
			)
			let weakKindOk = weakBuilt.situation.kind == .browserPage || weakBuilt.situation.kind == .videoOrSocial
			let weakOk = weakBuilt.situation.visualEvidenceConflicting
				&& !weakBuilt.situation.shouldUseWorkflow
				&& weakKindOk
				&& weakBuilt.input.contains("Limited readable text: yes")
				&& RichAnalyzeScreenPromptBuilder.analyzePromptExcludesBannedTokens(weakBuilt.input)
				&& !weakBuilt.input.lowercased().contains("likelyworkflow")

			let finalOk = ok && weakOk
			print("[AnalyzeScreenRich] selftest prompt_built ocrChars=\(built.ocrChars) axFragments=\(built.axFragments) visualKinds=\(built.visualKinds.joined(separator: ",")) ok=\(finalOk)")
			if finalOk {
				print("[Phase14Tuning] tuned reason=analyze_prompt")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Proposal timing self-test (synthetic metadata-only).
		// Run the app with `CONTEXTUAL_RUN_PROPOSAL_TIMING_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_PROPOSAL_TIMING_SELFTEST"] == "1" {
			Task { @MainActor in
				let okGate = ProposalTimingGate.selfTest()

				// Deferred-cancel safety self-test: schedule a deferred refresh, then invalidate selection before it fires.
				let sampleText = String(repeating: "a", count: TriggerEngine.selectedTextMinCharacterCount)
				self.processSourceEvent(.sourceChanged(.selectedTextChanged(text: sampleText)))
				let gen = self.contextPipelineGeneration
				self.scheduleDeferredProposalRefreshIfNeeded(retryAfter: 0.15, originalGeneration: gen)

				DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
					self.processSourceEvent(.sourceChanged(.selectedTextChanged(text: nil)))
				}

				try? await Task.sleep(nanoseconds: 300_000_000) // 0.30s

				print("[ProposalTiming] selftest ok=\(okGate)")
				NSApp.terminate(nil)
			}
			return true
		}

		// Self-test hook (no UI, no continuous polling).
		// Run the app with `CONTEXTUAL_RUN_AX_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_AX_SELFTEST"] == "1" {
			print("[AXContent] selftest starting")
			let ok = AXWindowContentSource.shared._selfTest()
			print("[AXContent] selftest finished ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
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
			return true
		}

		// Pointer activity DEBUG self-test (metadata-only; uses synthetic events to be non-interactive).
		// Run the app with `CONTEXTUAL_RUN_POINTER_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_POINTER_SELFTEST"] == "1" {
			print("[PointerActivity] selftest starting")
			let src = PointerActivitySource.shared
			src.reset()
			src.startMonitoring()

			func logSnapshot(_ label: String) {
				let ctx = src.currentContext()
				let idle = String(format: "%.1f", ctx.idleDuration)
				let focus = String(format: "%.2f", ctx.estimatedFocusIntensity)
				print("[PointerActivity] selftest \(label) state=\(ctx.pointerState.rawValue) moveEvents=\(ctx.recentMoveEventCount) clickEvents=\(ctx.recentClickEventCount) moveIntensity=\(ctx.movementBurstIntensity.rawValue) clickIntensity=\(ctx.clickBurstIntensity.rawValue) active=\(ctx.isPointerActive) idle=\(idle)s focus=\(focus)")
			}

			logSnapshot("initial")

			for _ in 0..<12 { src.recordSyntheticMoveEventForTesting() }
			logSnapshot("after_moves")
			for _ in 0..<3 { src.recordSyntheticClickEventForTesting() }
			logSnapshot("after_clicks")
			for _ in 0..<8 { src.recordSyntheticMoveEventForTesting() }
			for _ in 0..<2 { src.recordSyntheticScrollEventForTesting() }
			for _ in 0..<4 { src.recordSyntheticClickEventForTesting() }
			logSnapshot("after_burst_mix")

			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
				logSnapshot("after_wait_1s")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
				logSnapshot("after_wait_3s")
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
				logSnapshot("after_wait_6s")
				src.stopMonitoring()
				print("[PointerActivity] selftest finished")
				NSApp.terminate(nil)
			}
			return true
		}

		// Context fusion DEBUG self-test (synthetic metadata-only).
		// Run the app with `CONTEXTUAL_RUN_FUSION_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_FUSION_SELFTEST"] == "1" {
			_ = ContextFusionEngine.shared._selfTest()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Context freshness DEBUG self-test (synthetic metadata-only).
		// Run the app with `CONTEXTUAL_RUN_FRESHNESS_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_FRESHNESS_SELFTEST"] == "1" {
			_ = ContextFusionEngine.shared._freshnessSelfTest()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Rich context debug logger self-test (metadata-only).
		// Run the app with `CONTEXTUAL_RUN_CONTEXT_DEBUG_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_CONTEXT_DEBUG_SELFTEST"] == "1" {
			print("[ContextDebug] selftest starting")
			let ok = ContextDebugLogger.shared.selfTest()
			print("[ContextDebug] selftest finished ok=\(ok)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// T18.5: Chime-in policy self-test (deterministic; no I/O).
		// Run the app with `CONTEXTUAL_RUN_CHIMEIN_SELFTEST=1` to execute once and exit.
		if env["CONTEXTUAL_RUN_CHIMEIN_SELFTEST"] == "1" {
			print("[ChimeInPolicy] selftest starting")
			let policyOk = ContextualChimeInPolicy.runSelfTest()
			let noveltyOk = ProposalNoveltyTracker.runSelfTest()
			let presenterOk = GeneratedExecutionResultPresenter.runSelfTest()
			let ok = policyOk && noveltyOk && presenterOk
			print("[ChimeInPolicy] selftest finished ok=\(ok) policy=\(policyOk) novelty=\(noveltyOk) presenter=\(presenterOk)")
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			return true
		}

		// Run with `CONTEXTUAL_RUN_ACTIVATOR_SELFTEST=1` to validate proposal activation.
		if env["CONTEXTUAL_RUN_ACTIVATOR_SELFTEST"] == "1" {
			let ok = GeneratedExecutionProposalActivatorSelfTest.run()
			print("[GeneratedExecutionProposalActivatorSelfTest] env selftest ok=\(ok)")
			fflush(nil)
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
			return true
		}

		// Run with `CONTEXTUAL_RUN_TASK_INFERENCE_SELFTEST=1` to validate parser + composer (no live AI).
		if env["CONTEXTUAL_RUN_TASK_INFERENCE_SELFTEST"] == "1" {
			Task { @MainActor in
				let ok = await TaskInferenceSelfTest.run()
				print("[TaskInferenceSelfTest] env selftest ok=\(ok)")
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
			}
			return true
		}

		return false
	}
}
