import SwiftUI

// MARK: - Section chrome

struct SectionHeader: View {
	let title: String

	var body: some View {
		Text(title)
			.font(.subheadline)
			.fontWeight(.semibold)
			.foregroundStyle(.primary)
	}
}

extension View {
	/// Standard inset card for assistant panel sections.
	func contextualPanelCard(cornerRadius: CGFloat = 12) -> some View {
		padding(12)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
					.fill(Color(nsColor: .controlBackgroundColor))
			)
			.overlay(
				RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
					.stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
			)
	}
}

// MARK: - Header

struct PanelHeaderBar: View {
	@EnvironmentObject private var appState: AppState

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Contextual")
				.font(.title3)
				.fontWeight(.semibold)
			Text("Context-aware assistant")
				.font(.caption)
				.foregroundStyle(.secondary)

			HStack(spacing: 6) {
				Circle()
					.fill(appState.isPaused ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
					.frame(width: 8, height: 8)
					.accessibilityHidden(true)
				Text(appState.isPaused ? "Paused" : "Active")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
