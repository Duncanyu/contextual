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

