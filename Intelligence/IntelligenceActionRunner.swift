import Foundation

enum ActionPromptKind {
	case summarize
	case explain
	case rewrite
	case analyzeScreen
}

enum IntelligenceActionRunner {
	/// Shared anti-speculation rules for Analyze Screen (also asserted by Phase 14 tuning self-test).
	static let analyzeScreenSafetyPreamble = """
	You are helping interpret on-screen evidence for a macOS user.

	IMPORTANT RULES:
	- Treat the “Visible text” section as the only verbatim transcript of on-screen characters. Quote or paraphrase it carefully.
	- App name and bundle id are context only; they are not proof of what is visible.
	- Any “Layout hint” or “Activity pattern” lines are secondary; if they disagree with the readable text, prefer the text for factual claims.
	- Do not claim debugging, terminals, code review, or deep research unless the readable text clearly supports it.
	- If the capture is empty, very short, or mostly chrome/menus, say evidence is limited in one short sentence, then suggest practical next steps (select or copy text).
	- Do not infer passwords, private URLs, file paths, emails, or unseen window titles.
	- Be concise and practical. No title.
	"""

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
			\(Self.analyzeScreenSafetyPreamble)

			Screen situation and readable text:
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
