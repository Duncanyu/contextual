import Foundation

protocol TaskInferenceLLMGenerating: Sendable {
	func generate(
		prompt: String,
		model: String,
		numPredict: Int,
		temperature: Double,
		purpose: String?
	) async throws -> String

	/// Streaming variant: accumulates tokens and returns as soon as a balanced `{…}` JSON object
	/// is detected. Dramatically reduces effective latency vs waiting for full num_predict tokens.
	func generateStreamingJSON(
		prompt: String,
		model: String,
		numPredict: Int,
		temperature: Double,
		purpose: String?
	) async throws -> String
}

extension LocalAIClient: TaskInferenceLLMGenerating {}

/// Fast, timeout-bounded task inference using a small local model (task inference tier).
///
/// On every attempt emits [TaskInferencePerf] with full metadata.
/// Rolling stats are maintained in TaskInferencePerfStats.
/// Model selection is delegated to ActiveModelTierConfig (populated by ModelAuditManager).
/// On timeout: stay quiet — no generic template fallback.
actor TaskInferenceEngine {
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
		referenceTime: Date = Date()
	) async -> TaskInferenceResult? {
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

		let fingerprint = Self.fingerprint(
			snapshot: snapshot,
			situational: situational,
			recentTitles: recentTitles
		)

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

		let hookIds = contextFilteredHookIds(snapshot: snapshot, situational: situational)
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
		let qPresent = !parsed.userFacingQuestion.isEmpty
		let caps = parsed.neededCapabilities.joined(separator: ",")
		let question = qPresent ? " q=\"\(String(parsed.userFacingQuestion.prefix(60)))\"" : ""
		print(
			"[TaskInference] semantic_validation=\(validity.rawValue) chime=\(parsed.shouldChime ? "yes" : "no") conf=\(String(format: "%.2f", parsed.confidence)) hooks_count=\(parsed.neededCapabilities.count) question=\(qPresent ? "yes" : "no") task=\(sanitizeLog(parsed.inferredTaskType)) caps=[\(caps)]\(question) elapsed_ms=\(elapsedMs) warm=\(warm ? "yes" : "no")"
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
				case .placeholder:       return ["g", "a", "o", "h", "q"]
				case .exampleLeakage:    return ["g", "o", "q"]
				case .ungroundedOutput:  return ["g", "a", "o", "q"]
				default:                return ["g", "a", "o", "h", "q"]
				}
			}()
			let retryPrompt = TaskInferencePromptBuilder.buildRetryPrompt(
				snapshot: snapshot,
				situational: situational,
				hookIds: hookIds,
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
			print("[TaskInference] retry_success chime=\(retryParsed.shouldChime ? "yes" : "no") conf=\(String(format: "%.2f", retryParsed.confidence)) caps=[\(retryParsed.neededCapabilities.joined(separator: ","))] elapsed_ms=\(retryElapsedMs) fp=\(fingerprint)")
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

		// Success (valid or noHooks) — update warm tracker so future calls know model is resident.
		lastSuccessfulInferenceAt = referenceTime
		print(
			"[TaskInference] result chime=\(parsed.shouldChime ? "yes" : "no") conf=\(String(format: "%.2f", parsed.confidence)) task=\(sanitizeLog(parsed.inferredTaskType)) caps=[\(caps)]\(question) elapsed_ms=\(elapsedMs) warm=\(warm ? "yes" : "no")"
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

	private func sanitizeLog(_ s: String) -> String {
		let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return "none" }
		return String(trimmed.prefix(72)).replacingOccurrences(of: "\n", with: " ")
	}

	/// Returns the same context-filtered hook IDs the prompt builder selects.
	/// Used to pass the hook list to `buildRetryPrompt` without re-running prompt construction.
	private func contextFilteredHookIds(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> [String] {
		// Delegate to the prompt builder's internal selection. We call `build` but only
		// need the hook list; cheapest approach is to extract it via the same builder call
		// since build() is idempotent and fast (no network, no AI).
		// This small duplication is acceptable; the alternative is making contextFilteredHooks public.
		var ids: [String] = ["observe_current_context"]
		let cat = situational.appCategory
		let wf = situational.inferredWorkflow
		let hasText = situational.selectedTextSignal.availability == .available
			|| situational.ocrSignal.availability == .available
			|| (situational.clipboardSignal.availability == .available && situational.clipboardSignal.canBePrimary)
		if wf == .debugging || (snapshot.recentOCRExcerpt ?? "").lowercased().contains("error") {
			ids += ["explain_visible_error", "extract_error_messages"]
		}
		if cat == .browser || wf == .browsing || wf == .research {
			ids += ["extract_product_attributes", "compare_items", "summarize_context"]
		}
		if cat == .ide { ids += ["extract_code_symbols", "extract_error_messages"] }
		if cat == .notes || wf == .writing { ids += ["structure_key_points", "summarize_context"] }
		if hasText && !ids.contains("summarize_context") { ids += ["summarize_context"] }
		ids.append("present_result")
		var seen: Set<String> = []
		return ids.filter { seen.insert($0).inserted }.prefix(8).map { $0 }
	}
}
