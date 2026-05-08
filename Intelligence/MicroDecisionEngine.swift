import Foundation

/// Fast local classification tier (T12.3.5). Not wired into live proposal selection yet.
final class MicroDecisionEngine {
	func decide(request: MicroDecisionRequest) -> MicroDecisionResponse {
		if let reason = Self.skipReason(for: request) {
			print("[MicroDecision] skipped reason=\(reason)")
			let code = Self.debugSkipCode(reason)
			IntelligenceDebugLogger.log(
				stage: .micro,
				event: "skipped",
				meta: IntelligenceDebugMeta(reason: code, layer: "micro", detail: reason),
				throttleKey: "skip|\(code)"
			)
			return Self.fallback()
		}

		IntelligenceDebugLogger.log(
			stage: .micro,
			event: "attempted",
			meta: IntelligenceDebugMeta(layer: "micro", source: request.sourceType, type: request.contextType.rawValue)
		)

		guard let raw = MicroDecisionModelProvider.shared.predict(request: request) else {
			print("[MicroDecision] fallback_used reason=no_model_output")
			IntelligenceDebugLogger.log(
				stage: .micro,
				event: "output_missing",
				meta: IntelligenceDebugMeta(reason: "model_unavailable", layer: "micro")
			)
			IntelligenceDebugLogger.log(
				stage: .micro,
				event: "fallback",
				meta: IntelligenceDebugMeta(reason: "model_unavailable", layer: "micro", fallback: true)
			)
			return Self.fallback()
		}

		guard let validated = Self.validate(raw, request: request) else {
			print("[MicroDecision] fallback_used reason=invalid_model_output")
			IntelligenceDebugLogger.log(
				stage: .micro,
				event: "output_invalid",
				meta: IntelligenceDebugMeta(reason: "invalid_output", layer: "micro")
			)
			IntelligenceDebugLogger.log(
				stage: .micro,
				event: "fallback",
				meta: IntelligenceDebugMeta(reason: "invalid_output", layer: "micro", fallback: true)
			)
			return Self.fallback()
		}

		let c = String(format: "%.2f", validated.confidence)
		print("[MicroDecision] model_used conf=\(c)")
		IntelligenceDebugLogger.log(
			stage: .micro,
			event: "decision",
			meta: IntelligenceDebugMeta(
				layer: "micro",
				action: validated.bestActionId,
				conf: c,
				suggest: validated.shouldSuggest
			)
		)
		return validated
	}

	// MARK: - Internals

	private static func skipReason(for request: MicroDecisionRequest) -> String? {
		if request.compressedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return "empty_compressed"
		}
		if request.availableActions.isEmpty {
			return "no_actions"
		}
		if request.textLength < 20 {
			return "too_short"
		}
		let st = request.sourceType.trimmingCharacters(in: .whitespacesAndNewlines)
		if st.isEmpty || st == "unknown" {
			return "sourceType"
		}
		return nil
	}

	private static func validate(_ response: MicroDecisionResponse, request: MicroDecisionRequest) -> MicroDecisionResponse? {
		let confidence = min(1.0, max(0.0, response.confidence))

		if response.shouldSuggest {
			guard let id = response.bestActionId, request.availableActions.contains(id) else {
				return nil
			}
			return MicroDecisionResponse(shouldSuggest: true, bestActionId: id, confidence: confidence)
		}

		return MicroDecisionResponse(shouldSuggest: false, bestActionId: nil, confidence: confidence)
	}

	private static func fallback() -> MicroDecisionResponse {
		MicroDecisionResponse(shouldSuggest: false, bestActionId: nil, confidence: 0)
	}

	private static func debugSkipCode(_ internalReason: String) -> String {
		switch internalReason {
		case "empty_compressed": return "invalid_request"
		case "no_actions": return "no_actions"
		case "too_short": return "too_short"
		case "sourceType": return "bad_source"
		default: return "invalid_request"
		}
	}

	#if DEBUG
	/// Debug-only sanity checks; not invoked by the app.
	static func _selfTest() -> Bool {
		let features = ContextFeatures(
			textLength: 50,
			wordCount: 10,
			sentenceCount: 2,
			punctuationDensity: 0.05,
			hasQuestion: false,
			isLikelyCode: false,
			isLikelyLog: false,
			lineCount: 2,
			averageLineLength: 25,
			repetitionScore: 0
		)
		let filler = String(repeating: "a", count: 25)
		let reqOk = MicroDecisionRequest(
			contextType: .notes,
			features: features,
			availableActions: ["summarize_text"],
			sourceType: "clipboard",
			appName: nil,
			windowTitle: nil,
			textLength: 50,
			lineCount: 2,
			compressedText: filler
		)
		let engine = MicroDecisionEngine()
		let outOk = engine.decide(request: reqOk)
		if outOk.shouldSuggest { return false }
		if outOk.bestActionId != nil { return false }
		if outOk.confidence != 0 { return false }

		let reqShort = MicroDecisionRequest(
			contextType: .notes,
			features: features,
			availableActions: ["summarize_text"],
			sourceType: "clipboard",
			appName: nil,
			windowTitle: nil,
			textLength: 10,
			lineCount: 1,
			compressedText: filler
		)
		let outShort = engine.decide(request: reqShort)
		if outShort.shouldSuggest { return false }

		return true
	}
	#endif
}
