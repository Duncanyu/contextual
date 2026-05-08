import Foundation

/// Deterministic float features for `MicroDecisionClassifier` (T12.3.7).
/// Must stay in sync with `Scripts/build_micro_classifier.py` — used instead of raw-string TF-IDF (not CoreML-exportable).
enum MicroDecisionFeatureEncoder {
	static let dimension = 32

	/// Privacy-safe: derived counts and flags only; no logging here.
	static func floats(for request: MicroDecisionRequest) -> [Double] {
		var v = [Double](repeating: 0, count: dimension)
		let f = request.features

		v[0] = scale(request.textLength, max: 4000)
		v[1] = scale(request.lineCount, max: 120)
		v[2] = scale(f.wordCount, max: 1200)
		v[3] = scale(f.sentenceCount, max: 80)
		v[4] = min(1.0, max(0.0, f.punctuationDensity))
		v[5] = f.hasQuestion ? 1.0 : 0.0
		v[6] = f.isLikelyCode ? 1.0 : 0.0
		v[7] = f.isLikelyLog ? 1.0 : 0.0
		v[8] = min(1.0, f.averageLineLength / 150.0)
		v[9] = min(1.0, max(0.0, f.repetitionScore))

		switch request.contextType {
		case .question: v[10] = 1
		case .notes: v[11] = 1
		case .code: v[12] = 1
		case .errorLog: v[13] = 1
		case .article: v[14] = 1
		case .random: v[15] = 1
		}

		let b = sourceBucket8(request.sourceType)
		v[16 + b] = 1.0

		let acts = Set(request.availableActions)
		v[24] = acts.contains("summarize_text") ? 1.0 : 0.0
		v[25] = acts.contains("explain_text") ? 1.0 : 0.0
		v[26] = acts.contains("rewrite_text") ? 1.0 : 0.0
		v[27] = scale(request.availableActions.count, max: 6)
		v[28] = scale(request.textLength / 25, max: 80)
		v[29] = scale(request.lineCount / 2, max: 40)
		let sc = max(f.sentenceCount, 1)
		v[30] = scale(f.wordCount / sc, max: 120)
		let excerptLen = request.compressedText.count
		v[31] = scale(excerptLen, max: 2000)
		return v
	}

	private static func scale(_ x: Int, max: Int) -> Double {
		guard max > 0 else { return 0 }
		return min(1.0, Double(x) / Double(max))
	}

	/// FNV-1a 64-bit — must match Python training script.
	private static func sourceBucket8(_ s: String) -> Int {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for b in s.utf8 {
			hash ^= UInt64(b)
			hash &*= 1_099_511_628_211
		}
		return Int(hash % 8)
	}
}
