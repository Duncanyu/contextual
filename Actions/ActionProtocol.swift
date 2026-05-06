import Foundation

/// Executable capability derived from context (registered via `ActionRouter`).
protocol ActionProtocol {
	var id: String { get }
	var name: String { get }

	func canExecute(context: ContextModel) -> Bool
	func execute(context: ContextModel) async -> ActionResult
}
