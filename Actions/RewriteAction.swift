import Foundation

struct RewriteAction: ActionProtocol {
	static let rewriteTextId = "rewrite_text"
	private static let minUsefulLength = 30

	var id: String { Self.rewriteTextId }
	var name: String { "Rewrite" }

	func canExecute(context: ContextModel) -> Bool {
		ActionInputCapture.primaryText(for: context, minimumLength: Self.minUsefulLength, preference: context.actionInputSourcePreference) != nil
	}

	func execute(context: ContextModel) async -> ActionResult {
		let pref = context.actionInputSourcePreference
		guard let input = ActionInputCapture.primaryText(for: context, minimumLength: Self.minUsefulLength, preference: pref) else {
			let msg = pref == .automatic ? "No usable text found" : "That input source is not available right now."
			return ActionResult(actionId: id, outputText: msg)
		}
		let output = await IntelligenceActionRunner.runActionPrompt(actionType: .rewrite, input: input)
		return ActionResult(actionId: id, outputText: output)
	}
}
