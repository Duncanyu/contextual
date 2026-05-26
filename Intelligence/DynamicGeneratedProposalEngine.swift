import Foundation

/// LLM transport for dynamic proposal synthesis (testable, metadata-only logging).
protocol DynamicGeneratedProposalLLMGenerating: Sendable {
	func generate(prompt: String, model: String) async throws -> String
}

// MARK: - Task inference title memory (metadata-only; no hardcoded behavior labels)

private struct TaskInferenceTitleObservation: Sendable, Equatable {
	let title: String
	let capturedAt: Date
}

extension LocalAIClient: DynamicGeneratedProposalLLMGenerating {}

/// Generation availability gate (injectable for self-tests).
protocol DynamicGeneratedProposalAvailabilityChecking: Sendable {
	func isGenerationAvailable() async -> Bool
}

extension ModelManager: DynamicGeneratedProposalAvailabilityChecking {}

/// Injectable visual context scheduler abstraction (enables deterministic tests).
protocol VisualContextScheduling: Sendable {
	func collect(
		request: BoundedVisualContextRequest,
		budgetSnapshot: GeneratedExecutionBudgetSnapshot
	) async -> BoundedVisualContextResult
}

extension VisualContextScheduler: VisualContextScheduling {}

/// LLM-first dynamic generated execution proposal engine (T18.3.1).
/// Two-stage pipeline (T18.3.4): fast decision stage gates whether the large model runs.
actor DynamicGeneratedProposalEngine {

	static let shared = DynamicGeneratedProposalEngine(
		visualScheduler: VisualContextScheduler(provider: ScreenCaptureBoundedVisualContextProvider())
	)

	private let modelManager: any DynamicGeneratedProposalAvailabilityChecking
	private let client: any DynamicGeneratedProposalLLMGenerating
	private let decisionEngine: any AgenticProposalDeciding
	private let templateLibrary: any GeneratedActionTemplateLibraryProviding
	private let visualScheduler: (any VisualContextScheduling)?
	private let sparseVisualPeekGate: SparseVisualPeekGate
	private let timeoutNanoseconds: UInt64
	private var autoVisualGatheredAtByFingerprint: [String: Date] = [:]
	/// Model-requested context escalation tracker — separate from auto-visual-gather.
	/// Keyed by context fingerprint; value is the timestamp of the last escalation attempt.
	/// Prevents repeated escalation on the same page/context even if auto-gather recently ran.
	private var contextEscalatedAtByFingerprint: [String: Date] = [:]
	// Task inference: short-lived title memory (feature input only; not hardcoded behaviors).
	private var titleHistoryByBundle: [String: [TaskInferenceTitleObservation]] = [:]
	// Task inference: short-lived cache of previously successful action contracts (accelerator only).
	private var dynamicActionCacheByKey: [String: DynamicGeneratedActionContract] = [:]
	// Phase 4R — Strong context anchor (in-memory) to avoid transient weak browser titles
	// (profile/account/settings) overwriting a recently-seen strong page context.
	private var strongContextAnchor: StrongContextAnchor?

	private static var autoVisualGatherCooldownSeconds: TimeInterval {
		AgenticPivot.useEarlierProposalSurfacing ? 30 : 70
	}
	/// Model-requested escalation is allowed once per fingerprint per this window.
	/// Shorter than auto-gather so it fires for new pages even if auto-gather ran recently.
	private static var contextEscalationCooldownSeconds: TimeInterval {
		AgenticPivot.useEarlierProposalSurfacing ? 45 : 90
	}
	private static let titleHistoryMaxItems = 12
	private static let dynamicActionCacheTTLSeconds: TimeInterval = 180

	init(
		modelManager: any DynamicGeneratedProposalAvailabilityChecking = ModelManager.shared,
		client: any DynamicGeneratedProposalLLMGenerating = LocalAIClient.shared,
		decisionEngine: any AgenticProposalDeciding = AgenticProposalDecisionEngine.shared,
		templateLibrary: any GeneratedActionTemplateLibraryProviding = GeneratedActionTemplateLibrary.shared,
		visualScheduler: (any VisualContextScheduling)? = nil,
		timeoutSeconds: TimeInterval = 9
	) {
		self.modelManager = modelManager
		self.client = client
		self.decisionEngine = decisionEngine
		self.templateLibrary = templateLibrary
		self.visualScheduler = visualScheduler
		self.sparseVisualPeekGate = SparseVisualPeekGate()
		self.timeoutNanoseconds = UInt64(max(3, timeoutSeconds) * 1_000_000_000)
		#if DEBUG
		if ProposalLoggingFlags.traceInitEnabled {
			print("[TRACE_INIT] DynamicGeneratedProposalEngine file=\(#file) decisionEngine=\(type(of: decisionEngine)) library=\(type(of: templateLibrary))")
		}
		#endif
	}

	/// When `false` (default), the live LLM path in this engine is never executed even if reached.
	/// Set to `true` only in explicit debug/test scenarios. T18.3.5A defense-in-depth.
	static var allowLiveLLMForDebug: Bool = false

	/// Records a successful hook-composed execution as a short-lived cache entry (accelerator only).
	/// This is intentionally NOT used as a source of truth; it simply helps avoid re-composing the
	/// exact same action contract during rapid tab/app churn after the user accepted it.
	func recordSuccessfulDynamicActionExecution(
		candidateId: String,
		action: GeneratedExecutionAction,
		referenceTime: Date = Date()
	) {
		guard candidateId.hasPrefix("hook:") else { return }
		let rawKey = String(candidateId.dropFirst("hook:".count))
		guard !rawKey.isEmpty else { return }
		let keyBase = rawKey.components(separatedBy: "|h").first ?? rawKey

		let hookIds = HookCapabilityRegistry.hookIds(from: action.executionPlan.primitives)
		let contract = DynamicGeneratedActionContract(
			id: candidateId,
			title: action.title,
			userFacingQuestion: action.description,
			inferredUserGoal: action.intentType.rawValue,
			situationSummary: "cached_execution_success",
			whyNow: "cached_successful_execution",
			hookPlanIds: hookIds,
			requiredContext: action.requiredContextTypes,
			confidence: min(0.92, max(0.50, action.confidence + 0.04)),
			createdAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(120),
			cacheEligibility: true,
			cacheKey: keyBase
		)

		dynamicActionCacheByKey[keyBase] = contract
		pruneDynamicActionCache(referenceTime: referenceTime)
		print(
			"[DynamicActionSynthesis] cache_stored id=\(candidateId.prefix(48)) hooks=\(hookIds.joined(separator: ","))"
		)
	}

	func generateProposals(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		existingStaticActions: [String],
		reusableActions: [ReusableGeneratedActionRecord],
		budget: ExecutionBudget = .conservative,
		history: ProposalHistoryMetadata? = nil,
		situational: SituationalContextSnapshot? = nil,
		referenceTime: Date = Date(),
		isWarmupReady: Bool = true
	) async -> DynamicGeneratedProposalResult {
		// Emit active architecture mode on every attempt so traces are always unambiguous.
		let fallback = ProposalLoggingFlags.templateFallbackEnabled ? "yes" : "no"
		print("[ProposalArchitecture] mode=task_inference_hooks live_llm_enabled=no template_fallback_enabled=\(fallback)")

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

		// MARK: - Strong context preservation (Phase 4R)
		// Preserve a recently-seen strong page title + OCR excerpt when the current browser
		// title becomes weak/transient (profile/account/settings) or OCR becomes code-like.
		let anchored = applyStrongContextAnchorIfNeeded(
			snapshot: snapshot,
			situational: situationalContext,
			referenceTime: referenceTime
		)

		// MARK: - Automatic bounded visual context enrichment (T18.3.7B)
		// When context is metadata-only and perception says visual is useful/recommended, attempt a
		// single bounded visual peek BEFORE library retrieval. This is gated (cooldown, permission,
		// budget, thermal) and never loops/polls. If denied, continue with metadata-only proposals.

		var effectiveSnapshot = anchored.snapshot
		var effectiveSituational = anchored.situational
		if shouldAttemptAutoVisualGather(
			snapshot: effectiveSnapshot,
			situational: effectiveSituational,
			referenceTime: referenceTime
		) {
			let fingerprint = Self.autoVisualGatherFingerprint(snapshot: effectiveSnapshot, situational: effectiveSituational)
			if shouldAttemptAutoVisualGatherForFingerprint(fingerprint, referenceTime: referenceTime) {
				recordAutoVisualGatherAttempt(fingerprint, at: referenceTime)
				let workflow = effectiveSituational.inferredWorkflow.rawValue
				print(
					"[VisualContextGathering] requested reason=metadata_only_perception_recommended workflow=\(workflow) fp=\(fingerprint)"
				)

				let gateEval = await sparseVisualPeekGate.evaluate(
					snapshot: effectiveSnapshot,
					referenceTime: referenceTime
				)
				if gateEval.shouldDeny {
					print(
						"[VisualContextGathering] denied reason=\(gateEval.denyReason?.rawValue ?? "gate") fp=\(fingerprint)"
					)
				} else {
					let peekDecision = SparseVisualPeekPolicy.shouldRequestVisualPeek(
						snapshot: effectiveSnapshot,
						action: nil,
						explicitManualRequest: false,
						gateEvaluation: gateEval,
						referenceTime: referenceTime
					)
					if !peekDecision.shouldPeek || peekDecision.recommendedRequest == nil {
						print(
							"[VisualContextGathering] denied reason=\(peekDecision.denyReason?.rawValue ?? "policy") fp=\(fingerprint)"
						)
					} else {
						let wf = WorkflowExecutionMapper.workflowType(from: effectiveSituational.inferredWorkflow)
						let intent: IntentType = {
							if let it = effectiveSituational.inferredIntent {
								return WorkflowExecutionMapper.intentType(from: it)
							}
							return .unknown
						}()
						let autoBudget = ExecutionBudget(
							maxCPUPercent: 30,
							maxConcurrentTasks: 1,
							maxExecutionTime: 18,
							allowsVision: true,
							allowsOCR: true,
							allowsLLM: false,
							allowsBackgroundWork: false,
							thermalStateSensitivity: 0.55,
							budgetPriority: .low
						)
						// OCR-first policy: proactive gather fetches OCR only.
						// Visual descriptor is expensive and is deferred to the model-requested
						// context escalation pass (after the router has seen OCR and still
						// decides it needs visual context). This prevents visual descriptor
						// from running on every browsing context automatically.
						let request = BoundedVisualContextRequest(
							reason: "proposal_auto_visual_gather:ocr_only_metadata_only_perception_recommended",
							workflowType: wf,
							intentType: intent,
							requiresOCR: true,
							requiresVisualDescription: false,
							maxWindowSeconds: 6,
							maxOCRCharacters: min(
								BoundedVisualContextBounds.defaultMaxOCRCharacters,
								520
							),
							maxDescriptionCharacters: 0,
							budget: autoBudget,
							permissionAvailability: effectiveSnapshot.permissionAvailability,
							createdAt: referenceTime,
							expiresAt: referenceTime.addingTimeInterval(6)
						)

						if let scheduler = visualScheduler {
							print(
								"[VisualContextGathering] allowed reason=\(peekDecision.allowReason?.rawValue ?? "allowed") fp=\(fingerprint)"
							)
							let budgetSnapshot = GeneratedExecutionBudgetSnapshot(
								activeExecutionCount: 0,
								runtimeState: .idle,
								permissionAvailability: effectiveSnapshot.permissionAvailability,
								activeSamplingRequested: true
							)
						let visualResult = await scheduler.collect(
							request: request,
							budgetSnapshot: budgetSnapshot
						)
						let visualOK = visualResult.status == .completed || visualResult.status == .partial
						if visualOK {
							await sparseVisualPeekGate.recordPeekCompleted(at: referenceTime)
								let classification = VisualContextWorkflowClassifier.classify(
									appCategory: effectiveSituational.appCategory,
									windowTitle: effectiveSituational.windowTitle,
									visualTags: visualResult.visualTags,
									ocrExcerpt: visualResult.ocrExcerpt,
									priorWorkflow: effectiveSituational.inferredWorkflow,
									priorConfidence: effectiveSituational.workflowConfidence
								)
								let titleHint = BrowserTitleHeuristics.domainHint(from: effectiveSituational.windowTitle) ?? "none"
								let tagsHint = visualResult.visualTags.prefix(4).joined(separator: ",")
								let tagsPart = tagsHint.isEmpty ? "none" : tagsHint
								let confPart = String(format: "%.2f", classification.confidence)
								print(
									"[VisualContextClassification] before_workflow=\(effectiveSituational.inferredWorkflow.rawValue) after_workflow=\(classification.workflow.rawValue) app=\(effectiveSituational.activeAppName) title_hint=\(titleHint) tags=\(tagsPart) ocr_hint=\(classification.ocrHint) conf=\(confPart)"
								)

							let enriched = effectiveSnapshot.merging(
								visualResult: visualResult,
								priorWorkflow: classification.workflow,
								priorWorkflowConfidence: classification.confidence,
								referenceTime: referenceTime
							)
							effectiveSnapshot = enriched
							effectiveSituational = SituationalContextSynthesizer.synthesize(
								from: enriched,
								referenceTime: referenceTime
							)
							let captured = visualResult.capturedAt != nil ? "yes" : "no"
							let ocrUsed = (visualResult.ocrExcerpt ?? "").isEmpty ? "no" : "yes"
							let descriptors = ((visualResult.visualSummary ?? "").isEmpty == false || visualResult.visualTags.isEmpty == false) ? "yes" : "no"
							print(
								"[VisualContextGathering] merged capture=\(captured) ocr=\(ocrUsed) descriptors=\(descriptors) status=\(visualResult.status.rawValue) fp=\(fingerprint)"
							)
							} else {
								print(
									"[VisualContextGathering] denied reason=\(visualResult.status.rawValue) fp=\(fingerprint)"
								)
							}
						} else {
							print("[VisualContextGathering] denied reason=scheduler_unavailable fp=\(fingerprint)")
						}
					}
				}
			} else {
				print("[VisualContextGathering] skipped reason=already_attempted fp=\(fingerprint)")
			}
		}

		// MARK: - Model-driven task inference + hook composition (primary; no hardcoded behaviors)
		// This is the source of truth for user-facing dynamic actions. If it fails/times out,
		// we prefer silence (or cache) over falling back to generic seeded templates.

		recordTitleObservation(situational: effectiveSituational, referenceTime: referenceTime)
		let recentTitles = recentTitles(for: effectiveSituational)

		// MARK: Cheap inference pass
		print("[TaskInference] pass=cheap")
		var activeInference = await TaskInferenceEngine.shared.infer(
			snapshot: effectiveSnapshot,
			situational: effectiveSituational,
			recentTitles: recentTitles,
			history: history,
			referenceTime: referenceTime,
			isWarmupReady: isWarmupReady
		)

		// MARK: Context escalation (PART A) — model requested more context
		// When the model returns c=0 + need=[...], attempt bounded context gathering once
		// per fingerprint and re-run inference with the enriched snapshot.
		if let cheapResult = activeInference, !cheapResult.shouldChime, !cheapResult.need.isEmpty {
			let needList = cheapResult.need.joined(separator: ",")
			let escalationFP = Self.contextEscalationFingerprint(snapshot: effectiveSnapshot, situational: effectiveSituational)
			print("[ContextEscalation] requested need=[\(needList)] reason=\(cheapResult.needReason ?? "unspecified") fp=\(escalationFP)")
			if canEscalateContext(escalationFP, referenceTime: referenceTime) {
				recordContextEscalationAttempt(escalationFP, at: referenceTime)
				print("[ContextEscalation] gate=allowed source=model_requested need=[\(needList)] reason=\(cheapResult.needReason ?? "unspecified") fp=\(escalationFP)")
				let escalationStart = Date()
				let escalationOutcome = await gatherEscalatedContext(
					need: cheapResult.need,
					snapshot: effectiveSnapshot,
					situational: effectiveSituational,
					referenceTime: referenceTime
				)
				if let enriched = escalationOutcome.snapshot {
					let enrichedSituational = SituationalContextSynthesizer.synthesize(from: enriched, referenceTime: referenceTime)
					let axChars = escalationOutcome.axChars
					let ocrChars = escalationOutcome.ocrChars
					let descFlag = escalationOutcome.hasDescriptors ? "yes" : "no"
					let elapsed = Int(Date().timeIntervalSince(escalationStart) * 1000)
					print("[ContextEscalation] completed ax_chars=\(axChars) ocr_chars=\(ocrChars) descriptors=\(descFlag) elapsed_ms=\(elapsed) fp=\(escalationFP)")
					effectiveSnapshot = enriched
					effectiveSituational = enrichedSituational
					// Re-run inference with enriched context.
					print("[TaskInference] pass=enriched")
					activeInference = await TaskInferenceEngine.shared.infer(
						snapshot: enriched,
						situational: enrichedSituational,
						recentTitles: recentTitles,
						history: history,
						referenceTime: referenceTime,
						isEnrichedPass: true,
						isWarmupReady: isWarmupReady
					)
				} else {
					let elapsed = Int(Date().timeIntervalSince(escalationStart) * 1000)
					print("[ContextEscalation] denied reason=\(escalationOutcome.denialReason ?? "gather_unavailable") fp=\(escalationFP) elapsed_ms=\(elapsed)")
				}
			} else {
				print("[ContextEscalation] gate=denied reason=already_attempted_same_fp fp=\(escalationFP)")
			}
		}

		// MARK: Hook composition
		if let inference = activeInference {
			if !inference.shouldChime {
				let needStr = inference.need.isEmpty ? "" : " need=[\(inference.need.joined(separator: ","))]"
				print("[DynamicActionSynthesis] skipped reason=model_chose_quiet\(needStr)")
				return result(
					status: .quietByGate,
					reason: "task_inference_quiet",
					warnings: ["diag:task_inference_quiet"],
					cause: nil,
					referenceTime: referenceTime,
					contextSnapshot: effectiveSnapshot
				)
			}

			if let composed = await TaskInferencePlanningPipeline.compose(
				inference: inference,
				snapshot: effectiveSnapshot,
				situational: effectiveSituational,
				recentTitles: recentTitles,
				referenceTime: referenceTime
			) {
				print(
					"[DynamicActionSynthesis] source=hook_composer synthesized title=\(composed.contract.title) confidence=\(String(format: "%.2f", composed.contract.confidence)) why_now=\(composed.contract.whyNow)"
				)
				logMetadata(
					event: "dynamic_action_synthesis",
					value: "hook_composer",
					extra: "title=\(composed.contract.title) conf=\(String(format: "%.2f", composed.contract.confidence)) why_now=\(composed.contract.whyNow)"
				)
				return DynamicGeneratedProposalResult(
					status: .synthesized,
					shouldChimeIn: true,
					reason: "hook_composer",
					workflowAssessment: "hook_composer",
					proposalConfidence: composed.contract.confidence,
					requiresVisualContext: composed.contract.requiredContext.contains(.screenCapture) || composed.contract.requiredContext.contains(.fusedVisual),
					proposals: [composed.proposal],
					warnings: [],
					llmDiagnosticCause: nil,
					createdAt: referenceTime,
					contextSnapshot: effectiveSnapshot,
					libraryRecords: [],
					hookContracts: [composed.contract]
				)
			}

			// Phase 4R — If compose failed (often due to low grounding / transient title churn),
			// perform ONE isolated retry using the last strong context anchor when available.
			if let anchor = strongContextAnchor, !anchored.usedAnchor, !anchor.isExpired(at: referenceTime) {
				let aBundle = anchor.bundleIdentifier?.lowercased() ?? ""
				let cBundle = effectiveSnapshot.bundleIdentifier?.lowercased() ?? ""
				if !aBundle.isEmpty, !cBundle.isEmpty, aBundle == cBundle {
					print("[ProposalGeneration] retrying reason=activation_low_grounding using_strong_anchor=yes")
					print("[ProposalContext] using_strong_anchor=yes")
					let wfConfidence = max(0.55, effectiveSituational.workflowConfidence)
					let retrySnapshot = effectiveSnapshot.replacing(
						windowTitle: anchor.windowTitle,
						recentOCRExcerpt: anchor.ocrExcerpt,
						inferredWorkflow: anchor.workflow,
						workflowConfidence: wfConfidence
					)
					let retrySituational = effectiveSituational.replacing(
						windowTitle: anchor.windowTitle,
						inferredWorkflow: anchor.workflow,
						workflowConfidence: wfConfidence
					)
					if let retryInference = await TaskInferenceEngine.shared.infer(
						snapshot: retrySnapshot,
						situational: retrySituational,
						recentTitles: recentTitles,
						history: history,
						referenceTime: referenceTime,
						isEnrichedPass: true,
						isWarmupReady: isWarmupReady
					), retryInference.shouldChime,
					   let retryComposed = await TaskInferencePlanningPipeline.compose(
						inference: retryInference,
						snapshot: retrySnapshot,
						situational: retrySituational,
						recentTitles: recentTitles,
						referenceTime: referenceTime
					   )
					{
						print("[DynamicActionSynthesis] source=hook_composer_retry synthesized title=\(retryComposed.contract.title) confidence=\(String(format: "%.2f", retryComposed.contract.confidence)) why_now=\(retryComposed.contract.whyNow)")
						return DynamicGeneratedProposalResult(
							status: .synthesized,
							shouldChimeIn: true,
							reason: "hook_composer_retry",
							workflowAssessment: "hook_composer_retry",
							proposalConfidence: retryComposed.contract.confidence,
							requiresVisualContext: retryComposed.contract.requiredContext.contains(.screenCapture) || retryComposed.contract.requiredContext.contains(.fusedVisual),
							proposals: [retryComposed.proposal],
							warnings: [],
							llmDiagnosticCause: nil,
							createdAt: referenceTime,
							contextSnapshot: retrySnapshot,
							libraryRecords: [],
							hookContracts: [retryComposed.contract]
						)
					}
				}
			}

			print("[DynamicActionSynthesis] skipped reason=compose_failed")
		} else {
			print("[DynamicActionSynthesis] skipped reason=no_inference")
		}

		let cacheKey = dynamicActionCacheKey(
			snapshot: effectiveSnapshot,
			situational: effectiveSituational,
			recentTitles: recentTitles
		)
		if let cached = lookupCachedDynamicAction(
			key: cacheKey,
			situational: effectiveSituational,
			referenceTime: referenceTime
		) {
			print(
				"[DynamicActionSynthesis] source=cache synthesized title=\(cached.title) confidence=\(String(format: "%.2f", cached.confidence))"
			)
			logMetadata(
				event: "dynamic_action_synthesis",
				value: "cache",
				extra: "title=\(cached.title) conf=\(String(format: "%.2f", cached.confidence))"
			)
			let proposal = Self.proposal(from: cached, situational: effectiveSituational)
			return DynamicGeneratedProposalResult(
				status: .synthesized,
				shouldChimeIn: true,
				reason: "cache",
				workflowAssessment: "cache_hit",
				proposalConfidence: cached.confidence,
				requiresVisualContext: cached.requiredContext.contains(.screenCapture) || cached.requiredContext.contains(.fusedVisual),
				proposals: [proposal],
				warnings: [],
				llmDiagnosticCause: nil,
				createdAt: referenceTime,
				contextSnapshot: effectiveSnapshot,
				libraryRecords: [],
				hookContracts: [cached]
			)
		}

		// MARK: - Template library fallback (debug-only)
		// The reusable template library is an accelerator only; it must not dominate normal proposal
		// synthesis. Enable only for explicit debug workflows.
		if !ProposalLoggingFlags.templateFallbackEnabled {
			return result(
				status: .quietByGate,
				reason: "no_task_inference_action",
				warnings: ["diag:no_task_inference_action"],
				cause: nil,
				referenceTime: referenceTime,
				contextSnapshot: effectiveSnapshot
			)
		}

		// MARK: - Template library lookup (debug-only)

		logMetadata(
			event: "pipeline_stage",
			value: "library_lookup",
			extra: "workflow=\(effectiveSituational.inferredWorkflow.rawValue) perception=\(effectiveSituational.perceptionRecommendation.rawValue) primary=\(effectiveSituational.primaryAvailableSource.rawValue) context_types=\(Self.contextTypesLog(from: effectiveSituational))"
		)

		let libraryResult = await templateLibrary.retrieve(
			situational: effectiveSituational,
			referenceTime: referenceTime
		)

		logMetadata(
			event: "library_lookup_result",
			value: libraryResult.hasMatch ? "hit" : "miss",
			extra: "count=\(libraryResult.records.count) miss_reason=\(libraryResult.missReason?.rawValue ?? "none") workflow=\(effectiveSituational.inferredWorkflow.rawValue)"
		)

		if libraryResult.hasMatch {
			var records = libraryResult.records
			let perception = effectiveSituational.perceptionRecommendation
			let visualCount = records.filter { $0.metadata["requires_visual"] == "1" }.count
			if visualCount > 0 && (perception == .useful || perception == .recommended || perception == .requiredBeforeSpecificProposal) {
				let boostedMinUsefulness: Double = (perception == .requiredBeforeSpecificProposal || perception == .recommended) ? 0.90 : 0.85
				let boostedMinConfidence: Double = (perception == .requiredBeforeSpecificProposal || perception == .recommended) ? 0.78 : 0.75
				let boostedUsefulnessString = String(format: "%.2f", boostedMinUsefulness)
				records = records.map { record in
					guard record.metadata["requires_visual"] == "1" else { return record }
					var updated = record
					updated.usefulnessScore = max(updated.usefulnessScore, boostedMinUsefulness)
					updated.averageConfidence = max(updated.averageConfidence, boostedMinConfidence)
					if ProposalLoggingFlags.verboseProposalLogsEnabled {
						print("[TemplateRanking] visual_rank_boost template=\(record.actionTemplateId) reason=perception_\(perception.rawValue)")
					}
					return updated
				}
				logMetadata(
					event: "visual_template_priority",
					value: "applied",
					extra: "perception=\(perception.rawValue) visual=\(visualCount) boosted_usefulness_min=\(boostedUsefulnessString)"
				)
			}
			let titles = records.prefix(3).map(\.title).joined(separator: "|")
			logMetadata(
				event: "template_library_hit",
				value: "\(records.count)",
				extra: "workflow=\(effectiveSituational.inferredWorkflow.rawValue) source=library top_titles=\(titles)"
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
				contextSnapshot: effectiveSnapshot,
				libraryRecords: records,
				hookContracts: []
			)
		}

		// MARK: - Two-stage decision gate (T18.3.4 / T18.3.4A)
		// Only consulted after a library miss. The gate decides whether to queue prewarm or
		// recommend more context. The LLM is never called (unreachable in production).

		let decision = await decisionEngine.decide(
			snapshot: effectiveSnapshot,
			situational: effectiveSituational,
			referenceTime: referenceTime
		)
		logMetadata(
			event: "decision_stage",
			value: decision.shouldThink ? "think" : (decision.needsMoreContext ? "needs_context" : "quiet"),
			extra: "source=\(decision.decisionSource.rawValue) conf=\(String(format: "%.2f", decision.confidence)) reason=\(decision.reason)"
		)

		// Library missed — queue prewarm then evaluate decision gate for final return code.
		await templateLibrary.enqueuePrewarm(
			situational: effectiveSituational,
			decision: decision,
			referenceTime: referenceTime
		)
		logMetadata(
			event: "template_library_miss",
			value: libraryResult.missReason?.rawValue ?? "unknown",
			extra: "workflow=\(effectiveSituational.inferredWorkflow.rawValue) prewarm_queued=yes perception=\(effectiveSituational.perceptionRecommendation.rawValue)"
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
					referenceTime: referenceTime,
					contextSnapshot: effectiveSnapshot
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
				referenceTime: referenceTime,
				contextSnapshot: effectiveSnapshot
			)
		}

		logMetadata(event: "large_model_called", value: "no", extra: "reason=no_template_in_library")
		logMetadata(event: "library_miss_gate_result", value: "no_template", extra: "prewarm_already_queued=yes")
		return result(
			status: .quietByGate,
			reason: "no_template_in_library",
			warnings: ["diag:no_template_in_library"],
			cause: nil,
			referenceTime: referenceTime,
			contextSnapshot: effectiveSnapshot
		)

		// NOTE: Live large-model proposal synthesis is intentionally disabled in the hot path.
		// Any future slow-path LLM work should be wired as explicit/deferred work, not part of
		// continuous proposal updates.
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
				contextSnapshot: snapshot,
				libraryRecords: [],
				hookContracts: []
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
				contextSnapshot: snapshot,
				libraryRecords: [],
				hookContracts: []
			)
		}

		let cooldownSeconds: TimeInterval = AgenticPivot.useEarlierProposalSurfacing ? 10 : 30
		if let history, let dismissedAt = history.lastDismissedAt,
		   referenceTime.timeIntervalSince(dismissedAt) < cooldownSeconds
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
				contextSnapshot: snapshot,
				libraryRecords: [],
				hookContracts: []
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
			contextSnapshot: parsed.contextSnapshot,
			libraryRecords: [],
			hookContracts: parsed.hookContracts
		)
	}

	// MARK: - Automatic visual context gathering helpers (T18.3.7B)

	private func shouldAttemptAutoVisualGather(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) -> Bool {
		let perception = situational.perceptionRecommendation
		let perceptionAllows = perception == .useful
			|| perception == .recommended
			|| perception == .requiredBeforeSpecificProposal
		guard perceptionAllows else { return false }
		guard situational.primaryAvailableSource == .metadataOnly else { return false }

		let hasExistingVisual = snapshot.visualContextAvailability.hasUsableVisual
		let hasExistingOCR = !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		if hasExistingVisual || hasExistingOCR { return false }

		// If screen recording is explicitly denied, skip. Unknown state is allowed to proceed to policy.
		if snapshot.permissionAvailability[.screenRecording] == false { return false }

		return true
	}

	private func shouldAttemptAutoVisualGatherForFingerprint(
		_ fingerprint: String,
		referenceTime: Date
	) -> Bool {
		if let last = autoVisualGatheredAtByFingerprint[fingerprint],
		   referenceTime.timeIntervalSince(last) < Self.autoVisualGatherCooldownSeconds {
			return false
		}
		// Opportunistic prune (no timers/polling).
		let cutoff = referenceTime.addingTimeInterval(-Self.autoVisualGatherCooldownSeconds * 2)
		autoVisualGatheredAtByFingerprint = autoVisualGatheredAtByFingerprint.filter { $0.value > cutoff }
		return true
	}

	private func recordAutoVisualGatherAttempt(_ fingerprint: String, at time: Date) {
		autoVisualGatheredAtByFingerprint[fingerprint] = time
	}

	// MARK: - Model-requested context escalation helpers (PART A)

	/// Returns true if this fingerprint has not been escalated within the cooldown window.
	/// Model-requested escalation uses a SEPARATE gate from auto-visual-gather so that
	/// a prior proactive OCR attempt does not block a model-driven request on a new page.
	private func canEscalateContext(_ fingerprint: String, referenceTime: Date) -> Bool {
		if let last = contextEscalatedAtByFingerprint[fingerprint],
		   referenceTime.timeIntervalSince(last) < Self.contextEscalationCooldownSeconds {
			return false
		}
		// Prune stale entries.
		let cutoff = referenceTime.addingTimeInterval(-Self.contextEscalationCooldownSeconds * 2)
		contextEscalatedAtByFingerprint = contextEscalatedAtByFingerprint.filter { $0.value > cutoff }
		return true
	}

	private func recordContextEscalationAttempt(_ fingerprint: String, at time: Date) {
		contextEscalatedAtByFingerprint[fingerprint] = time
	}

	/// Gathers the context types requested by the model via `need[]`.
	/// Currently maps all visual context needs to the existing BoundedVisualContextRequest machinery.
	/// Returns an enriched snapshot (or nil) plus metadata-only counts for diagnostics.
	private func gatherEscalatedContext(
		need: [String],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) async -> (snapshot: CanonicalGeneratedExecutionContextSnapshot?, axChars: Int, ocrChars: Int, hasDescriptors: Bool, denialReason: String?) {
		var denialReason: String?
		var working = snapshot
		var axChars = 0
		var ocrChars = 0
		var hasDescriptors = false
		var didChange = false

		// MARK: - AX window text (accessibility)
		let wantsAX = need.contains("ax_window_text") || need.contains("browser_text")
		if wantsAX {
			let accessibilityAllowed = snapshot.permissionAvailability[.accessibility] != false
			if !accessibilityAllowed {
				denialReason = "permission_accessibility_denied"
				print("[TwoStageContextAcquisition] source=ax_window_text completed=no")
			} else if let ax = AXWindowContentSource.shared.extractActiveWindowContent() {
				let joined = ax.visibleTextFragments.prefix(40).joined(separator: " • ")
				let excerpt = String(joined.prefix(900))
				axChars = excerpt.count
				if axChars > 0 {
					working = working.merging(axWindowTextExcerpt: excerpt, referenceTime: referenceTime)
					didChange = true
				}
				print("[TwoStageContextAcquisition] source=ax_window_text completed=\(axChars > 0 ? "yes" : "no")")
			} else {
				if denialReason == nil {
					denialReason = "ax_unavailable"
				}
				print("[TwoStageContextAcquisition] source=ax_window_text completed=no")
			}
		}

		// MARK: - Visual/OCR gathering (screen recording)
		let wantsOCR = need.contains("visible_ocr") || need.contains("ocr")
		// OCR-first policy: visual descriptor is only gathered if OCR is NOT also being
		// requested in this same pass (or OCR is already present). When both are requested,
		// defer visual to a later escalation — the router will re-request it after seeing OCR.
		var wantsVisual = need.contains("visual_descriptor")
		let hasExistingOCR = !(snapshot.recentOCRExcerpt ?? "").isEmpty
		if wantsOCR && wantsVisual && !hasExistingOCR {
			wantsVisual = false
			print("[ContextEscalation] deferred=visual_descriptor reason=ocr_first_policy ocr_must_run_first=yes")
		}
		let wantsScreen = wantsOCR || wantsVisual

		if wantsScreen {
			guard let scheduler = visualScheduler else {
				denialReason = denialReason ?? "no_visual_scheduler"
				if wantsOCR { print("[TwoStageContextAcquisition] source=ocr completed=no") }
				if wantsVisual { print("[TwoStageContextAcquisition] source=visual_descriptor completed=no") }
				return (didChange ? working : nil, axChars, ocrChars, hasDescriptors, denialReason)
			}
			// Screen recording permission check — denied means we can't gather OCR/visual.
			if snapshot.permissionAvailability[.screenRecording] == false {
				denialReason = denialReason ?? "permission_screen_recording_denied"
				if wantsOCR { print("[TwoStageContextAcquisition] source=ocr completed=no") }
				if wantsVisual { print("[TwoStageContextAcquisition] source=visual_descriptor completed=no") }
				return (didChange ? working : nil, axChars, ocrChars, hasDescriptors, denialReason)
			}

			let escalationBudget = ExecutionBudget(
				maxCPUPercent: 30,
				maxConcurrentTasks: 1,
				maxExecutionTime: 12,
				allowsVision: true,
				allowsOCR: wantsOCR,
				allowsLLM: false,
				allowsBackgroundWork: false,
				thermalStateSensitivity: 0.55,
				budgetPriority: .low
			)
			let wf = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
			let request = BoundedVisualContextRequest(
				reason: "context_escalation:model_requested:[\(need.joined(separator: ","))]",
				workflowType: wf,
				intentType: .unknown,
				requiresOCR: wantsOCR,
				requiresVisualDescription: wantsVisual,
				maxWindowSeconds: 8,
				maxOCRCharacters: min(BoundedVisualContextBounds.defaultMaxOCRCharacters, 800),
				maxDescriptionCharacters: min(BoundedVisualContextBounds.defaultMaxDescriptionCharacters, 300),
				budget: escalationBudget,
				permissionAvailability: snapshot.permissionAvailability,
				createdAt: referenceTime,
				expiresAt: referenceTime.addingTimeInterval(10)
			)

			let budgetSnapshot = GeneratedExecutionBudgetSnapshot(
				activeExecutionCount: 0,
				runtimeState: .idle,
				permissionAvailability: snapshot.permissionAvailability,
				activeSamplingRequested: true
			)

			let visualResult = await scheduler.collect(request: request, budgetSnapshot: budgetSnapshot)
			if !(visualResult.status == .completed || visualResult.status == .partial) {
				denialReason = denialReason ?? "gather_\(visualResult.status.rawValue)"
				if wantsOCR { print("[TwoStageContextAcquisition] source=ocr completed=no") }
				if wantsVisual { print("[TwoStageContextAcquisition] source=visual_descriptor completed=no") }
				return (didChange ? working : nil, axChars, ocrChars, hasDescriptors, denialReason)
			}

			// Record gate so auto-visual-gather knows visual context was recently obtained.
			await sparseVisualPeekGate.recordPeekCompleted(at: referenceTime)

			let classification = VisualContextWorkflowClassifier.classify(
				appCategory: situational.appCategory,
				windowTitle: situational.windowTitle,
				visualTags: visualResult.visualTags,
				ocrExcerpt: visualResult.ocrExcerpt,
				priorWorkflow: situational.inferredWorkflow,
				priorConfidence: situational.workflowConfidence
			)

			let merged = working.merging(
				visualResult: visualResult,
				priorWorkflow: classification.workflow,
				priorWorkflowConfidence: classification.confidence,
				referenceTime: referenceTime
			)
			ocrChars = (merged.recentOCRExcerpt ?? "").count
			hasDescriptors = merged.visualContextAvailability.hasUsableVisual
			didChange = true
			working = merged

			if wantsOCR {
				print("[TwoStageContextAcquisition] source=ocr completed=\(ocrChars > 0 ? "yes" : "no")")
			}
			if wantsVisual {
				print("[TwoStageContextAcquisition] source=visual_descriptor completed=\(hasDescriptors ? "yes" : "no")")
			}
		}

		if didChange {
			return (working, axChars, ocrChars, hasDescriptors, nil)
		}
		return (nil, axChars, ocrChars, hasDescriptors, denialReason ?? "no_op")
	}

	/// Privacy-safe fingerprint hint for per-window auto-visual gating (process-local).
	private static func autoVisualGatherFingerprint(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> String {
		let raw = "\(snapshot.bundleIdentifier ?? snapshot.activeApp)|\(situational.windowTitle)|\(situational.inferredWorkflow.rawValue)"
		let hint = abs(raw.hashValue)
		return String(hint, radix: 16)
	}

	/// Fingerprint for model-requested context escalation.
	/// Intentionally excludes inferredWorkflow so that a workflow change after enrichment
	/// doesn't allow repeated escalation attempts on the same page/window.
	private static func contextEscalationFingerprint(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> String {
		let bundle = (situational.activeBundleId ?? snapshot.bundleIdentifier ?? snapshot.activeApp).lowercased()
		var title = situational.windowTitle.lowercased()
		for suffix in [" - google chrome", " - safari", " - firefox", " — mozilla firefox"] {
			if title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
		}
		title = title.trimmingCharacters(in: .whitespacesAndNewlines)
		let raw = "\(bundle)|\(title)"
		let hint = abs(raw.hashValue)
		return String(hint, radix: 16)
	}

	private static func contextTypesLog(from situational: SituationalContextSnapshot) -> String {
		var types: [ContextRequirementType] = []
		if situational.selectedTextSignal.availability == .available {
			types += [.textSnippet, .selectedText]
		}
		if situational.clipboardSignal.availability == .available {
			types.append(.textSnippet)
		}
		if situational.ocrSignal.availability == .available {
			types.append(.fusedVisual)
		}
		if situational.visualSignal.availability == .available {
			types += [.fusedVisual, .screenCapture]
		}
		if situational.inferredWorkflow != .unknown {
			types.append(.workflowContext)
		}
		if types.isEmpty { types = [.none] }
		var seen = Set<ContextRequirementType>()
		let deduped = types.filter { seen.insert($0).inserted }
		return deduped.map(\.rawValue).joined(separator: ",")
	}

	private func result(
		status: DynamicGeneratedProposalSynthesisStatus,
		reason: String,
		warnings: [String],
		cause: DynamicGeneratedProposalLLMDiagnosticCause?,
		referenceTime: Date,
		contextSnapshot: CanonicalGeneratedExecutionContextSnapshot? = nil
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
			contextSnapshot: contextSnapshot,
			libraryRecords: [],
			hookContracts: []
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

	// MARK: - Hook-composed proposal mapping

	private static func proposal(
		from contract: DynamicGeneratedActionContract,
		situational: SituationalContextSnapshot
	) -> ValidatedDynamicGeneratedProposal {
		let workflow = WorkflowExecutionMapper.workflowType(from: situational.inferredWorkflow)
		let ids = contract.hookPlanIds.filter { $0 != "observe_current_context" && $0 != "present_result" }
		let resolved = HookCapabilityRegistry.shared.resolveNeededCapabilities(ids).resolved
		let primitives = HookCapabilityRegistry.primitives(from: resolved)
		let intent: IntentType = {
			if primitives.contains(.compareContexts) { return .compare }
			if primitives.contains(.explainError) { return .explain }
			if primitives.contains(.extractActionItems) { return .extract }
			if primitives.contains(.organizeInformation) { return .organize }
			if primitives.contains(.synthesizeResearchSummary) { return .synthesize }
			if primitives.contains(.structureNotes) { return .structure }
			if primitives.contains(.classifyWorkflow) { return .classify }
			if primitives.contains(.answerFromContext) { return .answer }
			if primitives.contains(.summarizeContext) { return .summarize }
			return .unknown
		}()

		let interruptionCost: Double = {
			let base: Double
			switch workflow {
			case .debugging: base = 0.26
			case .research, .browsing, .studying: base = 0.22
			default: base = 0.18
			}
			return max(0.08, min(0.65, base - max(0, (contract.confidence - 0.7)) * 0.12))
		}()

		let proposal = ValidatedDynamicGeneratedProposal(
			id: contract.id,
			title: contract.title,
			description: contract.userFacingQuestion,
			workflowType: workflow,
			intentType: intent,
			expectedOutcome: contract.inferredUserGoal,
			requiredContextTypes: contract.requiredContext,
			suggestedPrimitives: primitives,
			interruptionCost: interruptionCost,
			confidence: contract.confidence,
			usefulnessHint: "hook_composer_cache",
			agenticPlan: nil
		)

		return proposal
	}

	// MARK: - Task inference memory + synthesis cache (metadata-only)

	private func recordTitleObservation(
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) {
		let key = (situational.activeBundleId ?? situational.activeAppName).lowercased()
		let title = situational.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !title.isEmpty else { return }
		var items = titleHistoryByBundle[key] ?? []
		items.append(TaskInferenceTitleObservation(title: title, capturedAt: referenceTime))
		if items.count > Self.titleHistoryMaxItems {
			items.removeFirst(items.count - Self.titleHistoryMaxItems)
		}
		titleHistoryByBundle[key] = items

		// Feed browsing title changes into comparison tracker.
		// BrowsingComparisonTracker deduplicates consecutive identical titles internally.
		let wf = situational.inferredWorkflow
		if wf == .browsing || wf == .research {
			let capturedTitle = title
			let capturedTime = referenceTime
			Task { await BrowsingComparisonTracker.shared.record(title: capturedTitle, at: capturedTime) }
		}
	}

	private func recentTitles(for situational: SituationalContextSnapshot) -> [String] {
		let key = (situational.activeBundleId ?? situational.activeAppName).lowercased()
		let history = titleHistoryByBundle[key] ?? []
		return history.map(\.title)
	}

	private func dynamicActionCacheKey(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		recentTitles: [String]
	) -> String {
		TaskInferenceEngine.fingerprint(snapshot: snapshot, situational: situational, recentTitles: recentTitles)
	}

	private func rememberDynamicActionContract(
		_ contract: DynamicGeneratedActionContract,
		referenceTime: Date
	) {
		guard contract.cacheEligibility else { return }
		dynamicActionCacheByKey[contract.cacheKey] = contract
		pruneDynamicActionCache(referenceTime: referenceTime)
	}

	private func lookupCachedDynamicAction(
		key: String,
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) -> DynamicGeneratedActionContract? {
		pruneDynamicActionCache(referenceTime: referenceTime)
		guard let cached = dynamicActionCacheByKey[key] else { return nil }
		if cached.expiresAt <= referenceTime { return nil }
		// Accelerator only: if we now have rich selected text, prefer fresh synthesis over cache.
		if situational.selectedTextSignal.availability == .available { return nil }
		return cached
	}

	private func pruneDynamicActionCache(referenceTime: Date) {
		let cutoff = referenceTime.addingTimeInterval(-Self.dynamicActionCacheTTLSeconds)
		dynamicActionCacheByKey = dynamicActionCacheByKey.filter { _, value in
			value.createdAt >= cutoff && value.expiresAt > referenceTime
		}
	}

	// MARK: - Strong Context Anchor (Phase 4R)

	private struct StrongAnchorApplication: Sendable {
		let snapshot: CanonicalGeneratedExecutionContextSnapshot
		let situational: SituationalContextSnapshot
		let usedAnchor: Bool
	}

	private func applyStrongContextAnchorIfNeeded(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) -> StrongAnchorApplication {
		let decision = StrongContextAnchorHeuristic.evaluate(
			now: referenceTime,
			currentTitle: situational.windowTitle,
			currentOCR: snapshot.recentOCRExcerpt,
			currentWorkflow: situational.inferredWorkflow,
			currentBundleId: snapshot.bundleIdentifier,
			anchor: strongContextAnchor
		)

		if decision.shouldStore {
			strongContextAnchor = StrongContextAnchor(
				appName: situational.activeAppName,
				bundleIdentifier: snapshot.bundleIdentifier,
				windowTitle: situational.windowTitle,
				ocrExcerpt: snapshot.recentOCRExcerpt,
				axExcerpt: nil,
				workflow: situational.inferredWorkflow,
				storedAt: referenceTime
			)
			print("[StrongContextAnchor] stored title=\(sanitizeTitleForLog(situational.windowTitle)) workflow=\(situational.inferredWorkflow.rawValue)")
			return StrongAnchorApplication(snapshot: snapshot, situational: situational, usedAnchor: false)
		}

		if decision.shouldPreserve, let anchor = strongContextAnchor {
			print("[StrongContextAnchor] preserved reason=\(decision.reason) current=\(sanitizeTitleForLog(situational.windowTitle))")
			print("[ProposalContext] using_strong_anchor=yes")
			let wfConfidence = max(0.55, situational.workflowConfidence)
			let preservedSnapshot = snapshot.replacing(
				windowTitle: anchor.windowTitle,
				recentOCRExcerpt: anchor.ocrExcerpt,
				inferredWorkflow: anchor.workflow,
				workflowConfidence: wfConfidence
			)
			let preservedSituational = situational.replacing(
				windowTitle: anchor.windowTitle,
				inferredWorkflow: anchor.workflow,
				workflowConfidence: wfConfidence
			)
			return StrongAnchorApplication(snapshot: preservedSnapshot, situational: preservedSituational, usedAnchor: true)
		}

		return StrongAnchorApplication(snapshot: snapshot, situational: situational, usedAnchor: false)
	}

	private func sanitizeTitleForLog(_ title: String) -> String {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return "none" }
		let out = trimmed.count > 72 ? String(trimmed.prefix(72)) : trimmed
		return out.replacingOccurrences(of: "\n", with: " ")
	}
}
