import Foundation

// MARK: - Types

struct ModelAuditBenchmarkResult: Sendable {
	let modelName: String
	let avgLatencyMs: Double
	let timeoutRate: Double
	let malformedRate: Double
	let parseSuccessRate: Double
	let sampleCount: Int
	let isRecommended: Bool
}

private struct SmokeTestResult: Sendable {
	let model: String
	let gotAnyBytes: Bool      // Did Ollama return ANY data before timeout?
	let streamingWorked: Bool  // Did streaming specifically succeed?
	let prefersBatch: Bool     // Streaming failed but batch succeeded — use batch for inference
	let parsedOK: Bool         // Did the minimal response contain expected content?
	let elapsedMs: Int
}

// MARK: - Manager

/// Discovers installed local Ollama models and benchmarks candidates for task inference.
///
/// Fast-model-first strategy:
/// - Task inference needs a tiny, fast, JSON-reliable model (not heavy models).
/// - Preferred: phi4-mini
/// - If none are installed, automatically pulls phi4-mini.
/// - Planner/executor tiers remain on the user's configured base model (phi4-mini, etc.).
///
/// Contention prevention:
/// - Acquires TaskInferenceEngine.auditGate before every benchmark run so that live task
///   inference cannot compete with benchmark requests for Ollama's inference queue.
///   Without this gate, other live-inference occupies Ollama while phi4-mini is being
///   benchmarked, causing the fast model to appear as 100% timeout — a false negative.
actor ModelAuditManager {
	static let shared = ModelAuditManager()

	// MARK: - Model catalogue

	/// Ordered preference for fast task inference models (< 2 GB, reliable JSON, < 2s warm).
	/// heavy models are intentionally ABSENT — they belong on planner/executor tier.
	private static let fastInferenceCandidates: [String] = [
		"qwen2.5:0.5b",
		"phi4-mini",
	]

	/// Auto-pull when no fast model is installed. phi4-mini pulls in ~30-90s.
	private static let autoPullModel = "phi4-mini"

	// MARK: - Timing constants

	private static let auditCooldown: TimeInterval = 3600
	/// Smoke test streaming timeout — generous to accommodate cold model load (1-4s) + first tokens.
	private static let smokeStreamingTimeout: TimeInterval = 12.0
	/// Smoke test batch fallback timeout — batch waits for full response, needs a bit more headroom.
	private static let smokeBatchTimeout: TimeInterval = 15.0
	/// Per-sample benchmark timeout — must be >= production inference timeout (6s).
	private static let benchmarkTimeout: TimeInterval = 8.0
	private static let benchmarkSamples = 3
	/// Max time to wait for an in-flight live inference to finish before benchmarking.
	private static let auditGateWaitSeconds: TimeInterval = 9.0
	/// Keepalive ping interval (Ollama default idle unload = 5 min).
	private static let keepaliveInterval: TimeInterval = 4 * 60

	// MARK: - State

	/// Persisted cooldown anchor (across launches) so we don't pause live task inference
	/// behind the audit gate on every app start.
	private var lastAuditAt: Date? {
		get { LocalAISettings.shared.taskInferenceLastAuditAt }
		set { LocalAISettings.shared.taskInferenceLastAuditAt = newValue }
	}
	private var selectedTaskInferenceModel: String?
	private var discoveredModels: [String] = []
	private var benchmarkResults: [ModelAuditBenchmarkResult] = []
	private var keepaliveTask: Task<Void, Never>?

	// MARK: - Public API

	func selectedModel() -> String? { selectedTaskInferenceModel }
	func lastDiscoveredModels() -> [String] { discoveredModels }
	func lastBenchmarkResults() -> [ModelAuditBenchmarkResult] { benchmarkResults }

	func runAuditIfNeeded(baseModel: String) async {
		if let last = lastAuditAt, Date().timeIntervalSince(last) < Self.auditCooldown { return }
		await runAudit(baseModel: baseModel)
	}

	// MARK: - Full audit

	func runAudit(baseModel: String) async {
		print("[LocalAIReady] checking")
		print("[ModelAudit] started base_model=\(baseModel)")
		lastAuditAt = Date()

		// ── Step 1: discover installed models ──────────────────────────────────────
		var installed = await fetchInstalledModels()
		discoveredModels = installed
		if installed.isEmpty {
			print("[LocalAIReady] ready=no reason=no_models_installed")
		} else {
			print("[LocalAIReady] ready=yes models=\(installed.count)")
		}
		print("[ModelAudit] discovered=[\(installed.joined(separator: ","))]")

		// ── Two-stage model readiness verification ─────────────────────────────────
		// Log which models are available for router (qwen2.5:0.5b) and planner (phi4-mini).
		// Only these two models are permitted for task inference — do NOT report heavy model readiness.
		let routerAvailable = installed.contains { modelNameMatches($0, candidate: "qwen2.5:0.5b") }
		let plannerAvailable = installed.contains { modelNameMatches($0, candidate: "phi4-mini") }
		print("[TwoStageModelReady] router=qwen2.5:0.5b available=\(routerAvailable ? "yes" : "no")")
		print("[TwoStageModelReady] planner=phi4-mini available=\(plannerAvailable ? "yes" : "no")")

		if installed.isEmpty {
			print("[ModelAudit] no_models_found cannot_benchmark")
			return  // Don't commit any selection — leave previous (or nil) in place.
		}

		// ── Step 2: pull fast model if missing ────────────────────────────────────
		if !hasFastInferenceModel(installed) {
			print("[ModelAudit] no_fast_model_found attempting_pull model=\(Self.autoPullModel)")
			let pulled = await ModelManager.shared.pullModel(named: Self.autoPullModel)
			if pulled {
				print("[ModelAudit] auto_pull_succeeded model=\(Self.autoPullModel)")
				installed.append(Self.autoPullModel)
				discoveredModels = installed
			} else {
				print("[ModelAudit] auto_pull_failed model=\(Self.autoPullModel)")
			}
		}

		// ── Step 3: build candidate list (fast models only) ───────────────────────
		// heavy models are excluded unless they are the ONLY thing available.
		var toTest: [String] = Self.fastInferenceCandidates.compactMap { candidate in
			installed.first { name in modelNameMatches(name, candidate: candidate) }
		}
		var seen: Set<String> = []
		toTest = toTest.filter { seen.insert($0).inserted }

		if toTest.isEmpty {
			// No fast model found even after pull attempt. Benchmark the base model as
			// last resort — at least we'll know its real performance characteristics.
			let baseMatch = installed.first { modelNameMatches($0, candidate: baseModel) } ?? baseModel
			toTest = [baseMatch]
			print("[ModelAudit] no_fast_models_available benchmarking_base_model=\(baseMatch)")
		}

		print("[ModelAudit] candidates=[\(toTest.joined(separator: ","))]")

		// ── Step 4: acquire audit gate ────────────────────────────────────────────
		// This prevents live inference from competing with benchmark requests for
		// Ollama's inference queue. Without it, other live-inference can occupy the
		// queue for 5-7s, making every phi4-mini benchmark sample time out.
		await TaskInferenceEngine.shared.setAuditGate(true)

		// Wait for any currently-running inference to finish (max 9s).
		let gateWaitStart = Date()
		while await TaskInferenceEngine.shared.isCurrentlyRunning() {
			let elapsed = Date().timeIntervalSince(gateWaitStart)
			if elapsed >= Self.auditGateWaitSeconds {
				print("[ModelAudit] gate_wait_timeout elapsed_s=\(Int(elapsed)) proceeding_anyway")
				break
			}
			try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms poll
		}
		let gateWaitMs = Int(Date().timeIntervalSince(gateWaitStart) * 1000)
		print("[ModelAudit] gate_acquired waited_ms=\(gateWaitMs)")

		// ── Step 5: smoke test + benchmark each candidate ─────────────────────────
		var results: [ModelAuditBenchmarkResult] = []

		for model in toTest.prefix(4) {
			// 5a: Smoke test — can the model return ANY structured bytes at all?
			// This distinguishes "streaming is broken" from "model too slow for schema".
			let smoke = await runSmokeTest(model: model)
			let modeLabel = smoke.prefersBatch ? "batch" : (smoke.streamingWorked ? "stream" : "none")
			print("[ModelAudit] smoke model=\(model) ok=\(smoke.parsedOK) bytes=\(smoke.gotAnyBytes ? "yes" : "no") mode=\(modeLabel) elapsed_ms=\(smoke.elapsedMs)")

			if !smoke.gotAnyBytes {
				// Model produced zero bytes in BOTH streaming and batch — genuine failure.
				// Not just slow — truly unresponsive. Skip full benchmark.
				print("[ModelAudit] smoke_total_failure model=\(model) skipping_full_benchmark")
				let r = ModelAuditBenchmarkResult(
					modelName: model, avgLatencyMs: 9999,
					timeoutRate: 1.0, malformedRate: 0, parseSuccessRate: 0,
					sampleCount: 0, isRecommended: false
				)
				results.append(r)
				continue
			}

			// 5b: Full benchmark — 3 samples × inference contexts.
			// If the smoke test found batch works but streaming doesn't, benchmark in batch mode.
			let r = await benchmarkModel(model, useBatch: smoke.prefersBatch)
			results.append(r)
			print(
				"[ModelAudit] benchmark model=\(model) latency=\(Int(r.avgLatencyMs))ms success=\(String(format: "%.0f", r.parseSuccessRate * 100))% timeout=\(String(format: "%.0f", r.timeoutRate * 100))%"
			)
		}
		benchmarkResults = results

		// ── Step 6: release audit gate ────────────────────────────────────────────
		await TaskInferenceEngine.shared.setAuditGate(false)

		// select winner ─────────────────────────────────────────────────
		// Require at least 1/3 samples to parse successfully. If nothing meets the bar,
		// do NOT fall back — log the failure and leave the previous selection.
		let viable = results.filter { $0.parseSuccessRate > 0 }
		guard let best = viable.min(by: {
			let diff = $0.parseSuccessRate - $1.parseSuccessRate
			if abs(diff) > 0.15 { return diff > 0 }
			return $0.avgLatencyMs < $1.avgLatencyMs
		}) else {
			print("[ModelAudit] no_viable_model_found all_candidates_failed smoke_or_benchmark")
			print("[ModelSelection] task_inference_disabled reason=no_viable_model")
			print("[ModelValidation] failed all_models_rejected")
			// Store the "none" sentinel — the engine reads this and disables inference
			// explicitly rather than silently falling back.
			LocalAISettings.shared.taskInferenceModel = ModelTierConfig.noViableModel
			ActiveModelTierConfig.shared.update(.from(settings: LocalAISettings.shared, auditSelected: ModelTierConfig.noViableModel))
			return
		}

		commitSelection(best.modelName, reason: "benchmark_winner")
	}

	// MARK: - Smoke test

	/// Test whether a model can produce ANY structured output at all.
	///
	/// Two-phase strategy:
	/// 1. Streaming (12s timeout) — preferred path. Logs first-byte timing.
	/// 2. Batch fallback (15s timeout) — for models/configs where streaming is unreliable.
	///
	/// If batch succeeds but streaming fails, marks the model as `prefersBatch` and persists
	/// `taskInferenceBatchMode = true` so the engine uses batch for live inference.
	///
	/// A smoke failure means ZERO bytes arrived in both modes — genuine connectivity problem.
	private func runSmokeTest(model: String) async -> SmokeTestResult {
		// Simplest possible prompt — model needs to emit ~10 tokens.
		// Using literal text rather than JSON escape sequences to reduce encoding issues.
		let prompt = "Respond with only this JSON, nothing else: {\"ok\":true}"
		let overallStart = Date()

		// ── Phase 1: streaming ────────────────────────────────────────────────────
		print("[ModelAudit] smoke_stream_attempt model=\(model) timeout_s=\(Int(Self.smokeStreamingTimeout))")
		let streamStart = Date()
		do {
			let output = try await withTimeout(Self.smokeStreamingTimeout) {
				try await LocalAIClient.shared.generateStreamingJSON(
					prompt: prompt,
					model: model,
					numPredict: 30,
					temperature: 0.0,
					purpose: "smoke_test"
				)
			}
			let ms = Int(Date().timeIntervalSince(streamStart) * 1000)
			let hasContent = output.contains("{") || output.contains("ok") || output.count > 2
			let preview = String(output.prefix(120)).replacingOccurrences(of: "\n", with: " ")
			print("[ModelAudit] smoke_stream_ok model=\(model) elapsed_ms=\(ms) has_content=\(hasContent) output=«\(preview)»")
			return SmokeTestResult(
				model: model, gotAnyBytes: true, streamingWorked: true,
				prefersBatch: false, parsedOK: hasContent,
				elapsedMs: ms
			)
		} catch {
			let ms = Int(Date().timeIntervalSince(streamStart) * 1000)
			print("[ModelAudit] smoke_stream_failed model=\(model) elapsed_ms=\(ms) error=\(error.localizedDescription.prefix(100))")
		}

		// ── Phase 2: batch fallback ───────────────────────────────────────────────
		print("[ModelAudit] smoke_batch_attempt model=\(model) timeout_s=\(Int(Self.smokeBatchTimeout))")
		let batchStart = Date()
		do {
			let output = try await withTimeout(Self.smokeBatchTimeout) {
				try await LocalAIClient.shared.generate(
					prompt: prompt,
					model: model,
					numPredict: 30,
					temperature: 0.0,
					purpose: "smoke_test"
				)
			}
			let ms = Int(Date().timeIntervalSince(batchStart) * 1000)
			let hasContent = output.contains("{") || output.contains("ok") || output.count > 2
			let preview = String(output.prefix(120)).replacingOccurrences(of: "\n", with: " ")
			print("[ModelAudit] smoke_batch_ok model=\(model) elapsed_ms=\(ms) has_content=\(hasContent) output=«\(preview)» → will_use_batch_mode")
			// Persist batch preference so the engine uses batch for this model going forward.
			LocalAISettings.shared.taskInferenceBatchMode = true
			return SmokeTestResult(
				model: model, gotAnyBytes: true, streamingWorked: false,
				prefersBatch: true, parsedOK: hasContent,
				elapsedMs: ms
			)
		} catch {
			let ms = Int(Date().timeIntervalSince(batchStart) * 1000)
			print("[ModelAudit] smoke_batch_failed model=\(model) elapsed_ms=\(ms) error=\(error.localizedDescription.prefix(100))")
		}

		let totalMs = Int(Date().timeIntervalSince(overallStart) * 1000)
		print("[ModelAudit] smoke_complete_failure model=\(model) total_ms=\(totalMs) both_streaming_and_batch_failed")
		return SmokeTestResult(
			model: model, gotAnyBytes: false, streamingWorked: false,
			prefersBatch: false, parsedOK: false, elapsedMs: totalMs
		)
	}

	// MARK: - Full benchmark

	/// Five representative inference contexts, from simplest to richest.
	/// The model must produce valid compact JSON for each to be considered viable.
	private static let benchmarkSamples_: [(name: String, prompt: String)] = [
		(
			"minimal",
			"""
			JSON only. Keys: c(0/1) g(goal) a(verb) o(obj) h(hooks[]) p(conf 0-1)
			caps∈[observe_current_context,present_result]
			app=Safari wf=browsing title=Google
			ocr=0 sel=0 clip=0
			"""
		),
		(
			"browser_product",
			"""
			JSON only. Keys: c(0/1) g(goal) a(verb) o(obj) h(hooks[]) q(question) p(conf 0-1)
			caps∈[observe_current_context,extract_product_attributes,compare_items,summarize_context,present_result]
			app=Chrome cat=browser wf=browsing
			title=iPhone 16 Pro Max Review — The Verge
			ocr=1 sel=0 clip=0
			ocr=Performance benchmarks show 30% improvement over iPhone 15 Pro. Battery life excellent.
			"""
		),
		(
			"ide_debug",
			"""
			JSON only. Keys: c(0/1) g(goal) a(verb) o(obj) h(hooks[]) q(question) p(conf 0-1)
			caps∈[observe_current_context,explain_visible_error,extract_error_messages,inspect_stacktrace,present_result]
			app=Xcode cat=ide wf=debugging
			title=ContentView.swift
			ocr=0 sel=1 clip=0
			sel=Fatal error: Index out of range. Stack: Array.subscript getter
			"""
		),
		(
			"research_compare",
			"""
			JSON only. Keys: c(0/1) g(goal) a(verb) o(obj) h(hooks[]) q(question) p(conf 0-1)
			caps∈[observe_current_context,extract_entities,compare_items,synthesize_research_takeaways,present_result]
			app=Chrome cat=browser wf=research
			title=DJI Mini 4 Pro vs Mini 3 Pro — Which Should You Buy?
			recent=DJI Mini 3 Pro specs|DJI Mini 4 Pro price|Best drones 2024
			ocr=1 sel=0 clip=0
			ocr=Mini 4 Pro: $759, omnidirectional obstacle avoidance, 4K60fps. Mini 3 Pro: $469, 3-way sensors.
			"""
		),
		(
			"notes_writing",
			"""
			JSON only. Keys: c(0/1) g(goal) a(verb) o(obj) h(hooks[]) q(question) p(conf 0-1)
			caps∈[observe_current_context,extract_entities,structure_key_points,generate_checklist,present_result]
			app=Notes cat=notes wf=writing
			title=Q3 Product Roadmap
			ocr=0 sel=1 clip=0
			sel=Feature A: launch Sept. Feature B: delayed to Oct. Feature C: cancelled. Need stakeholder update.
			"""
		),
	]

	private func benchmarkModel(_ model: String, useBatch: Bool = false) async -> ModelAuditBenchmarkResult {
		let samples = Self.benchmarkSamples_
		var latencies: [Double] = []
		var successes = 0
		var timeouts = 0
		var malformed = 0

		// Run first N samples (cap to benchmarkSamples to keep audit time bounded).
		for i in 0..<min(Self.benchmarkSamples, samples.count) {
			let (name, prompt) = samples[i]
			let start = Date()
			do {
				let output = try await withTimeout(Self.benchmarkTimeout) {
					if useBatch {
						return try await LocalAIClient.shared.generate(
							prompt: prompt,
							model: model,
							numPredict: 120,
							temperature: 0.1,
							purpose: "model_audit"
						)
					} else {
						return try await LocalAIClient.shared.generateStreamingJSON(
							prompt: prompt,
							model: model,
							numPredict: 120,
							temperature: 0.1,
							purpose: "model_audit"
						)
					}
				}
				let ms = Date().timeIntervalSince(start) * 1000
				latencies.append(ms)
				let (parsed, _) = TaskInferenceParser.parseWithFailure(from: output)
				if parsed != nil {
					successes += 1
					print("[ModelAudit] sample model=\(model) ctx=\(name) #\(i+1) latency=\(Int(ms))ms parse=ok outputBytes=\(output.utf8.count)")
				} else {
					malformed += 1
					let preview = String(output.prefix(80)).replacingOccurrences(of: "\n", with: " ")
					print("[ModelAudit] sample model=\(model) ctx=\(name) #\(i+1) latency=\(Int(ms))ms parse=malformed output=«\(preview)»")
				}
			} catch {
				let ms = Date().timeIntervalSince(start) * 1000
				latencies.append(ms)
				if ms >= Self.benchmarkTimeout * 1000 * 0.85 {
					timeouts += 1
					print("[ModelAudit] sample model=\(model) ctx=\(name) #\(i+1) latency=\(Int(ms))ms parse=timeout")
				} else {
					malformed += 1
					print("[ModelAudit] sample model=\(model) ctx=\(name) #\(i+1) latency=\(Int(ms))ms parse=error err=\(error.localizedDescription.prefix(60))")
				}
			}
		}

		let n = max(1, min(Self.benchmarkSamples, samples.count))
		let avg = latencies.isEmpty ? 9999 : latencies.reduce(0, +) / Double(latencies.count)
		return ModelAuditBenchmarkResult(
			modelName: model,
			avgLatencyMs: avg,
			timeoutRate: Double(timeouts) / Double(n),
			malformedRate: Double(malformed) / Double(n),
			parseSuccessRate: Double(successes) / Double(n),
			sampleCount: n,
			isRecommended: successes >= 2 && avg < 4000
		)
	}

	// MARK: - Selection helpers

	private func commitSelection(_ model: String, reason: String) {
		selectedTaskInferenceModel = model
		LocalAISettings.shared.taskInferenceModel = model
		// Note: taskInferenceBatchMode is managed by the smoke test — if batch succeeded,
		// it was already set to true above. If a streaming model won, leave it as-is
		// (the smoke test would have already set it to false if streaming worked first).
		print("[ModelAudit] selected task_inference_model=\(model) reason=\(reason) batch_mode=\(LocalAISettings.shared.taskInferenceBatchMode)")
		print("[ModelSelection] task_inference_model=\(model)")
		print("[ModelValidation] passed model=\(model)")
		ActiveModelTierConfig.shared.update(.from(settings: LocalAISettings.shared, auditSelected: model))
	}

	private func hasFastInferenceModel(_ installed: [String]) -> Bool {
		Self.fastInferenceCandidates.contains { candidate in
			installed.contains { name in modelNameMatches(name, candidate: candidate) }
		}
	}

	private func modelNameMatches(_ installedName: String, candidate: String) -> Bool {
		let nl = installedName.lowercased().trimmingCharacters(in: .whitespaces)
		let cl = candidate.lowercased().trimmingCharacters(in: .whitespaces)
		if nl == cl { return true }
		if nl.hasPrefix(cl + ":") { return true }
		if cl.hasPrefix(nl + ":") { return true }
		return false
	}

	// MARK: - Discovery

	private func fetchInstalledModels() async -> [String] {
		guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return [] }
		var req = URLRequest(url: url)
		req.httpMethod = "GET"
		req.timeoutInterval = 3.0
		do {
			let session = URLSession(configuration: {
				let c = URLSessionConfiguration.ephemeral
				c.waitsForConnectivity = false
				return c
			}())
			let (data, resp) = try await session.data(for: req)
			guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
			struct Root: Decodable { let models: [Entry] }
			struct Entry: Decodable { let name: String }
			return (try? JSONDecoder().decode(Root.self, from: data))?.models.map(\.name) ?? []
		} catch { return [] }
	}

	// MARK: - Timeout helper

	private enum TimeoutError: Error { case timeout }

	private func withTimeout<T: Sendable>(
		_ seconds: TimeInterval,
		_ op: @escaping @Sendable () async throws -> T
	) async throws -> T {
		let nanos = UInt64(seconds * 1_000_000_000)
		return try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask { try await op() }
			group.addTask {
				try await Task.sleep(nanoseconds: nanos)
				throw TimeoutError.timeout
			}
			guard let first = try await group.next() else { throw TimeoutError.timeout }
			group.cancelAll()
			return first
		}
	}
}

// MARK: - Warmup + Keepalive

extension ModelAuditManager {
	/// Fire one tiny silent inference to warm model caches. Never shows a proposal.
	func runWarmupIfNeeded(model: String, isManualInvocation: Bool = false) async {
		guard LocalAISettings.shared.localAIEnabled else { return }

		// Phase B.1.9 - Task 3: Startup warmup budget check
		if ModelManager.shared.isWithinStartupQuietPeriod() && !isManualInvocation {
			if model.lowercased().contains("qwen") {
				print("[StartupBudget] warmup_allowed model=\(model) reason=router_lightweight")
			} else if model.lowercased().contains("phi") {
				print("[StartupBudget] deferred_warmup model=\(model) reason=startup_quiet_period")
				return
			}
		}

		print("[TaskInferenceWarmup] started model=\(model)")
		let start = Date()
		let tiny = "Reply: {\"c\":0,\"p\":0.0}"
		do {
			_ = try await LocalAIClient.shared.generate(
				prompt: tiny,
				model: model,
				numPredict: 16,
				temperature: 0.0,
				purpose: "warmup"
			)
			let ms = Int(Date().timeIntervalSince(start) * 1000)
			print("[TaskInferenceWarmup] completed elapsed_ms=\(ms)")
		} catch {
			print("[TaskInferenceWarmup] failed reason=\(error.localizedDescription.prefix(80))")
		}
	}

	/// Start a background keepalive loop that pings the model every 4 minutes.
	/// Ollama's default idle timeout is 5 minutes; this prevents cold-start penalties.
	func startPeriodicKeepalive(model: String) {
		guard LocalAISettings.shared.localAIEnabled else { return }
		keepaliveTask?.cancel()
		print("[TaskInferenceWarmup] keepalive_started model=\(model) interval_s=\(Int(Self.keepaliveInterval))")
		keepaliveTask = Task.detached(priority: .background) { [interval = Self.keepaliveInterval] in
			while !Task.isCancelled {
				let sleepNanos = UInt64(interval * 1_000_000_000)
				try? await Task.sleep(nanoseconds: sleepNanos)
				guard !Task.isCancelled, LocalAISettings.shared.localAIEnabled else { break }
				let ping = "Reply: {\"c\":0}"
				do {
					_ = try await LocalAIClient.shared.generate(
						prompt: ping, model: model,
						numPredict: 8, temperature: 0.0, purpose: "warmup"
					)
					print("[TaskInferenceWarmup] keepalive_ping_ok model=\(model)")
				} catch {
					print("[TaskInferenceWarmup] keepalive_ping_failed model=\(model) reason=\(error.localizedDescription.prefix(60))")
				}
			}
			print("[TaskInferenceWarmup] keepalive_stopped model=\(model)")
		}
	}

	func stopPeriodicKeepalive() {
		keepaliveTask?.cancel()
		keepaliveTask = nil
	}
}
