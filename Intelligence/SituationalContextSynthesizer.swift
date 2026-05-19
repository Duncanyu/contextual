import Foundation

/// Deterministic situational context compression for proposal LLM prompts (T18.3.3).
enum SituationalContextSynthesizer {

	static let browserBundlePrefixes = [
		"org.mozilla.firefox",
		"com.google.Chrome",
		"com.apple.Safari",
		"com.brave.Browser",
		"company.thebrowser.Browser",
		"com.microsoft.edgemac",
		"com.operasoftware.Opera",
	]

	static func synthesize(
		from snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date = Date()
	) -> SituationalContextSnapshot {
		let appCategory = classifyApp(snapshot: snapshot)
		let selectedSignal = buildSelectedTextSignal(snapshot: snapshot, referenceTime: referenceTime)
		let clipboardSignal = buildClipboardSignal(snapshot: snapshot, referenceTime: referenceTime)
		let visualSignal = buildVisualSignal(snapshot: snapshot, referenceTime: referenceTime)
		let ocrSignal = buildOCRSignal(snapshot: snapshot, referenceTime: referenceTime)
		let activitySignal = buildActivitySignal(snapshot: snapshot, referenceTime: referenceTime)
		let interactionSignal = buildInteractionSignal(snapshot: snapshot, referenceTime: referenceTime)

		let titleOnly = isTitleOnlyContext(
			snapshot: snapshot,
			selected: selectedSignal,
			clipboard: clipboardSignal,
			ocr: ocrSignal,
			visual: visualSignal
		)

		let workflow = resolveWorkflow(
			snapshot: snapshot,
			appCategory: appCategory,
			titleOnly: titleOnly
		)
		let workflowConfidence = resolveWorkflowConfidence(
			snapshot: snapshot,
			inferred: workflow,
			titleOnly: titleOnly
		)

		let primary = resolvePrimarySource(
			selected: selectedSignal,
			clipboard: clipboardSignal,
			ocr: ocrSignal,
			visual: visualSignal,
			snapshot: snapshot,
			titleOnly: titleOnly
		)

		var available: [SituationalPrimarySource] = []
		var stale: [SituationalPrimarySource] = []
		var suppressed: [SituationalPrimarySource] = []
		accumulateSourceLists(
			selected: selectedSignal,
			clipboard: clipboardSignal,
			ocr: ocrSignal,
			visual: visualSignal,
			primary: primary,
			titleOnly: titleOnly,
			available: &available,
			stale: &stale,
			suppressed: &suppressed
		)

		let missing = buildMissingReasons(
			snapshot: snapshot,
			selected: selectedSignal,
			clipboard: clipboardSignal,
			ocr: ocrSignal,
			visual: visualSignal,
			titleOnly: titleOnly,
			primary: primary
		)

		let perception = buildPerceptionRecommendation(
			windowTitle: snapshot.windowTitle,
			appCategory: appCategory,
			selected: selectedSignal,
			clipboard: clipboardSignal,
			ocr: ocrSignal,
			visual: visualSignal,
			workflow: workflow,
			titleOnly: titleOnly,
			missing: missing
		)

		let continuity = min(1, max(0, snapshot.sourceMetadata.sessionContinuityScore))
		let freshness = GeneratedExecutionContextFreshnessScorer.score(
			snapshot: snapshot,
			referenceTime: referenceTime
		)

		let summary = buildSummary(
			snapshot: snapshot,
			appCategory: appCategory,
			workflow: workflow,
			primary: primary,
			selected: selectedSignal,
			clipboard: clipboardSignal,
			visual: visualSignal,
			perception: perception,
			titleOnly: titleOnly,
			missing: missing
		)

		let guidance = buildGuidance(
			primary: primary,
			selected: selectedSignal,
			clipboard: clipboardSignal,
			ocr: ocrSignal,
			visual: visualSignal,
			perception: perception,
			titleOnly: titleOnly,
			missing: missing,
			workflow: workflow,
			appCategory: appCategory
		)

		var metadata: [String: String] = [
			"fused_packet": snapshot.fusedPacketId == nil ? "no" : "yes",
			"packet_stale": snapshot.packetIsStale ? "yes" : "no",
			"title_only": titleOnly ? "yes" : "no",
		]
		if let hint = BrowserTitleHeuristics.domainHint(from: snapshot.windowTitle) {
			metadata["title_domain_hint"] = hint
		}

		return SituationalContextSnapshot(
			id: UUID(),
			activeAppName: snapshot.activeApp,
			activeBundleId: snapshot.bundleIdentifier,
			windowTitle: snapshot.windowTitle,
			appCategory: appCategory,
			inferredWorkflow: workflow,
			inferredIntent: snapshot.inferredIntent,
			workflowConfidence: workflowConfidence,
			contextFreshness: freshness,
			continuityConfidence: continuity,
			primaryAvailableSource: primary,
			availableSources: available,
			staleSources: stale,
			suppressedSources: suppressed,
			selectedTextSignal: selectedSignal,
			clipboardSignal: clipboardSignal,
			visualSignal: visualSignal,
			ocrSignal: ocrSignal,
			activitySignal: activitySignal,
			interactionSignal: interactionSignal,
			missingContextReasons: missing,
			perceptionRecommendation: perception.level,
			perceptionReasons: perception.reasons,
			situationalSummary: summary,
			assistantGuidance: guidance,
			createdAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(SituationalContextSnapshot.ttlSeconds),
			metadata: metadata
		)
	}

	// MARK: - Signals

	private static func buildSelectedTextSignal(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> SelectedTextSituationalSignal {
		let text = snapshot.selectedText ?? ""
		let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
		guard count > 0 else {
			return SelectedTextSituationalSignal(
				availability: .unavailable,
				lengthBucket: .none,
				freshness: .unknown,
				confidence: .low,
				reasonCodes: ["no_selection"],
				privacyLevel: .metadataOnly
			)
		}
		let capturedAt = snapshot.sourceMetadata.selectedTextCapturedAt ?? snapshot.generatedAt
		let freshness = SituationalSignalMetrics.freshnessLevel(
			capturedAt: capturedAt,
			source: .selectedText,
			referenceTime: referenceTime
		)
		let score = ContextFreshnessPolicy.freshnessScore(
			for: .selectedText,
			capturedAt: capturedAt,
			now: referenceTime
		)
		let availability: SituationalSourceAvailability = freshness == .stale ? .stale : .available
		return SelectedTextSituationalSignal(
			availability: availability,
			lengthBucket: SituationalSignalMetrics.lengthBucket(for: count),
			freshness: freshness,
			confidence: SituationalSignalMetrics.confidenceLevel(from: score),
			reasonCodes: ["selection_present"],
			privacyLevel: .cappedExcerpt
		)
	}

	private static func buildClipboardSignal(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> ClipboardSituationalSignal {
		let text = snapshot.clipboardText ?? ""
		let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
		guard count > 0 else {
			return ClipboardSituationalSignal(
				availability: .unavailable,
				lengthBucket: .none,
				freshness: .unknown,
				confidence: .low,
				reasonCodes: ["no_clipboard"],
				privacyLevel: .metadataOnly
			)
		}

		let suppression = GeneratedExecutionClipboardFreshnessPolicy.evaluate(
			snapshot: snapshot,
			referenceTime: referenceTime
		)
		if !suppression.includeClipboard {
			var reasons = [suppression.reasonCode ?? "clipboard_suppressed"]
			if reasons[0] == "selection_present" {
				reasons = ["stale_after_app_change", "selection_fresher"]
			}
			return ClipboardSituationalSignal(
				availability: .suppressed,
				lengthBucket: SituationalSignalMetrics.lengthBucket(for: count),
				freshness: .stale,
				confidence: .low,
				reasonCodes: reasons,
				privacyLevel: .metadataOnly
			)
		}

		let capturedAt = snapshot.sourceMetadata.clipboardCapturedAt ?? snapshot.generatedAt
		let freshness = SituationalSignalMetrics.freshnessLevel(
			capturedAt: capturedAt,
			source: .clipboardText,
			referenceTime: referenceTime
		)
		let score = ContextFreshnessPolicy.freshnessScore(
			for: .clipboardText,
			capturedAt: capturedAt,
			now: referenceTime
		)
		let availability: SituationalSourceAvailability = freshness == .stale ? .stale : .available
		return ClipboardSituationalSignal(
			availability: availability,
			lengthBucket: SituationalSignalMetrics.lengthBucket(for: count),
			freshness: freshness,
			confidence: SituationalSignalMetrics.confidenceLevel(from: score),
			reasonCodes: ["clipboard_usable"],
			privacyLevel: .cappedExcerpt
		)
	}

	private static func buildVisualSignal(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> VisualSituationalSignal {
		let visual = snapshot.visualContextAvailability
		guard visual.hasUsableVisual else {
			return VisualSituationalSignal(
				availability: .unavailable,
				freshness: .unknown,
				confidence: .low,
				reasonCodes: ["no_visual_metadata"],
				privacyLevel: .metadataOnly,
				hasDescriptor: false,
				hasWindowSnapshot: false
			)
		}
		let capturedAt = visual.visualCapturedAt ?? snapshot.generatedAt
		let freshness = SituationalSignalMetrics.freshnessLevel(
			capturedAt: capturedAt,
			source: .visualDescriptor,
			referenceTime: referenceTime
		)
		let score = ContextFreshnessPolicy.freshnessScore(
			for: .visualDescriptor,
			capturedAt: capturedAt,
			now: referenceTime
		)
		return VisualSituationalSignal(
			availability: freshness == .stale ? .stale : .available,
			freshness: freshness,
			confidence: SituationalSignalMetrics.confidenceLevel(from: score),
			reasonCodes: ["visual_metadata_present"],
			privacyLevel: .metadataOnly,
			hasDescriptor: visual.hasVisualDescriptor,
			hasWindowSnapshot: visual.hasWindowSnapshot
		)
	}

	private static func buildOCRSignal(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> OCRSituationalSignal {
		let text = snapshot.recentOCRExcerpt ?? ""
		let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
		guard count > 0 else {
			return OCRSituationalSignal(
				availability: .unavailable,
				lengthBucket: .none,
				freshness: .unknown,
				confidence: .low,
				reasonCodes: ["no_ocr"],
				privacyLevel: .metadataOnly
			)
		}
		let capturedAt = snapshot.sourceMetadata.ocrCapturedAt ?? snapshot.generatedAt
		let freshness = SituationalSignalMetrics.freshnessLevel(
			capturedAt: capturedAt,
			source: .screenOCR,
			referenceTime: referenceTime
		)
		let score = ContextFreshnessPolicy.freshnessScore(
			for: .screenOCR,
			capturedAt: capturedAt,
			now: referenceTime
		)
		return OCRSituationalSignal(
			availability: freshness == .stale ? .stale : .available,
			lengthBucket: SituationalSignalMetrics.lengthBucket(for: count),
			freshness: freshness,
			confidence: SituationalSignalMetrics.confidenceLevel(from: score),
			reasonCodes: ["ocr_excerpt_present"],
			privacyLevel: .cappedExcerpt
		)
	}

	private static func buildActivitySignal(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> ActivitySituationalSignal {
		let continuity = snapshot.sourceMetadata.sessionContinuityScore
		let dominant = snapshot.sourceMetadata.sessionDominantWorkflow
		let hasSignal = continuity >= 0.35 || dominant != nil
		return ActivitySituationalSignal(
			availability: hasSignal ? .available : .unavailable,
			freshness: continuity >= 0.55 ? .fresh : (continuity >= 0.3 ? .aging : .unknown),
			confidence: SituationalSignalMetrics.confidenceLevel(from: continuity),
			reasonCodes: hasSignal ? ["session_continuity"] : ["weak_session_signal"],
			sessionContinuityScore: continuity,
			dominantWorkflowHint: dominant
		)
	}

	private static func buildInteractionSignal(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> InteractionSituationalSignal {
		let trigger = snapshot.sourceMetadata.lastSourceTrigger
		let hasTrigger = trigger != nil
		let capturedAt = snapshot.sourceMetadata.contextUpdatedAt ?? snapshot.generatedAt
		let freshness = SituationalSignalMetrics.freshnessLevel(
			capturedAt: capturedAt,
			source: .activeApp,
			referenceTime: referenceTime
		)
		var reasons: [String] = []
		if trigger == LastSourceTrigger.activeAppChanged.rawValue {
			reasons.append("recent_app_change")
		}
		if trigger == LastSourceTrigger.selectedTextChanged.rawValue {
			reasons.append("recent_selection_change")
		}
		if reasons.isEmpty, hasTrigger { reasons.append("trigger_metadata") }
		return InteractionSituationalSignal(
			availability: hasTrigger ? .available : .unavailable,
			freshness: freshness,
			confidence: hasTrigger ? .medium : .low,
			reasonCodes: reasons,
			lastTriggerHint: trigger
		)
	}

	// MARK: - Classification

	private static func classifyApp(snapshot: CanonicalGeneratedExecutionContextSnapshot) -> SituationalAppCategory {
		if isBrowser(snapshot: snapshot) { return .browser }
		let bundle = (snapshot.bundleIdentifier ?? "").lowercased()
		let app = snapshot.activeApp.lowercased()
		if bundle.contains("xcode") || app.contains("xcode") { return .ide }
		if bundle.contains("terminal") || app.contains("terminal") || bundle.contains("iterm") { return .terminal }
		if app.contains("notes") || bundle.contains("notes") { return .notes }
		if app.contains("slack") || app.contains("mail") || app.contains("messages") { return .communication }
		if app.contains("vlc") || app.contains("quicktime") || app.contains("music") { return .media }
		return .unknown
	}

	static func isBrowser(snapshot: CanonicalGeneratedExecutionContextSnapshot) -> Bool {
		let bundle = snapshot.bundleIdentifier ?? ""
		if browserBundlePrefixes.contains(where: { bundle.hasPrefix($0) }) { return true }
		let app = snapshot.activeApp.lowercased()
		return app.contains("firefox") || app.contains("safari") || app.contains("chrome") || app.contains("edge")
	}

	private static func isTitleOnlyContext(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		selected: SelectedTextSituationalSignal,
		clipboard: ClipboardSituationalSignal,
		ocr: OCRSituationalSignal,
		visual: VisualSituationalSignal
	) -> Bool {
		let hasTitle = !snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let noStrongText = selected.availability != .available
			&& ocr.availability != .available
			&& (clipboard.availability != .available || clipboard.availability == .suppressed)
		return hasTitle && noStrongText && visual.availability != .available
	}

	private static func resolveWorkflow(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		appCategory: SituationalAppCategory,
		titleOnly: Bool
	) -> InferredWorkflow {
		if snapshot.inferredWorkflow != .unknown, snapshot.workflowConfidence >= 0.4 {
			return snapshot.inferredWorkflow
		}
		if titleOnly, appCategory == .browser {
			return BrowserTitleHeuristics.inferWorkflow(from: snapshot.windowTitle)
		}
		if appCategory == .ide { return .debugging }
		if appCategory == .terminal { return .debugging }
		if appCategory == .notes { return .writing }
		return snapshot.inferredWorkflow
	}

	private static func resolveWorkflowConfidence(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		inferred: InferredWorkflow,
		titleOnly: Bool
	) -> Double {
		if snapshot.inferredWorkflow == inferred, snapshot.workflowConfidence >= 0.35 {
			return snapshot.workflowConfidence
		}
		if titleOnly, inferred != .unknown { return 0.48 }
		if inferred != .unknown { return max(snapshot.workflowConfidence, 0.42) }
		return snapshot.workflowConfidence
	}

	private static func resolvePrimarySource(
		selected: SelectedTextSituationalSignal,
		clipboard: ClipboardSituationalSignal,
		ocr: OCRSituationalSignal,
		visual: VisualSituationalSignal,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		titleOnly: Bool
	) -> SituationalPrimarySource {
		if selected.availability == .available, selected.freshness != .stale {
			return .selectedText
		}
		if ocr.availability == .available, ocr.freshness != .stale {
			return .ocr
		}
		if visual.availability == .available {
			return .visual
		}
		if clipboard.availability == .available, clipboard.freshness != .stale {
			return .clipboard
		}
		if snapshot.inferredWorkflow != .unknown, snapshot.workflowConfidence >= 0.35 {
			return .workflowApp
		}
		if titleOnly || !snapshot.windowTitle.isEmpty {
			return .metadataOnly
		}
		return .none
	}

	private static func accumulateSourceLists(
		selected: SelectedTextSituationalSignal,
		clipboard: ClipboardSituationalSignal,
		ocr: OCRSituationalSignal,
		visual: VisualSituationalSignal,
		primary: SituationalPrimarySource,
		titleOnly: Bool,
		available: inout [SituationalPrimarySource],
		stale: inout [SituationalPrimarySource],
		suppressed: inout [SituationalPrimarySource]
	) {
		func track(_ source: SituationalPrimarySource, availability: SituationalSourceAvailability) {
			switch availability {
			case .available:
				if !available.contains(source) { available.append(source) }
			case .stale:
				if !stale.contains(source) { stale.append(source) }
			case .suppressed:
				if !suppressed.contains(source) { suppressed.append(source) }
			case .unavailable:
				break
			}
		}
		track(.selectedText, availability: selected.availability)
		track(.clipboard, availability: clipboard.availability)
		track(.ocr, availability: ocr.availability)
		track(.visual, availability: visual.availability)
		if titleOnly, !available.contains(.metadataOnly) {
			available.append(.metadataOnly)
		}
		if primary == .workflowApp, !available.contains(.workflowApp) {
			available.append(.workflowApp)
		}
		_ = primary
	}

	private static func buildMissingReasons(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		selected: SelectedTextSituationalSignal,
		clipboard: ClipboardSituationalSignal,
		ocr: OCRSituationalSignal,
		visual: VisualSituationalSignal,
		titleOnly: Bool,
		primary: SituationalPrimarySource
	) -> [String] {
		var reasons: [String] = []
		if snapshot.fusedPacketId == nil {
			reasons.append("no_fused_packet")
		} else if snapshot.packetIsStale {
			reasons.append("fused_packet_stale")
		}
		if selected.availability == .unavailable {
			reasons.append("no_selected_text")
		}
		if ocr.availability == .unavailable {
			reasons.append("no_ocr_excerpt")
		}
		if visual.availability == .unavailable {
			reasons.append("no_visual_metadata")
		}
		if clipboard.availability == .suppressed {
			reasons.append("clipboard_suppressed")
			if let code = clipboard.reasonCodes.first {
				reasons.append(code)
			}
		}
		if titleOnly {
			reasons.append("title_only_metadata")
			if isBrowser(snapshot: snapshot) {
				reasons.append("browser_ax_unavailable")
			}
		}
		if primary == .metadataOnly {
			reasons.append("metadata_only_context")
		}
		if snapshot.inferredWorkflow == .unknown, !titleOnly {
			reasons.append("workflow_unknown")
		}
		return Array(reasons.prefix(10))
	}

	private static func buildPerceptionRecommendation(
		windowTitle: String,
		appCategory: SituationalAppCategory,
		selected: SelectedTextSituationalSignal,
		clipboard: ClipboardSituationalSignal,
		ocr: OCRSituationalSignal,
		visual: VisualSituationalSignal,
		workflow: InferredWorkflow,
		titleOnly: Bool,
		missing: [String]
	) -> (level: SituationalPerceptionRecommendation, reasons: [SituationalPerceptionReason]) {
		var reasons: [SituationalPerceptionReason] = []
		let noText = selected.availability != .available && ocr.availability != .available

		if noText {
			reasons.append(.noTextContext)
		}
		if titleOnly, appCategory == .browser {
			reasons.append(.browserAXUnavailable)
		}
		if BrowserTitleHeuristics.suggestsVideoOrSlides(from: windowTitle) {
			reasons.append(.videoOrSlidesLikely)
		}
		if BrowserTitleHeuristics.suggestsImageOrDiagram(from: windowTitle) {
			reasons.append(.imageOrDiagramLikely)
		}
		if workflow == .unknown {
			reasons.append(.workflowUnknown)
		}
		if clipboard.availability == .suppressed || clipboard.availability == .stale,
		   selected.availability != .available,
		   ocr.availability != .available
		{
			reasons.append(.staleClipboardOnly)
		}
		if missing.contains("no_fused_packet") || missing.contains("fused_packet_stale") {
			reasons.append(.weakFusedContext)
		}

		let level: SituationalPerceptionRecommendation
		if reasons.contains(.videoOrSlidesLikely) || (titleOnly && appCategory == .browser && noText) {
			level = .recommended
		} else if reasons.contains(.browserAXUnavailable), noText {
			level = .recommended
		} else if reasons.contains(.imageOrDiagramLikely) {
			level = .useful
		} else if !reasons.isEmpty, noText {
			level = .useful
		} else {
			level = .none
		}
		return (level, Array(reasons.prefix(6)))
	}

	private static func buildSummary(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		appCategory: SituationalAppCategory,
		workflow: InferredWorkflow,
		primary: SituationalPrimarySource,
		selected: SelectedTextSituationalSignal,
		clipboard: ClipboardSituationalSignal,
		visual: VisualSituationalSignal,
		perception: (level: SituationalPerceptionRecommendation, reasons: [SituationalPerceptionReason]),
		titleOnly: Bool,
		missing: [String]
	) -> String {
		var parts: [String] = []
		parts.append("User appears to be in \(snapshot.activeApp)")

		if titleOnly, appCategory == .browser {
			let hint = BrowserTitleHeuristics.humanPageKind(from: snapshot.windowTitle)
			parts.append("viewing a \(hint) page with only window-title metadata (no readable page text)")
		} else if selected.availability == .available {
			parts.append("with fresh selected text available as primary context")
		} else if primary == .metadataOnly {
			parts.append("with only app/window metadata available")
		}

		if workflow != .unknown {
			parts.append("likely workflow: \(workflow.rawValue)")
		}

		if clipboard.availability == .suppressed {
			parts.append("clipboard should not be used (\(clipboard.reasonCodes.first ?? "suppressed"))")
		} else if clipboard.availability == .stale {
			parts.append("clipboard appears stale")
		}

		if snapshot.fusedPacketId == nil {
			parts.append("no fused context packet")
		} else if snapshot.packetIsStale {
			parts.append("fused packet is stale")
		}

		if perception.level == .recommended || perception.level == .requiredBeforeSpecificProposal {
			parts.append("sparse visual perception would likely help")
		} else if perception.level == .useful {
			parts.append("visual context may help")
		}

		if missing.contains("browser_ax_unavailable") {
			parts.append("avoid assuming page body contents")
		}

		let joined = parts.joined(separator: "; ") + "."
		if joined.count <= SituationalContextSnapshot.maxSummaryLength { return joined }
		return String(joined.prefix(SituationalContextSnapshot.maxSummaryLength))
	}

	private static func buildGuidance(
		primary: SituationalPrimarySource,
		selected: SelectedTextSituationalSignal,
		clipboard: ClipboardSituationalSignal,
		ocr: OCRSituationalSignal,
		visual: VisualSituationalSignal,
		perception: (level: SituationalPerceptionRecommendation, reasons: [SituationalPerceptionReason]),
		titleOnly: Bool,
		missing: [String],
		workflow: InferredWorkflow,
		appCategory: SituationalAppCategory
	) -> [String] {
		var lines: [String] = []

		if clipboard.availability == .suppressed || clipboard.availability == .stale {
			lines.append("Do not use clipboard as primary context.")
		}
		if selected.availability == .available, selected.freshness == .fresh {
			if workflow == .debugging || appCategory == .ide {
				lines.append("Selected code/text is fresh; proposals may focus on debugging or code review.")
			} else {
				lines.append("Use fresh selection as the primary evidence channel.")
			}
		}
		if titleOnly {
			lines.append("Generate only metadata-aware proposals; do not assume page body content.")
			lines.append("Avoid quoting or summarizing unseen page text.")
		}
		if perception.level == .recommended {
			lines.append("Recommend or ask for visual context before detailed page-specific proposals.")
		} else if perception.level == .useful {
			lines.append("Visual context may improve specificity but is not mandatory.")
		}
		if primary == .none || (titleOnly && workflow == .unknown) {
			lines.append("Stay quiet if no useful proposal can be made from metadata alone.")
		}
		if missing.contains("no_fused_packet") {
			lines.append("Missing fused packet is not automatic failure — use title/app metadata carefully.")
		}
		if ocr.availability == .available {
			lines.append("OCR excerpt is available; prefer it over clipboard when selection is absent.")
		}
		if visual.availability == .available {
			lines.append("Visual metadata exists; do not request capture if tags already suffice.")
		}

		return Array(lines.prefix(SituationalContextSnapshot.maxGuidanceItems))
	}
}

// MARK: - Browser title heuristics

enum BrowserTitleHeuristics {

	static func inferWorkflow(from windowTitle: String) -> InferredWorkflow {
		let lower = windowTitle.lowercased()
		if lower.contains("youtube") || lower.contains("vimeo") || lower.contains("netflix") {
			return .research
		}
		if lower.contains("reddit") {
			return .browsing
		}
		if lower.contains("job bank") || lower.contains("linkedin") || lower.contains("indeed") {
			return .research
		}
		if lower.contains("github") || lower.contains("stackoverflow") || lower.contains("documentation") {
			return .research
		}
		if lower.contains("mail") || lower.contains("inbox") {
			return .reviewing
		}
		return .browsing
	}

	static func humanPageKind(from windowTitle: String) -> String {
		let lower = windowTitle.lowercased()
		if lower.contains("youtube") { return "video/media" }
		if lower.contains("reddit") { return "discussion/browsing" }
		if lower.contains("job bank") { return "job-search" }
		if lower.contains("github") { return "code/repository" }
		return "web"
	}

	static func domainHint(from windowTitle: String) -> String? {
		let lower = windowTitle.lowercased()
		if lower.contains("youtube") { return "youtube" }
		if lower.contains("reddit") { return "reddit" }
		if lower.contains("job bank") { return "job_bank" }
		if lower.contains("firefox") || lower.contains("mozilla") { return "browser_shell" }
		return nil
	}

	static func suggestsVideoOrSlides(from windowTitle: String) -> Bool {
		let lower = windowTitle.lowercased()
		return lower.contains("youtube")
			|| lower.contains("vimeo")
			|| lower.contains("netflix")
			|| lower.contains(" — slides")
			|| lower.contains(" - slides")
			|| lower.contains("powerpoint")
	}

	static func suggestsImageOrDiagram(from windowTitle: String) -> Bool {
		let lower = windowTitle.lowercased()
		return lower.contains("diagram")
			|| lower.contains("figure")
			|| lower.contains("blueprint")
			|| lower.contains("screenshot")
	}
}
