import Foundation

enum ContextDebugStage: String, Sendable {
	case capability
	case source
	case budget
	case freshness
	case fusion
	case snapshot
	case visual
	case ax
	case typing
	case pointer
}

enum ContextDebugEvent: String, Sendable {
	case registered
	case updated
	case collected
	case skipped
	case invalidated
	case stale
	case expired
	case allowed
	case denied
	case deferred
	case fused
	case primary_selected
	case conflict
	case selftest
	case recorded
	case decayed
}

/// Central metadata-only logger for rich context infrastructure.
/// - Never logs raw user content.
/// - Dedupes identical lines within a short window to reduce spam.
final class ContextDebugLogger {
	static let shared = ContextDebugLogger()

	private let lock = NSLock()
	private var lastBySignature: [String: Date] = [:]

	/// Dedupe window for identical log lines.
	private let throttleSeconds: TimeInterval = 1.5

	private init() {}

	func log(
		stage: ContextDebugStage,
		event: ContextDebugEvent,
		source: String? = nil,
		reason: String? = nil,
		cost: ContextCollectionCost? = nil,
		privacy: ContextPrivacySensitivity? = nil,
		latency: ContextLatencyCategory? = nil,
		permission: ContextPermissionState? = nil,
		mode: ContextCollectionMode? = nil,
		freshness: Double? = nil,
		label: ContextFreshnessLabel? = nil,
		confidence: Double? = nil,
		score: Double? = nil,
		conflict: Double? = nil,
		meta: [String: String]? = nil
	) {
		var parts: [String] = []
		parts.append("[ContextDebug]")
		parts.append("stage=\(stage.rawValue)")
		parts.append("event=\(event.rawValue)")
		if let source { parts.append("source=\(source)") }
		if let reason { parts.append("reason=\(reason)") }
		if let cost { parts.append("cost=\(cost.rawValue)") }
		if let privacy { parts.append("privacy=\(privacy.rawValue)") }
		if let latency { parts.append("latency=\(latency.rawValue)") }
		if let permission { parts.append("permission=\(permission.rawValue)") }
		if let mode { parts.append("mode=\(mode.rawValue)") }
		if let freshness { parts.append("freshness=\(fmt(freshness))") }
		if let label { parts.append("label=\(label.rawValue)") }
		if let confidence { parts.append("confidence=\(fmt(confidence))") }
		if let score { parts.append("score=\(fmt(score))") }
		if let conflict { parts.append("conflict=\(fmt(conflict))") }
		if let meta, !meta.isEmpty {
			let stable = meta.keys.sorted().map { "\($0)=\(meta[$0]!)" }.joined(separator: ",")
			parts.append("meta=\(stable)")
		}

		let line = parts.joined(separator: " ")
		if shouldSuppress(line: line) { return }
		print(line)
	}

	private func fmt(_ x: Double) -> String {
		String(format: "%.2f", x)
	}

	private func shouldSuppress(line: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let now = Date()
		if let last = lastBySignature[line], now.timeIntervalSince(last) < throttleSeconds {
			return true
		}
		lastBySignature[line] = now
		// Avoid unbounded growth.
		if lastBySignature.count > 500 {
			lastBySignature = lastBySignature.filter { now.timeIntervalSince($0.value) < 30 }
		}
		return false
	}

	// MARK: - Self-test

	func selfTest() -> Bool {
		log(stage: .capability, event: .registered, source: "selectedText", cost: .cheap, privacy: .high, freshness: 0.96, confidence: 0.80)
		log(stage: .capability, event: .updated, source: "screenOCR", reason: "availability_changed", cost: .expensive, privacy: .high)
		log(stage: .source, event: .collected, source: "activeWindowSnapshot", cost: .medium, privacy: .high, freshness: 0.92)
		log(stage: .source, event: .skipped, source: "activeWindowSnapshot", reason: "permission_denied")
		log(stage: .budget, event: .denied, source: "screenVision", reason: "enough_text_context", score: 0.20)
		log(stage: .freshness, event: .stale, source: "clipboardText", freshness: 0.22, label: .stale)
		log(stage: .fusion, event: .primary_selected, source: "selectedText", freshness: 0.96, confidence: 0.91)
		log(stage: .fusion, event: .conflict, reason: "selection_clipboard_diverge", conflict: 0.35)

		// Throttle check: identical line should be suppressed.
		log(stage: .fusion, event: .conflict, reason: "selection_clipboard_diverge", conflict: 0.35)
		log(stage: .fusion, event: .conflict, reason: "selection_clipboard_diverge", conflict: 0.35)

		log(stage: .fusion, event: .selftest, reason: "ok")
		return true
	}

	/// Freshness log helper that avoids spamming by logging only when label changes.
	private var lastFreshnessLabelBySource: [String: ContextFreshnessLabel] = [:]

	func logFreshness(source: String, score: Double) {
		let label = ContextFreshnessPolicy.decayLabel(score: score)
		lock.lock()
		let prev = lastFreshnessLabelBySource[source]
		if prev == label {
			lock.unlock()
			return
		}
		lastFreshnessLabelBySource[source] = label
		lock.unlock()

		log(stage: .freshness, event: .decayed, source: source, freshness: score, label: label)
	}
}

