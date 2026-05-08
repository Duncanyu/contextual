import Foundation

struct ActionRelevanceScore: Equatable, Sendable {
	let actionId: String
	let score: Double
	let reason: String
}

enum ActionRelevanceScorer {
	/// Scores candidates (0.0–1.0) and returns sorted descending by score.
	static func scoreActions(
		candidateActionIds: [String],
		contextType: ContextType,
		features: ContextFeatures
	) -> [ActionRelevanceScore] {
		let unique = Array(LinkedHashSet(candidateActionIds))
		var out: [ActionRelevanceScore] = []
		out.reserveCapacity(unique.count)

		for id in unique {
			switch id {
			case "summarize_text":
				out.append(scoreSummarize(type: contextType, f: features))
			case "explain_text":
				out.append(scoreExplain(type: contextType, f: features))
			case "rewrite_text":
				out.append(scoreRewrite(type: contextType, f: features))
			default:
				out.append(ActionRelevanceScore(actionId: id, score: 0.50, reason: "default"))
			}
		}

		return out.sorted { a, b in
			if a.score != b.score { return a.score > b.score }
			return a.actionId < b.actionId
		}
	}

	private static func scoreSummarize(type: ContextType, f: ContextFeatures) -> ActionRelevanceScore {
		var score: Double
		var reason = "generic"

		if type == .article {
			score = 0.92
			reason = "article"
		} else if type == .notes {
			if f.textLength >= 220 {
				score = 0.90
				reason = "notes_long"
			} else {
				score = 0.86
				reason = "notes"
			}
		} else if f.textLength >= 200, f.sentenceCount >= 3, f.lineCount >= 3 {
			score = 0.80
			reason = "long_structured"
		} else if type == .question || type == .errorLog {
			score = 0.35
			reason = "question_or_log"
		} else if f.textLength < 80 {
			score = 0.30
			reason = "too_short"
		} else {
			score = 0.55
			reason = "medium"
		}

		return ActionRelevanceScore(actionId: "summarize_text", score: score, reason: reason)
	}

	private static func scoreExplain(type: ContextType, f: ContextFeatures) -> ActionRelevanceScore {
		var score: Double
		var reason = "generic"

		if type == .errorLog || f.isLikelyLog {
			score = 0.95
			reason = "error_log"
		} else if type == .code || f.isLikelyCode {
			score = 0.90
			reason = "code"
		} else if type == .question || f.hasQuestion {
			score = 0.85
			reason = "question"
		} else if type == .article || type == .notes {
			score = 0.55
			reason = "article_or_notes"
		} else if type == .random {
			score = 0.20
			reason = "random"
		} else {
			score = 0.50
			reason = "medium"
		}

		return ActionRelevanceScore(actionId: "explain_text", score: score, reason: reason)
	}

	private static func scoreRewrite(type: ContextType, f: ContextFeatures) -> ActionRelevanceScore {
		var score: Double
		var reason = "generic"

		let proseLike = !f.isLikelyCode && !f.isLikelyLog
		if !proseLike || type == .code || type == .errorLog || type == .random {
			score = 0.20
			reason = "not_prose"
		} else if type == .article || type == .notes, f.textLength >= 320 {
			// Long notes/articles: prefer summarize over rewrite unless it’s clearly a short draft.
			score = 0.45
			reason = "long_prose_draft_unlikely"
		} else if f.textLength >= 80, f.textLength <= 500, f.sentenceCount >= 1 {
			score = 0.70
			reason = "medium_prose"
		} else if type == .notes || type == .article {
			score = 0.55
			reason = "notes_or_article"
		} else if type == .question {
			score = 0.55
			reason = "question"
		} else {
			score = 0.45
			reason = "fallback"
		}

		return ActionRelevanceScore(actionId: "rewrite_text", score: score, reason: reason)
	}
}

/// Minimal insertion-order set for small arrays.
private struct LinkedHashSet<T: Hashable>: Sequence {
	private var seen: Set<T> = []
	private var ordered: [T] = []

	init(_ items: [T]) {
		for i in items { insert(i) }
	}

	mutating func insert(_ item: T) {
		if seen.insert(item).inserted {
			ordered.append(item)
		}
	}

	func makeIterator() -> IndexingIterator<[T]> { ordered.makeIterator() }
}

