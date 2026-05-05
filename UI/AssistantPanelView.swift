import SwiftUI

struct AssistantPanelView: View {
	@EnvironmentObject private var appState: AppState

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Context Assistant")
				.font(.headline)

			Text("Assistant Running")
				.font(.subheadline)
				.foregroundStyle(.secondary)

			Toggle(appState.isPaused ? "Resume" : "Pause", isOn: $appState.isPaused)
				.toggleStyle(.switch)
		}
		.padding(16)
		.frame(width: 280)
	}
}

