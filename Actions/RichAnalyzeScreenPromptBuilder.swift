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
		let visualKinds = (refreshMeta?["visualKinds"]?.split(separator: ",").map(String.init) ?? [])

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

		let workflow = workflowHints(
			appBundle: bundle,
			visualKinds: visualKinds,
			hints: hints,
			typing: typing,
			pointer: pointer,
			freshness: freshness
		)

		let input = """
		## Active app
		- appName: \(app)
		- bundleId: \(bundle)
		- windowTitleAvailable: \(windowTitleAvailable)

		## OCR
		- ocrChars: \(ocrChars)
		- ocrLines: \(ocrLines)
		- ocrText:
		\(ocr.isEmpty ? "(none)" : ocr)

		## Visual hints (no image)
		- visualKinds: \(visualKinds.isEmpty ? "none" : visualKinds.joined(separator: ","))

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
			visualKinds: visualKinds,
			fusedFreshness: freshness,
			fusedConfidence: confidence,
			fusedConflict: conflict
		)
	}

	private static func workflowHints(
		appBundle: String,
		visualKinds: [String],
		hints: [String],
		typing: String,
		pointer: String,
		freshness: Double
	) -> [String] {
		var out: [String] = []
		if appBundle.contains("Xcode") || appBundle.contains("com.apple.dt.Xcode") {
			out.append("activeAppCategory=developer")
		}
		if visualKinds.contains("editor") || hints.contains("ax_editor_like") || hints.contains("visual_monospace_region") {
			out.append("likelyWorkflow=code_editing")
		}
		if visualKinds.contains("terminal") {
			out.append("likelyWorkflow=terminal_debugging")
		}
		if visualKinds.contains("article") || visualKinds.contains("browser") {
			out.append("likelyWorkflow=reading")
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
}

