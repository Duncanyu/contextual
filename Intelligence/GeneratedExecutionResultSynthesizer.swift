import Foundation

/// Combines primitive outputs into a single `ExecutionResult` (deterministic, metadata-safe).
enum GeneratedExecutionResultSynthesizer {

	static func synthesize(
		action: GeneratedExecutionAction,
		outputs: [ExecutionPrimitiveOutput],
		warnings: [String],
		startedAt: Date,
		completedAt: Date,
		status: ExecutionResultStatus,
		profile: WorkflowExecutionProfile? = nil,
		planningWarnings: [String] = [],
		shapedConfidence: Double? = nil
	) -> ExecutionResult {
		let style = profile?.resultCompositionStyle ?? .linear
		let sections = composeSections(outputs: outputs, style: style)

		let content = outputs.map(\.content).joined(separator: "\n\n---\n\n")
		let primitiveCodes = outputs.map(\.primitive.rawValue).joined(separator: ",")
		var allWarnings = warnings
		allWarnings.append(contentsOf: planningWarnings)

		let baseConfidence = outputs.map(\.confidence).min() ?? action.confidence
		let confidence: Double
		if let profile {
			confidence = WorkflowExecutionPlanner.clampConfidence(
				shapedConfidence ?? baseConfidence,
				context: nil,
				profile: profile,
				warnings: allWarnings
			)
		} else {
			confidence = min(1.0, max(0.05, shapedConfidence ?? baseConfidence))
		}

		var metadata: [String: String] = [
			"runtimePhase": "primitive_execution",
			"primitiveCount": String(outputs.count),
			"primitiveCodes": primitiveCodes,
			"planId": action.executionPlan.id.uuidString,
			"compositionStyle": style.rawValue,
		]
		if let profile {
			metadata["workflowType"] = profile.workflowType.rawValue
			metadata["explanationStyle"] = profile.explanationStyle.rawValue
		}
		for output in outputs {
			for (key, value) in output.metadata {
				metadata["\(output.primitive.rawValue).\(key)"] = value
			}
		}

		let followUps = workflowFollowUpSuggestions(
			workflowType: action.workflowType,
			status: status,
			primitives: outputs.map(\.primitive)
		)

		return ExecutionResult(
			actionId: action.id,
			status: status,
			startedAt: startedAt,
			completedAt: completedAt,
			generatedContent: content.isEmpty ? nil : content,
			generatedSections: sections,
			warnings: allWarnings,
			executionMetadata: metadata,
			confidence: confidence,
			followUpSuggestions: followUps
		)
	}

	// MARK: - Workflow composition

	private static func composeSections(
		outputs: [ExecutionPrimitiveOutput],
		style: ResultCompositionStyle
	) -> [ExecutionResultSection] {
		guard style != .linear else {
			return defaultSections(from: outputs)
		}

		let titles = sectionTitles(for: style)
		var sections: [ExecutionResultSection] = []
		for (index, output) in outputs.enumerated() {
			let title = titleForOutput(output, index: index, titles: titles)
			if output.sections.isEmpty {
				sections.append(ExecutionResultSection(title: title, body: output.content, order: index))
			} else {
				for part in output.sections {
					sections.append(
						ExecutionResultSection(
							id: part.id,
							title: titleForPart(part.title, fallback: title),
							body: part.body,
							order: index * 10 + part.order
						)
					)
				}
			}
		}
		return sections.isEmpty ? defaultSections(from: outputs) : sections
	}

	private static func defaultSections(from outputs: [ExecutionPrimitiveOutput]) -> [ExecutionResultSection] {
		outputs.enumerated().flatMap { index, output -> [ExecutionResultSection] in
			if output.sections.isEmpty {
				return [ExecutionResultSection(title: output.title, body: output.content, order: index)]
			}
			return output.sections.map {
				ExecutionResultSection(
					id: $0.id,
					title: $0.title,
					body: $0.body,
					order: index * 10 + $0.order
				)
			}
		}
	}

	private static func sectionTitles(for style: ResultCompositionStyle) -> [String] {
		switch style {
		case .debuggingReport:
			["Likely Cause", "What to Check", "Next Steps", "Context Summary"]
		case .researchBrief:
			["Key Points", "Comparisons", "Open Questions", "Supporting Notes"]
		case .writingOutline:
			["Structured Draft", "Checklist", "Suggested Improvements", "Summary"]
		case .studyNotes:
			["Study Notes", "Key Terms", "Review Questions", "Summary"]
		case .reviewSummary:
			["Key Points", "Comparisons", "Action Items", "Summary"]
		case .linear:
			[]
		}
	}

	private static func titleForOutput(
		_ output: ExecutionPrimitiveOutput,
		index: Int,
		titles: [String]
	) -> String {
		switch output.primitive {
		case .explainError:
			return titles.first ?? output.title
		case .answerFromContext:
			return titles.dropFirst().first ?? output.title
		case .generateChecklist:
			return titles.dropFirst(2).first ?? output.title
		case .summarizeContext:
			return titles.last ?? output.title
		case .extractActionItems:
			return titles.dropFirst(2).first ?? "Action Items"
		case .structureNotes:
			return titles.first ?? output.title
		default:
			if index < titles.count { return titles[index] }
			return output.title
		}
	}

	private static func titleForPart(_ partTitle: String, fallback: String) -> String {
		if partTitle.hasPrefix("Section ") { return fallback }
		return partTitle
	}

	// MARK: - Workflow-aware follow-up suggestions

	private static func workflowFollowUpSuggestions(
		workflowType: WorkflowType,
		status: ExecutionResultStatus,
		primitives: [ExecutionPrimitive]
	) -> [String] {
		guard status == .success || status == .partialSuccess else { return [] }
		switch workflowType {
		case .debugging:
			return ["Search for similar errors", "Add a regression test", "Check recent git changes"]
		case .research:
			return ["Compare with another source", "Export key points", "Identify open questions"]
		case .writing:
			return ["Refine the draft", "Check for gaps", "Add supporting examples"]
		case .studying, .browsing:
			return ["Test yourself on key concepts", "Take a short break and review", "Add to study notes"]
		case .reviewing:
			return ["Flag items needing revision", "Share summary with teammates", "Create action items"]
		case .editing:
			return ["Review the changes", "Check for consistency", "Save a version before finalizing"]
		case .comparing:
			return ["Note the key differences", "Export comparison", "Decide on the preferred option"]
		case .organizing:
			return ["Review the structure", "Add missing categories", "Archive completed items"]
		case .unknown:
			if primitives.contains(.explainError) {
				return ["Search for similar errors", "Check related logs"]
			}
			return ["Copy the result", "Run again with more context"]
		}
	}
}
