import Foundation

enum ProposalTimingOutcome: String, Hashable, Sendable, Codable {
	case allow
	case deferred
	case suppress
}

struct ProposalTimingDecision: Hashable, Sendable {
	let outcome: ProposalTimingOutcome
	let reason: String
	let suggestedRetryAfter: TimeInterval?
}

/// Activity-aware proposal timing gate.
/// Lives in Triggers (not UI, not Sources). Uses only metadata inputs.
enum ProposalTimingGate {
	static func evaluate(
		isManualInvocation: Bool,
		isActionExecuting: Bool,
		hasStrongSelectedText: Bool,
		isSelectedTextPrimary: Bool,
		canonicalFreshness: Double?,
		canonicalConfidence: Double?,
		typing: TypingActivityContext?,
		pointer: PointerActivityContext?,
		proposalStrengthHint: Double?
	) -> ProposalTimingDecision {
		if isManualInvocation {
			return ProposalTimingDecision(outcome: .allow, reason: "manual_override", suggestedRetryAfter: nil)
		}

		if isActionExecuting {
			return ProposalTimingDecision(outcome: .suppress, reason: "action_executing", suggestedRetryAfter: nil)
		}

		let typingState = typing?.typingState
		let typingIntensity = typing?.burstIntensity
		let typingActive = typing?.isTypingActive ?? false
		let editingActivity = typing?.estimatedEditingActivity ?? 0.0

		let pointerState = pointer?.pointerState
		let moveIntensity = pointer?.movementBurstIntensity
		let clickIntensity = pointer?.clickBurstIntensity
		let pointerActive = pointer?.isPointerActive ?? false
		let focus = pointer?.estimatedFocusIntensity ?? 0.0

		let canonicalFresh = canonicalFreshness ?? 0.0
		let canonicalConf = canonicalConfidence ?? 0.0
		let strength = clamp01(proposalStrengthHint ?? max(canonicalConf, 0.0))

		let isTypingBurst = (typingState == .burst) || (typingIntensity == .high)
		let isPointerBurst = (pointerState == .burst) || (moveIntensity == .high) || (clickIntensity == .high)

		// Treat "active interaction" as meaningful editing/clicking, not mere low-intensity motion.
		let isInteracting = pointerState == .interacting || pointerState == .clicking
		let isEditing = typingState == .active || typingState == .started
		let isActiveInteraction = (typingActive && isEditing) || (pointerActive && isInteracting)

		let isIdlePause = (typingState == .idle || typingState == .stopped || typing == nil)
			&& (pointerState == .idle || pointerState == .stopped || pointer == nil)

		let contextIsStrong = (canonicalFresh >= 0.55) && (max(canonicalConf, strength) >= 0.70)

		let selectedTextVeryStrong = hasStrongSelectedText && isSelectedTextPrimary && strength >= 0.85

		// Strong selected text should usually show unless activity is truly high/burst.
		if selectedTextVeryStrong, !isTypingBurst, !isPointerBurst {
			// Allow even if there was mild movement/started typing.
			return ProposalTimingDecision(outcome: .allow, reason: "strong_selection_allowed", suggestedRetryAfter: nil)
		}

		// Burst behavior: avoid interrupting; defer briefly if it might be useful soon.
		if isTypingBurst {
			return ProposalTimingDecision(outcome: .deferred, reason: "typing_burst_defer", suggestedRetryAfter: 1.6)
		}
		if isPointerBurst {
			return ProposalTimingDecision(outcome: .deferred, reason: "pointer_burst_defer", suggestedRetryAfter: 1.4)
		}

		// Low-intensity pointer movement should not defer strong proposals.
		if pointerState == .moving, (moveIntensity == .none || moveIntensity == .low), strength >= 0.75 {
			return ProposalTimingDecision(outcome: .allow, reason: "pointer_low_allow", suggestedRetryAfter: nil)
		}

		// Low-intensity typing (started/active but not burst) should not defer strong selected text.
		if (typingState == .started || typingState == .active),
		   (typingIntensity == .none || typingIntensity == .low),
		   hasStrongSelectedText,
		   strength >= 0.75
		{
			return ProposalTimingDecision(outcome: .allow, reason: "typing_low_allow", suggestedRetryAfter: nil)
		}

		// Only defer for interacting with meaningful intensity (medium/high).
		if isInteracting, (moveIntensity == .medium || moveIntensity == .high || clickIntensity == .medium || clickIntensity == .high) {
			return ProposalTimingDecision(outcome: .deferred, reason: "active_interaction", suggestedRetryAfter: 1.2)
		}

		// Strong context but user is actively interacting: prefer defer rather than suppress.
		if isActiveInteraction, contextIsStrong {
			return ProposalTimingDecision(outcome: .deferred, reason: "active_interaction", suggestedRetryAfter: 1.2)
		}

		// Weak/medium proposals during active work should be suppressed to reduce interruptions.
		if isActiveInteraction, strength < 0.65, (editingActivity > 0.55 || focus > 0.55) {
			return ProposalTimingDecision(outcome: .suppress, reason: "weak_context_deferred", suggestedRetryAfter: nil)
		}

		// Idle pause: allow more readily if context is fresh or proposal is strong.
		if isIdlePause, canonicalFresh >= 0.35 || strength >= 0.75 {
			return ProposalTimingDecision(outcome: .allow, reason: "idle_pause", suggestedRetryAfter: nil)
		}

		// Default conservative behavior: allow only when not actively interacting.
		if !isActiveInteraction {
			return ProposalTimingDecision(outcome: .allow, reason: "high_confidence_allowed", suggestedRetryAfter: nil)
		}

		// Fallback: defer briefly.
		return ProposalTimingDecision(outcome: .deferred, reason: "defer_generic", suggestedRetryAfter: 1.2)
	}

	static func selfTest() -> Bool {
		print("[ProposalTiming] selftest starting")

		func typing(_ state: TypingState, intensity: TypingBurstIntensity, active: Bool) -> TypingActivityContext {
			TypingActivityContext(
				id: UUID(),
				updatedAt: Date(),
				appName: "TestApp",
				bundleIdentifier: "test.bundle",
				isTypingActive: active,
				typingState: state,
				recentEventCount: active ? 12 : 0,
				burstIntensity: intensity,
				sessionDuration: 2,
				idleDuration: active ? 0.2 : 2.2,
				estimatedEditingActivity: active ? 0.9 : 0.0
			)
		}

		func pointer(_ state: PointerState, move: PointerBurstIntensity, click: PointerBurstIntensity, active: Bool) -> PointerActivityContext {
			PointerActivityContext(
				id: UUID(),
				updatedAt: Date(),
				appName: "TestApp",
				bundleIdentifier: "test.bundle",
				isPointerActive: active,
				pointerState: state,
				recentMoveEventCount: active ? 18 : 0,
				recentClickEventCount: active ? 3 : 0,
				movementBurstIntensity: move,
				clickBurstIntensity: click,
				sessionDuration: 3,
				idleDuration: active ? 0.1 : 2.5,
				estimatedFocusIntensity: active ? 0.9 : 0.0
			)
		}

		let cases: [(String, ProposalTimingDecision)] = [
			("idle_strong_allows", evaluate(
				isManualInvocation: false,
				isActionExecuting: false,
				hasStrongSelectedText: true,
				isSelectedTextPrimary: true,
				canonicalFreshness: 0.9,
				canonicalConfidence: 0.85,
				typing: typing(.idle, intensity: .none, active: false),
				pointer: pointer(.idle, move: .none, click: .none, active: false),
				proposalStrengthHint: 0.85
			)),
			("strong_sel_pointer_moving_low_allows", evaluate(
				isManualInvocation: false,
				isActionExecuting: false,
				hasStrongSelectedText: true,
				isSelectedTextPrimary: true,
				canonicalFreshness: 0.8,
				canonicalConfidence: 0.8,
				typing: typing(.idle, intensity: .none, active: false),
				pointer: pointer(.moving, move: .low, click: .none, active: true),
				proposalStrengthHint: 0.88
			)),
			("strong_sel_typing_active_low_allows", evaluate(
				isManualInvocation: false,
				isActionExecuting: false,
				hasStrongSelectedText: true,
				isSelectedTextPrimary: true,
				canonicalFreshness: 0.8,
				canonicalConfidence: 0.8,
				typing: typing(.active, intensity: .low, active: true),
				pointer: pointer(.idle, move: .none, click: .none, active: false),
				proposalStrengthHint: 0.88
			)),
			("typing_burst_defers", evaluate(
				isManualInvocation: false,
				isActionExecuting: false,
				hasStrongSelectedText: true,
				isSelectedTextPrimary: true,
				canonicalFreshness: 0.7,
				canonicalConfidence: 0.7,
				typing: typing(.burst, intensity: .high, active: true),
				pointer: pointer(.idle, move: .none, click: .none, active: false),
				proposalStrengthHint: 0.8
			)),
			("pointer_burst_defers", evaluate(
				isManualInvocation: false,
				isActionExecuting: false,
				hasStrongSelectedText: true,
				isSelectedTextPrimary: true,
				canonicalFreshness: 0.7,
				canonicalConfidence: 0.7,
				typing: typing(.idle, intensity: .none, active: false),
				pointer: pointer(.burst, move: .high, click: .medium, active: true),
				proposalStrengthHint: 0.8
			)),
			("manual_override_allows", evaluate(
				isManualInvocation: true,
				isActionExecuting: false,
				hasStrongSelectedText: false,
				isSelectedTextPrimary: false,
				canonicalFreshness: 0.0,
				canonicalConfidence: 0.0,
				typing: typing(.burst, intensity: .high, active: true),
				pointer: pointer(.burst, move: .high, click: .high, active: true),
				proposalStrengthHint: 0.2
			)),
			("action_executing_suppresses", evaluate(
				isManualInvocation: false,
				isActionExecuting: true,
				hasStrongSelectedText: true,
				isSelectedTextPrimary: true,
				canonicalFreshness: 0.9,
				canonicalConfidence: 0.9,
				typing: typing(.idle, intensity: .none, active: false),
				pointer: pointer(.idle, move: .none, click: .none, active: false),
				proposalStrengthHint: 0.9
			)),
			("weak_during_activity_suppresses", evaluate(
				isManualInvocation: false,
				isActionExecuting: false,
				hasStrongSelectedText: false,
				isSelectedTextPrimary: false,
				canonicalFreshness: 0.4,
				canonicalConfidence: 0.4,
				typing: typing(.active, intensity: .low, active: true),
				pointer: pointer(.interacting, move: .medium, click: .low, active: true),
				proposalStrengthHint: 0.45
			))
		]

		for (name, d) in cases {
			let retry = d.suggestedRetryAfter.map { String(format: "%.1f", $0) } ?? "nil"
			print("[ProposalTiming] selftest case=\(name) outcome=\(d.outcome.rawValue) reason=\(d.reason) retry=\(retry)")
		}

		let ok = cases.contains(where: { $0.0 == "strong_sel_pointer_moving_low_allows" && $0.1.outcome == .allow })
			&& cases.contains(where: { $0.0 == "strong_sel_typing_active_low_allows" && $0.1.outcome == .allow })
			&& cases.contains(where: { $0.0 == "typing_burst_defers" && $0.1.outcome == .deferred })
			&& cases.contains(where: { $0.0 == "pointer_burst_defers" && $0.1.outcome == .deferred })
			&& cases.contains(where: { $0.0 == "manual_override_allows" && $0.1.outcome == .allow })
			&& cases.contains(where: { $0.0 == "action_executing_suppresses" && $0.1.outcome == .suppress })

		print("[ProposalTiming] selftest finished ok=\(ok)")
		return ok
	}
}

private func clamp01(_ x: Double) -> Double {
	min(1.0, max(0.0, x))
}

