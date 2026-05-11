import Foundation

struct RichAnalyzeScreenPromptBuildResult: Equatable, Sendable {
	/// Full model input (OCR verbatim + user-facing instructions only).
	let input: String
	let situation: ScreenSituation
	let ocrChars: Int
	let ocrLines: Int
	let axFragments: Int
	let axTextLen: Int
	let visualKinds: [String]
	let fusedFreshness: Double
	let fusedConfidence: Double
	let fusedConflict: Double
}

enum RichAnalyzeScreenPromptBuilder {
	static func build(
		context: ContextModel,
		ocrText: String?,
		ocrLineCount: Int,
		fused: FusedContextPacket?,
		refreshMeta: [String: String]?
	) -> RichAnalyzeScreenPromptBuildResult {
		let app = context.activeAppName ?? "Unknown app"
		let bundle = context.activeAppBundleIdentifier ?? "unknown.bundle"

		let ocr = (ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let ocrChars = ocr.count
		let ocrLines = max(0, ocrLineCount)

		let axFragments = Int(refreshMeta?["axFragments"] ?? "") ?? 0
		let axTextLen = Int(refreshMeta?["axTextLen"] ?? "") ?? 0
		let visualKindsRaw = (refreshMeta?["visualKinds"]?.split(separator: ",").map(String.init) ?? [])
		let visualArb = arbitrateVisualKinds(raw: visualKindsRaw)

		let freshness = fused?.freshnessScore ?? 0.0
		let confidence = fused?.confidence ?? 0.0
		let conflict = fused?.conflictScore ?? 0.0
		let stale = fused?.isStale ?? true

		let hints = fused?.uiStructureHints ?? []

		let oq = ScreenSituationClassifier.evaluateOCRQuality(ocr)
		let ocrQuality = OCRQuality(isWeak: oq.isWeak, label: oq.label)

		let inputs = ScreenSituationInputs(
			activeAppName: context.activeAppName,
			bundleId: bundle,
			ocrCharacterCount: ocrChars,
			ocrLineCount: ocrLines,
			ocrQualityIsWeak: ocrQuality.isWeak,
			ocrQualityLabel: ocrQuality.label,
			ocrLooksCodeLike: ScreenSituationClassifier.ocrLooksCodeLike(ocr),
			ocrLooksArticleLike: ScreenSituationClassifier.ocrLooksArticleLike(ocr),
			ocrLooksErrorLike: ScreenSituationClassifier.ocrLooksErrorLike(ocr),
			ocrLooksMenuNoise: ScreenSituationClassifier.ocrLooksMenuNoise(ocr),
			dominantVisualKind: visualArb.dominantKind,
			visualHasConflicts: visualArb.hasConflicts,
			axFragmentCount: axFragments,
			axVisibleTextLength: axTextLen,
			uiStructureHints: hints,
			fusedIsStale: stale,
			fusedOverallConfidence: confidence,
			workflowInference: WorkflowInferenceEngine.shared.latestResult(),
			sessionState: ContextualSessionTracker.shared.currentState()
		)

		let situation = ScreenSituationClassifier.classify(inputs)

		let layoutPlain = plainLayoutSummary(visual: visualArb)
		let workflowPlain = plainWorkflowLine(situation: situation, fusedStale: stale)
		let styleBlock = responseStyleInstructions(situation)

		let evidenceContract = """
		## What you are doing
		You are helping a macOS user understand what is on their screen right now. Write in clear, practical language. No title line.

		## Evidence rules (read first)
		- The **Visible text** section is the only verbatim transcript of characters read from the screen. Treat it as primary factual content.
		- The app name is context only; it is not proof of what is visible.
		- The short “Layout hint” and any “Activity pattern” lines are **secondary** hints only. If they disagree with the visible text, **ignore the hints** for factual claims.
		- Do **not** mention internal implementation details (no pipeline names, no scores, no raw hint vocabulary like “descriptor”, “accessibility tree dumps”, or “fusion”).
		- Do **not** invent passwords, private URLs, file paths, emails, or unseen window titles.
		- If evidence is thin, say so briefly, then offer one or two practical next steps (for example selecting or copying text). Do not write a long uncertainty essay.

		"""

		let situationBlock = """
		## Situation profile (for you — translate to natural language; do not paste labels)
		- Screen situation kind: \(situation.kind.rawValue)
		- Response style: \(situation.responseStyle.rawValue)
		- Hint reliability (internal bucket): \(situation.confidenceBucket)
		- Caution level: \(situation.cautionLevel)
		- Limited readable text: \(situation.shouldMentionLimitedEvidence ? "yes" : "no")
		- Layout hint (plain): \(layoutPlain)
		\(workflowPlain)

		"""

		let input = """
		\(evidenceContract)
		\(situationBlock)
		## Active app (context only)
		- Name: \(app)
		- Bundle id (metadata): \(bundle)

		\(styleBlock)

		## Visible text (verbatim — primary evidence)
		\(ocr.isEmpty ? "(none captured)" : ocr)

		"""

		return RichAnalyzeScreenPromptBuildResult(
			input: input,
			situation: situation,
			ocrChars: ocrChars,
			ocrLines: ocrLines,
			axFragments: axFragments,
			axTextLen: axTextLen,
			visualKinds: visualKindsRaw,
			fusedFreshness: freshness,
			fusedConfidence: confidence,
			fusedConflict: conflict
		)
	}

	// MARK: - Plain-language summaries (no raw AX / visual vocabulary in user rules)

	private static func plainLayoutSummary(visual: VisualKindArbitrationResult) -> String {
		if visual.hasConflicts {
			return "Several layout cues disagree (for example web-like and editor-like cues at once). Prefer the readable text; do not infer code, terminals, or debugging from layout alone."
		}
		switch visual.dominantKind {
		case "browser", "article":
			return "The layout most resembles a web or document-style page."
		case "editor":
			return "The layout suggests an editor-style surface."
		case "terminal":
			return "The layout suggests a terminal or log-style surface."
		case "dialog":
			return "The layout suggests a dialog or sheet."
		default:
			return "Layout cues are inconclusive; rely on the readable text."
		}
	}

	private static func plainWorkflowLine(situation: ScreenSituation, fusedStale: Bool) -> String {
		guard situation.shouldUseWorkflow else {
			return "- Activity pattern hint: (not used — keep conclusions anchored to the readable text.)"
		}
		guard let wf = WorkflowInferenceEngine.shared.latestResult(), !wf.isStale, wf.workflow != .unknown else {
			return "- Activity pattern hint: (not used — keep conclusions anchored to the readable text.)"
		}
		if fusedStale { return "- Activity pattern hint: (stale — ignore for conclusions.)" }
		let label = wf.workflow.rawValue.replacingOccurrences(of: "_", with: " ")
		return "- Activity pattern hint (secondary only): resembles \(label)-style work — mention only if the readable text supports it."
	}

	private static func responseStyleInstructions(_ situation: ScreenSituation) -> String {
		switch situation.responseStyle {
		case .debugExplainNextSteps:
			return """
			## How to answer
			- Assume developer-style on-screen text when the situation calls for it.
			- Summarize what the visible code or messages seem to be doing, note likely problem areas, and suggest practical next checks.
			- Stay grounded in the visible text; call out uncertainty briefly if the capture is partial.
			"""
		case .summarizeArticle:
			return """
			## How to answer
			- Give a concise summary and a few key takeaways.
			- State the apparent main topic in plain language.
			- If the text looks truncated, mention that once, briefly.
			"""
		case .limitedBrowserPage, .limitedVideoOrSocial:
			return """
			## How to answer
			- Describe the page type in everyday terms (for example “looks like a browser page with little readable body text”).
			- Do **not** claim deep research, debugging, or code analysis unless the readable text clearly supports it.
			- Keep it short; suggest selecting or copying text for a richer follow-up.
			"""
		case .formDescribeNextSteps:
			return """
			## How to answer
			- Describe visible structure at a high level (sections, fields, buttons) without guessing private values.
			- Suggest sensible next steps (for example review entries before submitting).
			"""
		case .explainErrorDialog:
			return """
			## How to answer
			- Focus on the visible error or dialog text: what it likely means and what to try next.
			- Stay close to quoted/paraphrased visible text.
			"""
		case .terminalLogInvestigate:
			return """
			## How to answer
			- Treat visible lines as log or console output; summarize patterns and likely issues.
			- Suggest focused next checks grounded in what is shown.
			"""
		case .generalPractical:
			return """
			## How to answer
			- Give a short, practical read of what is on screen.
			- Prefer next steps over technical meta-narration.
			"""
		}
	}

	// MARK: - Visual kind arbitration (prompt-only; no collection)

	private struct VisualKindArbitrationResult: Equatable, Sendable {
		let dominantKind: String?
		let hasConflicts: Bool
		let arbitratedLabel: String
		let conflictsLabel: String
	}

	private struct OCRQuality: Equatable, Sendable {
		let isWeak: Bool
		let label: String
	}

	/// For Analyze Screen, treat visual kinds as weak hints. If they conflict (e.g. browser+editor+terminal),
	/// prefer a safe dominant label (browser/article/dialog) and mark the rest as conflicts so the model won’t infer workflow.
	private static func arbitrateVisualKinds(raw: [String]) -> VisualKindArbitrationResult {
		let kinds = raw
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		let set = Set(kinds)

		let preferredOrder = ["browser", "article", "dialog", "editor", "terminal"]
		let dominant = preferredOrder.first(where: { set.contains($0) }) ?? kinds.first

		let conflicts: [String]
		if let dominant {
			conflicts = kinds.filter { $0 != dominant }
		} else {
			conflicts = []
		}

		let conflictSet = Set(conflicts)
		let hasConflicts = conflictSet.count >= 2
			|| (set.contains("browser") && (set.contains("editor") || set.contains("terminal")))

		let arbitratedLabel = dominant ?? "none"
		let conflictsLabel = conflictSet.isEmpty ? "none" : conflictSet.sorted().joined(separator: ",")
		return VisualKindArbitrationResult(
			dominantKind: dominant,
			hasConflicts: hasConflicts,
			arbitratedLabel: arbitratedLabel,
			conflictsLabel: conflictsLabel
		)
	}

	// MARK: - Self-test helpers (T16.4)

	/// Ensures the model-facing Analyze Screen prompt avoids internal pipeline vocabulary.
	static func analyzePromptExcludesBannedTokens(_ prompt: String) -> Bool {
		let lower = prompt.lowercased()
		let banned = [
			"fused context", "visualkinds", "axtext", "freshnessscore", "conflictscore",
			"uistructurehints", "primarytextsource", "likelyworkflow=", "uncertaintymode"
		]
		for b in banned where lower.contains(b) { return false }
		return true
	}

	static func runJargonSelfTest() -> Bool {
		let fused = FusedContextPacket(
			id: UUID(),
			createdAt: Date(),
			primarySource: .selectedText,
			availableSources: [.activeApp, .selectedText, .visualDescriptor],
			staleSources: [],
			appName: "Safari",
			bundleIdentifier: "com.apple.Safari",
			windowTitleAvailable: false,
			primaryTextSource: .selectedText,
			textAvailability: true,
			textLength: 400,
			lineCount: 12,
			hasSelectedText: false,
			hasClipboardText: false,
			hasOCRText: true,
			hasAXText: true,
			hasWindowSnapshot: true,
			hasVisualDescriptor: true,
			hasTypingActivity: false,
			hasPointerActivity: false,
			visualKinds: [.browser, .article],
			uiStructureHints: [],
			typingState: .idle,
			pointerState: .idle,
			confidence: 0.72,
			freshnessScore: 0.74,
			conflictScore: 0.18,
			isStale: false,
			suppressedSources: [],
			supportingSources: [.axText, .screenOCR],
			arbitrationReasons: ["selftest"],
			debugSummaryMetadata: ["selftest": "1"]
		)
		let article = String(repeating: "This is a readable sentence about science. ", count: 12)
		let built = RichAnalyzeScreenPromptBuilder.build(
			context: ContextModel(),
			ocrText: article,
			ocrLineCount: 24,
			fused: fused,
			refreshMeta: ["axFragments": "2", "axTextLen": "120", "visualKinds": "browser"]
		)
		let weakBuilt = RichAnalyzeScreenPromptBuilder.build(
			context: ContextModel(),
			ocrText: "YouTube\nSkip ads\n",
			ocrLineCount: 2,
			fused: fused,
			refreshMeta: ["axFragments": "0", "axTextLen": "0", "visualKinds": "browser,editor,terminal,dialog"]
		)
		let ok = analyzePromptExcludesBannedTokens(built.input)
			&& analyzePromptExcludesBannedTokens(weakBuilt.input)
			&& built.input.contains("## Visible text")
			&& built.input.contains("## What you are doing")
			&& weakBuilt.input.contains("Limited readable text: yes")
		return ok
	}
}
