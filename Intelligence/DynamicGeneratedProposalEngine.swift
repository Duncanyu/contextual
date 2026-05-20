import Foundation

/// LLM transport for dynamic proposal synthesis (testable, metadata-only logging).
protocol DynamicGeneratedProposalLLMGenerating: Sendable {
	func generate(prompt: String, model: String) async throws -> String
}

extension LocalAIClient: DynamicGeneratedProposalLLMGenerating {}

/// Generation availability gate (injectable for self-tests).
protocol DynamicGeneratedProposalAvailabilityChecking: Sendable {
	func isGenerationAvailable() async -> Bool
}

extension ModelManager: DynamicGeneratedProposalAvailabilityChecking {}

/// LLM-first dynamic generated execution proposal engine (T18.3.1).
/// Two-stage pipeline (T18.3.4): fast decision stage gates whether the large model runs.
actor DynamicGeneratedProposalEngine {

	static let shared = DynamicGeneratedProposalEngine()

	private let modelManager: any DynamicGeneratedProposalAvailabilityChecking
	private let client: any DynamicGeneratedProposalLLMGenerating
	private let decisionEngine: any AgenticProposalDeciding
	private let templateLibrary: any GeneratedActionTemplateLibraryProviding
	private let timeoutNanoseconds: UInt64

	init(
		modelManager: any DynamicGeneratedProposalAvailabilityChecking = ModelManager.shared,
		client: any DynamicGeneratedProposalLLMGenerating = LocalAIClient.shared,
		decisionEngine: any AgenticProposalDeciding = AgenticProposalDecisionEngine.shared,
		templateLibrary: any GeneratedActionTemplateLibraryProviding = GeneratedActionTemplateLibrary.shared,
		timeoutSeconds: TimeInterval = 9
	) {
		self.modelManager = modelManager
		self.client = client
		self.decisionEngine = decisionEngine
		self.templateLibrary = templateLibrary
		self.timeoutNanoseconds = UInt64(max(3, timeoutSeconds) * 1_000_000_000)
		print("[TRACE_INIT] DynamicGeneratedProposalEngine file=\(#file) decisionEngine=\(type(of: decisionEngine)) library=\(type(of: templateLibrary))")
	}

	/// When `false` (default), the live LLM path in this engine is never executed even if reached.
	/// Set to `true` only in explicit debug/test scenarios. T18.3.5A defense-in-depth.
	static var allowLiveLLMForDebug: Bool = false

	func generateProposals(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		existingStaticActions: [String],
		reusableActions: [ReusableGeneratedActionRecord],
		budget: ExecutionBudget = .conservative,
		history: ProposalHistoryMetadata? = nil,
		situational: SituationalContextSnapshot? = nil,
		referenceTime: Date = Date()
	) async -> DynamicGeneratedProposalResult {
		// T18.3.5A: Emit architecture mode on every attempt so traces are always unambiguous.
		print("[ProposalArchitecture] mode=template_library_only live_llm_enabled=no")

		let situationalContext: SituationalContextSnapshot
		if let situational {
			situationalContext = situational
		} else {
			situationalContext = SituationalContextSynthesizer.synthesize(
				from: snapshot,
				referenceTime: referenceTime
			)
			SituationalContextDiagnostics.log(situationalContext)
		}

		// MARK: - Template library lookup (T18.3.5 / T18.3.6B)
		// Runs BEFORE decision gate and BEFORE any LLM call.
		// If eligible seeded templates exist, surface them immediately regardless of perception
		// recommendation — the library is a fast, deterministic path that requires no LLM and
		// no visual context.  Decision gate only matters when the library misses.

		logMetadata(
			event: "pipeline_stage",
			value: "library_lookup",
			extra: "workflow=\(situationalContext.inferredWorkflow.rawValue) perception=\(situationalContext.perceptionRecommendation.rawValue) primary=\(situationalContext.primaryAvailableSource.rawValue)"
		)

		let libraryResult = await templateLibrary.retrieve(
			situational: situationalContext,
			referenceTime: referenceTime
		)

		logMetadata(
			event: "library_lookup_result",
			value: libraryResult.hasMatch ? "hit" : "miss",
			extra: "count=\(libraryResult.records.count) miss_reason=\(libraryResult.missReason?.rawValue ?? "none") workflow=\(situationalContext.inferredWorkflow.rawValue)"
		)

		if libraryResult.hasMatch {
			let records = libraryResult.records
			let titles = records.prefix(3).map(\.title).joined(separator: "|")
			logMetadata(
				event: "template_library_hit",
				value: "\(records.count)",
				extra: "workflow=\(situationalContext.inferredWorkflow.rawValue) source=library top_titles=\(titles)"
			)
			logMetadata(event: "large_model_called", value: "no", extra: "reason=template_library_hit")
			return DynamicGeneratedProposalResult(
				status: .synthesized,
				shouldChimeIn: true,
				reason: "library_hit",
				workflowAssessment: "library_match",
				proposalConfidence: records.map(\.usefulnessScore).max() ?? 0.6,
				requiresVisualContext: false,
				proposals: [],
				warnings: [],
				llmDiagnosticCause: nil,
				createdAt: referenceTime,
				libraryRecords: records
			)
		}

		// MARK: - Two-stage decision gate (T18.3.4 / T18.3.4A)
		// Only consulted after a library miss. The gate decides whether to queue prewarm or
		// recommend more context. The LLM is never called (unreachable in production).

		let decision = await decisionEngine.decide(
			snapshot: snapshot,
			situational: situationalContext,
			referenceTime: referenceTime
		)
		logMetadata(
			event: "decision_stage",
			value: decision.shouldThink ? "think" : (decision.needsMoreContext ? "needs_context" : "quiet"),
			extra: "source=\(decision.decisionSource.rawValue) conf=\(String(format: "%.2f", decision.confidence)) reason=\(decision.reason)"
		)

		// Library missed — queue prewarm then evaluate decision gate for final return code.
		await templateLibrary.enqueuePrewarm(
			situational: situationalContext,
			decision: decision,
			referenceTime: referenceTime
		)
		logMetadata(
			event: "template_library_miss",
			value: libraryResult.missReason?.rawValue ?? "unknown",
			extra: "workflow=\(situationalContext.inferredWorkflow.rawValue) prewarm_queued=yes perception=\(situationalContext.perceptionRecommendation.rawValue)"
		)

		if !decision.shouldThink {
			logMetadata(event: "large_model_called", value: "no", extra: "reason=\(decision.reason)")
			if decision.needsMoreContext {
				let contextKind = decision.recommendedContextKind.rawValue
				let tag = decision.recommendedContextKind == .visual
					? "diag:decision_needs_more_context:visual"
					: "diag:decision_needs_more_context:\(contextKind)"
				logMetadata(
					event: "library_miss_gate_result",
					value: "needs_more_context",
					extra: "kind=\(contextKind) miss_reason=\(libraryResult.missReason?.rawValue ?? "unknown")"
				)
				return result(
					status: .quietByGate,
					reason: "needs_more_context",
					warnings: [tag],
					cause: nil,
					referenceTime: referenceTime
				)
			}
			let tag = decision.reason == "timeout_cooldown"
				? "diag:decision_timeout_cooldown"
				: "diag:decision_quiet"
			logMetadata(event: "library_miss_gate_result", value: "quiet", extra: "reason=\(decision.reason)")
			return result(
				status: .quietByGate,
				reason: decision.reason,
				warnings: [tag],
				cause: nil,
				referenceTime: referenceTime
			)
		}

		logMetadata(event: "large_model_called", value: "no", extra: "reason=no_template_in_library")
		logMetadata(event: "library_miss_gate_result", value: "no_template", extra: "prewarm_already_queued=yes")
		return result(
			status: .quietByGate,
			reason: "no_template_in_library",
			warnings: ["diag:no_template_in_library"],
			cause: nil,
			referenceTime: referenceTime
		)

		// Decision approved — check preflight conditions before committing to LLM.
		// NOTE: The code below is preserved but currently unreachable (library miss returns above).
		// It will be re-enabled when the prewarm-to-LLM path is introduced (T18.3.6+).
		//
		// T18.3.5A: Hard gate — if this point is somehow reached, refuse to call LLM unless
		// allowLiveLLMForDebug is explicitly set (never true in production).
		guard DynamicGeneratedProposalEngine.allowLiveLLMForDebug else {
			print("[ARCHITECTURE ERROR] DynamicGeneratedProposalEngine reached live LLM path — expected library-only mode (T18.3.5A). Suppressing call.")
			assertionFailure("[ARCHITECTURE ERROR] DynamicGeneratedProposalEngine reached live LLM path — expected library-only mode (T18.3.5A).")
			return result(
				status: .quietByGate,
				reason: "architecture_error_live_llm_suppressed",
				warnings: ["diag:architecture_error_live_llm_suppressed"],
				cause: nil,
				referenceTime: referenceTime
			)
		}

		if let gate = preflightGate(
			snapshot: snapshot,
			situational: situationalContext,
			history: history,
			referenceTime: referenceTime
		) {
			logMetadata(event: "large_model_called", value: "no", extra: "reason=\(gate.reason)")
			return gate
		}

		guard LocalAISettings.shared.localAIEnabled else {
			logMetadata(event: "large_model_called", value: "no", extra: "reason=local_ai_disabled")
			return .unavailable(reason: "local_ai_disabled", cause: .modelUnavailable)
		}

		guard await modelManager.isGenerationAvailable() else {
			if ModelManager.shared.isWithinStartupGrace() {
				logMetadata(event: "large_model_called", value: "no", extra: "reason=startup_grace")
				return .unavailable(reason: "startup_grace", cause: .startupGrace)
			}
			logMetadata(event: "large_model_called", value: "no", extra: "reason=model_unavailable")
			return .unavailable(reason: "model_unavailable", cause: .modelUnavailable)
		}

		// Large model approved by decision stage.

		let prompt = DynamicGeneratedProposalPromptBuilder.build(
			snapshot: snapshot,
			existingStaticActions: existingStaticActions,
			reusableCount: reusableActions.count,
			history: history,
			budget: budget,
			situational: situationalContext
		)

		let model = LocalAISettings.shared.modelName
		logMetadata(event: "large_model_called", value: "yes", extra: "model=\(model) prompt_bytes=\(prompt.utf8.count)")
		logMetadata(event: "llm_generation_started", value: model, extra: "prompt_bytes=\(prompt.utf8.count)")
		// T18.3.5A: This line must never be reached in production (library-only mode).
		// If the app doesn't crash here → wrong file is executing.
		fatalError("[TRACE] LEGACY LIVE LLM PATH STILL ACTIVE — DynamicGeneratedProposalEngine.swift is not being compiled from the expected source. file=\(#file)")

		let generationStart = Date()
		let raw: String
		do {
			raw = try await withTimeout {
				try await self.client.generate(prompt: prompt, model: model)
			}
		} catch is CancellationError {
			logMetadata(event: "llm_generation_cancelled", value: "1", extra: "cause=context_cancelled")
			return result(
				status: .cancelled,
				reason: "cancelled",
				warnings: ["context_cancelled"],
				cause: .contextCancelled,
				referenceTime: referenceTime
			)
		} catch let err as DynamicGeneratedProposalEngineError {
			switch err {
			case .appTimeout:
				// Record fingerprint so next cycle for this context is skipped by decision stage.
				let fp = AgenticProposalDecisionEngine.contextFingerprint(
					snapshot: snapshot,
					situational: situationalContext
				)
				await decisionEngine.recordTimeout(fingerprint: fp, at: referenceTime)
				logMetadata(event: "llm_generation_timeout", value: "1", extra: "cause=app_timeout fingerprint_recorded=yes")
				return result(
					status: .timeout,
					reason: "app_timeout",
					warnings: ["app_timeout"],
					cause: .appTimeout,
					referenceTime: referenceTime
				)
			}
		} catch {
			let elapsed = Date().timeIntervalSince(generationStart)
			let cause: DynamicGeneratedProposalLLMDiagnosticCause = elapsed < 2.5 ? .clientFailed : .responseTooSlow
			logMetadata(
				event: "llm_generation_failed",
				value: "1",
				extra: "cause=\(cause.rawValue) elapsed_ms=\(Int(elapsed * 1000))"
			)
			return .unavailable(reason: cause.rawValue, cause: cause)
		}

		#if DEBUG
		if ProcessInfo.processInfo.environment["CONTEXTUAL_DEBUG_LLM_OUTPUT"] == "1" {
			let preview = String(raw.prefix(300))
			logMetadata(event: "debug_llm_output", value: "1", extra: "preview=\(preview)")
		}
		#endif

		let (parsed, hardFailTag) = DynamicGeneratedProposalParser.parseWithReason(from: raw, referenceTime: referenceTime)
		guard let parsed else {
			// Parser logs byte bucket, extraction result, and alias diagnostics via parser_diag.
			logMetadata(
				event: "llm_parse_failed",
				value: "1",
				extra: "cause=malformed_response bytes=\(raw.utf8.count)"
			)
			return result(
				status: .parseFailed,
				reason: "parse_failed",
				warnings: [hardFailTag ?? "diag:parse_failed"],
				cause: .malformedResponse,
				referenceTime: referenceTime
			)
		}

		let filtered = filterRepetitive(parsed: parsed, history: history)
		logMetadata(
			event: "llm_generated_proposals_count",
			value: "\(filtered.proposals.count)",
			extra: "should_chime_in=\(filtered.shouldChimeIn)"
		)
		logMetadata(event: "llm_should_chime_in", value: filtered.shouldChimeIn ? "true" : "false", extra: nil)
		if filtered.shouldChimeIn, let top = filtered.proposals.first {
			logMetadata(event: "proposal_promoted_reason", value: top.usefulnessHint, extra: "title_len=\(top.title.count)")
		}
		return filtered
	}

	// MARK: - Gates

	private func preflightGate(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		history: ProposalHistoryMetadata?,
		referenceTime: Date
	) -> DynamicGeneratedProposalResult? {
		let hasText = situational.selectedTextSignal.availability == .available
			|| situational.ocrSignal.availability == .available
		let hasWorkflow = situational.inferredWorkflow != .unknown && situational.workflowConfidence >= 0.35
		let hasMetadata = situational.primaryAvailableSource == .metadataOnly
			|| situational.primaryAvailableSource == .workflowApp
			|| !snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let metadataOnlyUsable = situational.primaryAvailableSource == .metadataOnly
			&& situational.contextFreshness >= 0.28
		let fusedStale = snapshot.fusedPacketId != nil && snapshot.packetIsStale
		let freshEnough = situational.contextFreshness >= 0.28 && (!fusedStale || metadataOnlyUsable)

		if !hasText && !hasWorkflow && !hasMetadata {
			return DynamicGeneratedProposalResult(
				status: .quietByGate,
				shouldChimeIn: false,
				reason: "no_fused_context",
				workflowAssessment: "",
				proposalConfidence: 0,
				requiresVisualContext: false,
				proposals: [],
				warnings: ["no_fused_context"],
				llmDiagnosticCause: nil,
				createdAt: referenceTime,
				libraryRecords: []
			)
		}
		if !freshEnough && !hasText && !hasMetadata && !metadataOnlyUsable {
			return DynamicGeneratedProposalResult(
				status: .quietByGate,
				shouldChimeIn: false,
				reason: "stale_context",
				workflowAssessment: "",
				proposalConfidence: 0,
				requiresVisualContext: false,
				proposals: [],
				warnings: ["stale_context"],
				llmDiagnosticCause: nil,
				createdAt: referenceTime,
				libraryRecords: []
			)
		}

		if let history, let dismissedAt = history.lastDismissedAt,
		   referenceTime.timeIntervalSince(dismissedAt) < 30
		{
			return DynamicGeneratedProposalResult(
				status: .quietByGate,
				shouldChimeIn: false,
				reason: "post_dismiss_cooldown",
				workflowAssessment: "",
				proposalConfidence: 0,
				requiresVisualContext: false,
				proposals: [],
				warnings: ["post_dismiss_cooldown"],
				llmDiagnosticCause: nil,
				createdAt: referenceTime,
				libraryRecords: []
			)
		}

		return nil
	}

	private func filterRepetitive(
		parsed: DynamicGeneratedProposalResult,
		history: ProposalHistoryMetadata?
	) -> DynamicGeneratedProposalResult {
		guard let history else { return parsed }
		let dismissed = history.recentDismissedCandidateIds
		let recentTitles = Set(history.recentProposalTitles.map { $0.lowercased() })

		let kept = parsed.proposals.filter { proposal in
			if dismissed.contains(proposal.id) { return false }
			if recentTitles.contains(proposal.title.lowercased()) { return false }
			return true
		}

		return DynamicGeneratedProposalResult(
			status: parsed.status,
			shouldChimeIn: parsed.shouldChimeIn && !kept.isEmpty,
			reason: parsed.reason,
			workflowAssessment: parsed.workflowAssessment,
			proposalConfidence: parsed.proposalConfidence,
			requiresVisualContext: parsed.requiresVisualContext,
			proposals: kept,
			warnings: parsed.warnings + (kept.count < parsed.proposals.count ? ["repetition_filtered"] : []),
			llmDiagnosticCause: parsed.llmDiagnosticCause,
			createdAt: parsed.createdAt,
			libraryRecords: []
		)
	}

	private func result(
		status: DynamicGeneratedProposalSynthesisStatus,
		reason: String,
		warnings: [String],
		cause: DynamicGeneratedProposalLLMDiagnosticCause?,
		referenceTime: Date
	) -> DynamicGeneratedProposalResult {
		DynamicGeneratedProposalResult(
			status: status,
			shouldChimeIn: false,
			reason: reason,
			workflowAssessment: "",
			proposalConfidence: 0,
			requiresVisualContext: false,
			proposals: [],
			warnings: warnings,
			llmDiagnosticCause: cause,
			createdAt: referenceTime,
			libraryRecords: []
		)
	}

	// MARK: - Timeout

	private enum DynamicGeneratedProposalEngineError: Error, Equatable {
		case appTimeout
	}

	private func withTimeout(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
		try await withThrowingTaskGroup(of: String.self) { group in
			group.addTask {
				try await operation()
			}
			group.addTask {
				try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
				throw DynamicGeneratedProposalEngineError.appTimeout
			}
			guard let first = try await group.next() else {
				throw DynamicGeneratedProposalEngineError.appTimeout
			}
			group.cancelAll()
			return first
		}
	}

	private func logMetadata(event: String, value: String, extra: String?) {
		if let extra, !extra.isEmpty {
			print("[DynamicGeneratedProposal] \(event)=\(value) \(extra)")
		} else {
			print("[DynamicGeneratedProposal] \(event)=\(value)")
		}
	}
}
