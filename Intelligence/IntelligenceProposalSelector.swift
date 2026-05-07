import Foundation

/// Runtime integration for T12.6: conservative LLM-assisted proposal selection after heuristics rank.
@MainActor
final class IntelligenceProposalSelector {
	private let budget = IntelligenceBudgetManager()
	private let cache = IntelligenceDecisionCache()
	private let engine = LocalIntelligenceDecisionEngine()

	private var lastConsideredSig: String?
	private var lastConsideredAt: Date?

	private static let overrideConfidenceThreshold: Double = 0.78
	private static let suppressConfidenceThreshold: Double = 0.85

	enum Outcome: Equatable {
		case unchanged
		case overridePrimary(String)
		case suppressProposal
	}

	struct Result: Equatable {
		let outcome: Outcome
	}

	/// - Parameter candidateLLMActionIds: Executable text actions (summarize / explain / rewrite) for the model to choose from.
	func run(
		context: ContextModel,
		triggerPacket: TriggerPacket,
		sourceText: String,
		contextType: ContextType,
		features: ContextFeatures,
		suggestionStrength: SuggestionStrength,
		candidateLLMActionIds: [String],
		heuristicPrimaryActionId: String,
		inputPreference: InputSourceChoice,
		isActionExecuting: Bool
	) async -> Result {
		guard !candidateLLMActionIds.isEmpty else { return Result(outcome: .unchanged) }

		let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return Result(outcome: .unchanged) }

		let sourceType = Self.intelligenceSourceType(triggerType: triggerPacket.triggerType, inputPreference: inputPreference)

		let packet = ContextCompressor.compress(
			contextType: contextType,
			features: features,
			availableActions: candidateLLMActionIds,
			sourceType: sourceType,
			appName: context.activeAppName,
			windowTitle: context.activeWindowTitle,
			text: sourceText
		)

		guard !packet.textExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return Result(outcome: .unchanged)
		}

		let request = IntelligenceDecisionRequest(
			contextType: contextType,
			features: features,
			availableActions: candidateLLMActionIds,
			sourceType: sourceType,
			appName: context.activeAppName,
			windowTitle: context.activeWindowTitle,
			textLength: max(trimmed.count, packet.originalTextLength),
			lineCount: packet.lineCount,
			compressedText: packet.textExcerpt
		)

		let metaFingerprint = IntelligenceDecisionCache.deriveFingerprint(for: request)
		let contentFingerprint = ContextCompressor.fingerprintHex(for: trimmed)
		let fingerprint = "\(metaFingerprint).\(contentFingerprint)"

		logConsideredIfNeeded(
			contextType: contextType,
			strength: suggestionStrength,
			actionCount: candidateLLMActionIds.count,
			lenBucket: request.textLength / 25
		)

		let isModelAvailable = await ModelManager.shared.isGenerationAvailable()

		if let cached = cache.lookup(fingerprint: fingerprint, request: request) {
			return applyInterpretation(decision: cached, heuristicPrimary: heuristicPrimaryActionId, request: request, fromCache: true)
		}

		let budgetDecision = budget.evaluate(
			request: request,
			suggestionStrength: suggestionStrength,
			isActionExecuting: isActionExecuting,
			isModelAvailable: isModelAvailable,
			contextFingerprint: fingerprint
		)

		if !budgetDecision.allowed {
			logHeuristicKept(reason: "budget_denied")
			return Result(outcome: .unchanged)
		}

		let decision = await engine.decide(request: request, suggestionStrength: suggestionStrength)

		if decision.isValid(for: request), decision.confidence > 0.02 {
			cache.store(decision: decision, fingerprint: fingerprint, request: request)
		}

		return applyInterpretation(decision: decision, heuristicPrimary: heuristicPrimaryActionId, request: request, fromCache: false)
	}

	// MARK: - Interpretation

	private func applyInterpretation(
		decision: IntelligenceDecisionResponse,
		heuristicPrimary: String,
		request: IntelligenceDecisionRequest,
		fromCache: Bool
	) -> Result {
		guard decision.isValid(for: request) else {
			print("[IntelligenceSelection] decision rejected reason=invalid fromCache=\(fromCache)")
			logHeuristicKept(reason: "invalid")
			return Result(outcome: .unchanged)
		}

		let c = min(1.0, max(0.0, decision.confidence))

		if !decision.shouldSuggest {
			if c >= Self.suppressConfidenceThreshold {
				let cs = String(format: "%.2f", c)
				print("[IntelligenceSelection] decision accepted apply=suppress conf=\(cs) fromCache=\(fromCache)")
				print("[IntelligenceSelection] proposal suppressed")
				return Result(outcome: .suppressProposal)
			}
			print("[IntelligenceSelection] decision rejected reason=low_conf_suggest_false fromCache=\(fromCache)")
			logHeuristicKept(reason: "low_conf")
			return Result(outcome: .unchanged)
		}

		guard let best = decision.bestActionId, c >= Self.overrideConfidenceThreshold else {
			print("[IntelligenceSelection] decision rejected reason=low_conf fromCache=\(fromCache)")
			logHeuristicKept(reason: "low_conf")
			return Result(outcome: .unchanged)
		}

		if best == heuristicPrimary {
			let cs = String(format: "%.2f", c)
			print("[IntelligenceSelection] decision accepted apply=keep conf=\(cs) fromCache=\(fromCache)")
			logHeuristicKept(reason: "same_primary")
			return Result(outcome: .unchanged)
		}

		let cs = String(format: "%.2f", c)
		print("[IntelligenceSelection] decision accepted apply=override conf=\(cs) fromCache=\(fromCache)")
		return Result(outcome: .overridePrimary(best))
	}

	// MARK: - Logging

	private func logConsideredIfNeeded(
		contextType: ContextType,
		strength: SuggestionStrength,
		actionCount: Int,
		lenBucket: Int
	) {
		let now = Date()
		let sig = "\(contextType.rawValue)|\(strength.rawValue)|\(actionCount)|\(lenBucket)"
		if let p = lastConsideredSig, p == sig, let t = lastConsideredAt, now.timeIntervalSince(t) < 2.0 { return }
		lastConsideredSig = sig
		lastConsideredAt = now
		print("[IntelligenceSelection] considered type=\(contextType.rawValue) strength=\(strength.rawValue) actions=\(actionCount) lenBucket=\(lenBucket)")
	}

	private func logHeuristicKept(reason: String) {
		print("[IntelligenceSelection] heuristic kept reason=\(reason)")
	}

	private static func intelligenceSourceType(triggerType: TriggerType, inputPreference: InputSourceChoice) -> String {
		switch inputPreference {
		case .clipboard:
			return "clipboard"
		case .selectedText:
			return "selected_text"
		case .screenOCR:
			return "screen_ocr"
		case .automatic:
			switch triggerType {
			case .clipboardTextEligible:
				return "clipboard"
			case .selectedTextEligible:
				return "selected_text"
			case .manualInvocation:
				return "manual"
			}
		}
	}
}
