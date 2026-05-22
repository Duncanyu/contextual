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
		schema: [String: Any]?
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
		purpose: String?
	) async throws -> String {
		try await generateStreamingJSON(prompt: prompt, model: model, numPredict: numPredict, temperature: temperature, purpose: purpose, schema: nil)
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

	private struct Cached: Sendable {
		let result: TaskInferenceResult
		let cachedAt: Date
	}

	private let modelManager: any DynamicGeneratedProposalAvailabilityChecking
	private let llm: any TaskInferenceLLMGenerating
	private var cacheByFingerprint: [String: Cached] = [:]

	/// Streaming hard timeout. Streaming stops early when JSON closes, so effective
	/// latency is much lower than this cap. phi3 warm = ~2-4s; qwen2.5:0.5b = ~0.5s.
	static let inferenceTimeoutSeconds: TimeInterval = 6.0
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

	/// Set by ModelAuditManager while benchmarking. During benchmark, Ollama must be
	/// exclusively available for the audit — live inference would compete for the inference
	/// queue, causing all benchmark samples to appear as timeouts (even for fast models).
	private var auditGateActive = false

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
		isEnrichedPass: Bool = false
	) async -> TaskInferenceResult? {
		let fingerprint = Self.fingerprint(
			snapshot: snapshot,
			situational: situational,
			recentTitles: recentTitles
		)

		if LocalAISettings.shared.twoStageTaskInferenceEnabled {
			if let activeFp = activeFingerprint, activeFp != fingerprint {
				print("[TwoStage] context changed (fp: \(activeFp) -> \(fingerprint)). Cancelling active planner task.")
				activePlannerTask?.cancel()
				activePlannerTask = nil
				activeFingerprint = nil
			}
			activeFingerprint = fingerprint

			let task = Task { [weak self] () -> TaskInferenceResult? in
				guard let self = self else { return nil }
				return await self.inferTwoStage(
					snapshot: snapshot,
					situational: situational,
					recentTitles: recentTitles,
					history: history,
					referenceTime: referenceTime,
					fingerprint: fingerprint,
					isEnrichedPass: isEnrichedPass
				)
			}
			activePlannerTask = task
			let result = await task.value

			if self.activeFingerprint == fingerprint {
				self.activePlannerTask = nil
				self.activeFingerprint = nil
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
						purpose: "task_inference"
					)
					return output
				} else {
					// Streaming: stops the moment a balanced {…} is detected — effective latency
					// is the time to the closing brace, not the full num_predict budget.
					let output = try await self.llm.generateStreamingJSON(
						prompt: prompt,
						model: model,
						numPredict: numPredict,
						temperature: temperature,
						purpose: "task_inference"
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
						return try await self.llm.generate(prompt: retryPrompt, model: model, numPredict: 80, temperature: 0.05, purpose: "task_inference_retry")
					} else {
						return try await self.llm.generateStreamingJSON(prompt: retryPrompt, model: model, numPredict: 80, temperature: 0.05, purpose: "task_inference_retry")
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
		isEnrichedPass: Bool
	) async -> TaskInferenceResult? {
		if Task.isCancelled { return nil }

		// Stage 0: Build and print lightweight context packet
		let hasOCR = snapshot.recentOCRExcerpt != nil && !snapshot.recentOCRExcerpt!.isEmpty
		let hasVisual = snapshot.visualContextAvailability.visualSummaryExcerpt != nil && !snapshot.visualContextAvailability.visualSummaryExcerpt!.isEmpty
		let hasSel = !(snapshot.selectedText ?? "").isEmpty
		let hasClip = !(snapshot.clipboardText ?? "").isEmpty
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

		print("[TwoStageRouter] started")

		// Blank desktop suppression (only deterministic safety logic kept)
		let appLower = situational.activeAppName.lowercased()
		let titleLower = situational.windowTitle.lowercased()
		if appLower == "finder" && (titleLower.isEmpty || titleLower == "desktop" || titleLower == "finder") {
			print("[TwoStageRouter] decision=insufficient_context reason=blank_desktop_suppression")
			return nil
		}

		// Router phase using a cheap model.
		let routerModel = "qwen2.5:0.5b"
		let plannerModel = "qwen2.5:1.5b"

		// Build lightweight router prompt.
		let routerPrompt = TwoStageRouterPromptBuilder.build(
			snapshot: snapshot,
			situational: situational,
			recentTitles: recentTitles,
			history: history,
			referenceTime: referenceTime
		)

		// Acquire lane for router.
		let routerStart = Date()
		guard await twoStageLane.acquire(purpose: "router") else { return nil }
		if Task.isCancelled {
			await twoStageLane.release(purpose: "router", elapsedMs: Int(Date().timeIntervalSince(routerStart) * 1000))
			return nil
		}

		var routerRaw: String = ""
		var routerUsedStreaming = true
		do {
			(routerRaw, routerUsedStreaming) = try await withInferenceTimeout(timeoutSeconds: Self.inferenceTimeoutSeconds) {
				try await self.llm.generateStreamingJSON(
					prompt: routerPrompt,
					model: routerModel,
					numPredict: 80,
					temperature: 0.10,
					purpose: "task_inference_router"
				)
			}
		} catch {
			print("[TwoStageRouter] failed error=\(error)")
			await twoStageLane.release(purpose: "router", elapsedMs: Int(Date().timeIntervalSince(routerStart) * 1000))
			return nil
		}

		let elapsedRouter = Int(Date().timeIntervalSince(routerStart) * 1000)
		await twoStageLane.release(purpose: "router", elapsedMs: elapsedRouter)

		if Task.isCancelled { return nil }

		// Parse router output tolerantly.
		guard let routerObj = Self.parseRouterOutput(routerRaw) else {
			let rawPreview = routerRaw.replacingOccurrences(of: "\n", with: "↵")
			print("[TwoStageRouter] raw=\(rawPreview)")
			print("[TwoStageRouter] parsed=nil")
			print("[TwoStageRouter] decision=insufficient_context")
			print("[TwoStageRouter] JSON parse failed raw=\(routerRaw)")
			return nil
		}

		let modelDecision: String
		if let dec = routerObj["decision"] as? String {
			let lowerDec = dec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if lowerDec == "enough_context" || lowerDec == "classify_now" {
				modelDecision = "enough_context"
			} else if lowerDec == "need_more_context" || lowerDec == "insufficient_context" {
				modelDecision = "need_more_context"
			} else {
				modelDecision = lowerDec
			}
		} else {
			modelDecision = "enough_context"
		}

		var requestedContexts: [String] = []
		if let reqArr = routerObj["request"] as? [String] {
			requestedContexts = reqArr
		} else if let reqArr = routerObj["request"] as? String {
			requestedContexts = reqArr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
		} else if let needArr = routerObj["need"] as? [String] {
			requestedContexts = needArr
		} else if let needStr = routerObj["need"] as? String {
			requestedContexts = needStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
		}
		requestedContexts = requestedContexts.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "none" }

		print("[TwoStageRouter] raw=\(routerRaw.replacingOccurrences(of: "\n", with: "↵"))")
		print("[TwoStageRouter] parsed=\(routerObj)")
		
		var finalDecision = modelDecision
		var finalRequestedContexts = requestedContexts

		if isEnrichedPass {
			var suppressedAny = false
			var filteredRequested: [String] = []
			for req in finalRequestedContexts {
				let lowerReq = req.lowercased().trimmingCharacters(in: .whitespaces)
				if lowerReq == "ocr" || lowerReq == "visible_ocr" {
					if let ocr = snapshot.recentOCRExcerpt, !ocr.isEmpty {
						print("[TwoStageRouter] repeated_context_request_suppressed source=\(req)")
						suppressedAny = true
						continue
					}
				} else if lowerReq == "visual_descriptor" {
					if let vis = snapshot.visualContextAvailability.visualSummaryExcerpt, !vis.isEmpty {
						print("[TwoStageRouter] repeated_context_request_suppressed source=\(req)")
						suppressedAny = true
						continue
					}
				} else if lowerReq == "ax_window_text" || lowerReq == "browser_text" {
					if let summary = snapshot.contextSummary, summary.contains("ax=") {
						print("[TwoStageRouter] repeated_context_request_suppressed source=\(req)")
						suppressedAny = true
						continue
					}
				}
				filteredRequested.append(req)
			}
			
			if suppressedAny {
				finalRequestedContexts = filteredRequested
				// Usable context check:
				let hasTitle = !situational.windowTitle.isEmpty
				let hasOCRText = snapshot.recentOCRExcerpt != nil && !snapshot.recentOCRExcerpt!.isEmpty
				let hasVisualText = snapshot.visualContextAvailability.visualSummaryExcerpt != nil && !snapshot.visualContextAvailability.visualSummaryExcerpt!.isEmpty
				let hasAX = snapshot.contextSummary?.contains("ax=") == true
				let hasSelected = snapshot.selectedText != nil && !snapshot.selectedText!.isEmpty
				let hasClipboard = snapshot.clipboardText != nil && !snapshot.clipboardText!.isEmpty
				
				let usableContextExists = hasTitle || hasOCRText || hasVisualText || hasAX || hasSelected || hasClipboard
				if usableContextExists {
					finalDecision = "enough_context"
					finalRequestedContexts = []
					print("[TwoStageRouter] decision=enough_context reason=enriched_context_available")
				}
			}
		}

		print("[TwoStageRouter] decision=\(finalDecision)")
		
		let reqsStr = "[" + finalRequestedContexts.map { "\"\($0)\"" }.joined(separator: ",") + "]"
		print("[TwoStageRouter] requested_context=\(reqsStr)")

		if finalDecision == "need_more_context" {
			var needMapped: [String] = []
			for req in finalRequestedContexts {
				if req == "ocr" || req == "visible_ocr" {
					needMapped.append("visible_ocr")
				} else if req == "visual_descriptor" {
					needMapped.append("visual_descriptor")
				} else if req == "ax_window_text" || req == "browser_text" {
					needMapped.append("ax_window_text")
				} else {
					needMapped.append(req)
				}
			}
			if !needMapped.isEmpty {
				return TaskInferenceResult(
					shouldChime: false,
					possibleUserGoal: "",
					confidence: routerObj["confidence"] as? Double ?? routerObj["p"] as? Double ?? 0.8,
					neededCapabilityCategories: [],
					whyNow: "",
					missingContext: [],
					expirySeconds: 20,
					createdAt: referenceTime,
					need: needMapped,
					needReason: "escalation"
				)
			} else {
				print("[TwoStageRouter] need_more_context but requested_context empty, staying quiet.")
				return nil
			}
		}

		guard finalDecision == "enough_context" else {
			print("[TwoStageRouter] decision=\(finalDecision), staying quiet.")
			return nil
		}

		// Debounce before planner.
		print("[TwoStagePlannerDebounce] scheduled fp=\(fingerprint)")
		do {
			try await Task.sleep(nanoseconds: 1_000_000_000) // 1000ms
		} catch {
			print("[TwoStagePlannerDebounce] cancelled during sleep fp=\(fingerprint)")
			return nil
		}

		if Task.isCancelled { return nil }
		print("[TwoStagePlannerDebounce] fired")

		// Planner phase.
		let plannerPrompt = TwoStageCompactPlannerPromptBuilder.build(
			snapshot: snapshot,
			situational: situational,
			recentTitles: recentTitles,
			history: history,
			referenceTime: referenceTime
		)

		let plannerStart = Date()
		guard await twoStageLane.acquire(purpose: "planner") else { return nil }
		if Task.isCancelled {
			await twoStageLane.release(purpose: "planner", elapsedMs: Int(Date().timeIntervalSince(plannerStart) * 1000))
			return nil
		}

		var plannerRaw: String = ""
		var plannerUsedStreaming = true
		do {
			(plannerRaw, plannerUsedStreaming) = try await withInferenceTimeout(timeoutSeconds: 2.5) {
				try await self.llm.generateStreamingJSON(
					prompt: plannerPrompt,
					model: plannerModel,
					numPredict: 120,
					temperature: 0.10,
					purpose: "task_inference_planner"
				)
			}
		} catch {
			print("[TwoStagePlanner] failed error=\(error)")
			await twoStageLane.release(purpose: "planner", elapsedMs: Int(Date().timeIntervalSince(plannerStart) * 1000))
			return nil
		}

		let elapsedPlanner = Int(Date().timeIntervalSince(plannerStart) * 1000)
		await twoStageLane.release(purpose: "planner", elapsedMs: elapsedPlanner)

		if Task.isCancelled { return nil }

		// Parse compact planner output.
		guard let plannerObj = Self.parseCompactPlanner(plannerRaw) else {
			let rawPreview = plannerRaw.replacingOccurrences(of: "\n", with: "↵")
			print("[TwoStagePlanner] raw=\(rawPreview)")
			print("[TwoStagePlanner] parsed=nil")
			print("[TwoStagePlanner] action=no")
			print("[TwoStagePlanner] quiet=yes reason=parse_failed")
			return nil
		}

		let activity = plannerObj["inferred_activity"] as? String ?? "unknown"
		let confidence = plannerObj["confidence"] as? Double ?? plannerObj["p"] as? Double ?? 0.85
		let evidence = plannerObj["evidence"] as? String ?? plannerObj["reason"] as? String ?? "stable context"
		let goal = plannerObj["candidate_action_title"] as? String ?? plannerObj["t"] as? String ?? ""
		let shouldChime: Bool
		if let surfaceVal = plannerObj["should_surface_softly"] as? Bool {
			shouldChime = surfaceVal
		} else if let surfaceVal = plannerObj["should_surface_softly"] as? Int {
			shouldChime = (surfaceVal != 0)
		} else if let surfaceVal = plannerObj["should_surface_softly"] as? String {
			let lower = surfaceVal.lowercased()
			shouldChime = (lower == "true" || lower == "1" || lower == "yes")
		} else if let aVal = plannerObj["a"] as? Int {
			shouldChime = (aVal != 0)
		} else if let aVal = plannerObj["a"] as? Bool {
			shouldChime = aVal
		} else {
			shouldChime = !goal.isEmpty
		}

		let categories: [String]
		if let hVal = plannerObj["suggested_hooks"] as? String {
			categories = hVal.split(separator: ",")
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
				.filter { !$0.isEmpty }
		} else if let hArr = plannerObj["suggested_hooks"] as? [String] {
			categories = hArr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
				.filter { !$0.isEmpty }
		} else if let hVal = plannerObj["h"] as? String {
			categories = hVal.split(separator: ",")
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
				.filter { !$0.isEmpty }
		} else if let hArr = plannerObj["h"] as? [String] {
			categories = hArr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
				.filter { !$0.isEmpty }
		} else {
			categories = []
		}

		let reqCtx: [String]
		if let reqArr = plannerObj["required_context"] as? [String] {
			reqCtx = reqArr
		} else if let reqStr = plannerObj["required_context"] as? String {
			reqCtx = reqStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
		} else {
			reqCtx = ["title"]
		}

		print("[TwoStagePlanner] raw=\(plannerRaw.replacingOccurrences(of: "\n", with: "↵"))")
		print("[TwoStagePlanner] parsed=\(plannerObj)")
		print("[TwoStagePlanner] inferred_activity=\(activity)")
		print("[TwoStagePlanner] evidence=\(evidence)")
		print("[TwoStagePlanner] required_context=\(reqCtx.joined(separator: "/"))")

		let plannerResult = TaskInferenceResult(
			shouldChime: shouldChime,
			possibleUserGoal: goal,
			confidence: confidence,
			neededCapabilityCategories: categories,
			whyNow: evidence,
			missingContext: [],
			expirySeconds: 20,
			createdAt: referenceTime,
			need: [],
			needReason: nil
		)

		return plannerResult
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

	private enum TaskInferenceTimeoutError: Error {
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

	// (No hook IDs are passed to the small model. Hook planning happens after inference.)
}

