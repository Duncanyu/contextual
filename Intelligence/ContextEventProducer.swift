import AppKit
import Foundation

/// Converts existing Contextual context snapshots into `ContextEvent`s and feeds
/// them into `WorkflowIntelligenceCoordinator`. This is the Phase B.1 wiring —
/// nothing else in the app needs to know about Phase B.
///
/// Design constraints:
/// - Producer NEVER stores raw clipboard contents or full selected text.
/// - OCR is distilled to a small set of repeated topic tokens.
/// - Window titles are stored verbatim only on `ContextEvent` (already
///   user-visible chrome); logs use FNV-1a hashes / truncations.
/// - All work is debounced — no inference is started for every keystroke.
/// - A kill switch (`CONTEXTUAL_WORKFLOW_INTELLIGENCE_ENABLED=0`) disables
///   the entire pipeline cleanly.
@MainActor
final class ContextEventProducer {

    // MARK: - Dependencies

    private let coordinator: WorkflowIntelligenceCoordinator
    private let behavioralCoordinator: BehavioralIntelligenceCoordinator?
    public var onAmbientJarvisSuggestionGenerated: (@Sendable (AmbientJarvisSuggestion?) -> Void)?
	public var onAmbientJarvisSuggestionInvalidated: (@Sendable (_ oldEntity: String, _ newEntity: String) -> Void)?

    // MARK: - Diff state (so we don't emit duplicate events)

    private var lastAppName: String?
    private var lastBundleID: String?
    private var lastTitleHash: String?
    private var lastOCRHash: String?
    private var lastSelectedHash: String?

    // MARK: - Debounce

    private var tickTask: Task<Void, Never>?
    private let debounceSeconds: Double
	private var activeRefreshLoopTask: Task<Void, Never>?
	private var lastObservedWindowTitle: String?
	private var latestWorkflowState: WorkflowState?
	private var latestBehaviorRecord: BehavioralStateRecord?
	private var latestTypingScore: Double = 0.0
	private var latestPointerScore: Double = 0.0
	private var latestDeterminerSignal: DeterminerSignal?
	private var latestActivityState: ActivityState?
	public private(set) var latestSemanticGrounding: SemanticGroundingResult?
	private var lastCheapSuggestionAt: Date?
	private var lastCheapSuggestionKey: String?

    // MARK: - One-shot logging

    private var didLogPrivacyBanner = false
	nonisolated(unsafe) private static var didDeferTickForModelNotReady: Bool = false
	nonisolated(unsafe) private static var didLogTickResumed: Bool = false

    // MARK: - Init

    init(
        coordinator: WorkflowIntelligenceCoordinator,
        behavioralCoordinator: BehavioralIntelligenceCoordinator? = nil,
        debounceSeconds: Double = 2.5
    ) {
        self.coordinator = coordinator
        self.behavioralCoordinator = behavioralCoordinator
        self.debounceSeconds = max(0.5, debounceSeconds)
    }

    // MARK: - Public API

    /// Feed one canonical snapshot to the producer. Diffs against the prior
    /// snapshot, emits only meaningful events, and schedules a debounced tick.
    func ingest(snapshot: CanonicalGeneratedExecutionContextSnapshot, now: Date = Date()) async {

        // Kill switch.
        if !WorkflowIntelligencePipeline.isEnabled {
            WorkflowIntelligencePipeline.logDisabledOnce()
            return
        }
        logPrivacyBannerOnce()

        var producedAny = false

        // 1. activeAppChanged
        let appKey = "\(snapshot.activeApp)|\(snapshot.bundleIdentifier ?? "")"
        let prevAppKey = "\(lastAppName ?? "")|\(lastBundleID ?? "")"
        if appKey != prevAppKey && !snapshot.activeApp.isEmpty {
			// Phase 27.2 — Fix 1: Ignore assistant-opened media side effects
			if isAssistantInitiatedMediaApp(snapshot.activeApp) {
				print("[ContextEventProducer] ignored_system_side_effect=yes app=\(snapshot.activeApp) action=\(AppState.lastAssistantInitiatedAction ?? "none")")
				return
			}

            let event = ContextEvent(
                timestamp: now,
                type: .activeAppChanged,
                appName: snapshot.activeApp,
                bundleIdentifier: snapshot.bundleIdentifier,
                windowTitle: snapshot.windowTitle,
                textHints: [],
                sourceConfidence: 0.95,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.0
            )
            await emit(event)
            lastAppName = snapshot.activeApp
            lastBundleID = snapshot.bundleIdentifier
            producedAny = true

            // Phase 26 — Feed app switch to FrictionEngine + WorkspacePatternTracker
            FrictionEngine.shared.recordAppSwitch(
                appName: snapshot.activeApp,
                bundleID: snapshot.bundleIdentifier,
                now: now
            )
        }

        // 2. windowTitleChanged
        let title = snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		lastObservedWindowTitle = title
        if !title.isEmpty {
            let titleHash = Self.fnv1a(title)
            if titleHash != lastTitleHash {
                let event = ContextEvent(
                    timestamp: now,
                    type: .windowTitleChanged,
                    appName: snapshot.activeApp,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    windowTitle: title,
                    textHints: Self.titleTopicHints(title),
                    sourceConfidence: 0.9,
                    privacyLevel: .publicMetadata,
                    activityIntensity: 0.0
                )
                await emit(event)
                lastTitleHash = titleHash
                producedAny = true
            } else {
                print("[ContextEventProducer] skipped reason=duplicate_event type=windowTitleChanged")
            }
        }

        // 3. ocrAvailable — distill topic tokens, never store raw OCR.
        if let ocrRaw = snapshot.recentOCRExcerpt,
           !ocrRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ocrHash = Self.fnv1a(ocrRaw)
            if ocrHash != lastOCRHash {
                let hints = Self.ocrTopicHints(ocrRaw)
                let event = ContextEvent(
                    timestamp: now,
                    type: .ocrAvailable,
                    appName: snapshot.activeApp,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    windowTitle: title,
                    textHints: hints,
                    sourceConfidence: 0.85,
                    privacyLevel: .redactedSummary,
                    activityIntensity: 0.0
                )
                await emit(event, extra: "chars=\(ocrRaw.count)")
                print("[WorkflowPrivacy] ocr_excerpt_truncated=yes chars=\(min(ocrRaw.count, 0))")
                lastOCRHash = ocrHash
                producedAny = true
            } else {
                print("[ContextEventProducer] skipped reason=duplicate_event type=ocrAvailable")
            }
        }

        // 4. selectedTextChanged — METADATA only. Length is the signal; the
        //    content is never copied into the event or the logs.
        if let selRaw = snapshot.selectedText,
           !selRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let selHash = Self.fnv1a(selRaw)
            if selHash != lastSelectedHash {
                let intensity = min(Double(selRaw.count) / 1000.0, 1.0)
                let event = ContextEvent(
                    timestamp: now,
                    type: .selectedTextChanged,
                    appName: snapshot.activeApp,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    windowTitle: title,
                    textHints: [],
                    sourceConfidence: 0.9,
                    privacyLevel: .restricted,
                    activityIntensity: intensity
                )
                await emit(event, extra: "len_bucket=\(Self.lengthBucket(selRaw.count))")
                lastSelectedHash = selHash
                producedAny = true
            } else {
                print("[ContextEventProducer] skipped reason=duplicate_event type=selectedTextChanged")
            }
        }

        if producedAny {
			let sig = "\(snapshot.bundleIdentifier ?? "")|\(title)"
			await ActiveContextRefresh.shared.noteSignature(sig, now: now)
            scheduleTick(oldInferenceLabel: snapshot.inferredWorkflow.rawValue)
        } else {
            print("[WorkflowPipeline] tick_skipped reason=no_meaningful_events")
        }
    }

	private func isAssistantInitiatedMediaApp(_ appName: String) -> Bool {
	        guard let lastAt = AppState.lastAssistantInitiatedAt else { return false }

	        let now = Date()
	        let recentlyTriggered = now.timeIntervalSince(lastAt) < 15.0 // 15s window
	        let isMediaApp = appName == "Music" || appName == "Spotify" || appName.lowercased().contains("music")

	let isKnownLaunch = (appName == AppState.lastAssistantInitiatedAppLaunch)
	let isMusicAction = (AppState.lastAssistantInitiatedAction == EnvironmentActionType.playFocusMedia.rawValue)

	        return recentlyTriggered && isMediaApp && (isKnownLaunch || isMusicAction)
	}
    /// Direct event passthrough — used by the typing/pointer/proposal hooks
    /// when they want to feed events without going through a snapshot.
    func ingest(event: ContextEvent, oldInferenceLabel: String? = nil) async {
        if !WorkflowIntelligencePipeline.isEnabled {
            WorkflowIntelligencePipeline.logDisabledOnce()
            return
        }
        await emit(event)
        scheduleTick(oldInferenceLabel: oldInferenceLabel)
    }

    /// Record that the user accepted a proposal (used by the inference packet).
    func recordProposalAccepted(_ title: String) async {
        await coordinator.recordProposalAccepted(title)
    }

    /// Record that the user dismissed/ignored a proposal.
    func recordProposalDismissed(_ title: String) async {
        await coordinator.recordProposalDismissed(title)
    }

    // Actor-isolated state for concurrency control
    private var inferenceInFlight: Bool = false
    private var tickPending: Bool = false

    // MARK: - Internal emission

    private func emit(_ event: ContextEvent, extra: String = "") async {
        await coordinator.recordEvent(event)

        let hashPrefix = Self.fnv1a(event.windowTitle).prefix(8)
        let extras = extra.isEmpty ? "" : " \(extra)"
        print("[ContextEventProducer] produced type=\(event.type.rawValue) app=\(event.appName) title_hash=\(hashPrefix)\(extras)")
        print("[WorkflowPipeline] event_recorded type=\(event.type.rawValue)")
    }

    private func scheduleTick(oldInferenceLabel: String?) {
        tickTask?.cancel()
        let delayMs = Int(debounceSeconds * 1000)
        print("[WorkflowPipeline] tick_scheduled delay_ms=\(delayMs) reason=meaningful_event")
        let oldLabel = oldInferenceLabel
        let delay = debounceSeconds
        tickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self else { return }

            if self.inferenceInFlight {
                self.tickPending = true
                print("[WorkflowPipeline] tick_coalesced reason=inference_in_flight")
                return
            }

            await self.executeTick(oldInferenceLabel: oldLabel)
        }
    }

    private func executeTick(oldInferenceLabel: String?) async {
        inferenceInFlight = true
        tickPending = false
        defer {
            inferenceInFlight = false
            if tickPending {
                print("[WorkflowPipeline] pending_tick_started reason=coalesced_updates")
                scheduleTick(oldInferenceLabel: oldInferenceLabel)
            }
        }

		let startupQuiet = ModelManager.shared.isWithinStartupQuietPeriod()
		let launchElapsed = ModelManager.shared.secondsSinceLaunch()

        // Phase 26.3 — Startup quiet period defers heavy inference only.
        if startupQuiet {
            let elapsed = launchElapsed ?? 0
            print("[StartupBudget] heavy_inference_deferred reason=startup_quiet_period elapsed_s=\(elapsed)")
			let modelReady = await ModelManager.shared.isGenerationAvailable()
			let cheap = await runCheapAlwaysOnPortfolio(
				reason: "startup_quiet_period",
				modelReady: modelReady,
				startupQuiet: true,
				workflowState: nil,
				behaviorRecord: nil,
				launchElapsedSeconds: launchElapsed
			)
			if let suggestion = cheap.suggestion {
				self.onAmbientJarvisSuggestionGenerated?(suggestion)
				await ActiveContextRefresh.shared.noteSuggestion()
			}
			logSuggestionTickSummary(
				modelReady: modelReady,
				startupQuiet: true,
				workflow: .unknown,
				workflowActionable: false,
				determinerActionable: cheap.determinerActionable,
				cheapPortfolioRan: cheap.ran,
				heavyPlannerRan: false,
				candidatesCount: cheap.candidatesCount,
				selected: cheap.selected,
				surfaceResult: cheap.suggestion == nil ? "suppressed" : "shown",
				suppressionReason: cheap.suggestion == nil ? cheap.suppressionReason : "none"
			)
            return
        }

        // Phase B.1.8 — Gate workflow inference on model readiness.
        let ready = await ModelManager.shared.isGenerationAvailable()
        if !ready {
            Self.didDeferTickForModelNotReady = true
            print("[WorkflowPipeline] tick_deferred reason=model_not_ready")
			let cheap = await runCheapAlwaysOnPortfolio(
				reason: "model_unavailable",
				modelReady: false,
				startupQuiet: false,
				workflowState: nil,
				behaviorRecord: nil,
				launchElapsedSeconds: launchElapsed
			)
			if let suggestion = cheap.suggestion {
				self.onAmbientJarvisSuggestionGenerated?(suggestion)
				await ActiveContextRefresh.shared.noteSuggestion()
			}
			logSuggestionTickSummary(
				modelReady: false,
				startupQuiet: false,
				workflow: .unknown,
				workflowActionable: false,
				determinerActionable: cheap.determinerActionable,
				cheapPortfolioRan: cheap.ran,
				heavyPlannerRan: false,
				candidatesCount: cheap.candidatesCount,
				selected: cheap.selected,
				surfaceResult: cheap.suggestion == nil ? "suppressed" : "shown",
				suppressionReason: cheap.suggestion == nil ? cheap.suppressionReason : "none"
			)
            return
        }
        if Self.didDeferTickForModelNotReady, !Self.didLogTickResumed {
            Self.didLogTickResumed = true
            print("[WorkflowPipeline] tick_resumed reason=model_ready")
        }

        // Phase B.1.8 — Single local model lane backpressure.
        let acquired = await LocalAIBackpressure.shared.acquire(purpose: "workflow_inference")
        if !acquired {
            print("[LocalAIBackpressure] deferred workflow_inference reason=goal_generator_active")
			logSuggestionTickSummary(
				modelReady: true,
				startupQuiet: false,
				workflow: latestWorkflowState?.workflowType ?? .unknown,
				workflowActionable: {
					let workflow = latestWorkflowState?.workflowType ?? .unknown
					return workflow != .unknown && workflow != .idle
				}(),
				determinerActionable: latestDeterminerSignal?.actionable ?? false,
				cheapPortfolioRan: false,
				heavyPlannerRan: false,
				candidatesCount: 0,
				selected: nil,
				surfaceResult: "suppressed",
				suppressionReason: "model_backpressure"
			)
            return
        }
        defer {
            Task { await LocalAIBackpressure.shared.release(purpose: "workflow_inference") }
        }

        print("[WorkflowPipeline] tick_started")
        let state = await coordinator.tick(now: Date(), oldInferenceLabel: oldInferenceLabel)
        let confStr = String(format: "%.2f", state.confidence)
        print("[WorkflowPipeline] tick_completed workflow=\(state.workflowType.rawValue) confidence=\(confStr)")

        if let behavioral = self.behavioralCoordinator {
            let events = await coordinator.getEventStreamSnapshot()
            let buffer = TemporalContextBuffer.build(from: events, now: Date())
            latestTypingScore = buffer.short.typingScore
            latestPointerScore = buffer.short.pointerScore
            let stabilized = await behavioral.tick(
                workflowState: state,
                shortWindow: buffer.short,
                now: Date()
            )
                
                // Phase 20D.5 — eligibility is now any workflow + behavior
                // that are both actionable (neither `.unknown` nor `.idle`).
                // The actual gate still lives inside JarvisSuggestionGenerator;
                // this is just the user-visible "I would have surfaced but the
                // mode is off" trace.
                let workflowActionable = state.workflowType != .unknown && state.workflowType != .idle
                let behaviorActionable = stabilized.state != .unknown && stabilized.state != .idle
                let isEligible = workflowActionable && behaviorActionable
                if isEligible && !AmbientMVPMode.isEnabled {
                    print("[AmbientMVPMode] warning=eligible_context_but_mode_disabled workflow=\(state.workflowType.rawValue) behavior=\(stabilized.state.rawValue)")
                }

                if AmbientMVPMode.isEnabled {
                    let compressor = TemporalContextCompressor.compress(buffer: buffer)

					// Phase 22.1 — Active-app-first context source (Task C / Task G).
					// Use lastAppName (updated synchronously on activeAppChanged) rather
					// than compressor.currentApp which may lag by one temporal buffer.
					let currentAppName = self.lastAppName ?? compressor.currentApp
					let appContext = AppContextAnalyzer.analyze(
						appName: currentAppName,
						bundleID: self.lastBundleID,
						windowTitle: self.lastObservedWindowTitle
					)
					print("[ContextSourcePriority] app=\"\(currentAppName)\""
						+ " category=\(appContext.category.rawValue)"
						+ " is_browser=\(appContext.isBrowser)")

					let browser: BrowserContextExtractor.BrowserContext?
					if appContext.isBrowser {
						print("[ContextSourcePriority] primary_source=browser")
						browser = BrowserContextExtractor.extract(appName: currentAppName, activeAppPID: nil)
					} else {
						print("[ContextSourcePriority] primary_source=active_app browser_skipped=yes")
						browser = nil
					}

					let tabTitles = browser?.recentTabTitles ?? []
					let selectedTitle = browser?.selectedTitle
					let selectedURLFound = browser?.selectedURL != nil
					var focusShift = false
					var focusObs: FocusEpochTracker.Observation?
					if let st = selectedTitle, !st.isEmpty {
						print("[CurrentContext] selected_tab_priority=yes")
						let obs = FocusEpochTracker.shared.observeSelectedTab(
							title: st,
							workflowLabel: state.workflowType.rawValue
						)
						focusObs = obs
						print("[CurrentContext] selected_terms=\(obs.selectedTerms.joined(separator: ","))")
						print("[BrowserTabs] selected_url_found=\(selectedURLFound ? "yes" : "no")")
						print("[BrowserTabs] selected_tab_age_s=\(obs.selectedAgeSeconds)")
						if obs.focusShiftDetected {
							focusShift = true
							self.onAmbientJarvisSuggestionInvalidated?(obs.previousEntity ?? "", obs.currentEntity)
							print("[JarvisSuggestion] invalidated reason=focus_shift")
						}
					}

					let effective: FocusOverride.Decision = {
						guard let obs = focusObs else {
							return FocusOverride.Decision(
								applied: false,
								effectiveWorkflow: state,
								effectiveBehavior: stabilized,
								reason: "no_focus_observation"
							)
						}
						return FocusOverride.applyIfNeeded(
							workflowState: state,
							behavioralRecord: stabilized,
							focusObservation: obs,
							recentTabTitles: tabTitles
						)
					}()

					if effective.applied {
						print("[FocusOverride] applied=yes old_workflow=\(state.workflowType.rawValue) new_workflow=\(effective.effectiveWorkflow.workflowType.rawValue) reason=\(effective.reason)")
						print("[FocusOverride] old_behavior=\(stabilized.state.rawValue) new_behavior=\(effective.effectiveBehavior.state.rawValue) reason=\(effective.reason)")
					}

					let groundingURL: URL? = browser?.selectedURL ?? browser?.currentURL
					let groundingInput = SemanticGroundingInput(
						appName: currentAppName,
						bundleId: self.lastBundleID ?? "",
						windowTitle: self.lastObservedWindowTitle ?? "",
						url: groundingURL,
						browserSelectedTitle: selectedTitle,
						browserSelectedURL: browser?.selectedURL,
						tabTitles: tabTitles,
						axTextSnippet: nil,
						selectedTextSnippet: nil,
						recentCompartment: await TaskCompartmentTracker.shared.getActiveCompartment(),
						recentAppSwitches: []
					)
					let groundingResult = await SemanticGroundingEngine.shared.ground(input: groundingInput)
					self.latestSemanticGrounding = groundingResult

					// Phase 27.2 — Fix 5: Grounding drives workflow state
					let effectiveWorkflow: WorkflowState = {
						if groundingResult.confidence >= 0.90,
						   let groundedType = AmbientWorkflowType(rawValue: groundingResult.domain),
						   groundedType != .unknown && groundedType != .idle {
							print("[WorkflowState] source=semantic_grounding type=\(groundedType.rawValue) confidence=\(groundingResult.confidence)")
							return WorkflowState(
								workflowType: groundedType,
								confidence: groundingResult.confidence,
								evidence: ["semantic_grounding"],
								uncertainty: "none",
								startedAt: Date(),
								lastUpdatedAt: Date(),
								stabilityScore: 0.95,
								dominantApps: [currentAppName],
								repeatedTerms: [],
								recentTransitions: [],
								suggestedIntentHints: [],
								sourcePacketHash: "semantic_grounding"
							)
						}
						return effective.effectiveWorkflow
					}()

					let activeComp = await TaskCompartmentTracker.shared.ingestUpdate(
						workflow: effectiveWorkflow.workflowType,
						behavior: effective.effectiveBehavior.state,
						title: selectedTitle ?? compressor.recentTitles.first ?? "",
						tabs: tabTitles,
						topicTerms: compressor.topicTerms,
						grounding: groundingResult
					)
					let allComps = await TaskCompartmentTracker.shared.compartments

					let memory = WorkingMemoryBuilder.build(
						workflow: effectiveWorkflow,
						behavior: effective.effectiveBehavior,
						packet: compressor,
						browserTabTitles: tabTitles,
						selectedBrowserTabTitle: selectedTitle,
						activeCompartment: activeComp,
						allCompartments: allComps
					)
					// Phase 21.2 — Evaluate DeterminerSignal every tick so the
					// live Jarvis path can escape workflow=unknown suppression
					// when compartment/memory context is already strong.
					// Phase 21.4 — Derive ActivityState from buffer scores + dwell.
					let activityState = ActivityState.derive(
						typingScore: buffer.short.typingScore,
						pointerScore: buffer.short.pointerScore,
						dwellSeconds: activeComp.dwellSeconds,
						hadRecentNavigation: !tabTitles.isEmpty
					)
					let determinerSignal = DeterminerSignal.evaluate(
						memory: memory,
						compartment: activeComp,
						workflowConfidence: effective.effectiveWorkflow.confidence,
						behaviorConfidence: effective.effectiveBehavior.confidence,
						browserTabCount: tabTitles.count,
						hasSelectedURL: selectedURLFound,
						activeTerms: memory.repeatedConcepts,
						currentEntity: memory.currentEntity,
						activityState: activityState,
						grounding: groundingResult
					)
					print("[DeterminerSignal] evaluated=yes actionable=\(determinerSignal.actionable ? "yes" : "no")")
					self.latestDeterminerSignal = determinerSignal
					self.latestActivityState = activityState

						// Phase 22.1/22.2 — Entity grounding + lookup (Tasks A, E, F).

					// Fire background metadata fetch for current URL (populates cache for next tick)
					if let gurl = groundingURL {
						EntityLookupLayer.prefetchIfNeeded(url: gurl, entityName: memory.currentEntity)
					} else {
						print("[EntityLookup] skipped reason=no_url entity=\"\(memory.currentEntity.prefix(40))\"")
					}

					// Enrich with cached lookup result if available
					let lookupResult = groundingURL.flatMap { EntityLookupLayer.cachedResult(for: $0) }
					if let lr = lookupResult {
						print("[EntityLookup] source=cache"
							+ " type=\(lr.entityType.rawValue)"
							+ " confidence=\(String(format: "%.2f", lr.confidence))"
							+ " will_influence_grounding=\(lr.confidence >= 0.65 ? "yes" : "no")")
					}

					let grounding = EntityGroundingLayer.ground(
						title: memory.currentEntity,
						url: groundingURL,
						appCategory: appContext.category,
						memory: memory,
						compartment: activeComp,
						lookupResult: lookupResult
					)

					// Phase 22.2 — Semantic priority resolution (Task E).
					// EntityGrounding > DeterminerSignal > Compartment > Workflow
					let workflowRaw = effective.effectiveWorkflow.workflowType.rawValue
					let semanticState = SemanticPriorityResolver.resolve(
						grounding: grounding,
						determinerSignal: determinerSignal,
						compartment: activeComp,
						workflowTypeRaw: workflowRaw
					)

					// Phase 26 — Feed concepts and tabs to FrictionEngine + WorkspacePatternTracker
					FrictionEngine.shared.recordConcepts(
					        memory.repeatedConcepts,
					        appName: currentAppName,
					        bundleID: self.lastBundleID,
					        windowTitle: self.lastObservedWindowTitle
					)
					do {
						let compID = activeComp.id.uuidString
						WorkspacePatternTracker.shared.recordApp(
							appName: self.lastAppName ?? compressor.currentApp,
							bundleID: self.lastBundleID,
							compartmentID: compID
						)
						WorkspacePatternTracker.shared.recordConcepts(
							memory.repeatedConcepts, compartmentID: compID)
						if let gurl = groundingURL {
							WorkspacePatternTracker.shared.recordURL(
								gurl.absoluteString, compartmentID: compID)
						}
						// Consolidate workspace pattern when compartment is settled
						if activeComp.dwellSeconds > 300 {
							WorkspacePatternTracker.shared.consolidate(
								compartmentID: compID,
								dwellMinutes: activeComp.dwellSeconds / 60.0)
						}
						}
						if let selectedTitle, !selectedTitle.isEmpty {
							FrictionEngine.shared.recordTabVisit(title: selectedTitle)
						}

					// Phase 26 — Detect friction signals
					let frictionSignals = FrictionEngine.shared.detectFriction()

					// Phase 26.2 — Derive media state before OpportunityEngine so portfolio can use it.
					let contextualMediaState = EnvironmentMediaState.derived(
						activeApp: compressor.currentApp,
						recentApps: compressor.recentApps,
						currentEntity: memory.currentEntity,
						entityType: semanticState.entityType,
						domain: semanticState.domain,
						behavior: effective.effectiveBehavior.state
					)
					let mediaSnapshot = MediaStateSource.currentSnapshot()
					let environmentMediaState = contextualMediaState.withMusicPlayback(
						isPlaying: mediaSnapshot.detectionAvailable ? mediaSnapshot.isMusicPlaying : contextualMediaState.isMusicPlaying,
						detectionAvailable: mediaSnapshot.detectionAvailable,
						source: mediaSnapshot.detectionAvailable ? "\(mediaSnapshot.source):\(mediaSnapshot.reason)" : "\(contextualMediaState.source):\(mediaSnapshot.reason)"
					)
					PassivePlaylistObserver.shared.tick(
						isMusicPlaying: environmentMediaState.isMusicPlaying,
						compartment: activeComp,
						workflow: activeComp.workflow
					)

						// Phase 22 — OpportunityEngine: dynamic reasoning, zero model calls.
						let hasRecentSelection = Self.hasRecentSelectionEvidence(in: compressor)
						let evidenceQualityTick = Self.evidenceQuality(
							hasSelection: hasRecentSelection,
							hasOCRHints: !compressor.ocrHints.isEmpty,
							hasBrowserContext: selectedURLFound,
							appCategory: appContext.category,
							groundingResult: groundingResult,
							compartment: activeComp
						)
					let groundingKey = groundingURL?.absoluteString ?? memory.currentEntity
					let opportunities = await OpportunityEngine.evaluate(
					        determinerSignal: determinerSignal,
					        activityState: activityState,
					        compartment: activeComp,
					        memory: memory,
					        evidenceQuality: evidenceQualityTick,
					        entityGrounding: grounding,
					        semanticState: semanticState,
					        entityKey: groundingKey,
					        frictionSignals: frictionSignals,
					        mediaState: environmentMediaState,
					        appCategory: appContext.category,
					        groundingResult: groundingResult
					)

					let topOpportunity = opportunities.first
					print("[PerformanceBudget] allowed model=yes ax=no ocr=no visual=no")
					print("[OpportunityBudget] deterministic=yes opportunities_count=\(opportunities.count)")

						let jarvisSuggestion = await JarvisSuggestionGenerator.generate(
							workflowState: effective.effectiveWorkflow,
							behavioralRecord: effective.effectiveBehavior,
							packet: compressor,
							recentTitles: buffer.short.recentTitles,
							repeatedTerms: buffer.short.repeatedTerms,
							memory: memory,
							hasSelection: hasRecentSelection,
							activeCompartment: activeComp,
							determinerSignal: determinerSignal,
							semanticDomain: semanticState.domain,
							semanticMode: semanticState.mode,
							semanticEntityType: semanticState.entityType,
							semanticEntityConfidence: semanticState.entityConfidence,
							mediaStateOverride: environmentMediaState,
							topOpportunity: topOpportunity,
							entityGrounding: grounding
						)
						var suggestion = jarvisSuggestion
						var cheapFallback: CheapPortfolioRun = .notRun(reason: "heavy_path_succeeded")
						if suggestion == nil {
							cheapFallback = await runCheapAlwaysOnPortfolio(
								reason: effective.effectiveWorkflow.workflowType == .unknown ? "unknown_but_context_trusted" : "jarvis_suppressed",
								modelReady: true,
								startupQuiet: false,
								workflowState: effective.effectiveWorkflow,
								behaviorRecord: effective.effectiveBehavior,
								launchElapsedSeconds: launchElapsed
							)
							if let cheapSuggestion = cheapFallback.suggestion {
								suggestion = cheapSuggestion
								print("[JarvisPipeline] decision=shown reason=cheap_always_on")
							}
						}
					if focusShift && suggestion != nil {
						print("[JarvisPipeline] regenerated reason=focus_shift")
					}
                    self.onAmbientJarvisSuggestionGenerated?(suggestion)
					self.latestWorkflowState = effective.effectiveWorkflow
					self.latestBehaviorRecord = effective.effectiveBehavior
						await ActiveContextRefresh.shared.noteWorkflowAndBehavior(
							workflow: effective.effectiveWorkflow.workflowType,
							behavior: effective.effectiveBehavior.state,
							evidenceQuality: evidenceQualityTick
						)
						if suggestion != nil {
							await ActiveContextRefresh.shared.noteSuggestion()
						}
						logSuggestionTickSummary(
							modelReady: true,
							startupQuiet: false,
							workflow: effective.effectiveWorkflow.workflowType,
							workflowActionable: effective.effectiveWorkflow.workflowType != .unknown && effective.effectiveWorkflow.workflowType != .idle,
							determinerActionable: determinerSignal.actionable,
							cheapPortfolioRan: cheapFallback.ran,
							heavyPlannerRan: true,
							candidatesCount: opportunities.count + cheapFallback.candidatesCount,
							selected: suggestion?.topOpportunity?.capabilityId ?? cheapFallback.selected ?? "none",
							surfaceResult: suggestion == nil ? "suppressed" : "shown",
							suppressionReason: suggestion == nil ? cheapFallback.suppressionReason : "none"
						)
						self.ensureActiveRefreshLoop()
                }
            }
    }

	// MARK: - ActiveContextRefresh loop (Phase 20G.4)

	private func ensureActiveRefreshLoop() {
		guard activeRefreshLoopTask == nil else { return }
		activeRefreshLoopTask = Task { @MainActor [weak self] in
			guard let self else { return }
			while !Task.isCancelled {
				// Adaptive cadence: wake infrequently unless a refresh is near-due.
				try? await Task.sleep(nanoseconds: 8_000_000_000) // 8s baseline cadence
				if Task.isCancelled { break }
				if !AmbientMVPMode.isEnabled { continue }

				// Phase 21.4 — Pass ActivityState + dwell into tick() so the
				// dwell-based refresh trigger can fire for canvas-type apps.
				let refreshActiveComp = await TaskCompartmentTracker.shared.getActiveCompartment()
				let refreshDwellSecs = refreshActiveComp?.dwellSeconds ?? 0
				let loopActivityState = ActivityState.derive(
					typingScore: self.latestTypingScore,
					pointerScore: self.latestPointerScore,
					dwellSeconds: refreshDwellSecs
				)
					let decision = await ActiveContextRefresh.shared.tick(
						now: Date(),
						modelBusy: self.inferenceInFlight,
						determinerSignal: self.latestDeterminerSignal,
						activityState: self.latestActivityState ?? loopActivityState,
						compartmentDwellSeconds: refreshDwellSecs
					)
				guard decision.action == .refresh || decision.cheapEnvironmentAllowed else { continue }

				let app = self.lastAppName ?? (NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown")
				let bundle = self.lastBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier

				// Phase 25.5 — Task D: Suppression for assistant side-effects.
				if let lastLaunch = AppState.lastAssistantInitiatedAppLaunch, let lastAt = AppState.lastAssistantInitiatedAt {
					let age = Date().timeIntervalSince(lastAt)
					let appMatches = app.lowercased().contains(lastLaunch.lowercased()) || lastLaunch.lowercased().contains(app.lowercased())
					
					if age < 10.0 && appMatches {
						print("[TaskCompartment] ignored app=\"\(app)\" reason=assistant_initiated_environment_action")
						print("[ContextEventProducer] ignored_system_side_effect=yes action=\(AppState.lastAssistantInitiatedAction ?? "unknown") app=\(app)")
						continue
					} else if age >= 10.0 || !appMatches {
						// Grace period expired or user switched to a different app
						AppState.lastAssistantInitiatedAppLaunch = nil
						AppState.lastAssistantInitiatedAt = nil
					}
				}

				let title = self.lastObservedWindowTitle
				
				var refreshedTabTitles: [String] = []
				if decision.action == .refresh {
					print("[ActiveContextRefresh] started tier=cheap")
					let refresh = await ActiveContextRefresh.shared.performRefresh(
						activeApp: app,
						windowTitle: title,
						bundleIdentifier: bundle
					)
					refreshedTabTitles = refresh.tabTitles
					print("[ActiveContextRefresh] focus_refresh=yes")
				} else {
					print("[ActiveContextRefresh] environment_eval=yes")
				}

				guard let workflowState = self.latestWorkflowState,
					  let behaviorRecord = self.latestBehaviorRecord else {
					print("[ActiveContextRefresh] jarvis_refresh=no reason=no_latest_state")
					continue
				}

				let events = await self.coordinator.getEventStreamSnapshot()
				let buffer = TemporalContextBuffer.build(from: events, now: Date())
				let compressor = TemporalContextCompressor.compress(buffer: buffer)

				// Phase 22.1 — Active-app-first in refresh loop too.
				let refreshCurrentApp = self.lastAppName ?? compressor.currentApp
				let refreshAppContext = AppContextAnalyzer.analyze(
					appName: refreshCurrentApp,
					bundleID: self.lastBundleID,
					windowTitle: self.lastObservedWindowTitle
				)
				print("[ContextSourcePriority] app=\"\(refreshCurrentApp)\""
					+ " category=\(refreshAppContext.category.rawValue)"
					+ " is_browser=\(refreshAppContext.isBrowser)"
					+ " path=refresh_loop")

				let browser: BrowserContextExtractor.BrowserContext?
				if refreshAppContext.isBrowser {
					print("[ContextSourcePriority] primary_source=browser path=refresh_loop")
					browser = BrowserContextExtractor.extract(appName: refreshCurrentApp, activeAppPID: nil)
				} else {
					print("[ContextSourcePriority] primary_source=active_app browser_skipped=yes path=refresh_loop")
					browser = nil
				}

				let tabTitles = browser?.recentTabTitles ?? refreshedTabTitles
				let selectedTitle = browser?.selectedTitle
				let focusObs: FocusEpochTracker.Observation? = {
					guard let st = selectedTitle, !st.isEmpty else { return nil }
					return FocusEpochTracker.shared.observeSelectedTab(title: st, workflowLabel: workflowState.workflowType.rawValue)
				}()

				let effective: FocusOverride.Decision = {
					guard let obs = focusObs else {
						return FocusOverride.Decision(applied: false, effectiveWorkflow: workflowState, effectiveBehavior: behaviorRecord, reason: "no_focus_observation")
					}
					return FocusOverride.applyIfNeeded(
						workflowState: workflowState,
						behavioralRecord: behaviorRecord,
						focusObservation: obs,
						recentTabTitles: tabTitles
					)
				}()
				if effective.applied {
					print("[FocusOverride] applied=yes old_workflow=\(workflowState.workflowType.rawValue) new_workflow=\(effective.effectiveWorkflow.workflowType.rawValue) reason=\(effective.reason)")
					print("[FocusOverride] old_behavior=\(behaviorRecord.state.rawValue) new_behavior=\(effective.effectiveBehavior.state.rawValue) reason=\(effective.reason)")
				}

				let groundingURL = browser?.selectedURL ?? browser?.currentURL
				let groundingInput = SemanticGroundingInput(
					appName: refreshCurrentApp,
					bundleId: self.lastBundleID ?? "",
					windowTitle: self.lastObservedWindowTitle ?? "",
					url: groundingURL,
					browserSelectedTitle: selectedTitle,
					browserSelectedURL: browser?.selectedURL,
					tabTitles: tabTitles,
					axTextSnippet: nil,
					selectedTextSnippet: nil,
					recentCompartment: await TaskCompartmentTracker.shared.getActiveCompartment(),
					recentAppSwitches: []
				)
				let groundingResult = await SemanticGroundingEngine.shared.ground(input: groundingInput)
				self.latestSemanticGrounding = groundingResult

				let activeComp = await TaskCompartmentTracker.shared.ingestUpdate(
					workflow: effective.effectiveWorkflow.workflowType,
					behavior: effective.effectiveBehavior.state,
					title: selectedTitle ?? compressor.recentTitles.first ?? "",
					tabs: tabTitles,
					topicTerms: compressor.topicTerms,
					grounding: groundingResult
				)
				let allComps = await TaskCompartmentTracker.shared.compartments

				let memory = WorkingMemoryBuilder.build(
					workflow: effective.effectiveWorkflow,
					behavior: effective.effectiveBehavior,
					packet: compressor,
					browserTabTitles: tabTitles,
					selectedBrowserTabTitle: selectedTitle,
					activeCompartment: activeComp,
					allCompartments: allComps
				)

				// Phase 21.2 — DeterminerSignal in refresh loop.
				// Phase 21.4 — Derive ActivityState for refresh path too.
				let refreshActivityState = ActivityState.derive(
					typingScore: buffer.short.typingScore,
					pointerScore: buffer.short.pointerScore,
					dwellSeconds: activeComp.dwellSeconds,
					hadRecentNavigation: !tabTitles.isEmpty
				)
				let refreshDeterminer = DeterminerSignal.evaluate(
					memory: memory,
					compartment: activeComp,
					workflowConfidence: effective.effectiveWorkflow.confidence,
					behaviorConfidence: effective.effectiveBehavior.confidence,
					browserTabCount: tabTitles.count,
					hasSelectedURL: browser?.currentURL != nil,
					activeTerms: memory.repeatedConcepts,
					currentEntity: memory.currentEntity,
					activityState: refreshActivityState,
					grounding: groundingResult
					)
					print("[DeterminerSignal] evaluated=yes actionable=\(refreshDeterminer.actionable ? "yes" : "no")")
					print("[ActiveContextRefresh] determiner_actionable=\(refreshDeterminer.actionable ? "yes" : "no")")
					self.latestDeterminerSignal = refreshDeterminer
					self.latestActivityState = refreshActivityState

					print("[ActiveContextRefresh] jarvis_refresh=yes reason=stable_meaningful_context")
					// Phase 22/22.2 — Entity grounding + semantic priority + dynamic reasoning.
					let refreshHasRecentSelection = Self.hasRecentSelectionEvidence(in: compressor)
					let refreshEvidenceQuality = Self.evidenceQuality(
						hasSelection: refreshHasRecentSelection,
						hasOCRHints: !compressor.ocrHints.isEmpty,
						hasBrowserContext: browser?.currentURL != nil,
						appCategory: refreshAppContext.category,
						groundingResult: groundingResult,
						compartment: activeComp
					)
				let refreshGroundingURL: URL? = browser?.selectedURL ?? browser?.currentURL

				if let gurl = refreshGroundingURL {
					EntityLookupLayer.prefetchIfNeeded(url: gurl, entityName: memory.currentEntity)
				} else {
					print("[EntityLookup] skipped reason=no_url entity=\"\(memory.currentEntity.prefix(40))\"")
				}
				let refreshLookupResult = refreshGroundingURL.flatMap { EntityLookupLayer.cachedResult(for: $0) }
				if let lr = refreshLookupResult {
					print("[EntityLookup] source=cache"
						+ " type=\(lr.entityType.rawValue)"
						+ " confidence=\(String(format: "%.2f", lr.confidence))"
						+ " will_influence_grounding=\(lr.confidence >= 0.65 ? "yes" : "no")")
				}

				let refreshGrounding = EntityGroundingLayer.ground(
					title: memory.currentEntity,
					url: refreshGroundingURL,
					appCategory: refreshAppContext.category,
					memory: memory,
					compartment: activeComp,
					lookupResult: refreshLookupResult
				)
				let refreshSemanticState = SemanticPriorityResolver.resolve(
					grounding: refreshGrounding,
					determinerSignal: refreshDeterminer,
					compartment: activeComp,
					workflowTypeRaw: effective.effectiveWorkflow.workflowType.rawValue
				)
				// Phase 26 — Feed concepts and tabs to FrictionEngine + WorkspacePatternTracker (refresh path)
				FrictionEngine.shared.recordConcepts(
				        memory.repeatedConcepts,
				        appName: self.lastAppName ?? compressor.currentApp,
				        bundleID: self.lastBundleID,
				        windowTitle: self.lastObservedWindowTitle
				)
				do {
					let compID = activeComp.id.uuidString
					WorkspacePatternTracker.shared.recordApp(
						appName: self.lastAppName ?? compressor.currentApp,
						bundleID: self.lastBundleID,
						compartmentID: compID
					)
					WorkspacePatternTracker.shared.recordConcepts(
						memory.repeatedConcepts, compartmentID: compID)
					if let gurl = refreshGroundingURL {
						WorkspacePatternTracker.shared.recordURL(
							gurl.absoluteString, compartmentID: compID)
					}
					if activeComp.dwellSeconds > 300 {
						WorkspacePatternTracker.shared.consolidate(
							compartmentID: compID,
							dwellMinutes: activeComp.dwellSeconds / 60.0)
					}
					}
					if let selectedTitle, !selectedTitle.isEmpty {
						FrictionEngine.shared.recordTabVisit(title: selectedTitle)
					}
				let refreshFrictionSignals = FrictionEngine.shared.detectFriction()

				// Phase 26.2 — Build media state before evaluate so portfolio can use it
				let refreshContextualMediaState = EnvironmentMediaState.derived(
					activeApp: compressor.currentApp,
					recentApps: compressor.recentApps,
					currentEntity: memory.currentEntity,
					entityType: refreshSemanticState.entityType,
					domain: refreshSemanticState.domain,
					behavior: effective.effectiveBehavior.state
				)
				let refreshMediaSnapshot = MediaStateSource.currentSnapshot()
				let refreshEnvironmentMediaState = refreshContextualMediaState.withMusicPlayback(
					isPlaying: refreshMediaSnapshot.detectionAvailable ? refreshMediaSnapshot.isMusicPlaying : refreshContextualMediaState.isMusicPlaying,
					detectionAvailable: refreshMediaSnapshot.detectionAvailable,
					source: refreshMediaSnapshot.detectionAvailable ? "\(refreshMediaSnapshot.source):\(refreshMediaSnapshot.reason)" : "\(refreshContextualMediaState.source):\(refreshMediaSnapshot.reason)"
				)
				PassivePlaylistObserver.shared.tick(
					isMusicPlaying: refreshEnvironmentMediaState.isMusicPlaying,
					compartment: activeComp,
					workflow: activeComp.workflow
				)

				let refreshGroundingKey = refreshGroundingURL?.absoluteString ?? memory.currentEntity
				let refreshOpportunities = await OpportunityEngine.evaluate(
				        determinerSignal: refreshDeterminer,
				        activityState: refreshActivityState,
				        compartment: activeComp,
				        memory: memory,
				        evidenceQuality: refreshEvidenceQuality,
				        entityGrounding: refreshGrounding,
				        semanticState: refreshSemanticState,
				        entityKey: refreshGroundingKey,
				        frictionSignals: refreshFrictionSignals,
				        mediaState: refreshEnvironmentMediaState,
				        appCategory: refreshAppContext.category,
				        groundingResult: groundingResult
				)

					print("[OpportunityBudget] deterministic=yes opportunities_count=\(refreshOpportunities.count)")
					let jarvisRefreshSuggestion = await JarvisSuggestionGenerator.generate(
						workflowState: effective.effectiveWorkflow,
						behavioralRecord: effective.effectiveBehavior,
						packet: compressor,
						recentTitles: buffer.short.recentTitles,
						repeatedTerms: buffer.short.repeatedTerms,
						memory: memory,
						hasSelection: refreshHasRecentSelection,
						activeCompartment: activeComp,
						determinerSignal: refreshDeterminer,
						semanticDomain: refreshSemanticState.domain,
						semanticMode: refreshSemanticState.mode,
						semanticEntityType: refreshSemanticState.entityType,
						semanticEntityConfidence: refreshSemanticState.entityConfidence,
						mediaStateOverride: refreshEnvironmentMediaState,
						topOpportunity: refreshOpportunities.first,
						entityGrounding: refreshGrounding
					)
					var suggestion = jarvisRefreshSuggestion
					var cheapFallback: CheapPortfolioRun = .notRun(reason: "refresh_heavy_path_succeeded")
					if suggestion == nil {
						cheapFallback = await self.runCheapAlwaysOnPortfolio(
							reason: effective.effectiveWorkflow.workflowType == .unknown ? "unknown_but_context_trusted" : "refresh_jarvis_suppressed",
							modelReady: true,
							startupQuiet: false,
							workflowState: effective.effectiveWorkflow,
							behaviorRecord: effective.effectiveBehavior,
							launchElapsedSeconds: ModelManager.shared.secondsSinceLaunch()
						)
						if let cheapSuggestion = cheapFallback.suggestion {
							suggestion = cheapSuggestion
							print("[JarvisPipeline] decision=shown reason=cheap_always_on")
						}
					}
					self.onAmbientJarvisSuggestionGenerated?(suggestion)
					print("[ActiveContextRefresh] completed evidence_quality=\(refreshEvidenceQuality)")
					logSuggestionTickSummary(
						modelReady: true,
						startupQuiet: false,
						workflow: effective.effectiveWorkflow.workflowType,
						workflowActionable: effective.effectiveWorkflow.workflowType != .unknown && effective.effectiveWorkflow.workflowType != .idle,
						determinerActionable: refreshDeterminer.actionable,
						cheapPortfolioRan: cheapFallback.ran,
						heavyPlannerRan: true,
						candidatesCount: refreshOpportunities.count + cheapFallback.candidatesCount,
						selected: suggestion?.topOpportunity?.capabilityId ?? cheapFallback.selected ?? "none",
						surfaceResult: suggestion == nil ? "suppressed" : "shown",
						suppressionReason: suggestion == nil ? cheapFallback.suppressionReason : "none"
					)
				}
		}
	}

	private struct CheapPortfolioRun {
		let ran: Bool
		let suggestion: AmbientJarvisSuggestion?
		let candidatesCount: Int
		let selected: String?
		let suppressionReason: String
		let determinerActionable: Bool

		static func notRun(reason: String) -> CheapPortfolioRun {
			CheapPortfolioRun(
				ran: false,
				suggestion: nil,
				candidatesCount: 0,
				selected: nil,
				suppressionReason: reason,
				determinerActionable: false
			)
		}
	}

	private func runCheapAlwaysOnPortfolio(
		reason: String,
		modelReady: Bool,
		startupQuiet: Bool,
		workflowState: WorkflowState?,
		behaviorRecord: BehavioralStateRecord?,
		launchElapsedSeconds: Int?
	) async -> CheapPortfolioRun {
		let events = await coordinator.getEventStreamSnapshot()
		guard !events.isEmpty else {
			return .notRun(reason: "no_context_events")
		}

		let buffer = TemporalContextBuffer.build(from: events, now: Date())
		latestTypingScore = buffer.short.typingScore
		latestPointerScore = buffer.short.pointerScore
		let compressor = TemporalContextCompressor.compress(buffer: buffer)
		let currentAppName = self.lastAppName ?? compressor.currentApp
		let appContext = AppContextAnalyzer.analyze(
			appName: currentAppName,
			bundleID: self.lastBundleID,
			windowTitle: self.lastObservedWindowTitle
		)
		let browser: BrowserContextExtractor.BrowserContext? = appContext.isBrowser
			? BrowserContextExtractor.extract(appName: currentAppName, activeAppPID: nil)
			: nil
		let tabTitles = browser?.recentTabTitles ?? []
		let selectedTitle = browser?.selectedTitle
		let fallbackBehaviorState = Self.behaviorState(
			typingScore: buffer.short.typingScore,
			pointerScore: buffer.short.pointerScore,
			hadRecentNavigation: !tabTitles.isEmpty || buffer.short.titleTransitions > 0
		)
		let behavior = behaviorRecord ?? BehavioralStateRecord(
			state: fallbackBehaviorState,
			confidence: fallbackBehaviorState == .unknown ? 0.10 : 0.45,
			reasoning: "cheap_always_on_activity",
			startedAt: Date(),
			lastUpdatedAt: Date(),
			stabilityScore: 0.30
		)
		let workflow = workflowState ?? WorkflowState(
			workflowType: .unknown,
			confidence: 0.0,
			evidence: ["cheap_always_on"],
			uncertainty: "heavy_inference_deferred",
			startedAt: Date(),
			lastUpdatedAt: Date(),
			stabilityScore: 0.0,
			dominantApps: compressor.recentApps,
			repeatedTerms: compressor.topicTerms,
			recentTransitions: [],
			suggestedIntentHints: [],
			sourcePacketHash: "cheap_always_on"
		)
		let groundingURL = browser?.selectedURL ?? browser?.currentURL
		let groundingInput = SemanticGroundingInput(
			appName: currentAppName,
			bundleId: self.lastBundleID ?? "",
			windowTitle: self.lastObservedWindowTitle ?? "",
			url: groundingURL,
			browserSelectedTitle: selectedTitle,
			browserSelectedURL: browser?.selectedURL,
			tabTitles: tabTitles,
			axTextSnippet: nil,
			selectedTextSnippet: nil,
			recentCompartment: await TaskCompartmentTracker.shared.getActiveCompartment(),
			recentAppSwitches: []
		)
		let groundingResult = await SemanticGroundingEngine.shared.ground(input: groundingInput)
		self.latestSemanticGrounding = groundingResult

		let activeComp = await TaskCompartmentTracker.shared.ingestUpdate(
			workflow: workflow.workflowType,
			behavior: behavior.state,
			title: selectedTitle ?? compressor.recentTitles.first ?? self.lastObservedWindowTitle ?? "",
			tabs: tabTitles,
			topicTerms: compressor.topicTerms,
			grounding: groundingResult
		)
		let allComps = await TaskCompartmentTracker.shared.compartments
		let activityState = ActivityState.derive(
			typingScore: buffer.short.typingScore,
			pointerScore: buffer.short.pointerScore,
			dwellSeconds: activeComp.dwellSeconds,
			hadRecentNavigation: !tabTitles.isEmpty || buffer.short.titleTransitions > 0
		)
		let memory = WorkingMemoryBuilder.build(
			workflow: workflow,
			behavior: behavior,
			packet: compressor,
			browserTabTitles: tabTitles,
			selectedBrowserTabTitle: selectedTitle,
			activeCompartment: activeComp,
			allCompartments: allComps
		)
		let selectedURLFound = browser?.selectedURL != nil || browser?.currentURL != nil
		let determiner = DeterminerSignal.evaluate(
			memory: memory,
			compartment: activeComp,
			workflowConfidence: workflow.confidence,
			behaviorConfidence: behavior.confidence,
			browserTabCount: tabTitles.count,
			hasSelectedURL: selectedURLFound,
			activeTerms: memory.repeatedConcepts,
			currentEntity: memory.currentEntity,
			activityState: activityState,
			grounding: groundingResult
		)
		self.latestDeterminerSignal = determiner
		self.latestActivityState = activityState
		self.latestWorkflowState = workflow
		self.latestBehaviorRecord = behavior
		await ActiveContextRefresh.shared.noteWorkflowAndBehavior(
			workflow: workflow.workflowType,
			behavior: behavior.state,
			evidenceQuality: Self.evidenceQuality(
				hasSelection: Self.hasRecentSelectionEvidence(in: compressor),
				hasOCRHints: !compressor.ocrHints.isEmpty,
				hasBrowserContext: selectedURLFound,
				appCategory: appContext.category,
				groundingResult: groundingResult,
				compartment: activeComp
			)
		)


		let lookupResult = groundingURL.flatMap { EntityLookupLayer.cachedResult(for: $0) }
		let grounding = EntityGroundingLayer.ground(
			title: memory.currentEntity,
			url: groundingURL,
			appCategory: appContext.category,
			memory: memory,
			compartment: activeComp,
			lookupResult: lookupResult
		)
		let semanticState = SemanticPriorityResolver.resolve(
			grounding: grounding,
			determinerSignal: determiner,
			compartment: activeComp,
			workflowTypeRaw: workflow.workflowType.rawValue,
			semanticGrounding: groundingResult
		)
		let shouldRun = CheapAlwaysOnPortfolio.shouldRun(
			startupQuiet: startupQuiet,
			modelReady: modelReady,
			workflow: workflow.workflowType,
			determinerSignal: determiner,
			entityGrounding: grounding,
			compartment: activeComp,
			activityState: activityState,
			launchElapsedSeconds: launchElapsedSeconds
		)
		guard shouldRun.allowed else {
			return CheapPortfolioRun(
				ran: false,
				suggestion: nil,
				candidatesCount: 0,
				selected: nil,
				suppressionReason: shouldRun.reason,
				determinerActionable: determiner.actionable
			)
		}
		if workflow.workflowType == .unknown || workflow.workflowType == .idle {
			print("[ActiveContextRefresh] cheap_lanes_allowed=yes reason=unknown_but_context_trusted")
			print("[ActiveContextRefresh] heavy_skipped=yes reason=workflow_unknown")
		}

		FrictionEngine.shared.recordConcepts(
		        memory.repeatedConcepts,
		        appName: currentAppName,
		        bundleID: self.lastBundleID,
		        windowTitle: self.lastObservedWindowTitle
		)

		if let selectedTitle, !selectedTitle.isEmpty {
			FrictionEngine.shared.recordTabVisit(title: selectedTitle)
		}
		let frictionSignals = FrictionEngine.shared.detectFriction()
		let contextualMediaState = EnvironmentMediaState.derived(
			activeApp: currentAppName,
			recentApps: compressor.recentApps,
			currentEntity: memory.currentEntity,
			entityType: semanticState.entityType,
			domain: semanticState.domain,
			behavior: behavior.state
		)
		let mediaSnapshot = MediaStateSource.currentSnapshot()
		let environmentMediaState = contextualMediaState.withMusicPlayback(
			isPlaying: mediaSnapshot.detectionAvailable ? mediaSnapshot.isMusicPlaying : contextualMediaState.isMusicPlaying,
			detectionAvailable: mediaSnapshot.detectionAvailable,
			source: mediaSnapshot.detectionAvailable ? "\(mediaSnapshot.source):\(mediaSnapshot.reason)" : "\(contextualMediaState.source):\(mediaSnapshot.reason)"
		)
		PassivePlaylistObserver.shared.tick(
			isMusicPlaying: environmentMediaState.isMusicPlaying,
			compartment: activeComp,
			workflow: activeComp.workflow
		)
		let entityKey = groundingURL?.absoluteString ?? memory.currentEntity
		let candidates = CheapAlwaysOnPortfolio.evaluate(
			CheapAlwaysOnPortfolioInput(
				reason: shouldRun.reason,
				workflow: workflow.workflowType,
				modelReady: modelReady,
				startupQuiet: startupQuiet,
				frictionSignals: frictionSignals,
				mediaState: environmentMediaState,
				semanticState: semanticState,
				entityGrounding: grounding,
				compartment: activeComp,
				memory: memory,
				activityState: activityState,
				entityKey: entityKey,
				currentApp: currentAppName,
				appCategory: appContext.category,
				groundingResult: groundingResult
			)
		)
		guard let selected = candidates.first else {
			return CheapPortfolioRun(
				ran: true,
				suggestion: nil,
				candidatesCount: 0,
				selected: nil,
				suppressionReason: "no_candidates",
				determinerActionable: determiner.actionable
			)
		}
		let cooldownKey = "\(selected.capabilityId)|\(entityKey)"
		if let lastAt = lastCheapSuggestionAt,
		   lastCheapSuggestionKey == cooldownKey,
		   Date().timeIntervalSince(lastAt) < ActiveContextRefresh.suggestionCooldownSeconds {
			return CheapPortfolioRun(
				ran: true,
				suggestion: nil,
				candidatesCount: candidates.count,
				selected: selected.capabilityId,
				suppressionReason: "recent_suggestion_cooldown",
				determinerActionable: determiner.actionable
			)
		}
		lastCheapSuggestionAt = Date()
		lastCheapSuggestionKey = cooldownKey
		let suggestion = makeCheapSuggestion(
			from: selected,
			workflow: workflow,
			behavior: behavior,
			memory: memory,
			compartment: activeComp
		)
		print("[JarvisPipeline] decision=shown reason=cheap_always_on")
		return CheapPortfolioRun(
			ran: true,
			suggestion: suggestion,
			candidatesCount: candidates.count,
			selected: selected.capabilityId,
			suppressionReason: "none",
			determinerActionable: determiner.actionable
		)
	}

	private func makeCheapSuggestion(
		from candidate: PortfolioCandidate,
		workflow: WorkflowState,
		behavior: BehavioralStateRecord,
		memory: WorkingMemorySnapshot,
		compartment: TaskCompartment?
	) -> AmbientJarvisSuggestion {
		let registry = CognitiveCapabilityRegistry.shared
		let primary = registry.get(candidate.capabilityId) ?? CognitiveCapability(
			id: candidate.capabilityId,
			label: candidate.title,
			inputRequirements: candidate.involvedApps,
			outputType: "system_action",
			evidenceThreshold: candidate.requiredEvidence,
			riskLevel: .light_action,
			requiresConfirmation: candidate.requiresConfirmation,
			executionMode: candidate.executionMode
		)
		let artifact = ArtifactResult(
			type: primary.outputType,
			title: candidate.title,
			subtitle: candidate.reason,
			confidence: candidate.confidence
		)
		let card = ActionCard(
			id: "cheap:\(candidate.capabilityId):\(abs(candidate.title.hashValue))",
			title: candidate.title,
			explanation: candidate.reason,
			primaryAction: primary,
			previewPayload: artifact,
			evidenceNote: "evidence_quality=\(candidate.requiredEvidence)",
			confidence: candidate.confidence,
			confirmationState: candidate.requiresConfirmation ? "required" : "none"
		)
		let opportunity = Opportunity(
			id: "opp:cheap:\(candidate.capabilityId):\(UUID().uuidString.prefix(6))",
			title: candidate.title,
			capabilityId: candidate.capabilityId,
			confidence: candidate.confidence,
			reason: candidate.reason,
			requiredEvidence: candidate.requiredEvidence,
			actionability: candidate.executability,
			inferredNeed: .planning,
			requiresConfirmation: candidate.requiresConfirmation,
			auxiliaryCapabilityIds: [],
			generatedAction: nil
		)
		let executionMode: AmbientExecutionMode = {
			switch candidate.executionMode {
			case .local_action: return .local_action
			case .preview_only: return .context_only_preview
			case .external_action: return .blocked_requires_control
			}
		}()
		return AmbientJarvisSuggestion(
			title: candidate.title,
			subtitle: candidate.reason,
			whyNow: "Cheap always-on portfolio selected \(candidate.capabilityId).",
			workflow: workflow.workflowType.rawValue,
			behavior: behavior.state.rawValue,
			confidence: candidate.confidence,
			kind: .comfort_action,
			intent: "environment:\(candidate.capabilityId)",
			intentConfidence: candidate.confidence,
			intentGoal: candidate.reason,
			targetEntity: memory.currentEntity,
			executionMode: executionMode,
			previewOnly: candidate.executionMode != .local_action,
			sourceEvidence: candidate.requiredEvidence,
			contextPayload: SuggestionContextPayload(
				taskCompartmentSnapshot: compartment,
				workingMemorySnapshot: memory,
				comparisonCandidates: memory.comparisonCandidates,
				relatedFocusEntities: memory.relatedFocusEntities,
				activeTerms: memory.repeatedConcepts,
				evidenceQuality: candidate.requiredEvidence,
				browserTabs: compartment?.browserTabs.sorted() ?? [],
				actionIntent: candidate.capabilityId
			),
			actionCard: card,
			topOpportunity: opportunity
		)
	}

	private nonisolated static func behaviorState(
		typingScore: Double,
		pointerScore: Double,
		hadRecentNavigation: Bool
	) -> BehavioralState {
		if typingScore > 0.05 { return .writing }
		if pointerScore > 0.05 { return .researching }
		if hadRecentNavigation { return .unknown }
		return .unknown
	}

	private nonisolated func logSuggestionTickSummary(
		modelReady: Bool,
		startupQuiet: Bool,
		workflow: AmbientWorkflowType,
		workflowActionable: Bool,
		determinerActionable: Bool,
		cheapPortfolioRan: Bool,
		heavyPlannerRan: Bool,
		candidatesCount: Int,
		selected: String?,
		surfaceResult: String,
		suppressionReason: String
	) {
		SuggestionTickSummaryLog.log(
			modelReady: modelReady,
			startupQuiet: startupQuiet,
			workflow: workflow,
			workflowActionable: workflowActionable,
			determinerActionable: determinerActionable,
			cheapPortfolioRan: cheapPortfolioRan,
			heavyPlannerRan: heavyPlannerRan,
			candidatesCount: candidatesCount,
			selected: selected,
			surfaceResult: surfaceResult,
			suppressionReason: suppressionReason
		)
	}

    // MARK: - One-shot privacy banner

    private func logPrivacyBannerOnce() {
        guard !didLogPrivacyBanner else { return }
        didLogPrivacyBanner = true
        print("[WorkflowPrivacy] clipboard_content_logged=no")
        print("[WorkflowPrivacy] selected_text_mode=metadata_only")
        print("[WorkflowPrivacy] ocr_topic_extraction=enabled")
    }

    // MARK: - Helpers (deterministic, internal-accessible for tests)

    /// Stable FNV-1a hash over UTF-8 bytes.
    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return String(h, radix: 16)
    }

    /// Distill repeated topic terms from an OCR excerpt. Returns at most 6
    /// lowercase tokens, each 4–20 chars, appearing at least twice. Numbers,
    /// punctuation, and very short tokens are dropped. Raw OCR is NEVER
    /// returned, only term tokens.
    static func ocrTopicHints(_ ocr: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for",
            "is", "are", "was", "be", "with", "by", "from", "this", "that",
            "it", "as", "but", "if", "so", "do", "did", "has", "have", "had",
            "will", "can", "get", "your", "you", "our", "their", "they", "all",
            "one", "two", "three", "out", "up", "not", "into", "than", "then",
            "what", "when", "where", "which", "who", "how",
        ]
        let words = ocr.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                guard token.count >= 4, token.count <= 20 else { return false }
                if stopwords.contains(token) { return false }
                if Int(token) != nil { return false }
                return true
            }
        var counts: [String: Int] = [:]
        for w in words { counts[w, default: 0] += 1 }
        return counts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map(\.key)
    }

    /// Title hints — short, low-volume topic distillation from the title only.
    static func titleTopicHints(_ title: String) -> [String] {
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && $0.count <= 20 }
        var unique: [String] = []
        var seen = Set<String>()
        for w in words where seen.insert(w).inserted {
            unique.append(w)
            if unique.count >= 4 { break }
        }
        return unique
    }

    /// Coarse length bucket so logs never reveal exact selection sizes.
	static func lengthBucket(_ n: Int) -> String {
		switch n {
		case 0...20: return "0-20"
		case 21...100: return "21-100"
		case 101...500: return "101-500"
		case 501...2000: return "501-2000"
		default: return "2000+"
		}
	}

	static func hasRecentSelectionEvidence(in packet: CompressedTemporalPacket) -> Bool {
		packet.selectionHints.contains { hint in
			hint == "selected_text_available=true" || hint.hasPrefix("selection_events=")
		}
	}

	static func evidenceQuality(
		hasSelection: Bool,
		hasOCRHints: Bool,
		hasBrowserContext: Bool,
		appCategory: AppContextAnalyzer.Category? = nil,
		groundingResult: SemanticGroundingResult? = nil,
		compartment: TaskCompartment? = nil
	) -> String {
		if hasSelection { return "selection" }
		if hasOCRHints { return "ocr" }
		if hasBrowserContext { return "browser_context" }
		if let quality = editorContextQuality(appCategory: appCategory, groundingResult: groundingResult, compartment: compartment) {
			return quality
		}
		return "title_only"
	}

	private static func editorContextQuality(
		appCategory: AppContextAnalyzer.Category?,
		groundingResult: SemanticGroundingResult?,
		compartment: TaskCompartment?
	) -> String? {
		guard appCategory == .editor else { return nil }
		let groundedCoding = groundingResult.map {
			$0.confidence >= 0.65 && ($0.domain.lowercased().contains("coding") || $0.domain.lowercased().contains("creative"))
		} ?? false
		let trustedCompartment = compartment.map {
			$0.compartmentTrust >= 0.50 && ($0.workflow == .coding || $0.workflow == .debugging)
		} ?? false
		if groundedCoding || trustedCompartment {
			print("[EvidenceQuality] upgraded reason=editor_context grounding_confidence=\(String(format: "%.2f", groundingResult?.confidence ?? 0)) compartment_trust=\(String(format: "%.2f", compartment?.compartmentTrust ?? 0))")
			return "editor_context"
		}
		return nil
	}
}

// MARK: - Pipeline kill switch

/// Process-wide on/off for the Workflow Intelligence pipeline. Default ON.
/// Disable with `CONTEXTUAL_WORKFLOW_INTELLIGENCE_ENABLED=0`.
enum WorkflowIntelligencePipeline {

    static var isEnabled: Bool {
        return ValidationConfiguration.workflowIntelligenceEnabled
    }

    nonisolated(unsafe) private static var didLogDisabled = false

    /// Log the disabled-state banner exactly once per process.
    static func logDisabledOnce() {
        if didLogDisabled { return }
        didLogDisabled = true
        print("[WorkflowPipeline] disabled reason=user_or_env")
    }
}
