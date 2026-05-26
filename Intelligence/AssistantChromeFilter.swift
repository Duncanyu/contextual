import Foundation

/// Safety fallback for Phase 4J: suppress assistant UI chrome from OCR when executing against a
/// non-assistant target anchor. This is not the primary solution (target anchoring is), but it
/// prevents obvious assistant-panel strings from polluting grounding/extraction.
enum AssistantChromeFilter {

	struct Result: Equatable, Sendable {
		let filteredText: String
		let suppressedLineCount: Int
		let totalLineCount: Int
	}

	static func filterOCR(
		_ text: String,
		targetBundleIdentifier: String?,
		assistantBundleIdentifier: String? = Bundle.main.bundleIdentifier
	) -> Result {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return Result(filteredText: "", suppressedLineCount: 0, totalLineCount: 0) }

		// Only filter when the execution target is NOT the assistant itself.
		if let targetBundleIdentifier,
		   let assistantBundleIdentifier,
		   targetBundleIdentifier == assistantBundleIdentifier {
			return Result(
				filteredText: trimmed,
				suppressedLineCount: 0,
				totalLineCount: trimmed.split(separator: "\n").count
			)
		}

		let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		var kept: [String] = []
		kept.reserveCapacity(lines.count)

		var suppressed = 0
		for line in lines {
			let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if l.isEmpty {
				kept.append(line)
				continue
			}
			if isAssistantChromeLine(l) {
				suppressed += 1
				continue
			}
			kept.append(line)
		}

		let filtered = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		return Result(filteredText: filtered, suppressedLineCount: suppressed, totalLineCount: lines.count)
	}

	private static func isAssistantChromeLine(_ line: String) -> Bool {
		let lowered = line.lowercased().trimmingCharacters(in: .whitespaces)
		// Phase 4M: drop lines that are *only* assistant button labels (single-token).
		// These slipped through previously because the substring match treats them
		// as legitimate page words ("Open", "Execute").
		let exactSingleTokens: Set<String> = [
			"open",
			"execute",
			"executing",
			"processing",
		]
		if exactSingleTokens.contains(lowered) { return true }

		let needles: [String] = [
			"contextual assistance",
			"generated execution",
			"runtime phase",
			"actions taken",
			"controlled interactions",
			// Assistant-panel text sometimes leaks into OCR when the assistant window
			// is foregrounded during execution.
			"processing review",
			"processing update product information",
			"update product information",
			"want me to",
			"run hook sandbox",
			"hook sandbox",
			"debug context",
			"prepare execution",
			"execution result",
		]
		return needles.contains { lowered.contains($0) }
	}
}
