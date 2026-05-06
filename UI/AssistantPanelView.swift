import SwiftUI

struct AssistantPanelView: View {
	@EnvironmentObject private var appState: AppState

	private var debugCtx: ContextModel { appState.debugContext }
	@State private var dismissedProposalKey: String?
	@State private var debugExpanded: Bool = false

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				PanelHeaderBar()
					.environmentObject(appState)

				suggestionSection

				availableActionsSection

				InputPreviewView(context: debugCtx)

				resultSection

				SystemStatusView()
					.environmentObject(appState)

				assistantControlsSection

				debugSection
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 14)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.frame(width: 300, height: 620)
	}

	// MARK: - Suggestion

	@ViewBuilder private var suggestionSection: some View {
		if let proposal = appState.currentProposal {
			let key = appState.suggestionKey(for: proposal, context: appState.debugContext)
			if dismissedProposalKey != key, !appState.isSuggestionOnCooldown(proposal, context: appState.debugContext) {
				SuggestionCard(
					title: proposal.title,
					primaryActionTitle: primaryActionTitle(for: proposal.primaryActionId),
					dismissTitle: "Dismiss",
					primaryDisabled: appState.isActionExecuting,
					onPrimary: {
						appState.acceptCurrentProposal()
						dismissedProposalKey = key
					},
					onDismiss: {
						appState.dismissCurrentProposal()
						dismissedProposalKey = key
					}
				)
			}
		}
	}

	// MARK: - Actions

	private var availableActionsSection: some View {
		VStack(alignment: .leading, spacing: 10) {
			SectionHeader(title: "Available Actions")
			VStack(alignment: .leading, spacing: 10) {
				if appState.availableActions.isEmpty {
					Text("No actions available")
						.font(.caption)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
				} else {
					VStack(spacing: 8) {
						ForEach(Array(appState.availableActions.enumerated()), id: \.element.id) { _, action in
							Button(action.name) {
								appState.invokeAction(id: action.id)
							}
							.buttonStyle(.bordered)
							.frame(maxWidth: .infinity, alignment: .leading)
							.disabled(appState.isActionExecuting)
						}
					}
					if appState.isActionExecuting {
						Text(processingLabel)
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
			}
			.contextualPanelCard()
		}
	}

	// MARK: - Result / loading

	@ViewBuilder private var resultSection: some View {
		if let text = appState.latestActionResult, !text.isEmpty {
			ResultView(
				isLoading: false,
				loadingTitle: "",
				resultText: text,
				actionId: appState.latestActionId,
				timestamp: appState.latestActionTimestamp,
				onClear: { appState.clearResult() }
			)
		} else if appState.isActionExecuting {
			ResultView(
				isLoading: true,
				loadingTitle: processingLabel,
				resultText: "",
				actionId: appState.executingActionId,
				timestamp: nil,
				onClear: {}
			)
		}
	}

	// MARK: - Controls

	private var assistantControlsSection: some View {
		VStack(alignment: .leading, spacing: 10) {
			SectionHeader(title: "Assistant")
			VStack(alignment: .leading, spacing: 14) {
				Toggle(appState.isPaused ? "Resume" : "Pause", isOn: $appState.isPaused)
					.toggleStyle(.switch)

				Button("Invoke assistant") {
					appState.requestManualInvocation?()
				}
				.buttonStyle(.borderedProminent)
				.frame(maxWidth: .infinity)
			}
			.contextualPanelCard()
		}
	}

	// MARK: - Debug

	private var debugSection: some View {
		DisclosureGroup(isExpanded: $debugExpanded) {
			VStack(alignment: .leading, spacing: 8) {
				Text("Active app: \(debugCtx.activeAppName ?? "—")")
				windowTitleDebugLine(title: debugCtx.activeWindowTitle)
				Text("Clipboard: available=\(debugCtx.clipboardTextAvailable) length=\(debugCtx.clipboardTextLength)")
				Text("Selection: available=\(debugCtx.selectedTextAvailable) length=\(debugCtx.selectedTextLength)")
				Text("Screen capture: available=\(debugCtx.screenCaptureAvailable)")
				Text("OCR: available=\(debugCtx.screenOCRAvailable) chars=\(debugCtx.screenOCRTextLength) lines=\(debugCtx.screenOCRLineCount)")
				Text("Last trigger: \(debugCtx.lastSourceTrigger?.rawValue ?? "—")")
				Text("Recent apps (max 5): \(recentList(debugCtx.recentAppNames))")
				Text("Recent triggers (max 5): \(recentList(debugCtx.recentTriggers))")
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.top, 6)
		} label: {
			Text("Debug Context")
				.font(.subheadline)
				.fontWeight(.semibold)
		}
		.padding(12)
		.background(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
		)
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

	private var processingLabel: String {
		if let t = appState.executingActionTitle, !t.isEmpty {
			return "Processing \(t)…"
		}
		return "Processing…"
	}

	private func primaryActionTitle(for actionId: String) -> String {
		if let action = appState.availableActions.first(where: { $0.id == actionId }) {
			return action.name
		}
		switch actionId {
		case "summarize_text":
			return "Summarize"
		case "explain_text":
			return "Explain"
		case "rewrite_text":
			return "Rewrite"
		default:
			return "Open"
		}
	}
}
