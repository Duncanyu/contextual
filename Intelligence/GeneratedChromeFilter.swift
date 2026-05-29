import Foundation

// MARK: - Result

/// Outcome of a `GeneratedChromeFilter.filter(...)` pass.
struct GeneratedChromeFilterResult: Sendable, Equatable {
	let filteredText: String
	let suppressedLineCount: Int
	let suppressedReasons: [String]
}

// MARK: - Filter

/// Phase 4N — Generated chrome suppression.
///
/// `AssistantChromeFilter` already drops a fixed set of assistant-panel
/// labels ("Open", "Execute", "Runtime Phase", …). `GeneratedChromeFilter`
/// extends that to **dynamic** chrome: text leaks that mirror the assistant's
/// own *current* runtime goal / proposal title back into the OCR pipeline
/// (which then made them look like primary grounded targets).
///
/// Symptoms it fixes (latest dogfood):
///   `Processing Search Firefox History...`
///   `Search Firefox History...`
///   `History for 'Anker Laptop Chargerl?`
///   (generated goal/title echoes from assistant UI)
///
/// The filter is stateless and deterministic. It accepts a `runtimeGoal` and
/// an optional `proposalTitle` so it can suppress whatever the assistant is
/// currently saying about itself, instead of relying on a hand-maintained
/// needle list per goal.
enum GeneratedChromeFilter {

	// MARK: - Grounding Support

	/// Evidence sources that can corroborate that a line is real page content
	/// (and not an assistant UI echo captured by OCR).
	///
	/// Phase 4R: When text overlaps the proposal title / runtime goal, we only
	/// suppress it if it lacks grounding support. This prevents real page titles
	/// (e.g. product headings) from being mistaken for "generated chrome".
	struct GroundingSupport: Sendable, Equatable {
		let windowTitle: String?
		let axText: String?
		let groundedNodeTexts: [String]
		let semanticTexts: [String]

		init(
			windowTitle: String? = nil,
			axText: String? = nil,
			groundedNodeTexts: [String] = [],
			semanticTexts: [String] = []
		) {
			self.windowTitle = windowTitle
			self.axText = axText
			self.groundedNodeTexts = groundedNodeTexts
			self.semanticTexts = semanticTexts
		}
	}

	/// Generic assistant runtime chrome that always indicates an internal label,
	/// regardless of the current goal.
	private static let staticChromeNeedles: [String] = [
		"generated execution", "runtime phase", "actions taken",
		"controlled interactions", "contextual assistance",
		"execution result", "prepare execution",
	]

	/// Exact-match single-token labels that come from generated UI buttons.
	/// Matched on the trimmed lowercased line in its entirety, not as substring.
	private static let exactSingleTokenChrome: Set<String> = [
		"open", "execute", "executing", "processing", "generated",
	]

	// MARK: - Per-line check

	/// Returns `(true, reason)` when the line should be suppressed.
	///
	/// `runtimeGoal` is the agentic plan goal currently in flight. `proposalTitle`
	/// is the surface text the user clicked (e.g. a generated proposal title).
	/// Either may be nil; the filter still applies its static checks.
	static func shouldSuppress(
		line: String,
		runtimeGoal: String?,
		proposalTitle: String? = nil,
		groundingSupport: GroundingSupport? = nil
	) -> (suppressed: Bool, reason: String?) {
		let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return (false, nil) }
		let lower = trimmed.lowercased()

		// Exact single-token UI labels.
		if exactSingleTokenChrome.contains(lower) {
			return (true, "single_token_assistant_chrome")
		}

		// Static assistant chrome phrases.
		for needle in staticChromeNeedles where lower.contains(needle) {
			return (true, "assistant_runtime_chrome")
		}

		// Exact dynamic goal/proposal title echo check (bypasses grounding preservation).
		if let goalLower = runtimeGoal?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
		   !goalLower.isEmpty,
		   lower == goalLower {
			print("[GeneratedChromeFilter] suppressed=\"\(line)\" reason=runtime_goal_echo_exact")
			return (true, "runtime_goal_echo_exact")
		}
		if let titleLower = proposalTitle?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
		   !titleLower.isEmpty,
		   lower == titleLower {
			print("[GeneratedChromeFilter] suppressed=\"\(line)\" reason=runtime_goal_echo_exact")
			return (true, "runtime_goal_echo_exact")
		}

		// Dynamic: "Processing <goal>" / "Processing <title>".
		if lower.hasPrefix("processing ") {
			let rest = String(lower.dropFirst("processing ".count))
				.trimmingCharacters(in: .whitespacesAndNewlines)
			if rest.isEmpty || rest == "..." {
				return (true, "processing_generic")
			}
			if let goalLower = runtimeGoal?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
			   !goalLower.isEmpty,
			   substringOverlap(rest, goalLower) {
				return (true, "processing_current_goal")
			}
			if let titleLower = proposalTitle?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
			   !titleLower.isEmpty,
			   substringOverlap(rest, titleLower) {
				return (true, "processing_current_title")
			}
			// Phase 4O: "Processing <verb …>" where <verb> is one of the goal
			// action verbs (compare / review / summarize / analyze / extract …)
			// AND the goal exists is treated as a generated echo even when the
			// noun phrase has been truncated by the panel (e.g. "Processing
			// Compare Anker" while goal is "Compare Anker Laptop Chargers").
			if let goalLower = runtimeGoal?.lowercased() {
				if shareLeadingActionVerb(rest, goalLower) {
					return (true, "processing_goal_echo")
				}
			}
			if let titleLower = proposalTitle?.lowercased() {
				if shareLeadingActionVerb(rest, titleLower) {
					return (true, "processing_title_echo")
				}
			}
		}

		// Exact or near-exact match of the current goal / proposal title.
		if let goalLower = runtimeGoal?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
		   !goalLower.isEmpty {
			// Phase 4U — Suppress imperative action-phrase echoes even when the noun
			// phrase has diverged from the goal due to planner repair (e.g. the OCR
			// captured "Extract Product Details from …" while the aligned goal is
			// "Extract useful product evidence …").
			if looksLikeAssistantActionEcho(lower) && shareLeadingActionVerb(lower, goalLower) {
				if let support = groundingSupport, let sources = groundedSources(for: trimmed, support: support) {
					print("[GeneratedChromeFilter] preserved_grounded_text=yes text=\"\(trimmed.prefix(80))\" sources=\(sources.joined(separator: ","))")
					return (false, nil)
				}
				print("[GeneratedChromeFilter] suppressed=\"\(line)\" reason=proposal_action_echo ungrounded=yes")
				return (true, "proposal_action_echo")
			}
			if lower == goalLower || (lower.contains(goalLower) && lower.count - goalLower.count <= 12) {
				if let support = groundingSupport, let sources = groundedSources(for: trimmed, support: support) {
					print("[GeneratedChromeFilter] preserved_grounded_text=yes text=\"\(trimmed.prefix(80))\" sources=\(sources.joined(separator: ","))")
					return (false, nil)
				}
				return (true, "matches_current_goal")
			}
			if (goalLower.contains(lower) && lower.count >= 8) || (lower.hasPrefix(goalLower) && goalLower.count >= 8) || (goalLower.hasPrefix(lower) && lower.count >= 8) {
				if let support = groundingSupport, let sources = groundedSources(for: trimmed, support: support) {
					print("[GeneratedChromeFilter] preserved_grounded_text=yes text=\"\(trimmed.prefix(80))\" sources=\(sources.joined(separator: ","))")
					return (false, nil)
				}
				print("[GeneratedChromeFilter] suppressed=\"\(line)\" reason=proposal_action_echo ungrounded=yes")
				return (true, "proposal_action_echo")
			}
			if lower.hasPrefix("search for ") {
				let rest = String(lower.dropFirst("search for ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
				if (goalLower.contains(rest) && rest.count >= 6) || (rest.contains(goalLower) && goalLower.count >= 6) {
					if let support = groundingSupport, let sources = groundedSources(for: trimmed, support: support) {
						print("[GeneratedChromeFilter] preserved_grounded_text=yes text=\"\(trimmed.prefix(80))\" sources=\(sources.joined(separator: ","))")
						return (false, nil)
					}
					print("[GeneratedChromeFilter] suppressed=\"\(line)\" reason=proposal_action_echo ungrounded=yes")
					return (true, "proposal_action_echo")
				}
			}
		}
		if let titleLower = proposalTitle?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
		   !titleLower.isEmpty {
			if looksLikeAssistantActionEcho(lower) && shareLeadingActionVerb(lower, titleLower) {
				if let support = groundingSupport, let sources = groundedSources(for: trimmed, support: support) {
					print("[GeneratedChromeFilter] preserved_grounded_text=yes text=\"\(trimmed.prefix(80))\" sources=\(sources.joined(separator: ","))")
					return (false, nil)
				}
				print("[GeneratedChromeFilter] suppressed=\"\(line)\" reason=proposal_action_echo ungrounded=yes")
				return (true, "proposal_action_echo")
			}
			if lower == titleLower || (lower.contains(titleLower) && lower.count - titleLower.count <= 12) {
				if let support = groundingSupport, let sources = groundedSources(for: trimmed, support: support) {
					print("[GeneratedChromeFilter] preserved_grounded_text=yes text=\"\(trimmed.prefix(80))\" sources=\(sources.joined(separator: ","))")
					return (false, nil)
				}
				return (true, "matches_current_title")
			}
			if (titleLower.contains(lower) && lower.count >= 8) || (lower.hasPrefix(titleLower) && titleLower.count >= 8) || (titleLower.hasPrefix(lower) && lower.count >= 8) {
				if let support = groundingSupport, let sources = groundedSources(for: trimmed, support: support) {
					print("[GeneratedChromeFilter] preserved_grounded_text=yes text=\"\(trimmed.prefix(80))\" sources=\(sources.joined(separator: ","))")
					return (false, nil)
				}
				print("[GeneratedChromeFilter] suppressed=\"\(line)\" reason=proposal_action_echo ungrounded=yes")
				return (true, "proposal_action_echo")
			}
			if lower.hasPrefix("search for ") {
				let rest = String(lower.dropFirst("search for ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
				if (titleLower.contains(rest) && rest.count >= 6) || (rest.contains(titleLower) && titleLower.count >= 6) {
					if let support = groundingSupport, let sources = groundedSources(for: trimmed, support: support) {
						print("[GeneratedChromeFilter] preserved_grounded_text=yes text=\"\(trimmed.prefix(80))\" sources=\(sources.joined(separator: ","))")
						return (false, nil)
					}
					print("[GeneratedChromeFilter] suppressed=\"\(line)\" reason=proposal_action_echo ungrounded=yes")
					return (true, "proposal_action_echo")
				}
			}
		}

		return (false, nil)
	}

	// MARK: - Whole-text filter

	/// Run the suppression rule across a multi-line OCR excerpt.
	static func filter(
		text: String,
		runtimeGoal: String?,
		proposalTitle: String? = nil,
		groundingSupport: GroundingSupport? = nil
	) -> GeneratedChromeFilterResult {
		if text.isEmpty {
			return GeneratedChromeFilterResult(
				filteredText: "",
				suppressedLineCount: 0,
				suppressedReasons: []
			)
		}
		let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		var kept: [String] = []
		kept.reserveCapacity(lines.count)
		var suppressedCount = 0
		var reasons: [String] = []

		for line in lines {
			let result = shouldSuppress(
				line: line,
				runtimeGoal: runtimeGoal,
				proposalTitle: proposalTitle,
				groundingSupport: groundingSupport
			)
			if result.suppressed {
				suppressedCount += 1
				if let r = result.reason { reasons.append(r) }
			} else {
				kept.append(line)
			}
		}

		let filtered = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		return GeneratedChromeFilterResult(
			filteredText: filtered,
			suppressedLineCount: suppressedCount,
			suppressedReasons: reasons
		)
	}

	// MARK: - Internals

	/// True when `candidate` and `target` overlap substantially enough that we
	/// should treat them as the same string (either direction).
	private static func substringOverlap(_ candidate: String, _ target: String) -> Bool {
		if candidate == target { return true }
		if candidate.contains(target) { return true }
		if target.contains(candidate) && candidate.count >= max(8, target.count / 2) {
			return true
		}
		return false
	}

	/// Action verbs the planner uses to title fast shells and refinements.
	/// A truncated panel echo like "Processing Compare Anker" matches the goal
	/// "Compare Anker Laptop Chargers" through this verb alone.
	private static let goalActionVerbs: Set<String> = [
		"compare", "review", "summarize", "summarise", "analyze", "analyse",
		"extract", "describe", "explain", "search", "find", "open",
	]

	/// True when both strings start with the same goal-action verb. Catches
	/// generated chrome echoes where the panel truncates the noun phrase.
	private static func shareLeadingActionVerb(_ a: String, _ b: String) -> Bool {
		guard let aFirst = leadingToken(a), let bFirst = leadingToken(b) else {
			return false
		}
		if aFirst != bFirst { return false }
		return goalActionVerbs.contains(aFirst)
	}

	private static func leadingToken(_ s: String) -> String? {
		let tokens = s.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		return tokens.first
	}

	/// Heuristic: true when the line reads like an assistant-generated action
	/// label (imperative verb + generic object phrase).
	///
	/// This does NOT use website-specific vocabulary.
	private static func looksLikeAssistantActionEcho(_ lower: String) -> Bool {
		guard let first = leadingToken(lower) else { return false }
		guard goalActionVerbs.contains(first) else { return false }
		let tokens = lower.split(separator: " ").map(String.init)
		guard tokens.count >= 3 else { return false }
		let genericObjects: Set<String> = [
			"product", "details", "context", "page", "screen", "visible",
			"information", "content", "workflow", "results",
		]
		let hasGenericObject = tokens.dropFirst().contains { genericObjects.contains($0) }
		// Require at least one generic object token (prevents suppressing real page
		// text that happens to start with e.g. "extract" but isn't an action label).
		return hasGenericObject
	}

	// MARK: - Grounding helpers

	private static func groundedSources(for line: String, support: GroundingSupport) -> [String]? {
		let needle = normalizeComparable(line)
		guard needle.count >= 6 else { return nil }

		var sources: [String] = []

		if let t = support.windowTitle, !t.isEmpty {
			let hay = normalizeComparable(t)
			if substringOverlap(needle, hay) || substringOverlap(hay, needle) {
				sources.append("window_title")
			}
		}
		if let ax = support.axText, !ax.isEmpty {
			let hay = normalizeComparable(ax)
			if hay.contains(needle) || needle.contains(hay) {
				sources.append("ax")
			}
		}
		for n in support.groundedNodeTexts {
			let hay = normalizeComparable(n)
			if hay.contains(needle) || needle.contains(hay) {
				sources.append("screen_graph")
				break
			}
		}
		for s in support.semanticTexts {
			let hay = normalizeComparable(s)
			if hay.contains(needle) || needle.contains(hay) {
				sources.append("semantic")
				break
			}
		}

		guard !sources.isEmpty else { return nil }
		// Note: when this function is used while filtering OCR, "ocr" is also a
		// grounding source (the line literally came from OCR). Include it for
		// clearer logs.
		if !sources.contains("ocr") { sources.append("ocr") }
		return sources
	}

	private static func normalizeComparable(_ s: String) -> String {
		s.lowercased()
			.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
