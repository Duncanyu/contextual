import AppKit
import Foundation

/// Proposal payload for panel and floating suggestion UI (same struct from `ProposalGenerator`).
typealias SuggestionViewModel = ActionProposal

/// Binds the visible floating card to lifecycle keys (T10.4).
struct ActiveFloatingLifecycleBinding: Equatable {
	let exactKey: String
	let safeKey: String
	let profile: ContentSimilarityProfile
	let primaryActionId: String
}

enum ActionSourceSurface: String {
	case floating
	case panel
	case unknown
}

struct PendingActionClickContext {
	let sourceSurface: ActionSourceSurface
	let proposalID: String
	let candidateID: String
	let capabilityID: String
	let contractID: String?
	let durableContext: DurableMemoryContext?
	let restoreKey: String?
}

private struct RecentAvailableActionEntry {
	let action: any ActionProtocol
	let cachedAt: Date
}

struct StoredActionResolution {
	let action: (any ActionProtocol)?
	let proposalID: String
	let candidateID: String
	let capabilityID: String
	let contractID: String?
	let resolved: Bool
	let reason: String
	let preservedRecentCandidate: Bool
	let contractValid: Bool
}

private struct FloatingVisibilityState {
	let proposalID: String
	let capabilityID: String
	let shownAt: Date
	let dwellRequiredMs: Int
	var proofVisible: Bool = false
	var proofAttempted: Bool = false
	var feedbackRecorded: Bool = false
}

@MainActor
final class AppState: ObservableObject {
	@Published var isPaused: Bool = false
	/// Latest context for UI (updated by app lifecycle; not built in UI).
	@Published var debugContext: ContextModel = ContextModel()

	/// Metadata-only chips for subtle panel context awareness (T14.9); updated by app lifecycle only.
	@Published var contextAwarenessSummary: ContextAwarenessSummary = .empty

	/// Internal rich-context debug snapshot (T14.10); metadata only; updated by app lifecycle only.
	@Published var richContextDebugSummary: RichContextDebugSummary = .empty

	/// Internal dynamic intent pipeline debug (T15.10); metadata only; updated by app lifecycle only.
	@Published var dynamicIntentDebugSummary: DynamicIntentDebugSummary = .empty

	/// Preview-only generated action display models (T15.11); derived, not persisted; updated by app lifecycle only.
	@Published var dynamicActionDisplaySummary: DynamicActionDisplaySummary = .empty

	/// Unified static + generated assistance ranking snapshot (T16.10); metadata-only; updated with preview refresh.
	@Published var richAssistanceRankingResult: RichAssistanceRankingResult = .empty

	/// Consolidated visible intelligence debug snapshot (T16.11); metadata-only; internal/debug UI only.
	@Published var visibleIntelligenceDebugSummary: VisibleIntelligenceDebugSummary = .empty

	/// Inline assistance candidate snapshot (T16.6 foundations; metadata-only; not rendered inline yet).
	@Published var inlineAssistanceSnapshot: InlineAssistanceSnapshot = .empty

	/// Subtle workflow continuity line for the assistant panel (T16.8); template labels only.
	@Published var workflowContinuitySummary: WorkflowContinuityDisplaySummary = .hidden(
		at: Date(timeIntervalSince1970: 0),
		reasons: ["initial"]
	)

	/// Lightweight metadata for panel proposal card (T16.2); empty when no safe context.
	@Published private(set) var proposalContextSummary: ProposalContextSummary = .unavailable
	/// Same for floating suggestion card.
	@Published private(set) var floatingProposalContextSummary: ProposalContextSummary = .unavailable

	private var lastContextAwarenessLogSignature: String?
	private var lastContextAwarenessLogAt: Date?
	private var lastRichContextDebugLogSignature: String?
	private var lastRichContextDebugLogAt: Date?
	private var lastDynamicIntentDebugLogSignature: String?
	private var lastDynamicIntentDebugLogAt: Date?
	private var lastDynamicActionUXLogSignature: String?
	private var lastDynamicActionUXLogAt: Date?
	private var lastProposalContextLogSignature: String?
	private var lastProposalContextLogAt: Date?
	private var lastProposalContextHiddenSignature: String?
	private var lastProposalContextHiddenAt: Date?
	private var lastWorkflowContinuityLogSignature: String?
	private var lastWorkflowContinuityLogAt: Date?

	/// Actions eligible at last trigger — populated by app lifecycle when a `TriggerPacket` is produced.
	@Published var availableActions: [any ActionProtocol] = [] {
		didSet {
			cacheAvailableActions()
		}
	}
	/// Callable tools (e.g. analyze screen) kept for debug/inline use — not shown as default panel actions (T18.3.2).
	@Published var registeredToolActions: [any ActionProtocol] = []
	@Published private(set) var generatedProposalDebugStatus: GeneratedProposalDebugStatus = .idle
	/// Ranked generated execution proposals for panel list (T18.3; preview only — no auto-execution).
	@Published private(set) var activatedGeneratedProposals: [GeneratedExecutionProposalPanelItem] = []
	@Published private(set) var generatedProposalActivationResult: GeneratedExecutionProposalActivationResult = .empty
	@Published var currentProposal: ActionProposal?
	@Published var currentProposalKey: String?
	@Published var lastAcceptedProposalActionId: String?
	@Published var lastDismissedProposalActionId: String?

	var lastDismissedProposalKey: String?
	var lastDismissedProposalAt: Date?
	var lastAcceptedProposalKey: String?
	var lastAcceptedProposalAt: Date?

	/// T18.6 — Proposal pipeline visibility outcome (metadata only; updated after every publication cycle).
	@Published private(set) var proposalVisibilityState: ProposalVisibilityState = .empty
	/// When the last visible generated proposal was published; used for resurfacing guarantee.
	var lastVisibleProposalAt: Date?

	/// T16.X — Snapshot of all reusable/seeded action records for the Action Library debug view.
	/// Populated on demand when the library view expands; never auto-refreshed.
	@Published private(set) var actionLibrarySnapshot: [ReusableGeneratedActionRecord] = []
	@Published private(set) var highlightedPanelActionID: String?
	@Published private(set) var panelAttentionIndicatorVisible: Bool = false

	/// Loads the latest action library snapshot from the persistence manager. Call when the
	/// library debug view expands; safe to call repeatedly (actor-isolated, non-blocking).
	func refreshActionLibrarySnapshot() {
		Task {
			let records = await GeneratedActionPersistenceManager.shared.snapshot()
			let sorted = records.sorted {
				if $0.workflowType.rawValue != $1.workflowType.rawValue {
					return $0.workflowType.rawValue < $1.workflowType.rawValue
				}
				return $0.usefulnessScore > $1.usefulnessScore
			}
			await MainActor.run { self.actionLibrarySnapshot = sorted }
		}
	}

	private func cacheAvailableActions(now: Date = Date()) {
		pruneRecentAvailableActions(now: now)
		for action in availableActions {
			recentAvailableActions[action.id] = RecentAvailableActionEntry(action: action, cachedAt: now)
			if let panelAction = action as? DeterministicCapabilityPanelAction {
				if LogControl.shared.shouldLog(category: .selection_reasoning, level: .trace) {
					print("[RecentActionCache] stored proposal_id=\(panelAction.proposalID) candidate_id=\(panelAction.candidateID) contract_id=\(panelAction.contractID ?? "missing")")
				}
			}
		}
	}

	private func pruneRecentAvailableActions(now: Date = Date()) {
		recentAvailableActions = recentAvailableActions.filter { _, entry in
			now.timeIntervalSince(entry.cachedAt) <= recentAvailableActionRetentionSeconds
		}
	}

	private func requiresTargetContract(_ capabilityID: String) -> Bool {
		[
			"arrange_side_by_side",
			"switch_to_paired_app",
			"restore_workspace",
			"split_research_setup"
		].contains(capabilityID)
	}

	private func hasValidContract(capabilityID: String, contract: ActionTargetContract?) -> Bool {
		guard requiresTargetContract(capabilityID) else { return true }
		guard let contract else { return false }
		return !contract.isExpired
	}

	// MARK: - Task inference perf stats (debug panel)

	/// Rolling task inference performance stats. Refreshed on demand by the debug panel.
	@Published private(set) var taskInferenceStats: TaskInferenceRollingStats = .empty

	/// Load latest stats from the actor; safe to call from main thread.
	func refreshTaskInferenceStats() {
		Task {
			let model = ActiveModelTierConfig.shared.taskInferenceModel
			let stats = await TaskInferencePerfStats.shared.rollingStats(model: model)
			await MainActor.run { self.taskInferenceStats = stats }
		}
	}

	/// Model audit discovered models — populated after audit runs.
	@Published private(set) var auditDiscoveredModels: [String] = []

	func refreshModelAuditInfo() {
		Task {
			let models = await ModelAuditManager.shared.lastDiscoveredModels()
			await MainActor.run {
				self.auditDiscoveredModels = models
				self.refreshModelStatus()
			}
		}
	}

	// MARK: - Model management state

	/// True while a benchmark audit is in progress.
	@Published private(set) var modelAuditRunning: Bool = false

	/// Whether the selected task inference model uses batch mode (set by audit smoke test).
	@Published private(set) var taskInferenceBatchMode: Bool = false

	/// Whether the audit explicitly found no viable model (the "none" sentinel was stored).
	@Published private(set) var taskInferenceDisabled: Bool = false

	/// The currently active task inference model name, or nil if disabled/not selected.
	@Published private(set) var activeTaskInferenceModel: String? = nil

	/// The planner model name (used for heavier synthesis, set in LocalAISettings).
	var plannerModelName: String { LocalAISettings.shared.modelName }

	func refreshModelStatus() {
		let settings = LocalAISettings.shared
		taskInferenceBatchMode = settings.taskInferenceBatchMode
		if settings.twoStageTaskInferenceEnabled {
			taskInferenceDisabled = false
			activeTaskInferenceModel = "phi4-mini"
		} else {
			taskInferenceDisabled = settings.taskInferenceModel == ModelTierConfig.noViableModel
			activeTaskInferenceModel = settings.effectiveTaskInferenceModel
		}
	}

	/// Trigger a fresh model benchmark audit. Safe to call from UI.
	func triggerModelBenchmark() {
		guard !modelAuditRunning else { return }
		modelAuditRunning = true
		Task.detached(priority: .utility) {
			let base = LocalAISettings.shared.modelName
			await ModelAuditManager.shared.runAudit(baseModel: base)
			await MainActor.run { self.modelAuditRunning = false }
			// refreshModelAuditInfo() also calls refreshModelStatus()
			await self.refreshModelAuditInfo()
			let chosen = await ModelAuditManager.shared.selectedModel() ?? base
			await ModelAuditManager.shared.runWarmupIfNeeded(model: chosen, isManualInvocation: true)
			await ModelAuditManager.shared.startPeriodicKeepalive(model: chosen)
		}
	}

	/// Pull phi4-mini (the recommended fast inference model) then re-run audit.
	func installRecommendedInferenceModel() {
		guard !modelAuditRunning else { return }
		modelAuditRunning = true
		Task.detached(priority: .utility) {
			print("[ModelSelection] installing_recommended model=phi4-mini")
			let ok = await ModelManager.shared.pullModel(named: "phi4-mini")
			if ok {
				let base = LocalAISettings.shared.modelName
				await ModelAuditManager.shared.runAudit(baseModel: base)
			} else {
				print("[ModelSelection] install_failed model=phi4-mini")
			}
			await MainActor.run { self.modelAuditRunning = false }
			await self.refreshModelAuditInfo()
		}
	}

	private let dismissedSuggestionCooldown = CooldownManager()
	private let acceptedSuggestionCooldown = CooldownManager()
	private let dismissedSuggestionCooldownSeconds: TimeInterval = 120
	private let acceptedSuggestionCooldownSeconds: TimeInterval = 60

	// MARK: - Local AI (delegates persistence + orchestration to app lifecycle)

	@Published var modelRuntimeState: ModelRuntimeState = .checking
	@Published var localAIEnabled: Bool = false
	@Published var autoStartOllama: Bool = false
	@Published var twoStageTaskInferenceEnabled: Bool = false {
		didSet {
			LocalAISettings.shared.twoStageTaskInferenceEnabled = twoStageTaskInferenceEnabled
			refreshModelStatus()
		}
	}

	@Published var latestActionResult: String?
	@Published var latestActionId: String?
	@Published var latestActionTimestamp: Date?

	// MARK: - T18.4 — Structured generated execution result
	/// Structured result card for generated execution (replaces raw text in latestActionResult).
	@Published var latestGeneratedExecutionPresentation: GeneratedExecutionResultPresentation?
	/// Calm in-flight label during generated execution ("Preparing context…", "Running…", etc.).
	@Published var generatedExecutionPhaseLabel: String?
	/// Wired by app lifecycle — user-initiated cancel; do NOT call from UI directly.
	var onCancelGeneratedExecution: (() -> Void)?

	/// Mirrors in-flight action execution for UI (updated only by app lifecycle).
	@Published var isActionExecuting: Bool = false
	@Published var executingActionId: String?
	@Published var executingActionTitle: String?

	/// Session-only preference for which input feed text actions use (`automatic` = selection → clipboard → screen OCR).
	@Published var selectedInputSourceChoice: InputSourceChoice = .automatic

	/// Session-only redundancy tuning (T11.7). Never stores raw text.
	let redundancyMemory = RedundancyMemory()

	// MARK: - Hook sandbox (debug only)

	/// Most recent canonical snapshot, updated at every pipeline trigger.
	/// Used exclusively by the hook sandbox debug button — not consumed by any production path.
	public static var lastAssistantInitiatedAppLaunch: String? = nil
	public static var lastAssistantInitiatedAction: String? = nil
	public static var lastAssistantInitiatedAt: Date? = nil

	@Published private(set) var latestCanonicalSnapshot: CanonicalGeneratedExecutionContextSnapshot?

	/// True while the hook sandbox chain is executing (gates button).
	@Published var hookSandboxRunning: Bool = false

	/// Result of the last hook sandbox run. Nil before first run.
	@Published var hookSandboxResult: HookSandboxResult? = nil

	/// Called by AppDelegate each time a canonical proposal snapshot is built.
	/// Keeps the sandbox fed with current context without any production side-effects.
	func updateLatestCanonicalSnapshot(_ snapshot: CanonicalGeneratedExecutionContextSnapshot) {
		self.latestCanonicalSnapshot = snapshot
		// Phase B.1: feed the snapshot into the workflow intelligence producer.
		// Non-blocking, debounced, kill-switch gated. Does NOT touch proposals.
		let producer = workflowEventProducer
		Task { [producer] in
			await producer.ingest(snapshot: snapshot)
		}
	}

	// MARK: - Phase B.1: Workflow Intelligence wiring

	/// Lazy-initialized coordinator + event producer. Created once on first
	/// snapshot. Does NOT interact with existing proposal generation. Disabled
	/// cleanly when `CONTEXTUAL_WORKFLOW_INTELLIGENCE_ENABLED=0`.
	lazy var workflowIntelligenceCoordinator: WorkflowIntelligenceCoordinator = {
		WorkflowIntelligenceCoordinator()
	}()

	lazy var behavioralIntelligenceCoordinator: BehavioralIntelligenceCoordinator = {
		BehavioralIntelligenceCoordinator()
	}()

	lazy var workflowEventProducer: ContextEventProducer = {
		let producer = ContextEventProducer(
			coordinator: workflowIntelligenceCoordinator,
			behavioralCoordinator: behavioralIntelligenceCoordinator
		)
		producer.onAmbientJarvisSuggestionGenerated = { [weak self] suggestion in
			Task { @MainActor in
				self?.publishAmbientJarvisSuggestion(suggestion)
			}
		}
		producer.onAmbientJarvisSuggestionInvalidated = { [weak self] oldEntity, newEntity in
			Task { @MainActor in
				self?.invalidateAmbientJarvisSuggestion(reason: "focus_shift", oldEntity: oldEntity, newEntity: newEntity)
			}
		}
		return producer
	}()

	@Published var activeAmbientJarvisSuggestion: AmbientJarvisSuggestion?
	private var lastAmbientJarvisTargetEntity: String = ""
	var lastAmbientJarvisShownAt: Date? = nil
	private var loggedFeedbackEvents: [String: String] = [:]
	private var pendingAutoDismissDurableFeedback: [String: Task<Void, Never>] = [:]

	func recordSuggestionFeedback(id: String, event: String, reason: String? = nil) {
		let normalizedId = id.replacingOccurrences(of: "ambient_jarvis:", with: "")
		if event == "accepted" {
			cancelPendingDurableFeedback(for: normalizedId)
		}
		let suffix = reason.map { " reason=\($0)" } ?? ""
		if let oldEvent = loggedFeedbackEvents[normalizedId] {
			if oldEvent == "accepted" {
				if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
					print("[SuggestionFeedback] suppressed_duplicate_event id=\(normalizedId) old=\(oldEvent) new=\(event)\(suffix)")
				}
				return
			}
			if event == "accepted" {
				loggedFeedbackEvents[normalizedId] = event
				if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
					print("[SuggestionFeedback] id=\(normalizedId) final_event=\(event)\(suffix)")
				}
				return
			}
			if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
				print("[SuggestionFeedback] suppressed_duplicate_event id=\(normalizedId) old=\(oldEvent) new=\(event)\(suffix)")
			}
			return
		}
		loggedFeedbackEvents[normalizedId] = event
		if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
			print("[SuggestionFeedback] id=\(normalizedId) final_event=\(event)\(suffix)")
		}
	}

	func recordSuggestionClickAttempt(id: String, capabilityId: String) {
		let normalizedId = id.replacingOccurrences(of: "ambient_jarvis:", with: "")
		if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
			print("[SuggestionFeedback] id=\(normalizedId) event=click_attempted capability=\(capabilityId)")
		}
	}

	func wasSuggestionFeedbackLogged(id: String, event: String) -> Bool {
		let normalizedId = id.replacingOccurrences(of: "ambient_jarvis:", with: "")
		return loggedFeedbackEvents[normalizedId] == event
	}

	private func cancelPendingDurableFeedback(for id: String) {
		pendingAutoDismissDurableFeedback[id]?.cancel()
		pendingAutoDismissDurableFeedback.removeValue(forKey: id)
	}

	private func commitDurableFeedback(
		id: String,
		capabilityId: String,
		event: DurableMemoryActionEvent,
		context: DurableMemoryContext,
		restoreKey: String? = nil
	) {
		cancelPendingDurableFeedback(for: id)
		DurableMemory.shared.recordActionFeedback(capabilityId: capabilityId, event: event, context: context)
		if let restoreKey {
			DurableMemory.shared.recordRestoreFeedback(restoreKey: restoreKey, event: event)
		}
	}

	func finalizeActionFeedback(actionID: String, status: CapabilityExecutionStatus?, reason: String? = nil) {
		guard let click = pendingActionClickContext.removeValue(forKey: actionID) else { return }
		let finalReason = reason ?? {
			switch status {
			case .alreadySatisfied: return "already_satisfied"
			case .success: return "execution_success"
			case .partial: return "partial"
			case .previewGenerated: return "preview_generated"
			case .blocked: return "blocked"
			case .cancelled: return "cancelled"
			case .openedSearch: return "opened_search"
			case .unavailable, .none: return requiresTargetContract(click.capabilityID) && click.contractID == nil ? "missing_contract" : "execution_not_verified"
			}
		}()
		let accepted = status == .success || status == .alreadySatisfied
		if accepted {
			recordSuggestionFeedback(id: click.proposalID, event: "accepted", reason: "execution_success")
			if let context = click.durableContext {
				commitDurableFeedback(
					id: click.proposalID.replacingOccurrences(of: "ambient_jarvis:", with: ""),
					capabilityId: click.capabilityID,
					event: .accepted,
					context: context,
					restoreKey: click.restoreKey
				)
			}
			return
		}
		recordSuggestionFeedback(id: click.proposalID, event: "failed", reason: finalReason)
		if click.durableContext != nil {
			print("[DurableMemory] action_feedback skipped capability=\(click.capabilityID) reason=execution_not_verified")
		}
	}

	private func scheduleAutoDismissDurableFeedback(
		id: String,
		capabilityId: String,
		context: DurableMemoryContext,
		restoreKey: String? = nil
	) {
		cancelPendingDurableFeedback(for: id)
		let task = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: 1_000_000_000)
			guard let self, !Task.isCancelled else { return }
			guard self.loggedFeedbackEvents[id] == "auto_dismissed" else {
				self.pendingAutoDismissDurableFeedback.removeValue(forKey: id)
				return
			}
			DurableMemory.shared.recordActionFeedback(capabilityId: capabilityId, event: .autoDismissed, context: context)
			if let restoreKey {
				DurableMemory.shared.recordRestoreFeedback(restoreKey: restoreKey, event: .autoDismissed)
			}
			self.pendingAutoDismissDurableFeedback.removeValue(forKey: id)
		}
		pendingAutoDismissDurableFeedback[id] = task
	}

	private func durableContext(for suggestion: AmbientJarvisSuggestion?) -> DurableMemoryContext? {
		guard let suggestion else { return nil }
		return DurableMemoryContext.build(
			workflow: suggestion.workflow,
			compartment: suggestion.contextPayload?.taskCompartmentSnapshot?.label,
			app: debugContext.activeAppName,
			activity: "active",
			browserType: suggestion.contextPayload?.browserContextType
		)
	}

	func ambientCapabilityId(for suggestion: AmbientJarvisSuggestion, actionId: String? = nil) -> String {
		if let actionId, actionId.contains(":secondary:"), let secondary = suggestion.actionCard?.secondaryAction?.id {
			return secondary
		}
		if let actionId, actionId.contains(":auxiliary:"), let auxiliary = suggestion.actionCard?.auxiliaryAction?.id {
			return auxiliary
		}
		if let cap = suggestion.topOpportunity?.capabilityId, !cap.isEmpty {
			return cap
		}
		if let primary = suggestion.actionCard?.primaryAction.id, !primary.isEmpty {
			return primary
		}
		return suggestion.intent.replacingOccurrences(of: "environment:", with: "")
	}

	private func restoreCooldownKey(for suggestion: AmbientJarvisSuggestion) -> String? {
		let capabilityId = ambientCapabilityId(for: suggestion)
		guard capabilityId == "restore_workspace" else { return nil }
		let apps = suggestion.topOpportunity?.involvedApps ?? []
		let urls = suggestion.topOpportunity?.involvedURLs ?? []
		let compartment = suggestion.contextPayload?.taskCompartmentSnapshot?.label
		return DurableMemory.restoreCooldownKey(apps: apps, urls: urls, compartment: compartment)
	}

	private func durableFeedbackAllowedForFloatingSuggestion(_ suggestionID: String?) -> Bool {
		guard let suggestionID else { return false }
		return floatingVisibilityState?.proposalID == suggestionID && floatingVisibilityState?.proofVisible == true
	}

	private func recordNotVisibleFeedbackIfNeeded(
		for proposalID: String,
		capabilityID: String,
		ambientSuggestion: AmbientJarvisSuggestion?
	) {
		guard floatingVisibilityState?.feedbackRecorded != true else { return }
		recordSuggestionFeedback(id: proposalID, event: "not_visible", reason: "visibility_proof_failed")
		print("[DurableMemory] action_feedback skipped capability=\(capabilityID) reason=not_visible_not_user_feedback")
		if let workflow = AmbientWorkflowType(rawValue: ambientSuggestion?.workflow ?? "") {
			let actionable = workflow != .unknown && workflow != .idle
			SuggestionTickSummaryLog.log(
				modelReady: true,
				startupQuiet: true,
				workflow: workflow,
				workflowActionable: actionable,
				determinerActionable: actionable,
				cheapPortfolioRan: true,
				heavyPlannerRan: false,
				candidatesCount: max(1, availableActions.count),
				selected: capabilityID,
				surfaceResult: "not_visible",
				suppressionReason: "visibility_proof_failed",
				panelCount: availableActions.count
			)
		}
		floatingVisibilityState?.feedbackRecorded = true
	}

	private func finalizePriorAmbientSuggestionIfNeeded(
		_ previous: AmbientJarvisSuggestion,
		replacement: AmbientJarvisSuggestion?
	) {
		let proposalID = "ambient_jarvis:\(previous.id)"
		let capabilityID = ambientCapabilityId(for: previous)
		if durableFeedbackAllowedForFloatingSuggestion(proposalID) {
			recordSuggestionFeedback(id: previous.id, event: "ignored")
			if let context = durableContext(for: previous) {
				DurableMemory.shared.recordActionFeedback(capabilityId: capabilityID, event: .ignored, context: context)
				if let restoreKey = restoreCooldownKey(for: previous) {
					DurableMemory.shared.recordRestoreFeedback(restoreKey: restoreKey, event: .ignored)
				}
				DurableMemory.shared.recordScheduleObservation(context: context, accepted: false, activityState: "active")
			}
		} else {
			recordNotVisibleFeedbackIfNeeded(for: proposalID, capabilityID: capabilityID, ambientSuggestion: previous)
		}
		if replacement?.id != previous.id {
			floatingVisibilityState = nil
		}
	}

	func invalidateAmbientJarvisSuggestion(reason: String, oldEntity: String, newEntity: String) {
		guard activeAmbientJarvisSuggestion != nil else { return }
		if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
			print("[AmbientSuggestionSurface] invalidated reason=\(reason) old_entity=\(oldEntity.prefix(120)) new_entity=\(newEntity.prefix(120))")
		}
		activeAmbientJarvisSuggestion = nil
		currentProposal = nil
		currentProposalKey = nil
		refreshProposalContext(for: nil)
		lastAmbientJarvisTargetEntity = ""
	}
	
	func publishAmbientJarvisSuggestion(_ suggestion: AmbientJarvisSuggestion?) {
		if let previous = activeAmbientJarvisSuggestion,
		   previous.id != suggestion?.id {
			finalizePriorAmbientSuggestionIfNeeded(previous, replacement: suggestion)
		}
		self.activeAmbientJarvisSuggestion = suggestion
		if let suggestion = suggestion {
			if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
				print("[AmbientSuggestionSurface] visible=yes kind=\(suggestion.kind.rawValue)")
				print("[JarvisRouting] route=ambient_context_only")
				// Phase 20D — kind is now display metadata only; intent + judgment
				// are the semantic drivers of execution.
				print("[JarvisRouting] kind=\(suggestion.kind.rawValue) semantic_driver=intent+judgment")
				print("[JarvisRouting] blocked_agentic reason=ambient_context_only")
			}
			
			// Build ActionProposal to match the existing proposal UI card
			let proposal = ActionProposal(
				title: suggestion.title,
				sourceCaption: "Jarvis Suggestion (Preview-Only)",
				primaryActionId: "ambient_jarvis:\(suggestion.id)",
				secondaryActionIds: suggestion.actionCard?.secondaryAction != nil ? ["ambient_jarvis:secondary:\(suggestion.id)"] : [],
				confidence: suggestion.confidence,
				reason: "ambient_context_only"
			)
			self.currentProposal = proposal
			self.currentProposalKey = "ambient_jarvis:\(suggestion.id)"
			self.refreshProposalContext(for: proposal)
			lastAmbientJarvisTargetEntity = suggestion.targetEntity
			self.onAmbientJarvisFloatingSuggestionCandidate?(proposal)
		} else {
			self.currentProposal = nil
			self.currentProposalKey = nil
			self.refreshProposalContext(for: nil)
			lastAmbientJarvisTargetEntity = ""
		}
	}

	/// Kick off the quarantined hook sandbox on the fixed debug test chain.
	/// Safe to call repeatedly; drops concurrent calls.
	func runHookSandboxSample() {
		runHookSandbox(mode: .sample)
	}

	func runHookSandboxLive() {
		runHookSandbox(mode: .live)
	}

	private func runHookSandbox(mode: HookSandboxMode) {
		guard !hookSandboxRunning else { return }
		let snapshot: CanonicalGeneratedExecutionContextSnapshot = {
			switch mode {
			case .sample:
				return HookExecutionSandbox.seededSampleSnapshot()
			case .live:
				// Prefer latest pipeline snapshot, fall back to minimal metadata-only one.
				return latestCanonicalSnapshot ?? CanonicalGeneratedExecutionContextSnapshot(
					activeApp: debugContext.activeAppName ?? "Unknown",
					windowTitle: debugContext.activeWindowTitle ?? ""
				)
			}
		}()
		hookSandboxRunning = true
		hookSandboxResult = nil
		Task.detached(priority: .userInitiated) { [weak self] in
			let result = await HookExecutionSandbox.shared.execute(
				chain: HookExecutionSandbox.defaultTestChain,
				snapshot: snapshot,
				mode: mode
			)
			await MainActor.run { [weak self] in
				self?.hookSandboxRunning = false
				self?.hookSandboxResult = result
			}
		}
	}

	// MARK: - Floating suggestion (T10.1)

	@Published var floatingSuggestion: SuggestionViewModel?
	@Published var isFloatingSuggestionVisible: Bool = false
    @Published var isPanelVisible: Bool = false
    @Published var ambientSuggestionDogfoodMode: Bool = true // Default to true for Phase 20I
	@Published var activeResearchResultCard: ResearchResultCardState? = nil

	/// Phase 4M: True between `ExecutionFocusHandoff.prepare()` and `finalize()`.
	/// Views that contribute to OCR (panel chrome, processing overlays) should
	/// honor this flag and dim/hide while a generated execution is running, so
	/// the runtime's screenshot does not capture assistant chrome instead of
	/// page content. Resets to false on completion.
	@Published private(set) var isExecutionUISuspended: Bool = false

	/// Internal entry point used by the focus-handoff coordinator. Not for UI usage.
	func _setExecutionUISuspended(_ value: Bool) {
		isExecutionUISuspended = value
	}

	let floatingSuggestionLifecycle = FloatingSuggestionLifecycle()
	private var activeFloatingLifecycleBinding: ActiveFloatingLifecycleBinding?
	private var floatingVisibilityState: FloatingVisibilityState?
	private var recentAvailableActions: [String: RecentAvailableActionEntry] = [:]
	private var pendingActionClickContext: [String: PendingActionClickContext] = [:]
	private let floatingVisibilityDwellMilliseconds = 2500
	private let recentAvailableActionRetentionSeconds: TimeInterval = 12
	private let highUsefulnessPanelCapabilities: Set<String> = [
		"arrange_side_by_side",
		"switch_to_paired_app",
		"restore_workspace",
		"split_research_setup"
	]

	private var floatingAutoDismissWorkItem: DispatchWorkItem?
	private let floatingAutoDismissSeconds: TimeInterval = 7

	/// Wired by app lifecycle to enqueue a manual trigger through the normal source pipeline.
	var requestManualInvocation: (() -> Void)?

	/// UI forwards user taps here; app lifecycle resolves execution with current context (UI never reads context).
	var onInvokeActionById: ((String) -> Void)?
	/// User-invoked generated proposal execution; wired by app lifecycle (no UI/runtime coupling).
	var onInvokeGeneratedExecutionProposalById: ((String) -> Void)?

	/// Ephemeral mapping from activated candidate id → execution action (for non-reusable, hook/LLM
	/// generated execution candidates). This avoids persisting raw context while still allowing
	/// user-click execution to resolve the action plan deterministically.
	///
	/// This cache is refreshed on each publication cycle by the app lifecycle.
	var generatedExecutionActionByCandidateId: [String: GeneratedExecutionAction] = [:]
	/// Ephemeral mapping from activated candidate id → hook-composed action contract (hook:...).
	/// Used to route user-invoked "Prepare execution" through the quarantined hook runtime.
	/// Refreshed on each publication cycle (no persistence required).
	private var hookContractByCandidateId: [String: DynamicGeneratedActionContract] = [:]
	/// Ephemeral mapping from activated candidate id → AgenticTaskPlan.
	/// Present only for agentic_runtime_candidate proposals; nil for fixed-chain candidates.
	/// Routes execution to AgenticRuntime instead of GeneratedExecutionRuntime.
	private var agenticPlanByCandidateId: [String: AgenticTaskPlan] = [:]

	var onEnableLocalAI: (() -> Void)?
	var onDisableLocalAI: (() -> Void)?
	var onEnableAutoStartOllama: (() -> Void)?
	var onDisableAutoStartOllama: (() -> Void)?
	var onStartOllamaNow: (() -> Void)?
	var onOpenOllamaDownload: (() -> Void)?
	var onPullLocalAIModel: (() -> Void)?
	/// Opens the assistant popover (menu bar); wired by app lifecycle.
	var onRevealAssistantPanel: (() -> Void)?
	/// Phase 20G.4 — request that the ambient Jarvis suggestion be surfaced
	/// via the floating suggestion panel (legacy path remains unchanged).
	var onAmbientJarvisFloatingSuggestionCandidate: ((ActionProposal) -> Void)?

	func updateHighUsefulnessPanelVisibility() {
		let highlighted = availableActions.first {
			(($0 as? DeterministicCapabilityPanelAction)?.capabilityId).map(highUsefulnessPanelCapabilities.contains) ?? highUsefulnessPanelCapabilities.contains($0.id)
		}
		let nextHighlightedID = (isFloatingSuggestionVisible || highlighted == nil) ? nil : highlighted?.id
		let apply = { [weak self] in
			guard let self else { return }
			self.highlightedPanelActionID = nextHighlightedID
			self.panelAttentionIndicatorVisible = nextHighlightedID != nil
			if let action = highlighted, nextHighlightedID != nil {
				let capability = (action as? DeterministicCapabilityPanelAction)?.capabilityId ?? action.id
				print("[PanelVisibility] capability=\(capability) visible=yes highlighted=yes reason=high_usefulness_panel_fallback")
			}
		}
		if isPanelVisible {
			print("[SurfaceLayoutGuard] deferred reason=avoid_layout_recursion")
			DispatchQueue.main.async(execute: apply)
		} else {
			apply()
		}
	}

	func resolveStoredAction(id: String, context: ContextModel, now: Date = Date()) -> StoredActionResolution {
		pruneRecentAvailableActions(now: now)
		if let current = availableActions.first(where: { $0.id == id }) {
			let capabilityID = (current as? DeterministicCapabilityPanelAction)?.capabilityId ?? id
			let candidateID = (current as? DeterministicCapabilityPanelAction)?.candidateID ?? id
			let proposalID = (current as? DeterministicCapabilityPanelAction)?.proposalID ?? id
			let contract = (current as? DeterministicCapabilityPanelAction)?.targetContract
			let contractValid = hasValidContract(capabilityID: capabilityID, contract: contract)
			return StoredActionResolution(
				action: current,
				proposalID: proposalID,
				candidateID: candidateID,
				capabilityID: capabilityID,
				contractID: contract?.contractID,
				resolved: true,
				reason: "current",
				preservedRecentCandidate: false,
				contractValid: contractValid
			)
		}
		if let recent = recentAvailableActions[id] {
			let capabilityID = (recent.action as? DeterministicCapabilityPanelAction)?.capabilityId ?? id
			let candidateID = (recent.action as? DeterministicCapabilityPanelAction)?.candidateID ?? id
			let proposalID = (recent.action as? DeterministicCapabilityPanelAction)?.proposalID ?? id
			let contract = (recent.action as? DeterministicCapabilityPanelAction)?.targetContract
			let contractValid = hasValidContract(capabilityID: capabilityID, contract: contract)
			let canExecute = recent.action.canExecute(context: context)
			if contractValid && canExecute {
				return StoredActionResolution(
					action: recent.action,
					proposalID: proposalID,
					candidateID: candidateID,
					capabilityID: capabilityID,
					contractID: contract?.contractID,
					resolved: true,
					reason: "recent_valid",
					preservedRecentCandidate: true,
					contractValid: true
				)
			}
			return StoredActionResolution(
				action: nil,
				proposalID: proposalID,
				candidateID: candidateID,
				capabilityID: capabilityID,
				contractID: contract?.contractID,
				resolved: false,
				reason: contractValid ? "stale" : "missing_contract",
				preservedRecentCandidate: true,
				contractValid: contractValid
			)
		}
		return StoredActionResolution(
			action: nil,
			proposalID: id,
			candidateID: id,
			capabilityID: id,
			contractID: nil,
			resolved: false,
			reason: "stale",
			preservedRecentCandidate: false,
			contractValid: false
		)
	}

	func pendingClickContext(for actionID: String) -> PendingActionClickContext? {
		pendingActionClickContext[actionID]
	}

	func invokeAction(id: String, sourceSurface: ActionSourceSurface = .panel) {
		if id.hasPrefix("ambient_jarvis:") {
			if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
				print("[AmbientSuggestionSurface] accepted id=\(id)")
			}
			Task {
				if let suggestion = self.activeAmbientJarvisSuggestion {
					let capabilityId = self.ambientCapabilityId(for: suggestion, actionId: id)
					let proposalID = suggestion.topOpportunity?.id ?? suggestion.id
					let candidateID = suggestion.topOpportunity?.candidateID ?? proposalID
					let targetContract = suggestion.topOpportunity?.targetContract
					let durableContext = self.durableContext(for: suggestion)
					let restoreKey = self.restoreCooldownKey(for: suggestion)
					self.recordSuggestionClickAttempt(id: proposalID, capabilityId: capabilityId)
					self.pendingActionClickContext[id] = PendingActionClickContext(
						sourceSurface: sourceSurface,
						proposalID: proposalID,
						candidateID: candidateID,
						capabilityID: capabilityId,
						contractID: targetContract?.contractID,
						durableContext: durableContext,
						restoreKey: restoreKey
					)
					if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
						print("[ActionClick] source_surface=\(sourceSurface.rawValue) proposal_id=\(proposalID) candidate_id=\(candidateID) capability=\(capabilityId) contract_id=\(targetContract?.contractID ?? "missing")")
					}
					if let durableContext {
						DurableMemory.shared.recordScheduleObservation(context: durableContext, accepted: true, activityState: "active")
					}
					let environmentActionIds: Set<String> = [
						"play_focus_media",
						"pause_media",
						"open_relevant_app",
						"launch_recent_workspace",
						"open_related_app_set",
						"start_focus_timer",
						// Phase 26.1 — Friction-reduction capabilities route through executor, not text generation
						"collect_references",
						"pin_reference_tabs",
						"restore_research_tabs",
						"restore_workspace",
						"arrange_side_by_side",
						"switch_to_paired_app",
						"split_research_setup",
						"copy_current_url",
						"remember_workspace",
						"open_current_task_panel",
						"resume_focus_media",
						"extract_and_organize",
						"precompute_answer",
					]
					let isSecondary = id.contains(":secondary:")
					let isAuxiliary = id.contains(":auxiliary:")
					let isEnvIntent = suggestion.intent.hasPrefix("environment:")
					
					// A card is an environment card if its primary action is a known environment ID,
					// or if it explicitly specifies local_action execution with system_action output.
					let isEnvCard = suggestion.actionCard.map { card in
						environmentActionIds.contains(card.primaryAction.id) ||
						(card.primaryAction.executionMode == .local_action && card.primaryAction.outputType == "system_action")
					} ?? false

					if (isEnvIntent || isEnvCard) && !isSecondary && !isAuxiliary {
						print("[ActionClickRouter] route=environment_executor")
						print("[ActionClickRouter] skipped_context_execution=yes")

						let actionTypeStr = suggestion.actionCard?.primaryAction.id ?? suggestion.intent.replacingOccurrences(of: "environment:", with: "")

						let executionMode = suggestion.actionCard?.primaryAction.executionMode ?? .local_action
						let type = EnvironmentActionType(rawValue: actionTypeStr) ?? .playFocusMedia
						// Phase 28.3: Carry MusicIntent from the opportunity through click routing.
						// Without this, "Resume your music?" clicks lose the intent and fall to search.
						let clickMusicIntent = suggestion.topOpportunity?.musicIntent
						let actionApps = suggestion.topOpportunity?.involvedApps
							.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
						let fallbackApps = suggestion.actionCard?.primaryAction.inputRequirements ?? []
						let supplementalContext: [String: Any] = [
							"tabTitles": suggestion.topOpportunity?.browserTabTitles ?? suggestion.contextPayload?.browserTabs ?? [],
							"tabURLs": suggestion.topOpportunity?.involvedURLs ?? [],
							"url": suggestion.topOpportunity?.involvedURLs.first as Any,
							"title": suggestion.topOpportunity?.browserTabTitles.first as Any,
							"currentEntity": suggestion.targetEntity,
							"workflow": suggestion.workflow,
							"behavior": suggestion.behavior,
							"activeTerms": suggestion.contextPayload?.activeTerms ?? [],
							"comparisonCandidates": suggestion.contextPayload?.comparisonCandidates ?? [],
							"relatedEntities": suggestion.contextPayload?.relatedFocusEntities ?? [],
							"suggestionTitle": suggestion.title,
							"targetContract": targetContract as Any,
							"candidate_id": candidateID,
							"source_surface": sourceSurface.rawValue,
							"proposal_id": proposalID
						]
						let action = EnvironmentAction(
							type: type,
							title: suggestion.title,
							reasoning: suggestion.intentGoal,
							executionMode: executionMode,
							requiresConfirmation: suggestion.actionCard?.primaryAction.requiresConfirmation ?? true,
							apps: actionApps.isEmpty ? fallbackApps : actionApps,
							capabilityId: actionTypeStr,
							musicIntent: clickMusicIntent,
							compartment: suggestion.contextPayload?.taskCompartmentSnapshot,
							workflow: AmbientWorkflowType(rawValue: suggestion.workflow)
						)
						let requiresContract = ["arrange_side_by_side", "switch_to_paired_app", "restore_workspace", "split_research_setup"].contains(actionTypeStr)
						let targetContract = supplementalContext["targetContract"] as? ActionTargetContract
						print("[ActionPreflight] capability=\(actionTypeStr) contract_id=\(targetContract?.contractID ?? "missing") status=\(requiresContract && targetContract == nil ? "blocked" : "ok")")

						// Phase 31 — Check action readiness before execution
						let _ = LocalActionReadiness.check(
							capabilityId: actionTypeStr,
							involvedApps: action.apps,
							involvedURLs: suggestion.topOpportunity?.involvedURLs ?? [],
							browserTabTitles: suggestion.topOpportunity?.browserTabTitles ?? suggestion.contextPayload?.browserTabs ?? []
						)

						// Phase 33 — Payload handoff audit
						let _ = PayloadHandoffAudit.verify(
							proposalId: suggestion.topOpportunity?.id ?? suggestion.id,
							capabilityId: actionTypeStr,
							generatedTargets: suggestion.topOpportunity?.involvedApps ?? [],
							clickedTargets: action.apps,
							generatedURLs: suggestion.topOpportunity?.involvedURLs ?? [],
							clickedURLs: (supplementalContext["tabURLs"] as? [String]) ?? []
						)

						let status = await EnvironmentActionExecutor.previewOrExecute(action, supplementalContext: supplementalContext)
						print("[EnvironmentActionExecution] completed status=\(status.rawValue)")
						await MainActor.run {
							self.finalizeActionFeedback(actionID: id, status: status)
						}

						if executionMode == .preview_only {
							let previewText = suggestion.actionCard?.previewPayload.render() ?? "Preview for workspace action"
							await MainActor.run {
								self.latestActionResult = previewText
								self.latestActionTimestamp = Date()
								self.latestActionId = id
							}
						} else {
							// For actual execution (local_action), we clear any previous result text.
							await MainActor.run {
								self.latestActionResult = nil
								self.latestActionTimestamp = Date()
								self.latestActionId = id
							}
						}
						return
					}

					// Special case: copy_result_to_clipboard auxiliary click
					if isAuxiliary && suggestion.actionCard?.auxiliaryAction?.id == "copy_result_to_clipboard" {
						print("[ActionClickRouter] route=capability_executor reason=auxiliary_copy")
						let resultText = self.latestActionResult ?? ""
						let _ = await CapabilityExecutor.shared.execute(
							capability: suggestion.actionCard!.auxiliaryAction!,
							context: ["text": resultText]
						)
						return
					}

					// Otherwise, route through ContextExecutionEngine:
					// This handles cognitive-only suggestions AND secondary clicks for hybrid suggestions.
					if isSecondary {
						print("[ActionClickRouter] route=context_execution reason=secondary_click_on_hybrid")
					}

					// Phase 31 — Context acquisition before execution
					let capId = suggestion.topOpportunity?.capabilityId ?? suggestion.intent
					let payload = suggestion.contextPayload
					let acquisitionPlan = ContextAcquisitionPlanner.plan(
						capabilityId: capId,
						activeApp: payload?.workingMemorySnapshot.currentEntity ?? "",
						bundleId: "",
						hasAXText: false,
						hasOCR: false,
						hasVisualDescriptor: false,
						hasBrowserTabs: !(payload?.browserTabs ?? []).isEmpty,
						hasSelectedText: false,
						hasClipboard: false,
						groundedFactsCount: 0,
						evidenceQuality: payload?.evidenceQuality ?? "title_only"
					)
					ContextAcquisitionPlanner.emit(acquisitionPlan)

					// Phase 31 — Emit execution context snapshot
					if let opp = suggestion.topOpportunity {
						let execSnapshot = ExecutionContextSnapshot.build(
							proposalId: opp.id,
							capabilityId: opp.capabilityId,
							activeApp: suggestion.contextPayload?.workingMemorySnapshot.currentEntity ?? "",
							bundleId: "",
							windowTitle: suggestion.targetEntity,
							browserSelectedTitle: suggestion.contextPayload?.browserTabs.first,
							browserSelectedURL: nil,
							browserTabTitles: suggestion.contextPayload?.browserTabs ?? [],
							compartment: suggestion.contextPayload?.taskCompartmentSnapshot,
							evidenceQuality: suggestion.contextPayload?.evidenceQuality ?? "unknown",
							hasOCR: false,
							hasAXText: false,
							hasSelectedText: false,
							targetApps: opp.involvedApps,
							targetURLs: opp.involvedURLs
						)
						execSnapshot.emit()
					}

					let snapshot = self.latestCanonicalSnapshot
					let result = await ContextExecutionEngine.execute(
						suggestion: suggestion,
						snapshot: snapshot
					)
					let outputText = result.render()

					await MainActor.run {
						let researchActions: Set<String> = [
							"explicit_visible_capture_summary", "summarize_visible_content", "extract_action_items", "create_checklist",
							"rewrite_text", "explain_context", "draft_reply", "diagnose_error", "synthesize_advice", "summarize_thread"
						]
						if researchActions.contains(capId) || suggestion.kind == .cognitive_action {
							self.activeResearchResultCard = ResearchResultCardState(
								capabilityID: capId,
								title: suggestion.title,
								text: outputText,
								outputChars: outputText.count
							)
							if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
								print("[ResearchResultCard] shown capability=\(capId) output_chars=\(outputText.count) dismissible=yes open_panel_option=yes")
							}
						} else {
							self.latestActionResult = outputText
							self.latestActionTimestamp = Date()
							self.latestActionId = id
						}
					}
				}
			}
			return
		}
		if id.hasPrefix(GeneratedExecutionProposalActivator.generatedProposalIdPrefix) {
			let candidateId = String(id.dropFirst(GeneratedExecutionProposalActivator.generatedProposalIdPrefix.count))
			invokeGeneratedExecutionProposal(id: candidateId)
			return
		}
		let resolution = resolveStoredAction(id: id, context: debugContext)
		recordSuggestionClickAttempt(id: resolution.proposalID, capabilityId: resolution.capabilityID)
		pendingActionClickContext[id] = PendingActionClickContext(
			sourceSurface: sourceSurface,
			proposalID: resolution.proposalID,
			candidateID: resolution.candidateID,
			capabilityID: resolution.capabilityID,
			contractID: resolution.contractID,
			durableContext: nil,
			restoreKey: nil
		)
		print("[ActionClick] source_surface=\(sourceSurface.rawValue) proposal_id=\(resolution.proposalID) candidate_id=\(resolution.candidateID) capability=\(resolution.capabilityID) contract_id=\(resolution.contractID ?? "missing")")
		GeneratedActionInteractionTracker.shared.considerAcceptedProxy(staticActionId: resolution.capabilityID)
		onInvokeActionById?(id)
	}

	/// Resolves `automatic` using the same minimum-length gates as text actions; otherwise returns the user’s explicit choice.
	func effectiveInputSource(for context: ContextModel, minimumUsefulLength: Int = 30) -> InputSourceChoice {
		switch selectedInputSourceChoice {
		case .automatic:
			if context.selectedTextAvailable && context.selectedTextLength >= minimumUsefulLength { return .selectedText }
			if context.clipboardTextAvailable && context.clipboardTextLength >= minimumUsefulLength { return .clipboard }
			if context.screenOCRAvailable && context.screenOCRTextLength >= minimumUsefulLength { return .screenOCR }
			return .automatic
		case .selectedText, .clipboard, .screenOCR:
			return selectedInputSourceChoice
		}
	}

	func inputSourceUsageDescription(for context: ContextModel) -> String {
		let resolved = effectiveInputSource(for: context)
		if selectedInputSourceChoice == .automatic {
			if resolved == .automatic {
				return "Using: Automatic (no text input)"
			}
			return "Using: Automatic → \(resolved.usingLabel)"
		}
		return "Using: \(resolved.usingLabel)"
	}

	func isInputSourceChoiceAvailable(_ choice: InputSourceChoice, context: ContextModel) -> Bool {
		switch choice {
		case .automatic:
			return true
		case .selectedText:
			return context.selectedTextAvailable && context.selectedTextLength > 0
		case .clipboard:
			return context.clipboardTextAvailable && context.clipboardTextLength > 0
		case .screenOCR:
			return context.screenOCRAvailable && context.screenOCRTextLength > 0
		}
	}

	/// Log-safe key (hashes text-bearing segments; never logs raw selection or titles).
	func floatingSuggestionLogKey(for proposal: ActionProposal, context: ContextModel) -> String {
		let trigH = currentProposalKey.map { String(fnv1a64(text: $0), radix: 16) } ?? "nil"
		let titleH = String(fnv1a64(text: proposal.title), radix: 16)
		let sk = suggestionKey(for: proposal, context: context)
		let skH = String(fnv1a64(text: sk), radix: 16)
		return "trigHash=\(trigH)|primary=\(proposal.primaryActionId)|titleHash=\(titleH)|src=\(selectedInputSourceChoice.rawValue)|skHash=\(skH)"
	}

	func suggestionKey(for proposal: ActionProposal, context: ContextModel) -> String {
		let triggerPrefix = currentProposalKey ?? "unknown_trigger|\(proposal.primaryActionId)"
		let selectionLen = context.selectedTextLength
		let clipboardLen = context.clipboardTextLength

		let selectionHash = selectionFingerprint(context: context)
		let clipboardHash = clipboardFingerprint()

		return [
			triggerPrefix,
			proposal.title,
			"selLen=\(selectionLen)",
			"clipLen=\(clipboardLen)",
			selectionHash.map { "selHash=\($0)" } ?? "selHash=nil",
			clipboardHash.map { "clipHash=\($0)" } ?? "clipHash=nil"
		].joined(separator: "|")
	}

	func isSuggestionOnCooldown(_ proposal: ActionProposal, context: ContextModel, now: Date = Date()) -> Bool {
		let key = suggestionKey(for: proposal, context: context)
        
        let dismissedInterval = ambientSuggestionDogfoodMode ? 10.0 : dismissedSuggestionCooldownSeconds
        let acceptedInterval = ambientSuggestionDogfoodMode ? 30.0 : acceptedSuggestionCooldownSeconds

		if dismissedSuggestionCooldown.isCoolingDown(key: key, interval: dismissedInterval, now: now) {
			return true
		}
		if acceptedSuggestionCooldown.isCoolingDown(key: key, interval: acceptedInterval, now: now) {
			return true
		}
		return false
	}

	func acceptCurrentProposal() {
		guard let proposal = currentProposal else { return }
		let id = proposal.primaryActionId
		let suggestionKey = suggestionKey(for: proposal, context: debugContext)
		let redundancyKey = String(fnv1a64(text: suggestionKey), radix: 16)
		print("[SuggestionCard] accepted proposal primary=\(id)")
		lastAcceptedProposalActionId = id

		redundancyMemory.record(event: .accepted, key: redundancyKey, actionId: id)

		acceptedSuggestionCooldown.markFired(key: suggestionKey)

		if let key = currentProposalKey {
			lastAcceptedProposalKey = key
			lastAcceptedProposalAt = Date()
			print("[ProposalCooldown] recorded accept key=\(key)")
		}

		if id.hasPrefix(GeneratedExecutionProposalActivator.generatedProposalIdPrefix) {
			let candidateId = String(id.dropFirst(GeneratedExecutionProposalActivator.generatedProposalIdPrefix.count))
			invokeGeneratedExecutionProposal(id: candidateId)
		} else {
			invokeAction(id: id)
		}
		currentProposal = nil
		currentProposalKey = nil
		refreshProposalContext(for: nil)
	}

	func applyGeneratedProposalActivation(
		_ result: GeneratedExecutionProposalActivationResult,
		debugStatus: GeneratedProposalDebugStatus? = nil
	) {
		let now = Date()
		let bundle = debugContext.activeAppBundleIdentifier ?? String(debugContext.activeAppName?.lowercased().prefix(20) ?? "unknown")
		let titlePrefix = String(debugContext.activeWindowTitle?.prefix(40) ?? "")

		// T18.6B — Smart preservation: keep existing proposals during transient failures/suppressions.
		//
		// Task A: Only clear on hard invalidation events (app changed, TTL expired, safety).
		// Same-app title churn, failed hook discovery, empty candidate results, and transient
		// no-trigger states must NOT clear a successfully visible proposal.
		let lastRes = generatedProposalActivationResult
		let lastBundle = lastRes.warnings.first(where: { $0.hasPrefix("bundle:") })?.replacingOccurrences(of: "bundle:", with: "")

		let ttlExpired = now.timeIntervalSince(generatedProposalActivationResult.createdAt) > 600
		let bundleChanged = (lastBundle != nil) && (lastBundle != bundle)

		// Compute clear_check log values before the preserve decision
		let existingCount = activatedGeneratedProposals.count
		if existingCount > 0 {
			if LogControl.shared.shouldLog(category: .selection_reasoning, level: .debug) {
				print("[GeneratedProposalState] clear_check existing=\(existingCount) anchor_match=\(!bundleChanged) ttl_expired=\(ttlExpired) strong_context_change=\(bundleChanged)")
			}
		}

		let shouldPreserve: Bool = Self.preservationDecision(
			existingCount: activatedGeneratedProposals.count,
			newVisibleCount: result.visibleProposals.count,
			isPolicySuppressed: result.isPolicySuppressed,
			bundleChanged: bundleChanged,
			ttlExpired: ttlExpired
		)

		if shouldPreserve {
			let failureLabel: String
			if result.visibleProposals.isEmpty {
				failureLabel = "refinement_failed_no_valid_replacement"
			} else {
				failureLabel = "policy_suppressed"
			}
			if LogControl.shared.shouldLog(category: .selection_reasoning, level: .debug) {
				print("[GeneratedProposalState] preserving existing reason=\(failureLabel) existing=\(activatedGeneratedProposals.count)")
			}

			// T18.6B — Update metadata but KEEP previous context warnings so we don't lose the "where" anchor.
			let lastWarnings = generatedProposalActivationResult.warnings.filter { $0.hasPrefix("bundle:") || $0.hasPrefix("title:") }
			let resultWithContext = GeneratedExecutionProposalActivationResult(
				visibleProposals: activatedGeneratedProposals,
				visibleStaticActionIds: result.visibleStaticActionIds,
				suppressedGeneratedCount: result.suppressedGeneratedCount,
				suppressedStaticCount: result.suppressedStaticCount,
				topSourceType: result.topSourceType,
				rankingSummary: result.rankingSummary,
				timingDecision: result.timingDecision,
				warnings: result.warnings + lastWarnings,
				createdAt: result.createdAt,
				floatingGeneratedProposalId: result.floatingGeneratedProposalId,
				isPolicySuppressed: result.isPolicySuppressed
			)
			generatedProposalActivationResult = resultWithContext
			if let debugStatus {
				generatedProposalDebugStatus = debugStatus
			}
			return
		}

		if result.visibleProposals.isEmpty {
			let clearReason: String
			if bundleChanged { clearReason = "strong_context_change" }
			else if ttlExpired { clearReason = "ttl_expired" }
			else { clearReason = "context_invalidated_or_expired" }
			if LogControl.shared.shouldLog(category: .selection_reasoning, level: .debug) {
				print("[GeneratedProposalState] clearing reason=\(clearReason)")
			}
		} else {
			if LogControl.shared.shouldLog(category: .selection_reasoning, level: .debug) {
				print("[GeneratedProposalState] replacing visible_generated=\(result.visibleProposals.count) reason=new_success")
			}
		}

		generatedProposalActivationResult = result
		// Inject bundle/title into warnings for context-aware preservation check in next cycle.
		let resultWithContext = GeneratedExecutionProposalActivationResult(
			visibleProposals: result.visibleProposals,
			visibleStaticActionIds: result.visibleStaticActionIds,
			suppressedGeneratedCount: result.suppressedGeneratedCount,
			suppressedStaticCount: result.suppressedStaticCount,
			topSourceType: result.topSourceType,
			rankingSummary: result.rankingSummary,
			timingDecision: result.timingDecision,
			warnings: result.warnings + ["bundle:\(bundle)", "title:\(titlePrefix)"],
			createdAt: result.createdAt,
			floatingGeneratedProposalId: result.floatingGeneratedProposalId,
			isPolicySuppressed: result.isPolicySuppressed
		)
		generatedProposalActivationResult = resultWithContext
		activatedGeneratedProposals = result.visibleProposals
		if let debugStatus {
			generatedProposalDebugStatus = debugStatus
		}
		if LogControl.shared.shouldLog(category: .selection_reasoning, level: .debug) {
			print("[GeneratedProposalState] app_state_visible_generated=\(activatedGeneratedProposals.count)")
		}
	}

	/// Clear the activated generated proposals from the panel. Owned here so the
	/// `private(set)` encapsulation of `activatedGeneratedProposals` is preserved.
	/// Used by the Day 2 Ambient MVP suppression path in AppDelegate.
	func clearActivatedGeneratedProposals(reason: String) {
		guard !activatedGeneratedProposals.isEmpty else { return }
		if LogControl.shared.shouldLog(category: .selection_reasoning, level: .debug) {
			print("[GeneratedProposalState] cleared count=\(activatedGeneratedProposals.count) reason=\(reason)")
		}
		activatedGeneratedProposals = []
	}

	/// Determines whether existing visible proposals should be preserved when a new activation
	/// result arrives. Extracted as a static helper for deterministic self-testing (Task E).
	///
	/// Preserve when:
	/// - There are existing proposals to preserve (existingCount > 0)
	/// - The new result has no visible proposals or is policy-suppressed (failed/empty attempt)
	/// - The app bundle has NOT changed (same app)
	/// - The TTL has NOT expired
	///
	/// - Returns: `true` if existing proposals should be kept; `false` to replace/clear.
	nonisolated static func preservationDecision(
		existingCount: Int,
		newVisibleCount: Int,
		isPolicySuppressed: Bool,
		bundleChanged: Bool,
		ttlExpired: Bool
	) -> Bool {
		// Nothing to preserve
		guard existingCount > 0 else { return false }
		// New result has content and is not suppressed — replace with fresh proposals
		if newVisibleCount > 0 && !isPolicySuppressed { return false }
		// Hard invalidation: app switched
		if bundleChanged { return false }
		// Hard invalidation: proposals are stale
		if ttlExpired { return false }
		// Failed/empty attempt on same app within TTL — keep existing
		return true
	}

	/// App lifecycle injects the latest in-memory executable actions for generated proposals.
	/// Reusable template executions are resolved via persistence; this cache is for non-reusable
	/// synthesized candidates (e.g. hook-composed fast path).
	func cacheGeneratedExecutionCandidateActions(_ candidates: [GeneratedExecutionProposalCandidate]) {
		let now = Date()
		for candidate in candidates {
			guard let action = candidate.executionAction else { continue }
			generatedExecutionActionByCandidateId[candidate.id] = action
			if let anchor = action.targetAnchor {
				print("[TargetAnchorTrace] stage=visible_action_created anchor_nil=no")
				print("[TargetAnchorTrace] bundle=\(anchor.bundleIdentifier)")
				print("[TargetAnchorTrace] title=\"\(anchor.windowTitle.prefix(80))\"")
			} else {
				print("[TargetAnchorTrace] stage=visible_action_created anchor_nil=yes")
				if let snap = latestCanonicalSnapshot,
				   let bundle = snap.bundleIdentifier,
				   !bundle.isEmpty,
				   bundle != Bundle.main.bundleIdentifier,
				   !snap.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					print("[TargetAnchorTrace] error=anchor_lost_at_candidate_creation")
				}
			}
			// Cache AgenticTaskPlan when present — routes execution to AgenticRuntime.
			if var plan = candidate.agenticPlan {
				let alignment = AgenticGoalAlignmentValidator.validate(
					title: candidate.title,
					goal: plan.goal,
					workflow: plan.workflow,
					appName: latestCanonicalSnapshot?.activeApp ?? "Unknown",
					bundleId: latestCanonicalSnapshot?.bundleIdentifier ?? "",
					windowTitle: latestCanonicalSnapshot?.windowTitle ?? "",
					ocrExcerpt: latestCanonicalSnapshot?.recentOCRExcerpt,
					axExcerpt: nil
				)
				if !AgenticPivot.useDirectAgentRuntime && alignment.status == AgenticGoalAlignmentDecision.Status.rejected {
					print("[AgenticPlanCache] rejected reason=goal_alignment_failed")
					continue
				}
				if !AgenticPivot.useDirectAgentRuntime && alignment.status == AgenticGoalAlignmentDecision.Status.repaired {
					plan = AgenticTaskPlan(
						id: plan.id,
						goal: alignment.alignedGoal, // Repaired goal
						workflow: plan.workflow,
						sourceProposalId: plan.sourceProposalId,
						allowedActionFamilies: plan.allowedActionFamilies,
						requiredObservations: plan.requiredObservations,
						successCriteria: plan.successCriteria,
						stopConditions: plan.stopConditions,
						maxSteps: plan.maxSteps,
						maxLLMCalls: plan.maxLLMCalls,
						maxOCRCalls: plan.maxOCRCalls,
						maxRuntimeSeconds: plan.maxRuntimeSeconds,
						requiresPermission: plan.requiresPermission,
						safetyLevel: plan.safetyLevel,
						createdAt: plan.createdAt
					)
					agenticPlanByCandidateId[candidate.id] = plan
					print("[AgenticPlanCache] stored id=\(candidate.id.prefix(40)) goal=\(plan.goal.prefix(60)) reason=goal_alignment_repaired")
				} else {
					agenticPlanByCandidateId[candidate.id] = plan
					print("[AgenticPlanCache] stored id=\(candidate.id.prefix(40)) goal=\(plan.goal.prefix(60))")
				}
				if let anchor = candidate.targetAnchor {
					print("[TargetAnchorTrace] stage=plan_cache_store anchor_nil=no")
					print("[TargetAnchorTrace] bundle=\(anchor.bundleIdentifier)")
					print("[TargetAnchorTrace] title=\"\(anchor.windowTitle.prefix(80))\"")
				} else {
					print("[TargetAnchorTrace] stage=plan_cache_store anchor_nil=yes")
				}
			}
		}
		for (id, action) in generatedExecutionActionByCandidateId {
			if now >= action.expirationDate {
				generatedExecutionActionByCandidateId.removeValue(forKey: id)
				agenticPlanByCandidateId.removeValue(forKey: id)
			}
		}
	}

	func cachedGeneratedExecutionAction(candidateId: String) -> GeneratedExecutionAction? {
		generatedExecutionActionByCandidateId[candidateId]
	}

	func cachedAgenticPlan(candidateId: String) -> AgenticTaskPlan? {
		if let plan = agenticPlanByCandidateId[candidateId] {
			print("[AgenticPlanCache] lookup id=\(candidateId.prefix(40)) found=yes")
			return plan
		}
		print("[AgenticPlanCache] lookup id=\(candidateId.prefix(40)) found=no")
		return nil
	}

	func cacheHookContracts(_ contracts: [DynamicGeneratedActionContract]) {
		let now = Date()
		for contract in contracts {
			guard contract.id.hasPrefix("hook:") else { continue }
			hookContractByCandidateId[contract.id] = contract
		}
		for (id, contract) in hookContractByCandidateId {
			if now >= contract.expiresAt {
				hookContractByCandidateId.removeValue(forKey: id)
			}
		}
	}

	func isProposalValid(candidateId: String) -> Bool {
		let now = Date()
		if candidateId.hasPrefix("hook:") {
			if let contract = hookContractByCandidateId[candidateId], now < contract.expiresAt {
				print("[GeneratedProposalValidity] id=\(candidateId) contract=\(contract.id) exists=true executable=true")
				return true
			} else {
				let contractId = hookContractByCandidateId[candidateId]?.id ?? "nil"
				print("[GeneratedProposalValidity] id=\(candidateId) contract=\(contractId) exists=\(contractId != "nil" ? "true" : "false") executable=false")
				return false
			}
		}
		print("[GeneratedProposalValidity] id=\(candidateId) contract=nil exists=true executable=true")
		return true
	}

	func validateAndPruneProposals() {
		let now = Date()
		var updatedList = [GeneratedExecutionProposalPanelItem]()
		var changed = false
		
		for item in activatedGeneratedProposals {
			if item.id.hasPrefix("hook:") {
				if let contract = hookContractByCandidateId[item.id], now < contract.expiresAt {
					updatedList.append(item)
					print("[GeneratedProposalValidity] id=\(item.id) contract=\(contract.id) exists=true executable=true")
				} else {
					changed = true
					let contractId = hookContractByCandidateId[item.id]?.id ?? "nil"
					print("[GeneratedProposalValidity] id=\(item.id) contract=\(contractId) exists=\(contractId != "nil" ? "true" : "false") executable=false")
					print("[GeneratedProposalEviction] id=\(item.id) contract=\(contractId)")
				}
			} else {
				updatedList.append(item)
			}
		}
		
		if changed {
			activatedGeneratedProposals = updatedList
			refreshDynamicActionDisplaySummary()
		}
	}

	func cachedHookContract(candidateId: String) -> DynamicGeneratedActionContract? {
		let now = Date()
		// Prune expired
		for (id, contract) in hookContractByCandidateId {
			if now >= contract.expiresAt {
				hookContractByCandidateId.removeValue(forKey: id)
			}
		}
		let contract = hookContractByCandidateId[candidateId]
		if candidateId.hasPrefix("hook:") {
			let exists = contract != nil
			let executable = exists && now < (contract?.expiresAt ?? now)
			print("[GeneratedProposalValidity] id=\(candidateId) contract=\(contract?.id ?? "nil") exists=\(exists ? "true" : "false") executable=\(executable ? "true" : "false")")
		}
		return contract
	}

	/// T18.6 — Update proposal visibility state after a publication cycle.
	func applyProposalVisibilityState(_ state: ProposalVisibilityState) {
		proposalVisibilityState = state
		if state.visibleCount > 0 {
			lastVisibleProposalAt = state.updatedAt
		}
	}

	/// User-invoked generated proposal execution (T18.4+) — no automatic execution on proposal generation.
	func invokeGeneratedExecutionProposal(id: String) {
		guard let item = activatedGeneratedProposals.first(where: { $0.id == id }) else { return }
		print("[GeneratedExecutionUI] run_requested id=\(id.prefix(12)) source=\(item.source.rawValue)")
		latestActionId = GeneratedExecutionProposalActivator.generatedProposalActionId(for: id)
		latestActionTimestamp = Date()
		latestActionResult = nil
		latestGeneratedExecutionPresentation = nil
		generatedExecutionPhaseLabel = "Preparing context…"
		onInvokeGeneratedExecutionProposalById?(id)
	}

	/// User-initiated cancel of in-flight generated execution (T18.4).
	func cancelGeneratedExecution() {
		print("[GeneratedExecutionUI] cancel_requested")
		onCancelGeneratedExecution?()
	}

	/// Clears the structured generated result card (user taps Clear).
	func clearGeneratedResult() {
		latestGeneratedExecutionPresentation = nil
		latestActionResult = nil
		latestActionTimestamp = nil
		latestActionId = nil
	}

	func dismissCurrentProposal() {
		guard let proposal = currentProposal else { return }
		if let suggestion = activeAmbientJarvisSuggestion,
		   let context = durableContext(for: suggestion) {
			let capabilityId = ambientCapabilityId(for: suggestion)
			DurableMemory.shared.recordActionFeedback(capabilityId: capabilityId, event: .dismissed, context: context)
			if let restoreKey = restoreCooldownKey(for: suggestion) {
				DurableMemory.shared.recordRestoreFeedback(restoreKey: restoreKey, event: .dismissed)
			}
			DurableMemory.shared.recordScheduleObservation(context: context, accepted: false, activityState: "active")
		}
		let suggestionKey = suggestionKey(for: proposal, context: debugContext)
		let redundancyKey = String(fnv1a64(text: suggestionKey), radix: 16)
		let id = proposal.primaryActionId
		print("[SuggestionCard] dismissed proposal primary=\(id)")
		lastDismissedProposalActionId = id

		redundancyMemory.record(event: .manuallyDismissed, key: redundancyKey, actionId: id)

		dismissedSuggestionCooldown.markFired(key: suggestionKey)

		if let key = currentProposalKey {
			lastDismissedProposalKey = key
			lastDismissedProposalAt = Date()
			if LogControl.shared.shouldLog(category: .selection_reasoning, level: .trace) {
				print("[ProposalCooldown] recorded dismiss key=\(key)")
			}
		}

		if LogControl.shared.shouldLog(category: .selection_reasoning, level: .debug) {
			print("[GeneratedProposalState] clearing reason=user_dismissed")
		}
		currentProposal = nil
		currentProposalKey = nil
		refreshProposalContext(for: nil)
	}

	private func selectionFingerprint(context: ContextModel) -> String? {
		guard context.selectedTextAvailable else { return nil }
		guard let text = ActionInputCapture.primaryText(for: context, minimumLength: 0, preference: selectedInputSourceChoice), !text.isEmpty else { return nil }
		return String(fnv1a64(text: String(text.prefix(2000))), radix: 16)
	}

	private func clipboardFingerprint() -> String? {
		guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return nil }
		return String(fnv1a64(text: String(text.prefix(2000))), radix: 16)
	}

	private func fnv1a64(text: String) -> UInt64 {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for b in text.utf8 {
			hash ^= UInt64(b)
			hash &*= 1_099_511_628_211
		}
		return hash
	}

	func enableLocalAI() {
		onEnableLocalAI?()
	}

	func disableLocalAI() {
		onDisableLocalAI?()
	}

	func enableAutoStartOllama() {
		onEnableAutoStartOllama?()
	}

	func disableAutoStartOllama() {
		onDisableAutoStartOllama?()
	}

	func startOllamaNow() {
		onStartOllamaNow?()
	}

	func openOllamaDownloadPage() {
		onOpenOllamaDownload?()
	}

	func pullLocalAIModel() {
		onPullLocalAIModel?()
	}

	func clearResult() {
		latestActionResult = nil
		latestActionId = nil
		latestActionTimestamp = nil
	}

	// MARK: - Floating suggestion controls

	private func floatingCapabilityID(for proposal: SuggestionViewModel) -> String {
		if proposal.primaryActionId.hasPrefix("ambient_jarvis:"),
		   let suggestion = activeAmbientJarvisSuggestion {
			return ambientCapabilityId(for: suggestion, actionId: proposal.primaryActionId)
		}
		return proposal.primaryActionId.replacingOccurrences(of: "ambient_jarvis:", with: "")
	}

	private func markFloatingSuggestionShownIfNeeded() {
		guard let state = floatingVisibilityState,
		      let bind = activeFloatingLifecycleBinding,
		      !state.proofVisible else { return }
		floatingSuggestionLifecycle.record(
			.shown,
			exactKey: bind.exactKey,
			primaryActionId: bind.primaryActionId,
			profile: bind.profile
		)
		floatingSuggestionLifecycle.logRecorded(state: .shown, safeKey: bind.safeKey)
		redundancyMemory.record(event: .shown, key: bind.exactKey, actionId: bind.primaryActionId)
		floatingVisibilityState?.proofVisible = true
		if let workflow = AmbientWorkflowType(rawValue: activeAmbientJarvisSuggestion?.workflow ?? "") {
			let actionable = workflow != .unknown && workflow != .idle
			SuggestionTickSummaryLog.log(
				modelReady: true,
				startupQuiet: true,
				workflow: workflow,
				workflowActionable: actionable,
				determinerActionable: actionable,
				cheapPortfolioRan: true,
				heavyPlannerRan: false,
				candidatesCount: max(1, availableActions.count),
				selected: state.capabilityID,
				surfaceResult: "shown",
				suppressionReason: "none",
				panelCount: availableActions.count
			)
		}
	}

	func reportFloatingVisibilityProof(
		attached: Bool,
		onScreen: Bool,
		alpha: Double,
		frame: CGRect,
		hiddenByPanel: Bool,
		dwellMs: Int,
		stillPresented: Bool
	) {
		guard var state = floatingVisibilityState else { return }
		state.proofAttempted = true
		let frameValid = frame.width > 0 && frame.height > 0
		let visible = attached && onScreen && alpha > 0.05 && frameValid && !hiddenByPanel && stillPresented && dwellMs >= state.dwellRequiredMs
		let frameText = "(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width)),\(Int(frame.size.height)))"
		print("[FloatingVisibilityProof] id=\(state.proposalID) capability=\(state.capabilityID) attached=\(attached ? "yes" : "no") on_screen=\(onScreen ? "yes" : "no") alpha=\(String(format: "%.2f", alpha)) frame=\(frameText) dwell_ms=\(dwellMs) visible=\(visible ? "yes" : "no")")
		if visible {
			floatingVisibilityState = state
			markFloatingSuggestionShownIfNeeded()
			return
		}
		let reason: String = {
			if !attached { return "not_attached" }
			if !stillPresented { return "replaced_or_detached_before_dwell" }
			if !onScreen { return "off_screen" }
			if alpha <= 0.05 { return "alpha_hidden" }
			if !frameValid { return "invalid_frame" }
			if hiddenByPanel { return "hidden_behind_panel" }
			return "dwell_threshold_not_met"
		}()
		print("[FloatingVisibilityProof] failed id=\(state.proposalID) reason=\(reason)")
		floatingVisibilityState = state
		recordNotVisibleFeedbackIfNeeded(for: state.proposalID, capabilityID: state.capabilityID, ambientSuggestion: activeAmbientJarvisSuggestion)
		floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil
		floatingSuggestion = nil
		isFloatingSuggestionVisible = false
		refreshFloatingProposalContext(for: nil)
		updateHighUsefulnessPanelVisibility()
		activeFloatingLifecycleBinding = nil
		floatingVisibilityState = nil
	}

	func showFloatingSuggestion(_ suggestion: SuggestionViewModel, lifecycle: ActiveFloatingLifecycleBinding) {
		if let old = floatingSuggestion, isFloatingSuggestionVisible, old.primaryActionId != suggestion.primaryActionId {
			print("[AmbientSuggestionReplacement] old=\(old.primaryActionId) new=\(suggestion.primaryActionId) reason=better_candidate")
		}
		floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil
		lastAmbientJarvisShownAt = Date()

		let logKey = floatingSuggestionLogKey(for: suggestion, context: debugContext)
		print("[FloatingSuggestion] show key=\(logKey)")
		activeFloatingLifecycleBinding = lifecycle
		
		let capId = floatingCapabilityID(for: suggestion)
		let acceptBehavior: String = {
			let researchActions: Set<String> = [
				"explicit_visible_capture_summary", "summarize_visible_content", "extract_action_items", "create_checklist",
				"rewrite_text", "explain_context", "draft_reply", "diagnose_error"
			]
			if researchActions.contains(capId) {
				return "run_and_show_floating_result"
			} else {
				return "execute_direct"
			}
		}()
		print("[SuggestionSurfaceContract] capability=\(capId) suggestion_surface=floating_card accept_behavior=\(acceptBehavior)")

		floatingVisibilityState = FloatingVisibilityState(
			proposalID: suggestion.primaryActionId,
			capabilityID: floatingCapabilityID(for: suggestion),
			shownAt: Date(),
			dwellRequiredMs: floatingVisibilityDwellMilliseconds
		)

		floatingSuggestion = suggestion
		isFloatingSuggestionVisible = true
		refreshFloatingProposalContext(for: suggestion)
		updateHighUsefulnessPanelVisibility()

		let work = DispatchWorkItem { [weak self] in
			Task { @MainActor in
				self?.dismissFloatingSuggestion(reason: .auto)
			}
		}
		floatingAutoDismissWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + floatingAutoDismissSeconds, execute: work)
	}

	enum FloatingSuggestionDismissReason: String {
		case manual
		case auto
		case panelOpen = "panel_open"
		case accepted
	}

	func dismissFloatingSuggestion(reason: FloatingSuggestionDismissReason = .manual) {
		let proposalSnapshot = floatingSuggestion
		let ctx = debugContext
		let hadFairVisibleChance = floatingVisibilityState?.proofVisible == true

		if reason != .accepted, let p = proposalSnapshot {
			if reason == .manual {
				recordSuggestionFeedback(id: p.primaryActionId, event: "dismissed")
			} else if hadFairVisibleChance {
				recordSuggestionFeedback(id: p.primaryActionId, event: "auto_dismissed")
			} else {
				recordNotVisibleFeedbackIfNeeded(
					for: p.primaryActionId,
					capabilityID: floatingCapabilityID(for: p),
					ambientSuggestion: activeAmbientJarvisSuggestion
				)
			}
		}

		if let ambient = activeAmbientJarvisSuggestion,
		   let context = durableContext(for: ambient),
		   reason != .accepted {
			let capabilityId = ambientCapabilityId(for: ambient)
			let normalizedId = proposalSnapshot?.primaryActionId.replacingOccurrences(of: "ambient_jarvis:", with: "") ?? capabilityId
			if !hadFairVisibleChance, reason != .manual {
				print("[DurableMemory] action_feedback skipped capability=\(capabilityId) reason=not_visible_not_user_feedback")
			} else if reason == .auto || reason == .panelOpen {
				scheduleAutoDismissDurableFeedback(
					id: normalizedId,
					capabilityId: capabilityId,
					context: context,
					restoreKey: restoreCooldownKey(for: ambient)
				)
			} else {
				commitDurableFeedback(
					id: normalizedId,
					capabilityId: capabilityId,
					event: .dismissed,
					context: context,
					restoreKey: restoreCooldownKey(for: ambient)
				)
			}
		}

		if let bind = activeFloatingLifecycleBinding, reason != .accepted {
			switch reason {
			case .auto, .panelOpen:
				if hadFairVisibleChance {
					floatingSuggestionLifecycle.record(
						.autoDismissed,
						exactKey: bind.exactKey,
						primaryActionId: bind.primaryActionId,
						profile: bind.profile
					)
					floatingSuggestionLifecycle.logRecorded(state: .autoDismissed, safeKey: bind.safeKey)
					redundancyMemory.record(event: .autoDismissed, key: bind.exactKey, actionId: bind.primaryActionId)
				}
			case .manual:
				floatingSuggestionLifecycle.record(
					.manuallyDismissed,
					exactKey: bind.exactKey,
					primaryActionId: bind.primaryActionId,
					profile: bind.profile
				)
				floatingSuggestionLifecycle.logRecorded(state: .manuallyDismissed, safeKey: bind.safeKey)
				redundancyMemory.record(event: .manuallyDismissed, key: bind.exactKey, actionId: bind.primaryActionId)
			case .accepted:
				break
			}
		}

		activeFloatingLifecycleBinding = nil
		floatingVisibilityState = nil

		floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil
		floatingSuggestion = nil
		isFloatingSuggestionVisible = false
		refreshFloatingProposalContext(for: nil)
		updateHighUsefulnessPanelVisibility()

		if reason != .accepted, let p = proposalSnapshot {
			let logKey = floatingSuggestionLogKey(for: p, context: ctx)
			print("[FloatingSuggestion] dismissed key=\(logKey) reason=\(reason.rawValue)")
		}
	}

	func dismissResearchResultCard(reason: String) {
		guard let card = activeResearchResultCard else { return }
		print("[ResearchResultCard] dismissed reason=\(reason)")
		activeResearchResultCard = nil
	}

	func acceptFloatingProposal() {
		guard let proposal = floatingSuggestion else { return }
		let id = proposal.primaryActionId
		let capId = floatingCapabilityID(for: proposal)
		
		let behavior: String = {
			let researchActions: Set<String> = [
				"explicit_visible_capture_summary", "summarize_visible_content", "extract_action_items", "create_checklist",
				"rewrite_text", "explain_context", "draft_reply", "diagnose_error"
			]
			if researchActions.contains(capId) {
				return "run_and_show_floating_result"
			} else {
				return "execute_direct"
			}
		}()
		print("[SuggestionAccepted] capability=\(capId) behavior=\(behavior)")
		
		if floatingVisibilityState != nil {
			markFloatingSuggestionShownIfNeeded()
		}
		let suggestionKey = suggestionKey(for: proposal, context: debugContext)
		print("[FloatingSuggestion] accepted primary=\(id)")

		if let bind = activeFloatingLifecycleBinding {
			floatingSuggestionLifecycle.record(
				.accepted,
				exactKey: bind.exactKey,
				primaryActionId: bind.primaryActionId,
				profile: bind.profile
			)
			floatingSuggestionLifecycle.logRecorded(state: .accepted, safeKey: bind.safeKey)
			redundancyMemory.record(event: .accepted, key: bind.exactKey, actionId: bind.primaryActionId)
		}

		acceptedSuggestionCooldown.markFired(key: suggestionKey)
		if let key = currentProposalKey {
			lastAcceptedProposalKey = key
			lastAcceptedProposalAt = Date()
		}

		dismissFloatingSuggestion(reason: .accepted)

		invokeAction(id: id, sourceSurface: .floating)
	}

	func floatingPrimaryButtonTitle(for proposal: ActionProposal) -> String {
		if let action = availableActions.first(where: { $0.id == proposal.primaryActionId }) {
			return action.name
		}
		if let title = ActionIntentRegistry.title(for: proposal.primaryActionId) {
			return title
		}
		return "Open"
	}

	// MARK: - Context awareness (T14.9)

	/// Recomputes panel chips from canonical fused metadata + safe app hints (no collection).
	func refreshContextAwarenessSummary() {
		let next = ContextAwarenessSummaryBuilder.build(
			canonical: CanonicalContextState.shared.current(),
			contextModel: debugContext
		)
		contextAwarenessSummary = next
		logContextAwarenessIfNeeded(next)
		refreshRichContextDebugSummary()
		refreshWorkflowContinuitySummary()
	}

	// MARK: - Workflow continuity UI (T16.8)

	func refreshWorkflowContinuitySummary() {
		let next = WorkflowContinuityDisplayBuilder.buildFromCurrentState()
		workflowContinuitySummary = next
		logWorkflowContinuityUIIfNeeded(next)
	}

	private func logWorkflowContinuityUIIfNeeded(_ summary: WorkflowContinuityDisplaySummary) {
		let now = Date()
		let sig: String
		if summary.isVisible {
			sig = "show|\(summary.workflow.rawValue)|\(summary.confidenceBucket)|\(summary.continuityBucket)"
		} else {
			sig = "hide|\(summary.reasonCodes.prefix(2).joined(separator: ","))"
		}
		if sig == lastWorkflowContinuityLogSignature, let lastWorkflowContinuityLogAt, now.timeIntervalSince(lastWorkflowContinuityLogAt) < 1.8 {
			return
		}
		lastWorkflowContinuityLogSignature = sig
		lastWorkflowContinuityLogAt = now

		if summary.isVisible {
			print(
				"[WorkflowContinuityUI] shown workflow=\(summary.workflow.rawValue) confidence=\(summary.confidenceBucket) continuity=\(summary.continuityBucket) reason=stable_session"
			)
		} else if let r = summary.reasonCodes.first {
			print("[WorkflowContinuityUI] hidden reason=\(r)")
		} else {
			print("[WorkflowContinuityUI] hidden reason=unspecified")
		}
	}

	private func logContextAwarenessIfNeeded(_ summary: ContextAwarenessSummary) {
		let now = Date()
		if !summary.showsInPanel {
			let sig = "hidden"
			if sig == lastContextAwarenessLogSignature, let lastContextAwarenessLogAt, now.timeIntervalSince(lastContextAwarenessLogAt) < 2.0 {
				return
			}
			lastContextAwarenessLogSignature = sig
			lastContextAwarenessLogAt = now
			print("[ContextAwarenessUI] hidden reason=no_context")
			return
		}

		let sig = summary.chipsJoined
		if sig == lastContextAwarenessLogSignature, let lastContextAwarenessLogAt, now.timeIntervalSince(lastContextAwarenessLogAt) < 1.2 {
			return
		}
		lastContextAwarenessLogSignature = sig
		lastContextAwarenessLogAt = now
		let chipsCsv = summary.chips.joined(separator: ",")
		print("[ContextAwarenessUI] updated chips=\(chipsCsv)")
	}

	// MARK: - Rich context debug (T14.10)

	func refreshRichContextDebugSummary() {
		let next = RichContextDebugSummaryBuilder.build(
			canonical: CanonicalContextState.shared.current(),
			refreshResult: RichContextRefreshPipeline.shared.lastRefreshResultSnapshot(),
			samplingDecision: AdaptiveContextSampler.shared.lastSamplingDecisionSnapshot(),
			lastArbitration: ContextConfidenceArbitrator.shared.lastArbitrationSnapshot()
		)
		richContextDebugSummary = next
		logRichContextDebugUIIfNeeded(next)
		refreshDynamicIntentDebugSummary()
	}

	private func logRichContextDebugUIIfNeeded(_ summary: RichContextDebugSummary) {
		let now = Date()
		if !summary.showsRichDebug {
			let sig = "hidden"
			if sig == lastRichContextDebugLogSignature, let lastRichContextDebugLogAt, now.timeIntervalSince(lastRichContextDebugLogAt) < 2.0 {
				return
			}
			lastRichContextDebugLogSignature = sig
			lastRichContextDebugLogAt = now
			print("[RichContextDebugUI] hidden reason=no_context")
			return
		}

		let sig = [
			summary.primarySource ?? "nil",
			summary.freshnessScoreBucket ?? "nil",
			summary.confidenceBucket ?? "nil",
			summary.lastSamplingDecision ?? ""
		].joined(separator: "|")
		if sig == lastRichContextDebugLogSignature, let lastRichContextDebugLogAt, now.timeIntervalSince(lastRichContextDebugLogAt) < 1.2 {
			return
		}
		lastRichContextDebugLogSignature = sig
		lastRichContextDebugLogAt = now
		print(
			"[RichContextDebugUI] updated primary=\(summary.primarySource ?? "nil") freshness=\(summary.freshnessScoreBucket ?? "nil") confidence=\(summary.confidenceBucket ?? "nil")"
		)
	}

	// MARK: - Dynamic intent debug (T15.10)

	func refreshDynamicIntentDebugSummary() {
		let next = DynamicIntentDebugSummaryBuilder.build()
		dynamicIntentDebugSummary = next
		logDynamicIntentDebugUIIfNeeded(next)
		refreshDynamicActionDisplaySummary()
	}

	func refreshDynamicActionDisplaySummary() {
		// Prune evicted hook proposals before building summary so they are auto-removed immediately
		let now = Date()
		var updatedList = [GeneratedExecutionProposalPanelItem]()
		var changed = false
		for item in activatedGeneratedProposals {
			if item.id.hasPrefix("hook:") {
				if let contract = hookContractByCandidateId[item.id], now < contract.expiresAt {
					updatedList.append(item)
					print("[GeneratedProposalValidity] id=\(item.id) contract=\(contract.id) exists=true executable=true")
				} else {
					changed = true
					let contractId = hookContractByCandidateId[item.id]?.id ?? "nil"
					print("[GeneratedProposalValidity] id=\(item.id) contract=\(contractId) exists=\(contractId != "nil" ? "true" : "false") executable=false")
					print("[GeneratedProposalEviction] id=\(item.id) contract=\(contractId)")
				}
			} else {
				updatedList.append(item)
			}
		}
		if changed {
			activatedGeneratedProposals = updatedList
		}

		let next = DynamicActionDisplayBuilder.build(
			activeProposals: activatedGeneratedProposals,
			isActionExecutingForPreviewRanking: isActionExecuting
		)
		dynamicActionDisplaySummary = next
		logDynamicActionUXIfNeeded(next)
		if next.previewItems.isEmpty {
			VisibleGeneratedActionPanelAdapter.logPanelHiddenIfNeeded()
		} else {
			let capped = Array(next.previewItems.prefix(VisibleGeneratedActionPanelAdapter.maxVisiblePreviews))
			VisibleGeneratedActionPanelAdapter.logPanelShownIfNeeded(rows: capped, groupLabel: next.previewGroupLabel)
		}
		refreshInlineAssistanceCandidates()

		let fused = CanonicalContextState.shared.current()
		let timing = RichAssistancePreviewContext.live(isActionExecuting: isActionExecuting).timing
		let rankInput = RichAssistanceRankingInput(
			referenceTime: Date(),
			staticActionIds: availableActions.map(\.id),
			staticBaseScores: [:],
			workflowProposalRanking: WorkflowAwareProposalRanker.latestRankingSnapshot(),
			generatedActions: GeneratedActionEngine.shared.latestActions(),
			generatedPlans: GeneratedActionEngine.shared.currentPlans(),
			workflowInference: WorkflowInferenceEngine.shared.latestResult(),
			session: ContextualSessionTracker.shared.currentState(),
			fused: fused,
			timing: timing,
			proposalPrimaryActionId: currentProposal?.primaryActionId,
			inlineDismissalKeys: inlineAssistanceSnapshot.rows.map(\.dismissalKey),
			interactionSnapshot: nil
		)
		richAssistanceRankingResult = RichAssistanceRanker.rankUnified(input: rankInput)
		if !richAssistanceRankingResult.debugLine.isEmpty {
			dynamicIntentDebugSummary = dynamicIntentDebugSummary.withRichAssistanceRankLine(richAssistanceRankingResult.debugLine)
		}
		refreshVisibleIntelligenceDebugSummary()
	}

	// MARK: - Visible intelligence debug (T16.11)

	func refreshVisibleIntelligenceDebugSummary() {
		let capture = VisibleIntelligenceDebugCapture.fromSharedAppState(
			proposalContext: proposalContextSummary,
			inline: inlineAssistanceSnapshot,
			dynamicDisplay: dynamicActionDisplaySummary,
			richRanking: richAssistanceRankingResult
		)
		let next = VisibleIntelligenceDebugSummaryBuilder.build(capture)
		visibleIntelligenceDebugSummary = next
		VisibleIntelligenceDebugLogger.logIfNeeded(next)
	}

	// MARK: - Inline assistance foundations (T16.6)

	func refreshInlineAssistanceCandidates() {
		let typing = TypingActivitySource.shared.currentContext()
		let pointer = PointerActivitySource.shared.currentContext()
		let fused = CanonicalContextState.shared.current()
		let staticSummaries = availableActions.map { ($0.id, $0.name) }
		let input = InlineAssistanceBuildInput(
			context: debugContext,
			staticActions: staticSummaries,
			currentProposal: currentProposal,
			currentProposalKey: currentProposalKey,
			generatedPreviewItems: dynamicActionDisplaySummary.previewItems,
			isManualInvocation: false,
			isActionExecuting: isActionExecuting,
			lastDismissedProposalActionId: lastDismissedProposalActionId,
			typing: typing,
			pointer: pointer,
			fused: fused
		)
		inlineAssistanceSnapshot = InlineAssistanceCandidateBuilder.build(input: input)
	}

	// MARK: - Proposal context (T16.2)

	func refreshProposalContext(for proposal: ActionProposal?) {
		if let p = proposal {
			let s = ProposalContextSummaryBuilder.build(for: p)
			proposalContextSummary = s
			logProposalContextIfNeeded(s, primary: p.primaryActionId)
		} else {
			proposalContextSummary = .unavailable
			logProposalContextHiddenIfNeeded()
		}
		refreshInlineAssistanceCandidates()
		refreshVisibleIntelligenceDebugSummary()
	}

	func refreshFloatingProposalContext(for proposal: ActionProposal?) {
		if let p = proposal {
			floatingProposalContextSummary = ProposalContextSummaryBuilder.build(for: p)
		} else {
			floatingProposalContextSummary = .unavailable
		}
		refreshVisibleIntelligenceDebugSummary()
	}

	private func logProposalContextIfNeeded(_ summary: ProposalContextSummary, primary: String) {
		guard summary.isAvailable else {
			logProposalContextHiddenIfNeeded()
			return
		}
		let now = Date()
		let wfChip = summary.chips.first { !$0.hasPrefix("confidence_") } ?? "none"
		let gen = summary.hasGeneratedInfluence ? "yes" : "no"
		let sig = "\(primary)|\(wfChip)|\(gen)|\(summary.chips.count)"
		if sig == lastProposalContextLogSignature, let lastProposalContextLogAt, now.timeIntervalSince(lastProposalContextLogAt) < 1.4 {
			return
		}
		lastProposalContextLogSignature = sig
		lastProposalContextLogAt = now
		let intentYN = summary.hasIntentAlignment ? "yes" : "no"
		print("[ProposalContext] built workflow=\(wfChip) generated=\(gen) intent=\(intentYN)")
		let chipsJoined = summary.chips.joined(separator: ",")
		print("[ProposalContext] attached proposal=\(primary) chips=\(chipsJoined)")
	}

	private func logProposalContextHiddenIfNeeded() {
		let now = Date()
		let sig = "hidden"
		if sig == lastProposalContextHiddenSignature, let lastProposalContextHiddenAt, now.timeIntervalSince(lastProposalContextHiddenAt) < 2.0 {
			return
		}
		lastProposalContextHiddenSignature = sig
		lastProposalContextHiddenAt = now
		print("[ProposalContext] hidden reason=no_context")
	}

	private func logDynamicIntentDebugUIIfNeeded(_ summary: DynamicIntentDebugSummary) {
		let now = Date()
		if !summary.showsDynamicDebug {
			let sig = "hidden"
			if sig == lastDynamicIntentDebugLogSignature, let lastDynamicIntentDebugLogAt, now.timeIntervalSince(lastDynamicIntentDebugLogAt) < 2.0 {
				return
			}
			lastDynamicIntentDebugLogSignature = sig
			lastDynamicIntentDebugLogAt = now
			print("[DynamicIntentDebugUI] hidden reason=no_dynamic_state")
			return
		}

		let wfKey = summary.workflowLine.isEmpty ? "nil" : String(summary.workflowLine.prefix(48))
		let sig = "\(wfKey)|i=\(summary.intentLines.count)|a=\(summary.actionLines.count)|p=\(summary.planLines.count)|r=\(summary.rankingLine.isEmpty ? 0 : 1)"
		if sig == lastDynamicIntentDebugLogSignature, let lastDynamicIntentDebugLogAt, now.timeIntervalSince(lastDynamicIntentDebugLogAt) < 1.2 {
			return
		}
		lastDynamicIntentDebugLogSignature = sig
		lastDynamicIntentDebugLogAt = now
		print(
			"[DynamicIntentDebugUI] updated workflow=\(wfKey) intents=\(summary.intentLines.count) actions=\(summary.actionLines.count) plans=\(summary.planLines.count)"
		)
	}

	// MARK: - Dynamic action UX preview (T15.11)

	private func logDynamicActionUXIfNeeded(_ summary: DynamicActionDisplaySummary) {
		let now = Date()
		if !summary.showsGeneratedPreview {
			let sig = "hidden"
			if sig == lastDynamicActionUXLogSignature, let lastDynamicActionUXLogAt, now.timeIntervalSince(lastDynamicActionUXLogAt) < 2.0 {
				return
			}
			lastDynamicActionUXLogSignature = sig
			lastDynamicActionUXLogAt = now
			print("[DynamicActionUX] hidden reason=no_generated_actions")
			return
		}

		let top = summary.previewItems.first?.category.rawValue ?? "nil"
		let sig = "\(summary.previewItems.count)|\(top)|b=\(summary.blockedSkippedTotal)"
		if sig == lastDynamicActionUXLogSignature, let lastDynamicActionUXLogAt, now.timeIntervalSince(lastDynamicActionUXLogAt) < 1.2 {
			return
		}
		lastDynamicActionUXLogSignature = sig
		lastDynamicActionUXLogAt = now
		print(
			"[DynamicActionUX] shown count=\(summary.previewItems.count) top=\(top) category=\(summary.previewItems.first?.category.rawValue ?? "nil")"
		)
	}
}

// MARK: - Research Result Card State

struct ResearchResultCardState: Equatable, Sendable {
	let capabilityID: String
	let title: String
	let text: String
	let outputChars: Int
}
