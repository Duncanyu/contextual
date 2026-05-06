import Foundation

struct ScreenAnalyzeAction: ActionProtocol {
	static let analyzeScreenId = "analyze_screen"
	private static let minOCRLength = 30

	var id: String { Self.analyzeScreenId }
	var name: String { "Analyze Screen" }

	func canExecute(context: ContextModel) -> Bool {
		guard context.screenCaptureAvailable else { return false }
		guard context.screenOCRAvailable else { return false }
		guard let text = context.screenOCRText, text.count >= Self.minOCRLength else { return false }
		return true
	}

	func execute(context: ContextModel) async -> ActionResult {
		guard let ocr = context.screenOCRText, ocr.count >= Self.minOCRLength else {
			return ActionResult(
				actionId: id,
				outputText: "I couldn’t read enough text from the screen yet. Try opening a text-heavy screen and invoking screen analysis again."
			)
		}

		let app = context.activeAppName ?? "Unknown app"
		let title = context.activeWindowTitle ?? "Unknown window"

		let input = """
		App: \(app)
		Window: \(title)

		OCR text:
		\(ocr)
		"""

		let output = await IntelligenceActionRunner.runActionPrompt(actionType: .analyzeScreen, input: input)
		return ActionResult(actionId: id, outputText: output)
	}
}

