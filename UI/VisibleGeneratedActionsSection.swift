import SwiftUI

/// Primary-panel surface for generated actions: preview-only, visually distinct from static action buttons (T16.1).
struct VisibleGeneratedActionsSection: View {
	let summary: DynamicActionDisplaySummary
	@Binding var dismissedIds: Set<UUID>
	/// Called with the candidateId when the user taps "Prepare execution" on an executable row.
	var onExecute: ((String) -> Void)? = nil
	@State private var expandedWhyIds: Set<UUID> = []

	private var visibleRows: [DynamicActionDisplayModel] {
		VisibleGeneratedActionPanelAdapter.visiblePreviews(from: summary, excluding: dismissedIds)
	}

	var body: some View {
		Group {
			if !visibleRows.isEmpty {
				VStack(alignment: .leading, spacing: 10) {
					VStack(alignment: .leading, spacing: 4) {
						SectionHeader(title: "Suggested")
						if let label = summary.previewGroupLabel, !label.isEmpty {
							Text(label)
								.font(.caption2)
								.fontWeight(.medium)
								.foregroundStyle(.secondary)
						}
					}
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
					.onAppear {
						GeneratedActionInteractionTracker.shared.onPreviewRowsVisible(visibleRows, surface: .generatedPreview)
					}
					.onChange(of: summary.previewItems.map(\.id)) { _ in
						GeneratedActionInteractionTracker.shared.onPreviewRowsVisible(visibleRows, surface: .generatedPreview)
					}
					.onChange(of: dismissedIds) { _ in
						GeneratedActionInteractionTracker.shared.onPreviewRowsVisible(visibleRows, surface: .generatedPreview)
					}
				}
			}
		}
	}

	@ViewBuilder
	private func generatedPreviewCard(_ row: DynamicActionDisplayModel) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Text(row.category.userFacingLabel)
					.font(.caption2)
					.fontWeight(.semibold)
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(Capsule().fill(Color.accentColor.opacity(0.14)))
				if row.isExecutable {
					executionModeChip(row.executionMode)
				} else {
					Text("Preview only")
						.font(.caption2)
						.fontWeight(.medium)
						.foregroundStyle(.secondary)
				}
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
						GeneratedActionInteractionTracker.shared.recordExpanded(row: row, surface: .generatedPreview)
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
				GeneratedActionInteractionTracker.shared.recordDismissed(row: row, surface: .generatedPreview)
				VisibleGeneratedActionPanelAdapter.logDismissed(id: row.id)
			} label: {
				Text("Hide suggestion")
					.font(.caption)
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			if row.isExecutable, let candidateId = row.executionCandidateId {
				executionButton(row: row, candidateId: candidateId)
			} else {
				Button("Preview only") {}
					.buttonStyle(.bordered)
					.font(.caption)
					.disabled(true)
					.help("Generated suggestions are not executable in this build.")
			}
		}
		.padding(.vertical, 4)
	}

	// MARK: - Execution mode helpers

	/// Mode chip shown next to the category pill on executable rows.
	@ViewBuilder
	private func executionModeChip(_ mode: HookExecutionMode) -> some View {
		let (label, color): (String, Color) = {
			switch mode {
			case .one_shot:             return ("One-shot", .green)
			case .observe_once:         return ("Observe once", .blue)
			case .interactive_loop:     return ("Agentic", .purple)
			case .external_control:     return ("External control", .orange)
			case .confirmation_required: return ("Needs confirmation", .red)
			}
		}()
		Text(label)
			.font(.caption2)
			.fontWeight(.semibold)
			.foregroundStyle(color)
	}

	/// Action button whose label and enabled state reflect the execution mode.
	@ViewBuilder
	private func executionButton(row: DynamicActionDisplayModel, candidateId: String) -> some View {
		let mode = row.executionMode
		if mode.isRuntimeSupported {
			Button("Prepare execution") {
				onExecute?(candidateId)
			}
			.buttonStyle(.borderedProminent)
			.font(.caption)
			.help(mode.userFacingDescription)
		} else {
			Button("\(mode.userFacingLabel) (unsupported)") {}
				.buttonStyle(.bordered)
				.font(.caption)
				.disabled(true)
				.help("\(mode.userFacingDescription). Not yet available at runtime.")
		}
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
