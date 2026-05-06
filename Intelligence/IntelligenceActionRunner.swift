import Foundation

enum ActionPromptKind {
	case summarize
	case explain
	case rewrite
	case analyzeScreen
}

enum IntelligenceActionRunner {
	static func runActionPrompt(actionType: ActionPromptKind, input: String) async -> String {
		guard LocalAISettings.shared.localAIEnabled else {
			return unavailableMessage(for: actionType, detail: "Local AI is disabled.")
		}
		guard ModelManager.shared.detectOllamaInstalled() else {
			return unavailableMessage(for: actionType, detail: "Ollama is not installed.")
		}
		guard await ModelManager.shared.isGenerationAvailable() else {
			return unavailableMessage(for: actionType, detail: "Ollama is not running or the configured model is missing.")
		}

		let model = LocalAISettings.shared.modelName
		let prompt = promptForAction(actionType, input: input)

		do {
			return try await LocalAIClient.shared.generate(prompt: prompt, model: model)
		} catch {
			return unavailableMessage(for: actionType, detail: error.localizedDescription)
		}
	}

	private static func promptForAction(_ kind: ActionPromptKind, input: String) -> String {
		switch kind {
		case .summarize:
			return """
			You summarize text concisely. Reply with only the summary, no title or preamble.

			Text:
			\(input)
			"""
		case .explain:
			return """
			You explain the following text in plain, simple language. Reply with only the explanation, no title or preamble.

			Text:
			\(input)
			"""
		case .rewrite:
			return """
			Rewrite the following text for clarity and flow. Preserve the original meaning. Reply with only the rewritten text, no title or preamble.

			Text:
			\(input)
			"""
		case .analyzeScreen:
			return """
			Based only on the text visible in the OCR below (not the image), explain what appears to be on screen. Summarize the key points and what the user is likely looking at. If the OCR is noisy, say so and focus on the clearest lines. Do not claim you can see visual details beyond the OCR. Reply with only the analysis, no title.

			OCR context:
			\(input)
			"""
		}
	}

	private static func unavailableMessage(for kind: ActionPromptKind, detail: String) -> String {
		let label: String
		switch kind {
		case .summarize: label = "Summary unavailable"
		case .explain: label = "Explanation unavailable"
		case .rewrite: label = "Rewrite unavailable"
		case .analyzeScreen: label = "Screen analysis unavailable"
		}
		return "\(label): \(detail)"
	}
}
