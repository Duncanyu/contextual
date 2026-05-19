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
		case .compareContexts, .organizeInformation, .generateStudyNotes,
		     .synthesizeResearchSummary, .classifyWorkflow:
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
		let bullets = lines.prefix(6).map { "• \($0)" }.joined(separator: "\n")
		let content = """
		Summary (\(lines.count) lines, \(context.workflowType.rawValue) workflow):
		\(bullets)
		"""
		return ExecutionPrimitiveOutput(
			primitive: .summarizeContext,
			title: "Context summary",
			content: content,
			confidence: min(action.confidence, 0.85),
			metadata: ["lineCount": String(lines.count)]
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
		let errorLines = nonEmptyLines(text).filter { line in
			let lower = line.lowercased()
			return lower.contains("error") || lower.contains("exception")
				|| lower.contains("failed") || lower.contains("fatal")
		}
		let focus = errorLines.prefix(3).joined(separator: "\n")
		let content: String
		if focus.isEmpty {
			content = """
			No explicit error markers in the bounded excerpt.
			Likely causes to inspect: recent code changes, missing permissions, or invalid input.
			"""
		} else {
			content = """
			Detected error signals:
			\(focus)

			Likely next steps: reproduce locally, check logs near these lines, verify inputs and permissions.
			"""
		}
		return ExecutionPrimitiveOutput(
			primitive: .explainError,
			title: "Error explanation",
			content: content,
			confidence: focus.isEmpty ? 0.5 : min(action.confidence, 0.82),
			metadata: ["errorLineCount": String(errorLines.count)]
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
