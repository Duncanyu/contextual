import Foundation

/// Evaluates structured context for trigger-worthy moments only (no AI, no UI, no action execution).
final class TriggerEngine {
	private let cooldownManager: CooldownManager

	static let clipboardMinCharacterCount = 30
	private static let clipboardCooldownKey = "clipboard_text_eligible"
	private let clipboardCooldownInterval: TimeInterval = 6

	private static let clipboardCandidateActions = ["summarize_text", "explain_text", "rewrite_text"]

	init(cooldownManager: CooldownManager = CooldownManager()) {
		self.cooldownManager = cooldownManager
	}

	func evaluate(_ context: ContextModel) -> TriggerPacket? {
		evaluateClipboard(context)
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
}
