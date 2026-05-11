import SwiftUI

/// Subtle fused-context awareness row (metadata chips only; no collection).
struct ContextAwarenessView: View {
	let summary: ContextAwarenessSummary

	var body: some View {
		Group {
			if summary.showsInPanel {
				Text("Context: \(summary.chipsJoined)")
					.font(.caption2)
					.foregroundStyle(.secondary)
					.lineLimit(2)
					.multilineTextAlignment(.leading)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.vertical, 5)
					.padding(.horizontal, 10)
					.background(
						RoundedRectangle(cornerRadius: 8, style: .continuous)
							.fill(Color(nsColor: .textBackgroundColor).opacity(0.32))
					)
					.overlay(
						RoundedRectangle(cornerRadius: 8, style: .continuous)
							.stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
					)
			}
		}
	}
}
