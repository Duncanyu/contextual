import Foundation

/// Metadata-only debug logging for the intelligence pipeline (T12.9). Never log user text, prompts, or model output.
enum IntelligenceDebugStage: String {
	case selection
	case micro
	case llm
	case cache
	case budget
	case execution
}

/// Safe fields only — no titles, excerpts, prompts, or raw model reasons.
struct IntelligenceDebugMeta: Sendable {
	var reason: String?
	var layer: String?
	/// Source kind (e.g. selected_text, clipboard)
	var source: String?
	/// Context classification raw value
	var type: String?
	var strength: String?
	var actions: Int?
	var lenBucket: Int?
	var lineBucket: Int?
	var action: String?
	/// Formatted confidence e.g. "0.91"
	var conf: String?
	var suggest: Bool?
	/// Budget score formatted
	var score: String?
	var fallback: Bool?
	/// Safe sub-reason (validator/budget detail codes only)
	var detail: String?
	var fp: String?
}

extension IntelligenceDebugMeta {
	func with(
		reason: String? = nil,
		layer: String? = nil,
		detail: String? = nil,
		action: String? = nil,
		conf: String? = nil,
		suggest: Bool? = nil,
		fallback: Bool? = nil
	) -> IntelligenceDebugMeta {
		var m = self
		if let reason { m.reason = reason }
		if let layer { m.layer = layer }
		if let detail { m.detail = detail }
		if let action { m.action = action }
		if let conf { m.conf = conf }
		if let suggest { m.suggest = suggest }
		if let fallback { m.fallback = fallback }
		return m
	}
}

enum IntelligenceDebugLogger {
	private static let lock = NSLock()
	private static var throttleUntil: [String: Date] = [:]
	private static let throttleInterval: TimeInterval = 2.0
	private static let throttlePruneAge: TimeInterval = 6.0

	/// Emits `[IntelligenceDebug] ...` — optional `throttleKey` suppresses identical operational noise within ~2s.
	static func log(
		stage: IntelligenceDebugStage,
		event: String,
		meta: IntelligenceDebugMeta = IntelligenceDebugMeta(),
		throttleKey: String? = nil
	) {
		let now = Date()
		if let tk = throttleKey {
			let key = "\(stage.rawValue)|\(event)|\(tk)"
			lock.lock()
			if let last = throttleUntil[key], now.timeIntervalSince(last) < throttleInterval {
				lock.unlock()
				return
			}
			throttleUntil[key] = now
			if throttleUntil.count > 200 {
				let cutoff = now.addingTimeInterval(-throttlePruneAge)
				throttleUntil = throttleUntil.filter { $0.value > cutoff }
			}
			lock.unlock()
		}

		var parts: [String] = []
		parts.append("stage=\(stage.rawValue)")
		parts.append("event=\(event)")
		if let r = meta.reason {
			if stage == .execution && event == "budget_denied" {
				let cleanR = r.replacingOccurrences(of: "\"", with: "")
				let mapped: String
				switch cleanR {
				case "permissionDenied", "expensive_context_denied", "expensiveContextDenied", "permission_denied", "permission_missing", "permission missing":
					mapped = "permission missing"
				case "generation_frequency_exceeded", "generationFrequencyExceeded", "frequencyLimit", "rate_limit", "rate limit":
					mapped = "rate limit"
				case "already_attempted", "alreadyAttempted", "already attempted":
					mapped = "already attempted"
				case "vision_not_allowed", "visionNotAllowed", "visual_model_not_allowed", "visual model not allowed":
					mapped = "visual model not allowed"
				case "ocr_not_allowed", "ocrNotAllowed", "ocr_disabled", "OCR disabled":
					mapped = "OCR disabled"
				default:
					mapped = "budget exhausted"
				}
				parts.append("reason=\"\(mapped)\"")
			} else {
				parts.append("reason=\(r)")
			}
		}
		if let l = meta.layer { parts.append("layer=\(l)") }
		if let s = meta.source { parts.append("source=\(s)") }
		if let t = meta.type { parts.append("type=\(t)") }
		if let st = meta.strength { parts.append("strength=\(st)") }
		if let a = meta.actions { parts.append("actions=\(a)") }
		if let lb = meta.lenBucket { parts.append("lenBucket=\(lb)") }
		if let ln = meta.lineBucket { parts.append("lineBucket=\(ln)") }
		if let ac = meta.action { parts.append("action=\(ac)") }
		if let c = meta.conf { parts.append("conf=\(c)") }
		if let su = meta.suggest { parts.append("suggest=\(su)") }
		if let sc = meta.score { parts.append("score=\(sc)") }
		if let f = meta.fallback { parts.append("fallback=\(f)") }
		if let d = meta.detail { parts.append("detail=\(d)") }
		if let p = meta.fp { parts.append("fp=\(p)") }

		print("[IntelligenceDebug] " + parts.joined(separator: " "))
	}

	static func selectionMeta(
		request: IntelligenceDecisionRequest,
		strength: SuggestionStrength,
		sourceType: String,
		actionCount: Int
	) -> IntelligenceDebugMeta {
		IntelligenceDebugMeta(
			source: sourceType,
			type: request.contextType.rawValue,
			strength: strength.rawValue,
			actions: actionCount,
			lenBucket: request.textLength / 25,
			lineBucket: request.lineCount / 2
		)
	}
}
