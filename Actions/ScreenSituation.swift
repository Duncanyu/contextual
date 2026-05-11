import Foundation

// MARK: - Types (T16.4 — metadata-only; no raw OCR stored on structs)

enum ScreenSituationKind: String, Equatable, Sendable, Codable, CaseIterable {
	case codeOrEditor
	case browserPage
	case articleOrResearch
	case videoOrSocial
	case formOrInput
	case errorOrDialog
	case terminalOrLog
	case unknown
}

enum ScreenSituationResponseStyle: String, Equatable, Sendable, Codable, CaseIterable {
	case debugExplainNextSteps
	case summarizeArticle
	case limitedBrowserPage
	case limitedVideoOrSocial
	case formDescribeNextSteps
	case explainErrorDialog
	case terminalLogInvestigate
	case generalPractical
}

enum ScreenSituationSignal: String, Equatable, Sendable, Codable, CaseIterable {
	case ocrContent
	case ocrWeak
	case axStructure
	case visualLayout
	case workflowAligned
	case sessionContinuity
	case visualConflict
}

struct ScreenSituation: Equatable, Sendable {
	let kind: ScreenSituationKind
	let confidenceBucket: String
	let responseStyle: ScreenSituationResponseStyle
	let supportedBy: [ScreenSituationSignal]
	let cautionLevel: String
	let shouldUseWorkflow: Bool
	let shouldMentionLimitedEvidence: Bool
	let shouldSuppressMetadataNarration: Bool
	let visualEvidenceConflicting: Bool
	/// When true, `ScreenAnalyzeAction` returns `deterministicUserReply` without calling Local AI.
	let shouldSkipLocalAI: Bool
	let deterministicUserReply: String?
}

struct ScreenSituationInputs: Equatable, Sendable {
	let activeAppName: String?
	let bundleId: String
	let ocrCharacterCount: Int
	let ocrLineCount: Int
	let ocrQualityIsWeak: Bool
	let ocrQualityLabel: String
	let ocrLooksCodeLike: Bool
	let ocrLooksArticleLike: Bool
	let ocrLooksErrorLike: Bool
	let ocrLooksMenuNoise: Bool
	let dominantVisualKind: String?
	let visualHasConflicts: Bool
	let axFragmentCount: Int
	let axVisibleTextLength: Int
	let uiStructureHints: [String]
	let fusedIsStale: Bool
	let fusedOverallConfidence: Double
	let workflowInference: WorkflowInferenceResult?
	let sessionState: ContextualSessionState?
}

enum ScreenSituationClassifier {
	private static let minWorkflowConfidence: Double = 0.46
	private static let minWorkflowForNarrative: Double = 0.52
	private static let logThrottleSeconds: TimeInterval = 2.0
	private static var lastLogSig: String?
	private static var lastLogAt: Date?

	private static let latestSnapshotLock = NSLock()
	private static var storedLatestClassificationSnapshot: ScreenSituation?

	/// Latest screen situation from the most recent `classify` call (in-memory only; for internal debug).
	static func latestClassificationSnapshot() -> ScreenSituation? {
		latestSnapshotLock.lock()
		defer { latestSnapshotLock.unlock() }
		return storedLatestClassificationSnapshot
	}

	private static func storeLatestClassificationSnapshot(_ situation: ScreenSituation) {
		latestSnapshotLock.lock()
		storedLatestClassificationSnapshot = situation
		latestSnapshotLock.unlock()
	}

	static func classify(_ i: ScreenSituationInputs) -> ScreenSituation {
		let out = compose(i)
		logClassification(out)
		storeLatestClassificationSnapshot(out)
		return out
	}

	// MARK: - Core

	private static func compose(_ i: ScreenSituationInputs) -> ScreenSituation {
		var signals: Set<ScreenSituationSignal> = []
		if i.ocrCharacterCount > 0 { signals.insert(.ocrContent) }
		if i.ocrQualityIsWeak { signals.insert(.ocrWeak) }
		if i.axFragmentCount > 0 || i.axVisibleTextLength > 40 { signals.insert(.axStructure) }
		if i.dominantVisualKind != nil { signals.insert(.visualLayout) }
		if i.visualHasConflicts { signals.insert(.visualConflict) }

		let wf = i.workflowInference
		let wfUsable = wf.map { !$0.isStale && $0.workflow != .unknown && $0.confidence >= minWorkflowConfidence } ?? false
		let wfStrong = wf.map { !$0.isStale && $0.workflow != .unknown && $0.confidence >= minWorkflowForNarrative } ?? false

		let bundleLower = i.bundleId.lowercased()
		let isVideoBundle = bundleLower.contains("youtube")
			|| bundleLower.contains("netflix")
			|| bundleLower.contains("tiktok")
			|| bundleLower.contains("twitch")
			|| bundleLower.contains("spotify")

		let isBrowserDominant = (i.dominantVisualKind == "browser" || i.dominantVisualKind == "article")
		let isEditorDominant = i.dominantVisualKind == "editor"
		let isTerminalDominant = i.dominantVisualKind == "terminal"
		let isDialogDominant = i.dominantVisualKind == "dialog"

		let formHeavy = i.uiStructureHints.contains { $0.lowercased().contains("form") || $0.lowercased().contains("input") }

		// Kind selection (order matters).
		var kind: ScreenSituationKind = .unknown
		if i.ocrLooksErrorLike || (isDialogDominant && i.ocrQualityIsWeak == false && i.ocrCharacterCount >= 24) {
			kind = .errorOrDialog
		} else if formHeavy && !isVideoBundle {
			kind = .formOrInput
		} else if isBrowserDominant, i.ocrLooksMenuNoise, i.ocrQualityIsWeak, i.ocrCharacterCount < 200, !i.visualHasConflicts {
			kind = .videoOrSocial
		} else if isVideoBundle && isBrowserDominant {
			kind = .videoOrSocial
		} else if i.visualHasConflicts, isBrowserDominant {
			kind = .browserPage
		} else if bundleLower.contains("xcode") || bundleLower.contains("com.apple.dt.xcode"), i.ocrLooksCodeLike, !i.ocrQualityIsWeak {
			kind = .codeOrEditor
		} else if isEditorDominant, i.ocrLooksCodeLike, !i.visualHasConflicts {
			kind = .codeOrEditor
		} else if isTerminalDominant, (i.ocrLooksCodeLike || i.ocrLooksErrorLike || i.axVisibleTextLength >= 400), !i.visualHasConflicts {
			kind = .terminalOrLog
		} else if isBrowserDominant, i.ocrLooksArticleLike, !i.ocrQualityIsWeak {
			kind = .articleOrResearch
		} else if isBrowserDominant {
			kind = .browserPage
		} else if i.ocrLooksArticleLike, !i.ocrQualityIsWeak {
			kind = .articleOrResearch
		}

		let visualConflict = i.visualHasConflicts
		let limitedEvidence = i.ocrQualityIsWeak || i.ocrCharacterCount < 90 || i.ocrLooksMenuNoise

		var shouldUseWorkflow = false
		if wfStrong, let w = wf {
			switch (kind, w.workflow) {
			case (.codeOrEditor, .debugging), (.terminalOrLog, .debugging), (.errorOrDialog, .debugging):
				shouldUseWorkflow = true
			case (.articleOrResearch, .research), (.browserPage, .research), (.videoOrSocial, .browsing):
				shouldUseWorkflow = true
			case (.formOrInput, .writing), (.codeOrEditor, .writing):
				shouldUseWorkflow = true
			default:
				if !visualConflict, i.ocrCharacterCount >= 120 {
					shouldUseWorkflow = true
				}
			}
		}
		if shouldUseWorkflow { signals.insert(.workflowAligned) }

		if let ses = i.sessionState, !ses.isStale, ses.continuityScore >= 0.42, let w = wf, ses.dominantWorkflow == w.workflow {
			signals.insert(.sessionContinuity)
		}

		let bucket = confidenceBucket(
			ocrWeak: i.ocrQualityIsWeak,
			ocrChars: i.ocrCharacterCount,
			visualConflict: visualConflict,
			wfConf: wf?.confidence ?? 0,
			wfUsable: wfUsable
		)

		let caution: String
		if visualConflict || i.ocrQualityIsWeak { caution = "elevated" }
		else if i.fusedIsStale || i.fusedOverallConfidence < 0.35 { caution = "elevated" }
		else { caution = "normal" }

		let style = responseStyle(for: kind, limited: limitedEvidence)

		let suppressMeta = true
		let mentionLimited = limitedEvidence || kind == .browserPage || kind == .videoOrSocial

		let skip = shouldDeterministicSkip(
			kind: kind,
			ocrChars: i.ocrCharacterCount,
			ocrWeak: i.ocrQualityIsWeak,
			axLen: i.axVisibleTextLength,
			visualHintsPresent: i.axFragmentCount > 0 || i.dominantVisualKind != nil,
			fusedFresh: i.fusedOverallConfidence >= 0.34 && !i.fusedIsStale
		)

		let det = skip ? deterministicReply(kind: kind, ocrChars: i.ocrCharacterCount, visualHintsPresent: i.axFragmentCount > 0 || i.dominantVisualKind != nil) : nil

		return ScreenSituation(
			kind: kind,
			confidenceBucket: bucket,
			responseStyle: style,
			supportedBy: Array(signals).sorted { $0.rawValue < $1.rawValue },
			cautionLevel: caution,
			shouldUseWorkflow: shouldUseWorkflow,
			shouldMentionLimitedEvidence: mentionLimited,
			shouldSuppressMetadataNarration: suppressMeta,
			visualEvidenceConflicting: visualConflict,
			shouldSkipLocalAI: skip,
			deterministicUserReply: det
		)
	}

	private static func responseStyle(for kind: ScreenSituationKind, limited: Bool) -> ScreenSituationResponseStyle {
		switch kind {
		case .codeOrEditor:
			return limited ? .generalPractical : .debugExplainNextSteps
		case .articleOrResearch:
			return limited ? .generalPractical : .summarizeArticle
		case .browserPage:
			return limited ? .limitedBrowserPage : .generalPractical
		case .videoOrSocial:
			return .limitedVideoOrSocial
		case .formOrInput:
			return .formDescribeNextSteps
		case .errorOrDialog:
			return .explainErrorDialog
		case .terminalOrLog:
			return .terminalLogInvestigate
		case .unknown:
			return .generalPractical
		}
	}

	private static func confidenceBucket(
		ocrWeak: Bool,
		ocrChars: Int,
		visualConflict: Bool,
		wfConf: Double,
		wfUsable: Bool
	) -> String {
		var score = 0.5
		if ocrWeak || ocrChars < 40 { score -= 0.22 }
		if ocrChars >= 220 { score += 0.12 }
		if visualConflict { score -= 0.18 }
		if wfUsable { score += 0.06 * min(1.0, max(0.0, wfConf)) }
		if score >= 0.62 { return "high" }
		if score >= 0.42 { return "medium" }
		if score > 0.22 { return "low" }
		return "unknown"
	}

	private static func shouldDeterministicSkip(
		kind: ScreenSituationKind,
		ocrChars: Int,
		ocrWeak: Bool,
		axLen: Int,
		visualHintsPresent: Bool,
		fusedFresh: Bool
	) -> Bool {
		if kind == .browserPage || kind == .videoOrSocial {
			if ocrWeak, ocrChars < 120, axLen < 180 { return true }
		}
		if ocrChars < 30, !visualHintsPresent, !fusedFresh { return true }
		return false
	}

	private static func deterministicReply(kind: ScreenSituationKind, ocrChars: Int, visualHintsPresent: Bool) -> String {
		if ocrChars < 30, !visualHintsPresent {
			return "I don’t have enough readable screen text or reliable layout hints to analyze this screen in depth right now. Try again when more text is visible, select the text you care about, or copy the relevant content and run the assistant on that."
		}
		switch kind {
		case .videoOrSocial, .browserPage:
			return "I can only see a limited amount of reliable on-screen text—common for browser or media pages—so I can’t produce a deep analysis from the capture alone.\n\nIt looks like a web-style page. For a better answer, select the passage you care about or copy the page text, then ask again using that text."
		default:
			return "There isn’t enough clear on-screen text to analyze in detail. If you can, select or copy the relevant content and try again."
		}
	}

	// MARK: - Logging (metadata-only)

	private static func logClassification(_ s: ScreenSituation) {
		let ev = s.supportedBy.map(\.rawValue).sorted().joined(separator: ",")
		let sig = "\(s.kind.rawValue)|\(s.confidenceBucket)|\(ev)|\(s.shouldSkipLocalAI)"
		let now = Date()
		if lastLogSig == sig, let t = lastLogAt, now.timeIntervalSince(t) < logThrottleSeconds { return }
		lastLogSig = sig
		lastLogAt = now
		print("[ScreenSituation] classified type=\(s.kind.rawValue) confidence=\(s.confidenceBucket) evidence=\(ev.isEmpty ? "none" : ev)")
		if s.shouldSkipLocalAI {
			print("[ScreenSituation] fallback reason=weak_evidence")
		}
	}

	static func logPromptProfile(situation: ScreenSituation) {
		print("[AnalyzeScreenRich] prompt_profile type=\(situation.kind.rawValue) style=\(situation.responseStyle.rawValue)")
	}

	// MARK: - OCR heuristics (called only from prompt builder; never log OCR body)

	static func evaluateOCRQuality(_ ocr: String) -> (isWeak: Bool, label: String) {
		let trimmed = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return (true, "empty") }
		let chars = trimmed.count
		if chars < 40 { return (true, "very_short") }
		let scalars = trimmed.unicodeScalars
		var alphaNum = 0
		var total = 0
		for s in scalars {
			total += 1
			if CharacterSet.alphanumerics.contains(s) { alphaNum += 1 }
		}
		let ratio = total == 0 ? 0.0 : (Double(alphaNum) / Double(total))
		if ratio < 0.45 { return (true, "noisy") }
		return (false, "ok")
	}

	static func ocrLooksCodeLike(_ ocr: String) -> Bool {
		let t = ocr
		if t.contains("{") && t.contains("}") { return true }
		if t.contains("func ") || t.contains("class ") || t.contains("import ") { return true }
		if t.contains("#include") || t.contains("def ") { return true }
		let codeish = CharacterSet(charactersIn: "{};[]<>")
		let count = t.unicodeScalars.filter { codeish.contains($0) }.count
		return count >= 8 && t.count >= 80
	}

	static func ocrLooksArticleLike(_ ocr: String) -> Bool {
		let t = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.count >= 220 else { return false }
		let sentences = [". ", "? ", "! "].reduce(0) { $0 + t.components(separatedBy: $1).count - 1 }
		return sentences >= 3
	}

	static func ocrLooksErrorLike(_ ocr: String) -> Bool {
		let lower = ocr.lowercased()
		if lower.contains("error:") || lower.contains("exception") || lower.contains("fatal") { return true }
		if lower.contains("traceback") || lower.contains("segmentation fault") { return true }
		return false
	}

	static func ocrLooksMenuNoise(_ ocr: String) -> Bool {
		let t = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.count < 200 else { return false }
		let lower = t.lowercased()
		let menuTokens = ["skip", "subscribe", "sign in", "home", "trending", "watch later", "shorts", "explore"]
		let hits = menuTokens.filter { lower.contains($0) }.count
		return hits >= 2 && t.split(separator: "\n").count <= 6
	}

	// MARK: - Self-test

	static func runSelfTest() -> Bool {
		print("[ScreenSituation] selftest starting")
		var failures: [String] = []
		func a(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let wfStale = WorkflowInferenceResult(
			workflow: .debugging,
			confidence: 0.9,
			contributingSignals: ["x"],
			inferredAt: Date(),
			isStale: true,
			summaryHint: nil,
			sourceFusedId: nil
		)
		let sStale = classify(
			ScreenSituationInputs(
				activeAppName: "Xcode",
				bundleId: "com.apple.dt.Xcode",
				ocrCharacterCount: 400,
				ocrLineCount: 12,
				ocrQualityIsWeak: false,
				ocrQualityLabel: "ok",
				ocrLooksCodeLike: true,
				ocrLooksArticleLike: false,
				ocrLooksErrorLike: false,
				ocrLooksMenuNoise: false,
				dominantVisualKind: "editor",
				visualHasConflicts: false,
				axFragmentCount: 10,
				axVisibleTextLength: 800,
				uiStructureHints: ["ax_editor_like"],
				fusedIsStale: false,
				fusedOverallConfidence: 0.7,
				workflowInference: wfStale,
				sessionState: nil
			)
		)
		a("stale_wf_ignored", !sStale.shouldUseWorkflow)

		let wfStrong = WorkflowInferenceResult(
			workflow: .debugging,
			confidence: 0.62,
			contributingSignals: ["x"],
			inferredAt: Date(),
			isStale: false,
			summaryHint: nil,
			sourceFusedId: nil
		)
		let sCode = classify(
			ScreenSituationInputs(
				activeAppName: "Xcode",
				bundleId: "com.apple.dt.Xcode",
				ocrCharacterCount: 500,
				ocrLineCount: 20,
				ocrQualityIsWeak: false,
				ocrQualityLabel: "ok",
				ocrLooksCodeLike: true,
				ocrLooksArticleLike: false,
				ocrLooksErrorLike: false,
				ocrLooksMenuNoise: false,
				dominantVisualKind: "editor",
				visualHasConflicts: false,
				axFragmentCount: 8,
				axVisibleTextLength: 900,
				uiStructureHints: ["ax_editor_like"],
				fusedIsStale: false,
				fusedOverallConfidence: 0.75,
				workflowInference: wfStrong,
				sessionState: nil
			)
		)
		a("xcode_code", sCode.kind == .codeOrEditor)
		a("strong_wf_supported_by_code", sCode.shouldUseWorkflow)

		let sArticle = classify(
			ScreenSituationInputs(
				activeAppName: "Safari",
				bundleId: "com.apple.Safari",
				ocrCharacterCount: 900,
				ocrLineCount: 40,
				ocrQualityIsWeak: false,
				ocrQualityLabel: "ok",
				ocrLooksCodeLike: false,
				ocrLooksArticleLike: true,
				ocrLooksErrorLike: false,
				ocrLooksMenuNoise: false,
				dominantVisualKind: "article",
				visualHasConflicts: false,
				axFragmentCount: 4,
				axVisibleTextLength: 200,
				uiStructureHints: [],
				fusedIsStale: false,
				fusedOverallConfidence: 0.7,
				workflowInference: nil,
				sessionState: nil
			)
		)
		a("article", sArticle.kind == .articleOrResearch)

		let sConflict = classify(
			ScreenSituationInputs(
				activeAppName: "Firefox",
				bundleId: "org.mozilla.firefox",
				ocrCharacterCount: 40,
				ocrLineCount: 3,
				ocrQualityIsWeak: true,
				ocrQualityLabel: "very_short",
				ocrLooksCodeLike: false,
				ocrLooksArticleLike: false,
				ocrLooksErrorLike: false,
				ocrLooksMenuNoise: true,
				dominantVisualKind: "browser",
				visualHasConflicts: true,
				axFragmentCount: 0,
				axVisibleTextLength: 0,
				uiStructureHints: [],
				fusedIsStale: false,
				fusedOverallConfidence: 0.5,
				workflowInference: WorkflowInferenceResult(
					workflow: .debugging,
					confidence: 0.88,
					contributingSignals: ["v"],
					inferredAt: Date(),
					isStale: false,
					summaryHint: nil,
					sourceFusedId: nil
				),
				sessionState: nil
			)
		)
		a("conflict_browser", sConflict.kind == .browserPage && sConflict.visualEvidenceConflicting)
		a("conflict_no_wf_claim", !sConflict.shouldUseWorkflow)

		let sForm = classify(
			ScreenSituationInputs(
				activeAppName: "App",
				bundleId: "com.example.app",
				ocrCharacterCount: 120,
				ocrLineCount: 8,
				ocrQualityIsWeak: false,
				ocrQualityLabel: "ok",
				ocrLooksCodeLike: false,
				ocrLooksArticleLike: false,
				ocrLooksErrorLike: false,
				ocrLooksMenuNoise: false,
				dominantVisualKind: "browser",
				visualHasConflicts: false,
				axFragmentCount: 6,
				axVisibleTextLength: 200,
				uiStructureHints: ["checkout_form"],
				fusedIsStale: false,
				fusedOverallConfidence: 0.6,
				workflowInference: nil,
				sessionState: nil
			)
		)
		a("form", sForm.kind == .formOrInput)

		let sErr = classify(
			ScreenSituationInputs(
				activeAppName: "App",
				bundleId: "com.example.app",
				ocrCharacterCount: 200,
				ocrLineCount: 6,
				ocrQualityIsWeak: false,
				ocrQualityLabel: "ok",
				ocrLooksCodeLike: false,
				ocrLooksArticleLike: false,
				ocrLooksErrorLike: true,
				ocrLooksMenuNoise: false,
				dominantVisualKind: "dialog",
				visualHasConflicts: false,
				axFragmentCount: 2,
				axVisibleTextLength: 80,
				uiStructureHints: [],
				fusedIsStale: false,
				fusedOverallConfidence: 0.55,
				workflowInference: nil,
				sessionState: nil
			)
		)
		a("error", sErr.kind == .errorOrDialog)

		let sWeakYt = classify(
			ScreenSituationInputs(
				activeAppName: "Firefox",
				bundleId: "org.mozilla.firefox",
				ocrCharacterCount: 48,
				ocrLineCount: 3,
				ocrQualityIsWeak: true,
				ocrQualityLabel: "very_short",
				ocrLooksCodeLike: false,
				ocrLooksArticleLike: false,
				ocrLooksErrorLike: false,
				ocrLooksMenuNoise: true,
				dominantVisualKind: "browser",
				visualHasConflicts: false,
				axFragmentCount: 0,
				axVisibleTextLength: 0,
				uiStructureHints: [],
				fusedIsStale: false,
				fusedOverallConfidence: 0.55,
				workflowInference: nil,
				sessionState: nil
			)
		)
		a("yt_firefox_video", sWeakYt.kind == .videoOrSocial)
		a("yt_skip_ai", sWeakYt.shouldSkipLocalAI == true)

		let ok = failures.isEmpty
		print("[ScreenSituation] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}
