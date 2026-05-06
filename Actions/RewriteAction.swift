import Foundation

struct RewriteAction: ActionProtocol {
	static let rewriteTextId = "rewrite_text"
	private static let minUsefulLength = 30

	var id: String { Self.rewriteTextId }
	var name: String { "Rewrite" }

	func canExecute(context: ContextModel) -> Bool {
		let selectionUseful = context.selectedTextAvailable && context.selectedTextLength >= Self.minUsefulLength
		let clipboardUseful = context.clipboardTextAvailable && context.clipboardTextLength >= Self.minUsefulLength
		return selectionUseful || clipboardUseful
	}

	func execute(context: ContextModel) async -> ActionResult {
		guard let input = ActionInputCapture.primaryText(for: context, minimumLength: Self.minUsefulLength) else {
			return ActionResult(actionId: id, outputText: "No usable text found")
		}
		let output = await IntelligenceActionRunner.runActionPrompt(actionType: .rewrite, input: input)
		return ActionResult(actionId: id, outputText: output)
	}
}
