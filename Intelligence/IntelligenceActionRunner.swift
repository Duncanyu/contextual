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
	- Treat the OCR body as the only verbatim evidence of visible text. Quote or paraphrase it carefully.
	- App name, bundle id, window-title availability, workflow hints, and fused metadata are NOT proof of what is on screen; never invent UI text from them.
	- Visual/AX/fused fields are low-trust hints only; if they disagree with OCR, prefer OCR for literal claims.
	- Never mention workflow hints (e.g. code editing, terminal debugging) unless directly supported by OCR or AX evidence. If visual metadata conflicts, ignore it for semantic conclusions.
	- If OCR is empty, very short, garbled, or metadata-only, say evidence is limited and avoid detailed narratives.
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
