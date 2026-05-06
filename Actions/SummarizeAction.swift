import Foundation

struct SummarizeAction: ActionProtocol {
	static let summarizeTextId = "summarize_text"
	private static let minUsefulLength = 30

	var id: String { Self.summarizeTextId }
	var name: String { "Summarize" }

	func canExecute(context: ContextModel) -> Bool {
		let selectionUseful = context.selectedTextAvailable && context.selectedTextLength >= Self.minUsefulLength
		let clipboardUseful = context.clipboardTextAvailable && context.clipboardTextLength >= Self.minUsefulLength
		return selectionUseful || clipboardUseful
	}

	func execute(context: ContextModel) async -> ActionResult {
		guard let input = ActionInputCapture.primaryText(for: context, minimumLength: Self.minUsefulLength) else {
			return ActionResult(actionId: id, outputText: "No usable text found")
		}
		let output = await IntelligenceActionRunner.runActionPrompt(actionType: .summarize, input: input)
		return ActionResult(actionId: id, outputText: output)
	}
}
