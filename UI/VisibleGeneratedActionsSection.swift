import SwiftUI

/// Primary-panel surface for generated actions: preview-only, visually distinct from static action buttons (T16.1).
struct VisibleGeneratedActionsSection: View {
	let summary: DynamicActionDisplaySummary
	@Binding var dismissedIds: Set<UUID>
	@State private var expandedWhyIds: Set<UUID> = []

	private var visibleRows: [DynamicActionDisplayModel] {
		VisibleGeneratedActionPanelAdapter.visiblePreviews(from: summary, excluding: dismissedIds)
	}

	var body: some View {
		Group {
			if !visibleRows.isEmpty {
				VStack(alignment: .leading, spacing: 10) {
					SectionHeader(title: "Suggested")
					VStack(alignment: .leading, spacing: 10) {
						ForEach(visibleRows) { row in
							generatedPreviewCard(row)
						}
					}
					.padding(12)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(
						RoundedRectangle(cornerRadius: 12, style: .continuous)
							.fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
					)
					.overlay(
						RoundedRectangle(cornerRadius: 12, style: .continuous)
							.stroke(Color(nsColor: .separatorColor).opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
					)
				}
			}
		}
	}

	@ViewBuilder
	private func generatedPreviewCard(_ row: DynamicActionDisplayModel) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Text("Contextual")
					.font(.caption2)
					.fontWeight(.semibold)
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(Capsule().fill(Color.accentColor.opacity(0.14)))
				Text("Preview only")
					.font(.caption2)
					.fontWeight(.medium)
					.foregroundStyle(.secondary)
			}
			Text(row.title)
				.font(.subheadline)
				.fontWeight(.semibold)
				.foregroundStyle(.primary)
				.lineLimit(2)
			HStack(spacing: 6) {
				Text(row.workflowLabel)
					.font(.caption2)
					.foregroundStyle(.secondary)
				Text("·")
					.font(.caption2)
					.foregroundStyle(.tertiary)
				Text("confidence \(row.confidenceBucket)")
					.font(.caption2)
					.foregroundStyle(.secondary)
				Text("·")
					.font(.caption2)
					.foregroundStyle(.tertiary)
				safetyBadgeView(row)
			}
			if !row.primitiveLabels.isEmpty {
				Text(row.primitiveLabels.joined(separator: ", "))
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.lineLimit(1)
			}
			DisclosureGroup(isExpanded: Binding(
				get: { expandedWhyIds.contains(row.id) },
				set: { isOn in
					if isOn {
						expandedWhyIds.insert(row.id)
						VisibleGeneratedActionPanelAdapter.logExpanded(id: row.id)
					} else {
						expandedWhyIds.remove(row.id)
					}
				}
			)) {
				Text(VisibleGeneratedActionPanelAdapter.whyAppearedLine(for: row))
					.font(.caption2)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.top, 2)
			} label: {
				Text("Why this appeared")
					.font(.caption)
					.fontWeight(.medium)
			}
			Button {
				dismissedIds.insert(row.id)
				expandedWhyIds.remove(row.id)
				VisibleGeneratedActionPanelAdapter.logDismissed(id: row.id)
			} label: {
				Text("Hide suggestion")
					.font(.caption)
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			Button("Preview only") {}
				.buttonStyle(.bordered)
				.font(.caption)
				.disabled(true)
				.help("Generated suggestions are not executable in this build.")
		}
		.padding(.vertical, 4)
	}

	@ViewBuilder
	private func safetyBadgeView(_ row: DynamicActionDisplayModel) -> some View {
		switch row.safetyBadge {
		case .reviewRequired:
			Text("review required")
				.font(.caption2)
				.fontWeight(.semibold)
				.foregroundStyle(.orange)
		case .safeReadOnly:
			Text("read-only")
				.font(.caption2)
				.foregroundStyle(.secondary)
		case .previewOnly:
			Text("preview")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
	}
}
