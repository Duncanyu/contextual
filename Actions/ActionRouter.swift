import Foundation

/// Maps trigger `candidateActions` identifiers to action instances. Does not execute.
struct ActionRouter {
	func matchingActions(for packet: TriggerPacket) -> [any ActionProtocol] {
		var result: [any ActionProtocol] = []
		for raw in packet.candidateActions {
			switch raw {
			case SummarizeAction.summarizeTextId:
				result.append(SummarizeAction())
			case ExplainAction.explainTextId:
				result.append(ExplainAction())
			case RewriteAction.rewriteTextId:
				result.append(RewriteAction())
			case ScreenAnalyzeAction.analyzeScreenId:
				result.append(ScreenAnalyzeAction())
			default:
				break
			}
		}
		return result
	}
}

struct DeterministicCapabilityActionSeed {
	let capabilityId: String
	let title: String
	let involvedApps: [String]
	let involvedURLs: [String]
	let browserTabTitles: [String]
	let browserAppName: String?
	let workflow: String
	let compartmentLabel: String?
	let windowTitle: String?
	let entity: String?
	let compartment: TaskCompartment?
}

struct DeterministicCapabilityPanelAction: ActionProtocol {
	let id: String
	let name: String
	private let seed: DeterministicCapabilityActionSeed

	init(seed: DeterministicCapabilityActionSeed) {
		self.id = seed.capabilityId
		self.name = SuggestionTitleRewriter.rewrite(title: seed.title, capabilityId: seed.capabilityId)
		self.seed = seed
	}

	func canExecute(context: ContextModel) -> Bool {
		let payload = LocalActionPayloadValidator.validate(
			capabilityId: seed.capabilityId,
			involvedApps: seed.involvedApps,
			involvedURLs: seed.involvedURLs,
			browserTabTitles: seed.browserTabTitles,
			compartmentLabel: seed.compartmentLabel,
			focusShortcutAvailable: seed.capabilityId == "enable_reduce_interruptions"
				? FocusShortcutDetector.detect().available
				: nil
		)
		return payload.valid
	}

	func execute(context: ContextModel) async -> ActionResult {
		guard let capability = CognitiveCapabilityRegistry.shared.get(seed.capabilityId) else {
			return ActionResult(actionId: id, outputText: "Capability unavailable.")
		}

		let status = await CapabilityExecutor.shared.execute(
			capability: capability,
			context: capabilityContext()
		)
		let outputText: String
		switch status {
		case .success:
			outputText = "\(name) completed."
		case .previewGenerated:
			outputText = "\(name) preview ready."
		case .blocked:
			outputText = "\(name) is blocked right now."
		case .unavailable:
			outputText = "\(name) is unavailable right now."
		case .cancelled:
			outputText = "\(name) was cancelled."
		case .openedSearch:
			outputText = "\(name) opened a search instead."
		}
		return ActionResult(actionId: id, outputText: outputText)
	}

	private func capabilityContext() -> [String: Any] {
		[
			"apps": seed.involvedApps,
			"tabURLs": seed.involvedURLs,
			"urls": seed.involvedURLs,
			"tabTitles": seed.browserTabTitles,
			"titles": seed.browserTabTitles,
			"browserAppName": seed.browserAppName as Any,
			"workflow": seed.workflow,
			"compartmentLabel": seed.compartmentLabel as Any,
			"windowTitle": seed.windowTitle as Any,
			"entity": seed.entity as Any,
			"compartment": seed.compartment as Any,
			"suggestionTitle": seed.title
		]
	}
}
