import Foundation

struct ActionResult: Equatable {
	let actionId: String
	let outputText: String
	let executionStatus: CapabilityExecutionStatus?

	init(actionId: String, outputText: String, executionStatus: CapabilityExecutionStatus? = nil) {
		self.actionId = actionId
		self.outputText = outputText
		self.executionStatus = executionStatus
	}
}
