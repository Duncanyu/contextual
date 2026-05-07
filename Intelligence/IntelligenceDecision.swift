import Foundation

struct IntelligenceDecisionRequest: Sendable, Equatable {
	let contextType: ContextType
	let features: ContextFeatures
	let availableActions: [String]

	let sourceType: String
	let appName: String?
	let windowTitle: String?

	let textLength: Int
	let lineCount: Int

	/// Placeholder for T12.2 (context compression). Keep empty for now.
	let compressedText: String
}

struct IntelligenceDecisionResponse: Sendable, Equatable {
	let shouldSuggest: Bool
	let bestActionId: String?
	let confidence: Double
	let reason: String
	let suggestedTitle: String?
}

extension IntelligenceDecisionResponse {
	func isValid(for request: IntelligenceDecisionRequest) -> Bool {
		guard confidence >= 0.0, confidence <= 1.0 else { return false }

		if shouldSuggest {
			guard let id = bestActionId, !id.isEmpty else { return false }
			guard request.availableActions.contains(id) else { return false }
		}

		if let t = suggestedTitle, t.count >= 120 { return false }
		if reason.count >= 200 { return false }
		return true
	}
}

extension IntelligenceDecisionRequest {
	func debugSummary() -> String {
		"[IntelligenceRequest] type=\(contextType.rawValue) len=\(textLength) lines=\(lineCount) actions=\(availableActions.count)"
	}
}

/// Heuristic stub only (no AI). Intended for testing T12.1 wiring.
enum IntelligenceDecisionStub {
	static func generate(request: IntelligenceDecisionRequest) -> IntelligenceDecisionResponse {
		let actions = request.availableActions
		let type = request.contextType

		switch type {
		case .question, .errorLog, .code:
			let best = actions.contains("explain_text") ? "explain_text" : actions.first
			return IntelligenceDecisionResponse(
				shouldSuggest: best != nil,
				bestActionId: best,
				confidence: type == .errorLog ? 0.90 : 0.80,
				reason: "stub:\(type.rawValue)",
				suggestedTitle: "Want me to explain this?"
			)

		case .article, .notes:
			let best = actions.contains("summarize_text") ? "summarize_text" : actions.first
			return IntelligenceDecisionResponse(
				shouldSuggest: best != nil,
				bestActionId: best,
				confidence: 0.75,
				reason: "stub:\(type.rawValue)",
				suggestedTitle: "Want a quick summary?"
			)

		case .random:
			return IntelligenceDecisionResponse(
				shouldSuggest: false,
				bestActionId: nil,
				confidence: 0.60,
				reason: "stub:random",
				suggestedTitle: nil
			)
		}
	}
}

