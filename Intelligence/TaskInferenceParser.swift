import Foundation

enum TaskInferenceParser {
	static func parseWithFailure(
		from raw: String,
		referenceTime: Date = Date()
	) -> (result: TaskInferenceResult?, failure: TaskInferenceParseFailure?) {
		var usedFence = false
		guard let json = extractJSONObject(from: raw, usedFence: &usedFence) else {
			return (nil, .parseNoJSONObject)
		}

		// Always repair first — strips schema-annotated keys ("c(0/1)" → "c"), trailing commas,
		// single quotes. For already-clean JSON this is a no-op.
		// Skipping repair caused schema-annotated keys to silently decode as all-nil (JSONDecoder
		// ignores unknown keys), producing a c=0 / confidence=0 result instead of the intended values.
		let repaired = repairJSON(json)

		// Pass 1: JSONDecoder — fast; works for clean + repaired output.
		if let decoded = tryJSONDecoder(repaired) {
			return buildResult(from: decoded, referenceTime: referenceTime)
		}

		// Pass 2: AnyCast fallback — handles type coercion JSONDecoder rejects:
		//   "c": true (Bool where Int expected)
		//   "p": "0.85" (String where Double expected)
		//   "h": "hook1,hook2" (String where [String] expected)
		if let decoded = decodeViaAnyCast(repaired) {
			return buildResult(from: decoded, referenceTime: referenceTime)
		}

		return (nil, .parseMalformedJSON)
	}

	// MARK: - Build result from tolerant output

	private static func buildResult(
		from decoded: TaskInferenceTolerantOutput,
		referenceTime: Date
	) -> (result: TaskInferenceResult?, failure: TaskInferenceParseFailure?) {
		let shouldChime = decoded.resolvedShouldChime
		let confidence = clamp01(decoded.resolvedConfidence)
		if shouldChime && confidence <= 0 {
			return (nil, .parseMissingRequiredKey)
		}

		let caps = decoded.resolvedCapabilities
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		var seen: Set<String> = []
		let uniqueCaps = caps.filter { seen.insert($0).inserted }

		let expiry = max(6, min(60, decoded.resolvedExpirySeconds))

		// Context escalation: parse need[] and needReason.
		// Allowed need values (validated set — unknown values are silently dropped).
		let allowedNeedValues: Set<String> = [
			"visible_ocr", "ax_window_text", "browser_text",
			"selected_text", "clipboard_if_relevant", "recent_titles", "visual_descriptor"
		]
		let rawNeed = decoded.resolvedNeed
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { allowedNeedValues.contains($0) }

		let result = TaskInferenceResult(
			shouldChime: shouldChime,
			possibleUserGoal: decoded.resolvedGoal,
			confidence: confidence,
			inferredTaskType: decoded.resolvedTaskType,
			evidenceSummary: decoded.resolvedEvidence,
			neededCapabilities: uniqueCaps,
			suggestedActionVerb: decoded.resolvedVerb,
			suggestedObject: decoded.resolvedObject,
			userFacingQuestion: decoded.resolvedUserFacingQuestion,
			whyNow: decoded.resolvedWhyNow,
			interruptionRisk: clamp01(decoded.resolvedRisk),
			missingContext: decoded.resolvedMissing,
			expirySeconds: expiry,
			createdAt: referenceTime,
			need: rawNeed,
			needReason: decoded.resolvedNeedReason
		)
		return (result, nil)
	}

	// MARK: - JSON extraction (tolerant; no raw logging)

	private static func extractJSONObject(from raw: String, usedFence: inout Bool) -> String? {
		if let fenced = extractFromCodeFence(raw) {
			usedFence = true
			if let braced = extractBracedObject(from: fenced) { return braced }
			return fenced
		}
		return extractBracedObject(from: raw)
	}

	private static func extractFromCodeFence(_ s: String) -> String? {
		let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
		var inFence = false
		var collected: [Substring] = []
		for line in lines {
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.hasPrefix("```") {
				inFence.toggle()
				continue
			}
			if inFence {
				collected.append(line)
			}
		}
		if collected.isEmpty { return nil }
		return collected.joined(separator: "\n")
	}

	private static func extractBracedObject(from s: String) -> String? {
		var depth = 0
		var startIndex: String.Index?
		var inString = false
		var escape = false

		for idx in s.indices {
			let ch = s[idx]
			if escape {
				escape = false
				continue
			}
			if ch == "\\" && inString {
				escape = true
				continue
			}
			if ch == "\"" {
				inString.toggle()
				continue
			}
			if inString { continue }

			if ch == "{" {
				if depth == 0 { startIndex = idx }
				depth += 1
				continue
			}
			if ch == "}" {
				guard depth > 0 else { continue }
				depth -= 1
				if depth == 0, let startIndex {
					let end = s.index(after: idx)
					return String(s[startIndex..<end])
				}
			}
		}
		return nil
	}

	// MARK: - Pass 1: JSONDecoder

	private static func tryJSONDecoder(_ json: String) -> TaskInferenceTolerantOutput? {
		guard let data = json.data(using: .utf8) else { return nil }
		return try? JSONDecoder().decode(TaskInferenceTolerantOutput.self, from: data)
	}

	// MARK: - Pass 2: Structural repair

	/// Fixes common structural issues that prevent JSONDecoder from parsing.
	/// Does NOT fix type mismatches (Bool/Int, String/Double) — that's handled by Pass 3.
	static func repairJSON(_ s: String) -> String {
		var r = s

		// Strip schema annotations from keys: "c(0/1)": → "c":
		// Handles "c(chime 0/1)", "g(goal)", "p(conf 0-1)", etc.
		r = r.replacingOccurrences(
			of: #""(\w+)\([^)"]*\)"\s*:"#,
			with: "\"$1\":",
			options: .regularExpression
		)

		// Remove // line comments (best-effort — may break strings containing "//")
		r = r.replacingOccurrences(of: #"//[^\n\r]*"#, with: "", options: .regularExpression)

		// Remove trailing commas before } or ]
		r = r.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)

		// Single → double quotes: only apply when the string looks uniformly single-quoted.
		// Heuristic: fewer than 2 double quotes AND at least 2 single quotes present.
		let doubleCount = r.filter { $0 == "\"" }.count
		let singleCount = r.filter { $0 == "'" }.count
		if doubleCount < 2 && singleCount >= 2 {
			r = r.replacingOccurrences(of: "'", with: "\"")
		}

		return r
	}

	// MARK: - Pass 3: AnyCast fallback with full type coercion

	/// Parses JSON using JSONSerialization (permissive), then manually coerces each field.
	/// Handles the type mismatches that JSONDecoder rejects:
	///   - "c": true  (Bool where Int expected)
	///   - "p": "0.85"  (String where Double expected)
	///   - "h": "hook1,hook2"  (String where [String] expected)
	///   - "c": 1  (Int where Bool might be expected for shouldChime)
	private static func decodeViaAnyCast(_ json: String) -> TaskInferenceTolerantOutput? {
		guard let data = json.data(using: .utf8),
			  let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
		else { return nil }

		func asBool(_ key: String) -> Bool? {
			guard let v = raw[key] else { return nil }
			if let b = v as? Bool { return b }
			if let i = v as? Int { return i != 0 }
			if let d = v as? Double { return d != 0 }
			if let s = v as? String {
				let l = s.lowercased().trimmingCharacters(in: .whitespaces)
				if l == "true" || l == "1" || l == "yes" { return true }
				if l == "false" || l == "0" || l == "no" { return false }
			}
			return nil
		}

		func asInt(_ key: String) -> Int? {
			guard let v = raw[key] else { return nil }
			if let i = v as? Int { return i }
			if let b = v as? Bool { return b ? 1 : 0 }
			if let d = v as? Double { return Int(d) }
			if let s = v as? String { return Int(s) ?? (Double(s).map { Int($0) } ?? nil) }
			return nil
		}

		func asDouble(_ key: String) -> Double? {
			guard let v = raw[key] else { return nil }
			if let d = v as? Double { return d }
			if let i = v as? Int { return Double(i) }
			if let b = v as? Bool { return b ? 1.0 : 0.0 }
			if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
			return nil
		}

		func asString(_ key: String) -> String? {
			guard let v = raw[key] else { return nil }
			if let s = v as? String { return s }
			return nil
		}

		func asStringArray(_ key: String) -> [String]? {
			guard let v = raw[key] else { return nil }
			if let arr = v as? [String] { return arr }
			if let arr = v as? [Any] { return arr.compactMap { $0 as? String } }
			if let s = v as? String {
				// Comma-separated string → array
				let items = s.split(separator: ",")
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
					.filter { !$0.isEmpty }
				return items.isEmpty ? nil : items
			}
			return nil
		}

		return TaskInferenceTolerantOutput(
			shouldChime: asBool("shouldChime"),
			shouldChimeIn: asBool("shouldChimeIn"),
			c: asInt("c"),
			possibleUserGoal: asString("possibleUserGoal"),
			goal: asString("goal"),
			g: asString("g"),
			confidence: asDouble("confidence"),
			conf: asDouble("conf"),
			p: asDouble("p"),
			inferredTaskType: asString("inferredTaskType"),
			taskType: asString("taskType"),
			task: asString("task"),
			evidenceSummary: asString("evidenceSummary"),
			evidence: asString("evidence"),
			neededCapabilities: asStringArray("neededCapabilities"),
			capabilities: asStringArray("capabilities"),
			caps: asStringArray("caps"),
			h: asStringArray("h"),
			suggestedActionVerb: asString("suggestedActionVerb"),
			verb: asString("verb"),
			a: asString("a"),
			suggestedObject: asString("suggestedObject"),
			object: asString("object"),
			obj: asString("obj"),
			o: asString("o"),
			userFacingQuestion: asString("userFacingQuestion"),
			question: asString("question"),
			q: asString("q"),
			whyNow: asString("whyNow"),
			why: asString("why"),
			interruptionRisk: asDouble("interruptionRisk"),
			risk: asDouble("risk"),
			missingContext: asStringArray("missingContext"),
			missing: asStringArray("missing"),
			expirySeconds: asDouble("expirySeconds"),
			expiry: asDouble("expiry"),
			need: asStringArray("need"),
			needReason: asString("needReason")
		)
	}

	// MARK: - Helpers

	private static func clamp01(_ d: Double) -> Double {
		if d.isNaN { return 0 }
		return max(0, min(1, d))
	}
}
