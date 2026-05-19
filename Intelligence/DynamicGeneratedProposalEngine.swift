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
actor DynamicGeneratedProposalEngine {

	static let shared = DynamicGeneratedProposalEngine()

	private let modelManager: any DynamicGeneratedProposalAvailabilityChecking
	private let client: any DynamicGeneratedProposalLLMGenerating
	private let timeoutNanoseconds: UInt64

	init(
		modelManager: any DynamicGeneratedProposalAvailabilityChecking = ModelManager.shared,
		client: any DynamicGeneratedProposalLLMGenerating = LocalAIClient.shared,
		timeoutSeconds: TimeInterval = 12
	) {
		self.modelManager = modelManager
		self.client = client
		self.timeoutNanoseconds = UInt64(max(3, timeoutSeconds) * 1_000_000_000)
	}

	func generateProposals(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		existingStaticActions: [String],
		reusableActions: [ReusableGeneratedActionRecord],
		budget: ExecutionBudget = .conservative,
		history: ProposalHistoryMetadata? = nil,
		situational: SituationalContextSnapshot? = nil,
		referenceTime: Date = Date()
	) async -> DynamicGeneratedProposalResult {
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

		if let gate = preflightGate(
			snapshot: snapshot,
			situational: situationalContext,
			history: history,
			referenceTime: referenceTime
		) {
			logMetadata(event: "llm_should_chime_in", value: "false", extra: "reason=\(gate.reason)")
			return gate
		}

		guard await modelManager.isGenerationAvailable() else {
			logMetadata(event: "llm_generation_skipped", value: "model_unavailable", extra: nil)
			return .unavailable(reason: "model_unavailable")
		}

		let prompt = DynamicGeneratedProposalPromptBuilder.build(
			snapshot: snapshot,
			existingStaticActions: existingStaticActions,
			reusableCount: reusableActions.count,
			history: history,
			budget: budget,
			situational: situationalContext
		)

		let model = LocalAISettings.shared.modelName
		logMetadata(event: "llm_generation_started", value: model, extra: "prompt_bytes=\(prompt.utf8.count)")

		let raw: String?
		do {
			raw = try await withTimeout {
				try await self.client.generate(prompt: prompt, model: model)
			}
		} catch is CancellationError {
			logMetadata(event: "llm_generation_cancelled", value: "1", extra: nil)
			return DynamicGeneratedProposalResult(
				status: .cancelled,
				shouldChimeIn: false,
				reason: "cancelled",
				workflowAssessment: "",
				proposalConfidence: 0,
				requiresVisualContext: false,
				proposals: [],
				warnings: ["cancelled"],
				createdAt: referenceTime
			)
		} catch let err as DynamicGeneratedProposalEngineError where err == .timeout {
			logMetadata(event: "llm_generation_timeout", value: "1", extra: nil)
			return DynamicGeneratedProposalResult(
				status: .timeout,
				shouldChimeIn: false,
				reason: "timeout",
				workflowAssessment: "",
				proposalConfidence: 0,
				requiresVisualContext: false,
				proposals: [],
				warnings: ["timeout"],
				createdAt: referenceTime
			)
		} catch {
			logMetadata(event: "llm_generation_failed", value: "1", extra: nil)
			return .unavailable(reason: "generate_failed")
		}

		guard let raw else {
			return .unavailable(reason: "empty_response")
		}

		guard let parsed = DynamicGeneratedProposalParser.parse(from: raw, referenceTime: referenceTime) else {
			logMetadata(event: "llm_parse_failed", value: "1", extra: nil)
			return DynamicGeneratedProposalResult(
				status: .parseFailed,
				shouldChimeIn: false,
				reason: "parse_failed",
				workflowAssessment: "",
				proposalConfidence: 0,
				requiresVisualContext: false,
				proposals: [],
				warnings: ["parse_failed"],
				createdAt: referenceTime
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
				createdAt: referenceTime
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
				createdAt: referenceTime
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
				createdAt: referenceTime
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
			createdAt: parsed.createdAt
		)
	}

	// MARK: - Timeout

	private enum DynamicGeneratedProposalEngineError: Error, Equatable {
		case timeout
	}

	private func withTimeout(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
		try await withThrowingTaskGroup(of: String.self) { group in
			group.addTask {
				try await operation()
			}
			group.addTask {
				try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
				throw DynamicGeneratedProposalEngineError.timeout
			}
			guard let first = try await group.next() else {
				throw DynamicGeneratedProposalEngineError.timeout
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
