import Foundation

/// Validates and sanitizes LLM proposal JSON (T18.3.3C: tolerant extraction + repair pass).
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

	// MARK: - Public entry points

	/// Returns the result and, on hard failure (nil result), the exact `"diag:*"` tag to stamp in warnings.
	static func parseWithReason(
		from raw: String,
		referenceTime: Date = Date()
	) -> (result: DynamicGeneratedProposalResult?, hardFailTag: String?) {
		let result = parse(from: raw, referenceTime: referenceTime)
		if result == nil {
			// Distinguish: was there a JSON object at all?
			var aliasUsed = false
			let tag = extractJSONObject(from: raw, aliasUsed: &aliasUsed) != nil
				? "diag:parse_decode_failed"
				: "diag:parse_no_json"
			return (nil, tag)
		}
		return (result, nil)
	}

	static func parse(from raw: String, referenceTime: Date = Date()) -> DynamicGeneratedProposalResult? {
		let byteCount = raw.utf8.count
		let byteBucket = DynamicGeneratedProposalParserDiagnostics.byteBucket(byteCount)
		let responseHashHint = abs(raw.hashValue) % 100_000  // 5-digit non-reversible bucket

		// Step 1 — extract a JSON object from potentially wrapped/noisy output.
		var aliasUsed = false
		guard let json = extractJSONObject(from: raw, aliasUsed: &aliasUsed) else {
			logDiagnostics(DynamicGeneratedProposalParserDiagnostics(
				rawByteBucket: byteBucket,
				extractionSucceeded: false,
				missingRequiredKey: nil,
				unknownPrimitiveCount: 0,
				confidenceIssue: false,
				aliasNormalizationUsed: false,
				repairAttempted: false,
				repairSucceeded: false
			), responseHashHint: responseHashHint)
			return nil
		}

		guard let data = json.data(using: .utf8) else { return nil }

		// Step 2 — tolerant decode (handles compact + legacy key aliases, singular/plural proposal).
		var missingKey: String? = nil
		var unknownPrimitiveCount = 0
		var confidenceIssue = false
		var primitiveAliasUsed = false

		guard let decoded = try? JSONDecoder().decode(DynamicGeneratedProposalTolerantOutput.self, from: data) else {
			logDiagnostics(DynamicGeneratedProposalParserDiagnostics(
				rawByteBucket: byteBucket,
				extractionSucceeded: true,
				missingRequiredKey: "top_level_decode_failed",
				unknownPrimitiveCount: 0,
				confidenceIssue: false,
				aliasNormalizationUsed: aliasUsed,
				repairAttempted: false,
				repairSucceeded: false
			), responseHashHint: responseHashHint)
			return nil
		}

		let proposalConfidence = clamp01(decoded.resolvedProposalConfidence)
		let rawChimeIn = decoded.resolvedChimeIn
		let shouldChimeIn = rawChimeIn && proposalConfidence >= minimumChimeInConfidence

		var validated: [ValidatedDynamicGeneratedProposal] = []
		var warnings: [String] = []

		let items = decoded.resolvedItems

		// If chimeIn=true but no proposals provided, treat as weak signal (not a hard reject).
		if items.isEmpty && rawChimeIn {
			warnings.append("chime_true_no_proposals")
		}

		var anyGenericRejected = false

		for (index, item) in items.prefix(maxProposals).enumerated() {
			var itemMissingKey: String? = nil
			var itemUnknown = 0
			var itemConfidenceIssue = false
			var itemPrimitiveAlias = false
			var itemGenericRejected = false

			if let proposal = validateItem(
				item,
				index: index,
				referenceTime: referenceTime,
				missingKey: &itemMissingKey,
				unknownPrimitiveCount: &itemUnknown,
				confidenceIssue: &itemConfidenceIssue,
				primitiveAliasUsed: &itemPrimitiveAlias,
				genericRejected: &itemGenericRejected
			) {
				validated.append(proposal)
			} else {
				warnings.append("item_rejected_\(index)")
				if let k = itemMissingKey, missingKey == nil { missingKey = k }
				unknownPrimitiveCount += itemUnknown
				if itemConfidenceIssue { confidenceIssue = true }
				if itemPrimitiveAlias { primitiveAliasUsed = true }
				if itemGenericRejected { anyGenericRejected = true }
			}
			if itemPrimitiveAlias { primitiveAliasUsed = true }
		}

		// Stamp soft-failure diag tags so StatusBuilder can map to exact failure reasons.
		if !rawChimeIn {
			warnings.append("diag:parse_no_chime")
		} else if validated.isEmpty && !items.isEmpty {
			if anyGenericRejected {
				warnings.append("diag:parse_generic_rejected")
			} else if unknownPrimitiveCount > 0 {
				// Unknown-primitive rejection is more specific than a generic missing-key tag;
				// it takes priority so StatusBuilder maps to parseUnknownPrimitivesOnly rather
				// than parseMissingRequiredKey (which fires when missingKey=="primitives" for
				// the same root cause: all primitives were unknown and filtered out).
				warnings.append("diag:parse_unknown_primitives:\(unknownPrimitiveCount)")
			} else if let k = missingKey {
				warnings.append("diag:parse_missing_key:\(k)")
			} else if confidenceIssue {
				warnings.append("diag:parse_confidence_too_low")
			}
		}

		// Alias flag: either key aliases were used in extraction OR primitive aliases were resolved.
		let anyAliasUsed = aliasUsed || primitiveAliasUsed ||
			decoded.chime != nil ||    // compact "chime" key used instead of "shouldChimeIn"
			decoded.proposal != nil    // singular "proposal" key used instead of "proposals" array

		logDiagnostics(DynamicGeneratedProposalParserDiagnostics(
			rawByteBucket: byteBucket,
			extractionSucceeded: true,
			missingRequiredKey: missingKey,
			unknownPrimitiveCount: unknownPrimitiveCount,
			confidenceIssue: confidenceIssue,
			aliasNormalizationUsed: anyAliasUsed,
			repairAttempted: false,
			repairSucceeded: !validated.isEmpty
		), responseHashHint: responseHashHint)

		let effectiveChimeIn = shouldChimeIn && !validated.isEmpty

		return DynamicGeneratedProposalResult(
			status: .synthesized,
			shouldChimeIn: effectiveChimeIn,
			reason: cap(decoded.reason, max: 160) ?? "llm_synthesized",
			workflowAssessment: cap(decoded.workflowAssessment, max: 200) ?? "",
			proposalConfidence: proposalConfidence,
			requiresVisualContext: decoded.requiresVisualContext ?? false,
			proposals: validated,
			warnings: warnings,
			llmDiagnosticCause: nil,
			createdAt: referenceTime,
			contextSnapshot: nil,
			libraryRecords: [],
			hookContracts: []
		)
	}

	// MARK: - Item validation

	private static func validateItem(
		_ item: DynamicGeneratedProposalTolerantItem,
		index: Int,
		referenceTime: Date,
		missingKey: inout String?,
		unknownPrimitiveCount: inout Int,
		confidenceIssue: inout Bool,
		primitiveAliasUsed: inout Bool,
		genericRejected: inout Bool
	) -> ValidatedDynamicGeneratedProposal? {
		let title = cap(item.title, max: maxTitleLength) ?? ""
		let description = cap(item.description, max: maxDescriptionLength) ?? ""

		if title.isEmpty { missingKey = missingKey ?? "title"; return nil }
		if description.isEmpty { missingKey = missingKey ?? "description"; return nil }

		if isGenericStaticParaphrase(title: title, description: description) {
			genericRejected = true
			logSuppressed(reason: "generic_static_paraphrase", index: index)
			return nil
		}

		let rawConfidence = item.resolvedConfidence
		let confidence = clamp01(rawConfidence)
		if confidence < minimumItemConfidence {
			confidenceIssue = true
			logSuppressed(reason: "low_confidence(\(String(format: "%.2f", confidence)))", index: index)
			return nil
		}

		// Normalize and validate primitives (handles snake_case, camelCase, and known aliases).
		let rawPrimitives = item.resolvedPrimitives
		let (primitives, usedAlias, unknownCount) = normalizePrimitivesWithDiagnostics(rawPrimitives)
		unknownPrimitiveCount += unknownCount
		if usedAlias { primitiveAliasUsed = true }

		guard !primitives.isEmpty else {
			missingKey = missingKey ?? "primitives"
			logSuppressed(reason: "unknown_primitives(count=\(unknownCount))", index: index)
			return nil
		}

		let workflow = parseWorkflow(item.resolvedWorkflow)
		let intent = parseIntent(item.resolvedIntent)
		let required = validateContextTypes(item.requiredContextTypes ?? [])
		let expected = cap(item.resolvedOutcome, max: maxOutcomeLength) ?? description

		return ValidatedDynamicGeneratedProposal(
			id: UUID().uuidString,
			title: title,
			description: description,
			workflowType: workflow,
			intentType: intent,
			expectedOutcome: expected,
			requiredContextTypes: required,
			suggestedPrimitives: primitives,
			interruptionCost: clamp01(item.interruptionCost ?? 0.3),
			confidence: confidence,
			usefulnessHint: "llm_dynamic",
			agenticPlan: nil
		)
	}

	// MARK: - Generic paraphrase detection

	static func isGenericStaticParaphrase(title: String, description: String) -> Bool {
		let lower = (title + " " + description).lowercased()
		if genericBannedPhrases.contains(where: { lower.contains($0) }) { return true }
		let staticVerbs = ["summarize", "explain", "rewrite"]
		let hasVerb = staticVerbs.contains {
			lower.hasPrefix($0 + " ") || lower.contains(" \($0) ")
		}
		let hasGenericObject = lower.contains("selected text")
			|| lower.contains("clipboard")
			|| lower.contains("this text")
			|| lower.contains("screen text")
		return hasVerb && hasGenericObject
	}

	// MARK: - Primitive normalization (T18.3.3C: camelCase + alias mapping)

	/// Maps lower-cased, underscore-stripped forms of known primitive names to their rawValues.
	private static let primitiveAliasTable: [String: String] = {
		var table: [String: String] = [:]
		for p in ExecutionPrimitive.allCases {
			let raw = p.rawValue   // e.g. "answer_from_context"
			// Direct match (already snake_case)
			table[raw] = raw
			// No-underscore variant for camelCase lookup: "answerfromcontext"
			let noUnderscore = raw.replacingOccurrences(of: "_", with: "")
			table[noUnderscore] = raw
		}
		// Extra tolerance for common local-model camelCase output variants:
		table["answerfromcontext"] = "answer_from_context"
		table["classifyworkflow"] = "classify_workflow"
		table["extractactionitems"] = "extract_action_items"
		table["comparecontexts"] = "compare_contexts"
		table["summarizecontext"] = "summarize_context"
		table["generatechecklist"] = "generate_checklist"
		table["structurenotes"] = "structure_notes"
		table["explainerror"] = "explain_error"
		table["organizeinformation"] = "organize_information"
		table["generatestudynotes"] = "generate_study_notes"
		table["synthesizeresearchsummary"] = "synthesize_research_summary"
		return table
	}()

	static func normalizePrimitivesWithDiagnostics(
		_ raw: [String]
	) -> (primitives: [ExecutionPrimitive], aliasUsed: Bool, unknownCount: Int) {
		var out: [ExecutionPrimitive] = []
		var aliasUsed = false
		var unknownCount = 0

		for code in raw {
			let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
			let lower = trimmed.lowercased()
				.replacingOccurrences(of: "-", with: "_")
				.replacingOccurrences(of: " ", with: "_")

			// 1. Direct rawValue match (snake_case, already correct).
			if let primitive = ExecutionPrimitive(rawValue: lower) {
				if !out.contains(primitive) { out.append(primitive) }
				continue
			}

			// 2. Alias table lookup (camelCase → snake_case).
			let noUnderscore = lower.replacingOccurrences(of: "_", with: "")
			if let mapped = primitiveAliasTable[noUnderscore] ?? primitiveAliasTable[lower],
			   let primitive = ExecutionPrimitive(rawValue: mapped)
			{
				aliasUsed = true
				if !out.contains(primitive) { out.append(primitive) }
				continue
			}

			unknownCount += 1
		}

		return (Array(out.prefix(GeneratedExecutionBounds.maxPrimitivesPerPlan)), aliasUsed, unknownCount)
	}

	// MARK: - Public primitive validation (used by existing self-tests)

	static func validatePrimitives(_ raw: [String]) -> [ExecutionPrimitive] {
		normalizePrimitivesWithDiagnostics(raw).primitives
	}

	// MARK: - JSON extraction (T18.3.3C: fence stripping + brace-depth scanner)

	/// Tries markdown fence extraction first, then brace-depth scan on the raw string.
	private static func extractJSONObject(from raw: String, aliasUsed: inout Bool) -> String? {
		// 1. Try to extract content from a markdown code fence.
		if let fenced = extractFromCodeFence(raw) {
			aliasUsed = true
			if let obj = extractBracedObject(from: fenced) { return obj }
			// If the fenced content itself is valid JSON without outer braces, wrap and try.
			if let obj = extractBracedObject(from: raw) { return obj }
		}
		// 2. Brace-depth scan on the raw string.
		return extractBracedObject(from: raw)
	}

	/// Strips one level of ``` (optionally followed by "json") fences and returns interior content.
	private static func extractFromCodeFence(_ s: String) -> String? {
		let lines = s.components(separatedBy: "\n")
		var inFence = false
		var fenceLines: [String] = []
		for line in lines {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") {
				if inFence { break }
				inFence = true
				continue
			}
			if inFence { fenceLines.append(line) }
		}
		guard !fenceLines.isEmpty else { return nil }
		return fenceLines.joined(separator: "\n")
	}

	/// Walks the string tracking brace depth and string literal state to locate the first complete `{...}` object.
	private static func extractBracedObject(from s: String) -> String? {
		guard let startIdx = s.firstIndex(of: "{") else { return nil }
		var depth = 0
		var inString = false
		var escaped = false
		var idx = startIdx

		while idx < s.endIndex {
			let c = s[idx]
			if escaped {
				escaped = false
			} else if c == "\\" && inString {
				escaped = true
			} else if c == "\"" {
				inString.toggle()
			} else if !inString {
				if c == "{" { depth += 1 }
				else if c == "}" {
					depth -= 1
					if depth == 0 { return String(s[startIdx...idx]) }
				}
			}
			idx = s.index(after: idx)
		}

		// Unbalanced braces — fall back to first-`{` / last-`}` slice.
		guard let end = s.lastIndex(of: "}"), startIdx <= end else { return nil }
		return String(s[startIdx...end])
	}

	// MARK: - Context type / workflow / intent helpers

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
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if let wf = WorkflowType(rawValue: trimmed) { return wf }
		if let inferred = InferredWorkflow(rawValue: trimmed) {
			return WorkflowExecutionMapper.workflowType(from: inferred)
		}
		return .unknown
	}

	private static func parseIntent(_ raw: String) -> IntentType {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if let it = IntentType(rawValue: trimmed) { return it }
		if let syn = SynthesizedIntentType(rawValue: trimmed) {
			return WorkflowExecutionMapper.intentType(from: syn)
		}
		return .unknown
	}

	// MARK: - Diagnostics logging (metadata-only; no raw LLM text)

	private static func logDiagnostics(
		_ d: DynamicGeneratedProposalParserDiagnostics,
		responseHashHint: Int
	) {
		var parts: [String] = [
			"bytes=\(d.rawByteBucket)",
			"extracted=\(d.extractionSucceeded ? 1 : 0)",
			"alias=\(d.aliasNormalizationUsed ? 1 : 0)",
			"unknown_primitives=\(d.unknownPrimitiveCount)",
			"confidence_issue=\(d.confidenceIssue ? 1 : 0)",
			"hash_hint=\(responseHashHint)",
		]
		if let k = d.missingRequiredKey { parts.append("missing_key=\(k)") }
		if d.repairAttempted { parts.append("repair=\(d.repairSucceeded ? "ok" : "fail")") }
		print("[DynamicGeneratedProposal] parser_diag \(parts.joined(separator: " "))")
	}

	private static func logSuppressed(reason: String, index: Int) {
		print("[DynamicGeneratedProposal] proposal_suppressed reason=\(reason) index=\(index)")
	}

	// MARK: - Utilities

	private static func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }

	private static func cap(_ value: String?, max: Int) -> String? {
		guard let value else { return nil }
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		return trimmed.count <= max ? trimmed : String(trimmed.prefix(max))
	}
}
