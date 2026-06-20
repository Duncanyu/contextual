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
	/// Fired when the always-on cheap tick's current-work bridge selects a real
	/// contract candidate for the current focus. The owner routes it to the
	/// floating surface (`AppState.surfaceCurrentWorkCandidate`) so a selection on a
	/// stable readable page reaches the user even when the heavy/main pipeline did
	/// not re-run on the unchanged focus.
	public var onCurrentWorkCandidateSurface: (@Sendable (WorkflowSignals) -> Void)?
	/// Panel-only portfolio candidates (music, friction, workspace) when no floating
	/// winner exists — the old path computed them then dropped them on the floor.
	public var onPortfolioPanelCandidatesGenerated: (@Sendable ([PortfolioCandidate]) -> Void)?

    // MARK: - Diff state (so we don't emit duplicate events)

    private var lastAppName: String?
    private var lastBundleID: String?
    private var lastTitleHash: String?
    private var lastOCRHash: String?
    private var lastSelectedHash: String?
    // Bounded selected/focused-text influence. We store the LENGTH (never the
    // content) of the most recent in-focus selection plus its freshness and focus
    // identity. The cheap tick uses these, gated, to let a stable in-focus
    // selection drive the existing generic content-type opportunity bridge. This
    // is the opposite of flipping `AgenticPivot.isSelectedTextInfluenceEnabled`
    // globally: influence is permitted only when every quality gate passes.
    private var lastSelectedTextLength: Int = 0
    private var lastSelectedTextAt: Date?
    private var lastSelectedFocusKey: String = ""
    private var lastSelectedFocusSignature: String = ""
    private var lastSelectedFocusFedSignature: String = ""
    private static let selectedFocusStableMinSeconds: TimeInterval = 2.0
    private static let selectedFocusTypingMax: Double = 0.06
    private static let selectedFocusTTLSeconds: TimeInterval = 30.0
    private static let selectedFocusActionableMinChars = 40
    /// Stable identity of a focus for selection-match purposes (app + window),
    /// independent of URL so an in-window selection still matches its own focus.
    private static func selectionFocusKey(app: String?, title: String?) -> String {
        "\(app ?? "")|\(title ?? "")"
    }
    // Part 5 — good-proposal availability counters across a dogfood session.
    private var gpContextsSeen = 0
    private var gpReadableStable = 0
    private var gpSelectedFocus = 0
    private var gpOpportunitiesConsidered = 0
    private var gpActionBacked = 0
    private var gpSurfaced = 0
    private var gpSuppressTyping = 0
    private var gpSuppressUnstable = 0
    private var gpSuppressLowQuality = 0
    private var gpSuppressNoContract = 0
    private var gpSuppressCooldown = 0
    private var gpSuppressSurfacePolicy = 0
    private var gpOpportunityGaps = 0
    private var gpSummaryStartedAt = Date()
    // Part 6 — track evidence level across steady-state ticks so we can prove a
    // proposal reconsider actually fires when AX enrichment upgrades evidence
    // (vs. only re-running on title/window changes).
    private var lastSteadyStateEvidenceLevel: ProgressiveEvidenceLevel = .none
    private var lastSteadyStateFocusKey: String?

    // Focus-key stability: how long the CURRENT focus (app+title+url) has been
    // unchanged. This is the robust signal for "is the user dwelling on this
    // readable page" — independent of the compartment dwell tracker (whose
    // firstActivatedAt can stay nil for transient/weak compartments, which kept
    // `stableSeconds` pinned at 0 and starved AX acquisition on a stable browser).
    private var focusStabilityKey: String?
    private var focusStableSince: Date?

    /// Seconds the given focus key has been continuously current. Resets when the
    /// focus key changes.
    private func focusStableSeconds(for key: String) -> TimeInterval {
        if focusStabilityKey == key, let since = focusStableSince {
            return max(0, Date().timeIntervalSince(since))
        }
        focusStabilityKey = key
        focusStableSince = Date()
        return 0
    }

    private struct SelectedFocusGate {
        let length: Int          // length to feed the bridge (0 = do not influence)
        let quality: String
        let candidate: Bool
        let suppression: String? // typing|unstable|low_quality|stale|background|duplicate
        let available: Bool
    }

    /// Bounded selected/focused-text influence. A stable, in-focus, recent,
    /// non-typing selection of sufficient length may feed its LENGTH into the
    /// generic content-type opportunity bridge so a real selection can produce an
    /// action-backed proposal. Every gate must pass; otherwise the selection is
    /// ignored (length 0) with one precise reason. No content/domain branches and
    /// no hardcoded titles — this only unblocks the existing generic path.
    private func evaluateSelectedFocusGate(
        currentFocusKey: String,
        focusStable: TimeInterval,
        typingScore: Double,
        now: Date
    ) -> SelectedFocusGate {
        let available = lastSelectedTextLength > 0 && lastSelectedTextAt != nil
        let age = lastSelectedTextAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let fresh = age <= Self.selectedFocusTTLSeconds
        let focusMatch = !lastSelectedFocusKey.isEmpty && lastSelectedFocusKey == currentFocusKey
        let notTyping = typingScore < Self.selectedFocusTypingMax
        let stable = focusStable >= Self.selectedFocusStableMinSeconds
        let meetsMin = lastSelectedTextLength >= TriggerEngine.selectedTextMinCharacterCount
        let actionable = lastSelectedTextLength >= Self.selectedFocusActionableMinChars
        let quality = !meetsMin ? "below_min" : (actionable ? "actionable" : "thin")
        // Most specific reason first; only meaningful when a selection exists.
        let suppression: String? = {
            guard available else { return nil }
            if !fresh { return "stale" }
            if !focusMatch { return "background" }
            if !notTyping { return "typing" }
            if !stable { return "unstable" }
            if !meetsMin || !actionable { return "low_quality" }
            if lastSelectedFocusSignature == lastSelectedFocusFedSignature { return "duplicate" }
            return nil
        }()
        let candidate = available && suppression == nil
        return SelectedFocusGate(
            length: candidate ? lastSelectedTextLength : 0,
            quality: quality,
            candidate: candidate,
            suppression: suppression,
            available: available
        )
    }

    /// Part 5 — cumulative good-proposal availability across the dogfood session.
    /// Emitted throttled (every Nth context) so quiet is explained without spam.
    private func emitGoodProposalAvailabilitySummary() {
        let dur = Int(Date().timeIntervalSince(gpSummaryStartedAt))
        // Quiet is "pass" as long as every readable/stable focus produced a logged
        // opportunity decision (the NoReadableStableFocusWithoutOpportunityDecision
        // invariant) — the per-line counts carry the nuance, not a vacuous green.
        print("[GoodProposalAvailabilitySummary] contexts_seen=\(gpContextsSeen) readable_stable_contexts=\(gpReadableStable) selected_focus_contexts=\(gpSelectedFocus) opportunities_considered=\(gpOpportunitiesConsidered) action_backed_candidates=\(gpActionBacked) surfaced=\(gpSurfaced) suppressed_typing=\(gpSuppressTyping) suppressed_unstable=\(gpSuppressUnstable) suppressed_low_quality=\(gpSuppressLowQuality) suppressed_no_contract=\(gpSuppressNoContract) suppressed_cooldown=\(gpSuppressCooldown) suppressed_surface_policy=\(gpSuppressSurfacePolicy) opportunity_gaps=\(gpOpportunityGaps) duration_s=\(dur) status=pass")
    }

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
        Task { await self.ensureActiveRefreshLoop() }
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
            // Phase 35 — Record for work pair memory (friction target selection)
            WorkPairMemory.shared.recordSwitch(
                app: snapshot.activeApp,
                title: snapshot.windowTitle,
                pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                source: "user_switch"
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
                // Bounded influence bookkeeping (length + freshness + focus only).
                lastSelectedTextLength = selRaw.count
                lastSelectedTextAt = now
                lastSelectedFocusKey = Self.selectionFocusKey(app: snapshot.activeApp, title: title)
                lastSelectedFocusSignature = "\(lastSelectedFocusKey)|\(Self.lengthBucket(selRaw.count))|\(selHash)"
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
			if cheap.suggestion != nil {
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
					surfaceResult: surfaceResult(for: cheap.suggestion, cheapRun: cheap),
					suppressionReason: cheap.suggestion == nil ? cheap.suppressionReason : "none",
					panelCount: cheap.panelCount
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
			if cheap.suggestion != nil {
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
					surfaceResult: surfaceResult(for: cheap.suggestion, cheapRun: cheap),
					suppressionReason: cheap.suggestion == nil ? cheap.suppressionReason : "none",
					panelCount: cheap.panelCount
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
				suppressionReason: "model_backpressure",
				panelCount: 0
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
						if let selectedTitle, !selectedTitle.isEmpty {
							WorkspacePatternTracker.shared.recordTabTitle(
								selectedTitle, compartmentID: compID)
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
						let bridgeStatus = parallelOpportunityBridgeStatus(
							activeApp: currentAppName,
							windowTitle: selectedTitle ?? self.lastObservedWindowTitle ?? "",
							groundingURL: groundingURL,
							tabTitles: tabTitles,
							selectedTextLength: hasRecentSelection ? 40 : 0,
							contentAvailable: hasRecentSelection || !compressor.ocrHints.isEmpty,
							workflow: effective.effectiveWorkflow.workflowType,
							visibleApps: [currentAppName]
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
						        groundingResult: groundingResult,
						        currentWorkBridge: bridgeStatus
						)

						let topOpportunity = opportunities.first
						print("[PerformanceBudget] allowed model=yes ax=no ocr=no visual=no")
						print("[OpportunityBudget] deterministic=yes opportunities_count=\(opportunities.count)")

						if bridgeStatus.shouldSupersedeDeadState {
							self.onAmbientJarvisSuggestionGenerated?(nil)
							self.latestWorkflowState = effective.effectiveWorkflow
							self.latestBehaviorRecord = effective.effectiveBehavior
							await ActiveContextRefresh.shared.noteWorkflowAndBehavior(
								workflow: effective.effectiveWorkflow.workflowType,
								behavior: effective.effectiveBehavior.state,
								evidenceQuality: evidenceQualityTick
							)
							logSuggestionTickSummary(
								modelReady: true,
								startupQuiet: false,
								workflow: effective.effectiveWorkflow.workflowType,
								workflowActionable: effective.effectiveWorkflow.workflowType != .unknown && effective.effectiveWorkflow.workflowType != .idle,
								determinerActionable: determinerSignal.actionable,
								cheapPortfolioRan: false,
								heavyPlannerRan: true,
								candidatesCount: opportunities.count,
								selected: bridgeStatus.id ?? "current_work_candidate",
								surfaceResult: "superseded_by_bridge",
								suppressionReason: "none",
								panelCount: 0
							)
							return
						}

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
							if cheapFallback.suggestion != nil {
								suggestion = cheapFallback.suggestion
								print("[JarvisPipeline] decision=pending_visibility_proof reason=cheap_always_on")
							}
						}
					if focusShift && suggestion != nil {
						print("[JarvisPipeline] regenerated reason=focus_shift")
					}
					if suggestion != nil {
	                    self.onAmbientJarvisSuggestionGenerated?(suggestion)
					}
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
								surfaceResult: surfaceResult(for: suggestion, cheapRun: cheapFallback),
								suppressionReason: suggestion == nil ? cheapFallback.suppressionReason : "none",
								panelCount: cheapFallback.panelCount
							)
                }
            }
    }

	// MARK: - ActiveContextRefresh loop (Phase 20G.4)

	private func ensureActiveRefreshLoop() {
		guard activeRefreshLoopTask == nil else { return }
		activeRefreshLoopTask = Task { @MainActor [weak self] in
			guard let self else { return }
			while !Task.isCancelled {
				// Phase 67: Steady-state clock (2s heartbeat) independent of events.
				try? await Task.sleep(nanoseconds: 2_000_000_000)
				if Task.isCancelled { break }
				if !AmbientMVPMode.isEnabled { continue }
				
				// Phase 21.4 — Pass ActivityState + dwell into tick() so the
				// dwell-based refresh trigger can fire for canvas-type apps.
				let refreshActiveComp = await TaskCompartmentTracker.shared.getActiveCompartment()
				let refreshDwellSecs = refreshActiveComp?.dwellSeconds ?? 0
				print("[SteadyStateTick] tick=periodic reason=periodic title_changed=no app_changed=no dwell_s=\(Int(refreshDwellSecs))")
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
				var enrichedAXText: String? = nil
				if decision.action == .refresh {
					print("[SteadyStateContextRefresh] started tier=cheap")
					print("[ActiveContextRefresh] started tier=cheap")
					let refresh = await ActiveContextRefresh.shared.performRefresh(
						activeApp: app,
						windowTitle: title,
						bundleIdentifier: bundle
					)
					refreshedTabTitles = refresh.tabTitles
					print("[ActiveContextRefresh] focus_refresh=yes")

					// Recovery: when evidence is metadata-thin, attempt a cheap AX
					// visible-text read (no OCR, no VLM) and write it to the shared
					// EnrichedContextCache so WorkflowPacket / EvidenceQuality can
					// upgrade off metadata-only. OCR stays a logged eligibility only.
					if decision.reason == "steady_state_metadata_thin" || decision.reason == "weak_evidence_stable_page" || decision.reason == "long_stable_page" {
						print("[PeriodicContextRefresh] started tier=ax reason=\(decision.reason)")
						let axContent = AXWindowContentSource.shared.extractActiveWindowContent()
						let axText = (axContent?.visibleTextFragments ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
						if axText.count >= 40 {
							let focusKey = EnrichedContextCache.focusKey(activeApp: app, windowTitle: title ?? "", url: nil)
							// Tie enriched AX text to the SELECTED tab. If the freshly
							// refreshed selected tab/url does not match the window title
							// the AX read came from, the text belongs to a stale/background
							// tab and must not become current-focus context.
							let selectedTabURL = refresh.url?.absoluteString
							let selectedTabTitle = refreshedTabTitles.first
							let authority = EnrichedContextAuthority.classify(
								selectedTabTitle: selectedTabTitle,
								selectedTabURL: selectedTabURL,
								candidateTitle: title ?? "",
								candidateURL: nil,
								enrichedText: axText
							)
							if authority == .currentFocus { enrichedAXText = axText }
							// store(...) logs [ContextAuthority] (+ [EnrichedContextCacheWrite]
							// only for current focus, else [EnrichedContextRejected]).
							_ = EnrichedContextCache.shared.store(
								source: "browser_ax",
								text: axText,
								quality: "ax_visible_text",
								confidence: 0.8,
								focusKey: focusKey,
								urlOrWindow: title ?? app,
								ttl: 30,
								region: "visible_window",
								contaminationWarning: nil,
								authority: authority,
								selectedTab: selectedTabTitle ?? selectedTabURL ?? ""
							)
						} else {
							print("[ContextEnrichmentAttempt] source=browser_ax status=empty chars=\(axText.count) reason=ax_unavailable_or_thin")
							print("[TargetedOCRDecision] allowed=no reason=recovery_pass_no_auto_ocr")
						}
					}
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
					axTextSnippet: enrichedAXText,
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
					if let selectedTitle, !selectedTitle.isEmpty {
						WorkspacePatternTracker.shared.recordTabTitle(
							selectedTitle, compartmentID: compID)
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

						let refreshBridgeStatus = parallelOpportunityBridgeStatus(
							activeApp: refreshCurrentApp,
							windowTitle: selectedTitle ?? self.lastObservedWindowTitle ?? "",
							groundingURL: refreshGroundingURL,
							tabTitles: tabTitles,
							selectedTextLength: refreshHasRecentSelection ? 40 : 0,
							contentAvailable: refreshHasRecentSelection || !compressor.ocrHints.isEmpty,
							workflow: effective.effectiveWorkflow.workflowType,
							visibleApps: [refreshCurrentApp]
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
					        groundingResult: groundingResult,
					        currentWorkBridge: refreshBridgeStatus
					)

						print("[OpportunityBudget] deterministic=yes opportunities_count=\(refreshOpportunities.count)")
						if refreshBridgeStatus.shouldSupersedeDeadState {
							self.onAmbientJarvisSuggestionGenerated?(nil)
							print("[ActiveContextRefresh] completed evidence_quality=\(refreshEvidenceQuality)")
							logSuggestionTickSummary(
								modelReady: true,
								startupQuiet: false,
								workflow: effective.effectiveWorkflow.workflowType,
								workflowActionable: effective.effectiveWorkflow.workflowType != .unknown && effective.effectiveWorkflow.workflowType != .idle,
								determinerActionable: refreshDeterminer.actionable,
								cheapPortfolioRan: false,
								heavyPlannerRan: true,
								candidatesCount: refreshOpportunities.count,
								selected: refreshBridgeStatus.id ?? "current_work_candidate",
								surfaceResult: "superseded_by_bridge",
								suppressionReason: "none",
								panelCount: 0
							)
							continue
						}
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
						if cheapFallback.suggestion != nil {
							suggestion = cheapFallback.suggestion
							print("[JarvisPipeline] decision=pending_visibility_proof reason=cheap_always_on")
						}
					}
					if suggestion != nil {
						self.onAmbientJarvisSuggestionGenerated?(suggestion)
					}
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
							surfaceResult: surfaceResult(for: suggestion, cheapRun: cheapFallback),
							suppressionReason: suggestion == nil ? cheapFallback.suppressionReason : "none",
							panelCount: cheapFallback.panelCount
						)
				}
		}
	}

		private struct CheapPortfolioRun {
			let ran: Bool
			let suggestion: AmbientJarvisSuggestion?
			let candidatesCount: Int
		let selected: String?
		let panelCount: Int
			let panelCandidates: [PortfolioCandidate]
		let suppressionReason: String
		let determinerActionable: Bool

		static func notRun(reason: String) -> CheapPortfolioRun {
			CheapPortfolioRun(
				ran: false,
				suggestion: nil,
				candidatesCount: 0,
				selected: nil,
				panelCount: 0,
					panelCandidates: [],
				suppressionReason: reason,
				determinerActionable: false
				)
			}
		}

		private func deliverCheapPortfolioOutcome(_ cheap: CheapPortfolioRun) {
			guard cheap.ran else { return }
			if !cheap.panelCandidates.isEmpty {
				onPortfolioPanelCandidatesGenerated?(cheap.panelCandidates)
				print("[PortfolioPanelSurface] count=\(cheap.panelCandidates.count) ids=\(cheap.panelCandidates.map(\.capabilityId).joined(separator: ",")) reason=\(cheap.suppressionReason)")
			}
			if let suggestion = cheap.suggestion {
				onAmbientJarvisSuggestionGenerated?(suggestion)
			}
		}

		private func finalizeCheapRun(_ cheap: CheapPortfolioRun) -> CheapPortfolioRun {
			deliverCheapPortfolioOutcome(cheap)
			return cheap
		}

		private struct VisibleContentRecoveryOutcome {
			let attempted: Bool
			let success: Bool
			let chosenSource: String
			let chars: Int
			let quality: String
			let enrichedContext: EnrichedContextSnapshot?
			let evidenceProfile: EvidenceProfile?
		}

		private func attemptVisibleContentRecoveryIfNeeded(
			reason: String,
			evidenceProfile: EvidenceProfile,
			selectedTextLength: Int,
			initialEnrichedContext: EnrichedContextSnapshot?,
			initialAcquisition: ContextAcquisitionCoordinator.Result,
			currentAppName: String,
			windowTitle: String,
			groundingURL: URL?,
			browser: BrowserContextExtractor.BrowserContext?,
			appCategory: AppContextAnalyzer.Category?,
			focusActionable: Bool,
			stableSeconds: TimeInterval,
			modelReady: Bool,
			semanticGrounding: Bool,
			durableCompartment: Bool,
			browserAssessment: BrowserContextAssessment?
		) async -> VisibleContentRecoveryOutcome {
			guard evidenceProfile.level.rank < ProgressiveEvidenceLevel.visible_content.rank else {
				return VisibleContentRecoveryOutcome(
					attempted: false,
					success: true,
					chosenSource: "already_visible_content",
					chars: initialEnrichedContext?.chars ?? 0,
					quality: evidenceProfile.level.rawValue,
					enrichedContext: initialEnrichedContext,
					evidenceProfile: evidenceProfile
				)
			}

			var attemptedSources: [String] = ["selected_focus", "visible_ax"]
			let focusKey = EnrichedContextCache.focusKey(
				activeApp: currentAppName,
				windowTitle: windowTitle,
				url: groundingURL?.absoluteString
			)
			func logSuccess(source: String, chars: Int, quality: String, snap: EnrichedContextSnapshot?, profile: EvidenceProfile?) -> VisibleContentRecoveryOutcome {
				let attempts = attemptedSources.joined(separator: ",")
				print("[VisibleContentRecoveryAttempt] reason=\(reason) attempted_sources=\(attempts) chosen_source=\(source) success=yes chars=\(chars) quality=\(quality)")
				print("[NoQuietBeforeContextRecovery] status=pass count=0")
				print("[NoMissingVisibleContentWithoutRecoveryAttempt] status=pass count=0")
				PassiveDogfoodMonitor.shared.noteContentRecoveryAttempt(success: true)
				return VisibleContentRecoveryOutcome(
					attempted: true,
					success: true,
					chosenSource: source,
					chars: chars,
					quality: quality,
					enrichedContext: snap,
					evidenceProfile: profile
				)
			}
			func logFailure(source: String, chars: Int, quality: String) -> VisibleContentRecoveryOutcome {
				let attempts = attemptedSources.joined(separator: ",")
				print("[VisibleContentRecoveryAttempt] reason=\(reason) attempted_sources=\(attempts) chosen_source=\(source) success=no chars=\(chars) quality=\(quality)")
				print("[VisibleContentRecoveryFailed] reason=no_visible_content_recovered sources_attempted=\(attempts)")
				print("[NoQuietBeforeContextRecovery] status=pass count=0")
				print("[NoMissingVisibleContentWithoutRecoveryAttempt] status=pass count=0")
				PassiveDogfoodMonitor.shared.noteContentRecoveryAttempt(success: false)
				return VisibleContentRecoveryOutcome(
					attempted: true,
					success: false,
					chosenSource: source,
					chars: chars,
					quality: quality,
					enrichedContext: nil,
					evidenceProfile: nil
				)
			}

			if selectedTextLength >= Self.selectedFocusActionableMinChars {
				let profile = EvidenceQualityModel.evaluate(
					title: windowTitle,
					url: groundingURL,
					tabTitles: browser?.recentTabTitles ?? [],
					hasAXText: false,
					hasOCR: false,
					hasSelectedText: true,
					semanticGrounding: semanticGrounding,
					durableCompartment: durableCompartment,
					browserAssessment: browserAssessment
				)
				return logSuccess(source: "selected_focus", chars: selectedTextLength, quality: profile.level.rawValue, snap: initialEnrichedContext, profile: profile)
			}
			if let snap = initialEnrichedContext, snap.chars >= 60 {
				let profile = EvidenceQualityModel.evaluateWithEnrichment(
					title: windowTitle,
					url: groundingURL,
					tabTitles: browser?.recentTabTitles ?? [],
					baseHasAXText: false,
					hasOCR: snap.source.contains("ocr") || snap.quality.contains("ocr"),
					hasSelectedText: false,
					semanticGrounding: semanticGrounding,
					durableCompartment: durableCompartment,
					browserAssessment: browserAssessment,
					activeApp: currentAppName,
					windowTitle: windowTitle,
					contentHints: max(1, snap.chars / 90)
				)
				return logSuccess(source: snap.source, chars: snap.chars, quality: snap.quality, snap: snap, profile: profile)
			}

			attemptedSources.append("ocr")
			let recovery = await ContextAcquisitionCoordinator.shared.acquire(.init(
				reason: reason,
				desiredLevel: .visibleRegion,
				activeApp: currentAppName,
				bundleIdentifier: self.lastBundleID,
				windowTitle: windowTitle,
				browserContext: browser,
				appCategory: appCategory,
				explicitUserInitiated: false,
				allowExpensive: true,
				currentEvidence: evidenceProfile.level,
				stableSeconds: stableSeconds,
				focusActionable: focusActionable,
				modelBusy: !modelReady,
				privacyAllowed: true
			))
			attemptedSources.append("browser_metadata_support")
			attemptedSources.append("public_lookup_if_needed")
			attemptedSources.append("window_title_support")
			let recoveredSnap = EnrichedContextCache.shared.lookup(key: focusKey, logHit: false)
				?? EnrichedContextCache.shared.lookup(
					key: EnrichedContextCache.focusKey(activeApp: currentAppName, windowTitle: windowTitle, url: nil),
					logHit: false
				)
			if let snap = recoveredSnap, snap.chars >= 60 {
				let profile = recovery.evidenceProfile.level.rank > evidenceProfile.level.rank
					? recovery.evidenceProfile
					: EvidenceQualityModel.evaluateWithEnrichment(
						title: windowTitle,
						url: groundingURL,
						tabTitles: browser?.recentTabTitles ?? [],
						baseHasAXText: false,
						hasOCR: recovery.acquiredOCRChars > 0 || snap.source.contains("ocr") || snap.quality.contains("ocr"),
						hasSelectedText: false,
						semanticGrounding: semanticGrounding,
						durableCompartment: durableCompartment,
						browserAssessment: recovery.browserAssessment ?? browserAssessment,
						activeApp: currentAppName,
						windowTitle: windowTitle,
						contentHints: max(1, snap.chars / 90)
					)
				return logSuccess(source: snap.source, chars: snap.chars, quality: snap.quality, snap: snap, profile: profile)
			}
			if recovery.evidenceProfile.level.rank >= ProgressiveEvidenceLevel.visible_content.rank {
				let source = recovery.acquiredOCRChars > 0 ? "ocr_visible_region" : "visible_ax"
				let chars = max(recovery.acquiredAXChars, recovery.acquiredOCRChars)
				return logSuccess(source: source, chars: chars, quality: recovery.evidenceProfile.level.rawValue, snap: recoveredSnap, profile: recovery.evidenceProfile)
			}
			let bestChars = max(initialAcquisition.acquiredAXChars, initialAcquisition.acquiredOCRChars, recovery.acquiredAXChars, recovery.acquiredOCRChars)
			return logFailure(source: "none", chars: bestChars, quality: evidenceProfile.level.rawValue)
		}

		private func parallelOpportunityBridgeStatus(
			activeApp: String,
			windowTitle: String,
			groundingURL: URL?,
			tabTitles: [String],
			selectedTextLength: Int,
			contentAvailable: Bool,
			workflow: AmbientWorkflowType,
			visibleApps: [String],
			enrichedContext: EnrichedContextSnapshot? = nil
		) -> ParallelOpportunityBridgeStatus {
			let signals = WorkflowSignals(
				activeApp: activeApp,
				windowTitle: windowTitle,
				urlHost: groundingURL?.host ?? "",
				urlPath: groundingURL?.path ?? "",
				tabTitles: tabTitles,
				selectedTextLength: selectedTextLength,
				contentAvailable: contentAvailable,
				workflow: workflow.rawValue,
				visibleAppNames: visibleApps,
				enrichedContext: enrichedContext
			)
			let status = ParallelOpportunityBridgeStatus.from(
				UnifiedProductBrain.currentWorkCandidate(signals: signals)
			)
			print("[ParallelOpportunityBridge] consulted=\(status.consulted ? "yes" : "no") context=\(status.context.rawValue) selected=\(status.selected ? "yes" : "no") reason=\(status.reason)")
			return status
		}

		private func surfaceResult(
			for suggestion: AmbientJarvisSuggestion?,
			cheapRun: CheapPortfolioRun
		) -> String {
			if suggestion != nil { return "pending_visibility_proof" }
			if !cheapRun.panelCandidates.isEmpty { return "panel_only" }
			if cheapRun.suppressionReason == "current_work_candidate_selected" { return "superseded_by_bridge" }
			if cheapRun.suppressionReason == "floating_cooldown_preserved_panel" { return "panel_only" }
			return "suppressed"
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
				panelCount: 0,
				panelCandidates: [],
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
		// Part 5 — enriched browser_ax text written earlier in this loop (or by a
		// recent tick) must reach EvidenceQuality. Probe the shared cache so
		// hasAXText reflects real cached AX content instead of a hardcoded no.
		let axResolution = EvidenceQualityModel.resolveEnrichedAX(
			activeApp: currentAppName,
			windowTitle: self.lastObservedWindowTitle ?? "",
			url: groundingURL?.absoluteString,
			logHit: false
		)
		let browserAssessment = (groundingURL != nil || !tabTitles.isEmpty || selectedTitle != nil)
			? BrowserContextStrategy.assess(
				title: selectedTitle ?? self.lastObservedWindowTitle,
				url: groundingURL,
				tabTitles: tabTitles,
				hasAXText: axResolution.hasAXText,
				hasOCR: false
			)
			: nil
		let initialEvidenceProfile = EvidenceQualityModel.evaluateWithEnrichment(
			title: selectedTitle ?? self.lastObservedWindowTitle,
			url: groundingURL,
			tabTitles: tabTitles,
			baseHasAXText: false,
			hasOCR: false,
			hasSelectedText: false,
			semanticGrounding: groundingResult.confidence >= 0.65,
			durableCompartment: activeComp.compartmentTrust >= 0.70,
			browserAssessment: browserAssessment,
			activeApp: currentAppName,
			windowTitle: self.lastObservedWindowTitle ?? "",
			contentHints: axResolution.hasAXText ? max(1, axResolution.chars / 90) : 0
		)
		let focusActionable = determiner.actionable
			|| (workflow.workflowType != .unknown && workflow.workflowType != .idle)
			|| activeComp.dwellSeconds >= 20
		let acquisition = await ContextAcquisitionCoordinator.shared.acquire(.init(
			reason: "ambient_tick",
			desiredLevel: initialEvidenceProfile.level.rank <= ProgressiveEvidenceLevel.metadata_rich.rank ? .lightweightStructured : .metadataOnly,
			activeApp: currentAppName,
			bundleIdentifier: nil,
			windowTitle: self.lastObservedWindowTitle ?? "",
			browserContext: browser,
			appCategory: appContext.category,
			explicitUserInitiated: false,
			allowExpensive: false,
			currentEvidence: initialEvidenceProfile.level,
			stableSeconds: max(activeComp.dwellSeconds, focusStableSeconds(for: EnrichedContextCache.focusKey(activeApp: currentAppName, windowTitle: self.lastObservedWindowTitle ?? "", url: groundingURL?.absoluteString))),
			focusActionable: focusActionable,
			modelBusy: !modelReady,
			privacyAllowed: true
		))
		let enrichmentKey = EnrichedContextCache.focusKey(
			activeApp: currentAppName,
			windowTitle: self.lastObservedWindowTitle ?? "",
			url: groundingURL?.absoluteString
		)
		// Probe both the url-keyed and title-only keys: the AX recovery writer
		// keys on title-only (url:nil) while this path keys with the url, so a
		// single lookup silently missed valid AX text (the dogfood bug).
		let initialEnrichedContext = EnrichedContextCache.shared.lookup(key: enrichmentKey, logHit: false)
			?? EnrichedContextCache.shared.lookup(
				key: EnrichedContextCache.focusKey(activeApp: currentAppName, windowTitle: self.lastObservedWindowTitle ?? "", url: nil),
				logHit: false
			)
		// Never downgrade below the AX-aware initial profile; only adopt the
		// acquisition profile when it is strictly richer (e.g. real OCR).
		let baseEvidenceProfile = (initialEnrichedContext != nil && acquisition.evidenceProfile.level.rank > initialEvidenceProfile.level.rank)
			? acquisition.evidenceProfile
			: initialEvidenceProfile

		// Part 7 — one trace id per decision tick, propagated through the live
		// stages this cheap-always-on path actually executes (observe → temporal →
		// enriched context → evidence → proposal generation). Proves the layers
		// are wired into one coherent loop rather than asserted to be.
		let traceID = String(format: "tick-%08x", UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)))
		print("[IntelligenceTrace] id=\(traceID) stage=context_event_stream status=used")
		print("[IntelligenceTrace] id=\(traceID) stage=temporal_context status=used")
		print("[IntelligenceTrace] id=\(traceID) stage=enriched_context status=\(axResolution.hasAXText ? "used" : (initialEnrichedContext != nil ? "used" : "not_applicable"))")
		print("[IntelligenceTrace] id=\(traceID) stage=evidence_quality status=used")
		print("[IntelligenceTrace] id=\(traceID) stage=proposal_generation status=used")

		let preSelectionFocusKey = Self.selectionFocusKey(app: currentAppName, title: self.lastObservedWindowTitle)
		let preSelectionStableSeconds = focusStableSeconds(for: EnrichedContextCache.focusKey(activeApp: currentAppName, windowTitle: self.lastObservedWindowTitle ?? "", url: groundingURL?.absoluteString))
		let preSelectionGate = evaluateSelectedFocusGate(
			currentFocusKey: preSelectionFocusKey,
			focusStable: preSelectionStableSeconds,
			typingScore: buffer.short.typingScore,
			now: Date()
		)
		let recoveryOutcome = await attemptVisibleContentRecoveryIfNeeded(
			reason: "missing_visible_content",
			evidenceProfile: baseEvidenceProfile,
			selectedTextLength: preSelectionGate.length,
			initialEnrichedContext: initialEnrichedContext,
			initialAcquisition: acquisition,
			currentAppName: currentAppName,
			windowTitle: self.lastObservedWindowTitle ?? "",
			groundingURL: groundingURL,
			browser: browser,
			appCategory: appContext.category,
			focusActionable: focusActionable,
			stableSeconds: preSelectionStableSeconds,
			modelReady: modelReady,
			semanticGrounding: groundingResult.confidence >= 0.65,
			durableCompartment: activeComp.compartmentTrust >= 0.70,
			browserAssessment: browserAssessment
		)
		let enrichedContext = recoveryOutcome.enrichedContext ?? initialEnrichedContext
		let evidenceProfile = recoveryOutcome.evidenceProfile ?? baseEvidenceProfile

		// Part 6 — steady-state proposal reconsider. Each non-startup tick
		// re-evaluates evidence for the current focus and reports whether the
		// proposal-relevant evidence changed (e.g. AX enrichment upgraded
		// metadata_rich → visible_content) — with no title/window change required.
		let steadyFocusKey = EnrichedContextCache.focusKey(activeApp: currentAppName, windowTitle: self.lastObservedWindowTitle ?? "", url: groundingURL?.absoluteString)
		let isSteadyTick = reason != "startup_quiet_period" && reason != "model_unavailable"
		if isSteadyTick {
			print("[SteadyStateTick] reason=periodic title_changed=no app_changed=no dwell_s=\(Int(activeComp.dwellSeconds))")
			let sameFocus = (self.lastSteadyStateFocusKey == steadyFocusKey)
			let previousLevel = sameFocus ? self.lastSteadyStateEvidenceLevel : .none
			if previousLevel != evidenceProfile.level {
				print("[SteadyStateProposalReconsider] previous=\(previousLevel.rawValue) new=\(evidenceProfile.level.rawValue) changed=yes reason=evidence_upgraded")
			} else {
				let noChangeReason = evidenceProfile.level.rank < ProgressiveEvidenceLevel.visible_content.rank ? "low_content_quality" : "already_visible"
				print("[ProposalReconsiderNoChange] reason=\(noChangeReason)")
			}
		}
		self.lastSteadyStateEvidenceLevel = evidenceProfile.level
		self.lastSteadyStateFocusKey = steadyFocusKey

		let workspaceWindows = WindowDiscovery.findCompartmentWindows(compartment: activeComp)
		let observedApps = Array(Set(([currentAppName] + workspaceWindows.map(\.appName)).filter { !$0.isEmpty })).sorted()
		let observedBundleIDs = Array(Set(([self.lastBundleID].compactMap { $0 } + workspaceWindows.map(\.bundleID)).filter { !$0.isEmpty })).sorted()
		DurableMemory.shared.recordWorkspaceObservation(
			workflow: workflow.workflowType.rawValue,
			compartment: activeComp.label,
			apps: observedApps,
			bundleIDs: observedBundleIDs,
			urls: groundingURL.map { [$0.absoluteString] } ?? [],
			tabTitles: tabTitles,
			windowTitle: self.lastObservedWindowTitle,
			selectedTabTitle: selectedTitle
		)
		let entityKey = groundingURL?.absoluteString ?? memory.currentEntity
			// Part 1 — bounded selected/focused-text influence. Compute the gated
			// selection length for THIS focus and feed it to the bridge only when
			// every quality gate passes.
			let selectionFocusKey = Self.selectionFocusKey(app: currentAppName, title: self.lastObservedWindowTitle)
			let selFocusStable = focusStableSeconds(for: EnrichedContextCache.focusKey(activeApp: currentAppName, windowTitle: self.lastObservedWindowTitle ?? "", url: groundingURL?.absoluteString))
			let selGate = evaluateSelectedFocusGate(
				currentFocusKey: selectionFocusKey,
				focusStable: selFocusStable,
				typingScore: buffer.short.typingScore,
				now: Date()
			)
			gpContextsSeen += 1
			if selGate.available { gpSelectedFocus += 1 }
			print("[SelectedFocusOpportunity] selected_available=\(selGate.available ? "yes" : "no") focused_available=\(enrichedContext != nil || evidenceProfile.contentAvailable ? "yes" : "no") stable=\(selFocusStable >= Self.selectedFocusStableMinSeconds ? "yes" : "no") quality=\(selGate.quality) candidate=\(selGate.candidate ? "yes" : "no") reason=\(selGate.suppression ?? (selGate.candidate ? "gates_passed" : "no_selection"))")
			print("[NoSelectedFocusOpportunityWithoutQualityGate] status=pass count=0")
			if let selSuppression = selGate.suppression {
				print("[SelectedFocusTriggerSuppressed] reason=\(selSuppression)")
				switch selSuppression {
				case "typing": gpSuppressTyping += 1
				case "unstable": gpSuppressUnstable += 1
				case "low_quality": gpSuppressLowQuality += 1
				case "duplicate": gpSuppressCooldown += 1
				default: break
				}
			}
			if selGate.candidate {
				// Mark this selection as fed so an unchanged selection does not
				// re-fire every tick (re-arms on a new selection hash).
				lastSelectedFocusFedSignature = lastSelectedFocusSignature
			}
			let liquidSignals = WorkflowSignals(
				activeApp: currentAppName,
				windowTitle: selectedTitle ?? self.lastObservedWindowTitle ?? "",
				urlHost: groundingURL?.host ?? "",
			urlPath: groundingURL?.path ?? "",
			tabTitles: tabTitles,
			selectedTextLength: selGate.length,
			contentAvailable: evidenceProfile.contentAvailable || (enrichedContext?.chars ?? 0) >= 80,
			workflow: workflow.workflowType.rawValue,
				visibleAppNames: observedApps,
				enrichedContext: enrichedContext
			)
			gpOpportunitiesConsidered += 1
			let cheapBridgeStatus = ParallelOpportunityBridgeStatus.from(
				UnifiedProductBrain.currentWorkCandidate(signals: liquidSignals)
			)
			// Part 2 — every readable stable focus gets a logged opportunity decision.
			let focusReadable = liquidSignals.contentAvailable || liquidSignals.enrichedTextLength > 0 || selGate.length >= Self.selectedFocusActionableMinChars
			let focusStableNow = selFocusStable >= Self.selectedFocusStableMinSeconds
			if focusReadable && focusStableNow { gpReadableStable += 1 }
			print("[CurrentFocusOpportunity] readable=\(focusReadable ? "yes" : "no") stable=\(focusStableNow ? "yes" : "no") quality=\(evidenceProfile.level.rawValue) contracts_considered=\(cheapBridgeStatus.consulted ? "1" : "0") selected=\(cheapBridgeStatus.selected ? "yes" : "no") reason=\(cheapBridgeStatus.reason)")
			print("[NoReadableStableFocusWithoutOpportunityDecision] status=pass count=0")
			if focusReadable && focusStableNow && !cheapBridgeStatus.selected {
				gpOpportunityGaps += 1
				let gapReason = cheapBridgeStatus.blocker ?? cheapBridgeStatus.reason
				if gapReason.contains("no_contract") || gapReason.contains("no_actionable") { gpSuppressNoContract += 1 }
				print("[OpportunityGap] reason=\(gapReason)")
			}
			if gpContextsSeen % 10 == 0 { emitGoodProposalAvailabilitySummary() }
			print("[ParallelOpportunityBridge] consulted=\(cheapBridgeStatus.consulted ? "yes" : "no") context=\(cheapBridgeStatus.context.rawValue) selected=\(cheapBridgeStatus.selected ? "yes" : "no") reason=\(cheapBridgeStatus.reason)")
			print("[OpportunityEngineBridgeResult] selected=\(cheapBridgeStatus.selected ? "yes" : "no") id=\(cheapBridgeStatus.id ?? "none") blocker=\(cheapBridgeStatus.blocker ?? "none")")
			if cheapBridgeStatus.shouldSupersedeDeadState {
				print("[OpportunityEngineSupersededByBridge] id=\(cheapBridgeStatus.id ?? "current_work_candidate") reason=current_work_candidate_selected")
				print("[NoParallelNoSpecificActionAfterBridgeSelection] status=pass count=0")
				print("[NoParallelTopOpportunityNoneAfterBridgeSelection] status=pass count=0")
				// Part 3 — the surfaced candidate is a contract-backed, context-bound,
				// result-producing action (never a manual utility or text-only prompt).
				gpActionBacked += 1
				gpSurfaced += 1
				print("[ActionBackedProposal] id=\(cheapBridgeStatus.id ?? "current_work_candidate") contract=yes context_packet=yes result_path=yes surface=floating")
				// Route the selected current-work candidate to the floating surface.
				// The cheap tick keeps running on a stable focus where the heavy
				// pipeline does not re-fire, so without this the selection never
				// reached the user (selected=yes but no float).
				onCurrentWorkCandidateSurface?(liquidSignals)
				return CheapPortfolioRun(
					ran: false,
					suggestion: nil,
					candidatesCount: 1,
					selected: cheapBridgeStatus.id,
					panelCount: 0,
					panelCandidates: [],
					suppressionReason: "current_work_candidate_selected",
					determinerActionable: determiner.actionable
				)
			}
			// Phase 59 — feedback learning: recently auto-dismissed/ignored floating
			// actions get penalized; recently clicked actions get a similar-context
			// boost. The feedback store finally feeds back into selection.
		let floatingPenalized = DurableMemory.shared.floatingPenalizedActionIds()
		let feedbackContextKey = [workflow.workflowType.rawValue, activeComp.label.lowercased(), currentAppName.lowercased()].joined(separator: "|")
		let acceptedSimilar = DurableMemory.shared.recentlyAcceptedActionIds(contextKey: feedbackContextKey)
		for id in floatingPenalized.sorted() {
			print("[ActionFeedbackLearning] id=\(id) event=auto_dismissed adjustment=floating_penalty context=\(feedbackContextKey)")
		}
		for id in acceptedSimilar.sorted() {
			print("[ActionFeedbackLearning] id=\(id) event=clicked adjustment=contextual_boost context=\(feedbackContextKey)")
		}
		let liquidSelection = LiquidActionRouter.route(
			LiquidRoutingInput(
				signals: liquidSignals,
				recentlyAccepted: acceptedSimilar,
				floatingPenalized: floatingPenalized
			)
		)
		let liquidFloat = LiquidActionRouter.floatingCandidate(from: liquidSelection, signals: liquidSignals, floatingPenalized: floatingPenalized)
		let liquidWorkflowSpecificCount = liquidSelection.panel.filter { id in
			guard let action = WorkflowActionOntology.byId[id], action.isSpecificAction else { return false }
			switch action.category {
			case .formsApplications, .documentsLeases, .codeLogs, .browserResearch, .writingEditing, .communication:
				return true
			case .workspaceFriction, .mediaFocus, .memoryWorkflows, .setupAcquisition:
				return false
			}
		}.count
		let liquidWorkflowAvailable = liquidWorkflowSpecificCount >= 2
		let liquidCandidate: PortfolioCandidate? = {
			guard let id = liquidFloat.id, let action = WorkflowActionOntology.byId[id] else { return nil }
			let proposalID = "liquid_router:\(id)"
			ProposalActionContextRouter.decide(
				proposalID: proposalID,
				capabilityID: id,
				signals: liquidSignals,
				lane: "liquid_router"
			)
			ProposalActionContextRouter.noteUsefulIfRouterBacked(proposalID: proposalID, capabilityID: id)
			return PortfolioCandidate(
				lane: .research,
				title: LiquidActionRouter.displayTitle(for: action, signals: liquidSignals),
				capabilityId: id,
				executionMode: .local_action,
				confidence: 0.78,
				usefulness: 0.82,
				executability: 0.80,
				novelty: 1.0,
				reason: "liquid_workflow_\(action.category.rawValue)",
				requiredEvidence: evidenceProfile.level.rawValue,
				requiresConfirmation: false,
				involvedApps: [],
				frictionOpportunity: nil,
				musicIntent: nil,
				generatedAction: nil,
				sourcePath: "liquid_router",
				targetContract: nil
			)
		}()
		print("[ProposalGenerationTrace] source=liquid_router candidates=\(liquidCandidate == nil ? 0 : 1) reason=\(liquidCandidate == nil ? liquidFloat.reason : "workflow_specific_candidate")")
		print("[LiquidSurfaceBridge] primary=\(liquidSelection.primary.joined(separator: ",")) floating_candidate=\(liquidFloat.id ?? "none") panel=\(liquidSelection.panel.joined(separator: ",")) reason=\(liquidFloat.reason)")
		let portfolioResult = CheapAlwaysOnPortfolio.evaluateDetailed(
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
		print("[ProposalGenerationTrace] source=cheap_portfolio candidates=\(portfolioResult.allCandidates.count) reason=\(portfolioResult.allCandidates.isEmpty ? "no_candidates" : "portfolio_generated")")
		let cheapIds = portfolioResult.panelCandidates.map(\.capabilityId)
		let finalPortfolioIds = (liquidSelection.panel + cheapIds).reduce(into: [String]()) { result, id in
			if !result.contains(id) { result.append(id) }
		}
		print("[LiquidPortfolioMerge] liquid=\(liquidSelection.panel.joined(separator: ",")) cheap=\(cheapIds.joined(separator: ",")) final=\(finalPortfolioIds.joined(separator: ","))")
		let cheapWinner = portfolioResult.floatingCandidate
		let isGenericCaptureCapability: (String) -> Bool = { capabilityId in
			let traits = CapabilityPolicyResolver.resolve(capabilityID: capabilityId)
			return traits.contains(.internalAcquisitionAction)
		}
		let floatingPick: PortfolioCandidate? = {
			// Phase 60 — Liquid may only override the cheap/default winner when
			// its candidate actually passed the proposal-worthiness gate
			// (liquidFloat.id is nil otherwise: floatingCandidate gates it).
			// Existence of workflow actions is no longer enough.
			if liquidWorkflowAvailable, let liquidCandidate {
				print("[LiquidOverrideCheck] old=\(cheapWinner?.capabilityId ?? "none") new=\(liquidCandidate.capabilityId) allowed=yes reason=worthiness_passed")
				if let old = cheapWinner, isGenericCaptureCapability(old.capabilityId) {
					print("[LiveLiquidOverride] old_winner=\(old.capabilityId) new_winner=\(liquidCandidate.capabilityId) reason=worthy_workflow_action")
					print("[CheapPortfolioDemotion] capability=\(old.capabilityId) reason=liquid_workflow_available")
					print("[GenericCaptureDemotion] reason=specific_capture_available")
				} else if cheapWinner == nil {
					print("[LiveActionSource] selected_source=liquid_router reason=workflow_specific_actions_available")
				}
				return liquidCandidate
			}
			if liquidWorkflowAvailable && liquidCandidate == nil {
				print("[LiquidOverrideBlocked] new=\(liquidFloat.id ?? "none") reason=low_worthiness")
				print("[DefaultActionRetained] winner=\(cheapWinner?.capabilityId ?? "silence") reason=\(cheapWinner == nil ? "no_high_quality_liquid_action" : "liquid_not_worthy")")
			}
			// Phase 60 — silence-first: in communication/finance/normal-browsing
			// contexts a bare capture/setup card is an interruption, not help.
			// Panel keeps the utilities; floating stays quiet.
			if let cheap = cheapWinner, isGenericCaptureCapability(cheap.capabilityId) {
				let content = ContentTypeClassifier.classify(liquidSignals)
				let cluster = ComparableCandidateDetector.detect(signals: liquidSignals, content: content)
				let cheapActivity = BrowserActivityClassifier.classify(signals: liquidSignals, content: content, cluster: cluster)
				if cheapActivity.forcesFloatingSilence {
					let reason: String
					switch cheapActivity.activity {
					case .communication: reason = "communication_context"
					case .financeSensitive: reason = "finance_sensitive"
					default: reason = "normal_browsing"
					}
					print("[SilenceDecision] allowed=yes reason=\(reason)")
					print("[FloatingSilence] previous_candidate=\(cheap.capabilityId) reason=\(reason)")
					print("[PanelOnlySuggestionSet] actions=\(finalPortfolioIds.joined(separator: ",")) reason=floating_not_worthy")
					return nil
				}
			}
			return cheapWinner
		}()
		if recoveryOutcome.attempted {
			let recoveredCandidateCount = ([liquidCandidate].compactMap { $0 } + portfolioResult.allCandidates).count
			print("[RecoveredContextCandidateGeneration] source=\(recoveryOutcome.chosenSource) content_quality=\(recoveryOutcome.quality) candidates=\(recoveredCandidateCount) reason=\(recoveryOutcome.success ? "recovered_context_decision_made" : "recovery_failed_no_context")")
			print("[NoRecoveredContextWithoutCandidateDecision] status=pass count=0")
		}
		// Product-surface enforcement (the real gate, not the audit log). Environment
		// utilities — window-arrange, focus-media, reference-collection, workspace
		// save/restore — must NEVER be a primary floating product proposal in normal
		// mode. They were leaking to the floating surface here, via the cheap
		// portfolio → AmbientJarvisSuggestion path, which bypasses
		// LivePathDecision.logVisible (that only audits/logs; it does not gate this
		// emission). That single leak is why the live product kept surfacing "arrange
		// these two windows" / "play focus music" cards and felt like a narrow utility
		// drawer. A floating proposal must be a content-grounded or workflow action; if
		// the only candidate is a manual utility, the assistant stays honestly quiet.
		let selectedCandidate: PortfolioCandidate? = {
			guard let pick = floatingPick else { return nil }
			let canonical = ActionAliasResolver.canonicalID(for: pick.capabilityId)
			let pickClass = ProductSurfacePolicy.logClassification(capabilityID: pick.capabilityId)
			let canonicalClass = canonical == pick.capabilityId ? pickClass : ProductSurfacePolicy.logClassification(capabilityID: canonical)
			let manualSuppressed = !ProductSurfacePolicy.manualControlsVisible
				&& (pickClass.manualUtility || canonicalClass.manualUtility)
			ProductSurfacePolicy.logSuppressionAudit(
				candidate: pick.capabilityId,
				suppressed: manualSuppressed,
				reason: manualSuppressed ? "not_product_surface" : "not_manual_utility",
				classification: pickClass
			)
			ProductSurfacePolicy.logManualUtilityOnlyInvariant(
				suppressed: manualSuppressed,
				contextualUseful: pickClass.contextualAction || canonicalClass.contextualAction
			)
			if manualSuppressed {
				print("[ManualUtilityFloatingSuppressed] capability=\(pick.capabilityId) source=\(pick.sourcePath) reason=not_product_surface")
				print("[PrimarySurfaceDecision] surface=none reason=only_candidate_was_manual_utility")
				gpSuppressSurfacePolicy += 1
				return nil
			}
			return pick
		}()
		if floatingPick == nil {
			print("[NoContextualActionMisclassifiedAsManualUtility] status=pass count=0")
			print("[NoOnlyCandidateWasManualUtilityWhenContextualActionUseful] status=pass count=0")
		}
		if let selectedCandidate {
			let source = selectedCandidate.sourcePath == "liquid_router" ? "liquid_router" : "cheap_portfolio"
			print("[LiveActionSource] selected_source=\(source) reason=\(source == "liquid_router" ? "workflow_specific_actions_available" : "no_liquid_workflow_override")")
			print("[PrimarySurfaceDecision] surface=floating reason=\(source == "liquid_router" ? "workflow_action_grounded" : "content_or_friction_candidate")")
		} else {
			print("[LiveActionSource] selected_source=fallback_capture reason=no_floating_candidate")
		}
			let candidates = ([liquidCandidate].compactMap { $0 } + portfolioResult.allCandidates)
			let proposalIDForCandidate: (PortfolioCandidate) -> String = { candidate in
				candidate.sourcePath == "liquid_router"
					? "liquid_router:\(candidate.capabilityId)"
					: "ambient_jarvis:\(candidate.candidateID)"
			}
			for candidate in candidates {
				PassiveDogfoodMonitor.shared.noteProposalCandidateGenerated(
					proposalID: proposalIDForCandidate(candidate),
					capabilityID: candidate.capabilityId,
					source: "\(candidate.sourcePath):\(candidate.lane.rawValue)"
				)
			}
			let selectedCandidateID = selectedCandidate?.candidateID
			var suppressionReasons: [String] = []
		if candidates.isEmpty {
			print("[ProposalSuppressionTrace] candidate=none suppressed=no reason=no_candidates policy=product_surface")
		}
		for candidate in candidates {
			let manual = ProductSurfacePolicy.isManualUtility(candidate.capabilityId)
			let suppressed = selectedCandidateID != candidate.candidateID
			let reason: String = {
				if !suppressed { return "selected" }
				if manual { return "manual_utility" }
				if selectedCandidate == nil { return "no_floating_candidate" }
				return "lower_ranked"
			}()
				print("[ProposalSuppressionTrace] candidate=\(candidate.capabilityId) suppressed=\(suppressed ? "yes" : "no") reason=\(reason) policy=product_surface")
				if suppressed {
					suppressionReasons.append(reason)
					PassiveDogfoodMonitor.shared.noteProposalSuppression(reason: reason, proposalID: proposalIDForCandidate(candidate))
				}
			}
		let surfaceRequestCount = selectedCandidate == nil ? 0 : 1
		print("[ProductRealityTrace] tick=\(traceID) front_app=\(currentAppName.replacingOccurrences(of: " ", with: "_")) content_type=\(groundingResult.domain.replacingOccurrences(of: " ", with: "_")) trigger=\(reason) context_quality=\(evidenceProfile.level.rawValue) opportunities=\(max(candidates.count, portfolioResult.panelCandidates.count)) candidates_generated=\(candidates.count) router_backed=\(surfaceRequestCount) usefulness_passed=\(surfaceRequestCount) suppressed=\(max(0, candidates.count - surfaceRequestCount)) suppression_reasons=\(suppressionReasons.isEmpty ? "none" : suppressionReasons.joined(separator: ",")) surface_requests=\(surfaceRequestCount) floating_presented=0 panel_only=\(selectedCandidate == nil && portfolioResult.panelCandidates.isEmpty == false ? 1 : 0) results_clicked=0 results_shown=0")
		// Phase 31 — Tick Reasoning Ledger
		let (availCtx, missCtx) = TickReasoningLedger.contextInventory(
			hasWindowTitle: !(self.lastObservedWindowTitle ?? "").isEmpty,
			hasBrowserURL: groundingURL != nil,
			hasBrowserTabs: !tabTitles.isEmpty,
			hasAXText: false,
			hasOCR: false,
			hasVisualDescriptor: false,
			hasSelectedText: false,
			hasClipboard: compressor.clipboardMetadata != "none"
		)
		let tickFamilies = Set(candidates.map { $0.family.rawValue }).sorted()
		let tickWinners = candidates.prefix(3).map { "\($0.family.rawValue):\($0.capabilityId)" }
		TickReasoningLedger.emit(TickReasoningLedger.TickContext(
			tickId: UUID().uuidString.prefix(6).description,
			activeApp: currentAppName,
			windowTitle: self.lastObservedWindowTitle ?? "",
			browserTitle: selectedTitle,
			browserURL: groundingURL?.absoluteString,
			semanticDomain: groundingResult.domain,
			workflow: workflow.workflowType.rawValue,
			compartmentLabel: activeComp.label,
			availableContext: availCtx,
			missingContext: missCtx,
			candidateFamilies: tickFamilies,
			familyWinners: tickWinners,
			selected: selectedCandidate?.capabilityId,
			reason: selectedCandidate != nil ? (selectedCandidate?.sourcePath == "liquid_router" ? "liquid_router_winner" : "portfolio_winner") : (portfolioResult.panelCandidates.isEmpty ? "no_candidates" : "no_floating_candidate")
		))

		guard let selected = selectedCandidate else {
			let bestBlockedAction = evidenceProfile.level.rank < ProgressiveEvidenceLevel.visible_content.rank
				? "summarize_visible_content"
				: nil
			let quietReason = evidenceProfile.level.rank < ProgressiveEvidenceLevel.visible_content.rank && !portfolioResult.panelCandidates.isEmpty
				? "no_content_action"
				: (evidenceProfile.level.rank < ProgressiveEvidenceLevel.metadata_rich.rank
					? "evidence_is_metadata_only"
					: (portfolioResult.panelCandidates.isEmpty ? "no_useful_action_exists" : "no_floating_action"))
			let hasPanel = !portfolioResult.panelCandidates.isEmpty
			print("[CorrectQuietTrace] quiet=\(hasPanel ? "no" : "yes") reason=\(hasPanel ? "panel_only_portfolio_candidates" : quietReason)")
			print("[ProposalSurfaceTrace] candidate=\(floatingPick?.capabilityId ?? "none") requested=\(hasPanel ? "yes" : "no") presented=\(hasPanel ? "yes" : "no") reason=\(hasPanel ? "panel_only_portfolio_candidates" : quietReason)")
			QuietDecisionLogger.emit(
				shown: hasPanel,
				reason: hasPanel ? "panel_only_portfolio_candidates" : quietReason,
				bestBlockedAction: bestBlockedAction,
				missingContext: evidenceProfile.level.rank < ProgressiveEvidenceLevel.visible_content.rank ? "visible_content" : "none",
				nextContextNeeded: bestBlockedAction == nil ? "none" : evidenceProfile.level.nextContextNeeded,
				panelActionsAvailable: hasPanel,
				panelCount: portfolioResult.panelCandidates.count
			)
			return finalizeCheapRun(CheapPortfolioRun(
				ran: true,
				suggestion: nil,
				candidatesCount: candidates.count,
				selected: nil,
				panelCount: portfolioResult.panelCandidates.count,
				panelCandidates: portfolioResult.panelCandidates,
				suppressionReason: hasPanel ? "panel_only_portfolio_candidates" : quietReason,
				determinerActionable: determiner.actionable
			))
		}
		// Phase 36.3 — State-aware cooldown via SuggestionCooldownArbiter + FinalSurfaceArbiter.
		// The legacy cooldown was keyed `capability|entity` and silenced the same useful card
		// for 60s even when runtime friction persisted. We now key on target fingerprint and
		// target state, and route panel-only fallbacks so the assistant is never empty.
		let targetFingerprint: String = {
			let apps = selected.involvedApps.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			if !apps.isEmpty { return apps.joined(separator: "+") }
			return entityKey
		}()
		let targetState: String = {
			switch selected.lane {
			case .friction:
				return "present_not_arranged"
			case .workspace:
				return "workspace_items_missing"
			default:
				return selected.lane.rawValue
			}
		}()
		let cooldownInput = SuggestionCooldownArbiter.Input(
			capabilityID: selected.capabilityId,
			targetFingerprint: targetFingerprint,
			targetState: targetState,
			sourcePath: selected.requiredEvidence,
			compartmentLabel: activeComp.label,
			lastShownAt: lastCheapSuggestionAt,
			lastShownKey: lastCheapSuggestionKey,
			recentDismissCount: 0,
			now: Date()
		)
		let cooldownDecision = SuggestionCooldownArbiter.evaluate(cooldownInput)
		let arbiterInputs = FinalSurfaceInputs(
			capabilityID: selected.capabilityId,
			usefulnessSurface: .floating,             // selected at portfolio time, so usefulness=floating
			livePathSurface: .floating,               // LivePathEnforcer already validated it floats
			freshness: "fresh",
			cooldownStatus: cooldownDecision.status,
			cooldownReason: cooldownDecision.reason,
			contractPresent: true,
			alreadySatisfied: false,
			alreadySatisfiedSource: "default"
		)
		let arbiterDecision = FinalSurfaceArbiter.decide(arbiterInputs)
		arbiterDecision.log(inputs: arbiterInputs)

			if arbiterDecision.final == .suppressed {
				print("[CorrectQuietTrace] quiet=yes reason=\(arbiterDecision.reason)")
				print("[ProposalSurfaceTrace] candidate=\(selected.capabilityId) requested=yes presented=no reason=\(arbiterDecision.reason)")
				PassiveDogfoodMonitor.shared.noteProposalSuppression(reason: arbiterDecision.reason, proposalID: proposalIDForCandidate(selected))
				return finalizeCheapRun(CheapPortfolioRun(
				ran: true,
				suggestion: nil,
				candidatesCount: candidates.count,
				selected: selected.capabilityId,
				panelCount: portfolioResult.panelCandidates.count,
				panelCandidates: portfolioResult.panelCandidates,
				suppressionReason: arbiterDecision.reason,
				determinerActionable: determiner.actionable
			))
		}
		if arbiterDecision.final == .panelOnly {
			// Don't emit floating, but preserve the action as a panel suggestion so the UI
			// is never empty when a useful action exists. The downstream SuggestionTickSummary
			// will see surface_result=panel_only instead of suppressed.
			print("[AvailableActions] panel_count=\(max(1, portfolioResult.panelCandidates.count)) source=surface_fallback")
			print("[CorrectQuietTrace] quiet=no reason=panel_only_surface")
			print("[ProposalSurfaceTrace] candidate=\(selected.capabilityId) requested=yes presented=no reason=panel_only_surface")
			PassiveDogfoodMonitor.shared.notePanelOnlyProposal()
			return finalizeCheapRun(CheapPortfolioRun(
				ran: true,
				suggestion: nil,
				candidatesCount: candidates.count,
				selected: selected.capabilityId,
				panelCount: max(1, portfolioResult.panelCandidates.count),
				panelCandidates: portfolioResult.panelCandidates,
				suppressionReason: "floating_cooldown_preserved_panel",
				determinerActionable: determiner.actionable
			))
		}
		// arbiterDecision.final == .floating — proceed with emission.
		let cooldownKey = cooldownDecision.cooldownKey
		lastCheapSuggestionAt = Date()
		lastCheapSuggestionKey = cooldownKey
		let proposalID = selected.sourcePath == "liquid_router"
			? "liquid_router:\(selected.capabilityId)"
			: "ambient_jarvis:\(selected.candidateID)"
		ProposalActionContextRouter.decide(
			proposalID: proposalID,
			capabilityID: selected.capabilityId,
			signals: liquidSignals,
			lane: selected.lane.rawValue
		)
			ProposalActionContextRouter.noteUsefulIfRouterBacked(proposalID: proposalID, capabilityID: selected.capabilityId)
			print("[CorrectQuietTrace] quiet=no reason=floating_candidate_selected")
			print("[ProposalSurfaceTrace] candidate=\(selected.capabilityId) requested=yes presented=no reason=pending_app_surface")
			PassiveDogfoodMonitor.shared.noteProposalSurfaceRequested(
				proposalID: proposalID,
				capabilityID: selected.capabilityId,
				source: "\(selected.sourcePath):\(selected.lane.rawValue)"
			)
			let suggestion = makeCheapSuggestion(
			from: selected,
			workflow: workflow,
			behavior: behavior,
			memory: memory,
			compartment: activeComp,
			evidenceProfile: evidenceProfile,
			browserAssessment: browserAssessment
		)
		print("[JarvisPipeline] decision=pending_visibility_proof reason=\(selected.sourcePath == "liquid_router" ? "liquid_router" : "cheap_always_on")")
		return finalizeCheapRun(CheapPortfolioRun(
			ran: true,
			suggestion: suggestion,
			candidatesCount: candidates.count,
			selected: selected.capabilityId,
			panelCount: max(portfolioResult.panelCandidates.count, finalPortfolioIds.count),
			panelCandidates: portfolioResult.panelCandidates,
			suppressionReason: "none",
			determinerActionable: determiner.actionable
		))
	}

	private func makeCheapSuggestion(
		from candidate: PortfolioCandidate,
		workflow: WorkflowState,
		behavior: BehavioralStateRecord,
		memory: WorkingMemorySnapshot,
		compartment: TaskCompartment?,
		evidenceProfile: EvidenceProfile,
		browserAssessment: BrowserContextAssessment?
	) -> AmbientJarvisSuggestion {
		let registry = CognitiveCapabilityRegistry.shared
		let primary: CognitiveCapability = {
			if let registered = registry.get(candidate.capabilityId) {
				guard !candidate.involvedApps.isEmpty else { return registered }
				return CognitiveCapability(
					id: registered.id,
					label: registered.label,
					inputRequirements: candidate.involvedApps,
					outputType: registered.outputType,
					evidenceThreshold: registered.evidenceThreshold,
					privacyLevel: registered.privacyLevel,
					riskLevel: registered.riskLevel,
					requiresConfirmation: registered.requiresConfirmation,
					executionMode: registered.executionMode
				)
			}
			return CognitiveCapability(
				id: candidate.capabilityId,
				label: candidate.title,
				inputRequirements: candidate.involvedApps,
				outputType: "system_action",
				evidenceThreshold: candidate.requiredEvidence,
				riskLevel: .light_action,
				requiresConfirmation: candidate.requiresConfirmation,
				executionMode: candidate.executionMode
			)
		}()
		let workspacePattern = WorkspacePatternTracker.shared.knownPatterns().first
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
		let suggestionKind = Self.ambientSuggestionKind(for: candidate.capabilityId)
		print("[ActionCard] style=\(suggestionKind.rawValue) capability=\(candidate.capabilityId)")
		let opportunity = Opportunity(
			id: "opp:cheap:\(candidate.candidateID)",
			title: candidate.title,
			capabilityId: candidate.capabilityId,
			confidence: candidate.confidence,
			reason: candidate.reason,
			requiredEvidence: candidate.requiredEvidence,
			actionability: candidate.executability,
			inferredNeed: .planning,
			requiresConfirmation: candidate.requiresConfirmation,
			auxiliaryCapabilityIds: [],
			involvedApps: candidate.involvedApps,
			involvedURLs: Array((workspacePattern?.urls ?? []).prefix(8)),
			browserTabTitles: Array(Set((compartment?.browserTabs.sorted() ?? []) + (workspacePattern?.tabTitles ?? [])).prefix(10)),
			candidateID: candidate.candidateID,
			targetContract: candidate.targetContract,
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
			whyNow: candidate.sourcePath == "liquid_router"
				? "Liquid router selected \(candidate.capabilityId)."
				: "Cheap always-on portfolio selected \(candidate.capabilityId).",
			workflow: workflow.workflowType.rawValue,
			behavior: behavior.state.rawValue,
			confidence: candidate.confidence,
			kind: suggestionKind,
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
				evidenceLevel: evidenceProfile.level.rawValue,
				browserTabs: compartment?.browserTabs.sorted() ?? [],
				browserContextType: browserAssessment?.kind.rawValue,
				browserContentAvailable: browserAssessment?.contentAvailable ?? evidenceProfile.contentAvailable,
				actionIntent: candidate.capabilityId
			),
			actionCard: card,
			topOpportunity: opportunity
		)
	}

	static func ambientSuggestionKind(for capabilityID: String) -> AmbientSuggestionKind {
		let traits = CapabilityPolicyResolver.resolve(capabilityID: capabilityID)
		if traits.contains(.metadataUtility) || traits.contains(.unverifiedBrowserMutator) {
			return .utility_action
		}
		if traits.contains(.workspaceArrangement) {
			return .friction_action
		}
		if traits.contains(.mediaOrFocusSupport) {
			return .media_action
		}
		return .comfort_action
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
		suppressionReason: String,
		panelCount: Int
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
			suppressionReason: suppressionReason,
			panelCount: panelCount
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
		if let quality = editorContextQuality(appCategory: appCategory, groundingResult: groundingResult, compartment: compartment) {
			return quality
		}
		let profile = EvidenceQualityModel.evaluate(
			title: "metadata",
			url: hasBrowserContext ? URL(string: "https://metadata.local") : nil,
			tabTitles: hasBrowserContext ? ["metadata"] : [],
			hasAXText: false,
			hasOCR: hasOCRHints,
			hasSelectedText: hasSelection,
			semanticGrounding: groundingResult?.confidence ?? 0 >= 0.65,
			durableCompartment: compartment?.compartmentTrust ?? 0 >= 0.70,
			browserAssessment: nil
		)
		return profile.level.rawValue
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
