import Foundation

/// Deterministic, bounded primitive execution (no shell, no code gen, no LLM in T17.3).
struct ExecutionPrimitiveRunner: Sendable {

	func run(
		primitive: ExecutionPrimitive,
		context: GeneratedExecutionContext,
		action: GeneratedExecutionAction
	) async throws -> ExecutionPrimitiveOutput {
		switch primitive {
		case .summarizeContext:
			return summarizeContext(context: context, action: action)
		case .extractActionItems:
			return extractActionItems(context: context, action: action)
		case .generateChecklist:
			return generateChecklist(context: context, action: action)
		case .explainError:
			return explainError(context: context, action: action)
		case .structureNotes:
			return structureNotes(context: context, action: action)
		case .answerFromContext:
			return answerFromContext(context: context, action: action)
		case .organizeInformation:
			return organizeInformation(context: context, action: action)
		case .generateStudyNotes:
			return generateStudyNotes(context: context, action: action)
		case .compareContexts, .synthesizeResearchSummary, .classifyWorkflow:
			throw ExecutionPrimitiveRunnerError.unsupportedPrimitive
		}
	}

	// MARK: - Implemented primitives

	private func summarizeContext(
		context: GeneratedExecutionContext,
		action: GeneratedExecutionAction
	) -> ExecutionPrimitiveOutput {
		let text = context.primarySourceText
		guard !text.isEmpty else {
			return insufficientOutput(primitive: .summarizeContext, title: "Summary")
		}
		let lines = nonEmptyLines(text)
		let app = context.appName.isEmpty ? nil : context.appName
		let title = context.windowTitle.isEmpty ? nil : context.windowTitle
		let workflow = context.workflowType.rawValue

		// Build a more descriptive header from available metadata.
		var headerParts: [String] = []
		if let app { headerParts.append(app) }
		if let title { headerParts.append("\"\(String(title.prefix(60)))\"") }
		let header = headerParts.isEmpty ? "Current context" : headerParts.joined(separator: " — ")

		let bullets = lines.prefix(7).map { "• \($0)" }.joined(separator: "\n")
		let content = """
		\(header)
		Workflow: \(workflow) · \(lines.count) line\(lines.count == 1 ? "" : "s") captured

		\(bullets)
		"""
		return ExecutionPrimitiveOutput(
			primitive: .summarizeContext,
			title: "Context summary",
			content: content,
			confidence: min(action.confidence, 0.85),
			metadata: ["lineCount": String(lines.count), "workflowType": workflow]
		)
	}

	private func extractActionItems(
		context: GeneratedExecutionContext,
		action: GeneratedExecutionAction
	) -> ExecutionPrimitiveOutput {
		let text = context.primarySourceText
		guard !text.isEmpty else {
			return insufficientOutput(primitive: .extractActionItems, title: "Action items")
		}
		let items = nonEmptyLines(text).filter { line in
			let lower = line.lowercased()
			return line.hasPrefix("-") || line.hasPrefix("•")
				|| lower.hasPrefix("todo") || lower.contains("action:")
				|| lower.range(of: #"\d+\."#, options: .regularExpression) != nil
		}
		let body: String
		if items.isEmpty {
			body = "No explicit action markers found. Review the source text for follow-ups."
		} else {
			body = items.prefix(8).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
		}
		return ExecutionPrimitiveOutput(
			primitive: .extractActionItems,
			title: "Action items",
			content: body,
			confidence: items.isEmpty ? 0.45 : min(action.confidence, 0.8),
			metadata: ["itemCount": String(items.count)]
		)
	}

	private func generateChecklist(
		context: GeneratedExecutionContext,
		action: GeneratedExecutionAction
	) -> ExecutionPrimitiveOutput {
		let text = context.primarySourceText
		guard !text.isEmpty else {
			return insufficientOutput(primitive: .generateChecklist, title: "Checklist")
		}
		let lines = nonEmptyLines(text).prefix(8)
		let checklist = lines.map { "- [ ] \($0)" }.joined(separator: "\n")
		return ExecutionPrimitiveOutput(
			primitive: .generateChecklist,
			title: "Checklist",
			content: checklist,
			confidence: min(action.confidence, 0.78),
			metadata: ["checklistItems": String(lines.count)]
		)
	}

	private func explainError(
		context: GeneratedExecutionContext,
		action: GeneratedExecutionAction
	) -> ExecutionPrimitiveOutput {
		let text = context.primarySourceText
		guard !text.isEmpty else {
			return insufficientOutput(primitive: .explainError, title: "Error explanation")
		}
		let allLines = nonEmptyLines(text)
		let errorLines = allLines.filter { line in
			let lower = line.lowercased()
			return lower.contains("error") || lower.contains("exception")
				|| lower.contains("failed") || lower.contains("fatal")
				|| lower.contains("crash") || lower.contains("assert")
				|| lower.contains("nil") || lower.contains("undefined")
		}
		let focusLines = errorLines.prefix(4)
		let contextLines = allLines.prefix(3)

		let content: String
		if focusLines.isEmpty {
			// No explicit error lines — give a diagnostic starting point from context.
			let excerpt = contextLines.map { "  \($0)" }.joined(separator: "\n")
			content = """
			No explicit error markers detected in the bounded excerpt.

			Available context:
			\(excerpt)

			Inspection checklist:
			• Review recent code changes near this location
			• Verify all required permissions are granted
			• Check for nil/optional unwrapping failures
			• Look for type mismatches or invalid input values
			• Confirm async/await patterns are correctly awaited
			"""
		} else {
			let errorBlock = focusLines.map { "  \($0)" }.joined(separator: "\n")
			content = """
			Detected error signals:
			\(errorBlock)

			Likely root causes:
			• Check the call stack leading to these lines
			• Look for unhandled optionals or force unwraps
			• Verify preconditions and guard statements nearby
			• Confirm dependencies / injected objects are non-nil

			Next steps: reproduce in isolation, add breakpoints near these lines, verify inputs.
			"""
		}
		return ExecutionPrimitiveOutput(
			primitive: .explainError,
			title: "Error analysis",
			content: content,
			confidence: focusLines.isEmpty ? 0.52 : min(action.confidence, 0.84),
			metadata: [
				"errorLineCount": String(errorLines.count),
				"totalLineCount": String(allLines.count),
			]
		)
	}

	private func structureNotes(
		context: GeneratedExecutionContext,
		action: GeneratedExecutionAction
	) -> ExecutionPrimitiveOutput {
		let text = context.primarySourceText
		guard !text.isEmpty else {
			return insufficientOutput(primitive: .structureNotes, title: "Structured notes")
		}
		let lines = nonEmptyLines(text)
		var sections: [ExecutionResultSection] = []
		for (idx, line) in lines.prefix(6).enumerated() {
			sections.append(ExecutionResultSection(title: "Section \(idx + 1)", body: line, order: idx))
		}
		let outline = sections.map { "## \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
		return ExecutionPrimitiveOutput(
			primitive: .structureNotes,
			title: "Structured notes",
			content: outline,
			sections: sections,
			confidence: min(action.confidence, 0.8),
			metadata: ["sectionCount": String(sections.count)]
		)
	}

	private func answerFromContext(
		context: GeneratedExecutionContext,
		action: GeneratedExecutionAction
	) -> ExecutionPrimitiveOutput {
		let text = context.primarySourceText
		guard !text.isEmpty else {
			return insufficientOutput(primitive: .answerFromContext, title: "Answer")
		}
		let excerpt = String(text.prefix(320))
		let content = """
		Question: \(action.title)
		Intent: \(action.intentType.rawValue)

		From bounded context (\(context.sourceType)):
		\(excerpt)
		"""
		return ExecutionPrimitiveOutput(
			primitive: .answerFromContext,
			title: "Contextual answer",
			content: content,
			confidence: min(action.confidence, 0.75),
			metadata: ["sourceType": context.sourceType]
		)
	}

	private func organizeInformation(
		context: GeneratedExecutionContext,
		action: GeneratedExecutionAction
	) -> ExecutionPrimitiveOutput {
		let text = context.primarySourceText
		guard !text.isEmpty else {
			return insufficientOutput(primitive: .organizeInformation, title: "Organized information")
		}
		let lines = nonEmptyLines(text)
		// Classify lines into categories by simple heuristics.
		var facts: [String] = []
		var questions: [String] = []
		var tasks: [String] = []
		var notes: [String] = []
		for line in lines {
			let lower = line.lowercased()
			if line.hasSuffix("?") || lower.hasPrefix("why") || lower.hasPrefix("how") || lower.hasPrefix("what") {
				questions.append(line)
			} else if lower.hasPrefix("todo") || lower.hasPrefix("- [ ]") || lower.hasPrefix("•") || lower.hasPrefix("-") {
				tasks.append(line)
			} else if lower.contains("note:") || lower.contains("important") || lower.hasPrefix("*") {
				notes.append(line)
			} else {
				facts.append(line)
			}
		}
		var parts: [String] = []
		if !facts.isEmpty {
			parts.append("Key information:\n" + facts.prefix(5).map { "  • \($0)" }.joined(separator: "\n"))
		}
		if !tasks.isEmpty {
			parts.append("Tasks / action items:\n" + tasks.prefix(5).map { "  • \($0)" }.joined(separator: "\n"))
		}
		if !questions.isEmpty {
			parts.append("Open questions:\n" + questions.prefix(4).map { "  • \($0)" }.joined(separator: "\n"))
		}
		if !notes.isEmpty {
			parts.append("Notes:\n" + notes.prefix(3).map { "  • \($0)" }.joined(separator: "\n"))
		}
		let content = parts.isEmpty ? "Insufficient structured content for organization." : parts.joined(separator: "\n\n")
		return ExecutionPrimitiveOutput(
			primitive: .organizeInformation,
			title: "Organized information",
			content: content,
			confidence: min(action.confidence, 0.80),
			metadata: [
				"factCount": String(facts.count),
				"taskCount": String(tasks.count),
				"questionCount": String(questions.count),
			]
		)
	}

	private func generateStudyNotes(
		context: GeneratedExecutionContext,
		action: GeneratedExecutionAction
	) -> ExecutionPrimitiveOutput {
		let text = context.primarySourceText
		guard !text.isEmpty else {
			return insufficientOutput(primitive: .generateStudyNotes, title: "Study notes")
		}
		let lines = nonEmptyLines(text)
		let concepts = lines.prefix(5).map { "• \($0)" }.joined(separator: "\n")
		let app = context.appName.isEmpty ? "current context" : context.appName
		let content = """
		Study notes from \(app):

		Key concepts:
		\(concepts)

		Review questions:
		• What is the main point of this material?
		• Which parts are still unclear or need more research?
		• How does this connect to what you already know?

		Next steps:
		• Re-read the parts that felt unclear
		• Make a short summary in your own words
		• Test yourself on the key concepts above
		"""
		return ExecutionPrimitiveOutput(
			primitive: .generateStudyNotes,
			title: "Study notes",
			content: content,
			confidence: min(action.confidence, 0.78),
			metadata: ["conceptCount": String(min(5, lines.count))]
		)
	}

	// MARK: - Helpers

	private func insufficientOutput(primitive: ExecutionPrimitive, title: String) -> ExecutionPrimitiveOutput {
		ExecutionPrimitiveOutput(
			primitive: primitive,
			title: title,
			content: "Insufficient bounded context for this primitive.",
			warnings: [ExecutionPrimitiveRunnerError.insufficientContext.rawValue],
			confidence: 0.35,
			metadata: [:]
		)
	}

	private func nonEmptyLines(_ text: String) -> [String] {
		text
			.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
	}
}
