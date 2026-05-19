import Foundation

/// Converts execution results into UI-safe presentation models (no AI, no runtime).
enum GeneratedExecutionResultPresenter {

	enum Limits {
		static let maxSummary = 420
		static let maxSectionBody = 900
		static let maxSections = 8
		static let maxBulletsPerSection = 6
		static let maxCopyText = 4_000
		static let maxMetadataRows = 6
		static let maxWarnings = 6
	}

	static func makePresentation(
		from result: ExecutionResult,
		action: GeneratedExecutionAction? = nil
	) -> GeneratedExecutionResultPresentation {
		let title = cap(action?.title ?? "Generated execution", max: 100)
		let statusLabel = statusLabel(for: result.status)
		let confidenceLabel = "Confidence \(Int((result.confidence * 100).rounded()))%"
		let subtitle = buildSubtitle(result: result, action: action)
		let summary = buildSummary(result: result, action: action)
		let sections = buildSections(result: result)
		let warnings = result.warnings.prefix(Limits.maxWarnings).map { capLine($0) }
		let metadataRows = safeMetadataRows(from: result.executionMetadata)
		let followUps = result.followUpSuggestions.map { capLine($0) }
		let copyText = buildCopyText(
			title: title,
			status: statusLabel,
			summary: summary,
			sections: sections,
			warnings: Array(warnings)
		)

		return GeneratedExecutionResultPresentation(
			id: result.id,
			title: title,
			subtitle: subtitle,
			statusLabel: statusLabel,
			confidenceLabel: confidenceLabel,
			summary: summary,
			sections: sections,
			warnings: Array(warnings),
			metadataRows: metadataRows,
			followUpSuggestions: followUps,
			copyText: copyText,
			createdAt: result.completedAt ?? result.startedAt,
			showsCopy: !copyText.isEmpty
		)
	}

	// MARK: - Sample (debug preview only)

	static func samplePresentation() -> GeneratedExecutionResultPresentation {
		let actionId = UUID()
		let action = GeneratedExecutionAction(
			id: actionId,
			title: "Summarize debugging context",
			description: "Sample generated execution",
			workflowType: .debugging,
			intentType: .explain,
			confidence: 0.82,
			interruptionCost: 0.2,
			requiredContextTypes: [.textSnippet],
			executionPlan: ExecutionPlan(
				primitives: [.explainError, .summarizeContext],
				estimatedCost: 0.3,
				estimatedRuntime: 12,
				requiresVision: false,
				requiresOCR: false,
				requiresUserIntent: false,
				requiredPermissions: [.none],
				fallbackBehavior: .failFast,
				executionBudget: .conservative,
				planConfidence: 0.75
			),
			explainabilitySummary: "sample",
			generationSource: .selfTest,
			createdAt: Date(),
			expirationDate: Date().addingTimeInterval(300),
			isReusable: true,
			reuseScore: 0.7
		)
		let result = ExecutionResult(
			actionId: action.id,
			status: .partialSuccess,
			startedAt: Date().addingTimeInterval(-8),
			completedAt: Date(),
			generatedContent: "Detected error signals in the bounded excerpt.",
			generatedSections: [
				ExecutionResultSection(title: "Likely Cause", body: "Missing nil check before access.", order: 0),
				ExecutionResultSection(title: "What to Check", body: "Validate optional binding around line 42.", order: 1),
			],
			warnings: ["primitive_execution_not_implemented"],
			executionMetadata: [
				"runtimePhase": "primitive_execution",
				"primitiveCount": "2",
				"workflowType": "debugging",
				"compositionStyle": "debugging_report",
			],
			confidence: 0.78,
			followUpSuggestions: ["Review logs", "Add regression test"]
		)
		return makePresentation(from: result, action: action)
	}

	static func sampleFailedPresentation() -> GeneratedExecutionResultPresentation {
		let action = GeneratedExecutionAction(
			title: "Compare research notes",
			description: "Failed sample",
			workflowType: .research,
			intentType: .compare,
			confidence: 0.5,
			interruptionCost: 0.3,
			requiredContextTypes: [.multiSource],
			executionPlan: ExecutionPlan(
				primitives: [.compareContexts],
				estimatedCost: 0.4,
				estimatedRuntime: 20,
				requiresVision: false,
				requiresOCR: false,
				requiresUserIntent: true,
				requiredPermissions: [.none],
				fallbackBehavior: .failFast,
				executionBudget: .conservative,
				planConfidence: 0.5
			),
			explainabilitySummary: "sample",
			generationSource: .selfTest,
			createdAt: Date(),
			expirationDate: Date().addingTimeInterval(60),
			isReusable: false,
			reuseScore: 0
		)
		let result = ExecutionResult(
			actionId: action.id,
			status: .failed,
			startedAt: Date().addingTimeInterval(-4),
			completedAt: Date(),
			generatedContent: nil,
			generatedSections: [],
			warnings: ["missing_required_context", "budget_exceeded"],
			executionMetadata: ["runtimePhase": "failed"],
			confidence: 0.4,
			followUpSuggestions: []
		)
		return makePresentation(from: result, action: action)
	}

	static func runSelfTest() -> Bool {
		let sample = samplePresentation()
		guard !sample.summary.isEmpty, !sample.sections.isEmpty else { return false }
		guard sample.copyText.contains(sample.title) else { return false }
		guard sampleFailedPresentation().isTerminalFailure else { return false }
		guard sample.copyText.count <= Limits.maxCopyText else { return false }
		return true
	}

	// MARK: - Internals

	static func capLine(_ text: String) -> String {
		cap(text.trimmingCharacters(in: .whitespacesAndNewlines), max: 200)
	}

	static func cap(_ text: String, max: Int) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count > max else { return trimmed }
		return String(trimmed.prefix(max)) + "…"
	}

	private static func statusLabel(for status: ExecutionResultStatus) -> String {
		switch status {
		case .pending: "Pending"
		case .success: "Completed"
		case .partialSuccess: "Partial success"
		case .failed: "Failed"
		case .cancelled: "Cancelled"
		case .timedOut: "Timed out"
		}
	}

	private static func buildSubtitle(
		result: ExecutionResult,
		action: GeneratedExecutionAction?
	) -> String {
		var parts: [String] = []
		if let action {
			parts.append(action.workflowType.rawValue)
			parts.append(action.intentType.rawValue)
		}
		if let count = result.executionMetadata["primitiveCount"] {
			parts.append("\(count) primitives")
		}
		if !result.warnings.isEmpty {
			parts.append("\(result.warnings.count) warnings")
		}
		return parts.isEmpty ? "Generated execution" : parts.joined(separator: " · ")
	}

	private static func buildSummary(
		result: ExecutionResult,
		action: GeneratedExecutionAction?
	) -> String {
		if let content = result.generatedContent?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
			return cap(content, max: Limits.maxSummary)
		}
		switch result.status {
		case .failed:
			return "Execution did not complete successfully."
		case .cancelled:
			return "Execution was cancelled before completion."
		case .timedOut:
			return "Execution timed out before completion."
		case .partialSuccess:
			return "Execution completed with partial results."
		default:
			return action?.description.cap(length: Limits.maxSummary) ?? "Execution finished."
		}
	}

	private static func buildSections(result: ExecutionResult) -> [GeneratedExecutionResultSectionPresentation] {
		var sections = result.generatedSections
			.sorted { $0.order < $1.order }
			.prefix(Limits.maxSections)
			.map { section in
				GeneratedExecutionResultSectionPresentation(
					id: section.id,
					title: cap(section.title, max: 80),
					body: cap(section.body, max: Limits.maxSectionBody),
					bullets: [],
					style: .detail,
					isInitiallyExpanded: false
				)
			}

		if sections.isEmpty, let content = result.generatedContent, !content.isEmpty {
			sections = [
				GeneratedExecutionResultSectionPresentation(
					title: "Output",
					body: cap(content, max: Limits.maxSectionBody),
					style: .summary,
					isInitiallyExpanded: true
				),
			]
		}
		return Array(sections)
	}

	private static func safeMetadataRows(from metadata: [String: String]) -> [String] {
		let allowedKeys = [
			"runtimePhase", "primitiveCount", "primitiveCodes", "workflowType",
			"compositionStyle", "explanationStyle", "planId",
		]
		return allowedKeys.compactMap { key in
			guard let value = metadata[key] else { return nil }
			return "\(key): \(cap(value, max: 80))"
		}.prefix(Limits.maxMetadataRows).map { $0 }
	}

	private static func buildCopyText(
		title: String,
		status: String,
		summary: String,
		sections: [GeneratedExecutionResultSectionPresentation],
		warnings: [String]
	) -> String {
		var lines: [String] = [title, status, "", summary]
		for section in sections {
			lines.append("")
			lines.append(section.title)
			if !section.body.isEmpty { lines.append(section.body) }
			for bullet in section.bullets {
				lines.append("• \(bullet)")
			}
		}
		if !warnings.isEmpty {
			lines.append("")
			lines.append("Warnings")
			warnings.forEach { lines.append("• \($0)") }
		}
		return cap(lines.joined(separator: "\n"), max: Limits.maxCopyText)
	}
}

private extension String {
	func cap(length: Int) -> String {
		GeneratedExecutionResultPresenter.cap(self, max: length)
	}
}
