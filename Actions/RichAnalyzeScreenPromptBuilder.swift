import Foundation

struct RichAnalyzeScreenPromptBuildResult: Equatable, Sendable {
	let input: String
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
		let windowTitleAvailable = (context.activeWindowTitle != nil)

		let ocr = (ocrText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let ocrChars = ocr.count
		let ocrLines = max(0, ocrLineCount)

		let axFragments = Int(refreshMeta?["axFragments"] ?? "") ?? 0
		let axTextLen = Int(refreshMeta?["axTextLen"] ?? "") ?? 0
		let visualKindsRaw = (refreshMeta?["visualKinds"]?.split(separator: ",").map(String.init) ?? [])
		let visualArb = arbitrateVisualKinds(raw: visualKindsRaw)

		let primary = fused?.primarySource.rawValue ?? "none"
		let primaryText = fused?.primaryTextSource.rawValue ?? "none"
		let freshness = fused?.freshnessScore ?? 0.0
		let confidence = fused?.confidence ?? 0.0
		let conflict = fused?.conflictScore ?? 0.0
		let stale = fused?.isStale ?? true

		let typing = fused?.typingState?.rawValue ?? "unknown"
		let pointer = fused?.pointerState?.rawValue ?? "unknown"

		let hints = fused?.uiStructureHints ?? []
		let hintsLabel = hints.isEmpty ? "none" : hints.prefix(12).joined(separator: ",")

		let ocrQuality = evaluateOCRQuality(ocr)
		let uncertaintyMode = (ocrQuality.isWeak || visualArb.hasConflicts) ? "on" : "off"

		let workflow = workflowHints(
			appBundle: bundle,
			visual: visualArb,
			hints: hints,
			typing: typing,
			pointer: pointer,
			freshness: freshness,
			ocrQuality: ocrQuality,
			axTextLen: axTextLen
		)

		let evidenceContract = """
		## Evidence contract (read first)
		- The OCR section is the only verbatim evidence of visible characters.
		- Active app / bundle / windowTitleAvailable / workflow hints are not proof of on-screen content; do not narrate UI from them alone.
		- Visual/AX/fused metadata are weak hints only; conflicting visual hints must NOT be used to infer workflow or intent.
		- If OCR is empty, short, or noisy, treat the rest as metadata-only context with limited evidence and default to uncertainty-first language.

		"""

		let input = """
		\(evidenceContract)
		## Active app
		- appName: \(app)
		- bundleId: \(bundle)
		- windowTitleAvailable: \(windowTitleAvailable)

		## OCR
		- ocrChars: \(ocrChars)
		- ocrLines: \(ocrLines)
		- ocrQuality: \(ocrQuality.label)
		- uncertaintyMode: \(uncertaintyMode)
		- ocrText:
		\(ocr.isEmpty ? "(none)" : ocr)

		## Visual hints (no image)
		- visualKindsRaw: \(visualKindsRaw.isEmpty ? "none" : visualKindsRaw.joined(separator: ","))
		- visualKindsArbitrated: \(visualArb.arbitratedLabel)
		- visualConflicts: \(visualArb.conflictsLabel)

		## AX hints (no raw tree)
		- axFragments: \(axFragments)
		- axEstimatedVisibleTextLength: \(axTextLen)

		## Fused context (metadata)
		- primarySource: \(primary)
		- primaryTextSource: \(primaryText)
		- freshnessScore: \(String(format: "%.2f", freshness))
		- confidence: \(String(format: "%.2f", confidence))
		- conflictScore: \(String(format: "%.2f", conflict))
		- isStale: \(stale)
		- uiStructureHints: \(hintsLabel)

		## Interaction state (metadata)
		- typingState: \(typing)
		- pointerState: \(pointer)

		## Workflow hints (metadata, low-confidence)
		\(workflow.map { "- \($0)" }.joined(separator: "\n"))
		"""

		return RichAnalyzeScreenPromptBuildResult(
			input: input,
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

	private static func workflowHints(
		appBundle: String,
		visual: VisualKindArbitrationResult,
		hints: [String],
		typing: String,
		pointer: String,
		freshness: Double,
		ocrQuality: OCRQuality,
		axTextLen: Int
	) -> [String] {
		var out: [String] = []
		if appBundle.contains("Xcode") || appBundle.contains("com.apple.dt.Xcode") {
			out.append("activeAppCategory=developer")
		}
		// Workflow hints are allowed only when evidence is strong AND visual metadata is non-conflicting.
		// For weak/noisy OCR or conflicting visual labels, avoid workflow claims entirely.
		let allowWorkflowHints = (!ocrQuality.isWeak) && (!visual.hasConflicts)

		let hasEditorEvidence = hints.contains("ax_editor_like")
			|| hints.contains("visual_monospace_region")
			|| axTextLen >= 900
		let hasTerminalEvidence = axTextLen >= 900

		if allowWorkflowHints, visual.dominantKind == "editor", hasEditorEvidence {
			out.append("likelyWorkflow=code_editing")
		}
		if allowWorkflowHints, visual.dominantKind == "terminal", hasTerminalEvidence {
			out.append("likelyWorkflow=terminal_debugging")
		}
		if allowWorkflowHints, visual.dominantKind == "browser" || visual.dominantKind == "article" {
			out.append("likelyWorkflow=browsing")
		}
		if typing == "burst" || typing == "active" {
			out.append("interactionState=typing_active")
		} else if pointer == "burst" || pointer == "interacting" || pointer == "clicking" {
			out.append("interactionState=pointer_active")
		} else {
			out.append("interactionState=idle_or_light")
		}
		out.append("contextFreshness=\(String(format: "%.2f", freshness))")
		return out
	}

	// MARK: - Visual kind arbitration (prompt-only; no collection)

	private struct VisualKindArbitrationResult: Equatable, Sendable {
		let dominantKind: String?
		let hasConflicts: Bool
		let arbitratedLabel: String
		let conflictsLabel: String
	}

	/// For Analyze Screen, treat visual kinds as weak hints. If they conflict (e.g. browser+editor+terminal),
	/// prefer a safe dominant label (browser/article/dialog) and mark the rest as conflicts so the model won’t infer workflow.
	private static func arbitrateVisualKinds(raw: [String]) -> VisualKindArbitrationResult {
		let kinds = raw
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		let set = Set(kinds)

		// Prefer browser/article first (common for video/social pages), then dialog, then editor/terminal.
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

	// MARK: - OCR quality (metadata-only)

	private struct OCRQuality: Equatable, Sendable {
		let isWeak: Bool
		let label: String
	}

	private static func evaluateOCRQuality(_ ocr: String) -> OCRQuality {
		let trimmed = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return OCRQuality(isWeak: true, label: "empty") }

		let chars = trimmed.count
		if chars < 40 { return OCRQuality(isWeak: true, label: "very_short") }

		// Noise proxy: if mostly non-alphanumeric, treat as weak.
		let scalars = trimmed.unicodeScalars
		var alphaNum: Int = 0
		var total: Int = 0
		for s in scalars {
			total += 1
			if CharacterSet.alphanumerics.contains(s) { alphaNum += 1 }
		}
		let ratio = total == 0 ? 0.0 : (Double(alphaNum) / Double(total))
		if ratio < 0.45 { return OCRQuality(isWeak: true, label: "noisy") }

		return OCRQuality(isWeak: false, label: "ok")
	}
}

