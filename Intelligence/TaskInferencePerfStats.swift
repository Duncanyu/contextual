import Foundation

// MARK: - Outcome

enum TaskInferencePerfOutcome: String, Sendable, Codable {
	case success
	case successAfterRetry = "success_after_retry"
	case timeout
	case malformedJSON = "malformed_json"
	case unavailable
	case cancelled
	case parseFailed = "parse_failed"
	case cached
	case placeholder     // parsed OK but detected as schema copy; retry triggered
	case exampleLeakage = "example_leakage" // parsed OK but echoes generic training-data phrase
	case ungroundedOutput = "ungrounded_output" // parsed OK but output not grounded in context
}

// MARK: - Entry

struct TaskInferencePerfEntry: Sendable {
	let model: String
	let promptBytes: Int
	let timeoutMs: Int
	let elapsedMs: Int
	let numPredict: Int
	let temperature: Double
	let outputBytes: Int
	let parseSuccess: Bool
	let outcome: TaskInferencePerfOutcome
	/// "none" | "ocr_only" | "text_only" | "text_and_ocr" | "rich"
	let contextRichness: String
	let hasOCR: Bool
	let usedCache: Bool
	let usedStreaming: Bool
	let recordedAt: Date
}

// MARK: - Rolling stats (published to debug panel)

struct TaskInferenceRollingStats: Sendable, Equatable {
	let attempts: Int
	let successCount: Int
	let timeoutCount: Int
	let malformedCount: Int
	let cachedCount: Int
	let p50LatencyMs: Int
	let p90LatencyMs: Int
	let p95LatencyMs: Int
	let successRate: Double
	let timeoutRate: Double
	/// Last 20 outcomes as short codes for the debug panel
	let last20Outcomes: [String]
	let currentModel: String
	let updatedAt: Date

	static let empty = TaskInferenceRollingStats(
		attempts: 0, successCount: 0, timeoutCount: 0, malformedCount: 0, cachedCount: 0,
		p50LatencyMs: 0, p90LatencyMs: 0, p95LatencyMs: 0,
		successRate: 0, timeoutRate: 0,
		last20Outcomes: [], currentModel: "—", updatedAt: Date(timeIntervalSince1970: 0)
	)
}

// MARK: - Actor

/// Bounded in-memory ring-buffer of TaskInference performance entries.
/// Thread-safe; does not persist across app launches.
actor TaskInferencePerfStats {
	static let shared = TaskInferencePerfStats()

	private static let maxEntries = 100

	private var entries: [TaskInferencePerfEntry] = []

	// MARK: - Record

	func record(_ entry: TaskInferencePerfEntry) {
		entries.append(entry)
		if entries.count > Self.maxEntries {
			entries.removeFirst(entries.count - Self.maxEntries)
		}
		// Always emit [TaskInferencePerf] log for every attempt.
		emitPerfLog(entry)
	}

	private func emitPerfLog(_ e: TaskInferencePerfEntry) {
		print(
			"[TaskInferencePerf] model=\(e.model) prompt_bytes=\(e.promptBytes) timeout_ms=\(e.timeoutMs) elapsed_ms=\(e.elapsedMs) num_predict=\(e.numPredict) temperature=\(String(format: "%.2f", e.temperature)) output_bytes=\(e.outputBytes) parse_success=\(e.parseSuccess ? "yes" : "no") outcome=\(e.outcome.rawValue) richness=\(e.contextRichness) ocr=\(e.hasOCR ? "1" : "0") cached=\(e.usedCache ? "yes" : "no") stream=\(e.usedStreaming ? "yes" : "no")"
		)
	}

	// MARK: - Rolling stats

	func rollingStats(model: String) -> TaskInferenceRollingStats {
		let recent = Array(entries.suffix(50))
		let total = recent.count
		guard total > 0 else {
			return TaskInferenceRollingStats(
				attempts: 0, successCount: 0, timeoutCount: 0, malformedCount: 0, cachedCount: 0,
				p50LatencyMs: 0, p90LatencyMs: 0, p95LatencyMs: 0,
				successRate: 0, timeoutRate: 0,
				last20Outcomes: [], currentModel: model, updatedAt: Date()
			)
		}

		let successes = recent.filter { $0.outcome == .success || $0.outcome == .successAfterRetry }.count
		let timeouts = recent.filter { $0.outcome == .timeout }.count
		let malformed = recent.filter { $0.outcome == .malformedJSON || $0.outcome == .parseFailed || $0.outcome == .placeholder || $0.outcome == .exampleLeakage || $0.outcome == .ungroundedOutput }.count
		let cached = recent.filter { $0.outcome == .cached }.count

		// Latency only from non-cached, non-unavailable entries
		let latencies = recent
			.filter { $0.outcome != .cached && $0.outcome != .unavailable }
			.map { $0.elapsedMs }
			.sorted()
		let p50 = percentile(latencies, 50)
		let p90 = percentile(latencies, 90)
		let p95 = percentile(latencies, 95)

		let successRate = total > 0 ? Double(successes) / Double(total) : 0
		let timeoutRate = total > 0 ? Double(timeouts) / Double(total) : 0

		let last20 = Array(entries.suffix(20)).map { shortCode($0.outcome) }

		return TaskInferenceRollingStats(
			attempts: total,
			successCount: successes,
			timeoutCount: timeouts,
			malformedCount: malformed,
			cachedCount: cached,
			p50LatencyMs: p50,
			p90LatencyMs: p90,
			p95LatencyMs: p95,
			successRate: successRate,
			timeoutRate: timeoutRate,
			last20Outcomes: last20,
			currentModel: model,
			updatedAt: Date()
		)
	}

	// MARK: - Helpers

	private func percentile(_ sorted: [Int], _ p: Int) -> Int {
		guard !sorted.isEmpty else { return 0 }
		let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count) * Double(p) / 100.0)))
		return sorted[idx]
	}

	private func shortCode(_ outcome: TaskInferencePerfOutcome) -> String {
		switch outcome {
		case .success: return "✓"
		case .successAfterRetry: return "✓R"
		case .timeout: return "⏱"
		case .malformedJSON: return "✗J"
		case .parseFailed: return "✗P"
		case .placeholder: return "✗φ"
		case .exampleLeakage: return "✗E"
		case .ungroundedOutput: return "✗U"
		case .unavailable: return "–"
		case .cancelled: return "✕"
		case .cached: return "↩"
		}
	}

	/// Context richness bucket from snapshot signals
	static func richnessBucket(hasOCR: Bool, hasSelectedText: Bool, hasClipboard: Bool) -> String {
		let count = (hasOCR ? 1 : 0) + (hasSelectedText ? 1 : 0) + (hasClipboard ? 1 : 0)
		if count >= 3 { return "rich" }
		if count == 2 { return "text_and_ocr" }
		if hasOCR { return "ocr_only" }
		if hasSelectedText || hasClipboard { return "text_only" }
		return "none"
	}
}
