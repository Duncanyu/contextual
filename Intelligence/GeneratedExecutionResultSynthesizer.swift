import Foundation

/// Combines primitive outputs into a single `ExecutionResult` (deterministic, metadata-safe).
enum GeneratedExecutionResultSynthesizer {

	static func synthesize(
		action: GeneratedExecutionAction,
		outputs: [ExecutionPrimitiveOutput],
		warnings: [String],
		startedAt: Date,
		completedAt: Date,
		status: ExecutionResultStatus
	) -> ExecutionResult {
		let sections = outputs.enumerated().flatMap { index, output -> [ExecutionResultSection] in
			if output.sections.isEmpty {
				return [
					ExecutionResultSection(
						title: output.title,
						body: output.content,
						order: index
					),
				]
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

		let content = outputs.map(\.content).joined(separator: "\n\n---\n\n")
		let primitiveCodes = outputs.map(\.primitive.rawValue).joined(separator: ",")
		let confidence = outputs.map(\.confidence).min() ?? action.confidence

		var metadata: [String: String] = [
			"runtimePhase": "primitive_execution",
			"primitiveCount": String(outputs.count),
			"primitiveCodes": primitiveCodes,
			"planId": action.executionPlan.id.uuidString,
		]
		for output in outputs {
			for (key, value) in output.metadata {
				metadata["\(output.primitive.rawValue).\(key)"] = value
			}
		}

		return ExecutionResult(
			actionId: action.id,
			status: status,
			startedAt: startedAt,
			completedAt: completedAt,
			generatedContent: content.isEmpty ? nil : content,
			generatedSections: sections,
			warnings: warnings,
			executionMetadata: metadata,
			confidence: confidence,
			followUpSuggestions: []
		)
	}
}
