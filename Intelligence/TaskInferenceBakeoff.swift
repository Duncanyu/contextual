import Foundation
import Darwin
import Darwin.Mach

/// TEMPORARY: Local benchmark harness for task inference models.
///
/// Goals:
/// - Compare multiple Ollama models using the *same* production structured-output schema,
///   prompt builder, parser, semantic validator, repair layer, timeout logic, and planner.
/// - Generate a markdown report file summarizing latency + reliability + resource usage.
///
/// This file is intentionally self-contained so it can be removed cleanly.
enum TaskInferenceBakeoff {

	struct ModelSpec: Sendable, Hashable {
		let name: String
	}

	struct Scenario: Sendable {
		let id: String
		let snapshot: CanonicalGeneratedExecutionContextSnapshot
	}

	struct TrialResult: Sendable {
		let model: String
		let scenarioId: String
		let isCold: Bool

		let elapsedMs: Int
		let modelLoadMs: Int?
		let promptEvalMs: Int?
		let evalMs: Int?
		let evalCount: Int?
		let tokensPerSecond: Double?

		let processCpuPct: Double
		let systemCpuPct: Double
		let rssBytes: UInt64
		let rssDeltaBytes: Int64

		let outputBytes: Int
		let parseFailure: TaskInferenceParseFailure?
		let repaired: Bool
		let shouldChime: Bool
		let cats: String
		let semanticValidity: TaskInferenceSemanticValidity?
		let plannerProducedProposal: Bool
	}

	struct ConcurrencyProbeAggregate: Sendable {
		let model: String
		let fanout: Int
		let trials: Int
		let okPct: Double
		let latencyP50: Int
		let latencyP95: Int
	}

	struct ModelAggregate: Sendable {
		let model: String
		let trials: Int
		let coldTrials: Int

		let validParsePct: Double
		let semanticValidPct: Double
		let repairedPct: Double
		let timeoutPct: Double
		let malformedPct: Double
		let forbiddenKeysPct: Double
		let executableProposalPct: Double

		let latencyP50: Int
		let latencyP95: Int
		let coldLatencyP50: Int
		let warmLatencyP50: Int
		let warmLatencyP95: Int

		let modelLoadP50: Int
		let modelLoadP95: Int
		let tokensPerSecondAvg: Double

		let processCpuAvgPct: Double
		let processCpuPeakPct: Double
		let systemCpuAvgPct: Double
		let systemCpuPeakPct: Double

		let rssAvgMB: Double
		let rssPeakMB: Double
		let rssPeakDeltaMB: Double

		let outputAvgBytes: Int

		let hotPathSuitabilityScore: Double
		let wouldFeelInstant: String
	}

	/// Entrypoint invoked via `AppDelegate.runTaskInferenceBakeoffOnLaunch`.
	static func run(
		modelNames: [String] = [
			"qwen2.5:1.5b",
			"qwen2.5:3b",
			"llama3.2:1b",
			"llama3.2:3b",
			"phi:3.8b",
			"gemma3:4b",
		],
		optionalModelNames: [String] = [
			"gemma3:1b",
			"qwen3:4b",
		],
		trialsPerModel: Int = 40,
		coldTrialsPerModel: Int = 6,
		timeoutSeconds: TimeInterval = 6.0,
		concurrencyProbeFanout: Int = 3,
		concurrencyProbeTrialsPerModel: Int = 3,
		referenceTime: Date = Date()
	) async -> Bool {
		let scenarios = bakeoffScenarios(referenceTime: referenceTime)
		guard !scenarios.isEmpty else {
			print("[TaskInferenceBakeoff] no_scenarios")
			return false
		}

		let installed = await fetchInstalledModelNames()
		let resolvedModels: [ModelSpec] = {
			var names = modelNames
			for opt in optionalModelNames where installed.contains(opt) {
				names.append(opt)
			}
			return names.map { ModelSpec(name: $0) }
		}()

		let missing = resolvedModels.map(\.name).filter { !installed.contains($0) }
		if !missing.isEmpty {
			let pulls = missing.map { "`ollama pull \($0)`" }.joined(separator: ", ")
			print("[TaskInferenceBakeoff] missing_models count=\(missing.count) pull=\(pulls)")
		}

		print("[TaskInferenceBakeoff] started models=\(resolvedModels.count) scenarios=\(scenarios.count) trials_per_model=\(trialsPerModel) cold_trials=\(coldTrialsPerModel)")

		var allResults: [TrialResult] = []
		var probes: [ConcurrencyProbeAggregate] = []

		for model in resolvedModels where installed.contains(model.name) {
			print("[TaskInferenceBakeoff] model_started name=\(model.name)")

			// Shuffle scenario order to avoid systematic bias.
			var rng = SystemRandomNumberGenerator()
			var scenarioOrder = scenarios
			scenarioOrder.shuffle(using: &rng)

			for i in 0..<trialsPerModel {
				let scenario = scenarioOrder[i % scenarioOrder.count]
				let isCold = i < coldTrialsPerModel

				// Best-effort attempt to make cold trials cold: request keep_alive=0.
				if isCold {
					await bestEffortUnload(model: model.name)
				}

				let trial = await runSingleTrial(
					model: model.name,
					scenario: scenario,
					isCold: isCold,
					timeoutSeconds: timeoutSeconds,
					referenceTime: referenceTime
				)
				allResults.append(trial)
			}

			if concurrencyProbeTrialsPerModel > 0, concurrencyProbeFanout >= 2 {
				let probe = await runConcurrencyProbe(
					model: model.name,
					scenario: scenarios[0],
					fanout: concurrencyProbeFanout,
					trials: concurrencyProbeTrialsPerModel,
					timeoutSeconds: timeoutSeconds,
					referenceTime: referenceTime
				)
				probes.append(probe)
			}

			print("[TaskInferenceBakeoff] model_finished name=\(model.name)")
		}

		let aggregates = summarize(allResults)
		let report = renderMarkdownReport(
			aggregates: aggregates,
			results: allResults,
			scenarios: scenarios,
			probes: probes,
			missingModels: missing,
			referenceTime: referenceTime
		)

		let outURL = resolveOutputURL(referenceTime: referenceTime)
		do {
			try report.write(to: outURL, atomically: true, encoding: .utf8)
			print("[TaskInferenceBakeoff] report_written path=\(outURL.path)")
		} catch {
			print("[TaskInferenceBakeoff] report_write_failed path=\(outURL.path) error=\(error)")
			return false
		}

		print("[TaskInferenceBakeoff] completed ok=yes")
		return true
	}

	// MARK: - Single trial

	private static func runSingleTrial(
		model: String,
		scenario: Scenario,
		isCold: Bool,
		timeoutSeconds: TimeInterval,
		referenceTime: Date
	) async -> TrialResult {
		let situational = SituationalContextSynthesizer.synthesize(from: scenario.snapshot, referenceTime: referenceTime)
		let prompt = TaskInferencePromptBuilder.build(
			snapshot: scenario.snapshot,
			situational: situational,
			recentTitles: [scenario.snapshot.windowTitle],
			history: nil,
			referenceTime: referenceTime
		)

		let schema = taskInferenceSchemaV1()

		let startWall = Date()
		let startUsage = ProcessUsage.sample()
		let startSys = SystemCPUSample.sample()
		let startRSS = RSS.sample()

		var raw = ""
		var timings: OllamaTimings? = nil

		do {
			let response = try await withTimeout(timeoutSeconds: timeoutSeconds) {
				try await ollamaGenerateBatch(
					model: model,
					prompt: prompt,
					schema: schema,
					purpose: isCold ? "bakeoff_cold" : "bakeoff_warm",
					numPredict: 90,
					temperature: 0.0,
					keepAlive: "10m"
				)
			}
			raw = response.text
			timings = response.timings
		} catch {
			let elapsedMs = Int(Date().timeIntervalSince(startWall) * 1000)
			let endUsage = ProcessUsage.sample()
			let endSys = SystemCPUSample.sample()
			let endRSS = RSS.sample()

			return TrialResult(
				model: model,
				scenarioId: scenario.id,
				isCold: isCold,
				elapsedMs: elapsedMs,
				modelLoadMs: nil,
				promptEvalMs: nil,
				evalMs: nil,
				evalCount: nil,
				tokensPerSecond: nil,
				processCpuPct: endUsage.cpuPct(since: startUsage, wallMs: elapsedMs),
				systemCpuPct: endSys.cpuPct(since: startSys),
				rssBytes: endRSS.bytes,
				rssDeltaBytes: Int64(endRSS.bytes) - Int64(startRSS.bytes),
				outputBytes: 0,
				parseFailure: .parseNoJSONObject,
				repaired: false,
				shouldChime: false,
				cats: "",
				semanticValidity: nil,
				plannerProducedProposal: false
			)
		}

		let elapsedMs = Int(Date().timeIntervalSince(startWall) * 1000)
		let endUsage = ProcessUsage.sample()
		let endSys = SystemCPUSample.sample()
		let endRSS = RSS.sample()

		var parseFailure: TaskInferenceParseFailure? = nil
		var repaired = false
		var shouldChime = false
		var cats = ""
		var semanticValidity: TaskInferenceSemanticValidity? = nil
		var plannerProducedProposal = false

		let (parsed, failure) = TaskInferenceParser.parseWithFailure(from: raw, referenceTime: referenceTime)
		parseFailure = failure
		if let parsed {
			let repairedResult = TaskInferenceSemanticRepairer.repairIfNeeded(parsed, snapshot: scenario.snapshot, situational: situational)
			repaired = repairedResult.repaired
			shouldChime = repairedResult.result.shouldChime
			cats = repairedResult.result.neededCapabilityCategories.joined(separator: ",")
			if repairedResult.result.shouldChime {
				semanticValidity = TaskInferenceSemanticValidator.validate(
					repairedResult.result,
					windowTitle: situational.windowTitle,
					appName: situational.activeAppName,
					selectedText: scenario.snapshot.selectedText
				)
			} else {
				semanticValidity = .valid
			}

			if semanticValidity == .valid, repairedResult.result.shouldChime {
				let planned = await TaskInferencePlanningPipeline.compose(
					inference: repairedResult.result,
					snapshot: scenario.snapshot,
					situational: situational,
					recentTitles: [scenario.snapshot.windowTitle],
					referenceTime: referenceTime
				)
				plannerProducedProposal = planned != nil
			}
		}

		let loadMs = timings?.loadMs
		let promptEvalMs = timings?.promptEvalMs
		let evalMs = timings?.evalMs
		let evalCount = timings?.evalCount
		let tps = timings?.tokensPerSecond

		return TrialResult(
			model: model,
			scenarioId: scenario.id,
			isCold: isCold,
			elapsedMs: elapsedMs,
			modelLoadMs: loadMs,
			promptEvalMs: promptEvalMs,
			evalMs: evalMs,
			evalCount: evalCount,
			tokensPerSecond: tps,
			processCpuPct: endUsage.cpuPct(since: startUsage, wallMs: elapsedMs),
			systemCpuPct: endSys.cpuPct(since: startSys),
			rssBytes: endRSS.bytes,
			rssDeltaBytes: Int64(endRSS.bytes) - Int64(startRSS.bytes),
			outputBytes: raw.utf8.count,
			parseFailure: parseFailure,
			repaired: repaired,
			shouldChime: shouldChime,
			cats: cats,
			semanticValidity: semanticValidity,
			plannerProducedProposal: plannerProducedProposal
		)
	}

	// MARK: - Concurrency probe

	private static func runConcurrencyProbe(
		model: String,
		scenario: Scenario,
		fanout: Int,
		trials: Int,
		timeoutSeconds: TimeInterval,
		referenceTime: Date
	) async -> ConcurrencyProbeAggregate {
		let situational = SituationalContextSynthesizer.synthesize(from: scenario.snapshot, referenceTime: referenceTime)
		let prompt = TaskInferencePromptBuilder.build(
			snapshot: scenario.snapshot,
			situational: situational,
			recentTitles: [scenario.snapshot.windowTitle],
			history: nil,
			referenceTime: referenceTime
		)
		let schema = taskInferenceSchemaV1()

		var okCount = 0
		var latencies: [Int] = []

		for _ in 0..<trials {
			let start = Date()
			let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
				for _ in 0..<fanout {
					group.addTask {
						do {
							let r = try await withTimeout(timeoutSeconds: timeoutSeconds) {
								try await ollamaGenerateBatch(
									model: model,
									prompt: prompt,
									schema: schema,
									purpose: "bakeoff_concurrency",
									numPredict: 90,
									temperature: 0.0,
									keepAlive: "10m"
								)
							}
							return !r.text.isEmpty
						} catch {
							return false
						}
					}
				}
				var outs: [Bool] = []
				for await v in group { outs.append(v) }
				return outs
			}
			let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
			let ok = results.filter { $0 }.count
			okCount += ok
			latencies.append(elapsedMs)
		}

		latencies.sort()
		let okPct = (Double(okCount) / Double(max(1, trials * fanout))) * 100.0
		return ConcurrencyProbeAggregate(
			model: model,
			fanout: fanout,
			trials: trials,
			okPct: okPct,
			latencyP50: percentile(latencies, 0.50),
			latencyP95: percentile(latencies, 0.95)
		)
	}

	// MARK: - Schema (must match production)

	private static func taskInferenceSchemaV1() -> [String: Any] {
		// Must match the production task inference contract (task_v1) shape.
		// Note: This schema is passed to Ollama via `format` (JSON schema).
		let catsEnum: [Any] = [
			"",
			"context",
			"extract",
			"compare",
			"output",
			"context,extract",
			"compare,extract",
			"compare,extract,output",
			"extract,output",
		]

		return [
			"type": "object",
			"properties": [
				"c": [
					"type": "integer",
					"enum": [0, 1],
				],
				"g": [
					"type": "string",
					"maxLength": 80,
				],
				"cats": [
					"type": "string",
					"enum": catsEnum,
				],
				"p": [
					"type": "number",
					"minimum": 0.0,
					"maximum": 1.0,
				],
			],
			"required": ["c", "g", "cats", "p"],
			"additionalProperties": false,
		]
	}

	// MARK: - Scenarios (realistic synthetic snapshots)

	private static func bakeoffScenarios(referenceTime: Date) -> [Scenario] {
		let basePerms: [PermissionRequirement: Bool] = [
			.screenRecording: false,
			.accessibility: false,
			.clipboard: true,
		]

		return [
			Scenario(
				id: "firefox_product_metadata",
				snapshot: CanonicalGeneratedExecutionContextSnapshot(
					activeApp: "Firefox",
					windowTitle: "Amazon.com: AirPods 4 Case - Black",
					bundleIdentifier: "org.mozilla.firefox",
					inferredWorkflow: .browsing,
					selectedText: nil,
					clipboardText: nil,
					recentOCRExcerpt: nil,
					contextSummary: "Browsing product pages",
					workflowConfidence: 0.72,
					availableContextTypes: [.workflowContext],
					permissionAvailability: basePerms,
					generatedAt: referenceTime,
					freshnessScore: 0.6
				)
			),
			Scenario(
				id: "firefox_product_ocr",
				snapshot: CanonicalGeneratedExecutionContextSnapshot(
					activeApp: "Firefox",
					windowTitle: "Amazon.com: AirPods 4 Case - Black",
					bundleIdentifier: "org.mozilla.firefox",
					inferredWorkflow: .browsing,
					selectedText: nil,
					clipboardText: nil,
					recentOCRExcerpt: "AirPods 4 Case • Price $19.99 • Color Black • Compatible with AirPods 4",
					contextSummary: "OCR-visible shopping content",
					workflowConfidence: 0.72,
					availableContextTypes: [.workflowContext, .textSnippet, .fusedVisual],
					permissionAvailability: basePerms,
					generatedAt: referenceTime,
					freshnessScore: 0.7
				)
			),
			Scenario(
				id: "reddit_thread_metadata",
				snapshot: CanonicalGeneratedExecutionContextSnapshot(
					activeApp: "Firefox",
					windowTitle: "Reddit - r/MacApps: Best window manager?",
					bundleIdentifier: "org.mozilla.firefox",
					inferredWorkflow: .browsing,
					selectedText: nil,
					clipboardText: nil,
					recentOCRExcerpt: nil,
					contextSummary: "Browsing forum thread",
					workflowConfidence: 0.66,
					availableContextTypes: [.workflowContext],
					permissionAvailability: basePerms,
					generatedAt: referenceTime,
					freshnessScore: 0.55
				)
			),
			Scenario(
				id: "article_reading_ocr",
				snapshot: CanonicalGeneratedExecutionContextSnapshot(
					activeApp: "Firefox",
					windowTitle: "Understanding Swift Concurrency - Blog",
					bundleIdentifier: "org.mozilla.firefox",
					inferredWorkflow: .research,
					selectedText: nil,
					clipboardText: nil,
					recentOCRExcerpt: "Swift concurrency introduces async/await, Task, actor isolation, and structured concurrency...",
					contextSummary: "Reading an article",
					workflowConfidence: 0.7,
					availableContextTypes: [.workflowContext, .textSnippet],
					permissionAvailability: basePerms,
					generatedAt: referenceTime,
					freshnessScore: 0.7
				)
			),
			Scenario(
				id: "youtube_video_ocr",
				snapshot: CanonicalGeneratedExecutionContextSnapshot(
					activeApp: "Firefox",
					windowTitle: "YouTube — SwiftUI Animations Tutorial",
					bundleIdentifier: "org.mozilla.firefox",
					inferredWorkflow: .browsing,
					selectedText: nil,
					clipboardText: nil,
					recentOCRExcerpt: "SwiftUI Animations Tutorial • Chapter 2: Transitions • 12:34 / 45:00",
					contextSummary: "Watching a tutorial video",
					workflowConfidence: 0.66,
					availableContextTypes: [.workflowContext, .textSnippet, .fusedVisual],
					permissionAvailability: basePerms,
					generatedAt: referenceTime,
					freshnessScore: 0.65
				)
			),
			Scenario(
				id: "xcode_debug_selected_text",
				snapshot: CanonicalGeneratedExecutionContextSnapshot(
					activeApp: "Xcode",
					windowTitle: "ContextualAppDelegate.swift — Build Failed",
					bundleIdentifier: "com.apple.dt.Xcode",
					inferredWorkflow: .debugging,
					selectedText: "Thread 1: Fatal error: Unexpectedly found nil while unwrapping an Optional value",
					clipboardText: nil,
					recentOCRExcerpt: nil,
					contextSummary: "Debugging a crash",
					workflowConfidence: 0.78,
					availableContextTypes: [.workflowContext, .selectedText, .textSnippet],
					permissionAvailability: basePerms,
					generatedAt: referenceTime,
					freshnessScore: 0.82
				)
			),
			Scenario(
				id: "clipboard_heavy",
				snapshot: CanonicalGeneratedExecutionContextSnapshot(
					activeApp: "Notes",
					windowTitle: "Notes — Draft",
					bundleIdentifier: "com.apple.Notes",
					inferredWorkflow: .writing,
					selectedText: nil,
					clipboardText: "Copied paragraph about product pricing and constraints...",
					recentOCRExcerpt: nil,
					contextSummary: "Clipboard contains draft text",
					workflowConfidence: 0.52,
					availableContextTypes: [.workflowContext, .textSnippet],
					permissionAvailability: basePerms,
					generatedAt: referenceTime,
					freshnessScore: 0.5
				)
			),
			Scenario(
				id: "weak_metadata_only",
				snapshot: CanonicalGeneratedExecutionContextSnapshot(
					activeApp: "Firefox",
					windowTitle: "New Tab",
					bundleIdentifier: "org.mozilla.firefox",
					inferredWorkflow: .unknown,
					selectedText: nil,
					clipboardText: nil,
					recentOCRExcerpt: nil,
					contextSummary: "Weak metadata-only context",
					workflowConfidence: 0.35,
					availableContextTypes: [],
					permissionAvailability: basePerms,
					generatedAt: referenceTime,
					freshnessScore: 0.4
				)
			),
		]
	}

	// MARK: - Summary

	private static func summarize(_ results: [TrialResult]) -> [ModelAggregate] {
		let byModel = Dictionary(grouping: results, by: \.model)
		var aggregates: [ModelAggregate] = []

		for (model, trials) in byModel {
			let total = trials.count
			let cold = trials.filter(\.isCold).count

			let validParse = Double(trials.filter { $0.parseFailure == nil }.count) / Double(max(1, total)) * 100.0
			let semanticValid = Double(trials.filter { $0.semanticValidity == .valid }.count) / Double(max(1, total)) * 100.0
			let repairedPct = Double(trials.filter(\.repaired).count) / Double(max(1, total)) * 100.0

			let timeoutPct = Double(trials.filter { $0.parseFailure == .parseNoJSONObject }.count) / Double(max(1, total)) * 100.0
			let malformedPct = Double(trials.filter { $0.parseFailure == .parseMalformedJSON || $0.parseFailure == .parseMissingRequiredKey }.count) / Double(max(1, total)) * 100.0
			let forbiddenPct = Double(trials.filter { $0.parseFailure == .parseForbiddenKeys }.count) / Double(max(1, total)) * 100.0
			let executablePct = Double(trials.filter(\.plannerProducedProposal).count) / Double(max(1, total)) * 100.0

			let latAll = trials.map(\.elapsedMs).sorted()
			let latWarm = trials.filter { !$0.isCold }.map(\.elapsedMs).sorted()
			let latCold = trials.filter(\.isCold).map(\.elapsedMs).sorted()

			let loadAll = trials.compactMap(\.modelLoadMs).sorted()
			let tpsAll = trials.compactMap(\.tokensPerSecond)

			let procCpuAll = trials.map(\.processCpuPct)
			let sysCpuAll = trials.map(\.systemCpuPct)
			let rssAll = trials.map { Double($0.rssBytes) / (1024.0 * 1024.0) }
			let rssDeltaAll = trials.map { Double($0.rssDeltaBytes) / (1024.0 * 1024.0) }

			let outAvg = Int(Double(trials.map(\.outputBytes).reduce(0, +)) / Double(max(1, total)))

			let agg = ModelAggregate(
				model: model,
				trials: total,
				coldTrials: cold,
				validParsePct: validParse,
				semanticValidPct: semanticValid,
				repairedPct: repairedPct,
				timeoutPct: timeoutPct,
				malformedPct: malformedPct,
				forbiddenKeysPct: forbiddenPct,
				executableProposalPct: executablePct,
				latencyP50: percentile(latAll, 0.50),
				latencyP95: percentile(latAll, 0.95),
				coldLatencyP50: percentile(latCold, 0.50),
				warmLatencyP50: percentile(latWarm, 0.50),
				warmLatencyP95: percentile(latWarm, 0.95),
				modelLoadP50: percentile(loadAll, 0.50),
				modelLoadP95: percentile(loadAll, 0.95),
				tokensPerSecondAvg: tpsAll.isEmpty ? 0 : tpsAll.reduce(0, +) / Double(tpsAll.count),
				processCpuAvgPct: procCpuAll.isEmpty ? 0 : procCpuAll.reduce(0, +) / Double(procCpuAll.count),
				processCpuPeakPct: procCpuAll.max() ?? 0,
				systemCpuAvgPct: sysCpuAll.isEmpty ? 0 : sysCpuAll.reduce(0, +) / Double(sysCpuAll.count),
				systemCpuPeakPct: sysCpuAll.max() ?? 0,
				rssAvgMB: rssAll.isEmpty ? 0 : rssAll.reduce(0, +) / Double(rssAll.count),
				rssPeakMB: rssAll.max() ?? 0,
				rssPeakDeltaMB: rssDeltaAll.max() ?? 0,
				outputAvgBytes: outAvg,
				hotPathSuitabilityScore: 0,
				wouldFeelInstant: "n/a"
			)

			aggregates.append(annotateSuitability(agg))
		}

		// Highest score first
		aggregates.sort { $0.hotPathSuitabilityScore > $1.hotPathSuitabilityScore }
		return aggregates
	}

	private static func annotateSuitability(_ a: ModelAggregate) -> ModelAggregate {
		// Weighted for hot-path UX (0–100):
		// - semantic correctness dominates
		// - p95 warm latency is the primary UX driver
		// - CPU spikes matter for thermals
		// - timeouts/malformed are hard failures
		let semantic = a.semanticValidPct
		let exec = a.executableProposalPct

		let warmP95 = Double(max(1, a.warmLatencyP95))
		let latencyScore: Double = {
			// 800ms feels instant, 1500ms borderline, >2000ms bad.
			if warmP95 <= 800 { return 100 }
			if warmP95 <= 1500 { return 100 - ((warmP95 - 800) / 700) * 45 } // down to ~55
			if warmP95 <= 2000 { return 55 - ((warmP95 - 1500) / 500) * 35 } // down to ~20
			return 0
		}()

		let cpuPeak = a.processCpuPeakPct
		let cpuScore: Double = {
			if cpuPeak <= 80 { return 100 }
			if cpuPeak <= 120 { return 100 - ((cpuPeak - 80) / 40) * 35 } // down to 65
			if cpuPeak <= 180 { return 65 - ((cpuPeak - 120) / 60) * 50 } // down to 15
			return 0
		}()

		let hardPenalty = (a.timeoutPct * 1.2) + (a.malformedPct * 0.8) + (a.forbiddenKeysPct * 0.8)
		let base =
			(semantic * 0.52) +
			(exec * 0.18) +
			(latencyScore * 0.22) +
			(cpuScore * 0.08)
		let score = max(0, min(100, base - hardPenalty))

		let instant: String = {
			if a.warmLatencyP95 <= 800, a.processCpuPeakPct <= 120, a.semanticValidPct >= 85 { return "yes" }
			if a.warmLatencyP95 <= 1500, a.semanticValidPct >= 80 { return "maybe" }
			return "no"
		}()

		return ModelAggregate(
			model: a.model,
			trials: a.trials,
			coldTrials: a.coldTrials,
			validParsePct: a.validParsePct,
			semanticValidPct: a.semanticValidPct,
			repairedPct: a.repairedPct,
			timeoutPct: a.timeoutPct,
			malformedPct: a.malformedPct,
			forbiddenKeysPct: a.forbiddenKeysPct,
			executableProposalPct: a.executableProposalPct,
			latencyP50: a.latencyP50,
			latencyP95: a.latencyP95,
			coldLatencyP50: a.coldLatencyP50,
			warmLatencyP50: a.warmLatencyP50,
			warmLatencyP95: a.warmLatencyP95,
			modelLoadP50: a.modelLoadP50,
			modelLoadP95: a.modelLoadP95,
			tokensPerSecondAvg: a.tokensPerSecondAvg,
			processCpuAvgPct: a.processCpuAvgPct,
			processCpuPeakPct: a.processCpuPeakPct,
			systemCpuAvgPct: a.systemCpuAvgPct,
			systemCpuPeakPct: a.systemCpuPeakPct,
			rssAvgMB: a.rssAvgMB,
			rssPeakMB: a.rssPeakMB,
			rssPeakDeltaMB: a.rssPeakDeltaMB,
			outputAvgBytes: a.outputAvgBytes,
			hotPathSuitabilityScore: score,
			wouldFeelInstant: instant
		)
	}

	private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
		guard !sorted.isEmpty else { return 0 }
		let idx = Int(Double(sorted.count - 1) * p)
		return sorted[max(0, min(sorted.count - 1, idx))]
	}

	// MARK: - Report rendering

	private static func renderMarkdownReport(
		aggregates: [ModelAggregate],
		results: [TrialResult],
		scenarios: [Scenario],
		probes: [ConcurrencyProbeAggregate],
		missingModels: [String],
		referenceTime: Date
	) -> String {
		let ranked = aggregates

		let summaryHeader = """
# Task Inference Bakeoff Report

Generated at: \(referenceTime)

This report is generated by `Intelligence/TaskInferenceBakeoff.swift` (temporary harness).

## Ranked Table (hot-path suitability score)

Higher score is better for: semantic reliability + actionable rate + low p95 warm latency + low CPU spikes.

| Rank | Model | Score | Instant? | Trials | Semantic valid % | Executable % | Timeout % | Warm p95 ms | Warm p50 ms | CPU peak % | RSS peak MB | TPS avg |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
"""

		let summaryRows = ranked.enumerated().map { idx, a in
			"| \(idx + 1) | \(a.model) | \(fmt1(a.hotPathSuitabilityScore)) | \(a.wouldFeelInstant) | \(a.trials) | \(fmtPct(a.semanticValidPct)) | \(fmtPct(a.executableProposalPct)) | \(fmtPct(a.timeoutPct)) | \(a.warmLatencyP95) | \(a.warmLatencyP50) | \(fmt1(a.processCpuPeakPct)) | \(fmt1(a.rssPeakMB)) | \(fmt1(a.tokensPerSecondAvg)) |"
		}.joined(separator: "\n")

				let recommendations = deriveRecommendations(aggregates: ranked)
				let probeSection = renderConcurrencyProbes(probes)
				let scenarioList = scenarios.map { scenario in
					let ctxTypes = scenario.snapshot.availableContextTypes.map(\.rawValue).joined(separator: ",")
					return "- `\(scenario.id)` title=`\(scenario.snapshot.windowTitle.prefix(80))` wf=`\(scenario.snapshot.inferredWorkflow.rawValue)` ctx=`\(ctxTypes)`"
				}.joined(separator: "\n")

		let missingSection: String = {
			guard !missingModels.isEmpty else { return "" }
			let pulls = missingModels.map { "- `ollama pull \($0)`" }.joined(separator: "\n")
			return """

## Missing models

The following models were not installed, so they were skipped:

\(pulls)
"""
		}()

		return """
\(summaryHeader)\(summaryRows)

## Recommendations

\(recommendations)

\(probeSection)

## Scenarios

\(scenarioList)

\(missingSection)

## Notes
- Resource metrics are best-effort:
  - Process CPU %% is computed from `getrusage` deltas divided by wall time.
  - System CPU %% is computed from host CPU tick deltas over the same wall window.
  - RSS is read from `mach_task_basic_info`.
  - Token/sec and load/eval durations come from Ollama’s `/api/generate` response timing fields (when present).
- “Cold” trials attempt `keep_alive=0` unload first; Ollama may still keep models resident depending on server settings.
- This harness calls only the local Ollama server and uses the production prompt/schema/parser/validator/repair/planner.
"""
	}

	private static func renderConcurrencyProbes(_ probes: [ConcurrencyProbeAggregate]) -> String {
		guard !probes.isEmpty else { return "" }
		let header = """
## Concurrency Probe (fanout)

Measures how each model behaves under small concurrent load (fanout per trial). Lower latency and higher ok%% is better.

| Model | Fanout | Trials | OK % | p50 ms | p95 ms |
|---|---:|---:|---:|---:|---:|
"""
		let rows = probes.map {
			"| \($0.model) | \($0.fanout) | \($0.trials) | \(fmtPct($0.okPct)) | \($0.latencyP50) | \($0.latencyP95) |"
		}.joined(separator: "\n")
		return "\(header)\(rows)\n"
	}

	private static func deriveRecommendations(aggregates: [ModelAggregate]) -> String {
		guard !aggregates.isEmpty else { return "No data." }

		let hotPath = aggregates.first
		let quality = aggregates.max { $0.semanticValidPct < $1.semanticValidPct }
		let future = aggregates.max { $0.tokensPerSecondAvg < $1.tokensPerSecondAvg }

		// "Ship today": semantic >= 85, warm p95 <= 1500, timeouts <= 10
		let shipToday = aggregates.first {
			$0.semanticValidPct >= 85 &&
			$0.warmLatencyP95 <= 1500 &&
			$0.timeoutPct <= 10
		}

		func line(_ label: String, _ a: ModelAggregate?, detail: String) -> String {
			guard let a else { return "- \(label): n/a" }
			return "- \(label): **\(a.model)** — \(detail)"
		}

		return [
			line("HOT PATH model (best overall)", hotPath, detail: "score=\(fmt1(hotPath?.hotPathSuitabilityScore ?? 0)) warm_p95=\(hotPath?.warmLatencyP95 ?? 0)ms semantic_valid=\(fmtPct(hotPath?.semanticValidPct ?? 0)) cpu_peak=\(fmt1(hotPath?.processCpuPeakPct ?? 0))"),
			line("QUALITY model (highest semantic valid %)", quality, detail: "semantic_valid=\(fmtPct(quality?.semanticValidPct ?? 0)) warm_p95=\(quality?.warmLatencyP95 ?? 0)ms"),
			line("FUTURE scaling model (highest TPS proxy)", future, detail: "tps_avg=\(fmt1(future?.tokensPerSecondAvg ?? 0)) warm_p95=\(future?.warmLatencyP95 ?? 0)ms"),
			line("SHIP TODAY model (meets conservative UX bounds)", shipToday, detail: "warm_p95=\(shipToday?.warmLatencyP95 ?? 0)ms timeout=\(fmtPct(shipToday?.timeoutPct ?? 0))"),
			"",
			"- Would this feel instant?: `yes` ~= warm p95 ≤ 800ms; `maybe` ≤ 1500ms; otherwise `no`.",
		].joined(separator: "\n")
	}

	private static func fmtPct(_ v: Double) -> String { String(format: "%.1f", v) }
	private static func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }

	// MARK: - Output path

	private static func resolveOutputURL(referenceTime: Date) -> URL {
		let fm = FileManager.default
		if let override = ProcessInfo.processInfo.environment["CONTEXTUAL_BAKEOFF_OUTPUT_PATH"], !override.isEmpty {
			return URL(fileURLWithPath: override)
		}
		// Default: ~/Downloads/TaskInferenceBakeoffReport.md
		let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
		return downloads.appendingPathComponent("TaskInferenceBakeoffReport.md")
	}

	// MARK: - Installed models

	private static func fetchInstalledModelNames() async -> Set<String> {
		guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return [] }
		var req = URLRequest(url: url)
		req.httpMethod = "GET"
		if let (data, _) = try? await URLSession.shared.data(for: req),
		   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		   let models = obj["models"] as? [[String: Any]]
		{
			let names = models.compactMap { $0["name"] as? String }
			return Set(names)
		}
		return []
	}

	// MARK: - Best-effort unload

	private static func bestEffortUnload(model: String) async {
		_ = try? await ollamaGenerateBatch(
			model: model,
			prompt: "{\"ok\":true}",
			schema: nil,
			purpose: "bakeoff_unload",
			numPredict: 1,
			temperature: 0.0,
			keepAlive: "0"
		)
	}

	// MARK: - Ollama batch call (bakeoff-only)

	private struct OllamaGenerateBatchResponse {
		let text: String
		let timings: OllamaTimings?
	}

	private struct OllamaTimings: Sendable {
		let loadMs: Int?
		let promptEvalMs: Int?
		let evalMs: Int?
		let evalCount: Int?
		let tokensPerSecond: Double?
	}

	private struct OllamaAPIResponse: Decodable {
		let response: String?
		let error: String?

		let load_duration: Int64?
		let prompt_eval_duration: Int64?
		let eval_duration: Int64?
		let eval_count: Int?
	}

	private static func ollamaGenerateBatch(
		model: String,
		prompt: String,
		schema: [String: Any]?,
		purpose: String,
		numPredict: Int,
		temperature: Double,
		keepAlive: String?
	) async throws -> OllamaGenerateBatchResponse {
		guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else {
			throw LocalAIClientError.invalidURL
		}
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")

		var payload: [String: Any] = [
			"model": model,
			"prompt": prompt,
			"stream": false,
			"options": [
				"num_predict": numPredict,
				"temperature": temperature,
			],
		]
		if let keepAlive {
			payload["keep_alive"] = keepAlive
		}
		if let schema { payload["format"] = schema }

		request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
		let (data, response) = try await URLSession.shared.data(for: request)
		let code = (response as? HTTPURLResponse)?.statusCode ?? -1
		guard code == 200 else { throw LocalAIClientError.badStatusCode(code) }

		let decoded = try JSONDecoder().decode(OllamaAPIResponse.self, from: data)
		if let err = decoded.error, !err.isEmpty { throw LocalAIClientError.serverMessage(err) }
		let text = decoded.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

		let timings = decodeTimings(decoded)
		return OllamaGenerateBatchResponse(text: text, timings: timings)
	}

	private static func decodeTimings(_ decoded: OllamaAPIResponse) -> OllamaTimings? {
		let loadMs = decoded.load_duration.map { Int(Double($0) / 1_000_000.0) }
		let promptEvalMs = decoded.prompt_eval_duration.map { Int(Double($0) / 1_000_000.0) }
		let evalMs = decoded.eval_duration.map { Int(Double($0) / 1_000_000.0) }
		let evalCount = decoded.eval_count
		let tps: Double? = {
			guard let evalNs = decoded.eval_duration, evalNs > 0, let count = evalCount, count > 0 else { return nil }
			return Double(count) / (Double(evalNs) / 1_000_000_000.0)
		}()
		if loadMs == nil, promptEvalMs == nil, evalMs == nil, evalCount == nil, tps == nil { return nil }
		return OllamaTimings(loadMs: loadMs, promptEvalMs: promptEvalMs, evalMs: evalMs, evalCount: evalCount, tokensPerSecond: tps)
	}

	// MARK: - Timeout helper (trial scoped)

	private enum TimeoutError: Error { case timeout }
	private static func withTimeout<T>(timeoutSeconds: TimeInterval, _ op: @escaping () async throws -> T) async throws -> T {
		try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask { try await op() }
			group.addTask {
				try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
				throw TimeoutError.timeout
			}
			let value = try await group.next()!
			group.cancelAll()
			return value
		}
	}
}

// MARK: - Process CPU (best-effort)

private struct ProcessUsage {
	let userSeconds: Double
	let sysSeconds: Double

	static func sample() -> ProcessUsage {
		var usage = rusage()
		getrusage(RUSAGE_SELF, &usage)
		let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
		let s = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0
		return ProcessUsage(userSeconds: u, sysSeconds: s)
	}

	func cpuPct(since start: ProcessUsage, wallMs: Int) -> Double {
		guard wallMs > 0 else { return 0 }
		let cpu = (userSeconds - start.userSeconds) + (sysSeconds - start.sysSeconds)
		let wall = Double(wallMs) / 1000.0
		return max(0, min(999, (cpu / wall) * 100.0))
	}
}

// MARK: - System CPU (best-effort)

private struct SystemCPUSample {
	let user: UInt64
	let system: UInt64
	let idle: UInt64
	let nice: UInt64

	static func sample() -> SystemCPUSample {
		var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
		var info = host_cpu_load_info_data_t()
		let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
			ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
				host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
			}
		}
		guard result == KERN_SUCCESS else {
			return SystemCPUSample(user: 0, system: 0, idle: 0, nice: 0)
		}
		return SystemCPUSample(
			user: UInt64(info.cpu_ticks.0),
			system: UInt64(info.cpu_ticks.1),
			idle: UInt64(info.cpu_ticks.2),
			nice: UInt64(info.cpu_ticks.3)
		)
	}

	func cpuPct(since start: SystemCPUSample) -> Double {
		let du = Double(max(0, Int64(user) - Int64(start.user)))
		let ds = Double(max(0, Int64(system) - Int64(start.system)))
		let di = Double(max(0, Int64(idle) - Int64(start.idle)))
		let dn = Double(max(0, Int64(nice) - Int64(start.nice)))
		let total = du + ds + di + dn
		guard total > 0 else { return 0 }
		let active = du + ds + dn
		return max(0, min(100, (active / total) * 100.0))
	}
}

// MARK: - RSS (best-effort)

private struct RSS {
	let bytes: UInt64

	static func sample() -> RSS {
		var info = mach_task_basic_info()
		var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
		let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
			ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
				task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
			}
		}
		if kerr != KERN_SUCCESS { return RSS(bytes: 0) }
		return RSS(bytes: UInt64(info.resident_size))
	}
}

// MARK: - Shared semantic repairer (matches production repair rules)

private enum TaskInferenceSemanticRepairer {
	struct RepairOutput: Sendable {
		let result: TaskInferenceResult
		let repaired: Bool
	}

	static func repairIfNeeded(
		_ parsed: TaskInferenceResult,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		situational: SituationalContextSnapshot
	) -> RepairOutput {
		var repaired = false
		var goal = parsed.possibleUserGoal.trimmingCharacters(in: .whitespacesAndNewlines)
		let rawGoalNorm = goal.lowercased()
		let leakedGoals: Set<String> = [
			"classify_context", "one_line_object", "title", "goal", "context",
			"classifycontext", "one-line-object",
		]
		if (leakedGoals.contains(rawGoalNorm) || rawGoalNorm.isEmpty) && parsed.shouldChime {
			goal = deriveGoal(from: situational)
			repaired = true
		}

		var cats = parsed.neededCapabilityCategories
		if parsed.shouldChime && cats.isEmpty {
			cats = deriveCats(from: situational)
			repaired = true
		}

		var p = parsed.confidence
		if p < 0 { p = 0; repaired = true }
		if p > 1 { p = 1; repaired = true }

		if !repaired {
			return RepairOutput(result: parsed, repaired: false)
		}
		return RepairOutput(
			result: TaskInferenceResult(
				shouldChime: parsed.shouldChime,
				possibleUserGoal: goal,
				confidence: p,
				neededCapabilityCategories: cats,
				whyNow: parsed.whyNow,
				missingContext: parsed.missingContext,
				expirySeconds: parsed.expirySeconds,
				createdAt: parsed.createdAt,
				need: parsed.need,
				needReason: parsed.needReason
			),
			repaired: true
		)
	}

	private static func deriveGoal(from situational: SituationalContextSnapshot) -> String {
		let wf = situational.inferredWorkflow
		let app = situational.activeAppName.lowercased()
		let title = situational.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		if wf == .debugging || app.contains("xcode") { return "extract debugging context" }
		if wf == .browsing || wf == .research {
			let topic = extractTopic(fromTitle: title)
			return topic.isEmpty ? "extract page details" : "extract \(topic) details"
		}
		return "extract context"
	}

	private static func deriveCats(from situational: SituationalContextSnapshot) -> [String] {
		let wf = situational.inferredWorkflow
		let app = situational.activeAppName.lowercased()
		let titleLower = situational.windowTitle.lowercased()
		if wf == .debugging || app.contains("xcode") { return ["context", "extract"] }
		if titleLower.contains(" vs ") || titleLower.contains("compare") { return ["compare", "extract"] }
		if wf == .research { return ["extract", "output"] }
		return ["extract"]
	}

	private static func extractTopic(fromTitle title: String) -> String {
		let separators = [" - ", " — ", " | ", " • "]
		var base = title
		for sep in separators {
			if let r = base.range(of: sep) {
				base = String(base[..<r.lowerBound])
				break
			}
		}
		let words = base.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "/" })
		guard !words.isEmpty else { return "" }
		return words.prefix(3).joined(separator: " ")
	}
}
