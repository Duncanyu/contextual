import Foundation

/// Display-only section style for generated execution results (T17.7).
enum GeneratedExecutionResultSectionStyle: String, Hashable, Sendable {
	case summary
	case detail
	case warning
	case metadata
}

/// One structured section in the generated execution result card.
struct GeneratedExecutionResultSectionPresentation: Identifiable, Equatable, Sendable {
	let id: UUID
	let title: String
	let body: String
	let bullets: [String]
	let style: GeneratedExecutionResultSectionStyle
	let isInitiallyExpanded: Bool

	init(
		id: UUID = UUID(),
		title: String,
		body: String,
		bullets: [String] = [],
		style: GeneratedExecutionResultSectionStyle = .detail,
		isInitiallyExpanded: Bool = false
	) {
		self.id = id
		self.title = title
		self.body = body
		self.bullets = bullets
		self.style = style
		self.isInitiallyExpanded = isInitiallyExpanded
	}
}

/// Stable, capped presentation model for `ExecutionResult` (no raw sensitive context).
struct GeneratedExecutionResultPresentation: Identifiable, Equatable, Sendable {
	let id: UUID
	let title: String
	let subtitle: String
	let statusLabel: String
	let confidenceLabel: String
	let summary: String
	let sections: [GeneratedExecutionResultSectionPresentation]
	let warnings: [String]
	let metadataRows: [String]
	let followUpSuggestions: [String]
	let copyText: String
	let createdAt: Date?
	let showsCopy: Bool

	init(
		id: UUID,
		title: String,
		subtitle: String,
		statusLabel: String,
		confidenceLabel: String,
		summary: String,
		sections: [GeneratedExecutionResultSectionPresentation],
		warnings: [String],
		metadataRows: [String],
		followUpSuggestions: [String],
		copyText: String,
		createdAt: Date?,
		showsCopy: Bool = true
	) {
		self.id = id
		self.title = title
		self.subtitle = subtitle
		self.statusLabel = statusLabel
		self.confidenceLabel = confidenceLabel
		self.summary = summary
		self.sections = sections
		self.warnings = warnings
		self.metadataRows = metadataRows
		self.followUpSuggestions = followUpSuggestions
		self.copyText = copyText
		self.createdAt = createdAt
		self.showsCopy = showsCopy
	}

	var isTerminalFailure: Bool {
		let lower = statusLabel.lowercased()
		return lower.contains("failed") || lower.contains("cancelled") || lower.contains("timed out")
	}
}
