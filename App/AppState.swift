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
	@Published var availableActions: [any ActionProtocol] = []
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

	private let dismissedSuggestionCooldown = CooldownManager()
	private let acceptedSuggestionCooldown = CooldownManager()
	private let dismissedSuggestionCooldownSeconds: TimeInterval = 120
	private let acceptedSuggestionCooldownSeconds: TimeInterval = 60

	// MARK: - Local AI (delegates persistence + orchestration to app lifecycle)

	@Published var modelRuntimeState: ModelRuntimeState = .checking
	@Published var localAIEnabled: Bool = false
	@Published var autoStartOllama: Bool = false

	@Published var latestActionResult: String?
	@Published var latestActionId: String?
	@Published var latestActionTimestamp: Date?

	/// Mirrors in-flight action execution for UI (updated only by app lifecycle).
	@Published var isActionExecuting: Bool = false
	@Published var executingActionId: String?
	@Published var executingActionTitle: String?

	/// Session-only preference for which input feed text actions use (`automatic` = selection → clipboard → screen OCR).
	@Published var selectedInputSourceChoice: InputSourceChoice = .automatic

	/// Session-only redundancy tuning (T11.7). Never stores raw text.
	let redundancyMemory = RedundancyMemory()

	// MARK: - Floating suggestion (T10.1)

	@Published var floatingSuggestion: SuggestionViewModel?
	@Published var isFloatingSuggestionVisible: Bool = false

	let floatingSuggestionLifecycle = FloatingSuggestionLifecycle()
	private var activeFloatingLifecycleBinding: ActiveFloatingLifecycleBinding?

	private var floatingAutoDismissWorkItem: DispatchWorkItem?
	private let floatingAutoDismissSeconds: TimeInterval = 7

	/// Wired by app lifecycle to enqueue a manual trigger through the normal source pipeline.
	var requestManualInvocation: (() -> Void)?

	/// UI forwards user taps here; app lifecycle resolves execution with current context (UI never reads context).
	var onInvokeActionById: ((String) -> Void)?
	/// User-invoked generated proposal execution; wired by app lifecycle (no UI/runtime coupling).
	var onInvokeGeneratedExecutionProposalById: ((String) -> Void)?

	var onEnableLocalAI: (() -> Void)?
	var onDisableLocalAI: (() -> Void)?
	var onEnableAutoStartOllama: (() -> Void)?
	var onDisableAutoStartOllama: (() -> Void)?
	var onStartOllamaNow: (() -> Void)?
	var onOpenOllamaDownload: (() -> Void)?
	var onPullLocalAIModel: (() -> Void)?
	/// Opens the assistant popover (menu bar); wired by app lifecycle.
	var onRevealAssistantPanel: (() -> Void)?

	func invokeAction(id: String) {
		if id.hasPrefix(GeneratedExecutionProposalActivator.generatedProposalIdPrefix) {
			let candidateId = String(id.dropFirst(GeneratedExecutionProposalActivator.generatedProposalIdPrefix.count))
			invokeGeneratedExecutionProposal(id: candidateId)
			return
		}
		GeneratedActionInteractionTracker.shared.considerAcceptedProxy(staticActionId: id)
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
		if dismissedSuggestionCooldown.isCoolingDown(key: key, interval: dismissedSuggestionCooldownSeconds, now: now) {
			return true
		}
		if acceptedSuggestionCooldown.isCoolingDown(key: key, interval: acceptedSuggestionCooldownSeconds, now: now) {
			return true
		}
		return false
	}

	func acceptCurrentProposal() {
		guard let proposal = currentProposal else { return }
		let suggestionKey = suggestionKey(for: proposal, context: debugContext)
		let redundancyKey = String(fnv1a64(text: suggestionKey), radix: 16)
		let id = proposal.primaryActionId
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
		generatedProposalActivationResult = result
		activatedGeneratedProposals = result.visibleProposals
		if let debugStatus {
			generatedProposalDebugStatus = debugStatus
		}
	}

	/// User-invoked generated proposal execution (T18.4+) — no automatic execution on proposal generation.
	func invokeGeneratedExecutionProposal(id: String) {
		guard let item = activatedGeneratedProposals.first(where: { $0.id == id }) else { return }
		print("[GeneratedProposalExecution] selected id=\(id.prefix(12)) source=\(item.source.rawValue)")
		latestActionId = GeneratedExecutionProposalActivator.generatedProposalActionId(for: id)
		latestActionTimestamp = Date()
		latestActionResult = "Executing generated action…"
		onInvokeGeneratedExecutionProposalById?(id)
	}

	func dismissCurrentProposal() {
		guard let proposal = currentProposal else { return }
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
			print("[ProposalCooldown] recorded dismiss key=\(key)")
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

	func showFloatingSuggestion(_ suggestion: SuggestionViewModel, lifecycle: ActiveFloatingLifecycleBinding) {
		floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil

		let logKey = floatingSuggestionLogKey(for: suggestion, context: debugContext)
		print("[FloatingSuggestion] show key=\(logKey)")

		floatingSuggestionLifecycle.record(
			.shown,
			exactKey: lifecycle.exactKey,
			primaryActionId: lifecycle.primaryActionId,
			profile: lifecycle.profile
		)
		floatingSuggestionLifecycle.logRecorded(state: .shown, safeKey: lifecycle.safeKey)
		activeFloatingLifecycleBinding = lifecycle

		redundancyMemory.record(event: .shown, key: lifecycle.exactKey, actionId: lifecycle.primaryActionId)

		floatingSuggestion = suggestion
		isFloatingSuggestionVisible = true
		refreshFloatingProposalContext(for: suggestion)

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

		if let bind = activeFloatingLifecycleBinding, reason != .accepted {
			switch reason {
			case .auto, .panelOpen:
				floatingSuggestionLifecycle.record(
					.autoDismissed,
					exactKey: bind.exactKey,
					primaryActionId: bind.primaryActionId,
					profile: bind.profile
				)
				floatingSuggestionLifecycle.logRecorded(state: .autoDismissed, safeKey: bind.safeKey)
				redundancyMemory.record(event: .autoDismissed, key: bind.exactKey, actionId: bind.primaryActionId)
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

		floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil
		floatingSuggestion = nil
		isFloatingSuggestionVisible = false
		refreshFloatingProposalContext(for: nil)

		if reason != .accepted, let p = proposalSnapshot {
			let logKey = floatingSuggestionLogKey(for: p, context: ctx)
			print("[FloatingSuggestion] dismissed key=\(logKey) reason=\(reason.rawValue)")
		}
	}

	/// Primary action on floating card: hide float, open panel, preserve proposal/context, run action via existing execution path.
	func acceptFloatingProposal() {
		guard let proposal = floatingSuggestion else { return }
		let suggestionKey = suggestionKey(for: proposal, context: debugContext)
		let id = proposal.primaryActionId
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

		onRevealAssistantPanel?()
		invokeAction(id: id)
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
		let next = DynamicActionDisplayBuilder.build(isActionExecutingForPreviewRanking: isActionExecuting)
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
			"[DynamicActionUX] updated count=\(summary.previewItems.count) top=\(top) category=\(summary.previewItems.first?.category.rawValue ?? "nil")"
		)
	}
}
