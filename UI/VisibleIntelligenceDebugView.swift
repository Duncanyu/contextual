import SwiftUI

/// Internal-only consolidated view of visible intelligence decisions (T16.11). Metadata-only; no raw context.
struct VisibleIntelligenceDebugView: View {
	let summary: VisibleIntelligenceDebugSummary

	var body: some View {
		Group {
			if summary.showsVisibleIntelligenceDebug {
				VStack(alignment: .leading, spacing: 6) {
					lineRow("Top ranked", summary.topRankedAssistanceLine)
					lineRow("Generated", summary.generatedSurfacingLine)
					lineRow("Workflow", summary.workflowInfluenceLine)
					lineRow("Suppression", summary.suppressionLine)
					lineRow("Interaction", summary.interactionUsefulnessLine)
					lineRow("Proposal", summary.proposalContextLine)
					lineRow("Inline", summary.inlineAssistanceLine)
					lineRow("Screen", summary.screenSituationLine)
					if !summary.reasonCodes.isEmpty {
						Text("Reasons: \(summary.reasonCodes.joined(separator: ","))")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(2)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				Text("No visible intelligence snapshot.")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
	}

	@ViewBuilder
	private func lineRow(_ title: String, _ value: String) -> some View {
		if !value.isEmpty {
			Text("\(title): \(value)")
				.font(.caption2)
				.foregroundStyle(.tertiary)
				.lineLimit(3)
		}
	}
}
