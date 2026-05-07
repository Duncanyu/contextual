import Foundation

struct SummarizeAction: ActionProtocol {
	static let summarizeTextId = "summarize_text"
	private static let minUsefulLength = 30

	var id: String { Self.summarizeTextId }
	var name: String { "Summarize" }

	func canExecute(context: ContextModel) -> Bool {
		ActionInputCapture.primaryText(for: context, minimumLength: Self.minUsefulLength, preference: context.actionInputSourcePreference) != nil
	}

	func execute(context: ContextModel) async -> ActionResult {
		let pref = context.actionInputSourcePreference
		guard let input = ActionInputCapture.primaryText(for: context, minimumLength: Self.minUsefulLength, preference: pref) else {
			let msg = pref == .automatic ? "No usable text found" : "That input source is not available right now."
			return ActionResult(actionId: id, outputText: msg)
		}
		let output = await IntelligenceActionRunner.runActionPrompt(actionType: .summarize, input: input)
		return ActionResult(actionId: id, outputText: output)
	}
}
