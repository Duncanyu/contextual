import Foundation

/// Deterministic, human-readable titles for reusable/generated proposals (no enum/signature leakage).
enum GeneratedProposalTitleSynthesizer {

	static func needsRepair(title: String, templateId: String) -> Bool {
		let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.isEmpty { return true }
		if t == "Reusable action" { return true }
		if t.hasPrefix("Reusable template (") { return true }
		// Raw signature leakage patterns (e.g. "unknown|structure|summarize_context|none|v1")
		if t.contains("|v") || t.contains("unknown|") || t.contains("browsing|")
			|| t.contains("research|") || t.contains("debugging|") || t.contains("studying|")
		{
			return true
		}
		if t.contains(templateId) { return true }
		// Earlier fallback format: "(unknown) ...", "(browsing) ..."
		if t.hasPrefix("("), t.contains(")") {
			let lower = t.lowercased()
			if lower.hasPrefix("(unknown)") || lower.hasPrefix("(browsing)") || lower.hasPrefix("(research)")
				|| lower.hasPrefix("(debugging)") || lower.hasPrefix("(studying)")
			{
				return true
			}
		}
		return false
	}

	static func synthesize(
		workflowType: WorkflowType,
		intentType: IntentType,
		primitiveSignature: String,
		requiredContextTypes: [ContextRequirementType],
		metadata: [String: String]
	) -> (title: String, description: String) {
		let requiresVisual = metadata["requires_visual"] == "1"
		let requiresOCR = metadata["requires_ocr"] == "1"
		let primaryPrimitive = primitiveSignature
			.split(separator: ",")
			.first
			.map(String.init)
			.flatMap { ExecutionPrimitive(rawValue: $0) }

		let required = Set(requiredContextTypes.filter { $0 != .none })

		// Visual-aware titles (execution-scoped).
		if requiresVisual || requiresOCR {
			switch workflowType {
			case .browsing, .research:
				return (
					title: "Gather sparse visual context for this page",
					description: "Take one bounded visual peek (optional OCR) to clarify what’s on-screen."
				)
			case .studying:
				return (
					title: "Inspect visible slide or page structure",
					description: "Take one bounded visual peek (optional OCR) to capture structure/headings."
				)
			case .debugging:
				return (
					title: "Analyze visible debugging state",
					description: "Take one bounded visual peek (optional OCR) to capture visible debug signals."
				)
			default:
				return (
					title: "Take a bounded visual peek",
					description: "Collect minimal on-screen signals (optional OCR) to improve context."
				)
			}
		}

		// Non-visual, workflow-aware titles.
		switch (workflowType, primaryPrimitive) {
		case (.browsing, .some(.extractActionItems)):
			return (
				title: "Extract key signals from this page",
				description: "Identify notable points, requirements, or action items from the current page context."
			)
		case (.research, .some(.extractActionItems)):
			return (
				title: "Extract useful research questions",
				description: "Turn the current context into specific questions and follow-ups to investigate."
			)
		case (.research, .some(.synthesizeResearchSummary)):
			return (
				title: "Create a source-review checklist",
				description: "Generate a checklist for evaluating credibility, claims, and next steps."
			)
		case (.debugging, .some(.explainError)):
			return (
				title: "Trace likely issue from the current context",
				description: "Identify likely causes and missing context needed to debug effectively."
			)
		case (.debugging, .some(.generateChecklist)):
			return (
				title: "Create a debugging checklist",
				description: "Generate a short checklist of debugging steps tailored to this situation."
			)
		case (.studying, .some(.generateStudyNotes)):
			return (
				title: "Create study notes from this learning context",
				description: "Generate structured notes and a shortlist of topics to revisit."
			)
		case (.studying, .some(.structureNotes)):
			return (
				title: "Structure notes from the current material",
				description: "Organize the current context into sections and a clear outline."
			)
		case (.writing, .some(.organizeInformation)), (.editing, .some(.organizeInformation)):
			return (
				title: "Organize this text or document",
				description: "Create a structured outline and next-step checklist from the current context."
			)
		case (_, .some(.classifyWorkflow)):
			return (
				title: "Classify the current workflow",
				description: "Decide what kind of work this is (debugging, research, writing, etc.)."
			)
		case (_, .some(.answerFromContext)):
			return (
				title: "Identify what context is needed",
				description: "Determine what additional information would make a good next action possible."
			)
		case (_, .some(.compareContexts)):
			return (
				title: "Create a comparison plan",
				description: "Lay out what to compare, what signals matter, and the output structure."
			)
		case (_, .some(.structureNotes)):
			return (
				title: "Structure this information",
				description: "Organize the current context into a clear structure."
			)
		case (_, .some(.generateChecklist)):
			return (
				title: "Generate a checklist for this task",
				description: "Create a short, bounded checklist appropriate to the current workflow."
			)
		default:
			// Safe fallback: avoid leaking signatures; keep human-readable.
			let contextHint: String = {
				if required.contains(.selectedText) { return " from selected text" }
				if required.contains(.textSnippet) { return " from available text" }
				if required.contains(.workflowContext) { return " from workflow context" }
				return ""
			}()
			let wf = workflowType == .unknown ? "current" : workflowType.rawValue.replacingOccurrences(of: "_", with: " ")
			return (
				title: "Prepare a next step for the \(wf) workflow\(contextHint)",
				description: "Generate a bounded, workflow-specific next action using available context."
			)
		}
	}
}

