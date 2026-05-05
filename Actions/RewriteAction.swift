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

	func execute(context: ContextModel) -> ActionResult {
		let selectionUseful = context.selectedTextAvailable && context.selectedTextLength >= Self.minUsefulLength
		let clipboardUseful = context.clipboardTextAvailable && context.clipboardTextLength >= Self.minUsefulLength

		let output: String
		if selectionUseful {
			output = "Rewrite (mock): selected text available"
		} else if clipboardUseful {
			output = "Rewrite (mock): clipboard text available"
		} else {
			output = "Rewrite (mock): nothing to rewrite"
		}
		return ActionResult(actionId: id, outputText: output)
	}
}
