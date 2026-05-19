import AppKit
import SwiftUI

/// Display-only card for generated execution results (T17.7).
struct GeneratedExecutionResultView: View {
	let presentation: GeneratedExecutionResultPresentation
	var onClear: (() -> Void)?

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			headerRow
			statusRow
			if !presentation.summary.isEmpty {
				Text(presentation.summary)
					.font(.callout)
					.foregroundStyle(.primary)
					.lineLimit(6)
			}
			if !presentation.warnings.isEmpty {
				warningsBlock
			}
			sectionsBlock
			if !presentation.followUpSuggestions.isEmpty {
				followUpBlock
			}
			if !presentation.metadataRows.isEmpty {
				metadataBlock
			}
		}
		.padding(12)
		.background(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(Color(nsColor: .controlBackgroundColor))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.stroke(borderColor, lineWidth: 1)
		)
	}

	private var borderColor: Color {
		presentation.isTerminalFailure
			? Color.orange.opacity(0.45)
			: Color(nsColor: .separatorColor).opacity(0.65)
	}

	private var headerRow: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text(presentation.title)
					.font(.subheadline)
					.fontWeight(.semibold)
					.lineLimit(2)
				if !presentation.subtitle.isEmpty {
					Text(presentation.subtitle)
						.font(.caption2)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
			}
			Spacer()
			if presentation.showsCopy {
				Button("Copy") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(presentation.copyText, forType: .string)
				}
				.buttonStyle(.borderless)
				.font(.caption)
			}
			if let onClear {
				Button("Clear") { onClear() }
					.buttonStyle(.borderless)
					.font(.caption)
			}
		}
	}

	private var statusRow: some View {
		HStack(spacing: 8) {
			Text(presentation.statusLabel)
				.font(.caption)
				.fontWeight(.medium)
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background(statusBadgeColor.opacity(0.18))
				.clipShape(Capsule())
			Text(presentation.confidenceLabel)
				.font(.caption2)
				.foregroundStyle(.secondary)
			if let createdAt = presentation.createdAt {
				Spacer()
				Text(createdAt.formatted(date: .omitted, time: .shortened))
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
	}

	private var statusBadgeColor: Color {
		if presentation.isTerminalFailure { return .orange }
		if presentation.statusLabel == "Completed" { return .green }
		return .accentColor
	}

	private var warningsBlock: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("Warnings")
				.font(.caption)
				.fontWeight(.medium)
				.foregroundStyle(.orange)
			ForEach(presentation.warnings, id: \.self) { warning in
				Text(warning)
					.font(.caption2)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
		}
	}

	@ViewBuilder
	private var sectionsBlock: some View {
		if presentation.sections.isEmpty {
			EmptyView()
		} else {
			VStack(alignment: .leading, spacing: 6) {
				ForEach(presentation.sections) { section in
					if section.isInitiallyExpanded {
						VStack(alignment: .leading, spacing: 4) {
							Text(section.title)
								.font(.caption)
								.fontWeight(.medium)
							sectionBody(section)
						}
					} else {
						DisclosureGroup {
							sectionBody(section)
						} label: {
							Text(section.title)
								.font(.caption)
								.fontWeight(.medium)
						}
					}
				}
			}
		}
	}

	@ViewBuilder
	private func sectionBody(_ section: GeneratedExecutionResultSectionPresentation) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			if !section.body.isEmpty {
				Text(section.body)
					.font(.caption)
					.textSelection(.enabled)
					.lineLimit(12)
			}
			ForEach(section.bullets, id: \.self) { bullet in
				Text("• \(bullet)")
					.font(.caption2)
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
		}
		.padding(.top, 4)
	}

	private var followUpBlock: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Follow-up ideas")
				.font(.caption)
				.fontWeight(.medium)
				.foregroundStyle(.secondary)
			FlowLayout(spacing: 6) {
				ForEach(presentation.followUpSuggestions, id: \.self) { suggestion in
					Text(suggestion)
						.font(.caption2)
						.padding(.horizontal, 8)
						.padding(.vertical, 4)
						.background(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
						.clipShape(Capsule())
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	private var metadataBlock: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("Execution details")
				.font(.caption2)
				.fontWeight(.medium)
				.foregroundStyle(.tertiary)
			ForEach(presentation.metadataRows, id: \.self) { row in
				Text(row)
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.lineLimit(1)
			}
		}
	}
}

/// Simple horizontal chip flow without layout risk from complex geometry.
private struct FlowLayout: Layout {
	var spacing: CGFloat = 6

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? 260
		var x: CGFloat = 0
		var y: CGFloat = 0
		var rowHeight: CGFloat = 0
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if x + size.width > width, x > 0 {
				x = 0
				y += rowHeight + spacing
				rowHeight = 0
			}
			rowHeight = max(rowHeight, size.height)
			x += size.width + spacing
		}
		return CGSize(width: width, height: y + rowHeight)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var x = bounds.minX
		var y = bounds.minY
		var rowHeight: CGFloat = 0
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if x + size.width > bounds.maxX, x > bounds.minX {
				x = bounds.minX
				y += rowHeight + spacing
				rowHeight = 0
			}
			subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
		}
	}
}
