import AppKit
import Foundation

/// Resolves in-memory text for floating lifecycle similarity only (not logged, not persisted).
enum FloatingSimilarityText {
	static func material(for context: ContextModel, triggerType: TriggerType, inputPreference: InputSourceChoice) -> String {
		switch inputPreference {
		case .clipboard:
			return NSPasteboard.general.string(forType: .string) ?? ""
		case .selectedText:
			return ActionInputCapture.primaryText(for: context, minimumLength: 0, preference: .selectedText) ?? ""
		case .screenOCR:
			return context.screenOCRText ?? ""
		case .automatic:
			switch triggerType {
			case .clipboardTextEligible:
				return NSPasteboard.general.string(forType: .string) ?? ""
			case .selectedTextEligible:
				return ActionInputCapture.primaryText(for: context, minimumLength: 0, preference: .selectedText) ?? ""
			case .manualInvocation:
				return ActionInputCapture.primaryText(for: context, minimumLength: 0, preference: .automatic) ?? ""
			}
		}
	}
}
