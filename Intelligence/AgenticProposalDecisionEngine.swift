import Foundation

/// Fast decision layer: decides whether the large LLM should run this cycle (T18.3.4).
///
/// Responsibilities:
/// - Stay quiet when context is weak or unclear.
/// - Recommend more context (visual/text) when needed rather than handing off to a slow LLM.
/// - Apply timeout fingerprint cooldowns so a recently-timed-out context isn't retried on every tab hop.
/// - Wrap the MicroDecisionEngine conservatively when available.
///
/// No LLM calls. No proposal JSON generation. No action execution.
actor AgenticProposalDecisionEngine {

	static let shared = AgenticProposalDecisionEngine()

	private var timeoutCooldowns: [String: Date] = [:]
	private var timeoutCooldownDuration: TimeInterval {
		AgenticPivot.useEarlierProposalSurfacing ? 15 : 45
	}
	private let microEngine = MicroDecisionEngine()

	// MARK: - Public API

	func decide(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date = Date()
	) -> AgenticProposalDecision {
		let fingerprint = Self.contextFingerprint(snapshot: snapshot, situational: situational)

		// 1. Timeout cooldown: skip if this context fingerprint recently caused a large-model timeout.
		if let timedOutAt = timeoutCooldowns[fingerprint],
		   referenceTime.timeIntervalSince(timedOutAt) < timeoutCooldownDuration
		{
			let elapsed = Int(referenceTime.timeIntervalSince(timedOutAt))
			log(event: "decision_stage", value: "timeout_cooldown", extra: "elapsed_s=\(elapsed) fingerprint=\(fingerprint)")
			return .quiet(reason: "timeout_cooldown")
		}

		// 2. Signal quality flags.
		let hasText = (AgenticPivot.isSelectedTextInfluenceEnabled && situational.selectedTextSignal.availability == .available)
			|| situational.ocrSignal.availability == .available
		let hasClipboard = AgenticPivot.isClipboardInfluenceEnabled 
			&& situational.clipboardSignal.availability == .available
			&& situational.clipboardSignal.canBePrimary
		let hasWorkflow = situational.inferredWorkflow != .unknown && situational.workflowConfidence >= 0.35
		let hasMetadata = !snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			|| situational.primaryAvailableSource == .workflowApp
			|| situational.primaryAvailableSource == .metadataOnly

		// 3. Visual / more-context recommendation: don't waste large model on missing context.
		let perceptionNeeded = situational.perceptionRecommendation == .recommended
			|| situational.perceptionRecommendation == .requiredBeforeSpecificProposal
		if perceptionNeeded && !hasText && !hasClipboard {
			log(event: "decision_stage", value: "needs_visual",
				extra: "perception=\(situational.perceptionRecommendation.rawValue) workflow=\(situational.inferredWorkflow.rawValue)")
			return .needsContext(kind: .visual, reason: "visual_context_recommended")
		}

		// 4. Hard floor: no useful signal at all.
		if !hasText && !hasClipboard && !hasWorkflow && !hasMetadata {
			log(event: "decision_stage", value: "quiet",
				extra: "reason=no_useful_signal freshness=\(String(format: "%.2f", situational.contextFreshness))")
			return .quiet(reason: "no_useful_signal")
		}

		// 4b. Metadata-only without content: recommend visual context rather than calling the large model.
		if !hasText && !hasClipboard && hasMetadata && !hasWorkflow {
			log(event: "decision_stage", value: "needs_context",
				extra: "reason=metadata_only_weak_workflow workflow_conf=\(String(format: "%.2f", situational.workflowConfidence))")
			return .needsContext(kind: .visual, reason: "metadata_only_weak_workflow")
		}

		// 5. Try micro model as a fast suppression signal (classification-only, wrapped conservatively).
		if let microDecision = tryMicroDecision(situational: situational) {
			log(event: "decision_stage", value: microDecision.shouldThink ? "think" : "quiet",
				extra: "source=micro_model conf=\(String(format: "%.2f", microDecision.confidence)) reason=\(microDecision.reason)")
			return microDecision
		}

		// 6. Heuristic fallback.
		let hasContent = hasText || hasClipboard
		let hasRichWorkflow = hasWorkflow && hasMetadata && situational.workflowConfidence >= 0.60
		let shouldThink = hasContent || hasRichWorkflow
		let confidence = heuristicConfidence(
			situational: situational,
			hasText: hasText,
			hasClipboard: hasClipboard,
			hasWorkflow: hasWorkflow
		)
		let interruptionCost: Double = hasText ? 0.3 : (hasClipboard ? 0.4 : 0.55)
		let reason = shouldThink ? "heuristic_ok" : "heuristic_quiet"

		log(event: "decision_stage", value: shouldThink ? "think" : "quiet",
			extra: "source=heuristic conf=\(String(format: "%.2f", confidence)) has_text=\(hasText) has_clipboard=\(hasClipboard) has_workflow=\(hasWorkflow) rich_workflow=\(hasRichWorkflow)")

		return AgenticProposalDecision(
			shouldThink: shouldThink,
			shouldChimeIn: shouldThink && confidence >= 0.45,
			needsMoreContext: false,
			recommendedContextKind: .none,
			workflowType: situational.inferredWorkflow,
			intentType: situational.inferredIntent,
			confidence: confidence,
			interruptionCost: interruptionCost,
			reason: reason,
			decisionSource: .heuristic
		)
	}

	/// Records that a large-model timeout occurred for this context fingerprint.
	/// Subsequent calls with the same fingerprint within `cooldownDuration` will be skipped.
	func recordTimeout(fingerprint: String, at time: Date) {
		timeoutCooldowns[fingerprint] = time
		// Prune entries older than 2× the cooldown to avoid unbounded growth.
		let cutoff = time.addingTimeInterval(-timeoutCooldownDuration * 2)
		timeoutCooldowns = timeoutCooldowns.filter { $0.value > cutoff }
		log(event: "timeout_fingerprint_recorded", value: fingerprint, extra: "cooldown_s=\(Int(timeoutCooldownDuration))")
	}

	/// Privacy-safe fingerprint for timeout tracking (no raw text, no OCR payloads).
	nonisolated static func contextFingerprint(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> String {
		"\(snapshot.activeApp)|\(situational.inferredWorkflow.rawValue)|\(situational.primaryAvailableSource.rawValue)"
	}

	// MARK: - Private

	private func tryMicroDecision(situational: SituationalContextSnapshot) -> AgenticProposalDecision? {
		// Use situational summary as a privacy-safe compressed representation.
		let compressedText = situational.situationalSummary
		guard compressedText.count >= 30 else { return nil }
		guard situational.primaryAvailableSource != .none else { return nil }

		let estimatedLen = estimatedTextLength(from: situational)
		let features = ContextFeatures(
			textLength: estimatedLen,
			wordCount: max(1, estimatedLen / 5),
			sentenceCount: max(1, estimatedLen / 80),
			punctuationDensity: 0.04,
			hasQuestion: false,
			isLikelyCode: situational.inferredWorkflow == .debugging,
			isLikelyLog: situational.inferredWorkflow == .debugging,
			lineCount: max(1, estimatedLen / 80),
			averageLineLength: 60,
			repetitionScore: 0
		)

		let request = MicroDecisionRequest(
			contextType: contextType(from: situational),
			features: features,
			availableActions: ["llm_dynamic"],
			sourceType: situational.primaryAvailableSource.rawValue,
			appName: situational.activeAppName,
			windowTitle: situational.windowTitle,
			textLength: compressedText.count,
			lineCount: max(1, compressedText.count / 80),
			compressedText: compressedText
		)

		let response = microEngine.decide(request: request)
		// Only use micro output when it is confident enough; otherwise fall through to heuristics.
		guard response.confidence >= 0.65 else { return nil }

		return AgenticProposalDecision(
			shouldThink: response.shouldSuggest,
			shouldChimeIn: response.shouldSuggest,
			needsMoreContext: false,
			recommendedContextKind: .none,
			workflowType: situational.inferredWorkflow,
			intentType: situational.inferredIntent,
			confidence: response.confidence,
			interruptionCost: response.shouldSuggest ? 0.35 : 0,
			reason: response.shouldSuggest ? "micro_suggest" : "micro_quiet",
			decisionSource: .microModel
		)
	}

	private func heuristicConfidence(
		situational: SituationalContextSnapshot,
		hasText: Bool,
		hasClipboard: Bool,
		hasWorkflow: Bool
	) -> Double {
		var score = 0.0
		if hasText { score += 0.4 }
		if hasClipboard { score += 0.25 }
		if hasWorkflow { score += 0.2 }
		score += situational.contextFreshness * 0.15
		
		// Part 1 Pivot: boost workflow confidence if transient sources are disabled
		if !AgenticPivot.isClipboardInfluenceEnabled && !AgenticPivot.isSelectedTextInfluenceEnabled && hasWorkflow {
			score += 0.2
		}
		
		return min(1.0, score)
	}

	private func estimatedTextLength(from situational: SituationalContextSnapshot) -> Int {
		let textBucket = AgenticPivot.isSelectedTextInfluenceEnabled ? situational.selectedTextSignal.lengthBucket : .none
		let clipBucket = AgenticPivot.isClipboardInfluenceEnabled ? situational.clipboardSignal.lengthBucket : .none
		let ocrBucket = situational.ocrSignal.lengthBucket
		let best = [textBucket, clipBucket, ocrBucket]
			.max(by: { bucketOrdinal($0) < bucketOrdinal($1) }) ?? .none
		return bucketMidpoint(best)
	}

	private func bucketOrdinal(_ b: SituationalLengthBucket) -> Int {
		switch b {
		case .none: return 0; case .tiny: return 1; case .small: return 2
		case .medium: return 3; case .large: return 4; case .huge: return 5
		}
	}

	private func bucketMidpoint(_ b: SituationalLengthBucket) -> Int {
		switch b {
		case .none: return 0; case .tiny: return 20; case .small: return 80
		case .medium: return 260; case .large: return 800; case .huge: return 1600
		}
	}

	private func contextType(from situational: SituationalContextSnapshot) -> ContextType {
		switch situational.inferredWorkflow {
		case .debugging: return .errorLog
		case .research, .browsing: return .article
		case .writing, .editing, .reviewing: return .notes
		case .unknown: return .random
		}
	}

	private func log(event: String, value: String, extra: String?) {
		if let extra {
			print("[AgenticDecision] \(event)=\(value) \(extra)")
		} else {
			print("[AgenticDecision] \(event)=\(value)")
		}
	}
}
