import Foundation

/// T12.7 — Strict, metadata-safe validation for model proposal titles (Intelligence layer only).
enum IntelligenceProposalTitleValidator {
	/// Conservative display cap (stricter than `IntelligenceDecisionResponse` storage limit).
	static let maxDisplayedLength: Int = 60

	enum Evaluation: Equatable {
		case accepted(String)
		case rejected(reason: String)
	}

	/// Single-line title intended for `ActionProposal.title`. Never logs or persists content.
	static func evaluate(_ raw: String?, request: IntelligenceDecisionRequest) -> Evaluation {
		guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
			return .rejected(reason: "empty")
		}

		let oneLine = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)

		guard oneLine.count <= maxDisplayedLength else {
			return .rejected(reason: "too_long")
		}
		guard oneLine.hasSuffix("?") else {
			return .rejected(reason: "not_question")
		}
		guard !oneLine.contains("\n"), !oneLine.contains("\r") else {
			return .rejected(reason: "newline")
		}

		// Quoted / fenced user echo
		if oneLine.contains("\"") || oneLine.contains("'") || oneLine.contains("`") || oneLine.contains("«") || oneLine.contains("»") {
			return .rejected(reason: "quotes")
		}

		let lower = oneLine.lowercased()

		// Natural safe openings (case-insensitive via lower).
		let prefixes = ["want ", "need ", "want me", "want help", "want a quick"]
		guard prefixes.contains(where: { lower.hasPrefix($0) }) else {
			return .rejected(reason: "prefix")
		}

		// URLs / schemes
		if lower.contains("http") || lower.contains("www.") || lower.contains("://") {
			return .rejected(reason: "url")
		}

		if oneLine.contains("@") {
			return .rejected(reason: "email")
		}

		// Paths (conservative)
		if oneLine.contains("\\") || oneLine.contains("/users/") || oneLine.contains("/home/") || oneLine.contains("/var/") || oneLine.contains(":\\") {
			return .rejected(reason: "path")
		}

		// Long digit runs (IDs, stack traces)
		if Self.containsDigitRun(oneLine, minimumLength: 5) {
			return .rejected(reason: "digits")
		}

		// Identifier-ish snake fragments from copied errors
		if oneLine.contains("_"), lower.range(of: "[a-z]+_[a-z]+", options: .regularExpression) != nil {
			return .rejected(reason: "identifier")
		}

		let excerptLower = request.compressedText.lowercased()

		// Long substring overlap with excerpt (privacy)
		if Self.hasForbiddenOverlap(oneLine, excerptLower: excerptLower, minimumLength: 8) {
			return .rejected(reason: "excerpt_overlap")
		}

		// Token overlap with excerpt (8+ chars), catches pasted words
		let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
		for tok in tokens where tok.count >= 8 {
			if excerptLower.contains(tok) {
				return .rejected(reason: "token_overlap")
			}
		}

		// App / window metadata leakage
		if let app = request.appName?.trimmingCharacters(in: .whitespacesAndNewlines), app.count >= 2 {
			if lower.contains(app.lowercased()) {
				return .rejected(reason: "app_meta")
			}
		}
		if let wt = request.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), wt.count >= 4 {
			if lower.contains(wt.lowercased()) {
				return .rejected(reason: "window_meta")
			}
		}

		return .accepted(oneLine)
	}

	private static func containsDigitRun(_ s: String, minimumLength: Int) -> Bool {
		var run = 0
		for ch in s.unicodeScalars {
			if CharacterSet.decimalDigits.contains(ch) {
				run += 1
				if run >= minimumLength { return true }
			} else {
				run = 0
			}
		}
		return false
	}

	private static func hasForbiddenOverlap(_ title: String, excerptLower: String, minimumLength: Int) -> Bool {
		let t = title.lowercased()
		guard t.count >= minimumLength, excerptLower.count >= minimumLength else { return false }
		var i = t.startIndex
		while i < t.endIndex {
			guard let j = t.index(i, offsetBy: minimumLength, limitedBy: t.endIndex) else { break }
			let sub = String(t[i..<j])
			if excerptLower.contains(sub) {
				return true
			}
			i = t.index(after: i)
		}
		return false
	}
}
