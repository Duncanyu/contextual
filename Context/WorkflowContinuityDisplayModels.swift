import Foundation

/// User-facing, template-only summary for subtle workflow continuity UI (T16.8). No raw user content.
struct WorkflowContinuityDisplaySummary: Equatable, Sendable {
	var isVisible: Bool
	/// Template phrase when `isVisible` (e.g. "Research session active"); empty when hidden.
	var label: String
	var workflow: InferredWorkflow
	/// Coarse buckets for logging / future chips: `low`, `medium`, `high`.
	var confidenceBucket: String
	var continuityBucket: String
	/// Bounded metadata tokens (no paths, titles, or text bodies).
	var chips: [String]
	var reasonCodes: [String]
	var isStale: Bool
	var generatedAt: Date

	static func hidden(at: Date = Date(), reasons: [String] = ["not_evaluated"]) -> WorkflowContinuityDisplaySummary {
		WorkflowContinuityDisplaySummary(
			isVisible: false,
			label: "",
			workflow: .unknown,
			confidenceBucket: "low",
			continuityBucket: "low",
			chips: [],
			reasonCodes: reasons,
			isStale: false,
			generatedAt: at
		)
	}
}

// MARK: - Builder

enum WorkflowContinuityDisplayBuilder {
	private static let maxChips = 2
	private static let mediumThreshold = 0.50
	private static let highThreshold = 0.68

	static func build(
		inference: WorkflowInferenceResult?,
		session: ContextualSessionState?,
		fused: FusedContextPacket?,
		referenceTime: Date = Date()
	) -> WorkflowContinuityDisplaySummary {
		guard let inference else {
			return finalizeHidden(at: referenceTime, reasons: ["no_inference"])
		}
		guard let session else {
			return finalizeHidden(at: referenceTime, reasons: ["no_session"])
		}
		guard let fused else {
			return finalizeHidden(at: referenceTime, reasons: ["no_fused_packet"])
		}

		var reasons: [String] = []

		if inference.workflow == .unknown {
			return finalizeHidden(at: referenceTime, reasons: ["unknown_workflow"])
		}
		if inference.isStale {
			return finalizeHidden(at: referenceTime, reasons: ["stale_workflow"])
		}
		if fused.isStale || fused.freshnessScore < 0.28 {
			return finalizeHidden(at: referenceTime, reasons: ["stale_context"])
		}
		if session.isStale {
			return finalizeHidden(at: referenceTime, reasons: ["stale_session"])
		}

		let wfBucket = bucket(for: inference.confidence)
		let contBucket = bucket(for: session.continuityConfidence)
		if wfBucket == "low" {
			return finalizeHidden(at: referenceTime, reasons: ["low_workflow_confidence"])
		}
		if contBucket == "low" {
			return finalizeHidden(at: referenceTime, reasons: ["weak_session"])
		}
		if session.patternConfidence < 0.44 {
			return finalizeHidden(at: referenceTime, reasons: ["weak_pattern"])
		}

		if intenseInteraction(fused) {
			return finalizeHidden(at: referenceTime, reasons: ["interaction_burst"])
		}

		if clipboardOnlyWeakEvidence(fused: fused, inference: inference) {
			return finalizeHidden(at: referenceTime, reasons: ["clipboard_only_weak"])
		}

		if session.dominantWorkflow == .unknown {
			return finalizeHidden(at: referenceTime, reasons: ["unknown_session_workflow"])
		}
		if !workflowsAlign(inference.workflow, session.dominantWorkflow) {
			return finalizeHidden(at: referenceTime, reasons: ["workflow_session_conflict"])
		}

		if !workflowSpecificEvidenceAllowsShow(inference: inference, fused: fused, contBucket: contBucket) {
			return finalizeHidden(at: referenceTime, reasons: ["weak_workflow_evidence"])
		}

		let label = templateLabel(workflow: inference.workflow, continuityBucket: contBucket)
		guard !label.isEmpty else {
			return finalizeHidden(at: referenceTime, reasons: ["no_label"])
		}

		reasons.append("stable_session")
		if wfBucket == "high" { reasons.append("strong_workflow") }
		if contBucket == "high" { reasons.append("strong_continuity") }

		var chips: [String] = []
		func addChip(_ s: String) {
			guard chips.count < maxChips, !chips.contains(s) else { return }
			chips.append(s)
		}
		addChip("wf_\(wfBucket)")
		addChip("session_\(contBucket)")

		return WorkflowContinuityDisplaySummary(
			isVisible: true,
			label: label,
			workflow: inference.workflow,
			confidenceBucket: wfBucket,
			continuityBucket: contBucket,
			chips: chips,
			reasonCodes: reasons,
			isStale: false,
			generatedAt: referenceTime
		)
	}

	/// Convenience: reads live singletons (main-thread UI refresh only).
	static func buildFromCurrentState(referenceTime: Date = Date()) -> WorkflowContinuityDisplaySummary {
		build(
			inference: WorkflowInferenceEngine.shared.latestResult(),
			session: ContextualSessionTracker.shared.currentState(),
			fused: CanonicalContextState.shared.current(),
			referenceTime: referenceTime
		)
	}

	// MARK: - Self-test (synthetic metadata only)

	static func runSelfTest() -> Bool {
		print("[WorkflowContinuityUI] selftest starting")
		var failures: [String] = []
		func a(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let t0 = Date(timeIntervalSince1970: 2_120_000_000)

		func fusedBase(
			primary: FusedTextSource,
			hasSelected: Bool,
			textLen: Int,
			lineCount: Int,
			visuals: [VisualUIKind],
			typing: TypingState?,
			pointer: PointerState?,
			freshness: Double,
			confidence: Double,
			conflict: Double,
			isStale: Bool
		) -> FusedContextPacket {
			FusedContextPacket(
				id: UUID(),
				createdAt: t0,
				primarySource: .selectedText,
				availableSources: [.activeApp, .selectedText],
				staleSources: [],
				appName: nil,
				bundleIdentifier: "com.selftest.app",
				windowTitleAvailable: false,
				primaryTextSource: primary,
				textAvailability: textLen > 0,
				textLength: textLen,
				lineCount: lineCount,
				hasSelectedText: hasSelected,
				hasClipboardText: primary == .clipboardText,
				hasOCRText: false,
				hasAXText: false,
				hasWindowSnapshot: false,
				hasVisualDescriptor: !visuals.isEmpty,
				hasTypingActivity: typing != nil,
				hasPointerActivity: pointer != nil,
				visualKinds: visuals,
				uiStructureHints: [],
				typingState: typing,
				pointerState: pointer,
				confidence: confidence,
				freshnessScore: freshness,
				conflictScore: conflict,
				isStale: isStale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: [],
				debugSummaryMetadata: ["selftest": "1"]
			)
		}

		func session(
			dominant: InferredWorkflow,
			contConf: Double,
			pattern: Double,
			stale: Bool
		) -> ContextualSessionState {
			ContextualSessionState(
				continuityScore: min(1.0, contConf + 0.05),
				continuityConfidence: contConf,
				patternConfidence: pattern,
				dominantWorkflow: dominant,
				activeTrajectorySummary: "\(dominant.rawValue)>\(dominant.rawValue)",
				contributingSignals: [.workflowStreak],
				updatedAt: t0,
				isStale: stale
			)
		}

		func infer(_ wf: InferredWorkflow, conf: Double, stale: Bool, signals: [String]) -> WorkflowInferenceResult {
			WorkflowInferenceResult(
				workflow: wf,
				confidence: conf,
				contributingSignals: signals,
				inferredAt: t0,
				isStale: stale,
				summaryHint: "\(wf.rawValue)_like",
				sourceFusedId: UUID()
			)
		}

		let fusedDebug = fusedBase(
			primary: .selectedText,
			hasSelected: true,
			textLen: 200,
			lineCount: 12,
			visuals: [.editor, .terminal],
			typing: .active,
			pointer: .idle,
			freshness: 0.72,
			confidence: 0.74,
			conflict: 0.12,
			isStale: false
		)
		let sDebug = session(dominant: .debugging, contConf: 0.71, pattern: 0.62, stale: false)
		let iDebug = infer(.debugging, conf: 0.66, stale: false, signals: ["terminal_present"])
		let outDebug = build(inference: iDebug, session: sDebug, fused: fusedDebug, referenceTime: t0)
		a("debug_visible", outDebug.isVisible && outDebug.label.contains("Debugging"))
		a("debug_continuing_or_detected", outDebug.label.contains("continuing") || outDebug.label.contains("detected"))

		let fusedRes = fusedBase(
			primary: .selectedText,
			hasSelected: false,
			textLen: 400,
			lineCount: 40,
			visuals: [.article, .browser],
			typing: .idle,
			pointer: .idle,
			freshness: 0.7,
			confidence: 0.7,
			conflict: 0.1,
			isStale: false
		)
		let sRes = session(dominant: .research, contConf: 0.66, pattern: 0.58, stale: false)
		let iRes = infer(.research, conf: 0.62, stale: false, signals: ["long_text_reading_shape"])
		let outRes = build(inference: iRes, session: sRes, fused: fusedRes, referenceTime: t0)
		a("research_label", outRes.isVisible && outRes.label == "Research session active")

		let fusedWrite = fusedBase(
			primary: .selectedText,
			hasSelected: true,
			textLen: 120,
			lineCount: 6,
			visuals: [.article, .form],
			typing: .active,
			pointer: .idle,
			freshness: 0.68,
			confidence: 0.66,
			conflict: 0.15,
			isStale: false
		)
		let sW = session(dominant: .writing, contConf: 0.63, pattern: 0.55, stale: false)
		let iW = infer(.writing, conf: 0.58, stale: false, signals: ["steady_typing_docs"])
		let outW = build(inference: iW, session: sW, fused: fusedWrite, referenceTime: t0)
		a("writing_label", outW.isVisible && outW.label == "Writing workflow continuing")

		let fusedRev = fusedBase(
			primary: .selectedText,
			hasSelected: true,
			textLen: 200,
			lineCount: 10,
			visuals: [.editor],
			typing: .idle,
			pointer: .idle,
			freshness: 0.7,
			confidence: 0.72,
			conflict: 0.1,
			isStale: false
		)
		let sRev = session(dominant: .reviewing, contConf: 0.64, pattern: 0.56, stale: false)
		let iRev = infer(.reviewing, conf: 0.6, stale: false, signals: ["editor_idle_review_shape"])
		let outRev = build(inference: iRev, session: sRev, fused: fusedRev, referenceTime: t0)
		a("review_label", outRev.isVisible && outRev.label == "Review workflow active")

		a("unknown_hidden", !build(inference: infer(.unknown, conf: 0.7, stale: false, signals: []), session: sDebug, fused: fusedDebug, referenceTime: t0).isVisible)

		a("low_wf_hidden", !build(inference: infer(.debugging, conf: 0.35, stale: false, signals: ["terminal_present"]), session: sDebug, fused: fusedDebug, referenceTime: t0).isVisible)

		let sWeak = session(dominant: .debugging, contConf: 0.32, pattern: 0.5, stale: false)
		a("weak_session_hidden", !build(inference: iDebug, session: sWeak, fused: fusedDebug, referenceTime: t0).isVisible)

		let fusedStale = fusedBase(
			primary: .selectedText,
			hasSelected: true,
			textLen: 100,
			lineCount: 4,
			visuals: [.editor],
			typing: .idle,
			pointer: .idle,
			freshness: 0.1,
			confidence: 0.5,
			conflict: 0.2,
			isStale: true
		)
		a("stale_fused_hidden", !build(inference: iDebug, session: sDebug, fused: fusedStale, referenceTime: t0).isVisible)

		let iStale = infer(.debugging, conf: 0.7, stale: true, signals: ["terminal_present"])
		a("stale_workflow_hidden", !build(inference: iStale, session: sDebug, fused: fusedDebug, referenceTime: t0).isVisible)

		let sConflict = session(dominant: .writing, contConf: 0.65, pattern: 0.55, stale: false)
		a("conflict_hidden", !build(inference: iDebug, session: sConflict, fused: fusedDebug, referenceTime: t0).isVisible)

		let fusedClip = fusedBase(
			primary: .clipboardText,
			hasSelected: false,
			textLen: 40,
			lineCount: 3,
			visuals: [.editor],
			typing: .idle,
			pointer: .idle,
			freshness: 0.65,
			confidence: 0.58,
			conflict: 0.12,
			isStale: false
		)
		let sClip = session(dominant: .debugging, contConf: 0.66, pattern: 0.55, stale: false)
		let iClip = infer(.debugging, conf: 0.58, stale: false, signals: ["editor_context"])
		a("clipboard_weak_hidden", !build(inference: iClip, session: sClip, fused: fusedClip, referenceTime: t0).isVisible)

		let fusedBrowseWeak = fusedBase(
			primary: .selectedText,
			hasSelected: false,
			textLen: 40,
			lineCount: 2,
			visuals: [.browser, .media],
			typing: .idle,
			pointer: .idle,
			freshness: 0.55,
			confidence: 0.5,
			conflict: 0.2,
			isStale: false
		)
		let sBrowse = session(dominant: .browsing, contConf: 0.55, pattern: 0.48, stale: false)
		let iBrowse = infer(.browsing, conf: 0.52, stale: false, signals: ["visual_browser_idle"])
		a("browsing_weak_hidden", !build(inference: iBrowse, session: sBrowse, fused: fusedBrowseWeak, referenceTime: t0).isVisible)

		let fusedBrowseOk = fusedBase(
			primary: .selectedText,
			hasSelected: false,
			textLen: 200,
			lineCount: 15,
			visuals: [.browser, .article],
			typing: .idle,
			pointer: .idle,
			freshness: 0.62,
			confidence: 0.64,
			conflict: 0.18,
			isStale: false
		)
		let sBrowseOk = session(dominant: .browsing, contConf: 0.62, pattern: 0.52, stale: false)
		let iBrowseOk = infer(.browsing, conf: 0.58, stale: false, signals: ["visual_browser_idle"])
		let outBrowse = build(inference: iBrowseOk, session: sBrowseOk, fused: fusedBrowseOk, referenceTime: t0)
		a("browsing_ok", outBrowse.isVisible && outBrowse.label == "Browsing context")

		a("chips_bounded", outDebug.chips.count <= maxChips && outRes.chips.count <= maxChips)

		for s in [outDebug, outRes, outW, outRev, outBrowse] {
			for c in [s.label] + s.chips {
				a("no_url_in_\(c.prefix(12))", !c.contains("://"))
			}
		}

		let ok = failures.isEmpty
		print("[WorkflowContinuityUI] selftest failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}

	// MARK: - Private

	private static func finalizeHidden(at: Date, reasons: [String]) -> WorkflowContinuityDisplaySummary {
		.hidden(at: at, reasons: reasons)
	}

	private static func bucket(for value: Double) -> String {
		let v = min(1.0, max(0.0, value))
		if v >= highThreshold { return "high" }
		if v >= mediumThreshold { return "medium" }
		return "low"
	}

	private static func intenseInteraction(_ fused: FusedContextPacket) -> Bool {
		if fused.typingState == .burst { return true }
		if fused.pointerState == .burst { return true }
		return false
	}

	private static func clipboardOnlyWeakEvidence(fused: FusedContextPacket, inference: WorkflowInferenceResult) -> Bool {
		guard fused.primaryTextSource == .clipboardText, !fused.hasSelectedText else { return false }
		let short = fused.textLength < 80 && fused.lineCount < 6
		let weakWf = inference.confidence < 0.62
		return short && weakWf
	}

	private static func workflowsAlign(_ a: InferredWorkflow, _ b: InferredWorkflow) -> Bool {
		if a == b { return true }
		let pair = Set([a, b])
		if pair == Set([.editing, .reviewing]) { return true }
		if pair == Set([.research, .browsing]) { return true }
		if pair == Set([.debugging, .editing]) { return true }
		if pair == Set([.writing, .research]) { return true }
		return false
	}

	private static func workflowSpecificEvidenceAllowsShow(
		inference: WorkflowInferenceResult,
		fused: FusedContextPacket,
		contBucket: String
	) -> Bool {
		let kinds = Set(fused.visualKinds)
		let signals = Set(inference.contributingSignals)

		switch inference.workflow {
		case .debugging:
			if kinds.contains(.terminal) { return true }
			if kinds.contains(.editor) { return true }
			return signals.contains("terminal_burst_or_conflict")
				|| signals.contains("terminal_present")
				|| signals.contains("continuity_multi_app_editor_terminal")

		case .research:
			return kinds.contains(.article)
				|| kinds.contains(.browser)
				|| signals.contains("long_text_reading_shape")

		case .writing, .editing:
			if fused.typingState == .active || fused.typingState == .started || fused.typingState == .burst { return true }
			return signals.contains("steady_typing_docs")

		case .reviewing:
			return kinds.contains(.editor) || signals.contains("editor_idle_review_shape")

		case .browsing:
			if kinds.contains(.media), !kinds.contains(.article), fused.lineCount < 10 { return false }
			return kinds.contains(.article)
				|| signals.contains("long_text_reading_shape")
				|| contBucket == "high"

		case .unknown:
			return false
		}
	}

	private static func templateLabel(workflow: InferredWorkflow, continuityBucket: String) -> String {
		switch workflow {
		case .debugging:
			return continuityBucket == "high" ? "Debugging workflow continuing" : "Debugging workflow detected"
		case .research:
			return "Research session active"
		case .writing, .editing:
			return "Writing workflow continuing"
		case .reviewing:
			return "Review workflow active"
		case .browsing:
			return "Browsing context"
		case .unknown:
			return ""
		}
	}
}
