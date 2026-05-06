import AppKit
import Foundation

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

	func invokeAction(id: String) {
		onInvokeActionById?(id)
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
		guard let text = ActionInputCapture.primaryText(for: context, minimumLength: 0), !text.isEmpty else { return nil }
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
}
