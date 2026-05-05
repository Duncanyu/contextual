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

	func execute(context: ContextModel) -> ActionResult {
		let output: String
		// Prefer selection by length first; only if selection is too short, fall back to clipboard length.
		if context.selectedTextLength >= Self.minUsefulLength {
			output = "Summary (mock): selected text available"
		} else if context.clipboardTextLength >= Self.minUsefulLength {
			output = "Summary (mock): clipboard text available"
		} else {
			output = "Nothing to summarize"
		}
		return ActionResult(actionId: id, outputText: output)
	}
}
