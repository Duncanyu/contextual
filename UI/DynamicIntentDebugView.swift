import SwiftUI

/// Internal-only dynamic intent pipeline debug (metadata-only; no raw context).
struct DynamicIntentDebugView: View {
	let summary: DynamicIntentDebugSummary

	var body: some View {
		Group {
			if summary.showsDynamicDebug {
				VStack(alignment: .leading, spacing: 6) {
					Text("Dynamic Intent")
						.font(.caption2)
						.fontWeight(.semibold)
						.foregroundStyle(.secondary)
					sectionBlock(title: "Workflow", summary.workflowLine)
					sectionBlock(title: "Session", summary.sessionLine)
					listBlock(title: "Intents", summary.intentLines)
					listBlock(title: "Synthesis", summary.synthesisMetaLines)
					listBlock(title: "Suppression", summary.suppressionLines)
					listBlock(title: "Generated", summary.actionLines)
					listBlock(title: "Plans", summary.planLines)
					listBlock(title: "Safety", summary.safetyLines)
					listBlock(title: "Explainability", summary.explainLines)
					if !summary.assistanceCategorySummaryLine.isEmpty {
						VStack(alignment: .leading, spacing: 2) {
							Text("Assistance categories")
								.font(.caption2)
								.fontWeight(.medium)
								.foregroundStyle(.secondary)
							Text(summary.assistanceCategorySummaryLine)
								.font(.caption2)
								.foregroundStyle(.tertiary)
								.lineLimit(3)
						}
					}
					if !summary.rankingLine.isEmpty {
						Text("Ranking · \(summary.rankingLine)")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(3)
					}
					if !summary.interactionSummaryLine.isEmpty {
						Text(summary.interactionSummaryLine)
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(3)
					}
					if !summary.richAssistanceRankLine.isEmpty {
						Text("Rich rank · \(summary.richAssistanceRankLine)")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(3)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				Text("No dynamic intent snapshot.")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
	}

	@ViewBuilder
	private func sectionBlock(title: String, _ line: String) -> some View {
		if !line.isEmpty {
			Text("\(title): \(line)")
				.font(.caption2)
				.foregroundStyle(.tertiary)
				.lineLimit(3)
		}
	}

	@ViewBuilder
	private func listBlock(title: String, _ lines: [String]) -> some View {
		if !lines.isEmpty {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.caption2)
					.fontWeight(.medium)
					.foregroundStyle(.secondary)
				ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
					Text(line)
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.lineLimit(2)
				}
			}
		}
	}
}
