import SwiftUI

/// Internal-only preview of generated actions/plans (preview-only, non-executable; metadata-only).
struct DynamicActionPreviewView: View {
	let summary: DynamicActionDisplaySummary

	var body: some View {
		Group {
			if summary.showsGeneratedPreview {
				VStack(alignment: .leading, spacing: 6) {
					Text("Generated actions (preview-only)")
						.font(.caption2)
						.fontWeight(.semibold)
						.foregroundStyle(.secondary)
					ForEach(summary.previewItems) { row in
						VStack(alignment: .leading, spacing: 2) {
							Text(row.title)
								.font(.caption2)
								.fontWeight(.medium)
								.foregroundStyle(.secondary)
								.lineLimit(2)
							Text(metaLine(for: row))
								.font(.caption2)
								.foregroundStyle(.tertiary)
								.lineLimit(2)
							if !row.primitiveLabels.isEmpty {
								Text("Primitives: \(row.primitiveLabels.joined(separator: ", "))")
									.font(.caption2)
									.foregroundStyle(.tertiary)
									.lineLimit(1)
							}
							if !row.reasonChips.isEmpty {
								Text("Chips: \(row.reasonChips.joined(separator: ", "))")
									.font(.caption2)
									.foregroundStyle(.tertiary)
									.lineLimit(2)
							}
						}
						.padding(.vertical, 2)
					}
					if !summary.blockedDebugLines.isEmpty {
						VStack(alignment: .leading, spacing: 2) {
							Text("Blocked (debug)")
								.font(.caption2)
								.fontWeight(.medium)
								.foregroundStyle(.orange.opacity(0.85))
							ForEach(Array(summary.blockedDebugLines.enumerated()), id: \.offset) { _, line in
								Text(line)
									.font(.caption2)
									.foregroundStyle(.tertiary)
									.lineLimit(2)
							}
						}
						.padding(.top, 4)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				Text("No generated action preview.")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
	}

	private func metaLine(for row: DynamicActionDisplayModel) -> String {
		[
			row.source.rawValue,
			"wf=\(row.workflowLabel)",
			"cat=\(row.category.rawValue)",
			"conf=\(row.confidenceBucket)",
			"safety=\(row.safetyBadge.rawValue)",
			row.reviewRequired ? "review=y" : "review=n",
			"intr=\(row.interruptionCostBucket)",
			"intent=\(row.sourceIntentType)"
		].joined(separator: " · ")
	}
}
