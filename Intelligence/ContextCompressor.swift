import Foundation

/// Small, safe packet for future intelligence decisions (T12.2). No persistence, no logging of excerpts.
struct CompressedContextPacket: Sendable, Equatable {
	let appName: String?
	let windowTitle: String?
	let sourceType: String
	let contextType: ContextType
	let featureSummary: ContextFeatures
	let availableActions: [String]
	let textExcerpt: String
	let originalTextLength: Int
	let excerptLength: Int
	let lineCount: Int
	let compressionApplied: Bool
}

enum ContextCompressor {
	/// Hard cap on excerpt size (privacy + performance).
	static let excerptCap: Int = 600
	private static let marker = "[…]"

	static func compress(
		contextType: ContextType,
		features: ContextFeatures,
		availableActions: [String],
		sourceType: String,
		appName: String?,
		windowTitle: String?,
		text: String
	) -> CompressedContextPacket {
		let cleaned = normalizeWhitespace(text).trimmingCharacters(in: .whitespacesAndNewlines)
		let originalLen = cleaned.count
		let lines = max(1, cleaned.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })

		let excerpt: String
		let applied: Bool
		if originalLen <= excerptCap {
			excerpt = cleaned
			applied = false
		} else {
			excerpt = makeHeadTailExcerpt(cleaned, cap: excerptCap)
			applied = true
		}

		return CompressedContextPacket(
			appName: appName,
			windowTitle: windowTitle,
			sourceType: sourceType,
			contextType: contextType,
			featureSummary: features,
			availableActions: availableActions,
			textExcerpt: excerpt,
			originalTextLength: originalLen,
			excerptLength: excerpt.count,
			lineCount: lines,
			compressionApplied: applied
		)
	}

	/// Deterministic local fingerprint of content (no raw text returned).
	static func fingerprintHex(for text: String) -> String {
		String(fnv1a64(text: text), radix: 16)
	}

	// MARK: - Internals

	private static func normalizeWhitespace(_ text: String) -> String {
		// Collapse runs of spaces/tabs; preserve newlines.
		var out = ""
		out.reserveCapacity(min(text.count, 2048))
		var lastWasSpace = false
		for ch in text {
			if ch == "\n" {
				out.append("\n")
				lastWasSpace = false
				continue
			}
			if ch == " " || ch == "\t" || ch == "\r" {
				if !lastWasSpace {
					out.append(" ")
					lastWasSpace = true
				}
				continue
			}
			out.append(ch)
			lastWasSpace = false
		}
		return out
	}

	private static func makeHeadTailExcerpt(_ text: String, cap: Int) -> String {
		guard cap > marker.count + 10 else {
			let hard = String(text.prefix(cap))
			return hard
		}

		let available = cap - marker.count
		let headCount = Int(Double(available) * 0.62)
		let tailCount = available - headCount

		let head = safeBoundaryPrefix(text, maxCount: headCount)
		let tail = safeBoundarySuffix(text, maxCount: tailCount)

		// Ensure we never exceed cap (boundary ops may slightly vary).
		var combined = head + marker + tail
		if combined.count > cap {
			combined = String(combined.prefix(cap))
		}
		return combined
	}

	private static func safeBoundaryPrefix(_ text: String, maxCount: Int) -> String {
		if text.count <= maxCount { return text }
		let idx = text.index(text.startIndex, offsetBy: maxCount)
		var slice = String(text[..<idx])
		// Avoid cutting mid-word when practical by backing up to a whitespace boundary.
		if let cut = slice.lastIndex(where: { $0 == " " || $0 == "\n" }) {
			let candidate = slice[..<cut]
			if candidate.count >= max(24, maxCount - 64) {
				slice = String(candidate)
			}
		}
		return slice
	}

	private static func safeBoundarySuffix(_ text: String, maxCount: Int) -> String {
		if text.count <= maxCount { return text }
		let start = text.index(text.endIndex, offsetBy: -maxCount)
		var slice = String(text[start...])
		// Avoid cutting mid-word by advancing to the first whitespace boundary.
		if let cut = slice.firstIndex(where: { $0 == " " || $0 == "\n" }) {
			let candidate = slice[cut...]
			if candidate.count >= max(24, maxCount - 64) {
				slice = String(candidate)
			}
		}
		return slice
	}

	private static func fnv1a64(text: String) -> UInt64 {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for b in text.utf8 {
			hash ^= UInt64(b)
			hash &*= 1_099_511_628_211
		}
		return hash
	}

	#if DEBUG
	/// Debug-only verification helper (not called from runtime).
	static func _selfTest() -> Bool {
		let short = "  hello\t\tworld  "
		let p1 = compress(
			contextType: .random,
			features: FeatureExtractor.extract(from: short),
			availableActions: [],
			sourceType: "test",
			appName: nil,
			windowTitle: nil,
			text: short
		)
		guard p1.textExcerpt == "hello world" else { return false }
		guard p1.compressionApplied == false else { return false }

		let long = String(repeating: "abc ", count: 400) + "THE_END"
		let p2 = compress(
			contextType: .random,
			features: FeatureExtractor.extract(from: long),
			availableActions: ["explain_text"],
			sourceType: "test",
			appName: "X",
			windowTitle: "Y",
			text: long
		)
		guard p2.textExcerpt.count <= excerptCap else { return false }
		guard p2.textExcerpt.contains(marker) else { return false }
		guard p2.textExcerpt.contains("THE_END") else { return false }

		let empty = "   \n\t "
		let p3 = compress(
			contextType: .random,
			features: FeatureExtractor.extract(from: empty),
			availableActions: [],
			sourceType: "test",
			appName: nil,
			windowTitle: nil,
			text: empty
		)
		guard p3.textExcerpt.isEmpty else { return false }
		return true
	}
	#endif
}

