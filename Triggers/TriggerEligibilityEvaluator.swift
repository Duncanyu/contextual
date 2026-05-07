import Foundation

/// Heuristic gate for whether a floating suggestion should appear (TES v1). Not AI confidence.
struct TriggerEligibilityResult: Equatable {
	let shouldShow: Bool
	let score: Double
	let reason: String
}

/// Conservative floating-suggestion eligibility (metadata-only; no raw text inspection).
enum TriggerEligibilityEvaluator {
	static let scoreThreshold: Double = 0.75
	static let minimumProposalConfidence: Double = 0.75

	private static let selectionStrongMin = 100
	private static let clipboardStrongMin = 100
	private static let clipboardErrorLikeMin = 400

	static func evaluate(
		proposal: ActionProposal,
		suggestionStrength: SuggestionStrength?,
		context: ContextModel,
		triggerType: TriggerType,
		isPaused: Bool,
		isPopoverOpen: Bool,
		isFloatingVisible: Bool,
		isActionExecuting: Bool,
		inputSourceChoice: InputSourceChoice
	) -> TriggerEligibilityResult {
		if isPaused {
			return TriggerEligibilityResult(shouldShow: false, score: 0, reason: "assistant_paused")
		}
		if isPopoverOpen {
			return TriggerEligibilityResult(shouldShow: false, score: 0, reason: "panel_open")
		}
		if isFloatingVisible {
			return TriggerEligibilityResult(shouldShow: false, score: 0, reason: "already_showing")
		}
		if isActionExecuting {
			return TriggerEligibilityResult(shouldShow: false, score: 0, reason: "executing_action")
		}
		if let strength = suggestionStrength, strength != .strong {
			return TriggerEligibilityResult(shouldShow: false, score: 0, reason: "not_strong strength=\(strength.rawValue)")
		}
		if proposal.confidence < minimumProposalConfidence {
			return TriggerEligibilityResult(shouldShow: false, score: proposal.confidence, reason: "low_confidence")
		}
		if triggerType == .manualInvocation {
			return TriggerEligibilityResult(shouldShow: false, score: 0, reason: "manual_invocation")
		}

		let dominant = dominantFloatingInput(context: context, preference: inputSourceChoice)
		guard let dominant else {
			return TriggerEligibilityResult(shouldShow: false, score: 0, reason: "no_meaningful_input")
		}

		var score = baseSignalScore(dominant: dominant)
		if dominant.kind == .clipboard, dominant.length >= clipboardErrorLikeMin {
			score = min(1.0, score + 0.08)
		}

		var allowReason = primaryAllowReason(for: dominant)

		if score < scoreThreshold, isLikelyContextualDeveloperApp(bundleId: context.activeAppBundleIdentifier) {
			let boosted = min(1.0, score + 0.08)
			if boosted >= scoreThreshold {
				score = boosted
				allowReason = "active_app_contextual"
			}
		}

		if score < scoreThreshold {
			return TriggerEligibilityResult(shouldShow: false, score: score, reason: "weak_signal")
		}

		return TriggerEligibilityResult(shouldShow: true, score: score, reason: allowReason)
	}

	private enum DominantKind {
		case selection
		case clipboard
	}

	private struct DominantInput {
		let kind: DominantKind
		let length: Int
	}

	/// Resolves which channel drives floating eligibility (selection preferred under `.automatic` when eligible).
	private static func dominantFloatingInput(context: ContextModel, preference: InputSourceChoice) -> DominantInput? {
		let selOK = context.selectedTextAvailable && context.selectedTextLength >= TriggerEngine.selectedTextMinCharacterCount
		let clipOK = context.clipboardTextAvailable && context.clipboardTextLength >= TriggerEngine.clipboardMinCharacterCount

		switch preference {
		case .automatic:
			if selOK {
				return DominantInput(kind: .selection, length: context.selectedTextLength)
			}
			if clipOK {
				return DominantInput(kind: .clipboard, length: context.clipboardTextLength)
			}
			return nil
		case .selectedText:
			guard selOK else { return nil }
			return DominantInput(kind: .selection, length: context.selectedTextLength)
		case .clipboard:
			guard clipOK else { return nil }
			return DominantInput(kind: .clipboard, length: context.clipboardTextLength)
		case .screenOCR:
			// Floating suggestions must not activate on OCR-only input for TES v1.
			return nil
		}
	}

	private static func baseSignalScore(dominant: DominantInput) -> Double {
		let len = dominant.length
		switch dominant.kind {
		case .selection:
			if len >= selectionStrongMin { return 0.90 }
			return 0.70
		case .clipboard:
			if len >= clipboardStrongMin { return 0.82 }
			return 0.76
		}
	}

	private static func primaryAllowReason(for dominant: DominantInput) -> String {
		switch dominant.kind {
		case .selection:
			return "high_signal_selection"
		case .clipboard:
			return "high_signal_clipboard"
		}
	}

	private static func isLikelyContextualDeveloperApp(bundleId: String?) -> Bool {
		guard let id = bundleId?.lowercased(), !id.isEmpty else { return false }
		return id.contains("xcode")
			|| id.contains("terminal")
			|| id.contains("vscode")
			|| id.contains("cursor")
			|| id.contains("jetbrains")
			|| id.contains("com.apple.dt")
			|| id.contains("fleet")
			|| id.contains("zed")
	}
}
