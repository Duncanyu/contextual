import Foundation

/// Metadata-only fingerprint for “similar enough” floating lifecycle matching (no raw text stored or logged).
struct ContentSimilarityProfile: Equatable, Sendable {
	let normalizedLength: Int
	let lengthBucket: Int
	let prefixHash: UInt64
	let suffixHash: UInt64

	private static let edgeSampleCount = 200
	private static let bucketSize = 50

	static func make(from rawText: String) -> ContentSimilarityProfile {
		let normalized = Self.normalize(rawText)
		let len = normalized.utf16.count
		let bucket = max(0, (len + bucketSize / 2) / bucketSize * bucketSize)
		let prefix = String(normalized.prefix(edgeSampleCount))
		let suffix = String(normalized.suffix(edgeSampleCount))
		return ContentSimilarityProfile(
			normalizedLength: len,
			lengthBucket: bucket,
			prefixHash: fnv1a64(prefix),
			suffixHash: fnv1a64(suffix)
		)
	}

	/// True when lengths are within 10% and prefix/suffix hashes match (cheap same-context proxy).
	static func isSimilar(_ a: ContentSimilarityProfile, _ b: ContentSimilarityProfile) -> Bool {
		guard a.prefixHash == b.prefixHash, a.suffixHash == b.suffixHash else { return false }
		let maxLen = max(a.normalizedLength, b.normalizedLength, 1)
		let diff = abs(a.normalizedLength - b.normalizedLength)
		return Double(diff) / Double(maxLen) <= 0.10
	}

	private static func normalize(_ text: String) -> String {
		var s = text.lowercased()
		s = s.trimmingCharacters(in: .whitespacesAndNewlines)
		let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
		var t = collapsed
		while let first = t.first, !first.isLetter && !first.isNumber {
			t.removeFirst()
		}
		while let last = t.last, !last.isLetter && !last.isNumber {
			t.removeLast()
		}
		return t
	}

	private static func fnv1a64(_ text: String) -> UInt64 {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for b in text.utf8 {
			hash ^= UInt64(b)
			hash &*= 1_099_511_628_211
		}
		return hash
	}
}
