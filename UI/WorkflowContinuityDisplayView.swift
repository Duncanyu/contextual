import SwiftUI

/// Subtle workflow continuity line for the assistant panel (T16.8). Display-only; no actions.
struct WorkflowContinuityDisplayView: View {
	let summary: WorkflowContinuityDisplaySummary

	var body: some View {
		Group {
			if summary.isVisible, !summary.label.isEmpty {
				Text(summary.label)
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.lineLimit(2)
					.multilineTextAlignment(.leading)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.vertical, 4)
					.padding(.horizontal, 10)
					.background(
						RoundedRectangle(cornerRadius: 7, style: .continuous)
							.fill(Color(nsColor: .textBackgroundColor).opacity(0.22))
					)
					.overlay(
						RoundedRectangle(cornerRadius: 7, style: .continuous)
							.stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
					)
					.accessibilityLabel(Text("Workflow continuity"))
					.accessibilityValue(Text(summary.label))
			}
		}
	}
}
