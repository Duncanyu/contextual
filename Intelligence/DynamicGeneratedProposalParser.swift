import Foundation

/// Validates and sanitizes LLM proposal JSON (T18.3.1).
enum DynamicGeneratedProposalParser {

	static let maxProposals = 3
	static let maxTitleLength = 72
	static let maxDescriptionLength = 200
	static let maxOutcomeLength = 240
	static let minimumItemConfidence: Double = 0.42
	static let minimumChimeInConfidence: Double = 0.48

	private static let genericBannedPhrases = [
		"summarize selected",
		"summarize this",
		"summarize text",
		"summarize clipboard",
		"summarize the",
		"explain selected",
		"explain this",
		"explain text",
		"rewrite selected",
		"rewrite this",
		"rewrite text",
		"structure notes",
		"structure note",
		"summarize current",
		"quick summary",
	]

	static func parse(from raw: String, referenceTime: Date = Date()) -> DynamicGeneratedProposalResult? {
		guard let json = extractJSONObject(from: raw),
		      let data = json.data(using: .utf8)
		else {
			return nil
		}

		let decoded: DynamicGeneratedProposalLLMOutput
		do {
			decoded = try JSONDecoder().decode(DynamicGeneratedProposalLLMOutput.self, from: data)
		} catch {
			return nil
		}

		let proposalConfidence = clamp01(decoded.proposalConfidence)
		let shouldChimeIn = decoded.shouldChimeIn && proposalConfidence >= minimumChimeInConfidence

		var validated: [ValidatedDynamicGeneratedProposal] = []
		var warnings: [String] = []

		for (index, item) in decoded.proposals.prefix(maxProposals).enumerated() {
			if let proposal = validateItem(item, index: index, referenceTime: referenceTime) {
				validated.append(proposal)
			} else {
				warnings.append("item_rejected_\(index)")
			}
		}

		let effectiveChimeIn = shouldChimeIn && !validated.isEmpty

		return DynamicGeneratedProposalResult(
			status: .synthesized,
			shouldChimeIn: effectiveChimeIn,
			reason: cap(decoded.reason, max: 160) ?? "llm_synthesized",
			workflowAssessment: cap(decoded.workflowAssessment, max: 200) ?? "",
			proposalConfidence: proposalConfidence,
			requiresVisualContext: decoded.requiresVisualContext,
			proposals: validated,
			warnings: warnings,
			createdAt: referenceTime
		)
	}

	// MARK: - Item validation

	private static func validateItem(
		_ item: DynamicGeneratedProposalLLMItem,
		index: Int,
		referenceTime: Date
	) -> ValidatedDynamicGeneratedProposal? {
		let title = cap(item.title, max: maxTitleLength) ?? ""
		let description = cap(item.description, max: maxDescriptionLength) ?? ""
		guard !title.isEmpty, !description.isEmpty else { return nil }

		if isGenericStaticParaphrase(title: title, description: description) {
			logSuppressed(reason: "generic_static_paraphrase", index: index)
			return nil
		}

		let confidence = clamp01(item.confidence)
		guard confidence >= minimumItemConfidence else {
			logSuppressed(reason: "low_confidence", index: index)
			return nil
		}

		let workflow = parseWorkflow(item.workflowType)
		let intent = parseIntent(item.intentType)
		let primitives = validatePrimitives(item.suggestedPrimitives)
		guard !primitives.isEmpty else {
			logSuppressed(reason: "unknown_primitives", index: index)
			return nil
		}

		let required = validateContextTypes(item.requiredContextTypes)
		let expected = cap(item.expectedOutcome, max: maxOutcomeLength) ?? description

		return ValidatedDynamicGeneratedProposal(
			id: UUID().uuidString,
			title: title,
			description: description,
			workflowType: workflow,
			intentType: intent,
			expectedOutcome: expected,
			requiredContextTypes: required,
			suggestedPrimitives: primitives,
			interruptionCost: clamp01(item.interruptionCost),
			confidence: confidence,
			usefulnessHint: "llm_dynamic"
		)
	}

	static func isGenericStaticParaphrase(title: String, description: String) -> Bool {
		let lower = (title + " " + description).lowercased()
		if genericBannedPhrases.contains(where: { lower.contains($0) }) { return true }
		let staticVerbs = ["summarize", "explain", "rewrite"]
		let hasVerb = staticVerbs.contains { lower.hasPrefix($0 + " ") || lower.contains(" \($0) ") }
		let hasGenericObject = lower.contains("selected text")
			|| lower.contains("clipboard")
			|| lower.contains("this text")
			|| lower.contains("screen text")
		return hasVerb && hasGenericObject
	}

	static func validatePrimitives(_ raw: [String]) -> [ExecutionPrimitive] {
		var out: [ExecutionPrimitive] = []
		for code in raw {
			let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			guard let primitive = ExecutionPrimitive(rawValue: trimmed) else { continue }
			if !out.contains(primitive) { out.append(primitive) }
		}
		return Array(out.prefix(GeneratedExecutionBounds.maxPrimitivesPerPlan))
	}

	private static func validateContextTypes(_ raw: [String]) -> [ContextRequirementType] {
		var out: [ContextRequirementType] = []
		for code in raw {
			let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
			guard let t = ContextRequirementType(rawValue: trimmed), t != .none else { continue }
			if !out.contains(t) { out.append(t) }
		}
		if out.isEmpty { out = [.textSnippet] }
		return out
	}

	private static func parseWorkflow(_ raw: String) -> WorkflowType {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if let wf = WorkflowType(rawValue: trimmed) { return wf }
		if let inferred = InferredWorkflow(rawValue: trimmed) {
			return WorkflowExecutionMapper.workflowType(from: inferred)
		}
		return .unknown
	}

	private static func parseIntent(_ raw: String) -> IntentType {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if let it = IntentType(rawValue: trimmed) { return it }
		if let syn = SynthesizedIntentType(rawValue: trimmed) {
			return WorkflowExecutionMapper.intentType(from: syn)
		}
		return .unknown
	}

	// MARK: - Utilities

	private static func extractJSONObject(from raw: String) -> String? {
		guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return nil }
		return String(raw[start...end])
	}

	private static func clamp01(_ value: Double) -> Double {
		min(1, max(0, value))
	}

	private static func cap(_ value: String, max: Int) -> String? {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		if trimmed.count <= max { return trimmed }
		return String(trimmed.prefix(max))
	}

	private static func logSuppressed(reason: String, index: Int) {
		print("[DynamicGeneratedProposal] proposal_suppressed_reason=\(reason) index=\(index)")
	}
}
