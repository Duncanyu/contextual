import Foundation

/// Runtime integration for T12.6 / T12.6.5: tier order = cache → MicroDecisionEngine (if loaded) → Local LLM fallback.
@MainActor
final class IntelligenceProposalSelector {
	private let budget = IntelligenceBudgetManager()
	private let cache = IntelligenceDecisionCache()
	private let engine = LocalIntelligenceDecisionEngine()

	private var lastConsideredSig: String?
	private var lastConsideredAt: Date?

	private var lastMicroSkipSig: String?
	private var lastMicroSkipAt: Date?

	private static let overrideConfidenceThreshold: Double = 0.78
	private static let suppressConfidenceThreshold: Double = 0.85
	private static let titleConfidenceThreshold: Double = 0.80

	enum Outcome: Equatable {
		case unchanged
		case overridePrimary(String)
		case suppressProposal
	}

	struct Result: Equatable {
		let outcome: Outcome
		let intelligenceTitle: String?
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
		guard !candidateLLMActionIds.isEmpty else { return Result(outcome: .unchanged, intelligenceTitle: nil) }

		let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return Result(outcome: .unchanged, intelligenceTitle: nil) }

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
			return Result(outcome: .unchanged, intelligenceTitle: nil)
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

		// MARK: Step 2 — Cache

		if let cached = cache.lookup(fingerprint: fingerprint, request: request) {
			print("[IntelligenceSelection] cache_hit")
			let r = applyInterpretation(decision: cached, heuristicPrimary: heuristicPrimaryActionId, request: request, fromCache: true, llmTier: false)
			if commitsWithoutLLM(decision: cached, result: r, heuristicPrimary: heuristicPrimaryActionId) {
				print("[IntelligenceSelection] heuristic_kept reason=tier_resolved_cache")
				return r
			}
		}

		// MARK: Step 3 — Micro (sync; only when a real CoreML model is loaded)

		if MicroDecisionModelProvider.shared.isModelLoaded {
			let microReq = MicroDecisionRequest(
				contextType: contextType,
				features: features,
				availableActions: candidateLLMActionIds,
				sourceType: sourceType,
				appName: context.activeAppName,
				windowTitle: context.activeWindowTitle,
				textLength: request.textLength,
				lineCount: request.lineCount,
				compressedText: request.compressedText
			)
			let microRaw = MicroDecisionEngine().decide(request: microReq)
			let microIntel = Self.intelligenceResponse(fromMicro: microRaw)
			if microIntel.isValid(for: request) {
				let r = applyInterpretation(decision: microIntel, heuristicPrimary: heuristicPrimaryActionId, request: request, fromCache: false, llmTier: false)
				if commitsWithoutLLM(decision: microIntel, result: r, heuristicPrimary: heuristicPrimaryActionId) {
					if microIntel.confidence > 0.02 {
						cache.store(decision: microIntel, fingerprint: fingerprint, request: request)
					}
					let c = String(format: "%.2f", min(1.0, max(0.0, microIntel.confidence)))
					print("[MicroDecisionIntegration] used conf=\(c)")
					print("[IntelligenceSelection] heuristic_kept reason=tier_resolved_micro")
					return r
				}
			}
			print("[MicroDecisionIntegration] rejected reason=low_conf_or_unchanged")
		} else {
			logMicroSkippedModelNotLoadedIfNeeded(strength: suggestionStrength, lenBucket: request.textLength / 25)
		}

		// MARK: Step 4 — Local LLM fallback (phi3 path)

		let isModelAvailable = await ModelManager.shared.isGenerationAvailable()

		let budgetDecision = budget.evaluate(
			request: request,
			suggestionStrength: suggestionStrength,
			isActionExecuting: isActionExecuting,
			isModelAvailable: isModelAvailable,
			contextFingerprint: fingerprint
		)

		if !budgetDecision.allowed {
			print("[IntelligenceSelection] llm_fallback_skipped reason=budget_\(budgetDecision.reason)")
			logHeuristicKept(reason: "budget_denied")
			return Result(outcome: .unchanged, intelligenceTitle: nil)
		}

		print("[IntelligenceSelection] llm_fallback_started")

		let decision = await engine.decideWithProposalSelectionDeadline(request: request, suggestionStrength: suggestionStrength)

		if decision.reason == "proposal_llm_timeout" {
			print("[IntelligenceSelection] heuristic_kept reason=timeout")
			return Result(outcome: .unchanged, intelligenceTitle: nil)
		}

		if decision.isValid(for: request), decision.confidence > 0.02 {
			cache.store(decision: decision, fingerprint: fingerprint, request: request)
		}

		return applyInterpretation(decision: decision, heuristicPrimary: heuristicPrimaryActionId, request: request, fromCache: false, llmTier: true)
	}

	// MARK: - Tier resolution

	private func commitsWithoutLLM(decision: IntelligenceDecisionResponse, result: Result, heuristicPrimary: String) -> Bool {
		switch result.outcome {
		case .suppressProposal:
			return true
		case .overridePrimary:
			return true
		case .unchanged:
			if result.intelligenceTitle != nil { return true }
			let c = min(1.0, max(0.0, decision.confidence))
			if decision.shouldSuggest,
			   let best = decision.bestActionId,
			   best == heuristicPrimary,
			   c >= Self.overrideConfidenceThreshold {
				return true
			}
			return false
		}
	}

	private static func intelligenceResponse(fromMicro micro: MicroDecisionResponse) -> IntelligenceDecisionResponse {
		IntelligenceDecisionResponse(
			shouldSuggest: micro.shouldSuggest,
			bestActionId: micro.bestActionId,
			confidence: micro.confidence,
			reason: "micro",
			suggestedTitle: nil
		)
	}

	// MARK: - Interpretation

	private func applyInterpretation(
		decision: IntelligenceDecisionResponse,
		heuristicPrimary: String,
		request: IntelligenceDecisionRequest,
		fromCache: Bool,
		llmTier: Bool = false
	) -> Result {
		guard decision.isValid(for: request) else {
			print("[IntelligenceSelection] decision rejected reason=invalid fromCache=\(fromCache)")
			logHeuristicKept(reason: "invalid")
			if llmTier {
				print("[IntelligenceFallback] reason=invalid_output layer=llm")
				print("[IntelligenceSelection] heuristic_kept reason=invalid_output")
			} else {
				print("[IntelligenceSelection] heuristic_kept reason=invalid_decision")
			}
			return Result(outcome: .unchanged, intelligenceTitle: nil)
		}

		let c = min(1.0, max(0.0, decision.confidence))

		if !decision.shouldSuggest {
			if c >= Self.suppressConfidenceThreshold {
				let cs = String(format: "%.2f", c)
				print("[IntelligenceSelection] decision accepted apply=suppress conf=\(cs) fromCache=\(fromCache)")
				print("[IntelligenceSelection] proposal suppressed")
				return Result(outcome: .suppressProposal, intelligenceTitle: nil)
			}
			print("[IntelligenceSelection] decision rejected reason=low_conf_suggest_false fromCache=\(fromCache)")
			logHeuristicKept(reason: "low_conf")
			print("[IntelligenceTitle] title_kept_heuristic reason=low_conf_decision fromCache=\(fromCache)")
			return Result(outcome: .unchanged, intelligenceTitle: nil)
		}

		guard let best = decision.bestActionId, c >= Self.overrideConfidenceThreshold else {
			print("[IntelligenceSelection] decision rejected reason=low_conf fromCache=\(fromCache)")
			logHeuristicKept(reason: "low_conf")
			print("[IntelligenceTitle] title_kept_heuristic reason=low_conf_decision fromCache=\(fromCache)")
			return Result(outcome: .unchanged, intelligenceTitle: nil)
		}

		let intelTitle = resolveIntelligenceTitle(decision: decision, confidence: c, request: request, fromCache: fromCache)

		if best == heuristicPrimary {
			let cs = String(format: "%.2f", c)
			print("[IntelligenceSelection] decision accepted apply=keep conf=\(cs) fromCache=\(fromCache)")
			logHeuristicKept(reason: "same_primary")
			return Result(outcome: .unchanged, intelligenceTitle: intelTitle)
		}

		let cs = String(format: "%.2f", c)
		print("[IntelligenceSelection] decision accepted apply=override conf=\(cs) fromCache=\(fromCache)")
		return Result(outcome: .overridePrimary(best), intelligenceTitle: intelTitle)
	}

	private func resolveIntelligenceTitle(
		decision: IntelligenceDecisionResponse,
		confidence: Double,
		request: IntelligenceDecisionRequest,
		fromCache: Bool
	) -> String? {
		guard confidence >= Self.titleConfidenceThreshold else {
			print("[IntelligenceTitle] title_kept_heuristic reason=below_title_threshold fromCache=\(fromCache)")
			return nil
		}
		switch IntelligenceProposalTitleValidator.evaluate(decision.suggestedTitle, request: request) {
		case .accepted(let title):
			let cs = String(format: "%.2f", confidence)
			print("[IntelligenceTitle] title_applied fromCache=\(fromCache) conf=\(cs)")
			return title
		case .rejected(let reason):
			print("[IntelligenceTitle] title_rejected reason=\(reason) fromCache=\(fromCache)")
			return nil
		}
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

	private func logMicroSkippedModelNotLoadedIfNeeded(strength: SuggestionStrength, lenBucket: Int) {
		let now = Date()
		let sig = "\(strength.rawValue)|\(lenBucket)"
		if let p = lastMicroSkipSig, p == sig, let t = lastMicroSkipAt, now.timeIntervalSince(t) < 2.5 { return }
		lastMicroSkipSig = sig
		lastMicroSkipAt = now
		print("[MicroDecisionIntegration] skipped reason=model_not_loaded")
		print("[IntelligenceFallback] reason=micro_unavailable layer=micro")
	}

	private func logHeuristicKept(reason: String) {
		print("[IntelligenceSelection] heuristic_kept reason=\(reason)")
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
