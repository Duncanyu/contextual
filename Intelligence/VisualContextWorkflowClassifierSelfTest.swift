import Foundation

/// T18.3.8 — Visual context workflow classifier self-tests (deterministic, no model calls).
enum VisualContextWorkflowClassifierSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()

		// 1) Firefox + YouTube + OCR should remain browsing/research-ish, never debugging.
		let youtube = VisualContextWorkflowClassifier.classify(
			appCategory: .browser,
			windowTitle: "YouTube — Example Video",
			visualTags: ["video", "player"],
			ocrExcerpt: "Subscribe • Comments • Up next",
			priorWorkflow: .browsing,
			priorConfidence: 0.55
		)
		check("youtube_not_debugging", youtube.workflow != .debugging)
		check("youtube_preserves_prior", youtube.workflow == .browsing || youtube.workflow == .research)

		// 2) Browser context with error-like OCR should still not flip to debugging without IDE context.
		let browserError = VisualContextWorkflowClassifier.classify(
			appCategory: .browser,
			windowTitle: "YouTube — Example Video",
			visualTags: ["video"],
			ocrExcerpt: "Error: playback failed",
			priorWorkflow: .browsing,
			priorConfidence: 0.55
		)
		check("browser_error_not_debugging", browserError.workflow != .debugging)

		// 3) Xcode + error-like OCR should classify as debugging.
		let xcode = VisualContextWorkflowClassifier.classify(
			appCategory: .ide,
			windowTitle: "Xcode — Build Failed",
			visualTags: ["stacktrace"],
			ocrExcerpt: "error: value of type 'Foo' has no member 'bar'",
			priorWorkflow: .unknown,
			priorConfidence: 0.2
		)
		check("xcode_debugging", xcode.workflow == .debugging)

		// 4) Unknown prior + browser title should resolve to browsing/research.
		let unknownPrior = VisualContextWorkflowClassifier.classify(
			appCategory: .browser,
			windowTitle: "Reddit — Some Thread",
			visualTags: [],
			ocrExcerpt: nil,
			priorWorkflow: .unknown,
			priorConfidence: 0.2
		)
		check("unknown_prior_browser_not_unknown", unknownPrior.workflow != .unknown)

		// 5) Visual merge should update situational primary source away from metadata_only when OCR exists.
		let baseSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			windowTitle: "YouTube — Example Video",
			bundleIdentifier: "com.apple.Safari",
			inferredWorkflow: .unknown,
			workflowConfidence: 0.2,
			generatedAt: now,
			freshnessScore: 0.4
		)
		let visualResult = BoundedVisualContextResult(
			requestId: UUID(),
			status: .completed,
			capturedAt: now,
			sourceSummary: "selftest",
			ocrExcerpt: "Subscribe Comments Up next",
			visualSummary: "Video player visible",
			visualTags: ["video", "player"],
			warnings: [],
			metadata: ["captureCount": "1"],
			expiresAt: now.addingTimeInterval(8)
		)
		let mergedSnap = baseSnap.merging(
			visualResult: visualResult,
			priorWorkflow: .browsing,
			priorWorkflowConfidence: 0.55,
			referenceTime: now
		)
		let situationalMerged = SituationalContextSynthesizer.synthesize(from: mergedSnap, referenceTime: now)
		check("merged_primary_is_not_metadata_only", situationalMerged.primaryAvailableSource != .metadataOnly)

		let ok = failures.isEmpty
		let detail = failures.joined(separator: ";")
		print("[VisualContextWorkflowClassifier] selftest ok=\(ok) failures=\(failures.count) detail=\(detail)")
		return ok
	}
}
