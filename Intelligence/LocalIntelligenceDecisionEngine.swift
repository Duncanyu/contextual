import Foundation

/// Local-only LLM decision step (T12.3). Never throws to callers; always returns a safe response.
final class LocalIntelligenceDecisionEngine {
	private let modelManager: ModelManager
	private let client: LocalAIClient

	/// Proposal-selection race deadline (not used by Summarize/Explain/Rewrite execution paths).
	private static let proposalSelectionNanos: UInt64 = 1_500_000_000

	init(modelManager: ModelManager = .shared, client: LocalAIClient = .shared) {
		self.modelManager = modelManager
		self.client = client
		print("[TRACE_INIT] LocalIntelligenceDecisionEngine active file=\(#file)")
	}

	/// LLM proposal intelligence with ~1.5s ceiling; late completions may be discarded by the caller via generation guards.
	func decideWithProposalSelectionDeadline(
		request: IntelligenceDecisionRequest,
		suggestionStrength: SuggestionStrength? = nil,
		nanoseconds: UInt64 = proposalSelectionNanos
	) async -> IntelligenceDecisionResponse {
		await withTaskGroup(of: IntelligenceDecisionResponse.self) { group in
			group.addTask {
				await self.decide(request: request, suggestionStrength: suggestionStrength)
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: nanoseconds)
				return Self.proposalTimeoutResponse()
			}
			let first = await group.next() ?? Self.fallback(reason: "Local intelligence unavailable or skipped")
			group.cancelAll()
			if first.reason == "proposal_llm_timeout" {
				print("[IntelligenceFallback] reason=timeout layer=llm")
				IntelligenceDebugLogger.log(
					stage: .llm,
					event: "fallback",
					meta: IntelligenceDebugMeta(reason: "timeout", layer: "llm", fallback: true),
					throttleKey: "timeout"
				)
			}
			return first
		}
	}

	func decide(
		request: IntelligenceDecisionRequest,
		suggestionStrength: SuggestionStrength? = nil
	) async -> IntelligenceDecisionResponse {
		if let strength = suggestionStrength, strength == .weak {
			Self.logLLMSkipped(reason: "weak_strength", meta: Self.safeMeta(request))
			return Self.fallback(reason: "Skipped: weak strength")
		}

		guard !request.compressedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			Self.logLLMSkipped(reason: "empty_text", meta: Self.safeMeta(request))
			return Self.fallback(reason: "Skipped: empty compressedText")
		}
		guard !request.availableActions.isEmpty else {
			Self.logLLMSkipped(reason: "no_actions", meta: Self.safeMeta(request))
			return Self.fallback(reason: "Skipped: no availableActions")
		}
		guard request.textLength >= 30 else {
			Self.logLLMSkipped(reason: "too_short", meta: Self.safeMeta(request))
			return Self.fallback(reason: "Skipped: too_short")
		}
		guard request.contextType != .random else {
			Self.logLLMSkipped(reason: "random_context", meta: Self.safeMeta(request))
			return Self.fallback(reason: "Skipped: random")
		}
		let st = request.sourceType.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !st.isEmpty, st != "unknown" else {
			Self.logLLMSkipped(reason: "bad_source", meta: Self.safeMeta(request))
			return Self.fallback(reason: "Skipped: sourceType")
		}

		// If the system already determined the suggestion is not medium/strong, avoid any model call.
		if let strength = suggestionStrength, strength == .medium || strength == .strong {
			// ok
		} else if suggestionStrength != nil {
			Self.logLLMSkipped(reason: "strength_not_allowed", meta: Self.safeMeta(request))
			return Self.fallback(reason: "Skipped: strength")
		}

		guard await modelManager.isGenerationAvailable() else {
			print("[IntelligenceFallback] reason=model_unavailable layer=llm")
			IntelligenceDebugLogger.log(
				stage: .llm,
				event: "skipped",
				meta: IntelligenceDebugMeta(reason: "model_unavailable", layer: "llm", source: request.sourceType, type: request.contextType.rawValue),
				throttleKey: "model_unavailable"
			)
			return Self.fallback(reason: "Local intelligence unavailable or skipped")
		}

		IntelligenceDebugLogger.log(
			stage: .llm,
			event: "started",
			meta: IntelligenceDebugMeta(layer: "llm", source: request.sourceType, type: request.contextType.rawValue)
		)

		let prompt = buildPrompt(request: request)
		let model = LocalAISettings.shared.modelName

		let raw: String
		do {
			raw = try await client.generate(prompt: prompt, model: model)
		} catch {
			IntelligenceDebugLogger.log(
				stage: .llm,
				event: "fallback",
				meta: IntelligenceDebugMeta(reason: "generate_failed", layer: "llm", fallback: true),
				throttleKey: "gen_fail"
			)
			return Self.fallback(reason: "Local intelligence unavailable or skipped")
		}

		guard let decoded = parseJSONDecision(from: raw) else {
			print("[IntelligenceFallback] reason=invalid_output layer=llm")
			IntelligenceDebugLogger.log(
				stage: .llm,
				event: "fallback",
				meta: IntelligenceDebugMeta(reason: "invalid_output", layer: "llm", fallback: true),
				throttleKey: "parse_fail"
			)
			return Self.fallback(reason: "Local intelligence unavailable or skipped")
		}

		let sanitized = sanitize(response: decoded, for: request)
		guard sanitized.isValid(for: request) else {
			print("[IntelligenceFallback] reason=invalid_output layer=llm")
			IntelligenceDebugLogger.log(
				stage: .llm,
				event: "fallback",
				meta: IntelligenceDebugMeta(reason: "invalid_output", layer: "llm", fallback: true),
				throttleKey: "invalid_sanitize"
			)
			return Self.fallback(reason: "Local intelligence unavailable or skipped")
		}

		let cs = String(format: "%.2f", sanitized.confidence)
		IntelligenceDebugLogger.log(
			stage: .llm,
			event: "decision",
			meta: IntelligenceDebugMeta(
				layer: "llm",
				action: sanitized.bestActionId,
				conf: cs,
				suggest: sanitized.shouldSuggest
			)
		)
		return sanitized
	}

	private static func safeMeta(_ request: IntelligenceDecisionRequest) -> IntelligenceDebugMeta {
		IntelligenceDebugMeta(
			layer: "llm",
			source: request.sourceType,
			type: request.contextType.rawValue,
			lenBucket: request.textLength / 25
		)
	}

	private static func logLLMSkipped(reason: String, meta: IntelligenceDebugMeta) {
		IntelligenceDebugLogger.log(stage: .llm, event: "skipped", meta: meta.with(reason: reason), throttleKey: "skip|\(reason)")
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
Rules: bestActionId must be one of [\(actions)] when shouldSuggest=true. suggestedTitle must be <=60 chars, end with ?, start with natural phrasing like "Want…", "Need…", "Want me…", "Want help…", or "Want a quick…", and must NOT quote or include user text.

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

		// Strict title validation for display happens in `IntelligenceProposalTitleValidator` (T12.7).

		return IntelligenceDecisionResponse(
			shouldSuggest: should,
			bestActionId: best,
			confidence: confidence,
			reason: reason,
			suggestedTitle: title
		)
	}

	private static func compactOneLine(_ s: String) -> String {
		s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func proposalTimeoutResponse() -> IntelligenceDecisionResponse {
		IntelligenceDecisionResponse(
			shouldSuggest: false,
			bestActionId: nil,
			confidence: 0,
			reason: "proposal_llm_timeout",
			suggestedTitle: nil
		)
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

