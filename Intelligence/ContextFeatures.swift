import Foundation

/// Structured text signals from local extraction (no AI).
struct ContextFeatures: Equatable, Sendable {
	let textLength: Int
	let wordCount: Int
	let sentenceCount: Int
	let punctuationDensity: Double
	let hasQuestion: Bool
	let isLikelyCode: Bool
	let isLikelyLog: Bool
	let lineCount: Int
	let averageLineLength: Double
	let repetitionScore: Double
}

/// O(n) feature extraction for intelligence layers (T11.2).
final class FeatureExtractor {
	private init() {}

	private static let punctuationChars = CharacterSet(charactersIn: ".,!?;:")
	private static let sentenceDelimiters = CharacterSet(charactersIn: ".!?")
	private static let logNeedles = ["error", "exception", "failed", "warning", "trace"]
	private static let maxWordsForRepetition = 100

	static func extract(from text: String) -> ContextFeatures {
		let len = text.count
		if len == 0 {
			return ContextFeatures(
				textLength: 0,
				wordCount: 0,
				sentenceCount: 0,
				punctuationDensity: 0,
				hasQuestion: false,
				isLikelyCode: false,
				isLikelyLog: false,
				lineCount: 0,
				averageLineLength: 0,
				repetitionScore: 0
			)
		}

		let lines = text.components(separatedBy: "\n")
		let lineCount = max(lines.count, 1)

		let words = text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
		let wordCount = words.count

		let sentenceParts = text.components(separatedBy: sentenceDelimiters)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		let sentenceCount = max(sentenceParts.count, 1)

		let punctCount = text.unicodeScalars.filter { punctuationChars.contains($0) }.count
		let punctuationDensity = Double(punctCount) / Double(max(len, 1))

		let hasQuestion = text.contains("?")

		let lower = text.lowercased()
		let isLikelyLog = logNeedles.contains { lower.contains($0) }

		let isLikelyCode = computeIsLikelyCode(text: text, lower: lower)

		let repetitionScore = computeRepetitionScore(words: words)

		let avgLineLen = Double(len) / Double(max(lineCount, 1))

		return ContextFeatures(
			textLength: len,
			wordCount: wordCount,
			sentenceCount: sentenceCount,
			punctuationDensity: punctuationDensity,
			hasQuestion: hasQuestion,
			isLikelyCode: isLikelyCode,
			isLikelyLog: isLikelyLog,
			lineCount: lineCount,
			averageLineLength: avgLineLen,
			repetitionScore: repetitionScore
		)
	}

	private static func computeIsLikelyCode(text: String, lower: String) -> Bool {
		if lower.contains("{") && lower.contains("}") { return true }
		if text.contains("()") { return true }
		if lower.contains("=>") || lower.contains("==") { return true }
		if lower.contains("let ") || lower.contains("var ") || lower.contains("func ") { return true }

		var letters = 0
		var symbols = 0
		for scalar in text.unicodeScalars {
			if CharacterSet.letters.contains(scalar) || scalar == "_" {
				letters += 1
			} else if !CharacterSet.whitespacesAndNewlines.contains(scalar),
			          !CharacterSet.decimalDigits.contains(scalar)
			{
				symbols += 1
			}
		}
		let total = letters + symbols
		if total >= 24, Double(symbols) / Double(max(total, 1)) >= 0.38 {
			return true
		}
		return false
	}

	private static func computeRepetitionScore(words: [String]) -> Double {
		guard !words.isEmpty else { return 0 }
		let capped = Array(words.prefix(maxWordsForRepetition))
		let total = capped.count
		guard total > 0 else { return 0 }
		let lowered = capped.map { $0.lowercased() }
		let unique = Set(lowered).count
		return 1.0 - (Double(unique) / Double(total))
	}
}
