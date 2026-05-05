import Foundation

/// Evaluates structured context for trigger-worthy moments only (no AI, no UI, no action execution).
final class TriggerEngine {
	private let cooldownManager: CooldownManager

	static let clipboardMinCharacterCount = 30
	static let selectedTextMinCharacterCount = 30

	private static let clipboardCooldownKey = "clipboard_text_eligible"
	private static let selectedTextCooldownKey = "selected_text_eligible"

	private let clipboardCooldownInterval: TimeInterval = 6
	private let selectedTextCooldownInterval: TimeInterval = 6
	/// Minimum time between **emitted** manual `TriggerPacket`s (not between `SourceEvent`s).
	private let manualInvocationPacketCooldownInterval: TimeInterval = 4

	private static let clipboardCandidateActions = ["summarize_text", "explain_text", "rewrite_text"]
	private static let selectedTextCandidateActions = ["summarize_text", "explain_text", "rewrite_text"]

	private var lastManualInvocationPacketEmittedAt: Date?

	init(cooldownManager: CooldownManager = CooldownManager()) {
		self.cooldownManager = cooldownManager
	}

	func evaluate(_ context: ContextModel) -> TriggerPacket? {
		if let packet = evaluateManual(context) {
			return packet
		}
		if let packet = evaluateClipboard(context) {
			return packet
		}
		return evaluateSelectedText(context)
	}

	private func evaluateManual(_ context: ContextModel) -> TriggerPacket? {
		guard context.lastSourceTrigger == .manualTriggerRequested else { return nil }

		let now = Date()
		if let lastPacketAt = lastManualInvocationPacketEmittedAt,
		   now.timeIntervalSince(lastPacketAt) < manualInvocationPacketCooldownInterval {
			return nil
		}

		var candidateActions: [String] = []
		if context.clipboardTextAvailable || context.selectedTextAvailable {
			candidateActions.append("summarize_text")
		}
		candidateActions.append(contentsOf: ["explain_text", "rewrite_text"])

		let hasStructuredSnippet = context.clipboardTextAvailable || context.selectedTextAvailable
		let reason = hasStructuredSnippet
			? "User manually invoked assistant (clipboard or selection metadata available)."
			: "User manually invoked assistant."

		let packet = TriggerPacket(
			triggerType: .manualInvocation,
			reason: reason,
			candidateActions: candidateActions,
			createdAt: now
		)
		lastManualInvocationPacketEmittedAt = now
		return packet
	}

	private func evaluateClipboard(_ context: ContextModel) -> TriggerPacket? {
		guard context.lastSourceTrigger == .clipboardTextChanged else { return nil }
		guard context.clipboardTextAvailable else { return nil }
		guard context.clipboardTextLength > Self.clipboardMinCharacterCount else { return nil }

		guard cooldownManager.acquireIfEligible(key: Self.clipboardCooldownKey, interval: clipboardCooldownInterval) else {
			return nil
		}

		return TriggerPacket(
			triggerType: .clipboardTextEligible,
			reason: "Clipboard plain text metadata indicates content longer than \(Self.clipboardMinCharacterCount) characters.",
			candidateActions: Self.clipboardCandidateActions,
			createdAt: Date()
		)
	}

	private func evaluateSelectedText(_ context: ContextModel) -> TriggerPacket? {
		guard context.lastSourceTrigger == .selectedTextChanged else { return nil }
		guard context.selectedTextAvailable else { return nil }
		guard context.selectedTextLength > Self.selectedTextMinCharacterCount else { return nil }

		guard cooldownManager.acquireIfEligible(key: Self.selectedTextCooldownKey, interval: selectedTextCooldownInterval) else {
			return nil
		}

		return TriggerPacket(
			triggerType: .selectedTextEligible,
			reason: "Accessibility-selected text metadata indicates selection longer than \(Self.selectedTextMinCharacterCount) characters.",
			candidateActions: Self.selectedTextCandidateActions,
			createdAt: Date()
		)
	}
}
