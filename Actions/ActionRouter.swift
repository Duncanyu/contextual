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
	let candidateID: String
	let proposalID: String
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
	let targetContract: ActionTargetContract?
}

struct DeterministicCapabilityPanelAction: ActionProtocol {
	let id: String
	let name: String
	private let seed: DeterministicCapabilityActionSeed
	let proposalID: String

	init(seed: DeterministicCapabilityActionSeed) {
		self.id = seed.candidateID
		self.name = SuggestionTitleRewriter.rewrite(title: seed.title, capabilityId: seed.capabilityId)
		self.seed = seed
		self.proposalID = seed.proposalID
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
		return await execute(context: context, sourceSurface: "panel")
	}

	func execute(context: ContextModel, sourceSurface: String) async -> ActionResult {
		guard let capability = CognitiveCapabilityRegistry.shared.get(seed.capabilityId) else {
			print("[ExecutorAvailability] capability=\(seed.capabilityId) available=no executor=missing reason=not_in_registry")
			return ActionResult(actionId: id, outputText: "Capability unavailable.")
		}

		let status = await CapabilityExecutor.shared.execute(
			capability: capability,
			context: capabilityContext(sourceSurface: sourceSurface, contextModel: context)
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
		case .partial:
			outputText = "\(name) completed with partial results."
		case .alreadySatisfied:
			outputText = "\(name) was already done."
		}
		return ActionResult(actionId: id, outputText: outputText, executionStatus: status)
	}

	var capabilityId: String { seed.capabilityId }
	var candidateID: String { seed.candidateID }
	var targetContract: ActionTargetContract? { seed.targetContract }
	var contractID: String? { seed.targetContract?.contractID }

	private func capabilityContext(sourceSurface: String, contextModel: ContextModel? = nil) -> [String: Any] {
		var ctx: [String: Any] = [
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
			"suggestionTitle": seed.title,
			"targetContract": seed.targetContract as Any,
			"candidate_id": seed.candidateID,
			"source_surface": sourceSurface,
			"proposal_id": proposalID
		]
		// Phase 42 — Include selection availability from ContextModel so executors can decide strategy.
		if let cm = contextModel {
			ctx["selectedTextAvailable"] = cm.selectedTextAvailable
			ctx["selectedTextLength"] = cm.selectedTextLength
		}
		return ctx
	}
}
