import Foundation

struct ExplainAction: ActionProtocol {
	static let explainTextId = "explain_text"
	private static let minUsefulLength = 30

	var id: String { Self.explainTextId }
	var name: String { "Explain" }

	func canExecute(context: ContextModel) -> Bool {
		let selectionUseful = context.selectedTextAvailable && context.selectedTextLength >= Self.minUsefulLength
		let clipboardUseful = context.clipboardTextAvailable && context.clipboardTextLength >= Self.minUsefulLength
		return selectionUseful || clipboardUseful
	}

	func execute(context: ContextModel) -> ActionResult {
		let selectionUseful = context.selectedTextAvailable && context.selectedTextLength >= Self.minUsefulLength
		let clipboardUseful = context.clipboardTextAvailable && context.clipboardTextLength >= Self.minUsefulLength

		let output: String
		if selectionUseful {
			output = "Explain (mock): selected text available"
		} else if clipboardUseful {
			output = "Explain (mock): clipboard text available"
		} else {
			output = "Explain (mock): nothing to explain"
		}
		return ActionResult(actionId: id, outputText: output)
	}
}
