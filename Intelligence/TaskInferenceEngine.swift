import Foundation

protocol TaskInferenceLLMGenerating: Sendable {
	func generate(
		prompt: String,
		model: String,
		numPredict: Int,
		temperature: Double,
		purpose: String?,
		schema: [String: Any]?
	) async throws -> String

	/// Streaming variant: accumulates tokens and returns as soon as a balanced `{…}` JSON object
	/// is detected. Dramatically reduces effective latency vs waiting for full num_predict tokens.
	func generateStreamingJSON(
		prompt: String,
		model: String,
		numPredict: Int,
		temperature: Double,
		purpose: String?,
		schema: [String: Any]?,
		onProgress: (@Sendable (String) -> Void)?
	) async throws -> String
}

extension TaskInferenceLLMGenerating {
	func generate(
		prompt: String,
		model: String,
		numPredict: Int,
		temperature: Double,
		purpose: String?
	) async throws -> String {
		try await generate(prompt: prompt, model: model, numPredict: numPredict, temperature: temperature, purpose: purpose, schema: nil)
	}

	func generateStreamingJSON(
		prompt: String,
		model: String,
		numPredict: Int,
		temperature: Double,
		purpose: String?,
		schema: [String: Any]? = nil,
		onProgress: (@Sendable (String) -> Void)? = nil
	) async throws -> String {
		try await generateStreamingJSON(prompt: prompt, model: model, numPredict: numPredict, temperature: temperature, purpose: purpose, schema: schema, onProgress: onProgress)
	}
}

extension LocalAIClient: TaskInferenceLLMGenerating {}

/// Fast, timeout-bounded task inference using a small local model (task inference tier).
///
/// On every attempt emits [TaskInferencePerf] with full metadata.
/// Rolling stats are maintained in TaskInferencePerfStats.
/// Model selection is delegated to ActiveModelTierConfig (populated by ModelAuditManager).
/// On timeout: stay quiet — no generic template fallback.
actor TaskInferenceEngine {
    // Two-stage lane manager for serialized router/planner calls
    private let twoStageLane = TwoStageLaneManager.shared
	static let shared = TaskInferenceEngine()
	static let routerModelName = "qwen2.5:0.5b"
	static let plannerModelName = "phi4-mini"

	private struct Cached: Sendable {
		let result: TaskInferenceResult
		let cachedAt: Date
	}

	static let routerSchema: [String: Any] = [
		"type": "object",
		"properties": [
			"decision": [
				"type": "string",
				"enum": [
					"enough_context",
					"need_more_context",
					"insufficient_context"
				]
			],
			"request": [
				"type": "array",
				// Constrain items to valid context source names only.
				// Prevents degenerate repetition under grammar-constrained decoding
				// which would exhaust the num_predict budget before JSON closes.
				"items": [
					"type": "string",
					"enum": ["ocr", "ax", "selection", "window_title", "visual_snapshot"]
				],
				"maxItems": 5
			],
			"confidence": [
				"type": "number"
			],
			"reason": [
				"type": "string"
			],
			"proposed_title": [
				"type": "string",
				"maxLength": 80
			] as [String: Any],
			"proposed_goal": [
				"type": "string",
				"maxLength": 80
			] as [String: Any]
		],
		"required": [
			"decision",
			"request",
			"confidence",
			"proposed_title",
			"proposed_goal"
		]
	]

	/// Planner schema — produces 1–3 ranked action candidates for deterministic selection.
	///
	/// Each candidate has: title (user-facing action), caps (capability category list),
	/// confidence (0-1), novelty (how specific to current context), requires (needed context).
	/// should_surface_softly at top level: gate on whether to surface any proposal at all.
	///
	/// maxLength on strings bounds the grammar tree. minItems:1 ensures at least one action.
	/// num_predict 220 covers 3 compact candidates (~140 tokens) plus JSON structure.
	static let plannerSchema: [String: Any] = [
		"type": "object",
		"properties": [
			"actions": [
				"type": "array",
				"items": [
					"type": "object",
					"properties": [
						"title": ["type": "string", "maxLength": 80] as [String: Any],
						"caps":  ["type": "string", "maxLength": 60] as [String: Any],
						"confidence": ["type": "number"] as [String: Any],
						"novelty": ["type": "number"] as [String: Any],
						"requires": [
							"type": "array",
							"items": [
								"type": "string",
								"enum": ["title", "ocr", "selected_text", "clipboard", "ax_window_text", "visual_descriptor"]
							] as [String: Any],
							"maxItems": 4
						] as [String: Any]
					] as [String: Any],
					"required": ["title", "caps", "confidence"]
				] as [String: Any],
				"minItems": 1,
				"maxItems": 3
			] as [String: Any],
			"should_surface_softly": ["type": "boolean"] as [String: Any]
		] as [String: Any],
		"required": ["actions", "should_surface_softly"]
	]

	private let modelManager: any DynamicGeneratedProposalAvailabilityChecking
	private let llm: any TaskInferenceLLMGenerating
	private var cacheByFingerprint: [String: Cached] = [:]

	/// Streaming hard timeout. Streaming stops early when JSON closes, so effective
	/// latency is much lower than this cap. phi4-mini warm = ~0.5s.
	static let inferenceTimeoutSeconds: TimeInterval = 6.0

	/// Router-specific timeout. The router model (phi4-mini) produces a tiny JSON object.
	/// 8s covers model cold-start (typical 3-6s for GGUF) plus inference time.
	/// Pre-session logs showed cold-start completions at 6073ms/6300ms/6391ms — a 4s limit
	/// caused all of those to fail. Keep at 8s until warm-model optimizations are validated.
	static let routerTimeoutSeconds: TimeInterval = 8.0

	/// Planner-specific timeout. phi4-mini + schema-constrained decoding needs more headroom
	/// than the tiny router. Schema enforcement adds per-token grammar overhead; the planner
	/// also produces a larger JSON object than the router. 6s comfortably covers warm inference
	/// (~1.5-2.5s) plus any grammar overhead spikes without stalling the pipeline too long.
	/// Previous value was 2.5s — too tight, caused timeout failures even on warm models.
	static let plannerTimeoutSeconds: TimeInterval = 4.0

	/// Router max tokens. The router produces a JSON object with decision, request[], confidence, reason.
	/// A full worst-case response ("need_more_context" + all 3 request items + reason) is ~70-80 tokens
	/// under schema-constrained decoding. 80 gives enough headroom; 48 caused one failure in 25 where
	/// the model's constrained generation exhausted the budget before closing the JSON object.
	static let routerNumPredict: Int = 80
	static let cacheMaxAgeSeconds: TimeInterval = 28
	static let cacheStaleMaxAgeSeconds: TimeInterval = 56

	/// Warm-model window: if the last successful inference was within this interval,
	/// Ollama almost certainly still has the model loaded in memory (with keep_alive=10m).
	static let warmWindowSeconds: TimeInterval = 9 * 60  // 9 minutes

	/// Tracks the timestamp of the last successful (non-cached) inference.
	private var lastSuccessfulInferenceAt: Date?

	/// True when the model is likely still resident in Ollama's memory.
	private var isLikelyWarm: Bool {
		guard let last = lastSuccessfulInferenceAt else { return false }
		return Date().timeIntervalSince(last) < Self.warmWindowSeconds
	}

	// MARK: - Concurrency guards

	/// Prevents two live inferences from running simultaneously (and competing for Ollama).
	/// When a second call arrives while one is in flight, it returns nil immediately rather
	/// than queuing — the caller will retry on the next context event.
	private var isInferenceRunning = false
	private var activePlannerTask: Task<TaskInferenceResult?, Never>?
	private var activeFingerprint: String?

	/// Task B: tracks whether the in-flight task has entered the planner phase.
	/// Set to true after the planner debounce fires. Used to decide whether a minor
	/// same-app title change should cancel the task or be tolerated.
	private var activePlannerPhaseStarted = false

	/// Task B: marks the in-flight result as potentially stale due to a minor title
	/// change that occurred while the planner was running.
	private var activePlannerTaskMaybeStale = false

	/// Set by ModelAuditManager while benchmarking. During benchmark, Ollama must be
	/// exclusively available for the audit — live inference would compete for the inference
	/// queue, causing all benchmark samples to appear as timeouts (even for fast models).
	private var auditGateActive = false

	/// Tracks the timestamp of the last planner failure/timeout for each fingerprint.
	private var lastPlannerFailureAt: [String: Date] = [:]
	private var surfacedTitlesHistory: [String] = []
	private var lastSuccessfulResult: TaskInferenceResult? = nil

	// Telemetry variables
	private var totalPlannerCalls = 0
	private var totalPlannerTimeouts = 0
	private var totalPlannerSalvages = 0
	private var totalPlannerSkips = 0
	private var totalPlannerDurationSumMs = 0

	/// Called by ModelAuditManager before and after benchmarking.
	func setAuditGate(_ active: Bool) {
		auditGateActive = active
		print("[TaskInference] audit_gate=\(active ? "acquired" : "released") inference_\(active ? "paused" : "resumed")")
	}

	/// Polled by ModelAuditManager to wait for any current in-flight inference before
	/// starting the benchmark — prevents overlap on the first benchmark sample.
	func isCurrentlyRunning() -> Bool { isInferenceRunning }

	init(
		modelManager: any DynamicGeneratedProposalAvailabilityChecking = ModelManager.shared,
		llm: any TaskInferenceLLMGenerating = LocalAIClient.shared
	) {
		self.modelManager = modelManager
		self.llm = llm
	}

	// MARK: - Main entry point

	func infer(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		recentTitles: [String],
		history: ProposalHistoryMetadata?,
		referenceTime: Date = Date(),
		isEnrichedPass: Bool = false,
		isWarmupReady: Bool = true
	) async -> TaskInferenceResult? {
		let fingerprint = Self.fingerprint(
			snapshot: snapshot,
			situational: situational,
			recentTitles: recentTitles
		)

		if LocalAISettings.shared.twoStageTaskInferenceEnabled {
			if let activeFp = activeFingerprint, activeFp != fingerprint {
				let isMinor = Self.isMinorSameAppChange(old: activeFp, new: fingerprint)
				if isMinor && activePlannerPhaseStarted {
					// Task B: planner is past the router+debounce phase for the same app+workflow.
					// A minor title change (tab switch within same browser session) should not
					// cancel the in-flight planner. Mark result as maybe-stale; validate at activation.
					print("[ContextChurn] weak_title_ignored current=\(situational.windowTitle.prefix(40))...")
					print("[TwoStage] context_changed soft_preserve reason=weak_title_churn")
					activePlannerTaskMaybeStale = true
					return nil  // no new inference started; existing planner result will surface
				} else {
					let hardCancelReason = isMinor ? "planner_not_yet_started" : "app_or_domain_changed"
					print("[ProposalStability] reset reason=context_changed old=\(activeFp) new=\(fingerprint)")
					print("[TwoStage] context changed hard_cancel reason=\(hardCancelReason)")
					activePlannerTask?.cancel()
					activePlannerTask = nil
					activeFingerprint = nil
					activePlannerPhaseStarted = false
					activePlannerTaskMaybeStale = false
				}
			}
			activeFingerprint = fingerprint
			activePlannerPhaseStarted = false
			activePlannerTaskMaybeStale = false

			let task = Task { [weak self] () -> TaskInferenceResult? in
				guard let self = self else { return nil }
				return await self.inferTwoStage(
					snapshot: snapshot,
					situational: situational,
					recentTitles: recentTitles,
					history: history,
					referenceTime: referenceTime,
					fingerprint: fingerprint,
					isEnrichedPass: isEnrichedPass,
					isWarmupReady: isWarmupReady
				)
			}
			activePlannerTask = task
			let result = await task.value

			if self.activeFingerprint == fingerprint {
				// Task B: log stale check before clearing state
				if self.activePlannerTaskMaybeStale {
					print("[GeneratedProposalActivation] stale_check anchor_match=no result=maybe_stale fp=\(fingerprint)")
				} else {
					print("[GeneratedProposalActivation] stale_check anchor_match=yes fp=\(fingerprint)")
				}
				self.activePlannerTask = nil
				self.activeFingerprint = nil
				self.activePlannerPhaseStarted = false
				self.activePlannerTaskMaybeStale = false
			}
			return result
		}

		// Audit gate: ModelAuditManager holds this while benchmarking to get exclusive
		// access to Ollama. During benchmark, live inference would compete for the inference
		// queue and cause every benchmark sample to time out.
		// Single-flight: if inference is already in flight, drop this call rather than
		// queuing a second Ollama request. The caller will trigger again on the next
		// context change. This prevents multiple overlapping /api/generate calls.
		guard !isInferenceRunning else {
			print("[TaskInference] skipped reason=inference_already_running")
			return nil
		}

		// Audit gate: during benchmark we must not compete for Ollama. Still allow cache hits.
		if auditGateActive {
			if let cached = cachedIfFresh(
				fingerprint: fingerprint,
				referenceTime: referenceTime,
				allowStaleFallback: true
			) {
				let age = Int(referenceTime.timeIntervalSince(cached.cachedAt) * 1000)
				print("[TaskInference] cached_used age_ms=\(age) reason=audit_gate_active fp=\(fingerprint)")
				return cached.result
			}
			print("[TaskInference] skipped reason=audit_gate_active fp=\(fingerprint)")
			return nil
		}

		// Cache hit (fresh)
		if let cached = cachedIfFresh(fingerprint: fingerprint, referenceTime: referenceTime) {
			let age = Int(referenceTime.timeIntervalSince(cached.cachedAt) * 1000)
			print("[TaskInference] cached_used age_ms=\(age) fp=\(fingerprint)")
			Task {
				await TaskInferencePerfStats.shared.record(TaskInferencePerfEntry(
					model: ActiveModelTierConfig.shared.taskInferenceModel,
					promptBytes: 0,
					timeoutMs: Int(Self.inferenceTimeoutSeconds * 1000),
					elapsedMs: 0,
					numPredict: 0,
					temperature: 0,
					outputBytes: 0,
					parseSuccess: true,
					outcome: .cached,
					contextRichness: richnessBucket(snapshot: snapshot, situational: situational),
					hasOCR: !(snapshot.recentOCRExcerpt ?? "").isEmpty,
					usedCache: true,
					usedStreaming: false,
					recordedAt: referenceTime
				))
			}
			return cached.result
		}

		// Model availability gate
		guard LocalAISettings.shared.localAIEnabled else {
			print("[TaskInference] skipped reason=\(TaskInferenceSkipReason.modelUnavailable.rawValue)")
			recordSkip(outcome: .unavailable, snapshot: snapshot, situational: situational, referenceTime: referenceTime)
			return nil
		}
		// IMPORTANT: Do not let the startup grace/audit availability gate block task inference.
		// The small model is fast enough to probe directly; if it fails, we treat it as unavailable.
		let withinStartupGrace = (modelManager as? ModelManager)?.isWithinStartupGrace() ?? false
		if withinStartupGrace {
			print("[TaskInference] availability_gate=bypass_startup_grace fp=\(fingerprint)")
		} else {
			guard await modelManager.isGenerationAvailable() else {
				print("[TaskInference] skipped reason=\(TaskInferenceSkipReason.modelUnavailable.rawValue) fp=\(fingerprint)")
				recordSkip(outcome: .unavailable, snapshot: snapshot, situational: situational, referenceTime: referenceTime)
				return nil
			}
		}

		// Select model via tier config (updated by ModelAuditManager).
		// If the audit stored "none", it found no viable model — disable inference gracefully.
		let model = ActiveModelTierConfig.shared.taskInferenceModel
		if model == ModelTierConfig.noViableModel {
			print("[TaskInferenceDisabled] no_viable_model reason=audit_found_none fp=\(fingerprint)")
			recordSkip(outcome: .unavailable, snapshot: snapshot, situational: situational, referenceTime: referenceTime)
			return nil
		}
		ModelTier.taskInference.log(model: model)

		let prompt = TaskInferencePromptBuilder.build(
			snapshot: snapshot,
			situational: situational,
			recentTitles: recentTitles,
			history: history,
			referenceTime: referenceTime
		)
		let numPredict = 120
		let temperature = 0.10
		let timeoutMs = Int(Self.inferenceTimeoutSeconds * 1000)
		let warm = isLikelyWarm
		// Batch mode is used when the audit determined streaming is unreliable for this model.
		let batchMode = LocalAISettings.shared.taskInferenceBatchMode
		print("[TaskInference] started model=\(model) mode=\(batchMode ? "batch" : "stream") warm=\(warm ? "yes" : "no") fp=\(fingerprint) prompt_bytes=\(prompt.utf8.count)")

		// Mark inference as running so concurrent calls are dropped (not queued).
		isInferenceRunning = true
		defer { isInferenceRunning = false }

		let startTime = Date()
		let raw: String
		var usedStreaming = !batchMode
		do {
			(raw, usedStreaming) = try await withInferenceTimeout(timeoutSeconds: Self.inferenceTimeoutSeconds) {
				if batchMode {
					// Batch mode: wait for full response. Useful when streaming is unreliable.
					let output = try await self.llm.generate(
						prompt: prompt,
						model: model,
						numPredict: numPredict,
						temperature: temperature,
						purpose: "task_inference",
						schema: Self.plannerSchema
					)
					return output
				} else {
					// Streaming: stops the moment a balanced {…} is detected — effective latency
					// is the time to the closing brace, not the full num_predict budget.
					print("[StructuredOutput] planner schema_enabled=yes")
					print("[StructuredOutput] format=json_schema")
					let output = try await self.llm.generateStreamingJSON(
						prompt: prompt,
						model: model,
						numPredict: numPredict,
						temperature: temperature,
						purpose: "task_inference",
						schema: Self.plannerSchema
					)
					return output
				}
			}
		} catch TaskInferenceTimeoutError.timeout {
			let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
			// On timeout: try stale cache fallback, otherwise stay quiet.
			if let cached = cachedIfFresh(
				fingerprint: fingerprint,
				referenceTime: referenceTime,
				allowStaleFallback: true
			) {
				let age = Int(referenceTime.timeIntervalSince(cached.cachedAt) * 1000)
				print("[TaskInference] cached_used age_ms=\(age) reason=timeout fp=\(fingerprint)")
				Task {
					await TaskInferencePerfStats.shared.record(TaskInferencePerfEntry(
						model: model,
						promptBytes: prompt.utf8.count,
						timeoutMs: timeoutMs,
						elapsedMs: elapsedMs,
						numPredict: numPredict,
						temperature: temperature,
						outputBytes: 0,
						parseSuccess: true,
						outcome: .cached,
						contextRichness: richnessBucket(snapshot: snapshot, situational: situational),
						hasOCR: !(snapshot.recentOCRExcerpt ?? "").isEmpty,
						usedCache: true,
						usedStreaming: usedStreaming,
						recordedAt: referenceTime
					))
				}
				return cached.result
			}
			// Stay quiet — DO NOT resurrect fallback templates.
			print("[TaskInference] skipped reason=\(TaskInferenceSkipReason.timeout.rawValue) elapsed_ms=\(elapsedMs) warm=\(warm ? "yes" : "no") fp=\(fingerprint)")
			Task {
				await TaskInferencePerfStats.shared.record(TaskInferencePerfEntry(
					model: model,
					promptBytes: prompt.utf8.count,
					timeoutMs: timeoutMs,
					elapsedMs: elapsedMs,
					numPredict: numPredict,
					temperature: temperature,
					outputBytes: 0,
					parseSuccess: false,
					outcome: .timeout,
					contextRichness: richnessBucket(snapshot: snapshot, situational: situational),
					hasOCR: !(snapshot.recentOCRExcerpt ?? "").isEmpty,
					usedCache: false,
					usedStreaming: usedStreaming,
					recordedAt: referenceTime
				))
			}
			return nil
		} catch {
			let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
			print("[TaskInference] skipped reason=\(TaskInferenceSkipReason.modelUnavailable.rawValue) elapsed_ms=\(elapsedMs)")
			Task {
				await TaskInferencePerfStats.shared.record(TaskInferencePerfEntry(
					model: model,
					promptBytes: prompt.utf8.count,
					timeoutMs: timeoutMs,
					elapsedMs: elapsedMs,
					numPredict: numPredict,
					temperature: temperature,
					outputBytes: 0,
					parseSuccess: false,
					outcome: .unavailable,
					contextRichness: richnessBucket(snapshot: snapshot, situational: situational),
					hasOCR: !(snapshot.recentOCRExcerpt ?? "").isEmpty,
					usedCache: false,
					usedStreaming: usedStreaming,
					recordedAt: referenceTime
				))
			}
			return nil
		}

		let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
		let (parsed, failure) = TaskInferenceParser.parseWithFailure(from: raw, referenceTime: referenceTime)
		
		if parsed != nil {
			print("[StructuredOutput] planner valid_json=yes")
		} else {
			let rawPreview = String(raw.prefix(200)).replacingOccurrences(of: "\n", with: "↵")
			print("[StructuredOutput] invalid_response raw=\"\(rawPreview)\"")
		}

		guard let parsed else {
			let outcome: TaskInferencePerfOutcome = failure == .parseMalformedJSON ? .malformedJSON : .parseFailed
			// Log a safe raw preview so we can diagnose model output format issues.
			let rawPreview = String(raw.prefix(220))
				.replacingOccurrences(of: "\n", with: "↵")
				.replacingOccurrences(of: "\t", with: "→")
			print(
				"[TaskInference] skipped reason=\(TaskInferenceSkipReason.parseFailed.rawValue) failure=\(failure?.rawValue ?? "unknown") elapsed_ms=\(elapsedMs) fp=\(fingerprint) raw=«\(rawPreview)»"
			)
			Task {
				await TaskInferencePerfStats.shared.record(TaskInferencePerfEntry(
					model: model,
					promptBytes: prompt.utf8.count,
					timeoutMs: timeoutMs,
					elapsedMs: elapsedMs,
					numPredict: numPredict,
					temperature: temperature,
					outputBytes: raw.utf8.count,
					parseSuccess: false,
					outcome: outcome,
					contextRichness: richnessBucket(snapshot: snapshot, situational: situational),
					hasOCR: !(snapshot.recentOCRExcerpt ?? "").isEmpty,
					usedCache: false,
					usedStreaming: usedStreaming,
					recordedAt: referenceTime
				))
			}
			return nil
		}

		// c=0 with need[] — model requesting context escalation; surface immediately so the
		// caller (DynamicGeneratedProposalEngine) can gather and re-run. Do NOT retry.
		if !parsed.shouldChime && !parsed.need.isEmpty {
			let needList = parsed.need.joined(separator: ",")
			print("[TaskInference] context_escalation_requested need=[\(needList)] reason=\(parsed.needReason ?? "unspecified") pass=cheap")
			return parsed
		}

		// Semantic validation — detect bad outputs before accepting result.
		let validity = TaskInferenceSemanticValidator.validate(
			parsed,
			windowTitle: situational.windowTitle,
			appName: situational.activeAppName,
			selectedText: snapshot.selectedText
		)
		let cats = parsed.neededCapabilityCategories.joined(separator: ",")
		let goalPreview = sanitizeLog(parsed.possibleUserGoal)
		print(
			"[TaskInference] semantic_validation=\(validity.rawValue) chime=\(parsed.shouldChime ? "yes" : "no") conf=\(String(format: "%.2f", parsed.confidence)) needCats=[\(cats)] goal=\(goalPreview) elapsed_ms=\(elapsedMs) warm=\(warm ? "yes" : "no")"
		)

		// placeholder, exampleLeakage, ungroundedOutput all trigger one retry.
		if validity == .placeholder || validity == .exampleLeakage || validity == .ungroundedOutput {
			// Record the attempt with the appropriate outcome, then retry once.
			let richness = richnessBucket(snapshot: snapshot, situational: situational)
			let hasOCR = !(snapshot.recentOCRExcerpt ?? "").isEmpty
			let badOutcome: TaskInferencePerfOutcome
			switch validity {
			case .exampleLeakage: badOutcome = .exampleLeakage
			case .ungroundedOutput: badOutcome = .ungroundedOutput
			default: badOutcome = .placeholder
			}
			Task {
				await TaskInferencePerfStats.shared.record(TaskInferencePerfEntry(
					model: model, promptBytes: prompt.utf8.count, timeoutMs: timeoutMs,
					elapsedMs: elapsedMs, numPredict: numPredict, temperature: temperature,
					outputBytes: raw.utf8.count, parseSuccess: false, outcome: badOutcome,
					contextRichness: richness, hasOCR: hasOCR,
					usedCache: false, usedStreaming: usedStreaming, recordedAt: referenceTime
				))
			}

			// Build ultra-short correction prompt and retry once.
			let invalidFields: [String] = {
				switch validity {
				case .placeholder:       return ["g", "needCats"]
				case .exampleLeakage:    return ["g"]
				case .ungroundedOutput:  return ["g"]
				default:                return ["g", "needCats"]
				}
			}()
			let retryPrompt = TaskInferencePromptBuilder.buildRetryPrompt(
				snapshot: snapshot,
				situational: situational,
				retryReason: validity.rawValue,
				invalidFields: invalidFields
			)
			print("[TaskInference] retry_started reason=\(validity.rawValue) model=\(model) retry_prompt_bytes=\(retryPrompt.utf8.count) fp=\(fingerprint)")
			let retryStart = Date()
			let retryTimeoutS: TimeInterval = 5.0
			let retryRaw: String
			let retryUsedStreaming: Bool
			do {
				(retryRaw, retryUsedStreaming) = try await withInferenceTimeout(timeoutSeconds: retryTimeoutS) {
					// Lower token budget for retry — we only need the compact JSON object.
					// This reduces the chance of the model generating prose after the JSON.
					if batchMode {
						return try await self.llm.generate(prompt: retryPrompt, model: model, numPredict: 80, temperature: 0.05, purpose: "task_inference_retry", schema: Self.plannerSchema)
					} else {
						return try await self.llm.generateStreamingJSON(prompt: retryPrompt, model: model, numPredict: 80, temperature: 0.05, purpose: "task_inference_retry", schema: Self.plannerSchema)
					}
				}
			} catch {
				let retryElapsedMs = Int(Date().timeIntervalSince(retryStart) * 1000)
				print("[TaskInference] retry_failed reason=timeout model=\(model) elapsed_ms=\(retryElapsedMs) fp=\(fingerprint)")
				return nil
			}
			let retryElapsedMs = Int(Date().timeIntervalSince(retryStart) * 1000)
			let (retryParsed, retryFailure) = TaskInferenceParser.parseWithFailure(from: retryRaw, referenceTime: referenceTime)
			guard let retryParsed else {
				let rawPreview = String(retryRaw.prefix(200)).replacingOccurrences(of: "\n", with: "↵")
				print("[TaskInference] retry_failed reason=\(retryFailure?.rawValue ?? "unknown") elapsed_ms=\(retryElapsedMs) fp=\(fingerprint) raw=«\(rawPreview)»")
				return nil
			}
			let retryValidity = TaskInferenceSemanticValidator.validate(
				retryParsed,
				windowTitle: situational.windowTitle,
				appName: situational.activeAppName,
				selectedText: snapshot.selectedText
			)
			if retryValidity == .placeholder || retryValidity == .exampleLeakage || retryValidity == .ungroundedOutput {
				print("[TaskInference] retry_failed reason=still_\(retryValidity.rawValue) elapsed_ms=\(retryElapsedMs) fp=\(fingerprint)")
				return nil
			}
			// Don't count "quiet" as a retry success unless it's accompanied by a structured context request.
			if retryParsed.shouldChime == false, retryParsed.need.isEmpty {
				print("[TaskInference] retry_failed reason=returned_quiet elapsed_ms=\(retryElapsedMs) fp=\(fingerprint)")
				return nil
			}
			// Retry produced a usable result.
			let retryCats = retryParsed.neededCapabilityCategories.joined(separator: ",")
			print("[TaskInference] retry_success chime=\(retryParsed.shouldChime ? "yes" : "no") conf=\(String(format: "%.2f", retryParsed.confidence)) needCats=[\(retryCats)] elapsed_ms=\(retryElapsedMs) fp=\(fingerprint)")
			lastSuccessfulInferenceAt = referenceTime
			Task {
				await TaskInferencePerfStats.shared.record(TaskInferencePerfEntry(
					model: model, promptBytes: retryPrompt.utf8.count, timeoutMs: Int(retryTimeoutS * 1000),
					elapsedMs: retryElapsedMs, numPredict: 80, temperature: 0.05,
					outputBytes: retryRaw.utf8.count, parseSuccess: true, outcome: .successAfterRetry,
					contextRichness: richness, hasOCR: hasOCR,
					usedCache: false, usedStreaming: retryUsedStreaming, recordedAt: referenceTime
				))
			}
			cacheByFingerprint[fingerprint] = Cached(result: retryParsed, cachedAt: referenceTime)
			pruneCache(referenceTime: referenceTime)
			return retryParsed
		}

		// Success — update warm tracker so future calls know model is resident.
		lastSuccessfulInferenceAt = referenceTime
		print(
			"[TaskInference] result chime=\(parsed.shouldChime ? "yes" : "no") conf=\(String(format: "%.2f", parsed.confidence)) needCats=[\(cats)] goal=\(goalPreview) elapsed_ms=\(elapsedMs) warm=\(warm ? "yes" : "no")"
		)

		Task {
			await TaskInferencePerfStats.shared.record(TaskInferencePerfEntry(
				model: model,
				promptBytes: prompt.utf8.count,
				timeoutMs: timeoutMs,
				elapsedMs: elapsedMs,
				numPredict: numPredict,
				temperature: temperature,
				outputBytes: raw.utf8.count,
				parseSuccess: true,
				outcome: .success,
				contextRichness: richnessBucket(snapshot: snapshot, situational: situational),
				hasOCR: !(snapshot.recentOCRExcerpt ?? "").isEmpty,
				usedCache: false,
				usedStreaming: usedStreaming,
				recordedAt: referenceTime
			))
		}

		cacheByFingerprint[fingerprint] = Cached(result: parsed, cachedAt: referenceTime)
		pruneCache(referenceTime: referenceTime)
		return parsed
	
    }

    // MARK: - Two-Stage Inference

	private func inferTwoStage(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		recentTitles: [String],
		history: ProposalHistoryMetadata?,
		referenceTime: Date,
		fingerprint: String,
		isEnrichedPass: Bool,
		isWarmupReady: Bool
	) async -> TaskInferenceResult? {
		if Task.isCancelled { return nil }
		let triggerStart = Date()

		let hasOCR = snapshot.recentOCRExcerpt != nil && !snapshot.recentOCRExcerpt!.isEmpty
		let hasVisual = snapshot.visualContextAvailability.visualSummaryExcerpt != nil && !snapshot.visualContextAvailability.visualSummaryExcerpt!.isEmpty
		
		if !AgenticPivot.isSelectedTextInfluenceEnabled && snapshot.selectedText != nil {
			print("[AgenticPivot] suppressed selected_text influence")
		}
		if !AgenticPivot.isClipboardInfluenceEnabled && snapshot.clipboardText != nil {
			print("[AgenticPivot] suppressed clipboard influence")
		}

		let hasSel = AgenticPivot.isSelectedTextInfluenceEnabled && !(snapshot.selectedText ?? "").isEmpty
		let hasClip = AgenticPivot.isClipboardInfluenceEnabled && !(snapshot.clipboardText ?? "").isEmpty
		let hasTitle = !snapshot.windowTitle.isEmpty
		
		// T18.7.4 — Hard gate: do not attempt generation if context is practically empty.
		let isFunctionallyEmpty: Bool = {
			if !hasTitle && !hasSel && !hasOCR && !hasVisual {
				if !hasClip { return true }
				if situational.primaryAvailableSource == .metadataOnly { return true }
			}
			return false
		}()

		if isFunctionallyEmpty {
			print("[TaskInference] skipped reason=\(TaskInferenceSkipReason.lowContext.rawValue) fp=\(fingerprint)")
			return nil
		}

		// Stage 0: Build and print lightweight context packet
		let typingState = situational.metadata["typingState"] ?? "no"
		let pointerState = situational.metadata["pointerState"] ?? "no"
		let recentChanges = recentTitles.joined(separator: "|")
		let availableSources = snapshot.availableContextTypes.map(\.rawValue).joined(separator: ",")
		
		let visualExcerpt = snapshot.visualContextAvailability.visualSummaryExcerpt ?? ""
		let visualConf = hasVisual ? 0.95 : 0.0
		let visualAgeMs: Int
		if let capturedAt = snapshot.visualContextAvailability.visualCapturedAt {
			visualAgeMs = Int(referenceTime.timeIntervalSince(capturedAt) * 1000)
		} else {
			visualAgeMs = -1
		}
		
		print("[TwoStageContextPacket] app=\"\(situational.activeAppName)\" title=\"\(situational.windowTitle)\" wf=\"\(situational.inferredWorkflow.rawValue)\" cat=\"\(situational.appCategory.rawValue)\" ocr_avail=\(hasOCR ? "yes" : "no") visual_avail=\(hasVisual ? "yes" : "no") typing=\(typingState) pointer=\(pointerState) has_sel=\(hasSel ? "yes" : "no") has_clip=\(hasClip ? "yes" : "no") recent_changes=\"\(recentChanges)\" available_context_sources=\"\(availableSources)\" visual_descriptor_available=\(hasVisual ? "yes" : "no") visual_descriptor_excerpt=\"\(visualExcerpt)\" visual_descriptor_confidence=\(visualConf) visual_descriptor_age_ms=\(visualAgeMs)")

		// Task A — Stability window before router.
		let stabilityWindowStart = Date()
		let att = ProposalAttemptScope.currentId ?? "none"
		print("[ProposalStability] waiting fp=\(fingerprint)")
		
		let stabilityNanoseconds: UInt64 = AgenticPivot.useEarlierProposalSurfacing ? 250_000_000 : 800_000_000
		
		do {
			try await Task.sleep(nanoseconds: stabilityNanoseconds)
		} catch {
			print("[ProposalStability] reset reason=context_changed old=\(fingerprint)")
			return nil
		}
		if Task.isCancelled { return nil }
		let stabilityElapsedMs = Int(Date().timeIntervalSince(stabilityWindowStart) * 1000)
		print("[ProposalStability] stable fp=\(fingerprint) elapsed_ms=\(stabilityElapsedMs)")
		print("[ProposalAttempt] id=\(att) started_after_stability=yes")
		print("[ProposalLatency] stability_ms=\(stabilityElapsedMs)")

		// Warmup gate: allow lightweight visibility if router/planner not ready.
		if !isWarmupReady {
			print("[ProposalWarmupGate] planner_not_ready but_router_ready=yes allowing_lightweight_surface=yes")
			let title = situational.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			if Self.isSpecificTitle(title, appName: situational.activeAppName) {
				let latency = Int(Date().timeIntervalSince(triggerStart) * 1000)
				print("[FastVisibility] eligible=yes source=window_title latency_ms=\(latency)")
				print("[ProposalLatency] first_visible_ms=\(latency)")
				return TaskInferenceResult(
					shouldChime: true,
					possibleUserGoal: title,
					confidence: 0.85,
					neededCapabilityCategories: ["extract"],
					whyNow: "warmup_lightweight_shell",
					missingContext: [],
					expirySeconds: 20,
					createdAt: referenceTime,
					need: [],
					needReason: nil
				)
			} else {
				print("[FastVisibility] eligible=no reason=generic_title")
				return nil
			}
		}

		// Readiness gate: don't run router/planner until Ollama is confirmed reachable.
		// Uses the same coalesced/cached check as single-stage (6s TTL, startup grace).
		print("[LocalAIReady] checking")
		guard await modelManager.isGenerationAvailable() else {
			print("[LocalAIReady] ready=no reason=server_unreachable")
			print("[TaskInference] skipped reason=local_ai_not_ready fp=\(fingerprint)")
			return nil
		}
		print("[LocalAIReady] ready=yes")

		print("[TwoStageRouter] started")

		// Blank desktop suppression
		let appLower = situational.activeAppName.lowercased()
		let titleLower = situational.windowTitle.lowercased()
		if appLower == "finder" && (titleLower.isEmpty || titleLower == "desktop" || titleLower == "finder") {
			print("[TwoStageRouter] decision=insufficient_context reason=blank_desktop_suppression")
			return nil
		}

		// Router phase using a cheap model.
		let routerModel = TaskInferenceEngine.routerModelName
		let routerPrompt = TwoStageRouterPromptBuilder.build(
			snapshot: snapshot,
			situational: situational,
			recentTitles: recentTitles,
			history: history,
			referenceTime: referenceTime
		)

		let routerStart = Date()
		guard await twoStageLane.acquire(purpose: "router") else { return nil }
		if Task.isCancelled {
			await twoStageLane.release(purpose: "router", elapsedMs: Int(Date().timeIntervalSince(routerStart) * 1000))
			return nil
		}

		var routerRaw: String = ""
		do {
			(routerRaw, _) = try await withInferenceTimeout(timeoutSeconds: Self.routerTimeoutSeconds) {
				return try await self.llm.generateStreamingJSON(
					prompt: routerPrompt,
					model: routerModel,
					numPredict: Self.routerNumPredict,
					temperature: 0.10,
					purpose: "task_inference_router",
					schema: Self.routerSchema
				)
			}
		} catch {
			let elapsedMs = Int(Date().timeIntervalSince(routerStart) * 1000)
			print("[TwoStageRouter] failed error=\(error) elapsed_ms=\(elapsedMs)")
			await twoStageLane.release(purpose: "router", elapsedMs: elapsedMs)
			return nil
		}

		let elapsedRouter = Int(Date().timeIntervalSince(routerStart) * 1000)
		await twoStageLane.release(purpose: "router", elapsedMs: elapsedRouter)
		print("[ProposalLatency] router_ms=\(elapsedRouter)")

		if Task.isCancelled { return nil }

		guard let routerObj = Self.parseRouterOutput(routerRaw) else {
			return nil
		}

		let modelDecision = (routerObj["decision"] as? String)?.lowercased() ?? "enough_context"
		var requestedContexts = (routerObj["request"] as? [String]) ?? []
		requestedContexts = requestedContexts.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "none" }

		var finalDecision = modelDecision
		var finalRequestedContexts = requestedContexts

		// Router grounding sufficiency upgrade.
		let hasVisualText = snapshot.visualContextAvailability.visualSummaryExcerpt != nil && !snapshot.visualContextAvailability.visualSummaryExcerpt!.isEmpty
		let hasAX = snapshot.contextSummary?.contains("ax=") == true
		let groundingDecision = RouterGroundingHeuristic.evaluate(
			modelDecision: modelDecision,
			requestedContexts: requestedContexts,
			windowTitle: situational.windowTitle,
			appName: situational.activeAppName,
			workflow: situational.inferredWorkflow.rawValue,
			ocrExcerpt: snapshot.recentOCRExcerpt,
			selectedText: snapshot.selectedText,
			hasVisualDescriptor: hasVisualText,
			hasAXText: hasAX
		)
		if groundingDecision.shouldUpgrade {
			finalDecision = "enough_context"
			finalRequestedContexts = []
			print("[TwoStageRouter] decision=enough_context reason=router_grounding_upgrade")
		}

		if finalDecision == "need_more_context" && !finalRequestedContexts.isEmpty {
			var needMapped: [String] = []
			for req in finalRequestedContexts {
				let r = req.lowercased().trimmingCharacters(in: .whitespaces)
				if r == "ocr" || r == "visible_ocr" { needMapped.append("visible_ocr") }
				else if r == "visual_descriptor" || r == "visual_snapshot" { needMapped.append("visual_descriptor") }
				else if r == "ax_window_text" || r == "browser_text" || r == "ax" { needMapped.append("ax_window_text") }
				else if r == "selected_text" || r == "selection" { needMapped.append("selected_text") }
				else if r == "window_title" { needMapped.append("window_title") }
				else { needMapped.append(req) }
			}
			return TaskInferenceResult(
				shouldChime: false,
				possibleUserGoal: "",
				confidence: 0.8,
				neededCapabilityCategories: [],
				whyNow: "",
				missingContext: [],
				expirySeconds: 20,
				createdAt: referenceTime,
				need: needMapped,
				needReason: "escalation"
			)
		}

		guard finalDecision == "enough_context" else { return nil }

		// Phase 4R: Fast model-generated surfacing path.
		let proposedTitle = routerObj["proposed_title"] as? String ?? ""
		let proposedGoal = routerObj["proposed_goal"] as? String ?? ""

		if !proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
			let isValid = validateProposal(
				title: proposedTitle,
				goal: proposedGoal,
				isolated: isolated
			)

			if isValid && validateDiversity(title: proposedTitle, history: history) {
				let latency = Int(Date().timeIntervalSince(triggerStart) * 1000)
				print("[FastVisibility] eligible=yes source=router_proposed_title latency_ms=\(latency)")
				print("[ProposalLatency] first_visible_ms=\(latency)")
				recordSurfacedTitle(proposedTitle)
				let result = TaskInferenceResult(
					shouldChime: true,
					possibleUserGoal: proposedTitle,
					confidence: 0.85,
					neededCapabilityCategories: ["extract"],
					whyNow: "fast_proposal_shell",
					missingContext: [],
					expirySeconds: 20,
					createdAt: referenceTime,
					need: [],
					needReason: nil
				)
				self.lastSuccessfulResult = result
				print("[PlannerRefinement] pending=yes")
				return result
			}
		}

		// Planner execution.
		let canInvokePlanner = hasOCR || (snapshot.selectedText != nil) || (situational.workflowConfidence >= 0.72)
		if !canInvokePlanner {
			return synthesizeFallbackProposal(snapshot: snapshot, situational: situational, referenceTime: referenceTime, reason: "weak_context")
		}

		// Debounce before planner.
		let debounceNanoseconds: UInt64 = AgenticPivot.useEarlierProposalSurfacing ? 350_000_000 : 1_000_000_000
		print("[TwoStagePlannerDebounce] scheduled fp=\(fingerprint)")
		do {
			try await Task.sleep(nanoseconds: debounceNanoseconds)
		} catch {
			return nil
		}

		activePlannerPhaseStarted = true
		let plannerStart = Date()
		let comparisonHint = await BrowsingComparisonTracker.shared.comparisonSummary(at: referenceTime)
		let plannerPrompt = TwoStageCompactPlannerPromptBuilder.build(
			snapshot: snapshot,
			situational: situational,
			recentTitles: recentTitles,
			history: history,
			referenceTime: referenceTime,
			comparisonHint: comparisonHint,
			strict: false
		)

		guard await twoStageLane.acquire(purpose: "planner") else { return nil }
		var plannerRaw: String = ""
		do {
			(plannerRaw, _) = try await withInferenceTimeout(timeoutSeconds: Self.plannerTimeoutSeconds) {
				return try await self.llm.generateStreamingJSON(
					prompt: plannerPrompt,
					model: TaskInferenceEngine.plannerModelName,
					numPredict: 140,
					temperature: 0.05,
					purpose: "task_inference_planner",
					schema: Self.plannerSchema
				)
			}
		} catch {
			let elapsedMs = Int(Date().timeIntervalSince(plannerStart) * 1000)
			await twoStageLane.release(purpose: "planner", elapsedMs: elapsedMs)
			return handlePlannerFailureRecovery(wasRecovered: false, snapshot: snapshot, situational: situational, referenceTime: referenceTime, reason: "planner_failed")
		}

		let elapsedPlanner = Int(Date().timeIntervalSince(plannerStart) * 1000)
		await twoStageLane.release(purpose: "planner", elapsedMs: elapsedPlanner)
		print("[ProposalLatency] planner_ms=\(elapsedPlanner)")
		let totalLatency = Int(Date().timeIntervalSince(triggerStart) * 1000)
		print("[ProposalLatency] first_visible_ms=\(totalLatency)")
		print("[ProposalLatency] trigger_to_first_visible_ms=\(totalLatency)")

		guard let parsed = Self.parsePlannerCandidates(plannerRaw) else {
			return handlePlannerFailureRecovery(wasRecovered: false, snapshot: snapshot, situational: situational, referenceTime: referenceTime, reason: "planner_failed")
		}

		let isolated = ProposalContextIsolationGate.isolate(snapshot: snapshot)
		guard let selected = PlannerCandidateSelector.select(from: parsed.candidates, snapshot: snapshot, situational: situational) else {
			return handlePlannerFailureRecovery(wasRecovered: false, snapshot: snapshot, situational: situational, referenceTime: referenceTime, reason: "planner_no_candidates")
		}

		let isValid = validateProposal(
			title: selected.title,
			goal: selected.whyUseful ?? "",
			isolated: isolated
		)
		guard isValid else {
			print("[ProposalValidation] rejected stage=early reason=selected_candidate_invalid title=\"\(selected.title)\"")
			return handlePlannerFailureRecovery(wasRecovered: false, snapshot: snapshot, situational: situational, referenceTime: referenceTime, reason: "selected_candidate_rejected")
		}

		let result = TaskInferenceResult(
			shouldChime: parsed.shouldSurface,
			possibleUserGoal: selected.title,
			confidence: selected.confidence,
			neededCapabilityCategories: selected.caps,
			whyNow: selected.whyUseful ?? "planner",
			missingContext: [],
			expirySeconds: 20,
			createdAt: referenceTime,
			need: [],
			needReason: nil
		)
		self.lastSuccessfulResult = result
		return result
	}


	// MARK: - Fingerprint / cache

	static func fingerprint(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		recentTitles: [String]
	) -> String {
		let bundle = (situational.activeBundleId ?? situational.activeAppName).lowercased()
		let wf = situational.inferredWorkflow.rawValue
		let primary = situational.primaryAvailableSource.rawValue
		let hasSel = (snapshot.selectedText ?? "").isEmpty ? "0" : "1"
		let hasOCR = (snapshot.recentOCRExcerpt ?? "").isEmpty ? "0" : "1"
		let title = normalizeTitle(situational.windowTitle)
		let diversity = Set(recentTitles.map { normalizeTitle($0) }).count
		return "\(bundle)|\(wf)|\(primary)|t\(hasSel)o\(hasOCR)|d\(diversity)|\(title)"
	}

	internal static func hasStrongContext(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> Bool {
		if let ocr = snapshot.recentOCRExcerpt, !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		if let ax = snapshot.contextSummary, ax.contains("ax=") && !ax.isEmpty {
			return true
		}
		if let sel = snapshot.selectedText, !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		let title = situational.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		if isSpecificTitle(title, appName: situational.activeAppName) {
			return true
		}
		return false
	}

	internal static func isSpecificTitle(_ title: String, appName: String) -> Bool {
		let lower = title.lowercased()
		guard !lower.isEmpty else { return false }
		let genericTitles = [
			"mozilla firefox", "firefox", "google chrome", "chrome", "safari", "finder",
			"system settings", "system preferences", "new tab", "about:blank", "blank page",
			"untitled", "home", "search", "desktop"
		]
		if genericTitles.contains(lower) || lower == appName.lowercased() {
			return false
		}
		let assistantChrome = ["processing", "controlled interactions", "execute", "chime in", "antigravity", "contextual"]
		for ac in assistantChrome {
			if lower.contains(ac) {
				return false
			}
		}
		let tokens = title.split(separator: " ").map(String.init).filter { $0.count > 1 }
		if tokens.count < 3 {
			return false
		}
		return true
	}

	private func handlePlannerFailureRecovery(
		wasRecovered: Bool,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date,
		reason: String
	) -> TaskInferenceResult {
		if wasRecovered {
			if let existing = lastSuccessfulResult, !existing.possibleUserGoal.isEmpty {
				print("[PlannerRecovery] preserving existing proposal: \(existing.possibleUserGoal)")
				return existing
			} else {
				print("[PlannerRecovery] no_visible_proposal reason=planner_timeout_no_existing_contextual_title")
				return TaskInferenceResult(
					shouldChime: false,
					possibleUserGoal: "",
					confidence: 0.0,
					neededCapabilityCategories: [],
					whyNow: "",
					missingContext: [],
					expirySeconds: 20,
					createdAt: referenceTime,
					need: [],
					needReason: nil
				)
			}
		}
		return synthesizeFallbackProposal(snapshot: snapshot, situational: situational, referenceTime: referenceTime, reason: reason)
	}

	private func synthesizeFallbackProposal(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date,
		reason: String
	) -> TaskInferenceResult {
		print("[FallbackProposal] suppressed reason=\(reason)")

		return TaskInferenceResult(
			shouldChime: false,
			possibleUserGoal: "",
			confidence: 0.0,
			neededCapabilityCategories: [],
			whyNow: "",
			missingContext: [],
			expirySeconds: 20,
			createdAt: referenceTime,
			need: [],
			needReason: nil
		)
	}

	private func cachedIfFresh(
		fingerprint: String,
		referenceTime: Date,
		allowStaleFallback: Bool = false
	) -> Cached? {
		guard let cached = cacheByFingerprint[fingerprint] else { return nil }
		let age = referenceTime.timeIntervalSince(cached.cachedAt)
		if age <= Self.cacheMaxAgeSeconds { return cached }
		if allowStaleFallback, age <= Self.cacheStaleMaxAgeSeconds { return cached }
		return nil
	}

	private func pruneCache(referenceTime: Date) {
		let cutoff = referenceTime.addingTimeInterval(-Self.cacheStaleMaxAgeSeconds)
		cacheByFingerprint = cacheByFingerprint.filter { _, v in v.cachedAt >= cutoff }
	}

	// MARK: - Timeout

	internal enum TaskInferenceTimeoutError: Error {
		case timeout
	}

	/// Returns `(output, usedStreaming)` on success.
	/// The `usedStreaming` flag is set by the caller before invoking this helper.
	private func withInferenceTimeout(
		timeoutSeconds: TimeInterval,
		_ operation: @escaping @Sendable () async throws -> String
	) async throws -> (String, Bool) {
		let nanos = UInt64(max(1.0, timeoutSeconds) * 1_000_000_000)
		let result = try await withThrowingTaskGroup(of: String.self) { group in
			group.addTask {
				try await operation()
			}
			group.addTask {
				try await Task.sleep(nanoseconds: nanos)
				throw TaskInferenceTimeoutError.timeout
			}
			guard let first = try await group.next() else {
				throw TaskInferenceTimeoutError.timeout
			}
			group.cancelAll()
			return first
		}
		// usedStreaming is tracked by the call site — return a placeholder here
		// that will be overridden by the var set before the do-catch.
		return (result, true)
	}

	// MARK: - Helpers

	private func recordSkip(
		outcome: TaskInferencePerfOutcome,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot,
		referenceTime: Date
	) {
		Task {
			await TaskInferencePerfStats.shared.record(TaskInferencePerfEntry(
				model: ActiveModelTierConfig.shared.taskInferenceModel,
				promptBytes: 0,
				timeoutMs: Int(Self.inferenceTimeoutSeconds * 1000),
				elapsedMs: 0,
				numPredict: 0,
				temperature: 0,
				outputBytes: 0,
				parseSuccess: false,
				outcome: outcome,
				contextRichness: richnessBucket(snapshot: snapshot, situational: situational),
				hasOCR: !(snapshot.recentOCRExcerpt ?? "").isEmpty,
				usedCache: false,
				usedStreaming: false,
				recordedAt: referenceTime
			))
		}
	}

	private func richnessBucket(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> String {
		let hasOCR = situational.ocrSignal.availability == .available
		let hasSel = situational.selectedTextSignal.availability == .available
		let hasClip = situational.clipboardSignal.availability == .available && situational.clipboardSignal.canBePrimary
		return TaskInferencePerfStats.richnessBucket(hasOCR: hasOCR, hasSelectedText: hasSel, hasClipboard: hasClip)
	}

	/// Task B: returns true when only the title (and possibly diversity count) changed
	/// but the app bundle and workflow stayed the same. These minor changes should not
	/// hard-cancel a planner that is already running.
	///
	/// Fingerprint format: "bundle|workflow|primary|tXoX|dN|title"
	private static func isMinorSameAppChange(old: String, new: String) -> Bool {
		let oldParts = old.split(separator: "|", maxSplits: 5).map(String.init)
		let newParts = new.split(separator: "|", maxSplits: 5).map(String.init)
		guard oldParts.count >= 2, newParts.count >= 2 else { return false }
		// Same bundle and same workflow → minor change
		return oldParts[0] == newParts[0] && oldParts[1] == newParts[1]
	}

	private static func normalizeTitle(_ title: String) -> String {
		let lower = title.lowercased()
		let trimmed = lower.replacingOccurrences(of: #"[\|\-–—•]+"#, with: " ", options: .regularExpression)
		let collapsed = trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		return collapsed.split(separator: " ").prefix(10).joined(separator: " ")
	}

	static func sanitizePlannerResponse(_ raw: String) -> String {
		var content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		
		// Check for block fences: ```json ... ```
		if content.hasPrefix("```") {
			let lines = content.components(separatedBy: .newlines)
			if lines.count >= 2 {
				let firstLine = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
				if firstLine.hasPrefix("```") {
					var middleLines = Array(lines.dropFirst())
					if let lastLine = middleLines.last?.trimmingCharacters(in: .whitespacesAndNewlines), lastLine == "```" {
						middleLines.removeLast()
					}
					content = middleLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
				}
			}
		}
		
		// Check for single-line inline fences or leftovers:
		if content.hasPrefix("```") {
			let prefixToRemove = content.hasPrefix("```json") ? "```json" : "```"
			content = String(content.dropFirst(prefixToRemove.count)).trimmingCharacters(in: .whitespacesAndNewlines)
			if content.hasSuffix("```") {
				content = String(content.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
			}
		}
		
		return content
	}

	static func extractFirstBalancedJSONObject(from str: String) -> String? {
		var braceDepth = 0
		var inString = false
		var isEscaped = false
		var firstBraceIndex: String.Index? = nil
		
		let chars = Array(str)
		var i = 0
		while i < chars.count {
			let char = chars[i]
			
			if inString {
				if isEscaped {
					isEscaped = false
				} else if char == "\\" {
					isEscaped = true
				} else if char == "\"" {
					inString = false
				}
			} else {
				if char == "\"" {
					inString = true
				} else if char == "{" {
					if braceDepth == 0 {
						firstBraceIndex = str.index(str.startIndex, offsetBy: i)
					}
					braceDepth += 1
				} else if char == "}" {
					if braceDepth > 0 {
						braceDepth -= 1
						if braceDepth == 0, let startIdx = firstBraceIndex {
							let endIdx = str.index(str.startIndex, offsetBy: i)
							return String(str[startIdx...endIdx])
						}
					}
				}
			}
			i += 1
		}
		return nil
	}

	// MARK: - Multi-candidate planner parsing (Part A)

	/// A single action candidate from the multi-candidate planner output.
	struct PlannerCandidate: Sendable {
		let title: String
		let caps: [String]          // capability category strings
		let confidence: Double
		let novelty: Double
		let requires: [String]      // ["title", "ocr", ...]
		let whyUseful: String?
	}

	// Fallback salvaging parser for incomplete/timeout JSON
	static func salvagePartialPlannerOutput(_ raw: String) -> (candidates: [PlannerCandidate], shouldSurface: Bool)? {
		var shouldSurface = false
		if let range = raw.range(of: #""should_surface_softly"\s*:\s*(true|false)"#, options: .regularExpression) {
			let match = String(raw[range])
			if match.contains("true") {
				shouldSurface = true
			}
		}

		var candidates: [PlannerCandidate] = []
		let characters = Array(raw)
		var openBraceIndices: [Int] = []
		
		var i = 0
		var inString = false
		var escape = false
		
		while i < characters.count {
			let ch = characters[i]
			if escape {
				escape = false
				i += 1
				continue
			}
			if ch == "\\" && inString {
				escape = true
				i += 1
				continue
			}
			if ch == "\"" {
				inString.toggle()
				i += 1
				continue
			}
			if inString {
				i += 1
				continue
			}
			
			if ch == "{" {
				openBraceIndices.append(i)
			} else if ch == "}" {
				if let openIdx = openBraceIndices.popLast() {
					let substring = String(characters[openIdx...i])
					if let data = substring.data(using: .utf8),
					   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
						let title = dict["title"] as? String ?? dict["candidate_action_title"] as? String ?? dict["t"] as? String
						if let title = title, !title.isEmpty {
							let capsStr = dict["caps"] as? String ?? dict["suggested_hooks"] as? String ?? dict["h"] as? String ?? ""
							let caps = capsStr.split(separator: ",")
								.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
								.filter { !$0.isEmpty }
							let conf = dict["confidence"] as? Double ?? dict["p"] as? Double ?? 0.8
							let novelty = dict["novelty"] as? Double ?? 0.5
							let requires = dict["requires"] as? [String] ?? ["title"]
							let why = dict["why_useful"] as? String ?? dict["why"] as? String
							
							if !candidates.contains(where: { $0.title == title }) {
								candidates.append(PlannerCandidate(
									title: title,
									caps: caps,
									confidence: conf,
									novelty: novelty,
									requires: requires,
									whyUseful: why
								))
							}
						}
					}
				}
			}
			i += 1
		}

		// Phase 4R — Aggressive trailing-candidate recovery.
		// When the model streamed multiple action objects but only the first
		// closed before the timeout, the brace walker above misses the truncated
		// ones. Probe the raw text for ALL `"title": "..."` occurrences (and the
		// alternate keys the schema accepts). Pair each title with nearby
		// numeric fields via regex. No title regex / template — we use whatever
		// the model wrote and let the downstream validators decide safety.
		let titleKeys: [String] = ["title", "candidate_action_title", "t"]
		for key in titleKeys {
			let pattern = #""\#(key)"\s*:\s*"([^"]+)""#
			guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
			let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
			regex.enumerateMatches(in: raw, options: [], range: nsRange) { match, _, _ in
				guard let match, match.numberOfRanges >= 2,
					  let titleRange = Range(match.range(at: 1), in: raw) else { return }
				let title = String(raw[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
				guard !title.isEmpty else { return }
				if candidates.contains(where: { $0.title == title }) { return }

				// Window the raw text immediately after this title for neighbor field extraction.
				let tailStart = titleRange.upperBound
				// Take up to 240 chars after the title — generous enough to span a partial object.
				let tail: String = {
					let endIndex = raw.index(tailStart, offsetBy: 240, limitedBy: raw.endIndex) ?? raw.endIndex
					return String(raw[tailStart..<endIndex])
				}()

				let caps = extractStringArrayOrCSV(in: tail, key: "caps")
					?? extractStringArrayOrCSV(in: tail, key: "suggested_hooks")
					?? extractStringArrayOrCSV(in: tail, key: "h")
					?? []
				let confidence = extractNumber(in: tail, key: "confidence") ?? extractNumber(in: tail, key: "p") ?? 0.5
				let novelty = extractNumber(in: tail, key: "novelty") ?? 0.5
				let requires = extractStringArrayOrCSV(in: tail, key: "requires") ?? ["title"]
				let why = extractStringValue(in: tail, key: "why_useful") ?? extractStringValue(in: tail, key: "why")

				candidates.append(PlannerCandidate(
					title: title,
					caps: caps.map { $0.lowercased() },
					confidence: max(0, min(1, confidence)),
					novelty: max(0, min(1, novelty)),
					requires: requires,
					whyUseful: why
				))
			}
		}

		guard !candidates.isEmpty else { return nil }

		if !raw.contains("should_surface_softly") {
			shouldSurface = candidates.max(by: { $0.confidence < $1.confidence }).map { $0.confidence > 0.6 } ?? false
		}

		print("[TwoStagePlannerRecovery] status=partial_success actionsRecovered=\(candidates.count) reason=timeout_partial_json")
		return (candidates: candidates, shouldSurface: shouldSurface)
	}

	// MARK: - Phase 4R: trailing-candidate field probes

	/// Extract a string value for `"key": "value"` in `text`. nil if absent.
	private static func extractStringValue(in text: String, key: String) -> String? {
		let pattern = #""\#(key)"\s*:\s*"([^"]*)""#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
		let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
		guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
			  match.numberOfRanges >= 2,
			  let r = Range(match.range(at: 1), in: text) else { return nil }
		return String(text[r])
	}

	/// Extract a numeric value for `"key": <number>` in `text`. nil if absent.
	private static func extractNumber(in text: String, key: String) -> Double? {
		let pattern = #""\#(key)"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
		let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
		guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
			  match.numberOfRanges >= 2,
			  let r = Range(match.range(at: 1), in: text) else { return nil }
		return Double(text[r])
	}

	/// Extract either a JSON string array OR a comma-separated string for the given key.
	/// Returns an empty array when the field exists but is empty; nil when absent.
	private static func extractStringArrayOrCSV(in text: String, key: String) -> [String]? {
		// Array form: "key": ["a", "b"]
		let arrayPattern = #""\#(key)"\s*:\s*\[([^\]]*)\]"#
		if let regex = try? NSRegularExpression(pattern: arrayPattern, options: []) {
			let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
			if let match = regex.firstMatch(in: text, options: [], range: nsRange),
			   match.numberOfRanges >= 2,
			   let r = Range(match.range(at: 1), in: text) {
				let inner = String(text[r])
				let items = inner.split(separator: ",").compactMap { piece -> String? in
					let trimmed = piece.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\""))
					return trimmed.isEmpty ? nil : trimmed
				}
				return items
			}
		}
		// CSV string form: "key": "a, b, c"
		if let value = extractStringValue(in: text, key: key) {
			return value.split(separator: ",")
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
		}
		return nil
	}

	/// Parse the new multi-candidate `actions` array format.
	/// Falls back to old flat format via parseCompactPlanner for backward compat.
	static func parsePlannerCandidates(_ raw: String) -> (candidates: [PlannerCandidate], shouldSurface: Bool)? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let data = trimmed.data(using: .utf8),
			  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			// Try legacy flat format
			if let legacy = parseCompactPlanner(raw) {
				let title = legacy["candidate_action_title"] as? String ?? legacy["t"] as? String ?? ""
				guard !title.isEmpty else { return nil }
				let capsStr = legacy["suggested_hooks"] as? String ?? legacy["h"] as? String ?? ""
				let caps = capsStr.split(separator: ",")
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
					.filter { !$0.isEmpty }
				let conf = legacy["confidence"] as? Double ?? 0.8
				let surf: Bool
				if let sv = legacy["should_surface_softly"] as? Bool { surf = sv }
				else if let sv = legacy["a"] as? Int { surf = sv != 0 }
				else { surf = !title.isEmpty }
				let cand = PlannerCandidate(title: title, caps: caps, confidence: conf, novelty: 0.5, requires: ["title"], whyUseful: nil)
				return (candidates: [cand], shouldSurface: surf)
			}
			
			// Try partial salvaging fallback
			if let salvaged = salvagePartialPlannerOutput(raw) {
				return salvaged
			}
			
			return nil
		}

		// New actions array format
		guard let actions = obj["actions"] as? [[String: Any]], !actions.isEmpty else {
			// Possibly old flat format wrapped in JSON
			if let legacy = parseCompactPlanner(raw) {
				let title = legacy["candidate_action_title"] as? String ?? ""
				guard !title.isEmpty else { return nil }
				let capsStr = legacy["suggested_hooks"] as? String ?? ""
				let caps = capsStr.split(separator: ",")
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
					.filter { !$0.isEmpty }
				let conf = legacy["confidence"] as? Double ?? 0.8
				let surf = legacy["should_surface_softly"] as? Bool ?? !title.isEmpty
				return (candidates: [PlannerCandidate(title: title, caps: caps, confidence: conf, novelty: 0.5, requires: ["title"], whyUseful: nil)], shouldSurface: surf)
			}
			if let salvaged = salvagePartialPlannerOutput(raw) {
				return salvaged
			}
			return nil
		}

		let candidates: [PlannerCandidate] = actions.compactMap { action in
			guard let title = action["title"] as? String, !title.isEmpty else { return nil }
			let capsStr = action["caps"] as? String ?? ""
			let caps = capsStr.split(separator: ",")
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
				.filter { !$0.isEmpty }
			let conf = action["confidence"] as? Double ?? 0.8
			let novelty = action["novelty"] as? Double ?? 0.5
			let requires = action["requires"] as? [String] ?? ["title"]
			let why = action["why_useful"] as? String
			return PlannerCandidate(title: title, caps: caps, confidence: conf, novelty: novelty, requires: requires, whyUseful: why)
		}
		guard !candidates.isEmpty else { return nil }

		let shouldSurface: Bool
		if let sv = obj["should_surface_softly"] as? Bool { shouldSurface = sv }
		else { shouldSurface = candidates.max(by: { $0.confidence < $1.confidence }).map { $0.confidence > 0.6 } ?? false }

		return (candidates: candidates, shouldSurface: shouldSurface)
	}

	// MARK: - Candidate selection (Part B)

	static func parseCompactPlanner(_ raw: String) -> [String: Any]? {
		let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		
		// Attempt 1: Strict JSON decode
		if let data = trimmedRaw.data(using: .utf8),
		   let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
			#if DEBUG
			print("[TwoStagePlanner] parse_success")
			#endif
			return obj
		}
		
		// Attempt 2: Sanitize response and retry decode
		let sanitized = sanitizePlannerResponse(raw)
		#if DEBUG
		print("[TwoStagePlanner] sanitized_json=\(sanitized)")
		#endif
		
		if let data = sanitized.data(using: .utf8),
		   let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
			#if DEBUG
			print("[TwoStagePlanner] parse_recovered_via_sanitizer")
			#endif
			return obj
		}
		
		// Attempt 3: Extract first balanced {...} JSON object
		if let balanced = extractFirstBalancedJSONObject(from: raw) {
			#if DEBUG
			print("[TwoStagePlanner] sanitized_json=\(balanced)")
			#endif
			if let data = balanced.data(using: .utf8),
			   let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
				#if DEBUG
				print("[TwoStagePlanner] parse_recovered_via_sanitizer")
				#endif
				return obj
			}
		}

		// Attempt 4: Single-to-double quote repair
		let repaired = repairSingleQuotes(sanitized)
		if let data = repaired.data(using: .utf8),
		   let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
			#if DEBUG
			print("[TwoStagePlanner] parse_recovered_via_single_quote_repair")
			#endif
			return obj
		}

		// Attempt 5: Regex fallback extraction
		if let dict = regexExtractPlannerFields(raw) {
			#if DEBUG
			print("[TwoStagePlanner] parse_recovered_via_regex")
			#endif
			return dict
		}
		
		#if DEBUG
		print("[TwoStagePlanner] parse_failed_final raw=\(raw)")
		#endif
		return nil
	}

	static func repairSingleQuotes(_ raw: String) -> String {
		return raw.replacingOccurrences(of: "'", with: "\"")
	}

	static func regexExtractRouterFields(_ raw: String) -> [String: Any]? {
		var dict: [String: Any] = [:]
		
		// Extract decision
		if let decMatch = raw.range(of: #""decision"\s*:\s*"([^"]+)""#, options: .regularExpression) {
			let sub = raw[decMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if valPart.hasPrefix("\""), valPart.hasSuffix("\"") {
					dict["decision"] = String(valPart.dropFirst().dropLast())
				}
			}
		}
		
		// Extract reason
		if let reasonMatch = raw.range(of: #""reason"\s*:\s*"([^"]+)""#, options: .regularExpression) {
			let sub = raw[reasonMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if valPart.hasPrefix("\""), valPart.hasSuffix("\"") {
					dict["reason"] = String(valPart.dropFirst().dropLast())
				}
			}
		}
		
		// Extract confidence
		if let confMatch = raw.range(of: #""confidence"\s*:\s*([0-9\.]+)"#, options: .regularExpression) {
			let sub = raw[confMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if let val = Double(valPart) {
					dict["confidence"] = val
				}
			}
		} else if let confMatch = raw.range(of: #""p"\s*:\s*([0-9\.]+)"#, options: .regularExpression) {
			let sub = raw[confMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if let val = Double(valPart) {
					dict["confidence"] = val
				}
			}
		}
		
		// Extract request array
		if let reqMatch = raw.range(of: #""request"\s*:\s*\[([^\]]*)\]"#, options: .regularExpression) {
			let sub = raw[reqMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if valPart.hasPrefix("["), valPart.hasSuffix("]") {
					let inner = valPart.dropFirst().dropLast()
					let items = inner.split(separator: ",").map {
						$0.trimmingCharacters(in: .whitespacesAndNewlines)
						  .replacingOccurrences(of: "\"", with: "")
						  .replacingOccurrences(of: "'", with: "")
					}.filter { !$0.isEmpty }
					dict["request"] = items
				}
			}
		}
		
		if dict["decision"] != nil {
			// Extract proposed_title
			if let titleMatch = raw.range(of: #""proposed_title"\s*:\s*"([^"]+)""#, options: .regularExpression) {
				let sub = raw[titleMatch]
				if let colonIdx = sub.firstIndex(of: ":") {
					let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
					if valPart.hasPrefix("\""), valPart.hasSuffix("\"") {
						dict["proposed_title"] = String(valPart.dropFirst().dropLast())
					}
				}
			}
			// Extract proposed_goal
			if let goalMatch = raw.range(of: #""proposed_goal"\s*:\s*"([^"]+)""#, options: .regularExpression) {
				let sub = raw[goalMatch]
				if let colonIdx = sub.firstIndex(of: ":") {
					let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
					if valPart.hasPrefix("\""), valPart.hasSuffix("\"") {
						dict["proposed_goal"] = String(valPart.dropFirst().dropLast())
					}
				}
			}
			return dict
		}
		return nil
	}

	static func regexExtractPlannerFields(_ raw: String) -> [String: Any]? {
		var dict: [String: Any] = [:]
		
		let keys = ["inferred_activity", "evidence", "candidate_action_title", "suggested_hooks", "reason", "t", "h"]
		for key in keys {
			let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
			if let matchRange = raw.range(of: pattern, options: .regularExpression) {
				let sub = raw[matchRange]
				if let colonIdx = sub.firstIndex(of: ":") {
					let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
					if valPart.hasPrefix("\""), valPart.hasSuffix("\"") {
						dict[key] = String(valPart.dropFirst().dropLast())
					}
				}
			}
		}
		
		// Extract confidence
		if let confMatch = raw.range(of: #""confidence"\s*:\s*([0-9\.]+)"#, options: .regularExpression) {
			let sub = raw[confMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if let val = Double(valPart) {
					dict["confidence"] = val
					dict["p"] = val
				}
			}
		} else if let confMatch = raw.range(of: #""p"\s*:\s*([0-9\.]+)"#, options: .regularExpression) {
			let sub = raw[confMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if let val = Double(valPart) {
					dict["confidence"] = val
					dict["p"] = val
				}
			}
		}
		
		// Extract should_surface_softly / a
		if let surfaceMatch = raw.range(of: #""should_surface_softly"\s*:\s*(true|false|1|0)"#, options: .regularExpression) {
			let sub = raw[surfaceMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if valPart == "true" || valPart == "1" {
					dict["should_surface_softly"] = true
					dict["a"] = 1
				} else {
					dict["should_surface_softly"] = false
					dict["a"] = 0
				}
			}
		} else if let surfaceMatch = raw.range(of: #""a"\s*:\s*(true|false|1|0)"#, options: .regularExpression) {
			let sub = raw[surfaceMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if valPart == "true" || valPart == "1" {
					dict["should_surface_softly"] = true
					dict["a"] = 1
				} else {
					dict["should_surface_softly"] = false
					dict["a"] = 0
				}
			}
		}
		
		// Extract required_context array
		if let reqMatch = raw.range(of: #""required_context"\s*:\s*\[([^\]]*)\]"#, options: .regularExpression) {
			let sub = raw[reqMatch]
			if let colonIdx = sub.firstIndex(of: ":") {
				let valPart = sub[sub.index(after: colonIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
				if valPart.hasPrefix("["), valPart.hasSuffix("]") {
					let inner = valPart.dropFirst().dropLast()
					let items = inner.split(separator: ",").map {
						$0.trimmingCharacters(in: .whitespacesAndNewlines)
						  .replacingOccurrences(of: "\"", with: "")
						  .replacingOccurrences(of: "'", with: "")
					}.filter { !$0.isEmpty }
					dict["required_context"] = items
				}
			}
		}
		
		if dict["candidate_action_title"] != nil || dict["inferred_activity"] != nil || dict["t"] != nil {
			return dict
		}
		return nil
	}

	struct RouterBoostResult {
		let score: Double
		let reasons: [String]
	}

	static func computeDeterministicBoost(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> RouterBoostResult {
		var score: Double = 0.0
		var reasons: [String] = []

		let appLower = (situational.activeAppName).lowercased()
		let titleLower = (situational.windowTitle).lowercased()
		let wf = situational.inferredWorkflow
		
		// 1. Xcode and debugging workflow
		if appLower == "xcode" {
			score += 0.8
			reasons.append("Xcode editor")
		} else if wf == .debugging {
			score += 0.5
			reasons.append("debugging workflow")
		}

		// 2. Title product-like keywords
		let productKeywords = ["amazon", "product", "price", "shop", "cart", "checkout", "buy", "store", "review", "rating", "ebay", "walmart", "target", "aliexpress", "aliexpress.com", "shopify"]
		for kw in productKeywords {
			if titleLower.contains(kw) {
				score += 0.9
				reasons.append("product keyword (\(kw))")
				break
			}
		}

		// 4. Title search result pages
		let searchKeywords = ["google search", "bing search", "search results", "query=", "search?q="]
		for kw in searchKeywords {
			if titleLower.contains(kw) {
				score += 0.5
				reasons.append("search result keyword (\(kw))")
				break
			}
		}

		// 5. Title code-like terms
		let codeKeywords = [".swift", ".py", ".js", ".ts", ".json", ".yml", ".yaml", ".xml", "github", "gitlab", "terminal", "vscode", "cursor"]
		for kw in codeKeywords {
			if titleLower.contains(kw) {
				score += 0.6
				reasons.append("code/developer keyword (\(kw))")
				break
			}
		}

		// 6. Selected text presence
		if let sel = snapshot.selectedText, !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let count = sel.count
			if count > 0 {
				score += 0.7
				reasons.append("selected text (\(count) chars)")
			}
		}

		// 7. Clipboard length and recent
		if let clip = snapshot.clipboardText, !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let count = clip.count
			if count > 300 {
				score += 0.6
				reasons.append("long clipboard text (\(count) chars)")
			}
		}

		// 8. Visual OCR with meaningful text
		if let ocr = snapshot.recentOCRExcerpt, !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let count = ocr.count
			if count > 500 {
				if wf == .browsing || wf == .reviewing || wf == .debugging {
					score += 0.8
					reasons.append("long OCR (\(count) chars) in active \(wf) workflow")
				} else {
					score += 0.5
					reasons.append("long OCR (\(count) chars)")
				}
			}
		}

		// 9. Compare / research / review workflows
		if titleLower.contains("compare") || titleLower.contains("review") || titleLower.contains("research") {
			score += 0.4
			reasons.append("active research workflow title")
		}

		// 10. Forms / applications / signups
		let formKeywords = ["form", "sign up", "register", "application", "checkout", "billing", "shipping"]
		for kw in formKeywords {
			if titleLower.contains(kw) {
				score += 0.5
				reasons.append("form/application title (\(kw))")
				break
			}
		}

		return RouterBoostResult(score: score, reasons: reasons)
	}

	static func parseRouterOutput(_ raw: String) -> [String: Any]? {
		let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		
		// Attempt 1: Strict JSON decode
		if let data = trimmedRaw.data(using: .utf8),
		   let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
			return obj
		}
		
		// Attempt 2: Sanitize response and retry decode
		let sanitized = sanitizePlannerResponse(raw)
		if let data = sanitized.data(using: .utf8),
		   let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
			return obj
		}
		
		// Attempt 3: Extract first balanced {...} JSON object
		if let balanced = extractFirstBalancedJSONObject(from: raw) {
			if let data = balanced.data(using: .utf8),
			   let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
				return obj
			}
		}

		// Attempt 4: Single-to-double quote repair
		let repaired = repairSingleQuotes(sanitized)
		if let data = repaired.data(using: .utf8),
		   let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
			return obj
		}

		// Attempt 5: Regex fallback extraction
		if let dict = regexExtractRouterFields(raw) {
			return dict
		}
		
		return nil
	}

	private func sanitizeLog(_ s: String) -> String {
		let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return "none" }
		return String(trimmed.prefix(72)).replacingOccurrences(of: "\n", with: " ")
	}

	/// Performs safety, capability, literal scanning, and grounding checks using ProposalCapabilityValidator.
	private func validateProposal(
		title: String,
		goal: String,
		isolated: IsolatedProposalContext
	) -> Bool {
		let res = ProposalCapabilityValidator.validate(
			title: title,
			goal: goal,
			isolated: isolated,
			stage: "early"
		)
		if !res.accepted {
			print("[ProposalValidation] rejected stage=early reason=\(res.reason) title=\"\(title)\"")
		}
		print("[ProposalValidation] context_consistent=yes stage=early_to_activation")
		return res.accepted
	}

	/// Checks semantic diversity against surfacedTitlesHistory and recentProposalTitles in history.
	private func validateDiversity(title: String, history: ProposalHistoryMetadata?) -> Bool {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return false }
		let lower = trimmed.lowercased()

		// 1. Prefix check (repeated leading verb suppression)
		let words = lower.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
		if let firstWord = words.first {
			let allRecent = (surfacedTitlesHistory + (history?.recentProposalTitles ?? [])).map { $0.lowercased() }
			var matchCount = 0
			for recentTitle in allRecent.prefix(5) {
				let recentWords = recentTitle.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
				if let rFirst = recentWords.first, rFirst == firstWord {
					matchCount += 1
				}
			}
			if matchCount > 2 {
				print("[ProposalDiversity] repeated_prefix=yes prefix=\(firstWord)")
				return false
			}
		}

		// 2. Similarity check (word overlap Jaccard index)
		let allRecent = (surfacedTitlesHistory + (history?.recentProposalTitles ?? []))
		for recentTitle in allRecent {
			let score = wordOverlapSimilarity(lower, recentTitle.lowercased())
			if score > 0.8 {
				print("[ProposalDiversity] similarity_score=\(String(format: "%.2f", score)) suppressed=yes")
				return false
			}
		}

		print("[ProposalDiversity] repeated_prefix=no")
		return true
	}

	private func wordOverlapSimilarity(_ s1: String, _ s2: String) -> Double {
		let w1 = Set(s1.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
		let w2 = Set(s2.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
		if w1.isEmpty || w2.isEmpty { return 0.0 }
		let intersection = w1.intersection(w2)
		let union = w1.union(w2)
		return Double(intersection.count) / Double(union.count)
	}

	private func recordSurfacedTitle(_ title: String) {
		surfacedTitlesHistory.insert(title, at: 0)
		if surfacedTitlesHistory.count > 10 {
			surfacedTitlesHistory = Array(surfacedTitlesHistory.prefix(10))
		}
	}

	// (No hook IDs are passed to the small model. Hook planning happens after inference.)
}

// MARK: - Planner candidate selection (Part B)

/// Scores and selects the best action candidate from the planner's multi-candidate output.
/// Applies generic penalties for low-utility actions and bonuses for context availability.
/// Not a domain-specific gate — no hardcoded "Amazon bad" rules.
enum PlannerCandidateSelector {
	static func select(
		from candidates: [TaskInferenceEngine.PlannerCandidate],
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> TaskInferenceEngine.PlannerCandidate? {
		guard !candidates.isEmpty else { return nil }

		print("[PlannerCandidates] count=\(candidates.count)")
		for c in candidates {
			print("[PlannerCandidate] title=\"\(c.title)\" confidence=\(String(format: "%.2f", c.confidence)) novelty=\(String(format: "%.2f", c.novelty)) requires=[\(c.requires.joined(separator: ","))] capabilities=[\(c.caps.joined(separator: ","))]")
		}

		let appLower = situational.activeAppName.lowercased()
		let titleLower = situational.windowTitle.lowercased().prefix(30)
		let hasOCR = (snapshot.recentOCRExcerpt ?? "").count > 50
		let hasSel = (snapshot.selectedText ?? "").count > 0
		let hasClip = (snapshot.clipboardText ?? "").count > 0

		var scored: [(candidate: TaskInferenceEngine.PlannerCandidate, score: Double, reason: String)] = []

		for c in candidates {
			var score = c.confidence * 0.55 + c.novelty * 0.35
			var reason = "baseline"

			// T18.7.2 — Normalize capabilities (handle slash-delimited, comma-delimited, etc.)
			let normalizedCaps: [String] = c.caps.flatMap { cap in
				cap.lowercased()
					.components(separatedBy: CharacterSet(charactersIn: "/, "))
					.map { $0.trimmingCharacters(in: .punctuationCharacters) }
					.filter { !$0.isEmpty }
			}
			
			let att = ProposalAttemptScope.currentId ?? "none"
			print("[ProposalAttempt] id=\(att) planner_candidates=\(candidates.count)")
			print("[PlannerCandidateSelection] title=\"\(c.title)\" normalized_caps=\(normalizedCaps)")

			// Generic low-capability penalty (T18.3.3F): reject candidates that only sense context.
			// Candidates must have at least one operational capability (extract, reason, compare, etc.)
			// AND ideally an output capability.
			let hasOutput = normalizedCaps.contains("output") || normalizedCaps.contains("compare") || normalizedCaps.contains("organize")
			let hasOperation = normalizedCaps.contains("extract") || normalizedCaps.contains("reason") ||
							 normalizedCaps.contains("compare") || normalizedCaps.contains("organize") ||
							 normalizedCaps.contains("control") || normalizedCaps.contains("utility") ||
							 normalizedCaps.contains("memory") || normalizedCaps.contains("debug") ||
							 normalizedCaps.contains("study")

			print("[PlannerCandidateSelection] has_operation=\(hasOperation ? "yes" : "no") has_output=\(hasOutput ? "yes" : "no")")

			if normalizedCaps.allSatisfy({ $0 == "context" }) {
				// Pure sensing candidate with no operation or output.
				print("[PlannerCandidateSelection] rejected title=\"\(c.title)\" reason=context_only_candidate")
				continue
			}

			if !hasOutput && !normalizedCaps.contains("control") {
				if hasOperation {
					// T18.7 — Allow intent-only candidates; HookScriptDiscovery will find the output path.
					print("[PlannerCandidateSelection] selected title=\"\(c.title)\" despite_missing_output reason=hook_discovery_can_add_output")
					print("[PlannerCandidateSelection] implied_capability=output")
				} else {
					// Caps are unreliable (planner sometimes emits generic verbs or filename strings
					// instead of canonical category tokens). Fall back to title-verb intent inference
					// before rejecting — derive transform/reason intent from the candidate's title.
					let titleLower2 = c.title.lowercased()
					let transformVerbs: [String] = [
						"edit", "fix", "modify", "update", "refactor", "rewrite", "improve",
						"clean", "rename", "delete", "add", "create", "generate", "write"
					]
					let reasonVerbs: [String] = [
						"view", "inspect", "review", "explain", "understand", "analyze",
						"check", "read", "find", "search", "debug", "trace", "diagnose"
					]
					if transformVerbs.contains(where: { titleLower2.contains($0) }) {
						print("[PlannerCandidateSelection] inferred_intent_from_title=transform title=\"\(c.title)\"")
						print("[PlannerCandidateSelection] accepted reason=title_intent")
						// Fall through: let this candidate score normally
					} else if reasonVerbs.contains(where: { titleLower2.contains($0) }) {
						print("[PlannerCandidateSelection] inferred_intent_from_title=reason title=\"\(c.title)\"")
						print("[PlannerCandidateSelection] accepted reason=title_intent")
						// Fall through: let this candidate score normally
					} else {
						// No operation, no output, no recognizable title verb — dead-end sensing chain.
						print("[PlannerCandidateSelection] rejected title=\"\(c.title)\" reason=no_output_path")
						continue
					}
				}
			}

			if !hasOperation && !normalizedCaps.contains("output") {
				// Only "context" + "output" is valid but weak utility.
				score -= 0.15
				reason = "low_operation_utility"
			}

			// Generic low-utility penalty: describes current state rather than offering an operation
			let lower = c.title.lowercased()
			let openVerbs = ["open ", "view ", "browse ", "go to ", "navigate to ", "visit "]
			for verb in openVerbs {
				if lower.hasPrefix(verb) {
					// Only penalize if the action title mentions the same app or page currently open
					if lower.contains(appLower) || lower.contains(titleLower) {
						score -= 0.35
						reason = "low_utility_describes_current_state"
						break
					}
				}
			}

			// Context availability bonus: prefer candidates whose requires are already met
			var contextBonus = 0.0
			for req in c.requires {
				switch req {
				case "ocr":           if hasOCR  { contextBonus += 0.04 }
				case "selected_text": if hasSel  { contextBonus += 0.04 }
				case "clipboard":     if hasClip { contextBonus += 0.02 }
				default: break
				}
			}
			score += contextBonus

			// Novelty boost: highly specific candidates get a small bonus
			if c.novelty >= 0.8 { score += 0.05 }

			scored.append((c, score, reason))
		}

		let sorted = scored.sorted { $0.score > $1.score }

		guard let best = sorted.first else { return nil }
		print("[PlannerCandidateSelection] selected=\"\(best.candidate.title)\" score=\(String(format: "%.3f", best.score)) reason=\"\(best.reason)\"")
		for rejected in sorted.dropFirst() {
			print("[PlannerCandidateSelection] rejected title=\"\(rejected.candidate.title)\" reason=\"\(rejected.reason)\"")
		}
		return best.candidate
	}
}

// MARK: - Thread-safe progressive partial tracker
final class SharedPartialString: @unchecked Sendable {
	private let lock = NSLock()
	private var value = ""
	private var firstTokenElapsedMs: Int? = nil
	private let startTime = Date()

	func update(_ newValue: String) {
		lock.lock()
		defer { lock.unlock() }
		value = newValue
		if firstTokenElapsedMs == nil && !newValue.isEmpty {
			firstTokenElapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
		}
	}

	var current: String {
		lock.lock()
		defer { lock.unlock() }
		return value
	}

	var firstTokenMs: Int? {
		lock.lock()
		defer { lock.unlock() }
		return firstTokenElapsedMs
	}
}
