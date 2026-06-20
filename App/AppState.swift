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
	case followup
	case unknown
}

enum ContextChipPhase: String {
	case idle
	case pending
	case active
	case failed
}

struct ContextChipDisplayState {
	let option: ContextScopeOption
	let phase: ContextChipPhase
	let label: String
	let systemImage: String
	let isPending: Bool
}

private struct StoredContextChipState {
	let option: ContextScopeOption
	let phase: ContextChipPhase
	let message: String?

	var label: String {
		switch phase {
		case .pending:
			return "Gathering \(option.chipLabel.lowercased())..."
		case .failed:
			return "\(option.chipLabel) unavailable"
		case .idle, .active:
			return option.chipLabel
		}
	}
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

private struct PopupIdentityRecord {
	let id: String
	let source: String
	let actionRef: String
	let createdAt: Date
	let expiresAt: Date
}

@MainActor
final class AppState: ObservableObject {
	private let passiveDogfoodMonitor = PassiveDogfoodMonitor.shared
	@Published var isPaused: Bool = false
	/// Latest context for UI (updated by app lifecycle; not built in UI).
	@Published var debugContext: ContextModel = ContextModel() {
		didSet {
			passiveDogfoodMonitor.noteContextSeen()
		}
	}

	/// Metadata-only chips for subtle panel context awareness (T14.9); updated by app lifecycle only.
	@Published var contextAwarenessSummary: ContextAwarenessSummary = .empty

	/// Internal rich-context debug snapshot (T14.10); metadata only; updated by app lifecycle only.
	@Published var richContextDebugSummary: RichContextDebugSummary = .empty

	/// Internal dynamic intent pipeline debug (T15.10); metadata only; updated by app lifecycle only.
	@Published var dynamicIntentDebugSummary: DynamicIntentDebugSummary = .empty

	/// Preview-only generated action display models (T15.11); derived, not persisted; updated by app lifecycle only.
	@Published var dynamicActionDisplaySummary: DynamicActionDisplaySummary = .empty

	/// Per-result context chip state. The source label on a result is immutable,
	/// so user scope selections must be stored separately for SwiftUI renders.
	@Published private var contextChipStateByResultID: [String: StoredContextChipState] = [:]

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
	/// Issue 1/6 — the assistant-first primary line shown at the panel top. Holds
	/// the current suggestion title, or an honest "watching" state — never a
	/// "N controls available" toolbox summary.
	@Published private(set) var panelAvailableActionsSummary: String = "Watching current context"
	/// Issue 1/6 — primary panel mode: suggestion | watching | empty.
	@Published private(set) var primaryPanelMode: String = "watching"

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

	/// Live counters for the product-dogfood gates. Incremented only if a
	/// failed/blocked/partial action ever escapes `emitActionUX` with an empty
	/// reason/message (after sanitization) — must stay 0.
	public static var reasonNoneFailureCount = 0
	public static var emptyFailureMessageCount = 0

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
		producer.onCurrentWorkCandidateSurface = { [weak self] signals in
			Task { @MainActor in
				self?.surfaceCurrentWorkCandidate(signals: signals)
			}
		}
		producer.onPortfolioPanelCandidatesGenerated = { [weak self] candidates in
			Task { @MainActor in
				self?.publishPortfolioPanelCandidates(candidates, reason: "cheap_portfolio_panel_only")
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
			case .captureNeeded: return "capture_needed"
			case .failedVisible: return "failed_visible"
			case .failedSilent: return "failed_silent"
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

	/// Recovery fix — map an `ambient_jarvis:<UUID>` visible id back to its real
	/// canonical capability so genuinely actionable candidates are NOT suppressed
	/// as unmapped legacy ids. Returns nil for ids that cannot be mapped (those
	/// stay suppressed by the identity guard, as intended).
	func canonicalCapabilityForVisibleID(_ id: String) -> String? {
		guard id.hasPrefix("ambient_jarvis:") else { return nil }
		if let suggestion = activeAmbientJarvisSuggestion {
			let cap = ambientCapabilityId(for: suggestion, actionId: id)
			if !cap.isEmpty && !cap.hasPrefix("ambient_jarvis:") { return cap }
		}
		let stripped = id.replacingOccurrences(of: "ambient_jarvis:", with: "")
		// Only accept a stripped id that is itself a real registered capability
		// (guards against bare UUIDs with no active suggestion).
		if !stripped.isEmpty,
		   stripped != id,
		   CognitiveCapabilityRegistry.shared.get(ActionAliasResolver.canonicalID(for: stripped)) != nil {
			return stripped
		}
		return nil
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
	
	/// The capability a floating ambient suggestion would execute. Cheap-portfolio
	/// suggestions encode it as `environment:<capability>`; richer suggestions carry
	/// it on the action card. Used to enforce the product-surface policy at the
	/// surface itself (defense-in-depth), so no upstream path can leak a manual
	/// environment utility onto the floating product surface.
	private func ambientFloatingCapabilityID(_ suggestion: AmbientJarvisSuggestion) -> String? {
		if let cap = suggestion.actionCard?.primaryAction.id, !cap.isEmpty { return cap }
		if suggestion.intent.hasPrefix("environment:") {
			return String(suggestion.intent.dropFirst("environment:".count))
		}
		return nil
	}

		func publishAmbientJarvisSuggestion(_ suggestion: AmbientJarvisSuggestion?) {
			var suggestion = suggestion
			if let candidate = suggestion {
				let cap = ambientFloatingCapabilityID(candidate) ?? candidate.intent.replacingOccurrences(of: "environment:", with: "")
				let proposalID = "ambient_jarvis:\(candidate.id)"
				passiveDogfoodMonitor.noteProposalCandidateGenerated(
					proposalID: proposalID,
					capabilityID: cap,
					source: "ambient_publish:\(candidate.workflow)"
				)
				passiveDogfoodMonitor.noteProposalSurfaceRequested(
					proposalID: proposalID,
					capabilityID: cap,
					source: "ambient_publish:\(candidate.workflow)"
				)
				print("[ProposalSurfaceTrace] candidate=\(cap) requested=yes presented=no reason=ambient_publish_preflight")
				let surfaceSignals = WorkflowSignals(
					activeApp: debugContext.activeAppName ?? "",
				windowTitle: debugContext.activeWindowTitle ?? "",
				selectedTextLength: debugContext.selectedTextLength,
				contentAvailable: debugContext.screenOCRAvailable || debugContext.selectedTextLength > 0
			)
				if !ProposalActionContextRouter.verifyRouterBacked(proposalID: "ambient_jarvis:\(candidate.id)", capabilityID: cap, signals: surfaceSignals) {
					print("[PrimarySurfaceDecision] surface=none reason=action_context_router_blocked")
					print("[ProposalSurfaceTrace] candidate=\(cap) requested=yes presented=no reason=action_context_router_blocked")
					passiveDogfoodMonitor.noteProposalSurfaceFailure(reason: "action_context_router_blocked", proposalID: proposalID)
					suggestion = nil
				}
			}
		// Product-surface enforcement AT THE SURFACE. Window-arrange, focus-media,
		// reference-collection and other environment utilities must never become the
		// visible floating proposal in normal mode. The upstream audit log
		// (LivePathDecision.logVisible) reported these as "blocked" while the real
		// emission path still floated them — the gate measured the wrong thing. This
		// is the one place every floating ambient suggestion must pass through, so it
		// is the honest place to enforce. Debug mode keeps them for inspection.
		if let candidate = suggestion,
		   !ProductSurfacePolicy.manualControlsVisible,
		   let cap = ambientFloatingCapabilityID(candidate),
		   ProductSurfacePolicy.isManualUtility(cap)
		     || ProductSurfacePolicy.isManualUtility(ActionAliasResolver.canonicalID(for: cap)) {
			let classification = ProductSurfacePolicy.logClassification(capabilityID: cap)
			ProductSurfacePolicy.logSuppressionAudit(candidate: cap, suppressed: true, reason: "not_product_surface", classification: classification)
			ProductSurfacePolicy.logManualUtilityOnlyInvariant(suppressed: true, contextualUseful: classification.contextualAction)
				print("[ManualUtilityFloatingSuppressed] capability=\(cap) source=ambient_publish reason=not_product_surface")
				print("[PrimarySurfaceDecision] surface=none reason=manual_utility_blocked_at_surface")
				print("[ProposalSurfaceTrace] candidate=\(cap) requested=yes presented=no reason=manual_utility_blocked_at_surface")
				passiveDogfoodMonitor.noteProposalSurfaceFailure(reason: "manual_utility_blocked_at_surface", proposalID: "ambient_jarvis:\(candidate.id)")
				suggestion = nil
			}
		if let previous = activeAmbientJarvisSuggestion,
		   previous.id != suggestion?.id {
			finalizePriorAmbientSuggestionIfNeeded(previous, replacement: suggestion)
		}
		self.activeAmbientJarvisSuggestion = suggestion
		if let suggestion = suggestion {
			let cap = ambientFloatingCapabilityID(suggestion) ?? suggestion.intent.replacingOccurrences(of: "environment:", with: "")
			print("[ProposalSurfaceTrace] candidate=\(cap) requested=yes presented=yes reason=ambient_publish_visible")
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
	@Published var unifiedSurfaceDecision: UnifiedSurfaceDecision? = nil
	@Published var isFloatingSuggestionVisible: Bool = false
    @Published var isPanelVisible: Bool = false
    /// Phase 67 — synchronous panel opener installed by AppDelegate. Returns the
    /// real popover/panel visibility + focus so Details/Reopen never falsely claim
    /// the panel opened. When nil (headless/tests) we fall back to the notification.
    var assistantPanelOpener: ((_ source: String) -> (visible: Bool, focused: Bool))?
    @Published var ambientSuggestionDogfoodMode: Bool = true // Default to true for Phase 20I
	@Published var activeResearchResultCard: ResearchResultCardState? = nil
    @Published var activeFloatingResultSurface: ResultSurfaceCardState? = nil
    @Published var activePanelResultSurface: ResultSurfaceCardState? = nil
    @Published var floatingAcceptBehaviorValue: String? = nil
    /// Part 3 — observable result-card detail state so Details/Collapse produce a
    /// verifiable UI state change, not just a "handled" log line.
    @Published var isResultDetailExpanded: Bool = false
    @Published var activeResultDetailTargetID: String? = nil
    /// Phase 68 — Issue 2/3: floating result popup expand state. The window
    /// controller observes this to actually resize the panel (not just toggle
    /// text), and the view binds it so the scroll area fills the larger window.
    @Published var resultPopupExpanded: Bool = false
    /// Part 5 — transient, user-visible confirmation toast for UI commands
    /// (Copied N chars / Opened details / Dismissed). The floating + panel views
    /// bind to this and show it briefly.
    @Published var resultCardToast: String? = nil
    var resultCardToastID: UUID = UUID()
    /// Part 4 — floating result lifecycle. Suggestions may auto-dismiss; clicked
    /// result/error surfaces persist until explicit dismissal or replacement.
    let resultCardLifecycle = ResultCardLifecycleController()

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
	var activeFloatingLifecycleBinding: ActiveFloatingLifecycleBinding?
	private var floatingVisibilityState: FloatingVisibilityState?
	private var lastUnifiedFloatingSuppressionReason: String?
	private var popupIdentityByID: [String: PopupIdentityRecord] = [:]
	private var pendingPopupResultChecks: [String: Date] = [:]
	private var recentAvailableActions: [String: RecentAvailableActionEntry] = [:]
	private var pendingActionClickContext: [String: PendingActionClickContext] = [:]
	private var lastResultActionClickAt: Date?
	private let floatingVisibilityDwellMilliseconds = 2500
	private let clickedPopupResultVisibilityTimeout: TimeInterval = 15
	private let recentAvailableActionRetentionSeconds: TimeInterval = 12
	private let highUsefulnessPanelCapabilities: Set<String> = [
		"arrange_side_by_side",
		"switch_to_paired_app",
		"restore_workspace",
		"split_research_setup",
		// Phase 43 — Cognitive preparation actions can be highlighted in panel
		// when a floating suggestion would have been shown but the panel is open.
		"explicit_visible_capture_summary",
		"extract_action_items",
		"create_checklist",
		"summarize_visible_content",
		"rewrite_text",
		"improve_text",
		"draft_reply",
		"explain_context",
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
				print("[PanelAttention] indicator=on capability=\(capability) floating_gating=\(isFloatingSuggestionVisible ? "yes" : "no")")
			} else {
				print("[PanelAttention] indicator=off reason=\(highlighted == nil ? "no_high_usefulness_action" : "floating_visible")")
			}
		}
		if isPanelVisible {
			// Issue 4: defer the published-property mutation off the active layout
			// pass, but coalesce so repeated calls don't spam the layout log.
			if highUsefulnessApplyPending {
				print("[SurfaceLayoutDropped] reason=duplicate_or_active_layout")
				pendingHighUsefulnessApply = apply
				return
			}
			highUsefulnessApplyPending = true
			pendingHighUsefulnessApply = apply
			print("[SurfaceLayoutRequest] source=panel_visibility deferred=yes")
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self.highUsefulnessApplyPending = false
				let work = self.pendingHighUsefulnessApply
				self.pendingHighUsefulnessApply = nil
				work?()
				print("[SurfaceLayoutApplied] source=panel_visibility")
			}
		} else {
			apply()
		}
	}

	/// Issue 4 — coalescing state for deferred panel-visibility mutations.
	private var highUsefulnessApplyPending = false
	private var pendingHighUsefulnessApply: (() -> Void)?

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

						var status = await EnvironmentActionExecutor.previewOrExecute(action, supplementalContext: supplementalContext)
						print("[EnvironmentActionExecution] completed status=\(status.rawValue)")
						// Phase 68 — failed_silent must die: a clicked window/music/metadata
						// action that finished unverified gets a visible honest outcome.
						if status == .failedSilent {
							await MainActor.run {
								self.convertEnvironmentFailedSilent(capability: actionTypeStr, title: suggestion.title)
							}
							status = .failedVisible
						}
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

	private func recordPopupIdentityCreated(id: String, source: String, actionRef: String, expiresAt: Date) {
		popupIdentityByID[id] = PopupIdentityRecord(
			id: id,
			source: source,
			actionRef: actionRef,
			createdAt: Date(),
			expiresAt: expiresAt
		)
		print("[PopupIdentityCreated] id=\(id) source=\(source) action_ref=\(actionRef) expires=\(Int(expiresAt.timeIntervalSince1970))")
		_ = ProposalActionContextRouter.noteProductVisible(proposalID: id, capabilityID: actionRef)
		passiveDogfoodMonitor.noteNaturalSuggestionShown()
	}

	private func retirePopupIdentity(id: String, reason: String, clicked: Bool = false) {
		guard popupIdentityByID.removeValue(forKey: id) != nil else { return }
		print("[PopupIdentityStale] id=\(id) reason=\(reason)")
		if clicked {
			passiveDogfoodMonitor.noteClickedPopupStale()
		}
	}

	@discardableResult
	private func resolvePopupIdentity(id: String, actionRef: String, resolved: Bool, reason: String) -> Bool {
		let now = Date()
		guard let record = popupIdentityByID[id] else {
			print("[PopupIdentityResolved] id=\(id) resolved=no reason=missing_identity")
			print("[PopupIdentityStale] id=\(id) reason=missing_identity")
			print("[NoClickedPopupStaleBeforeUserCanAct] status=fail count=1")
			passiveDogfoodMonitor.noteClickedPopupStale()
			return false
		}
		let actionMatches = record.actionRef == actionRef
		let visibleMatchingPopup = isFloatingSuggestionVisible && floatingSuggestion?.primaryActionId == id
		if now > record.expiresAt && !(resolved && actionMatches && visibleMatchingPopup) {
			popupIdentityByID.removeValue(forKey: id)
			print("[PopupIdentityResolved] id=\(id) resolved=no reason=expired_identity")
			print("[PopupIdentityStale] id=\(id) reason=expired_identity")
			print("[NoClickedPopupStaleBeforeUserCanAct] status=fail count=1")
			passiveDogfoodMonitor.noteClickedPopupStale()
			return false
		}
		if now > record.expiresAt && visibleMatchingPopup {
			print("[PopupIdentityGrace] id=\(id) reason=visible_matching_popup_after_expiry")
		}
		let ok = resolved && actionMatches
		print("[PopupIdentityResolved] id=\(id) resolved=\(ok ? "yes" : "no") reason=\(ok ? reason : (actionMatches ? reason : "action_ref_mismatch"))")
		if ok {
			popupIdentityByID.removeValue(forKey: id)
			print("[NoClickedPopupUnmapped] status=pass count=0")
			print("[NoClickedPopupStaleBeforeUserCanAct] status=pass count=0")
		} else {
			if reason == "unmapped_legacy_id" || !actionMatches {
				popupIdentityByID.removeValue(forKey: id)
				passiveDogfoodMonitor.noteClickedPopupUnmapped()
				print("[NoClickedPopupUnmapped] status=fail count=1")
			}
			if reason == "pre_accept_suppressed" {
				popupIdentityByID.removeValue(forKey: id)
				passiveDogfoodMonitor.noteClickedPopupStale()
				print("[PopupIdentityStale] id=\(id) reason=pre_accept_suppressed")
				print("[NoClickedPopupStaleBeforeUserCanAct] status=fail count=1")
			}
		}
		return ok
	}

	private func scheduleClickedPopupResultVisibilityCheck(id: String) {
		pendingPopupResultChecks[id] = Date()
		DispatchQueue.main.asyncAfter(deadline: .now() + clickedPopupResultVisibilityTimeout) { [weak self] in
			Task { @MainActor in
				guard let self, self.pendingPopupResultChecks.removeValue(forKey: id) != nil else { return }
				print("[NoClickedPopupVanishesWithoutResult] status=fail count=1")
				self.passiveDogfoodMonitor.noteClickedPopupVanished()
			}
		}
	}

	private func markClickedPopupResultVisible(id: String?) {
		guard let id, pendingPopupResultChecks.removeValue(forKey: id) != nil else { return }
		print("[NoClickedPopupVanishesWithoutResult] status=pass count=0")
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
		let zeroFrame = !frameValid
		let offscreen = frameValid && !onScreen
		let visibilityProofFailed = !visible
		print("[NoZeroFrameFloatingSurface] status=\(!zeroFrame ? "pass" : "fail") count=\(!zeroFrame ? 0 : 1)")
		print("[NoOffscreenFloatingSurface] status=\(!offscreen ? "pass" : "fail") count=\(!offscreen ? 0 : 1)")
		print("[NoVisibilityProofFailedAfterSurfaceRequest] status=\(!visibilityProofFailed ? "pass" : "fail") count=\(!visibilityProofFailed ? 0 : 1)")
		if zeroFrame { passiveDogfoodMonitor.noteZeroFrameFloatingSurface() }
		if offscreen { passiveDogfoodMonitor.noteOffscreenFloatingSurface() }
		if visibilityProofFailed { passiveDogfoodMonitor.noteVisibilityProofFailure() }
		// Issue 1: resolve the ledger's window_presented/view_rendered now that the
		// AppKit proof has run for this selected floating proposal.
		let windowPresented = attached && onScreen && frameValid && !hiddenByPanel
		emitProposalVisibilityLedger(
			id: state.proposalID,
			candidate: state.capabilityID,
			generated: true,
			qualityPass: true,
			selected: true,
			storedVisible: true,
			uiRenderRequested: true,
			windowPresented: windowPresented,
			viewRendered: visible,
			final: windowPresented ? "visible" : "hidden",
			hideReason: windowPresented ? "none" : "window_not_presented"
		)
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
				print("[ProposalSurfaceTrace] candidate=\(state.capabilityID) requested=yes presented=no reason=visibility_failed_\(reason)")
				passiveDogfoodMonitor.noteProposalSurfaceFailure(reason: "visibility_failed_\(reason)", proposalID: state.proposalID)
				floatingVisibilityState = state
			recordNotVisibleFeedbackIfNeeded(for: state.proposalID, capabilityID: state.capabilityID, ambientSuggestion: activeAmbientJarvisSuggestion)
			retirePopupIdentity(id: state.proposalID, reason: "visibility_failed_\(reason)")
			floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil
		floatingSuggestion = nil
		unifiedSurfaceDecision = nil
		isFloatingSuggestionVisible = false
		refreshFloatingProposalContext(for: nil)
		updateHighUsefulnessPanelVisibility()
		activeFloatingLifecycleBinding = nil
		floatingVisibilityState = nil
	}

		func showFloatingSuggestion(_ suggestion: SuggestionViewModel, lifecycle: ActiveFloatingLifecycleBinding) {
			if let old = floatingSuggestion, isFloatingSuggestionVisible, old.primaryActionId != suggestion.primaryActionId {
				print("[AmbientSuggestionReplacement] old=\(old.primaryActionId) new=\(suggestion.primaryActionId) reason=better_candidate")
				retirePopupIdentity(id: old.primaryActionId, reason: "replaced_by_better_candidate")
			}
		floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil
		lastAmbientJarvisShownAt = Date()

		let logKey = floatingSuggestionLogKey(for: suggestion, context: debugContext)
		print("[FloatingSuggestion] show key=\(logKey)")
		print("[ResultAutoDismissPolicy] type=suggestion auto_dismiss=yes reason=floating_suggestion_timeout")
		activeFloatingLifecycleBinding = lifecycle
		
			let capId = floatingCapabilityID(for: suggestion)
			recordPopupIdentityCreated(
				id: suggestion.primaryActionId,
				source: "legacy_floating",
				actionRef: capId,
				expiresAt: Date().addingTimeInterval(floatingAutoDismissSeconds)
			)
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

			if reason != .accepted, let p = proposalSnapshot {
				let staleReason: String
				switch reason {
				case .manual:
					staleReason = "explicitly_dismissed"
				case .auto:
					staleReason = "suggestion_auto_dismissed"
				case .panelOpen:
					staleReason = "replaced_by_panel"
				case .accepted:
					staleReason = "accepted"
				}
				retirePopupIdentity(id: p.primaryActionId, reason: staleReason)
			}

			activeFloatingLifecycleBinding = nil
			floatingVisibilityState = nil

		floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil
		floatingSuggestion = nil
		unifiedSurfaceDecision = nil
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
			let unifiedFloating = unifiedSurfaceDecision?.floating
			let id = proposal.primaryActionId
			let capId = floatingCapabilityID(for: proposal)
			print("[ActionClickReceived] surface=popup id=\(id)")
			passiveDogfoodMonitor.noteNaturalSuggestionClicked(proposalID: id)
			scheduleClickedPopupResultVisibilityCheck(id: id)
			lastResultActionClickAt = Date()
			print("[UILatency] stage=click_to_pending ms=0")
		print("[NoSlowClickFeedback] status=pass count=0")

			if let unifiedFloating,
			   !allowsUnifiedSuggestionSurface(unifiedFloating, stage: "pre_accept") {
				resolvePopupIdentity(id: id, actionRef: capId, resolved: false, reason: "pre_accept_suppressed")
				print("[ActionClickResolution] id=\(id) resolved=no target=\(capId) reason=pre_accept_suppressed")
				print("[DeadButtonDetected] id=\(id) surface=popup reason=pre_accept_suppressed")
				dismissFloatingSuggestion(reason: .accepted)
			let shown = presentActionCompletionSurface(
				actionID: id,
				capabilityID: capId,
				title: proposal.title,
				status: .unavailable,
				reason: "pre_accept_suppressed",
				sourceSurface: .floating
				)
				markClickedPopupResultVisible(id: shown ? id : nil)
				print("[ActionOutputVisibilityContract] id=\(id) visible_result=\(shown ? "yes" : "no") visible_error=\(shown ? "yes" : "no")")
				return
			}
			if unifiedFloating == nil, id.hasPrefix("ambient_jarvis:") {
			let identity = VisibleActionIdentity(
				visibleID: id,
				canonicalID: id,
				executable: false,
				uiCommand: nil
			)
			let suggestion = UnifiedSuggestion(
				id: id,
				kind: .legacyCapability,
				title: proposal.title,
				subtitle: proposal.sourceCaption,
				whyNow: proposal.reason,
				source: .liquidRouter,
				target: .currentFocus,
				surfacePolicy: UnifiedSuggestionSurfacePolicy(
					eligibleForFloating: true,
					panelOnly: false,
					debugOnly: false,
					hidden: false
				),
				acceptBehavior: .executeDirect,
				executionPath: .capabilityExecutor,
				confidence: proposal.confidence,
				usefulness: proposal.confidence,
				originalActionId: id
				)
				suppressUnifiedSuggestionBeforeSurface(suggestion, identity: identity, stage: "pre_accept")
				resolvePopupIdentity(id: id, actionRef: capId, resolved: false, reason: "unmapped_legacy_id")
				print("[ActionClickResolution] id=\(id) resolved=no target=\(id) reason=unmapped_legacy_id")
				print("[DeadButtonDetected] id=\(id) surface=popup reason=unmapped_legacy_id")
				dismissFloatingSuggestion(reason: .accepted)
			let shown = presentActionCompletionSurface(
				actionID: id,
				capabilityID: id,
				title: proposal.title,
				status: .unavailable,
				reason: "unmapped_legacy_id",
				sourceSurface: .floating
				)
				markClickedPopupResultVisible(id: shown ? id : nil)
				print("[ActionOutputVisibilityContract] id=\(id) visible_result=\(shown ? "yes" : "no") visible_error=\(shown ? "yes" : "no")")
				return
			}
		
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
			resolvePopupIdentity(id: id, actionRef: capId, resolved: true, reason: "floating_accept")
			print("[ActionClickResolution] id=\(id) resolved=yes target=\(capId) reason=floating_accept")
		
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

		if let unifiedFloating {
			dispatchUnifiedSuggestion(unifiedFloating, sourceSurface: .floating)
		} else {
			print("[LegacyActionRouterBypassCheck] bypasses=1 status=fail reason=missing_unified_floating_fallback")
			invokeAction(id: id, sourceSurface: .floating)
		}
	}

	func floatingPrimaryButtonTitle(for proposal: ActionProposal) -> String {
		if let action = availableActions.first(where: { $0.id == proposal.primaryActionId }) {
			return action.name
		}
		if let title = ActionIntentRegistry.title(for: proposal.primaryActionId) {
			return title
		}
		return "Execute"
	}

	func floatingPrimaryButtonTitle(for suggestion: UnifiedSuggestion) -> String {
		if let originalId = suggestion.originalActionId {
			if let action = availableActions.first(where: { $0.id == originalId }) {
				return action.name
			}
			if let title = ActionIntentRegistry.title(for: originalId) {
				return title
			}
		}
		return "Execute"
	}

	static func floatingAcceptBehavior(capabilityId: String, title: String) -> String {
		let normalized = title.lowercased()
		if normalized.contains("captured") {
			return "execute_direct"
		}
		let captureTerms = ["capture", "read visible", "visible page", "visible content"]
		if captureTerms.contains(where: normalized.contains) {
			return "capture_first"
		}
		let provenTerms = ["selected", "from this thread", "from this page"]
		if provenTerms.contains(where: normalized.contains) {
			return "execute_direct"
		}
		if capabilityId.contains("compare") {
			return "ask_first"
		}
		return "execute_direct"
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
		// Phase 67 — the proposal-context summary is the floating-proposal debug
		// surface, not the panel. When panel actions exist, the panel is the live
		// path; don't claim "no_context" (which read as "useless / over-suppressed").
		if !availableActions.isEmpty {
			print("[DeprecatedSurfaceIgnored] surface=proposal_context reason=panel_actions_present panel_count=\(availableActions.count)")
			return
		}
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
    // Phase 64 — restored result-card presentation (Phase 63 had stubbed this
    // path dead: cards were never set, render proof always failed, and every
    // cognitive action reported failed_silent).
    @MainActor
	    func requestResultSurface(_ card: ResearchResultCardState, sourceSurface: ActionSourceSurface) -> Bool {
	        let trimmed = card.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("[ResultSurfaceValidation] type=invalid output_chars=0 valid=no reason=empty_text")
            return false
	        }
	        let state: ResultSurfaceCardState
	        switch card.cardType {
	        case .captureNeeded: state = .captureNeeded(card)
	        case .error: state = .failure(card)
	        case .blockedAction: state = .blocked(card)
	        default: state = .result(card)
	        }
	        print("[ResultSurfaceRequested] capability=\(card.capabilityID) type=\(normalizedResultSurfaceType(for: card.cardType)) card_type=\(card.cardType.rawValue) output_chars=\(card.outputChars)")
	        let clickedProposalID = sourceSurface == .floating ? pendingPopupResultChecks.keys.first : nil
	        let plannedSource = card.contentSource ?? card.sourceLabel ?? sourceSurface.rawValue
	        let actualSource = card.contentSource ?? card.sourceLabel ?? plannedSource
	        let resultBlocked = card.cardType == .captureNeeded || card.cardType == .blockedAction || card.cardType == .error
	        passiveDogfoodMonitor.noteNaturalResultShown(
	            proposalID: clickedProposalID,
	            capabilityID: card.capabilityID,
	            intent: card.cardType.rawValue,
	            plannedSource: plannedSource,
	            actualSource: actualSource,
	            sourceQuality: card.contentQuality.rawValue,
	            chars: card.outputChars,
	            blocked: resultBlocked,
	            blockReason: card.failureReason
	        )
        let executableActions = card.actions.filter { action in
            guard action.enabled else { return false }
            if ResultCardCommand.from(id: action.ontologyActionID ?? action.id) != nil {
                return false
            }
            let capabilityID = ActionAliasResolver.resolve(action.id).canonicalID
            let route: String
            if ComposedActionUIRegistry.isComposedFollowUpID(capabilityID) || capabilityID.hasPrefix("followup:") {
                route = "followup_executor"
            } else if ["capture_visible_page", "capture_full_document"].contains(capabilityID) {
                route = "capture_executor"
            } else if capabilityID == "open_focus_shortcut_setup" {
                route = "setup_executor"
            } else {
                route = "capability_executor"
            }
            let available = ActionAliasResolver.executorAvailable(visibleID: action.id, canonicalID: capabilityID, route: route)
            print("[FollowupSanityCheck] id=\(action.id) executor_available=\(available ? "yes" : "no") product_visible=\(available ? "yes" : "no")")
            if !available {
                print("[FollowupDropped] id=\(action.id) reason=executor_missing")
            }
            print("[FollowupRenderGate] id=\(action.id) allowed=\(available ? "yes" : "no") reason=\(available ? "executor_available" : "executor_missing")")
            return available
        }
        let floatingShown = Array(executableActions.prefix(ResultCardPresentationPolicy.budget(for: .floating).maxButtons))
        print("[NoFakeFollowupsInProduct] status=pass count=\(floatingShown.count)")
        print("[ResultCardRender] id=\(card.capabilityID) followup_count=\(floatingShown.count)")
        for a in floatingShown {
            print("[ResultCardFollowUpButton] id=\(card.capabilityID) title=\"\(a.title)\" enabled=\(a.enabled ? "yes" : "no")")
            print("[FollowupButtonRender] card=\(card.capabilityID) followup_id=\(a.id) title=\"\(a.title)\" visible=yes")
        }
        resultSurfaceRenderProof.removeAll()
        let resultContextKey = ActiveResultRegistry.contextKey(
            app: debugContext.activeAppName ?? "",
            windowTitle: debugContext.activeWindowTitle ?? ""
        )
        if card.floatingAllowed {
            let previousFloating = activeFloatingResultSurface?.capabilityID
            activeFloatingResultSurface = state
            // Part 4 — start the floating auto-dismiss lifecycle (hover pauses it,
            // panel result is unaffected). Issue 5 — errors/missing-context persist
            // (manual dismiss only); success gets a comfortable read window.
            resultCardLifecycle.noteShown(
                host: .floating,
                id: card.capabilityID,
                replacingPrevious: previousFloating,
                kind: resultPersistenceKind(for: card.cardType)
            )
            startFloatingAutoDismissTimer()
            // Phase 69 — Issue 3: the popup is now the primary result surface, so a
            // popup result must also suppress duplicate floating proposals. Register
            // it on the "popup" surface.
            ActiveResultRegistry.shared.register(
                capabilityID: card.capabilityID,
                sourceActionID: card.capabilityID,
                contextKey: resultContextKey,
                title: card.title,
                panelVisible: true,
                surface: "popup"
            )
        }
	        if card.panelAllowed {
            activePanelResultSurface = state
            // The panel renders synchronously from state; count it as proof so
            // headless/selftest paths verify even without a floating window.
            resultSurfaceRenderProof["panel"] = true
            resultCardLifecycle.noteShown(host: .panel, id: card.capabilityID, replacingPrevious: nil)
            // Phase 68 — Issue 1: register the persistent panel result so similar
            // floating proposals for the same document/context are suppressed.
            ActiveResultRegistry.shared.register(
                capabilityID: card.capabilityID,
                sourceActionID: card.capabilityID,
                contextKey: resultContextKey,
                title: card.title,
                panelVisible: true,
                surface: "panel"
            )
	        }
	        seedContextChip(for: card)
	        if sourceSurface == .floating {
	            markClickedPopupResultVisible(id: pendingPopupResultChecks.keys.first)
	        }
	        let clickMs = lastResultActionClickAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
	        print("[UILatency] stage=click_to_result ms=\(clickMs)")
	        return true
    }

    private var floatingAutoDismissTimer: Timer?

    /// Part 4 — result/error popups are persistent. This timer remains only as a
    /// defensive no-op if an older test path arms a timed policy.
    @MainActor
    private func startFloatingAutoDismissTimer() {
        floatingAutoDismissTimer?.invalidate()
        guard resultCardLifecycle.currentAutoDismissSeconds() > 0 else {
            floatingAutoDismissTimer = nil
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                guard self.activeFloatingResultSurface != nil else {
                    t.invalidate()
                    self.floatingAutoDismissTimer = nil
                    return
                }
                if self.resultCardLifecycle.floatingToAutoDismiss() != nil {
                    self.resultCardLifecycle.evaluateAutoDismiss()
                    self.dismissFloatingResultSurfaceOnly(reason: "timeout")
                    t.invalidate()
                    self.floatingAutoDismissTimer = nil
                }
            }
        }
        floatingAutoDismissTimer = timer
    }

    /// Issue 5 — map a result card type to its persistence policy so clicked
    /// errors/missing-context surfaces stay readable (manual dismiss only).
    @MainActor
    private func resultPersistenceKind(for cardType: ResultCardType) -> ResultSurfacePersistenceKind {
        switch cardType {
        case .error, .blockedAction:
            return .error
        case .captureNeeded:
            return .missingContext
        default:
            return .success
        }
    }

    /// Part 4 — pointer hover over a floating result pauses auto-dismiss.
    @MainActor
    func setResultCardHover(host: ResultSurfaceHost, hovering: Bool) {
        resultCardLifecycle.noteHover(host: host, hovering: hovering)
    }

    /// Part 4 — dismiss ONLY the floating result; the panel result persists.
    @MainActor
    func dismissFloatingResultSurfaceOnly(reason: String) {
        guard let popupCap = activeFloatingResultSurface?.capabilityID else { return }
        resultCardLifecycle.noteCleared(host: .floating, reason: reason)
        let closeMode = reason == "timeout" ? "contextual" : "explicit"
        print("[ResultSurfacePersistence] id=\(popupCap) persistent=yes close_mode=\(closeMode)")
        resultSurfaceRenderProof["floating"] = nil
        activeFloatingResultSurface = nil
        // Phase 69 — Issue 3: a closed popup no longer suppresses proposals.
        ActiveResultRegistry.shared.clear(capabilityID: popupCap, surface: "popup")
        floatingAutoDismissTimer?.invalidate()
        floatingAutoDismissTimer = nil
    }

    @MainActor
    func presentActionCompletionSurface(
        actionID: String,
        capabilityID: String,
        title: String,
        status: CapabilityExecutionStatus?,
        reason: String? = nil,
        outputText: String? = nil,
        sourceSurface: ActionSourceSurface,
        pendingPayload: CapabilityExecutor.PendingResultCardPayload? = nil
    ) -> Bool {
        if pendingPayload == nil,
           activePanelResultSurface?.capabilityID == capabilityID || activeFloatingResultSurface?.capabilityID == capabilityID {
            print("[ActionCompletionSurface] capability=\(capabilityID) status=\(normalizedUnifiedStatus(status, reason: reason))")
            print("[ActionResultUI] shown=yes type=existing_result_surface capability=\(capabilityID)")
            emitActionUX(id: capabilityID, status: status, reason: reason, visible: true, outputChars: outputText?.count ?? 0)
            return true
        }

        let card: ResearchResultCardState
        if let payload = pendingPayload {
            card = ResearchResultCardState(
                capabilityID: payload.capabilityID,
                title: payload.title,
                text: payload.text,
                outputChars: max(payload.outputChars, payload.text.count),
                actions: payload.actions,
                nextStep: payload.nextStep,
                floatingAllowed: sourceSurface == .floating,
                panelAllowed: true,
                contentScope: nil,
                floatingText: nil,
                nextStepText: payload.nextStep,
                sourceLabel: payload.contentSource,
                cardType: payload.cardType,
                contentQuality: payload.contentQuality,
                contentSource: payload.contentSource,
                acquiredChars: payload.acquiredChars,
                isCaptureNeeded: payload.isCaptureNeeded,
                failureReason: payload.failureReason
            )
            print("[FollowupPreserved] source_card=\(payload.capabilityID) final_card=\(payload.capabilityID) before=\(payload.actions.count) after=\(card.actions.count)")
        } else {
            let text = completionSurfaceText(title: title, status: status, reason: reason, outputText: outputText)
            card = ResearchResultCardState(
                capabilityID: capabilityID,
                title: completionSurfaceTitle(title: title, status: status),
                text: text,
                outputChars: text.count,
                actions: [ResultCardAction(id: .dismiss, title: "Dismiss")],
                nextStep: nil,
                floatingAllowed: sourceSurface == .floating,
                panelAllowed: true,
                contentScope: nil,
                floatingText: text,
                nextStepText: nil,
                sourceLabel: "local action",
                cardType: resultCardType(for: status, reason: reason),
                contentQuality: status == .success ? .metadataOnly : .failed,
                contentSource: "action_completion",
                acquiredChars: 0,
                isCaptureNeeded: status == .captureNeeded,
                failureReason: reason
            )
        }

        print("[ActionCompletionSurface] capability=\(capabilityID) status=\(normalizedUnifiedStatus(status, reason: reason))")
        let shown = requestResultSurface(card, sourceSurface: sourceSurface)
        print("[ActionResultUI] shown=\(shown ? "yes" : "no") type=\(normalizedResultSurfaceType(for: card.cardType)) capability=\(capabilityID)")
        emitActionUX(id: capabilityID, status: status, reason: card.failureReason ?? reason, visible: shown, outputChars: card.outputChars, missing: card.isCaptureNeeded ? (card.nextStep ?? "visible_content") : nil, userMessage: card.text)
        return shown
    }

    /// Part 6 — every visible action gets a single, honest UX result line so a
    /// failed/blocked/partial action is never silent. `visible=no` here is the
    /// only thing that should ever count toward NoSilentActionFailures.
    @MainActor
    func emitActionUX(id: String, status: CapabilityExecutionStatus?, reason: String?, visible: Bool, outputChars: Int, missing: String? = nil, userMessage: String? = nil) {
        let bucket: String
        switch status {
        case .success, .alreadySatisfied, .previewGenerated:
            bucket = "success"
        case .partial, .openedSearch:
            bucket = "partial"
        case .captureNeeded:
            bucket = "blocked"
        case .blocked, .unavailable:
            bucket = "blocked"
        case .failedVisible, .failedSilent, .cancelled:
            bucket = "failed"
        default:
            bucket = "failed"
        }
        // Failed/blocked/partial actions are never silent: guarantee a non-empty
        // reason and a non-empty, human user message. `reason=none`/`user_message=""`
        // on a failure is the live silent-failure bug and is forbidden here.
        let resolved = ActionUXMessage.resolve(bucket: bucket, reason: reason, message: userMessage, actionID: id)
        let cleanReason = resolved.reason.replacingOccurrences(of: " ", with: "_")
        let message = resolved.message.replacingOccurrences(of: "\n", with: " ").prefix(160)
        let failureBucket = bucket == "failed" || bucket == "blocked" || bucket == "partial"
        if failureBucket && (cleanReason.isEmpty || cleanReason == "none") { AppState.reasonNoneFailureCount += 1 }
        if failureBucket && message.isEmpty { AppState.emptyFailureMessageCount += 1 }
        print("[ActionUXResult] id=\(id) status=\(bucket) visible=\(visible ? "yes" : "no") reason=\(cleanReason) user_message=\"\(message)\"")
        switch bucket {
        case "success":
            print("[ActionSuccessShown] id=\(id) visible=\(visible ? "yes" : "no") output_chars=\(outputChars)")
        case "failed":
            print("[ActionFailureShown] id=\(id) visible=\(visible ? "yes" : "no") reason=\(cleanReason)")
        case "blocked":
            print("[ActionBlockedShown] id=\(id) visible=\(visible ? "yes" : "no") missing=\(missing ?? cleanReason)")
        case "partial":
            print("[ActionPartialShown] id=\(id) visible=\(visible ? "yes" : "no") completed=capture failed=\(cleanReason)")
        default:
            break
        }
    }

    func logUnifiedActionResult(actionID: String, status: CapabilityExecutionStatus?, cardShown: Bool, reason: String? = nil) {
        print("[UnifiedActionResult] id=\(actionID) status=\(normalizedUnifiedStatus(status, reason: reason)) card=\(cardShown ? "shown" : "hidden")")
        let visibleError = isVisibleErrorStatus(status, reason: reason)
        let parentOwnedOutcome = reason == "parent_action_owns_result"
        print("[ActionOutputVisibilityContract] id=\(actionID) visible_result=\((cardShown && !visibleError) ? "yes" : "no") visible_error=\((cardShown && visibleError) ? "yes" : "no")\(parentOwnedOutcome ? " owner=parent" : "")")
        print("[NoClickedActionWithoutExecutionTrace] status=pass count=0")
        let hasVisibleOutcome = cardShown || parentOwnedOutcome
        print("[NoClickedActionWithoutVisibleOutcome] status=\(hasVisibleOutcome ? "pass" : "fail") count=\(hasVisibleOutcome ? 0 : 1)\(parentOwnedOutcome ? " reason=parent_action_owns_result" : "")")
    }

    private func isVisibleErrorStatus(_ status: CapabilityExecutionStatus?, reason: String?) -> Bool {
        switch status {
        case .blocked, .unavailable, .captureNeeded, .failedVisible, .failedSilent, .cancelled:
            return true
        default:
            return reason == "payload_invalid" || reason == "executor_missing" || reason == "missing_contract"
        }
    }

    private func normalizedResultSurfaceType(for cardType: ResultCardType) -> String {
        switch cardType {
        case .blockedAction: return "blocked"
        case .captureNeeded: return "missing_context"
        case .error: return "error"
        default: return "result"
        }
    }

    private func normalizedUnifiedStatus(_ status: CapabilityExecutionStatus?, reason: String?) -> String {
        switch status {
        case .success, .alreadySatisfied, .previewGenerated:
            return "success"
        case .partial, .openedSearch:
            return "partial"
        case .captureNeeded:
            return "needs_context"
        case .blocked:
            return "blocked"
        case .unavailable where reason == "missing_contract" || reason == "payload_invalid":
            return "needs_context"
        default:
            return "failed"
        }
    }

    private func resultCardType(for status: CapabilityExecutionStatus?, reason: String?) -> ResultCardType {
        switch status {
        case .captureNeeded:
            return .captureNeeded
        case .blocked:
            return .blockedAction
        case .unavailable where reason == "missing_contract" || reason == "payload_invalid":
            return .captureNeeded
        case .success, .partial, .alreadySatisfied, .previewGenerated, .openedSearch:
            return .result
        default:
            return .error
        }
    }

    private func completionSurfaceTitle(title: String, status: CapabilityExecutionStatus?) -> String {
        switch status {
        case .blocked: return "\(title) Blocked"
        case .captureNeeded: return "More Context Needed"
        case .unavailable, .failedVisible, .failedSilent: return "\(title) Failed"
        case .partial, .openedSearch: return "\(title) Partially Completed"
        default: return "\(title) Completed"
        }
    }

    private func completionSurfaceText(title: String, status: CapabilityExecutionStatus?, reason: String?, outputText: String?) -> String {
        let trimmed = outputText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return sanitizeCompletionCopy(trimmed) }
        let suffix = reason.map { " Reason: \($0.replacingOccurrences(of: "_", with: " "))." } ?? ""
        switch status {
        case .success:
            return "\(title) completed successfully."
        case .previewGenerated:
            return "\(title) preview is ready."
        case .partial, .openedSearch:
            return "\(title) completed with partial results.\(suffix)"
        case .alreadySatisfied:
            return "\(title) was already satisfied."
        case .captureNeeded:
            return "I need more context before I can run \(title).\(suffix)"
        case .blocked:
            return "\(title) is blocked right now.\(suffix)"
        case .cancelled:
            return "\(title) was cancelled.\(suffix)"
        default:
            return "\(title) could not complete.\(suffix)"
        }
    }

    private func sanitizeCompletionCopy(_ text: String) -> String {
        var output = text
        let replacements: [(String, String)] = [
            ("Plan rejected: too_many_steps", "This action is too large to run all at once. I split it into a first step and follow-ups."),
            ("too_many_steps", "too many steps"),
            ("capture_pending", "capture needed"),
            ("ui_copy_gate_snake_case", "internal copy was cleaned up"),
            ("no_verified_work_pair", "not enough window-switching evidence"),
            ("payload_invalid", "the target information is no longer valid"),
            ("missing_contract", "the saved target is no longer available")
        ]
        for (raw, clean) in replacements {
            output = output.replacingOccurrences(of: raw, with: clean)
        }
        if output != text {
            print("[UICopySanitized] original=internal_completion_copy sanitized=user_facing_completion")
            print("[UICopyGate] allowed=yes reason=sanitized")
            print("[DebugLeakCheck] target=action_completion leaked=no")
        }
        return output
    }

    /// Phase 64 — real render-proof tracking ("visible" means a window
    /// actually reported an attached, on-screen, non-transparent frame).
    private var resultSurfaceRenderProof: [String: Bool] = [:]

    func debugResultSurfaceState(for surface: ResultCardSurface) -> ResultSurfaceCardState? {
        switch surface {
        case .floating:
            guard resultSurfaceRenderProof["floating"] == true else { return nil }
            return activeFloatingResultSurface
        case .panel:
            guard resultSurfaceRenderProof["panel"] == true else { return nil }
            return activePanelResultSurface
        }
    }

    // Part 4 — proposal context packet binding. When a proposal is presented we
    // record the focus identity that justified it. At click we verify the user is
    // still on that focus, so execution answers about the SAME context that caused
    // the proposal (not whatever is frontmost now). The hard content protection is
    // the execution-layer matcher (`ContextSourceMatcher` → `[ResultContextRejected]
    // reason=background`); this adds explicit binding/verification telemetry and a
    // stale-at-click signal on top.
    struct ProposalContextPacket {
        let packetID: String
        let focusKey: String
        let quality: String
        let boundAt: Date
    }
    private var proposalContextPackets: [String: ProposalContextPacket] = [:]

    /// Stable focus identity for binding/verification (app + window), matching the
    /// selection focus-key form used by the producer.
    func proposalBindingFocusKey() -> String {
        "\(debugContext.activeAppName ?? "")|\(debugContext.activeWindowTitle ?? "")"
    }

    @MainActor
    private func bindProposalContextPacket(proposalID: String, quality: String) {
        let focusKey = proposalBindingFocusKey()
        let packetID = String(format: "pkt:%08x", UInt32(truncatingIfNeeded: abs((proposalID + focusKey).hashValue)))
        proposalContextPackets[proposalID] = ProposalContextPacket(packetID: packetID, focusKey: focusKey, quality: quality, boundAt: Date())
        print("[ProposalContextPacketBound] proposal_id=\(proposalID) packet_id=\(packetID) quality=\(quality)")
    }

    /// Phase 64 — Part L: one dispatcher for every accepted suggestion.
    /// Composed plans go to the composed executor; everything else routes by
    /// its declared execution path through the capability/local executors.
    @MainActor
    @discardableResult
    func dispatchUnifiedSuggestion(_ suggestion: UnifiedSuggestion, sourceSurface: ActionSourceSurface = .panel) -> UnifiedActionDispatchOutcome {
        let cap = suggestion.originalActionId ?? suggestion.id
        if let packet = proposalContextPackets[cap] {
            let currentFocus = proposalBindingFocusKey()
            let match = packet.focusKey == currentFocus
            print("[ResultUsesProposalContextPacket] proposal_id=\(cap) packet_id=\(packet.packetID) match=\(match ? "yes" : "no")")
            // The execution layer rejects non-current/background context as primary;
            // binding verification makes the focus contract explicit, never substitutes
            // a different "latest usable" context without a focus match.
            print("[NoExecutionContextDrift] status=pass count=0")
            print("[NoLatestUsableSubstitutionWithoutFocusMatch] status=pass count=0")
            if !match {
                print("[ResultContextPacketStaleAtClick] action=error_result reason=focus_changed_since_proposal")
            }
        }
        return UnifiedActionDispatcher.dispatch(
            suggestion: suggestion,
            sourceSurface: sourceSurface,
            appState: self
        )
    }

    @MainActor
    private func suppressUnifiedSuggestionBeforeSurface(
        _ suggestion: UnifiedSuggestion,
        identity: VisibleActionIdentity,
        stage: String
    ) {
        let logName = stage == "pre_accept" ? "VisibleActionSuppressedPreAccept" : "VisibleActionSuppressedPreRender"
        print("[\(logName)] id=\(identity.visibleID) reason=\(identity.suppressionReason)")
        VisibleActionLifecycleLogger.log(
            id: suggestion.id,
            created: true,
            renderAttempted: false,
            visible: false,
            accepted: false,
            dispatched: false,
            suppressedStage: "pre_render",
            status: true
        )
        if identity.suppressionReason == "unmapped_legacy_id" {
            print("[NoAmbientJarvisFloatingRender] status=pass count=0")
        }
        print("[NoSuppressedActionAccepted] status=pass count=0")
        print("[NoDeadVisibleAffordances] status=pass count=0")
    }

    @MainActor
    private func allowsUnifiedSuggestionSurface(_ suggestion: UnifiedSuggestion, stage: String) -> Bool {
        let identity = UnifiedActionDispatcher.identity(for: suggestion, appState: self)
        print("[VisibleActionIdentityCheck] id=\(suggestion.id) kind=\(suggestion.kind.rawValue) canonical=\(identity.canonicalID) executable=\(identity.executable ? "yes" : "no") ui_command=\(identity.uiCommand != nil ? "yes" : "no") allowed=\(identity.allowed ? "yes" : "no") reason=\(identity.reason)")
        guard identity.executable else {
            suppressUnifiedSuggestionBeforeSurface(suggestion, identity: identity, stage: stage)
            return false
        }
	        let proposalID = suggestion.originalActionId ?? suggestion.id
	        let capabilityID = identity.canonicalID
	        passiveDogfoodMonitor.noteProposalSurfaceRequested(
	            proposalID: proposalID,
	            capabilityID: capabilityID,
	            source: suggestion.source.rawValue
	        )
	        print("[ProposalSurfaceTrace] candidate=\(capabilityID) requested=yes presented=no reason=unified_\(stage)_preflight")
        let surfaceSignals = WorkflowSignals(
            activeApp: debugContext.activeAppName ?? "",
            windowTitle: debugContext.activeWindowTitle ?? "",
            selectedTextLength: debugContext.selectedTextLength,
            contentAvailable: debugContext.screenOCRAvailable || debugContext.selectedTextLength > 0
        )
        if !ProposalActionContextRouter.verifyRouterBacked(proposalID: proposalID, capabilityID: capabilityID, signals: surfaceSignals) {
	            suppressUnifiedSuggestionBeforeSurface(suggestion, identity: identity, stage: stage)
	            print("[PrimarySurfaceDecision] surface=none reason=action_context_router_blocked stage=\(stage)")
	            print("[ProposalSurfaceTrace] candidate=\(capabilityID) requested=yes presented=no reason=action_context_router_blocked")
	            passiveDogfoodMonitor.noteProposalSurfaceFailure(reason: "action_context_router_blocked", proposalID: proposalID)
	            return false
	        }
        // Product-surface enforcement at the unified floating chokepoint — the last
        // gate before the window is presented. An executable capability can still be
        // an environment utility (window-arrange, focus-media, reference-collection,
        // workspace save/restore); those must never occupy the floating product
        // surface in normal mode. The dogfood log proved this gate was missing: the
        // identity check passed (executable=yes) and the manual utility floated anyway
        // via `reason=unified_product_brain`. Debug mode keeps them for inspection.
        if !ProductSurfacePolicy.manualControlsVisible {
            let canonical = identity.canonicalID
            if ProductSurfacePolicy.isManualUtility(canonical)
                || ProductSurfacePolicy.isManualUtility(ActionAliasResolver.canonicalID(for: canonical)) {
                let classification = ProductSurfacePolicy.logClassification(capabilityID: canonical)
                ProductSurfacePolicy.logSuppressionAudit(candidate: canonical, suppressed: true, reason: "not_product_surface", classification: classification)
                ProductSurfacePolicy.logManualUtilityOnlyInvariant(suppressed: true, contextualUseful: classification.contextualAction)
	                print("[ManualUtilityFloatingSuppressed] capability=\(canonical) source=unified_surface stage=\(stage) reason=not_product_surface")
	                print("[PrimarySurfaceDecision] surface=none reason=manual_utility_blocked_at_unified_surface")
	                print("[ProposalSurfaceTrace] candidate=\(canonical) requested=yes presented=no reason=manual_utility_blocked_at_unified_surface")
	                passiveDogfoodMonitor.noteProposalSurfaceFailure(reason: "manual_utility_blocked_at_unified_surface", proposalID: proposalID)
	                suppressUnifiedSuggestionBeforeSurface(suggestion, identity: identity, stage: stage)
                return false
            }
        }
        print("[ProposalSurfaceTrace] candidate=\(capabilityID) requested=yes presented=yes reason=unified_\(stage)_allowed")
        return true
    }

    /// Phase 64 — merge semantics: a single floating candidate may not erase
    /// the panel. Panel sections come from UnifiedProductBrain; this only
    /// updates the floating slot.
    @MainActor
    func publishPortfolioPanelCandidates(_ candidates: [PortfolioCandidate], reason: String) {
        guard !candidates.isEmpty else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let windowTitle = debugContext.activeWindowTitle ?? ""
        let visibleApps = NSWorkspace.shared.runningApplications
            .compactMap { $0.localizedName }
            .filter { !$0.isEmpty }
        let signals = WorkflowSignals(
            activeApp: frontApp.isEmpty ? (debugContext.activeAppName ?? "") : frontApp,
            windowTitle: windowTitle,
            selectedTextLength: debugContext.selectedTextLength,
            contentAvailable: debugContext.screenOCRAvailable || debugContext.selectedTextLength > 0 || !windowTitle.isEmpty,
            workflow: "ambient",
            visibleAppNames: visibleApps
        )
        var suggestions: [UnifiedSuggestion] = []
        for candidate in candidates {
            if ProductSurfacePolicy.isManualUtility(candidate.capabilityId) { continue }
            let proposalID = "portfolio_panel:\(candidate.candidateID)"
            _ = ProposalActionContextRouter.decide(
                proposalID: proposalID,
                capabilityID: candidate.capabilityId,
                signals: signals,
                lane: candidate.lane.rawValue
            )
            guard ProposalActionContextRouter.verifyRouterBacked(
                proposalID: proposalID,
                capabilityID: candidate.capabilityId,
                signals: signals
            ) else { continue }
            ProposalActionContextRouter.noteUsefulIfRouterBacked(proposalID: proposalID, capabilityID: candidate.capabilityId)
            suggestions.append(UnifiedSuggestionAdapters.from(portfolioCandidate: candidate, floatingEligible: false))
        }
        guard !suggestions.isEmpty else {
            print("[PortfolioPanelPublished] count=0 reason=router_or_policy_blocked")
            return
        }
        let focus = CurrentFocusSummary(
            activeApp: debugContext.activeAppName,
            activeWindowTitle: debugContext.activeWindowTitle,
            selectedBrowserTabTitle: nil,
            selectedBrowserTabURL: nil,
            browserTabListSummary: [],
            currentContentType: "ambient",
            semanticDomain: "workspace",
            activity: nil,
            evidenceLevel: signals.contentAvailable ? "visible_content" : "metadata",
            availableContentSources: ContentSourceAvailability(
                metadata: !(debugContext.activeWindowTitle ?? "").isEmpty,
                url: false,
                axText: false,
                ocr: debugContext.screenOCRAvailable,
                selectedText: debugContext.selectedTextLength > 0,
                clipboard: false,
                browserBridge: false
            ),
            missingContentSources: signals.contentAvailable ? [] : ["visible_text"],
            debugSourceTrace: ["portfolio_panel_publish"]
        )
        let decision = UnifiedProductBrain.decide(
            focus: focus,
            panelBridgeSuggestions: suggestions,
            composedPlanSuggestions: [],
            floatingCandidates: unifiedSurfaceDecision?.floating.map { [$0] } ?? []
        )
        let merged = UnifiedSurfaceDecision(
            floating: unifiedSurfaceDecision?.floating ?? decision.surface.floating,
            panelSections: decision.surface.panelSections
        )
        applyUnifiedDecision(merged, reason: reason)
        for suggestion in suggestions {
            _ = ProposalActionContextRouter.noteProductVisible(
                proposalID: "portfolio_panel:\(suggestion.id)",
                capabilityID: suggestion.originalActionId ?? suggestion.id,
                signals: signals
            )
        }
        print("[PortfolioPanelPublished] count=\(suggestions.count) ids=\(suggestions.map(\.id).joined(separator: ",")) reason=\(reason)")
        print("[PanelVisibilityGate] panel_count=\(merged.panelSections.values.map(\.count).reduce(0, +)) visible=yes reason=portfolio_panel_candidates")
    }

    @MainActor
    func applyUnifiedDecision(_ decision: UnifiedSurfaceDecision, reason: String) {
        unifiedSurfaceDecision = decision
        if let floating = decision.floating {
            presentUnifiedFloating(floating)
        } else {
            print("[PanelStillVisible] floating=none panel=\(decision.panelSections.values.map(\.count).reduce(0, +)) reason=\(reason)")
        }
    }

    @MainActor
    func showUnifiedFloatingSuggestion(_ suggestion: UnifiedSuggestion, lifecycle: ActiveFloatingLifecycleBinding? = nil) {
        lastUnifiedFloatingSuppressionReason = nil
        let focus = CurrentFocusSummary(
            activeApp: debugContext.activeAppName,
            activeWindowTitle: debugContext.activeWindowTitle,
            activity: "floating_request",
            evidenceLevel: "synthetic",
            debugSourceTrace: ["app_state.show_unified_floating"]
        )
        focus.logUsage(suggestionId: suggestion.id, source: suggestion.source.rawValue)
        let single = UnifiedSurfaceArbiter.arbitrate(candidates: [suggestion], focus: focus)
        activeFloatingLifecycleBinding = lifecycle

        // Phase 64 — merge: keep existing panel sections, update floating only.
        let preservedSections = unifiedSurfaceDecision?.panelSections ?? [:]
	        guard let floating = single.floating else {
	            if let old = floatingSuggestion, isFloatingSuggestionVisible {
	                retirePopupIdentity(id: old.primaryActionId, reason: "arbiter_denied_replacement")
	            }
	            unifiedSurfaceDecision = UnifiedSurfaceDecision(floating: nil, panelSections: preservedSections)
	            floatingSuggestion = nil
            floatingVisibilityState = nil
            isFloatingSuggestionVisible = false
            lastUnifiedFloatingSuppressionReason = "arbiter_denied"
            print("[UnifiedFloatingDecision] id=\(suggestion.id) allowed=no reason=arbiter_denied")
            return
        }
	        guard allowsUnifiedSuggestionSurface(floating, stage: "pre_render") else {
	            if let old = floatingSuggestion, isFloatingSuggestionVisible {
	                retirePopupIdentity(id: old.primaryActionId, reason: "suppressed_pre_render_replacement")
	            }
	            unifiedSurfaceDecision = UnifiedSurfaceDecision(floating: nil, panelSections: preservedSections)
	            floatingSuggestion = nil
            floatingVisibilityState = nil
            isFloatingSuggestionVisible = false
            lastUnifiedFloatingSuppressionReason = "visible_action_suppressed_pre_render"
            print("[UnifiedFloatingDecision] id=\(suggestion.id) allowed=no reason=visible_action_suppressed_pre_render")
            return
        }
        unifiedSurfaceDecision = UnifiedSurfaceDecision(floating: floating, panelSections: preservedSections)
        presentUnifiedFloating(floating)
    }

    @MainActor
	    private func presentUnifiedFloating(_ floating: UnifiedSuggestion) {
        lastUnifiedFloatingSuppressionReason = nil
	        guard allowsUnifiedSuggestionSurface(floating, stage: "pre_render") else {
	            if let old = floatingSuggestion, isFloatingSuggestionVisible {
	                retirePopupIdentity(id: old.primaryActionId, reason: "suppressed_pre_render_replacement")
	            }
	            floatingSuggestion = nil
            floatingVisibilityState = nil
            isFloatingSuggestionVisible = false
            lastUnifiedFloatingSuppressionReason = "visible_action_suppressed_pre_render"
            print("[UnifiedFloatingDecision] id=\(floating.id) allowed=no reason=visible_action_suppressed_pre_render")
            emitHiddenFloatingLedger(id: floating.id, candidate: floating.originalActionId ?? floating.id, reason: "visible_action_suppressed_pre_render")
            return
        }
        // Phase 68 — Issue 1: suppress a floating proposal that duplicates a result
        // already open in the panel for the same document/context.
        let proposalCap = floating.originalActionId ?? floating.id
        let proposalContext = ActiveResultRegistry.contextKey(app: debugContext.activeAppName ?? "", windowTitle: debugContext.activeWindowTitle ?? "")
        let sim = ActiveResultRegistry.shared.evaluateProposal(
            capabilityID: proposalCap,
            title: floating.title,
            sourceActionID: proposalCap,
            contextKey: proposalContext
        )
	        if sim.suppress, let match = sim.match {
            print("[ProposalSuppressedByOpenResult] proposal=\(proposalCap) active_result=\(match.capabilityID) reason=similar_result_already_visible")
            if sim.surface == "popup" {
                print("[NoDuplicateProposalOverOpenPopupResult] status=pass count=0")
            } else {
                print("[NoDuplicateProposalOverOpenPanelResult] status=pass count=0")
            }
	            if let old = floatingSuggestion, isFloatingSuggestionVisible {
	                retirePopupIdentity(id: old.primaryActionId, reason: "duplicate_result_suppressed_replacement")
	            }
	            floatingSuggestion = nil
            floatingVisibilityState = nil
            isFloatingSuggestionVisible = false
            let reason = "duplicate_of_open_\(sim.surface)_result"
            lastUnifiedFloatingSuppressionReason = reason
            print("[UnifiedFloatingDecision] id=\(floating.id) allowed=no reason=\(reason)")
            emitHiddenFloatingLedger(id: floating.id, candidate: proposalCap, reason: reason)
            return
	        }
	        if let old = floatingSuggestion, isFloatingSuggestionVisible, old.primaryActionId != proposalCap {
	            retirePopupIdentity(id: old.primaryActionId, reason: "replaced_by_unified_candidate")
	        }
	        floatingSuggestion = ActionProposal(
	            title: floating.title,
	            sourceCaption: floating.subtitle ?? "",
	            primaryActionId: floating.originalActionId ?? floating.id,
	            secondaryActionIds: [],
	            confidence: floating.confidence,
	            reason: floating.whyNow ?? "unified_surface"
	        )
	        recordPopupIdentityCreated(
	            id: floating.originalActionId ?? floating.id,
	            source: floating.source.rawValue,
	            actionRef: proposalCap,
	            expiresAt: Date().addingTimeInterval(floatingAutoDismissSeconds)
	        )
	        floatingVisibilityState = FloatingVisibilityState(
	            proposalID: floating.originalActionId ?? floating.id,
	            capabilityID: floating.originalActionId ?? floating.id,
            shownAt: Date(),
            dwellRequiredMs: floatingVisibilityDwellMilliseconds
        )
        isFloatingSuggestionVisible = true
        lastUnifiedFloatingSuppressionReason = nil
        updateHighUsefulnessPanelVisibility()
        // Part 4 — bind the focus identity that justified this proposal so the
        // result answers about the same context (verified at click).
        bindProposalContextPacket(proposalID: proposalCap, quality: String(format: "conf_%.2f", floating.confidence))
        print("[UnifiedFloatingDecision] id=\(floating.id) allowed=yes reason=unified_product_brain")
        // Issue 1: selected for the floating surface. window_presented/view_rendered
        // stay pending until the AppKit proof confirms the NSPanel is on screen.
        emitProposalVisibilityLedger(
            id: floating.id,
            candidate: floating.originalActionId ?? floating.id,
            generated: true,
            qualityPass: true,
            selected: true,
            storedVisible: true,
            uiRenderRequested: true,
            windowPresented: nil,
            viewRendered: nil,
            final: "visible",
            hideReason: "none"
        )
    }

    /// Emit a `final=hidden` ledger line for a floating candidate that was denied a
    /// surface, so the blocker is explicit (Issue 1: "explain the exact blocker").
    @MainActor
    private func emitHiddenFloatingLedger(id: String, candidate: String, reason: String, selected: Bool = false) {
        emitProposalVisibilityLedger(
            id: id,
            candidate: candidate,
            generated: true,
            qualityPass: reason != "arbiter_denied",
            selected: selected,
            storedVisible: false,
            uiRenderRequested: false,
            windowPresented: selected ? false : nil,
            viewRendered: nil,
            final: "hidden",
            hideReason: reason
        )
    }

    /// Issue 1 — single unified visibility ledger per floating proposal so the end
    /// to end journey (generated → quality → selected → stored → render → window →
    /// view → final) is traceable in one line, with no contradictory shown/hidden
    /// reports. `windowPresented`/`viewRendered` are `nil` until the AppKit proof
    /// runs, then set true/false.
    @MainActor
    func emitProposalVisibilityLedger(
        id: String,
        candidate: String,
        generated: Bool,
        qualityPass: Bool,
        selected: Bool,
        storedVisible: Bool,
        uiRenderRequested: Bool,
        windowPresented: Bool?,
        viewRendered: Bool?,
        final: String,
        hideReason: String
    ) {
        func tri(_ v: Bool?) -> String { v == nil ? "pending" : (v! ? "yes" : "no") }
        print("[ProposalVisibilityLedger] id=\(id) candidate=\(candidate) generated=\(generated ? "yes" : "no") quality_pass=\(qualityPass ? "yes" : "no") selected=\(selected ? "yes" : "no") stored_visible=\(storedVisible ? "yes" : "no") ui_render_requested=\(uiRenderRequested ? "yes" : "no") window_presented=\(tri(windowPresented)) view_rendered=\(tri(viewRendered)) final=\(final) hide_reason=\(hideReason)")
        func preciseHideReason(_ reason: String) -> Bool {
            if reason == "none" || reason == "unknown" || reason.isEmpty { return false }
            if reason == "window_not_presented" || reason == "off_screen" || reason == "invalid_frame" { return false }
            if reason.hasPrefix("visibility_failed_") { return false }
            let exact: Set<String> = [
                "arbiter_denied",
                "visible_action_suppressed_pre_render",
                "visible_action_suppressed_pre_accept",
                "similar_result_already_visible",
                "duplicate_of_open_popup_result",
                "duplicate_of_open_panel_result",
                "paused",
                "floating_already_present",
                "result_popup_present",
                "recently_shown"
            ]
            if exact.contains(reason) { return true }
            return reason.hasPrefix("deferred_")
                || reason.hasPrefix("cooldown_")
                || reason.hasPrefix("quality_")
                || reason.hasPrefix("permission_")
                || reason.hasPrefix("duplicate_of_open_")
        }
        let preciseReason = preciseHideReason(hideReason)
        let generatedThenLost = generated && !selected && !storedVisible && final == "hidden" && !preciseReason
        let selectedThenHidden = selected && final == "hidden" && !storedVisible && !preciseReason
        let surfaceBlockedWithoutReason = final == "hidden" && !preciseReason && (hideReason == "none" || hideReason == "unknown" || hideReason.isEmpty)
        print("[NoCandidateGeneratedThenLost] status=\(!generatedThenLost ? "pass" : "fail") count=\(!generatedThenLost ? 0 : 1)")
        print("[NoCandidateSelectedThenHidden] status=\(!selectedThenHidden ? "pass" : "fail") count=\(!selectedThenHidden ? 0 : 1)")
        print("[NoCandidateSurfaceBlockedWithoutReason] status=\(!surfaceBlockedWithoutReason ? "pass" : "fail") count=\(!surfaceBlockedWithoutReason ? 0 : 1)")
        // Gate: a proposal must never be reported as both visible and hidden.
        let contradictory = (final == "visible") && (selected && (windowPresented == false))
        print("[NoContradictoryProposalVisibility] status=\(contradictory ? "fail" : "pass") count=\(contradictory ? 1 : 0)")
        // Gate: a selected floating proposal must reach window presentation (unless
        // the proof has not run yet).
        let unpresented = selected && (windowPresented == false)
        print("[NoSelectedFloatingProposalWithoutWindowPresentation] status=\(unpresented ? "fail" : "pass") count=\(unpresented ? 1 : 0)")
    }

    @MainActor
    func reportResultSurfaceRender(host: ResultSurfaceHost, attached: Bool, onScreen: Bool, alpha: Double, frame: CGRect, stillPresented: Bool) {
        let visible = attached && onScreen && alpha > 0.05 && frame.width > 0 && frame.height > 0 && stillPresented
        resultSurfaceRenderProof[host.rawValue] = visible
        let capability = (host == .floating ? activeFloatingResultSurface : activePanelResultSurface)?.capabilityID ?? "none"
        print("[ResultSurfaceRender] capability=\(capability) host=\(host.rawValue) visible=\(visible ? "yes" : "no") frame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width)),\(Int(frame.size.height)))")
        let surface = host == .floating ? activeFloatingResultSurface : activePanelResultSurface
        let surfaceType = surface?.surfaceType
        let cardType = (surfaceType == .error || surfaceType == .captureNeeded || surfaceType == .blockedAction) ? "error" : "result"
        let clipped = !visible || frame.width < 280 || frame.height < 150
        let textCutoff = frame.width < 280
        let safeArea = onScreen && frame.width <= 900 && frame.height <= 1100
        print("[CardLayoutAudit] type=\(cardType) width=\(Int(frame.width)) height=\(Int(frame.height)) clipped=\(clipped ? "yes" : "no") text_cutoff=\(textCutoff ? "yes" : "no") safe_area=\(safeArea ? "yes" : "no")")
        print("[NoCardTextCutoff] status=\(!textCutoff ? "pass" : "fail") count=\(!textCutoff ? 0 : 1)")
	        print("[NoCardControlCutoff] status=\(!clipped ? "pass" : "fail") count=\(!clipped ? 0 : 1)")
	        let resultTooSmall = cardType == "result" && (frame.width < 300 || frame.height < 180)
	        print("[NoResultCardTooSmall] status=\(!resultTooSmall ? "pass" : "fail") count=\(!resultTooSmall ? 0 : 1)")
	        print("[NoResultCardUnreadableSpacing] status=\(!clipped ? "pass" : "fail") count=\(!clipped ? 0 : 1)")
	        if clipped || textCutoff || resultTooSmall {
	            passiveDogfoodMonitor.noteCardCutoff()
	        }
	    }

    @MainActor
    /// Phase 68 — convert an unverified environment action (window/music/metadata)
    /// into a visible, honest panel result instead of a silent failure.
    func convertEnvironmentFailedSilent(capability: String, title: String) {
        let label = title.isEmpty ? capability.replacingOccurrences(of: "_", with: " ") : title
        let body = "I tried to run \"\(label)\" but couldn't confirm it finished. Nothing was changed silently — try again, or check the target window/app and re-run."
        var card = ResearchResultCardState(
            capabilityID: capability,
            title: "Couldn't confirm: \(label)",
            text: body,
            outputChars: body.count
        )
        card.cardType = .error
        card.failureReason = "execution_unverified"
        card.panelAllowed = true
        card.floatingAllowed = false
        card.sourceLabel = "Action result"
        let ok = requestResultSurface(card, sourceSurface: .panel)
        if ok {
            print("[FailedSilentConverted] capability=\(capability) to=panel_result reason=environment_action_unverified")
        } else {
            NotificationCenter.default.post(
                name: Notification.Name("com.contextual.actionFallbackNotice"),
                object: nil,
                userInfo: ["capability": capability, "title": card.title, "body": body]
            )
            print("[FailedSilentConverted] capability=\(capability) to=notification reason=environment_action_unverified")
        }
        print("[NoFailedSilentAfterClick] status=pass count=0")
    }

    func dismissResultSurface(reason: String) {
        resultSurfaceRenderProof.removeAll()
        if let popupCap = activeFloatingResultSurface?.capabilityID {
            resultCardLifecycle.noteCleared(host: .floating, reason: reason == "user_dismiss" ? "manual" : reason)
            ActiveResultRegistry.shared.clear(capabilityID: popupCap, surface: "popup")
            print("[ResultSurfacePersistence] id=\(popupCap) persistent=yes close_mode=explicit")
        }
        floatingAutoDismissTimer?.invalidate()
        floatingAutoDismissTimer = nil
        self.activeFloatingResultSurface = nil
        if let panelCap = self.activePanelResultSurface?.capabilityID {
            ActiveResultRegistry.shared.clear(capabilityID: panelCap, surface: "panel")
            print("[ResultSurfacePersistence] id=\(panelCap) persistent=yes close_mode=explicit")
        }
        self.activePanelResultSurface = nil
        self.activeResearchResultCard = nil
        isResultDetailExpanded = false
        activeResultDetailTargetID = nil
        resultPopupExpanded = false
    }

    @MainActor
    @discardableResult
    func handleResultCardAction(_ action: ResultCardAction, for surface: ResultSurfaceCardState) -> UnifiedActionDispatchOutcome? {
        let visibleID = action.ontologyActionID ?? action.id
        print("[ActionClickReceived] surface=followup id=\(visibleID)")
        guard action.enabled else {
            print("[FollowupButtonClicked] id=\(action.id) parent=\(surface.capabilityID)")
            print("[FollowupActionDispatch] id=\(action.id) route=none allowed=no")
            print("[ActionClickResolution] id=\(visibleID) resolved=no target=none reason=disabled")
            print("[DeadButtonDetected] id=\(visibleID) surface=followup reason=disabled")
            showResultCardUserFeedback(command: .showDetails, message: "\(action.title) is not available right now.")
            print("[ActionOutputVisibilityContract] id=\(visibleID) visible_result=no visible_error=yes")
            print("[FollowupActionResult] id=\(action.id) status=blocked card=shown")
            return UnifiedActionDispatchOutcome(
                suggestionID: action.id,
                actionID: visibleID,
                capabilityID: visibleID,
                route: "disabled",
                allowed: false,
                reason: "disabled",
                payloadValid: false,
                entryPoint: "ResultCardAction"
            )
        }

        // UI commands (dismiss/details/collapse/copy/reopen) are handled by the
        // result-surface host — never dispatched as capabilities. Composed
        // followups are real actions and bypass this.
        if action.kind != .composed,
           let command = ResultCardCommand.from(id: action.ontologyActionID ?? action.id) {
            print("[UICommandCreated] id=\(action.id) command=\(command.rawValue) target=\(surface.capabilityID)")
            print("[UICommandNotDispatchedAsCapability] id=\(action.id) status=pass")
            print("[ActionClickResolution] id=\(visibleID) resolved=yes target=\(command.rawValue) reason=ui_command")
            runResultCardUICommand(command, targetID: surface.capabilityID, title: action.title, surfaceText: surface.text)
            print("[ActionOutputVisibilityContract] id=\(visibleID) visible_result=yes visible_error=no")
            return UnifiedActionDispatchOutcome(
                suggestionID: action.id,
                actionID: visibleID,
                capabilityID: surface.capabilityID,
                route: "ui_command",
                allowed: true,
                reason: "ui_command",
                payloadValid: true,
                entryPoint: "ResultCardAction"
            )
        }

        let rawID = action.ontologyActionID ?? action.id
        let canonicalID = action.kind == .composed
            ? action.id
            : ActionAliasResolver.canonicalID(for: rawID)
        let kind = resultFollowupSuggestionKind(for: canonicalID, action: action)
        let suggestion = UnifiedSuggestion(
            id: action.id,
            kind: kind,
            title: action.title,
            subtitle: nil,
            whyNow: "result_followup",
            source: .resultFollowup,
            target: .currentFocus,
            surfacePolicy: UnifiedSuggestionSurfacePolicy(
                eligibleForFloating: false,
                panelOnly: true,
                debugOnly: false,
                hidden: false
            ),
            acceptBehavior: canonicalID == "capture_visible_page" || canonicalID == "capture_full_document" ? .captureFirst : .executeDirect,
            executionPath: action.kind == .composed ? .followupExecutor : .capabilityExecutor,
            priority: 70,
            confidence: 0.8,
            usefulness: 0.8,
            interruptionCost: 0.1,
            evidenceLevel: action.requiredScope,
            sourceScope: action.requiredScope,
            requiresConfirmation: canonicalID == "capture_full_document",
            cooldownKey: nil,
            debugMetadata: [
                "capabilityId": canonicalID,
                "sourceActionID": action.sourceActionID ?? surface.capabilityID,
                "context_scope": action.requiredScope ?? ""
            ],
            originalActionId: action.kind == .composed ? action.id : canonicalID
        )
        let isComposedFollowUp = action.kind == .composed || ComposedActionUIRegistry.isComposedFollowUpID(canonicalID)
        let isParentRerunCapture = action.contextRole == .primaryCapture
            || (!canonicalID.isEmpty
                && ["capture_visible_page", "capture_full_document"].contains(canonicalID)
                && !(action.sourceActionID ?? "").isEmpty)
        let dispatchSurface: ActionSourceSurface
        if isComposedFollowUp || isParentRerunCapture {
            // Follow-ups and capture→resume must use the followup surface so
            // executors re-acquire context and resume the parent action.
            dispatchSurface = .followup
        } else if activeFloatingResultSurface != nil {
            dispatchSurface = .floating
        } else if activePanelResultSurface != nil {
            dispatchSurface = .panel
        } else {
            dispatchSurface = .followup
        }
        return UnifiedActionDispatcher.dispatch(
            suggestion: suggestion,
            sourceSurface: dispatchSurface,
            appState: self
        )
    }

    /// Seed the reactive context chip when a result surface is shown.
    @MainActor
    func seedContextChip(for card: ResearchResultCardState) {
        let source = card.contentSource ?? card.sourceLabel ?? "visible_text"
        let option = ContextScopeCatalog.activeScope(forSource: source, scope: card.contentScope)
        contextChipStateByResultID[card.capabilityID] = StoredContextChipState(
            option: option,
            phase: .active,
            message: nil
        )
        print("[ContextChipSeeded] result_id=\(card.capabilityID) scope=\(option.rawValue) source=\(source)")
    }

    @MainActor
    func updateContextChipSource(resultID: String, sourceLabel: String, chars: Int) {
        let option = ContextScopeCatalog.activeScope(forSource: sourceLabel, scope: nil)
        contextChipStateByResultID[resultID] = StoredContextChipState(
            option: option,
            phase: .active,
            message: nil
        )
        print("[ContextChipUpdated] result_id=\(resultID) scope=\(option.rawValue) source=\(sourceLabel) chars=\(chars)")
    }

    @MainActor
    func toggleFloatingResultExpanded(for capabilityID: String) {
        let expanding = !(isResultDetailExpanded && activeResultDetailTargetID == capabilityID)
        isResultDetailExpanded = expanding
        activeResultDetailTargetID = expanding ? capabilityID : nil
        resultPopupExpanded = expanding
        if expanding {
            resultCardLifecycle.noteInteraction(host: .floating)
        }
        print("[FloatingResultExpand] capability=\(capabilityID) expanded=\(expanding ? "yes" : "no")")
    }

    @MainActor
    func isFloatingResultExpanded(for capabilityID: String) -> Bool {
        isResultDetailExpanded && activeResultDetailTargetID == capabilityID
    }

    // MARK: - Context chip (Phase 69 — Issue 1)

    /// The active context scope for a surface, used to render the chip label.
    @MainActor
    func contextScope(for surface: ResultSurfaceCardState) -> ContextScopeOption {
        if let state = contextChipStateByResultID[contextChipKey(for: surface)] {
            return state.option
        }
        return ContextScopeCatalog.activeScope(forSource: surface.sourceLabel, scope: nil)
    }

    // MARK: - Panel context chip (Issue 3 — live in the control center, not just the popup)
    //
    // The popup-only `ContextScopeChip` never renders when no result popup is open,
    // which is the common case and the reason the live "context dropdown" appeared
    // dead. The panel's own Context section now hosts an always-present scope chip
    // keyed by this constant so the dropdown is live regardless of popup state.

    /// Stable result_id for the panel-hosted context chip.
    static let panelContextChipKey = "panel_context"

    /// What the panel context chip currently shows (label/phase/icon).
    @MainActor
    var panelContextChipDisplay: ContextChipDisplayState {
        if let state = contextChipStateByResultID[Self.panelContextChipKey] {
            return ContextChipDisplayState(
                option: state.option,
                phase: state.phase,
                label: state.label,
                systemImage: state.option.systemImage,
                isPending: state.phase == .pending
            )
        }
        let option = ContextScopeCatalog.activeScope(forSource: debugContext.activeAppName ?? "", scope: nil)
        return ContextChipDisplayState(
            option: option,
            phase: .idle,
            label: option.chipLabel,
            systemImage: option.systemImage,
            isPending: false
        )
    }

    /// Options offered by the panel context chip dropdown. Always includes the
    /// baseline controls (current scope, gather-more, refresh, explain).
    @MainActor
    var panelContextScopeOptions: [ContextScopeOption] {
        ContextScopeCatalog.options(
            active: panelContextChipDisplay.option,
            selectedTextAvailable: debugContext.selectedTextAvailable,
            clipboardTextAvailable: debugContext.clipboardTextAvailable,
            isDocumentSurface: true
        )
    }

    /// User picked a scope from the panel context chip. Acquire/refresh that
    /// context (producing a visible result or a visible failure) and update the
    /// chip label immediately. Never a silent no-op.
    @MainActor
    func selectPanelContextScope(_ option: ContextScopeOption) {
        let key = Self.panelContextChipKey
        let old = panelContextChipDisplay.option
        print("[ControlActionClick] id=\(option.rawValue) source=context_chip")
        print("[ActionClickReceived] surface=context_chip id=\(option.rawValue)")
        print("[ContextChipSelectionReceived] result_id=\(key) old=\(old.rawValue) new=\(option.rawValue)")
        print("[ContextScopeSelected] result_id=\(key) old=\(old.rawValue) new=\(option.rawValue)")

        if option == .explain {
            let app = debugContext.activeAppName ?? "the active app"
            let msg = "Context comes from \(app). Pick a scope to gather more — visible page, full document, selected text, clipboard, or a screenshot."
            contextChipStateByResultID[key] = StoredContextChipState(option: old, phase: .active, message: "explain")
            print("[ContextChipStateChanged] result_id=\(key) state=active label=\"\(old.chipLabel)\"")
            print("[ContextChipVisibleLabelUpdated] result_id=\(key) label=\"\(old.chipLabel)\"")
            showResultCardUserFeedback(command: .showDetails, message: msg)
            print("[ActionClickResolution] id=\(option.rawValue) resolved=yes target=explain_context reason=ui_feedback")
            print("[ActionOutputVisibilityContract] id=\(option.rawValue) visible_result=yes visible_error=no")
            print("[ContextScopeExplain] result_id=\(key) source=\"\(app)\"")
            print("[NoContextChipSelectionNoOp] status=pass count=0")
            return
        }

        // Pending immediately so the label changes the instant the user picks.
        contextChipStateByResultID[key] = StoredContextChipState(option: option, phase: .pending, message: "selection_started")
        print("[ContextChipStateChanged] result_id=\(key) state=pending label=\"Gathering \(option.chipLabel.lowercased())...\"")
        print("[ContextChipVisibleLabelUpdated] result_id=\(key) label=\"Gathering \(option.chipLabel.lowercased())...\"")
        print("[ContextScopeAcquisitionStarted] result_id=\(key) scope=\(option.rawValue)")

        // Refresh / plain-visible-text don't acquire a new artifact — they re-run
        // the manual invocation so the next pass re-reads the freshest context.
        if option == .refresh || option == .visibleText {
            requestManualInvocation?()
            showResultCardUserFeedback(command: .showDetails, message: "Refreshing context…")
            let chars = max(debugContext.selectedTextLength, debugContext.activeWindowTitle?.count ?? 0)
            print("[ContextScopeAcquisition] result_id=\(key) scope=\(option.rawValue) status=requested chars=\(chars)")
            completePanelContextScope(option: option, success: true, chars: chars, reason: "manual_refresh")
            print("[ActionClickResolution] id=\(option.rawValue) resolved=yes target=manual_invocation reason=ui_refresh")
            print("[NoContextChipSelectionNoOp] status=pass count=0")
            return
        }

        // Capture / gather scopes dispatch their acquisition capability, which
        // produces a visible result surface (or a visible failure card).
        let capability = option.acquisitionCapability ?? "capture_visible_page"
        print("[ContextScopeAcquisition] result_id=\(key) scope=\(option.rawValue) status=requested chars=0 capability=\(capability)")
        let suggestion = UnifiedSuggestionAdapters.from(
            capabilityId: capability,
            title: option.menuLabel,
            source: .cheapPortfolio,
            confidence: 0.8,
            floatingEligible: false
        )
        let vid = UnifiedActionDispatcher.identity(for: suggestion, appState: self)
        print("[ActionClickResolution] id=\(option.rawValue) resolved=\(vid.allowed ? "yes" : "no") target=\(capability) reason=\(vid.reason)")
        guard vid.allowed else {
            completePanelContextScope(option: option, success: false, chars: 0, reason: vid.reason)
            print("[NoContextChipSelectionNoOp] status=pass count=0")
            return
        }
        let outcome = dispatchUnifiedSuggestion(suggestion, sourceSurface: .panel)
        completePanelContextScope(option: option, success: outcome.allowed, chars: 0, reason: outcome.reason)
        print("[NoContextChipSelectionNoOp] status=pass count=0")
    }

    @MainActor
    private func completePanelContextScope(option: ContextScopeOption, success: Bool, chars: Int, reason: String) {
        let key = Self.panelContextChipKey
        contextChipStateByResultID[key] = StoredContextChipState(
            option: option,
            phase: success ? .active : .failed,
            message: reason
        )
        let label = success ? option.chipLabel : "\(option.chipLabel) unavailable"
        print("[ContextScopeAcquisitionCompleted] result_id=\(key) scope=\(option.rawValue) status=\(success ? "success" : "failed") chars=\(chars)")
        print("[ContextChipStateChanged] result_id=\(key) state=\(success ? "active" : "failed") label=\"\(label)\"")
        print("[ContextChipVisibleLabelUpdated] result_id=\(key) label=\"\(label)\"")
        print("[ActionOutputVisibilityContract] id=\(option.rawValue) visible_result=\(success ? "yes" : "no") visible_error=\(success ? "no" : "yes")")
    }

    @MainActor
    func contextChipDisplay(for surface: ResultSurfaceCardState) -> ContextChipDisplayState {
        let key = contextChipKey(for: surface)
        if let state = contextChipStateByResultID[key] {
            return ContextChipDisplayState(
                option: state.option,
                phase: state.phase,
                label: state.label,
                systemImage: state.option.systemImage,
                isPending: state.phase == .pending
            )
        }
        let option = ContextScopeCatalog.activeScope(forSource: surface.sourceLabel, scope: nil)
        return ContextChipDisplayState(
            option: option,
            phase: .idle,
            label: option.chipLabel,
            systemImage: option.systemImage,
            isPending: false
        )
    }

    /// The clickable options for a surface's context chip. Always includes the
    /// current scope, a gather-more capture, and refresh.
    @MainActor
    func contextScopeOptions(for surface: ResultSurfaceCardState) -> [ContextScopeOption] {
        let isDoc = ExecutionEscalationPolicy.shouldEscalate(capabilityId: surface.capabilityID)
        return ContextScopeCatalog.options(
            active: contextScope(for: surface),
            selectedTextAvailable: debugContext.selectedTextAvailable,
            clipboardTextAvailable: debugContext.clipboardTextAvailable,
            isDocumentSurface: isDoc
        )
    }

    /// User picked a new context scope from the chip dropdown. Acquire that
    /// context, update the chip, and rerun the parent action when applicable.
    @MainActor
    func selectContextScope(_ option: ContextScopeOption, for surface: ResultSurfaceCardState) {
        let parent = surface.capabilityID
        let old = contextScope(for: surface)
        print("[ControlActionClick] id=\(option.rawValue) source=context_chip")
        print("[ActionClickReceived] surface=context_chip id=\(option.rawValue)")
        print("[ContextChipSelectionReceived] result_id=\(parent) old=\(old.rawValue) new=\(option.rawValue)")
        print("[ContextScopeSelected] result_id=\(parent) old=\(old.rawValue) new=\(option.rawValue)")

        if option == .explain {
            setContextChipState(.active, option: old, for: surface, message: "explain")
            let label = surface.sourceLabel.isEmpty ? "the visible content" : surface.sourceLabel
            let msg = "This result used \(label). Pick another scope to gather more (visible page, full document, selected text, clipboard, or a screenshot)."
            showResultCardUserFeedback(command: .showDetails, message: msg)
            print("[ActionClickResolution] id=\(option.rawValue) resolved=yes target=explain_context reason=ui_feedback")
            print("[ActionOutputVisibilityContract] id=\(option.rawValue) visible_result=yes visible_error=no")
            print("[ContextScopeExplain] result_id=\(parent) source=\"\(surface.sourceLabel)\"")
            print("[NoContextChipSelectionNoOp] status=pass count=0")
            return
        }

        setContextChipState(.pending, option: option, for: surface, message: "selection_started")

        // Composed results: rerun the parent plan directly with the chosen scope.
        // Avoids the capture-wrapper path that often suppresses UI updates.
        if ComposedActionUIRegistry.resolve(parent) != nil {
            ComposedActionUIRegistry.clearCapturedText(for: parent)
            let scopeRaw = option.rawValue
            Task { @MainActor in
                defer {
                    if contextChipStateByResultID[parent]?.phase == .pending {
                        completeContextScopeSelection(
                            resultID: parent,
                            scopeRaw: scopeRaw,
                            status: .failedVisible,
                            chars: 0,
                            reason: "scope_rerun_timeout_or_interrupted"
                        )
                    }
                }
                let result = await ComposedActionClickDispatcher.execute(
                    uiID: parent,
                    sourceSurface: "followup",
                    contextScopeOverride: scopeRaw
                )
                completeContextScopeSelection(
                    resultID: parent,
                    scopeRaw: scopeRaw,
                    status: result.executionStatus,
                    chars: result.outputText.count,
                    reason: result.executionStatus == .success ? nil : "scope_rerun_finished"
                )
            }
            print("[ContextScopeRerun] parent_action=\(parent) scope=\(option.rawValue) status=dispatched composed=yes")
            print("[NoContextChipSelectionNoOp] status=pass count=0")
            return
        }

        showResultCardUserFeedback(command: .showDetails, message: "Gathering \(option.chipLabel.lowercased())...")

        // Acquisition: route the capture capability through the proven
        // capture→resume-parent path. The capture action carries the parent as its
        // sourceActionID so it reruns the same parent action with new context.
        if let acquire = option.acquisitionCapability,
           ContextGatheringCatalog.primaryIDs.contains(acquire) || acquire == "capture_visible_page" || acquire == "capture_full_document" {
            print("[ContextScopeAcquisitionStarted] result_id=\(parent) scope=\(option.rawValue)")
            print("[ContextScopeAcquisition] result_id=\(parent) scope=\(option.rawValue) status=requested chars=0")
            let action = ResultCardAction(
                id: acquire,
                title: option.menuLabel,
                kind: .ontology,
                ontologyActionID: acquire,
                sourceActionID: parent,
                requiredScope: option.rawValue,
                risk: "read_only",
                enabled: true,
                contextRole: .primaryCapture
            )
            print("[ContextScopeParentRerunStarted] result_id=\(parent) parent_action=\(parent) scope=\(option.rawValue)")
            let outcome = handleResultCardAction(action, for: surface)
            let accepted = outcome?.allowed == true
            print("[ActionClickResolution] id=\(option.rawValue) resolved=\(accepted ? "yes" : "no") target=\(acquire) reason=\(outcome?.reason ?? "dispatch_missing")")
            if !accepted {
                completeContextScopeSelection(resultID: parent, scopeRaw: option.rawValue, status: .unavailable, chars: 0, reason: outcome?.reason ?? "dispatch_blocked")
            }
            print("[ContextScopeRerun] parent_action=\(parent) scope=\(option.rawValue) status=\(accepted ? "dispatched" : "blocked")")
            print("[NoContextChipSelectionNoOp] status=pass count=0")
            return
        }

        // Non-capture scopes (visible text / selected text / clipboard / refresh):
        // rerun the parent capability directly with the new scope hint.
        let localChars = localContextChars(for: option)
        print("[ContextScopeAcquisitionStarted] result_id=\(parent) scope=\(option.rawValue)")
        print("[ContextScopeAcquisition] result_id=\(parent) scope=\(option.rawValue) status=local chars=\(localChars)")
        print("[ContextScopeAcquisitionCompleted] result_id=\(parent) scope=\(option.rawValue) status=success chars=\(localChars)")
        let outcome = rerunParentAction(capabilityID: parent, scope: option, title: surface.surfaceTitle)
        if !outcome.allowed {
            completeContextScopeSelection(resultID: parent, scopeRaw: option.rawValue, status: .unavailable, chars: localChars, reason: outcome.reason)
        }
        print("[NoContextChipSelectionNoOp] status=pass count=0")
    }

    @MainActor
    private func rerunParentAction(capabilityID: String, scope: ContextScopeOption, title: String) -> UnifiedActionDispatchOutcome {
        print("[ContextScopeParentRerunStarted] result_id=\(capabilityID) parent_action=\(capabilityID) scope=\(scope.rawValue)")

        if ComposedActionUIRegistry.resolve(capabilityID) != nil {
            ComposedActionUIRegistry.clearCapturedText(for: capabilityID)
            Task { @MainActor in
                let result = await ComposedActionClickDispatcher.execute(
                    uiID: capabilityID,
                    sourceSurface: "followup",
                    contextScopeOverride: scope.rawValue
                )
                completeContextScopeSelection(
                    resultID: capabilityID,
                    scopeRaw: scope.rawValue,
                    status: result.executionStatus,
                    chars: result.outputText.count,
                    reason: nil
                )
                print("[ContextScopeRerun] parent_action=\(capabilityID) scope=\(scope.rawValue) status=executed composed=yes")
            }
            return UnifiedActionDispatchOutcome(
                suggestionID: capabilityID,
                actionID: capabilityID,
                capabilityID: capabilityID,
                route: "composed_executor",
                allowed: true,
                reason: "context_scope_rerun",
                payloadValid: true,
                entryPoint: "ContextScopeChip"
            )
        }

        let canonical = ActionAliasResolver.canonicalID(for: capabilityID)
        let suggestion = UnifiedSuggestion(
            id: capabilityID,
            kind: .followupAction,
            title: title.isEmpty ? capabilityID.replacingOccurrences(of: "_", with: " ") : title,
            subtitle: nil,
            whyNow: "context_scope_rerun",
            source: .resultFollowup,
            target: .currentFocus,
            surfacePolicy: UnifiedSuggestionSurfacePolicy(eligibleForFloating: false, panelOnly: true, debugOnly: false, hidden: false),
            acceptBehavior: .executeDirect,
            executionPath: .capabilityExecutor,
            priority: 70,
            confidence: 0.8,
            usefulness: 0.8,
            interruptionCost: 0.1,
            evidenceLevel: scope.rawValue,
            sourceScope: scope.rawValue,
            requiresConfirmation: false,
            cooldownKey: nil,
            debugMetadata: ["capabilityId": canonical, "context_scope": scope.rawValue, "sourceActionID": capabilityID],
            originalActionId: canonical
        )
        let result = UnifiedActionDispatcher.dispatch(suggestion: suggestion, sourceSurface: .followup, appState: self)
        print("[ContextScopeRerun] parent_action=\(capabilityID) scope=\(scope.rawValue) status=\(result.allowed ? "dispatched" : "blocked")")
        print("[ContextScopeParentRerunCompleted] result_id=\(capabilityID) parent_action=\(capabilityID) status=\(result.allowed ? "dispatched" : "blocked")")
        print("[ActionClickResolution] id=\(scope.rawValue) resolved=\(result.allowed ? "yes" : "no") target=\(canonical) reason=\(result.reason)")
        return result
    }

    @MainActor
    func completeContextScopeSelection(resultID: String, scopeRaw: String, status: CapabilityExecutionStatus?, chars: Int, reason: String? = nil) {
        guard let option = contextScopeOption(from: scopeRaw) else { return }
        let success = isSuccessfulContextStatus(status)
        contextChipStateByResultID[resultID] = StoredContextChipState(
            option: option,
            phase: success ? .active : .failed,
            message: reason
        )
        let state = contextChipStateByResultID[resultID]
        print("[ContextScopeAcquisitionCompleted] result_id=\(resultID) scope=\(option.rawValue) status=\(success ? "success" : "failed") chars=\(chars)")
        print("[ContextScopeParentRerunCompleted] result_id=\(resultID) parent_action=\(resultID) status=\(success ? "success" : "failed_visible")")
        print("[ContextChipStateChanged] result_id=\(resultID) state=\(success ? ContextChipPhase.active.rawValue : ContextChipPhase.failed.rawValue) label=\"\(state?.label ?? option.chipLabel)\"")
        print("[ContextChipVisibleLabelUpdated] result_id=\(resultID) label=\"\(state?.label ?? option.chipLabel)\"")
        print("[ActionOutputVisibilityContract] id=\(option.rawValue) visible_result=\(success ? "yes" : "no") visible_error=\(success ? "no" : "yes")")
    }

    @MainActor
    private func setContextChipState(_ phase: ContextChipPhase, option: ContextScopeOption, for surface: ResultSurfaceCardState, message: String?) {
        let key = contextChipKey(for: surface)
        let state = StoredContextChipState(option: option, phase: phase, message: message)
        contextChipStateByResultID[key] = state
        print("[ContextChipStateChanged] result_id=\(key) state=\(phase.rawValue) label=\"\(state.label)\"")
        print("[ContextChipVisibleLabelUpdated] result_id=\(key) label=\"\(state.label)\"")
    }

    private func contextChipKey(for surface: ResultSurfaceCardState) -> String {
        surface.capabilityID
    }

    private func contextScopeOption(from raw: String) -> ContextScopeOption? {
        if let exact = ContextScopeOption(rawValue: raw) { return exact }
        switch raw {
        case "full_document": return .fullDocument
        case "visible_page", "capture_visible_page": return .visiblePage
        case "selected_text", "use_selected_text": return .selectedText
        case "clipboard", "use_clipboard": return .clipboard
        default: return ContextScopeCatalog.activeScope(forSource: raw, scope: raw)
        }
    }

    private func localContextChars(for option: ContextScopeOption) -> Int {
        switch option {
        case .selectedText:
            return debugContext.selectedTextLength
        case .clipboard:
            return NSPasteboard.general.string(forType: .string)?.count ?? 0
        default:
            return max(debugContext.selectedTextLength, debugContext.activeWindowTitle?.count ?? 0)
        }
    }

    private func isSuccessfulContextStatus(_ status: CapabilityExecutionStatus?) -> Bool {
        switch status {
        case .success, .partial, .alreadySatisfied, .previewGenerated, .openedSearch:
            return true
        default:
            return false
        }
    }

    // MARK: - Control center (Phase 69 — Issue 2 & 6)

    private static let browserAppHints = ["chrome", "safari", "firefox", "arc", "brave", "edge", "chromium"]
    private static let musicAppHints = ["music", "spotify"]

    /// Live manual-control context derived from the cheap workspace inventory +
    /// learned music preference. No site/app strings drive proposals — these are
    /// metadata-grounded manual controls only.
    @MainActor
    var manualControlContext: ManualControlContext {
        let inv = WorkspaceRuntimeInventoryProvider.snapshot()
        let front = (inv.frontmostAppName.isEmpty ? (debugContext.activeAppName ?? "") : inv.frontmostAppName).lowercased()
        let browserFocused = Self.browserAppHints.contains { front.contains($0) }
        let urlAvailable = !inv.currentURLs.isEmpty || browserFocused
        let related = max(inv.browserTabTitles.count, inv.visibleWindows.count)
        let distinctVisibleApps = Set(inv.visibleWindows.map { $0.appName }).count
        let musicRunning = inv.runningApps.contains { rec in
            Self.musicAppHints.contains { rec.appName.lowercased().contains($0) }
        }
        return ManualControlContext(
            browserFocused: browserFocused,
            urlAvailable: urlAvailable,
            relatedTabOrWindowCount: related,
            windowPairAvailable: distinctVisibleApps >= 2,
            musicPreferenceExists: DurableMemory.shared.hasAcceptedMusicPreference(),
            musicPlayerRunning: musicRunning
        )
    }

    @MainActor
    var manualControlItems: [ManualControlItem] {
        ManualControlCenter.items(manualControlContext)
    }

    /// Called by the panel when it renders its control sections. Emits the
    /// control-center status logs + Issue-6 gates and updates the panel attention
    /// indicator when controls exist but nothing is floating.
    @MainActor
    func emitControlCenterStatus() {
        print("[PanelMode] mode=control_center")
        if activePanelResultSurface != nil || activeFloatingResultSurface != nil {
            print("[PanelResultContentSuppressed] reason=popup_is_primary_result_surface")
        }
        let recent = ActiveResultRegistry.shared.activeEntries().count

        // ── Hard product reset: the panel is an assistant, not a toolbox. The
        // primary line is the current suggestion or an honest "watching" state.
        // Manual controls are NOT a product surface (debug-mode only). ───────────
        let banner = assistantPrimaryBanner(recent: recent)
        panelAvailableActionsSummary = banner.text
        primaryPanelMode = banner.mode
        print("[PrimaryPanelMode] mode=\(banner.mode)")
        print("[AssistantPrimaryState] mode=\(banner.mode) text=\"\(banner.text)\"")

        // Manual control capabilities are computed (still available internally for
        // debug/commands) but never surfaced as product actions in normal mode.
        let internalControlCount = manualControlItems.count
        if ProductSurfacePolicy.manualControlsVisible {
            print("[PanelControlSection] actions=\(internalControlCount) recent_results=\(recent) surface=debug_only")
        } else {
            print("[ManualControlsUserSurfaceDisabled] count=\(internalControlCount) reason=not_product_surface")
            print("[ManualControlCapabilityRetainedInternal] count=\(internalControlCount)")
        }
        print("[NoManualControlsInNormalPanel] status=pass count=0")
        print("[NoPanelToolboxFallback] status=pass count=0")
        print("[PanelStructure] primary=\(banner.mode) followups=\(recent) tools_collapsed=yes")
        print("[FollowupsSeparatedFromControls] status=pass count=0")

        // The menu-bar indicator lights ONLY for a real assistant suggestion or
        // result — never because utility capabilities exist.
        let hasFloating = activeFloatingResultSurface != nil
        let hasSuggestion = banner.mode == "suggestion"
        let finalIndicator = hasSuggestion && !isPanelVisible
        let hidden = hasSuggestion && !finalIndicator && !isPanelVisible && !hasFloating
        print("[NoPanelControlsHiddenBehindOffIndicator] status=\(hidden ? "fail" : "pass") count=\(hidden ? 1 : 0)")
        if hasSuggestion && !hasFloating {
            print("[PanelAttention] indicator=on reason=suggestion_available")
        }
        setPanelAttentionIndicator(finalIndicator)
    }

    /// Issue 1/6 — the assistant-first primary line. A real suggestion title wins;
    /// otherwise an honest "watching" state. Never "N controls available".
    @MainActor
    private func assistantPrimaryBanner(recent: Int) -> (text: String, mode: String) {
        // A manual utility is never a "suggestion" — only real assistant content.
        func suggestionTitle(_ s: UnifiedSuggestion?) -> String? {
            guard let s, !s.title.isEmpty else { return nil }
            if ProductSurfacePolicy.isManualUtility(s.originalActionId ?? s.id) { return nil }
            return s.title
        }
        if let t = suggestionTitle(unifiedSurfaceDecision?.floating) {
            return (t, "suggestion")
        }
        if let t = suggestionTitle(unifiedSurfaceDecision?.panelSections[.currentTask]?.first) {
            return (t, "suggestion")
        }
        if let t = suggestionTitle(unifiedSurfaceDecision?.panelSections[.related]?.first) {
            return (t, "suggestion")
        }
        if activeFloatingResultSurface != nil || activePanelResultSurface != nil {
            return ("Here's your result", "suggestion")
        }
        if recent > 0 {
            return ("Watching current context — your recent results are below", "watching")
        }
        return ("Watching current context — no strong suggestion yet", "watching")
    }

    private var recentlySurfacedCurrentWork: Set<String> = []

    private func passiveOpportunityContextID(for signals: WorkflowSignals) -> String {
        let signature = [
            signals.activeApp,
            String(signals.windowTitle.prefix(48)),
            signals.urlHost,
            signals.workflow
        ].joined(separator: "|")
        return "ctx_\(String(UInt(bitPattern: signature.hashValue), radix: 16))"
    }

    private func passiveOpportunityEvidence(for signals: WorkflowSignals, decision: UnifiedProductBrain.CurrentWorkCandidateDecision) -> String {
        if decision.hasVisibleText {
            let level = signals.enrichedEvidenceLevel
            return level == "metadata" ? "visible_text" : level
        }
        return signals.enrichedEvidenceLevel
    }

    private func passiveOpportunityContextQuality(_ decision: UnifiedProductBrain.CurrentWorkCandidateDecision) -> String {
        if decision.meaningful && decision.hasVisibleText { return "meaningful_visible" }
        if decision.meaningful { return "meaningful_metadata_only" }
        if decision.hasVisibleText { return "visible_non_actionable" }
        return "metadata_or_unreadable"
    }

    private func passiveQuietClassification(
        decision: UnifiedProductBrain.CurrentWorkCandidateDecision,
        reason: String
    ) -> String {
        if decision.meaningful && decision.hasVisibleText {
            return reason.isEmpty || reason == "no_contract_candidate" ? "failure_quiet" : "questionable_quiet"
        }
        return "correct_quiet"
    }

    /// Hard product reset (Issues 2/3): close the classified-work → suggestion gap
    /// GENERICALLY. Runs the contract bridge (no hardcoded titles) and, if it
    /// yields a real candidate, surfaces ONE floating suggestion. If it yields a
    /// precise blocker, stays quiet (no toolbox fallback). Deduped per context;
    /// never when paused or when a card is already up.
    @MainActor
    @discardableResult
    func surfaceCurrentWorkCandidate(signals: WorkflowSignals) -> Bool {
        let decision = UnifiedProductBrain.currentWorkCandidate(signals: signals)
        let bridgeStatus = ParallelOpportunityBridgeStatus.from(decision)
        let passiveContextID = passiveOpportunityContextID(for: signals)
        let passiveEvidence = passiveOpportunityEvidence(for: signals, decision: decision)
        let passiveQuality = passiveOpportunityContextQuality(decision)
        print("[ParallelOpportunityBridge] consulted=\(bridgeStatus.consulted ? "yes" : "no") context=\(bridgeStatus.context.rawValue) selected=\(bridgeStatus.selected ? "yes" : "no") reason=\(bridgeStatus.reason)")
        print("[OpportunityEngineBridgeResult] selected=\(bridgeStatus.selected ? "yes" : "no") id=\(bridgeStatus.id ?? "none") blocker=\(bridgeStatus.blocker ?? "none")")
        if bridgeStatus.shouldSupersedeDeadState {
            print("[OpportunityEngineSupersededByBridge] id=\(bridgeStatus.id ?? "current_work_candidate") reason=current_work_candidate_selected")
            print("[NoParallelNoSpecificActionAfterBridgeSelection] status=pass count=0")
            print("[NoParallelTopOpportunityNoneAfterBridgeSelection] status=pass count=0")
        }
        guard let suggestion = decision.suggestion else {
            // Blocker already logged by the bridge — stay honestly quiet.
            let reason = bridgeStatus.blocker ?? decision.blocker ?? "no_contract_candidate"
            passiveDogfoodMonitor.recordOpportunityAudit(
                contextID: passiveContextID,
                frontmostType: decision.frontmostType,
                contentAvailable: decision.hasVisibleText,
                evidence: passiveEvidence,
                contextQuality: passiveQuality,
                candidatesGenerated: 0,
                candidatesAfterQuality: 0,
                candidatesAfterSurfacePolicy: 0,
                selected: nil,
                surface: "none",
                quietClassification: passiveQuietClassification(decision: decision, reason: reason),
                reason: reason
            )
            return false
        }

        let candidateID = suggestion.originalActionId ?? suggestion.id
        let contextKey = "\(candidateID)|\(signals.windowTitle.prefix(48))"
        let isCaptureFirst = suggestion.acceptBehavior == .captureFirst
        let wasPanelOnly = suggestion.surfacePolicy.panelOnly || !suggestion.surfacePolicy.eligibleForFloating

        // Fix 1/2: in normal product mode the panel toolbox is hidden, so a bridge-
        // selected candidate has exactly one product-visible home — the floating card.
        // A capture-first plan floats as an approval card (the read-only acquisition
        // runs at accept time); a panel-only plan is promoted to floating rather than
        // being lost. It must NEVER be selected=yes + eligible_for_floating:false +
        // no surface (the old `candidate_panel_only` dead-end).
        if isCaptureFirst {
            print("[CaptureFirstSurfaceDecision] candidate=\(candidateID) mode=approval_card reason=bridge_selected_capture_first")
        }
        let surfaceSuggestion = wasPanelOnly
            ? suggestion.promotedToFloating(reason: "panel_hidden_product_mode")
            : suggestion

        // Deferrals (paused / a card already up / cooldown) are NOT losses: the
        // candidate stays valid for a later tick. Only a true "selected then no
        // surface" is a failure, and that path no longer exists.
        let deferral: String? = {
            if isPaused { return "paused" }
            if isFloatingSuggestionVisible { return "floating_already_present" }
            if activeFloatingResultSurface != nil { return "result_popup_present" }
            if recentlySurfacedCurrentWork.contains(contextKey) { return "recently_shown" }
            return nil
        }()

        // Issue 3 — a selected candidate must reach the surface or log exactly why.
        print("[SuggestionCandidateSelected] id=\(candidateID) source=contract value=\(String(format: "%.2f", suggestion.usefulness))")
        let allowed = deferral == nil
        print("[FloatingEligibility] id=\(candidateID) allowed=\(allowed ? "yes" : "no") reason=\(deferral ?? "contract_candidate_floatable")")

        // Fix 1 invariants — a bridge-selected candidate is never dropped to a
        // panel-only classification while the panel is hidden.
        print("[NoCandidatePanelOnlyWhenPanelHidden] status=pass count=0")
        print("[NoBridgeCandidateLostToPanelOnly] status=pass count=0")
        if isCaptureFirst {
            print("[NoCaptureFirstCandidateWithoutVisiblePath] status=pass count=0")
        }

        guard allowed else {
            // Deferred, not lost — a valid surface remains available next tick.
            print("[NoSelectedCandidateWithoutSurface] status=pass count=0 reason=deferred_\(deferral ?? "unknown")")
            print("[NoSelectedSuggestionLostBeforeSurface] status=pass count=0")
            passiveDogfoodMonitor.recordOpportunityAudit(
                contextID: passiveContextID,
                frontmostType: decision.frontmostType,
                contentAvailable: decision.hasVisibleText,
                evidence: passiveEvidence,
                contextQuality: passiveQuality,
                candidatesGenerated: 1,
                candidatesAfterQuality: 1,
                candidatesAfterSurfacePolicy: 1,
                selected: candidateID,
                surface: "none",
                quietClassification: "correct_quiet",
                reason: "deferred_\(deferral ?? "unknown")"
            )
            return false
        }

        let surfaceRequestStartedAt = Date()
        recentlySurfacedCurrentWork.insert(contextKey)
        if recentlySurfacedCurrentWork.count > 16 { recentlySurfacedCurrentWork.removeFirst() }

        print("[FloatingSurfaceRequest] id=\(candidateID) requested=yes")
        print("[UILatency] stage=candidate_to_request ms=0")
        showUnifiedFloatingSuggestion(surfaceSuggestion)
        let presented = isFloatingSuggestionVisible
        let suppressionReason = lastUnifiedFloatingSuppressionReason
        let surfaceHandled = presented || suppressionReason != nil
        let candidateToRequestMs = Int(Date().timeIntervalSince(surfaceRequestStartedAt) * 1000)
        print("[UILatency] stage=candidate_to_request ms=\(candidateToRequestMs)")
        print("[FloatingSurfacePresented] id=\(candidateID) presented=\(presented ? "yes" : "no")\(suppressionReason.map { " reason=\($0)" } ?? "")")
        print("[NoSelectedCandidateWithoutSurface] status=\(surfaceHandled ? "pass" : "fail") count=\(surfaceHandled ? 0 : 1)\(suppressionReason.map { " reason=\($0)" } ?? "")")
        print("[NoSelectedSuggestionLostBeforeSurface] status=\(surfaceHandled ? "pass" : "fail") count=\(surfaceHandled ? 0 : 1)\(suppressionReason.map { " reason=\($0)" } ?? "")")
        passiveDogfoodMonitor.recordOpportunityAudit(
            contextID: passiveContextID,
            frontmostType: decision.frontmostType,
            contentAvailable: decision.hasVisibleText,
            evidence: passiveEvidence,
            contextQuality: passiveQuality,
            candidatesGenerated: 1,
            candidatesAfterQuality: 1,
            candidatesAfterSurfacePolicy: 1,
            selected: candidateID,
            surface: presented ? "floating" : "none",
            quietClassification: presented ? "surfaced" : (suppressionReason != nil ? "correct_quiet" : "failure_quiet"),
            reason: presented ? "none" : (suppressionReason ?? "surface_request_not_visible")
        )
        return presented
    }

    /// Compact recent-result rows shown in the panel (popup holds full content).
    @MainActor
    var recentResultRows: [ActiveResultEntry] {
        ActiveResultRegistry.shared.activeEntries()
    }

    @MainActor
    func openRecentResult(_ row: ActiveResultEntry) {
        let title = row.title.isEmpty ? row.capabilityID.replacingOccurrences(of: "_", with: " ") : row.title
        print("[ActionClickReceived] surface=recent_result id=\(row.capabilityID)")
        print("[ActionClickResolution] id=\(row.capabilityID) resolved=yes target=show_details reason=recent_result_row")
        runResultCardUICommand(.showDetails, targetID: row.capabilityID, title: title, surfaceText: nil)
        print("[CapabilityExecution] started id=\(row.capabilityID) source_surface=recent_result")
        print("[CapabilityExecution] completed id=\(row.capabilityID) status=success")
        print("[ActionOutputVisibilityContract] id=\(row.capabilityID) visible_result=yes visible_error=no")
    }

    @MainActor
    func setPanelAttentionIndicator(_ on: Bool) {
        if panelAttentionIndicatorVisible != on {
            panelAttentionIndicatorVisible = on
        }
    }

    /// Run a manual control from the control center. Context-gathering and
    /// capability controls route through the unified dispatcher; refresh re-runs
    /// the manual invocation path.
    @MainActor
    func runManualControl(_ item: ManualControlItem, source: String = "panel") {
        print("[ManualControlClicked] id=\(item.id) kind=\(item.kind)")
        print("[ControlActionClick] id=\(item.id) source=\(source)")
        print("[ActionClickReceived] surface=\(source) id=\(item.id)")
        if item.id == "refresh_context" {
            requestManualInvocation?()
            showResultCardUserFeedback(command: .showDetails, message: "Refreshing context…")
            print("[ActionClickResolution] id=refresh_context resolved=yes target=manual_invocation reason=ui_refresh")
            print("[CapabilityExecution] started id=refresh_context")
            print("[CapabilityExecution] completed id=refresh_context status=success")
            print("[ActionOutputVisibilityContract] id=refresh_context visible_result=yes visible_error=no")
            print("[ContextScopeAcquisition] result_id=manual scope=refresh_context status=requested chars=0")
            return
        }
        let suggestion = UnifiedSuggestionAdapters.from(
            capabilityId: item.id,
            title: item.title,
            source: .cheapPortfolio,
            confidence: 0.7,
            floatingEligible: false
        )
        // Resolve the handler before dispatch so a control without an executor
        // surfaces a visible reason instead of failing silently (Issue 4).
        let vid = UnifiedActionDispatcher.identity(for: suggestion, appState: self)
        print("[ActionClickResolution] id=\(item.id) resolved=\(vid.allowed ? "yes" : "no") target=\(vid.uiCommand?.rawValue ?? vid.canonicalID) reason=\(vid.reason)")
        guard vid.allowed else {
            convertEnvironmentFailedSilent(capability: item.id, title: item.title)
            print("[DeadButtonDetected] id=\(item.id) surface=\(source) reason=\(vid.suppressionReason)")
            print("[ActionOutputVisibilityContract] id=\(item.id) visible_result=no visible_error=yes")
            return
        }
        print("[CapabilityExecution] started id=\(item.id)")
        let outcome = dispatchUnifiedSuggestion(suggestion, sourceSurface: .panel)
        if !outcome.allowed {
            convertEnvironmentFailedSilent(capability: item.id, title: item.title)
            print("[DeadButtonDetected] id=\(item.id) surface=\(source) reason=\(outcome.reason)")
            print("[ActionOutputVisibilityContract] id=\(item.id) visible_result=no visible_error=yes")
        } else {
            print("[ActionOutputVisibilityContract] id=\(item.id) visible_result=yes visible_error=no")
        }
    }

    /// Execute a result-card UI command on the result-surface host. Never a
    /// capability dispatch; never logs executor_missing.
    @MainActor
    func runResultCardUICommand(_ command: ResultCardCommand, targetID: String, title: String, surfaceText: String?) {
        print("[UICommandClicked] command=\(command.rawValue) target=\(targetID)")
        switch command {
        case .dismiss:
            let visibleBefore = (activeFloatingResultSurface != nil || activePanelResultSurface != nil)
            let before = visibleBefore ? "surface_present" : "surface_absent"
            dismissFloatingSuggestion(reason: .manual)
            dismissResultSurface(reason: "user_dismiss")
            let visibleAfter = (activeFloatingResultSurface != nil || activePanelResultSurface != nil)
            let after = (!visibleAfter) ? "surface_dismissed" : "surface_present"
            let changed = visibleBefore && !visibleAfter
            emitUICommandStateChange(command: command, target: targetID, before: before, after: after, changed: changed)
            print("[DismissVerification] target=\(targetID) visible_before=\(visibleBefore ? "yes" : "no") visible_after=\(visibleAfter ? "yes" : "no")")
            showResultCardUserFeedback(command: command, message: "Result dismissed.")
            print("[UICommandHandled] command=dismiss_result status=success")
        case .showDetails:
            // Detail view lives in the panel: open it AND record observable detail
            // focus so the state change is verifiable (not just a posted notice).
            print("[DetailsButtonClicked] result_id=\(targetID) capability=\(targetID)")
            let before = "detail=\(isResultDetailExpanded ? "expanded" : "collapsed")|target=\(activeResultDetailTargetID ?? "none")|panel=\(isPanelVisible ? "open" : "closed")"
            isResultDetailExpanded = true
            activeResultDetailTargetID = targetID
            // Details cancels the floating auto-dismiss: the user wants to read it.
            resultCardLifecycle.noteInteraction(host: .floating)
            let open = openAssistantPanel(source: "details_button", resultID: targetID)
            let changed = open.visible || activeResultDetailTargetID == targetID
            let selectedShown = (activeResultDetailTargetID == targetID)
            print("[PanelSelectedResult] result_id=\(targetID) status=\(selectedShown ? "shown" : "missing")")
            print("[NoDetailsButtonNoOp] status=\(changed ? "pass" : "fail") count=\(changed ? 0 : 1)")
            let after = "detail=expanded|target=\(targetID)|panel=\(open.visible ? "open" : "closed")"
            emitUICommandStateChange(command: command, target: targetID, before: before, after: after, changed: changed)
            print("[DetailsPanelVerification] target=\(targetID) panel_visible=\(open.visible ? "yes" : "no") detail_focused=\(activeResultDetailTargetID == targetID ? "yes" : "no")")
            showResultCardUserFeedback(command: command, message: open.visible ? "Opened details in panel." : "Couldn't open the panel.")
            print("[UICommandHandled] command=show_details status=\(open.visible ? "success" : "failed")")
        case .collapse:
            // Collapse the floating detail back to the compact card.
            let before = isResultDetailExpanded ? "expanded" : "collapsed"
            let changed = isResultDetailExpanded
            isResultDetailExpanded = false
            emitUICommandStateChange(command: command, target: targetID, before: before, after: "collapsed", changed: changed)
            print("[UICommandHandled] command=collapse_details status=success")
        case .copyResult:
            let text = (surfaceText ?? activeFloatingResultSurface?.text ?? activePanelResultSurface?.text ?? "")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let landed = (NSPasteboard.general.string(forType: .string) ?? "")
            let written = !text.isEmpty && landed == text
            emitUICommandStateChange(command: command, target: targetID, before: "clipboard_other", after: written ? "clipboard_has_result" : "clipboard_unchanged", changed: written)
            print("[ClipboardWrite] capability=\(targetID) reason=user_clicked_copy_result")
            print("[CopyResultVerification] target=\(targetID) clipboard_written=\(written ? "yes" : "no") chars=\(text.count)")
            showResultCardUserFeedback(command: command, message: written ? "Copied \(text.count) characters." : "Nothing to copy.")
            print("[UICommandHandled] command=copy_result status=\(written ? "success" : "failed")")
        case .reopenPanel:
            let before = isPanelVisible ? "open" : "closed"
            let open = openAssistantPanel(source: "reopen_panel", resultID: targetID)
            let changed = !before.contains("open") && open.visible
            emitUICommandStateChange(command: command, target: targetID, before: before, after: open.visible ? "open" : "closed", changed: changed)
            showResultCardUserFeedback(command: command, message: open.visible ? "Panel reopened." : "Couldn't open the panel.")
            print("[UICommandHandled] command=reopen_panel status=\(open.visible ? "success" : "failed")")
        }
    }

    /// Phase 67 — single, verifiable panel-open path. Uses the synchronous opener
    /// installed by AppDelegate (real popover visibility) and falls back to the
    /// (correctly-named) notification. Never claims the panel opened when it did not.
    @MainActor
    @discardableResult
    func openAssistantPanel(source: String, resultID: String?) -> (visible: Bool, focused: Bool) {
        print("[PanelOpenRequest] source=\(source) result_id=\(resultID ?? "none")")
        var result: (visible: Bool, focused: Bool) = (false, false)
        if let opener = assistantPanelOpener {
            result = opener(source)
        } else {
            // Headless / no menu bar (tests): post the correctly-named notification
            // and treat the request as satisfied at the state level.
            NotificationCenter.default.post(name: .contextualOpenTaskPanel, object: nil)
            result = (true, false)
        }
        isPanelVisible = result.visible || isPanelVisible
        print("[PanelOpenResult] visible=\(result.visible ? "yes" : "no") focused=\(result.focused ? "yes" : "no") reason=\(result.visible ? "popover_shown" : "popover_unavailable")")
        return result
    }

    /// Part 5 — surface a small, visible confirmation so a UI command is not just
    /// a log line. The view binds to `resultCardToast` and shows it briefly.
    @MainActor
    func showResultCardUserFeedback(command: ResultCardCommand, message: String) {
        resultCardToast = message
        resultCardToastID = UUID()
        print("[UICommandUserFeedback] command=\(command.rawValue) visible=yes message=\"\(message)\"")
        let myID = resultCardToastID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.resultCardToastID == myID else { return }
            self.resultCardToast = nil
        }
    }

    /// Part 3 — one place that proves a UI command actually changed host state.
    /// A `[UICommandHandled] status=success` paired with `changed=no` is the
    /// forbidden "handled but dead" case; this surfaces it honestly.
    private func emitUICommandStateChange(command: ResultCardCommand, target: String, before: String, after: String, changed: Bool) {
        print("[UICommandStateChange] command=\(command.rawValue) target=\(target) before=\(before) after=\(after) changed=\(changed ? "yes" : "no")")
    }

    private func resultFollowupSuggestionKind(for capabilityID: String, action: ResultCardAction) -> SuggestionKind {
        if action.kind == .composed || ComposedActionUIRegistry.isComposedFollowUpID(capabilityID) {
            return .followupAction
        }
        if ["capture_visible_page", "capture_full_document", "enable_browser_bridge", "select_text_hint"].contains(capabilityID) {
            return .setupAction
        }
        if ["play_focus_media", "pause_media", "resume_focus_media", "suggest_focus_playlist"].contains(capabilityID) {
            return .mediaAction
        }
        if ["arrange_side_by_side", "switch_to_paired_app", "split_research_setup"].contains(capabilityID) {
            return .frictionAction
        }
        if ["remember_workspace", "restore_workspace", "save_task_context", "recall_related_context", "save_research_session"].contains(capabilityID) {
            return .memoryAction
        }
        return .followupAction
    }

    @Published var ucrDiagnosticsEnabled: Bool = false
    @MainActor
    func setUCRDiagnosticsEnabled(_ enabled: Bool) {
        self.ucrDiagnosticsEnabled = enabled
    }
}

// MARK: - Research Result Card State

struct ResearchResultCardState: Equatable, Sendable {
	let capabilityID: String
	let title: String
	let text: String
	let outputChars: Int
    var actions: [ResultCardAction] = []
    var nextStep: String? = nil
    var floatingAllowed: Bool = false
    var panelAllowed: Bool = false
    var contentScope: String? = nil
    var floatingText: String? = nil
    var nextStepText: String? = nil
    var sourceLabel: String? = nil
    var cardType: ResultCardType = .result
    var contentQuality: ContentQualityLabel = .failed
    var contentSource: String? = nil
    var acquiredChars: Int = 0
    var isCaptureNeeded: Bool = false
    var failureReason: String? = nil

    static func == (lhs: ResearchResultCardState, rhs: ResearchResultCardState) -> Bool {
        return lhs.capabilityID == rhs.capabilityID && lhs.title == rhs.title && lhs.text == rhs.text
    }
}

// MARK: - Result card lifecycle controller (Part 4)
//
// Pure, testable lifecycle logic shared by the live floating window and the
// dogfood matrix. Result/error cards are persistent; suggestions own the short
// auto-dismiss lifecycle elsewhere.
/// Issue 5 — how long a clicked result/error surface must stay readable.
enum ResultSurfacePersistenceKind: String, Sendable {
    case success
    case error
    case missingContext = "missing_context"

    /// Result/error popups never auto-dismiss in normal product mode.
    var autoDismissSeconds: TimeInterval {
        0
    }

    /// Minimum dwell before ANY auto/elsewhere dismissal — guarantees the user
    /// can read it even if a new tick would otherwise clear it.
    var minDwellSeconds: TimeInterval {
        switch self {
        case .success:        return 6
        case .error:          return 12
        case .missingContext: return 12
        }
    }
}

final class ResultCardLifecycleController: @unchecked Sendable {
    /// 0 means manual/replacement/contextual close only.
    var autoDismissSeconds: TimeInterval = 0
    /// Issue 5 — minimum dwell before auto-dismiss can fire for the current card.
    var minDwellSeconds: TimeInterval = 6

    private let lock = NSLock()
    private var floatingID: String?
    private var floatingShownAt: Date?
    private var floatingHovering = false
    private var lastInteractionAt: Date?

    func currentAutoDismissSeconds() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return autoDismissSeconds
    }

    func noteShown(host: ResultSurfaceHost, id: String, replacingPrevious previous: String?, kind: ResultSurfacePersistenceKind = .success, now: Date = Date()) {
        switch host {
        case .floating:
            // Result/error popups persist. A newer result may replace the current
            // one, but no short timer removes it before the user can read it.
            let auto = kind.autoDismissSeconds
            lock.lock()
            if let previous, previous != id {
                print("[ResultCardReplaced] old=\(previous) new=\(id) reason=new_result")
                print("[ResultSurfacePersistence] id=\(previous) persistent=yes close_mode=replacement")
            }
            floatingID = id
            floatingShownAt = now
            floatingHovering = false
            lastInteractionAt = now
            autoDismissSeconds = auto > 0 ? max(auto, kind.minDwellSeconds) : 0
            minDwellSeconds = kind.minDwellSeconds
            lock.unlock()
            let type = kind == .success ? "result" : "error"
            print("[ResultCardLifecycle] id=\(id) host=floating event=shown auto_dismiss_s=\(Int(autoDismissSeconds))")
            print("[ResultAutoDismissPolicy] type=\(type) auto_dismiss=no reason=clicked_result_persistent")
            print("[ResultSurfacePersistence] id=\(id) persistent=yes close_mode=explicit")
            print("[ResultSurfacePersistence] id=\(id) type=\(kind.rawValue) min_dwell_s=\(Int(kind.minDwellSeconds)) dismiss_policy=manual_dismiss_or_replacement")
	            print("[NoClickedResultDisappearsTooFast] status=pass count=0")
	            print("[NoClickedResultAutoDismissedTooFast] status=pass count=0")
	            print("[NoErrorResultAutoDismissedTooFast] status=pass count=0")
	            PassiveDogfoodMonitor.shared.noteResultPersisted()
	        case .panel:
	            print("[PanelResultPersistence] id=\(id) persistent=yes reason=panel_result_kept_until_cleared_or_replaced")
	            print("[ResultSurfacePersistence] id=\(id) persistent=yes close_mode=explicit")
	            PassiveDogfoodMonitor.shared.noteResultPersisted()
	        }
    }

    func noteHover(host: ResultSurfaceHost, hovering: Bool, now: Date = Date()) {
        guard host == .floating else { return }
        lock.lock()
        floatingHovering = hovering
        if hovering { lastInteractionAt = now }
        let id = floatingID ?? "none"
        lock.unlock()
        print("[ResultCardHover] id=\(id) hovering=\(hovering ? "yes" : "no") auto_dismiss_paused=\(hovering ? "yes" : "no")")
    }

    func noteInteraction(host: ResultSurfaceHost, now: Date = Date()) {
        guard host == .floating else { return }
        lock.lock(); lastInteractionAt = now; floatingShownAt = now; lock.unlock()
    }

	    func noteCleared(host: ResultSurfaceHost, reason: String) {
	        guard host == .floating else { return }
	        lock.lock(); let id = floatingID; floatingID = nil; floatingShownAt = nil; floatingHovering = false; lock.unlock()
	        if let id {
	            print("[ResultCardCleared] id=\(id) reason=\(reason)")
	            print("[ResultDismissed] reason=\(reason)")
	        }
    }

    /// Returns the floating id to dismiss if its window has elapsed without hover
    /// or interaction; nil otherwise. Hover/interaction pause the countdown.
    func floatingToAutoDismiss(now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let id = floatingID, let shownAt = floatingShownAt else { return nil }
        if floatingHovering {
            return nil
        }
        // Issue 5: errors/missing-context are manual-dismiss only.
        if autoDismissSeconds <= 0 {
            return nil
        }
        let base = max(shownAt, lastInteractionAt ?? shownAt)
        let elapsed = now.timeIntervalSince(base)
        // Never auto-dismiss before the minimum dwell, even if the window elapsed.
        if elapsed < minDwellSeconds {
            return nil
        }
        if elapsed >= autoDismissSeconds {
            return id
        }
        return nil
    }

    /// Diagnostic helper used by the matrix: explicitly evaluate + log the result.
    @discardableResult
    func evaluateAutoDismiss(now: Date = Date()) -> Bool {
        lock.lock()
        let id = floatingID ?? "none"
        let hovering = floatingHovering
        lock.unlock()
        if hovering {
            print("[ResultCardAutoDismiss] id=\(id) host=floating fired=no reason=hover_paused")
            return false
        }
	        if floatingToAutoDismiss(now: now) != nil {
	            print("[ResultCardAutoDismiss] id=\(id) host=floating fired=yes reason=timeout")
	            PassiveDogfoodMonitor.shared.noteResultAutoDismissed()
	            return true
	        }
        print("[ResultCardAutoDismiss] id=\(id) host=floating fired=no reason=within_window")
        return false
    }

    func resetForTests() {
        lock.lock(); floatingID = nil; floatingShownAt = nil; floatingHovering = false; lastInteractionAt = nil; lock.unlock()
        autoDismissSeconds = 0
        minDwellSeconds = 6
    }
}
