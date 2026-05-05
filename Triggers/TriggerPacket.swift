import Foundation

enum TriggerType: String, Equatable {
	/// Clipboard has plain-text metadata meeting length rules (contents not inspected here).
	case clipboardTextEligible = "clipboard_text_eligible"
	/// Focused UI reports selected text metadata meeting length rules (contents not inspected here).
	case selectedTextEligible = "selected_text_eligible"
	/// User invoked the assistant explicitly (shortcut or UI).
	case manualInvocation = "manual_invocation"
}

struct TriggerPacket: Equatable {
	let triggerType: TriggerType
	/// Short, privacy-safe explanation (metadata only—no pasted or selected contents).
	let reason: String
	let candidateActions: [String]
	let createdAt: Date
}
