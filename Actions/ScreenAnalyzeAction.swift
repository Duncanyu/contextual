import Foundation

struct ScreenAnalyzeAction: ActionProtocol {
	static let analyzeScreenId = "analyze_screen"
	private static let minOCRLength = 30

	var id: String { Self.analyzeScreenId }
	var name: String { "Analyze Screen" }

	func canExecute(context: ContextModel) -> Bool {
		// Manual assistant open: user may run Analyze Screen; AppDelegate performs capture+OCR immediately before execute.
		if context.lastSourceTrigger == .manualTriggerRequested {
			return true
		}
		// Post–screen-OCR trigger: allow when an explicit OCR completion populated the model.
		guard context.lastSourceTrigger == .screenOCRCompleted else { return false }
		guard context.screenCaptureAvailable else { return false }
		guard context.screenOCRAvailable else { return false }
		return true
	}

	func execute(context: ContextModel) async -> ActionResult {
		print("[AnalyzeScreenRich] explicit=true")
		print("[AnalyzeScreenRich] refresh_started")

		// Manual rich refresh (budget-aware). Never sends screenshots to the model.
		let refreshReq = RichContextRefreshRequest(
			trigger: .manual,
			reason: "analyze_screen",
			includeWindowSnapshot: true,
			includeVisualDescriptor: true,
			includeAXContent: true,
			includeTypingActivity: true,
			includePointerActivity: true,
			allowExpensiveSources: true,
			currentContextModel: context,
			isActionExecuting: false,
			currentIntelligenceConfidence: nil
		)
		let refresh = await RichContextRefreshPipeline.shared.refresh(refreshReq)
		let fused = refresh.fusedPacket ?? CanonicalContextState.shared.current()

		let ocr = context.screenOCRText
		let ocrChars = ocr?.count ?? 0
		let ocrLines = context.screenOCRLineCount

		let built = RichAnalyzeScreenPromptBuilder.build(
			context: context,
			ocrText: ocr,
			ocrLineCount: ocrLines,
			fused: fused,
			refreshMeta: refresh.debugSummaryMetadata
		)

		let kindsLabel = built.visualKinds.isEmpty ? "none" : built.visualKinds.joined(separator: ",")
		print("[AnalyzeScreenRich] prompt_built ocrChars=\(built.ocrChars) axFragments=\(built.axFragments) visualKinds=\(kindsLabel) confidence=\(String(format: "%.2f", built.fusedConfidence))")

		let richSources = refresh.collectedSources.map(\.rawValue).joined(separator: ",")
		print("[AnalyzeScreenRich] refresh_completed sources=ocr,\(richSources)")

		// Failure behavior: if OCR is empty and fused metadata is weak, return a safe "not enough context" result.
		let hasMeaningfulOCR = (ocrChars >= Self.minOCRLength)
		let hasUsefulMeta = (built.axFragments > 0) || !built.visualKinds.isEmpty || (built.fusedFreshness >= 0.35)
		if !hasMeaningfulOCR, !hasUsefulMeta {
			print("[AnalyzeScreenRich] fallback reason=not_enough_context")
			return ActionResult(
				actionId: id,
				outputText: "I don’t have enough readable screen text or reliable metadata to analyze right now. Try again on a more text-heavy screen, or rerun after the screen finishes updating."
			)
		}

		let output = await IntelligenceActionRunner.runActionPrompt(actionType: .analyzeScreen, input: built.input)
		return ActionResult(actionId: id, outputText: output)
	}
}

