import AppKit
import Foundation

/// Proposal payload for panel and floating suggestion UI (same struct from `ProposalGenerator`).
typealias SuggestionViewModel = ActionProposal

@MainActor
final class AppState: ObservableObject {
	@Published var isPaused: Bool = false
	/// Latest context for UI (updated by app lifecycle; not built in UI).
	@Published var debugContext: ContextModel = ContextModel()

	/// Actions eligible at last trigger — populated by app lifecycle when a `TriggerPacket` is produced.
	@Published var availableActions: [any ActionProtocol] = []
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

	@Published var modelRuntimeState: ModelRuntimeState = .notRunning
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

	// MARK: - Floating suggestion (T10.1)

	@Published var floatingSuggestion: SuggestionViewModel?
	@Published var isFloatingSuggestionVisible: Bool = false

	private var floatingAutoDismissWorkItem: DispatchWorkItem?
	private let floatingAutoDismissSeconds: TimeInterval = 7

	/// Wired by app lifecycle to enqueue a manual trigger through the normal source pipeline.
	var requestManualInvocation: (() -> Void)?

	/// UI forwards user taps here; app lifecycle resolves execution with current context (UI never reads context).
	var onInvokeActionById: ((String) -> Void)?

	var onEnableLocalAI: (() -> Void)?
	var onDisableLocalAI: (() -> Void)?
	var onEnableAutoStartOllama: (() -> Void)?
	var onDisableAutoStartOllama: (() -> Void)?
	var onStartOllamaNow: (() -> Void)?
	var onOpenOllamaDownload: (() -> Void)?
	/// Opens the assistant popover (menu bar); wired by app lifecycle.
	var onRevealAssistantPanel: (() -> Void)?

	func invokeAction(id: String) {
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
		let id = proposal.primaryActionId
		print("[SuggestionCard] accepted proposal primary=\(id)")
		lastAcceptedProposalActionId = id

		acceptedSuggestionCooldown.markFired(key: suggestionKey)

		if let key = currentProposalKey {
			lastAcceptedProposalKey = key
			lastAcceptedProposalAt = Date()
			print("[ProposalCooldown] recorded accept key=\(key)")
		}

		invokeAction(id: id)
		currentProposal = nil
		currentProposalKey = nil
	}

	func dismissCurrentProposal() {
		guard let proposal = currentProposal else { return }
		let suggestionKey = suggestionKey(for: proposal, context: debugContext)
		let id = proposal.primaryActionId
		print("[SuggestionCard] dismissed proposal primary=\(id)")
		lastDismissedProposalActionId = id

		dismissedSuggestionCooldown.markFired(key: suggestionKey)

		if let key = currentProposalKey {
			lastDismissedProposalKey = key
			lastDismissedProposalAt = Date()
			print("[ProposalCooldown] recorded dismiss key=\(key)")
		}

		currentProposal = nil
		currentProposalKey = nil
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

	func clearResult() {
		latestActionResult = nil
		latestActionId = nil
		latestActionTimestamp = nil
	}

	// MARK: - Floating suggestion controls

	func showFloatingSuggestion(_ suggestion: SuggestionViewModel) {
		floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil

		floatingSuggestion = suggestion
		isFloatingSuggestionVisible = true

		let work = DispatchWorkItem { [weak self] in
			Task { @MainActor in
				self?.dismissFloatingSuggestion()
			}
		}
		floatingAutoDismissWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + floatingAutoDismissSeconds, execute: work)
	}

	func dismissFloatingSuggestion() {
		floatingAutoDismissWorkItem?.cancel()
		floatingAutoDismissWorkItem = nil
		floatingSuggestion = nil
		isFloatingSuggestionVisible = false
	}

	/// Primary action on floating card: reveal panel and invoke (same outcome as accepting in-panel).
	func acceptFloatingProposal() {
		guard let proposal = floatingSuggestion else { return }
		let suggestionKey = suggestionKey(for: proposal, context: debugContext)
		let id = proposal.primaryActionId
		print("[FloatingSuggestion] accepted primary=\(id)")

		acceptedSuggestionCooldown.markFired(key: suggestionKey)
		if let key = currentProposalKey {
			lastAcceptedProposalKey = key
			lastAcceptedProposalAt = Date()
		}

		dismissFloatingSuggestion()
		currentProposal = nil
		currentProposalKey = nil

		onRevealAssistantPanel?()
		invokeAction(id: id)
	}

	func floatingPrimaryButtonTitle(for proposal: ActionProposal) -> String {
		if let action = availableActions.first(where: { $0.id == proposal.primaryActionId }) {
			return action.name
		}
		switch proposal.primaryActionId {
		case "summarize_text":
			return "Summarize"
		case "explain_text":
			return "Explain"
		case "rewrite_text":
			return "Rewrite"
		case ScreenAnalyzeAction.analyzeScreenId:
			return "Analyze Screen"
		default:
			return "Open"
		}
	}
}
