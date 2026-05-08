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
			You are analyzing what the user is likely looking at on screen.

			IMPORTANT RULES:
			- Base your analysis ONLY on the provided OCR text and the structured metadata sections.
			- Do NOT infer hidden UI content or details that are not supported by the OCR or metadata.
			- Treat visual/AX/fused fields as *hints*, not ground truth.
			- If OCR is noisy or incomplete, say so and prefer the clearest evidence.
			- If evidence is insufficient, say what is uncertain and what is missing.
			- Be concise and practical. No title.

			Screen context (OCR + metadata):
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
