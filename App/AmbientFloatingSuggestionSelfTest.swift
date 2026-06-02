import Foundation

/// Phase 20G.4 — Regression test: ambient Jarvis proposals can surface via the
/// floating suggestion panel and respect cooldown/dismissal.
///
/// Trigger:
///   CONTEXTUAL_RUN_AMBIENT_FLOATING_SUGGESTION_SELFTEST=1
@MainActor
enum AmbientFloatingSuggestionSelfTest {
	static func run() async -> Bool {
		print("[AmbientFloatingSuggestionSelfTest] starting")
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if ok { print("[AmbientFloatingSuggestionSelfTest] pass case=\(name)") }
			else  { print("[AmbientFloatingSuggestionSelfTest] fail case=\(name)"); failures.append(name) }
		}

		let appState = AppState()
		let proposal = ActionProposal(
			title: "Looks like you're studying something new",
			sourceCaption: "Jarvis Suggestion (Preview-Only)",
			primaryActionId: "ambient_jarvis:test",
			secondaryActionIds: [],
			confidence: 0.80,
			reason: "ambient_context_only"
		)

		// Simulate the floating surface attaching.
		let packet = TriggerPacket(
			triggerType: .contextMetadataEligible,
			reason: "ambient_jarvis",
			candidateActions: [],
			createdAt: Date()
		)
		let profile = ContentSimilarityProfile.make(from: FloatingSimilarityText.material(
			for: appState.debugContext,
			triggerType: packet.triggerType,
			inputPreference: .automatic
		))
		let bind = ActiveFloatingLifecycleBinding(
			exactKey: appState.floatingSuggestionLifecycle.exactKey(
				triggerType: packet.triggerType,
				primaryActionId: proposal.primaryActionId,
				profile: profile
			),
			safeKey: appState.floatingSuggestionLifecycle.safeLogKey(
				triggerType: packet.triggerType,
				primaryActionId: proposal.primaryActionId,
				profile: profile
			),
			profile: profile,
			primaryActionId: proposal.primaryActionId
		)

		appState.showFloatingSuggestion(proposal, lifecycle: bind)
		check("ambient_floating_attaches", appState.isFloatingSuggestionVisible)

		// Dismiss should put it on cooldown.
		appState.dismissFloatingSuggestion(reason: .manual)
		check("ambient_floating_dismissed", !appState.isFloatingSuggestionVisible)

		// Publish as currentProposal then dismiss to mark cooldown in the same
		// way the UI does.
		appState.currentProposal = proposal
		appState.dismissCurrentProposal()
		check("cooldown_blocks_repeat", appState.isSuggestionOnCooldown(proposal, context: appState.debugContext))

		let ok = failures.isEmpty
		print("[AmbientFloatingSuggestionSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}

