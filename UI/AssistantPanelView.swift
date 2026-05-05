import SwiftUI

struct AssistantPanelView: View {
	@EnvironmentObject private var appState: AppState

	private var debugCtx: ContextModel { appState.debugContext }

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				Text("Context Assistant")
					.font(.headline)

				Text("Assistant Running")
					.font(.subheadline)
					.foregroundStyle(.secondary)

				Toggle(appState.isPaused ? "Resume" : "Pause", isOn: $appState.isPaused)
					.toggleStyle(.switch)

				Button("Invoke assistant") {
					appState.requestManualInvocation?()
				}

				Divider()

				Text("Debug context")
					.font(.subheadline)
					.fontWeight(.semibold)

				Group {
					Text("Active app: \(debugCtx.activeAppName ?? "—")")
					windowTitleDebugLine(title: debugCtx.activeWindowTitle)
					Text("Clipboard: available=\(debugCtx.clipboardTextAvailable) length=\(debugCtx.clipboardTextLength)")
					Text("Selection: available=\(debugCtx.selectedTextAvailable) length=\(debugCtx.selectedTextLength)")
					Text("Last trigger: \(debugCtx.lastSourceTrigger?.rawValue ?? "—")")
					Text("Recent apps (max 5): \(recentList(debugCtx.recentAppNames))")
					Text("Recent triggers (max 5): \(recentList(debugCtx.recentTriggers))")
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}
			.padding(16)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.frame(width: 300, height: 420)
	}

	@ViewBuilder
	private func windowTitleDebugLine(title: String?) -> some View {
		if let title, !title.isEmpty {
			Text("Window title: \(title)")
		} else {
			Text("Window title: unavailable")
		}
	}

	private func recentList(_ items: [String]) -> String {
		if items.isEmpty { return "—" }
		return items.joined(separator: " → ")
	}
}

