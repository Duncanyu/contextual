import SwiftUI

/// Static debug samples for generated execution result UI (T17.7/T17.10) — built once, display-only.
private enum GeneratedExecutionResultDebugSamples {
	static let partial = GeneratedExecutionResultPresenter.samplePresentation()
	static let failed = GeneratedExecutionResultPresenter.sampleFailedPresentation()
}

struct AssistantPanelView: View {
	@EnvironmentObject private var appState: AppState

	private var debugCtx: ContextModel { appState.debugContext }
	@State private var dismissedProposalKey: String?
	@State private var debugExpanded: Bool = false
	@State private var richContextDebugExpanded: Bool = false
	@State private var dynamicIntentDebugExpanded: Bool = false
	@State private var dynamicActionPreviewExpanded: Bool = false
	@State private var inlineAssistanceDebugExpanded: Bool = false
	@State private var visibleIntelligenceDebugExpanded: Bool = false
	@State private var generatedExecutionResultDebugExpanded: Bool = false
	@State private var dismissedVisibleGeneratedActionIds: Set<UUID> = []

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				PanelHeaderBar()
					.environmentObject(appState)

				ContextAwarenessView(summary: appState.contextAwarenessSummary)

				WorkflowContinuityDisplayView(summary: appState.workflowContinuitySummary)

				suggestionSection

				availableActionsSection

				generatedExecutionProposalsSection

				VisibleGeneratedActionsSection(
					summary: appState.dynamicActionDisplaySummary,
					dismissedIds: $dismissedVisibleGeneratedActionIds
				)

				InputPreviewView(context: debugCtx)
					.environmentObject(appState)

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
		.onChange(of: appState.dynamicActionDisplaySummary) { new in
			if new.previewItems.isEmpty {
				dismissedVisibleGeneratedActionIds.removeAll()
			}
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
					inputSourceLine: suggestionInputSourceLine(for: proposal),
					proposalContext: appState.proposalContextSummary,
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

	private var generatedExecutionProposalsSection: some View {
		Group {
			if !appState.activatedGeneratedProposals.isEmpty {
				VStack(alignment: .leading, spacing: 10) {
					SectionHeader(title: "Generated Proposals")
					VStack(alignment: .leading, spacing: 8) {
						ForEach(appState.activatedGeneratedProposals) { item in
							VStack(alignment: .leading, spacing: 4) {
								HStack {
									Text(item.title)
										.font(.subheadline.weight(.semibold))
									Spacer(minLength: 4)
									Text("Generated")
										.font(.caption2.weight(.medium))
										.foregroundStyle(.secondary)
								}
								if !item.subtitle.isEmpty {
									Text(item.subtitle)
										.font(.caption)
										.foregroundStyle(.secondary)
								}
								if !item.expectedOutputSummary.isEmpty {
									Text(item.expectedOutputSummary)
										.font(.caption2)
										.foregroundStyle(.tertiary)
										.lineLimit(2)
								}
								Button(item.source == .reusableGenerated ? "Run" : "Prepare execution") {
									appState.invokeGeneratedExecutionProposal(id: item.id)
									print("[GeneratedExecutionUI] run_requested id=\(item.id.prefix(12)) title=\(item.title.prefix(40))")
								}
								.buttonStyle(.borderedProminent)
								.frame(maxWidth: .infinity, alignment: .leading)
								.disabled(appState.isActionExecuting)
							}
							.padding(8)
							.background(Color.primary.opacity(0.04))
							.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
						}
					}
					.contextualPanelCard()
				}
			}
		}
	}

	private var availableActionsSection: some View {
		VStack(alignment: .leading, spacing: 10) {
			SectionHeader(title: "Contextual Assistance")
			VStack(alignment: .leading, spacing: 10) {
				if appState.activatedGeneratedProposals.isEmpty {
					Text(generatedProposalEmptyLine)
						.font(.caption)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
				} else {
					Text("Use Generated Proposals below when the assistant has a situational suggestion.")
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				if appState.isActionExecuting {
					Text(processingLabel)
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
			}
			.contextualPanelCard()
		}
	}

	private var generatedProposalEmptyLine: String {
		let status = appState.generatedProposalDebugStatus
		if status.attempted {
			if let reason = status.failureReason {
				return "No generated proposal — \(reason.userFacingLabel)."
			}
			if let raw = status.zeroVisibleReason, !raw.isEmpty {
				let readable = raw.replacingOccurrences(of: "_", with: " ")
				return "No generated proposal (\(readable))."
			}
		}
		return "No generated proposal yet — waiting for useful context."
	}

	// MARK: - Result / loading

	@ViewBuilder private var resultSection: some View {
		// T18.4: structured generated execution result card takes priority over raw text.
		if let presentation = appState.latestGeneratedExecutionPresentation {
			GeneratedExecutionResultView(
				presentation: presentation,
				onClear: { appState.clearGeneratedResult() }
			)
		} else if let text = appState.latestActionResult, !text.isEmpty {
			ResultView(
				isLoading: false,
				loadingTitle: "",
				resultText: text,
				actionId: appState.latestActionId,
				timestamp: appState.latestActionTimestamp,
				onClear: { appState.clearResult() }
			)
		} else if appState.isActionExecuting {
			if appState.executingActionId?.hasPrefix(GeneratedExecutionProposalActivator.generatedProposalIdPrefix) == true {
				generatedExecutionLoadingView
			} else {
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
	}

	/// Calm loading indicator for in-flight generated execution with phase label and Cancel button.
	private var generatedExecutionLoadingView: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				ProgressView().scaleEffect(0.75)
				Text(appState.generatedExecutionPhaseLabel ?? "Running generated action…")
					.font(.caption)
					.foregroundStyle(.secondary)
				Spacer()
				Button("Cancel") {
					appState.cancelGeneratedExecution()
				}
				.buttonStyle(.bordered)
				.font(.caption)
			}
			if let title = appState.executingActionTitle, !title.isEmpty, title != "Generated execution" {
				Text(title)
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.lineLimit(2)
			}
		}
		.padding(12)
		.background(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(Color(nsColor: .controlBackgroundColor))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
		)
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

	/// T18.6 — Lightweight pipeline visibility footer shown inside the debug panel.
	@ViewBuilder private var proposalVisibilityDebugFooter: some View {
		let state = appState.proposalVisibilityState
		if !state.isIdle || state.suppressedCount > 0 {
			HStack(spacing: 4) {
				Image(systemName: state.isFullySuppressed ? "eye.slash" : "eye")
					.font(.caption2)
					.foregroundStyle(state.isFullySuppressed ? Color.orange : Color.secondary)
				Text(state.debugFooterLine)
					.font(.caption2)
					.foregroundStyle(state.isFullySuppressed ? Color.orange : Color.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(.vertical, 2)
		}
	}

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
				Text(appState.generatedProposalDebugStatus.logLine)
					.font(.caption2)
					.fixedSize(horizontal: false, vertical: true)
				// T18.6 — Proposal pipeline visibility footer.
				proposalVisibilityDebugFooter
				if !appState.registeredToolActions.isEmpty {
					VStack(alignment: .leading, spacing: 6) {
						Text("Tools (debug)")
							.font(.caption.weight(.medium))
						ForEach(Array(appState.registeredToolActions.enumerated()), id: \.element.id) { _, action in
							Button(action.name) {
								appState.invokeAction(id: action.id)
							}
							.buttonStyle(.bordered)
							.frame(maxWidth: .infinity, alignment: .leading)
							.disabled(appState.isActionExecuting)
						}
					}
				}
				Text("Recent apps (max 5): \(recentList(debugCtx.recentAppNames))")
				Text("Recent triggers (max 5): \(recentList(debugCtx.recentTriggers))")

				DisclosureGroup(isExpanded: $richContextDebugExpanded) {
					RichContextDebugView(summary: appState.richContextDebugSummary)
						.padding(.top, 4)
				} label: {
					Text("Rich context (internal)")
						.font(.caption)
						.fontWeight(.medium)
				}

				DisclosureGroup(isExpanded: $dynamicIntentDebugExpanded) {
					DynamicIntentDebugView(summary: appState.dynamicIntentDebugSummary)
						.padding(.top, 4)
				} label: {
					Text("Dynamic intent (internal)")
						.font(.caption)
						.fontWeight(.medium)
				}

				DisclosureGroup(isExpanded: $dynamicActionPreviewExpanded) {
					DynamicActionPreviewView(summary: appState.dynamicActionDisplaySummary)
						.padding(.top, 4)
				} label: {
					Text("Generated actions (internal)")
						.font(.caption)
						.fontWeight(.medium)
				}

				DisclosureGroup(isExpanded: $inlineAssistanceDebugExpanded) {
					InlineAssistanceDebugView(snapshot: appState.inlineAssistanceSnapshot)
						.padding(.top, 4)
				} label: {
					Text("Inline assistance (internal)")
						.font(.caption)
						.fontWeight(.medium)
				}

				DisclosureGroup(isExpanded: $visibleIntelligenceDebugExpanded) {
					VisibleIntelligenceDebugView(summary: appState.visibleIntelligenceDebugSummary)
						.padding(.top, 4)
				} label: {
					Text("Visible intelligence (internal)")
						.font(.caption)
						.fontWeight(.medium)
				}

				DisclosureGroup(isExpanded: $generatedExecutionResultDebugExpanded) {
					VStack(alignment: .leading, spacing: 10) {
						GeneratedExecutionResultView(presentation: GeneratedExecutionResultDebugSamples.partial)
						GeneratedExecutionResultView(presentation: GeneratedExecutionResultDebugSamples.failed)
					}
					.padding(.top, 4)
				} label: {
					Text("Generated execution result (sample)")
						.font(.caption)
						.fontWeight(.medium)
				}
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

	private func suggestionInputSourceLine(for proposal: ActionProposal) -> String? {
		if !proposal.sourceCaption.isEmpty {
			return proposal.sourceCaption
		}
		if proposal.primaryActionId == ScreenAnalyzeAction.analyzeScreenId {
			return "Using screen text"
		}
		return appState.inputSourceUsageDescription(for: appState.debugContext)
	}

	private func primaryActionTitle(for actionId: String) -> String {
		if let action = appState.availableActions.first(where: { $0.id == actionId }) {
			return action.name
		}
		if let title = ActionIntentRegistry.title(for: actionId) {
			return title
		}
		return "Open"
	}
}
