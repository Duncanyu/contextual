import Foundation

/// Fast local classification tier (T12.3.5). Not wired into live proposal selection yet.
final class MicroDecisionEngine {
	func decide(request: MicroDecisionRequest) -> MicroDecisionResponse {
		if let reason = Self.skipReason(for: request) {
			print("[MicroDecision] skipped reason=\(reason)")
			return Self.fallback()
		}

		guard let raw = MicroDecisionModelProvider.shared.predict(request: request) else {
			print("[MicroDecision] fallback_used reason=no_model_output")
			return Self.fallback()
		}

		guard let validated = Self.validate(raw, request: request) else {
			print("[MicroDecision] fallback_used reason=invalid_model_output")
			return Self.fallback()
		}

		let c = String(format: "%.2f", validated.confidence)
		print("[MicroDecision] model_used conf=\(c)")
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
