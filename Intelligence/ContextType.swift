import Foundation

enum ContextType: String, Sendable {
	case question
	case notes
	case code
	case errorLog
	case article
	case random
}

enum ContextClassifier {
	static func classify(features: ContextFeatures, text _: String) -> ContextType {
		// Order matters: question overrides others per spec.
		if features.hasQuestion { return .question }
		if features.isLikelyLog { return .errorLog }
		if features.isLikelyCode { return .code }

		let prose = !features.isLikelyCode && !features.isLikelyLog

		// Long prose in Notes / browser often has few newlines or few explicit sentence delimiters
		// but is still a valid article/notes context (T12.10 regression fix).
		if prose, features.textLength >= 220, features.wordCount >= 40 {
			// List-like or multi-paragraph notes
			if features.lineCount > 2, features.averageLineLength < 120 {
				if features.sentenceCount >= 2 { return .notes }
				// Long-enough selection with multiple lines but minimal `.` / `!` (URLs, titles, prose)
				if features.textLength >= 280, features.lineCount >= 3 { return .notes }
			}
			// Single block or a few long lines (typical article / note body)
			if features.lineCount <= 4, features.textLength >= 250 {
				return .article
			}
			if features.textLength >= 300 { return .article }
		}

		// Notes: short lines, multi-line, multiple sentences.
		if features.lineCount > 2, features.averageLineLength < 120, features.sentenceCount >= 2 {
			return .notes
		}

		// Article: longer, multi-sentence, punctuation is present.
		if features.textLength > 200, features.sentenceCount >= 3, features.punctuationDensity > 0.02 {
			return .article
		}

		return .random
	}
}

