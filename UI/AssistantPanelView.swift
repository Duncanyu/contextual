import SwiftUI

struct AssistantPanelView: View {
	@EnvironmentObject private var appState: AppState

	private var debugCtx: ContextModel { appState.debugContext }

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				Text("Context Assistant")
					.font(.headline)

				if let proposal = appState.currentProposal {
					let primaryId = proposal.primaryActionId
					let primaryName = appState.availableActions.first(where: { $0.id == primaryId })?.name ?? "Run"

					SuggestionCard(
						proposal: proposal,
						primaryButtonTitle: primaryName
					)
					.onAppear {
						print("[SuggestionCard] rendering proposal primary=\(primaryId)")
					}
				}

				Text("Assistant Running")
					.font(.subheadline)
					.foregroundStyle(.secondary)

				Toggle(appState.isPaused ? "Resume" : "Pause", isOn: $appState.isPaused)
					.toggleStyle(.switch)

				Button("Invoke assistant") {
					appState.requestManualInvocation?()
				}

				Divider()

				Text("AI Setup")
					.font(.subheadline)
					.fontWeight(.semibold)

				Group {
					if !appState.localAIEnabled {
						Text("Local AI is disabled")
							.font(.caption)
							.foregroundStyle(.secondary)
						Button("Enable Local AI") {
							appState.enableLocalAI()
						}
					} else {
						switch appState.modelRuntimeState {
						case .notInstalled:
							Text("Ollama is not installed")
								.font(.caption)
								.foregroundStyle(.secondary)
							Button("Open Ollama Download") {
								appState.openOllamaDownloadPage()
							}
						case .notRunning:
							Text("Ollama is installed but not running")
								.font(.caption)
								.foregroundStyle(.secondary)
							HStack(spacing: 8) {
								Button("Start Ollama") {
									appState.startOllamaNow()
								}
								Button("Start automatically in the future") {
									appState.enableAutoStartOllama()
								}
							}
						case .installing:
							Text("Setting up local AI...")
								.font(.caption)
								.foregroundStyle(.secondary)
						case .ready:
							Text("Local AI ready")
								.font(.caption)
								.foregroundStyle(.secondary)
						case .error(let message):
							Text("Local AI setup error: \(message)")
								.font(.caption)
								.foregroundStyle(.secondary)
						}

						Button("Disable Local AI") {
							appState.disableLocalAI()
						}
						.font(.caption)
					}
				}

				Divider()

				Text("Available Actions")
					.font(.subheadline)
					.fontWeight(.semibold)

				if appState.availableActions.isEmpty {
					Text("No actions available")
						.font(.caption)
						.foregroundStyle(.secondary)
				} else {
					ForEach(Array(appState.availableActions.enumerated()), id: \.element.id) { _, action in
						Button(action.name) {
							appState.invokeAction(id: action.id)
						}
					}
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
		.frame(width: 300, height: 620)
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

