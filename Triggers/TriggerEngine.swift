import Foundation

/// Evaluates structured context for trigger-worthy moments only (no AI, no UI, no action execution).
final class TriggerEngine {
	private let cooldownManager: CooldownManager

	static let clipboardMinCharacterCount = 30
	static let selectedTextMinCharacterCount = 30

	private static let clipboardCooldownKey = "clipboard_text_eligible"
	private static let selectedTextCooldownKey = "selected_text_eligible"

	private let clipboardCooldownInterval: TimeInterval = 6
	/// Slightly calmer re-triggers on repeated similar selections (T14.11 tuning).
	private let selectedTextCooldownInterval: TimeInterval = 6.5
	private let contextMetadataCooldownInterval: TimeInterval = 8

	private static let contextMetadataCooldownPrefix = "context_metadata_eligible"

	private static let clipboardCandidateActions: [String] = {
		if DynamicOnlyProposalMode.isEnabled { return [] }
		return ["summarize_text", "explain_text", "rewrite_text"]
	}()

	private static let selectedTextCandidateActions: [String] = {
		if DynamicOnlyProposalMode.isEnabled { return [] }
		return ["summarize_text", "explain_text", "rewrite_text"]
	}()

	init(cooldownManager: CooldownManager = CooldownManager()) {
		self.cooldownManager = cooldownManager
	}

	func evaluate(_ context: ContextModel) -> TriggerPacket? {
		if let packet = evaluateManual(context) {
			return packet
		}
		if let packet = evaluateScreenOCRReady(context) {
			return packet
		}
		if let packet = evaluateClipboard(context) {
			return packet
		}
		if let packet = evaluateSelectedText(context) {
			return packet
		}
		return evaluateContextMetadata(context)
	}

	/// T18.3.4: metadata-only proposal path when browsing / app focus changes (dynamic-only).
	private func evaluateContextMetadata(_ context: ContextModel) -> TriggerPacket? {
		guard DynamicOnlyProposalMode.isEnabled else { return nil }
		guard context.lastSourceTrigger == .activeAppChanged
			|| context.lastSourceTrigger == .windowTitleChanged
		else {
			return nil
		}

		let window = (context.activeWindowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let app = (context.activeAppName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !window.isEmpty || !app.isEmpty else { return nil }

		let cooldownKey = "\(Self.contextMetadataCooldownPrefix)|\(context.activeAppBundleIdentifier ?? app)|\(window.prefix(48))"
		guard cooldownManager.acquireIfEligible(
			key: cooldownKey,
			interval: contextMetadataCooldownInterval
		) else {
			return nil
		}

		return TriggerPacket(
			triggerType: .contextMetadataEligible,
			reason: "App/window metadata changed; situational proposal path (no fused packet required).",
			candidateActions: [],
			createdAt: Date()
		)
	}

	private func evaluateScreenOCRReady(_ context: ContextModel) -> TriggerPacket? {
		guard context.lastSourceTrigger == .screenOCRCompleted else { return nil }
		guard context.screenCaptureAvailable,
			  context.screenOCRAvailable,
			  context.screenOCRTextLength > 30 else { return nil }

		var candidateActions: [String] = ["analyze_screen"]
		if !DynamicOnlyProposalMode.isEnabled,
		   context.clipboardTextAvailable || context.selectedTextAvailable {
			candidateActions.insert("summarize_text", at: 0)
			candidateActions.append(contentsOf: ["explain_text", "rewrite_text"])
		}

		return TriggerPacket(
			triggerType: .manualInvocation,
			reason: "Screen OCR updated after manual capture.",
			candidateActions: candidateActions,
			createdAt: Date()
		)
	}

	private func evaluateManual(_ context: ContextModel) -> TriggerPacket? {
		guard context.lastSourceTrigger == .manualTriggerRequested else { return nil }

		let now = Date()
		var candidateActions: [String] = ["analyze_screen"]
		if !DynamicOnlyProposalMode.isEnabled,
		   context.clipboardTextAvailable || context.selectedTextAvailable {
			candidateActions.insert("summarize_text", at: 0)
			candidateActions.append(contentsOf: ["explain_text", "rewrite_text"])
		}

		let hasStructuredSnippet = context.clipboardTextAvailable || context.selectedTextAvailable
		let reason = hasStructuredSnippet
			? "User manually invoked assistant (clipboard or selection metadata available)."
			: "User manually invoked assistant."

		return TriggerPacket(
			triggerType: .manualInvocation,
			reason: reason,
			candidateActions: candidateActions,
			createdAt: now
		)
	}

	private func evaluateClipboard(_ context: ContextModel) -> TriggerPacket? {
		guard AgenticPivot.isClipboardInfluenceEnabled else { return nil }
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
		// Bounded selected-text influence. The global flag stays off; a meaningful,
		// non-typing selection may re-trigger the pipeline under strict gates so real
		// selected work can produce an action-backed proposal (downstream quality
		// gates still decide whether anything surfaces). This is the opposite of
		// flipping the transient-context flag on globally.
		let bounded = AgenticPivot.boundedSelectedTextDecision(context: context)
		guard AgenticPivot.isSelectedTextInfluenceEnabled || bounded.allowed else {
			print("[SelectedFocusTriggerSuppressed] reason=\(bounded.reason)")
			print("[NoSelectedFocusOpportunityWithoutQualityGate] status=pass count=0")
			return nil
		}
		guard context.selectedTextLength > Self.selectedTextMinCharacterCount else {
			print("[SelectedFocusTriggerSuppressed] reason=low_quality")
			return nil
		}

		guard cooldownManager.acquireIfEligible(key: Self.selectedTextCooldownKey, interval: selectedTextCooldownInterval) else {
			print("[SelectedFocusTriggerSuppressed] reason=duplicate")
			return nil
		}

		print("[SelectedFocusOpportunity] selected_available=yes focused_available=yes stable=yes quality=actionable candidate=yes reason=bounded_trigger")
		print("[NoSelectedFocusOpportunityWithoutQualityGate] status=pass count=0")
		return TriggerPacket(
			triggerType: .selectedTextEligible,
			reason: "Bounded selected-text influence: meaningful in-focus selection (>= \(AgenticPivot.boundedSelectedTextMinChars) chars), not actively typing.",
			candidateActions: Self.selectedTextCandidateActions,
			createdAt: Date()
		)
	}
}
