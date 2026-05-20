import Foundation

/// Deterministic workflow inference for post-visual/OCR enriched contexts (T18.3.8).
///
/// Rules:
/// - Uses metadata only: app category, window title, visual tags, bounded OCR excerpt.
/// - Never reads raw screenshots.
/// - Never calls models.
enum VisualContextWorkflowClassifier {

	struct Result: Equatable, Sendable {
		let workflow: InferredWorkflow
		let confidence: Double
		/// Metadata-only reason codes (no raw OCR text).
		let reasonCodes: [String]
		let ocrHint: String
	}

	static func classify(
		appCategory: SituationalAppCategory,
		windowTitle: String,
		visualTags: [String],
		ocrExcerpt: String?,
		priorWorkflow: InferredWorkflow,
		priorConfidence: Double
	) -> Result {
		let titleLower = windowTitle.lowercased()
		let ocrLower = (ocrExcerpt ?? "").lowercased()
		let tagsLower = Set(visualTags.map { $0.lowercased() })

		let hasOcr = !ocrLower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

		let isIdeLike = appCategory == .ide || appCategory == .terminal
		let isBrowserLike = appCategory == .browser

		let debugSignals = hasDebugSignals(titleLower: titleLower, ocrLower: ocrLower, tagsLower: tagsLower)
		let browseSignals = isBrowserLike || titleLower.contains("youtube") || titleLower.contains("reddit") || titleLower.contains("github")

		var reasons: [String] = []
		var workflow: InferredWorkflow = .unknown
		var confidence: Double = 0.4

		let ocrHint = ocrHintBucket(ocrLower: ocrLower, hasOcr: hasOcr)

		// 1) Preserve a useful prior workflow unless OCR strongly contradicts it.
		if priorWorkflow != .unknown, priorConfidence >= 0.45 {
			reasons.append("prior:\(priorWorkflow.rawValue)")
			workflow = priorWorkflow
			confidence = min(0.9, max(priorConfidence, 0.55))
		}

		// 2) Strong debugging signals can override, but only when app is IDE/terminal or OCR is clearly error-like.
		if debugSignals {
			if isIdeLike {
				reasons.append("override:ide_debug")
				return Result(
					workflow: .debugging,
					confidence: 0.82,
					reasonCodes: reasons + ["debug_signals", "app_ide_like"],
					ocrHint: ocrHint
				)
			}
			if ocrHint == "error_like" {
				reasons.append("override:ocr_error_like")
				return Result(
					workflow: .debugging,
					confidence: 0.7,
					reasonCodes: reasons + ["debug_signals", "ocr_error_like"],
					ocrHint: ocrHint
				)
			}
			// Browser-like + weak debug tokens should not force debugging.
			reasons.append("debug_signals_ignored")
		}

		// 3) Browser-like contexts should prefer browsing/research/reviewing rather than unknown.
		if isBrowserLike || browseSignals {
			let inferred = BrowserTitleHeuristics.inferWorkflow(from: windowTitle)
			let wf: InferredWorkflow = inferred == .unknown ? .browsing : inferred
			let baseConf: Double = (titleLower.contains("youtube") || tagsLower.contains("video")) ? 0.62 : 0.56
			reasons.append("browser_title_heuristic")
			return Result(
				workflow: workflow == .unknown ? wf : workflow,
				confidence: max(confidence, baseConf),
				reasonCodes: reasons + ["app_browser_like"],
				ocrHint: ocrHint
			)
		}

		return Result(workflow: workflow, confidence: confidence, reasonCodes: reasons, ocrHint: ocrHint)
	}

	private static func hasDebugSignals(
		titleLower: String,
		ocrLower: String,
		tagsLower: Set<String>
	) -> Bool {
		if titleLower.contains("xcode") { return true }
		if tagsLower.contains("stacktrace") || tagsLower.contains("exception") { return true }
		// OCR excerpt is bounded; simple keyword checks only.
		let tokens = ["error", "exception", "stack trace", "fatal", "assert", "segmentation fault", "traceback"]
		return tokens.contains { ocrLower.contains($0) }
	}

	private static func ocrHintBucket(ocrLower: String, hasOcr: Bool) -> String {
		guard hasOcr else { return "empty" }
		if ocrLower.contains("error") || ocrLower.contains("exception") || ocrLower.contains("traceback") {
			return "error_like"
		}
		if ocrLower.contains("{") || ocrLower.contains("};") || ocrLower.contains("->") || ocrLower.contains("func ") {
			return "code_like"
		}
		if ocrLower.contains("youtube") || ocrLower.contains("subscribe") || ocrLower.contains("comments") {
			return "video_like"
		}
		return "generic"
	}
}

