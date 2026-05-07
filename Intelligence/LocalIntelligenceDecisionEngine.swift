import Foundation

/// Local-only LLM decision step (T12.3). Infrastructure only; not wired into the live pipeline.
final class LocalIntelligenceDecisionEngine {
	private let modelManager: ModelManager
	private let client: LocalAIClient

	init(modelManager: ModelManager = .shared, client: LocalAIClient = .shared) {
		self.modelManager = modelManager
		self.client = client
	}

	func decide(
		request: IntelligenceDecisionRequest,
		suggestionStrength: SuggestionStrength? = nil
	) async -> IntelligenceDecisionResponse {
		if let strength = suggestionStrength, strength == .weak {
			return Self.fallback(reason: "Skipped: weak strength")
		}

		guard !request.compressedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return Self.fallback(reason: "Skipped: empty compressedText")
		}
		guard !request.availableActions.isEmpty else {
			return Self.fallback(reason: "Skipped: no availableActions")
		}
		guard request.textLength >= 30 else {
			return Self.fallback(reason: "Skipped: too_short")
		}
		guard request.contextType != .random else {
			return Self.fallback(reason: "Skipped: random")
		}
		let st = request.sourceType.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !st.isEmpty, st != "unknown" else {
			return Self.fallback(reason: "Skipped: sourceType")
		}

		// If the system already determined the suggestion is not medium/strong, avoid any model call.
		if let strength = suggestionStrength, strength == .medium || strength == .strong {
			// ok
		} else if suggestionStrength != nil {
			return Self.fallback(reason: "Skipped: strength")
		}

		guard await modelManager.isGenerationAvailable() else {
			return Self.fallback(reason: "Local intelligence unavailable or skipped")
		}

		print("[LocalIntelligence] attempted \(request.debugSummary())")

		let prompt = buildPrompt(request: request)
		let model = LocalAISettings.shared.modelName

		let raw: String
		do {
			raw = try await client.generate(prompt: prompt, model: model)
		} catch {
			print("[LocalIntelligence] fallback reason=generate_failed")
			return Self.fallback(reason: "Local intelligence unavailable or skipped")
		}

		guard let decoded = parseJSONDecision(from: raw) else {
			print("[LocalIntelligence] fallback reason=parse_failed")
			return Self.fallback(reason: "Local intelligence unavailable or skipped")
		}

		let sanitized = sanitize(response: decoded, for: request)
		guard sanitized.isValid(for: request) else {
			print("[LocalIntelligence] fallback reason=invalid_response")
			return Self.fallback(reason: "Local intelligence unavailable or skipped")
		}

		print("[LocalIntelligence] accepted shouldSuggest=\(sanitized.shouldSuggest) confidence=\(String(format: "%.2f", sanitized.confidence))")
		return sanitized
	}

	// MARK: - Prompting (no raw text logging)

	private func buildPrompt(request: IntelligenceDecisionRequest) -> String {
		// Strict JSON only; keep prompt short and only include compressed text.
		let actions = request.availableActions.joined(separator: ", ")
		let app = request.appName ?? ""
		let title = request.windowTitle ?? ""
		let type = request.contextType.rawValue

		let f = request.features
		let feats = [
			"len=\(f.textLength)",
			"words=\(f.wordCount)",
			"sentences=\(f.sentenceCount)",
			"punct=\(String(format: "%.4f", f.punctuationDensity))",
			"q=\(f.hasQuestion)",
			"code=\(f.isLikelyCode)",
			"log=\(f.isLikelyLog)",
			"lines=\(f.lineCount)",
			"rep=\(String(format: "%.3f", f.repetitionScore))"
		].joined(separator: " ")

		return """
Return STRICT JSON only with keys: shouldSuggest (bool), bestActionId (string|null), confidence (number 0..1), reason (string), suggestedTitle (string|null).
Rules: bestActionId must be one of [\(actions)] when shouldSuggest=true. suggestedTitle must be short (<120 chars), generic, and must NOT quote or include user text.

Context:
type=\(type)
sourceType=\(request.sourceType)
app=\(app)
windowTitle=\(title)
features=\(feats)
availableActions=[\(actions)]
compressedText:
\(request.compressedText)
"""
	}

	// MARK: - Parsing / sanitization

	private struct ModelDecisionJSON: Decodable {
		let shouldSuggest: Bool?
		let bestActionId: String?
		let confidence: Double?
		let reason: String?
		let suggestedTitle: String?
	}

	private func parseJSONDecision(from raw: String) -> IntelligenceDecisionResponse? {
		// Attempt to isolate a JSON object without logging raw output.
		guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return nil }
		let json = String(raw[start...end])
		guard let data = json.data(using: .utf8) else { return nil }
		guard let decoded = try? JSONDecoder().decode(ModelDecisionJSON.self, from: data) else { return nil }

		let should = decoded.shouldSuggest ?? false
		let id = decoded.bestActionId?.trimmingCharacters(in: .whitespacesAndNewlines)
		let conf = decoded.confidence ?? 0
		let reason = decoded.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let title = decoded.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

		return IntelligenceDecisionResponse(
			shouldSuggest: should,
			bestActionId: id?.isEmpty == true ? nil : id,
			confidence: conf,
			reason: reason,
			suggestedTitle: title?.isEmpty == true ? nil : title
		)
	}

	private func sanitize(response: IntelligenceDecisionResponse, for request: IntelligenceDecisionRequest) -> IntelligenceDecisionResponse {
		var should = response.shouldSuggest
		var best = response.bestActionId
		var confidence = min(1.0, max(0.0, response.confidence))

		var reason = Self.compactOneLine(response.reason)
		if reason.count > 180 { reason = String(reason.prefix(180)) }
		if reason.isEmpty { reason = "local_intelligence" }

		var title = response.suggestedTitle.map(Self.compactOneLine)
		if let t = title, t.count >= 120 { title = nil }

		// Enforce action id constraints.
		if should {
			guard let id = best, request.availableActions.contains(id) else {
				should = false
				best = nil
				confidence = 0
				title = nil
				reason = "invalid_bestActionId"
				return IntelligenceDecisionResponse(shouldSuggest: should, bestActionId: best, confidence: confidence, reason: reason, suggestedTitle: title)
			}
		} else {
			best = nil
			title = nil
		}

		// Title safety: require question-style and avoid echoing user text.
		if let t = title {
			if !isSafeSuggestedTitle(t, request: request) {
				title = nil
			}
		}

		return IntelligenceDecisionResponse(
			shouldSuggest: should,
			bestActionId: best,
			confidence: confidence,
			reason: reason,
			suggestedTitle: title
		)
	}

	private func isSafeSuggestedTitle(_ title: String, request: IntelligenceDecisionRequest) -> Bool {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count < 120 else { return false }
		guard trimmed.hasSuffix("?") else { return false }
		guard !trimmed.contains("\n") else { return false }

		// Avoid the model copying text from the excerpt: reject if any token >= 8 chars appears in compressedText.
		let excerptLower = request.compressedText.lowercased()
		let tokens = trimmed.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
		for tok in tokens where tok.count >= 8 {
			if excerptLower.contains(tok) {
				return false
			}
		}
		return true
	}

	private static func compactOneLine(_ s: String) -> String {
		s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func fallback(reason: String) -> IntelligenceDecisionResponse {
		IntelligenceDecisionResponse(
			shouldSuggest: false,
			bestActionId: nil,
			confidence: 0,
			reason: reason,
			suggestedTitle: nil
		)
	}
}

