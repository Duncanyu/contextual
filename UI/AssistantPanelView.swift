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
	@State private var actionLibraryDebugExpanded: Bool = false
	@State private var taskInferenceStatsExpanded: Bool = false
	// Debug subsection expansion
	@State private var debugSystemExpanded: Bool = false
	@State private var debugContextExpanded: Bool = true
	@State private var debugIntelligenceExpanded: Bool = false
	@State private var debugPerformanceExpanded: Bool = false
	@State private var dismissedVisibleGeneratedActionIds: Set<UUID> = []
	@State private var dismissedGeneratedProposalIds: Set<String> = []

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				PanelHeaderBar()
					.environmentObject(appState)

				SystemStatusView()
					.environmentObject(appState)

				ContextAwarenessView(summary: appState.contextAwarenessSummary)

				WorkflowContinuityDisplayView(summary: appState.workflowContinuitySummary)

				unifiedSections

				InputPreviewView(context: debugCtx)
					.environmentObject(appState)

				resultSection

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
		.onChange(of: appState.activatedGeneratedProposals) { new in
			if new.isEmpty {
				dismissedGeneratedProposalIds.removeAll()
			}
		}
		.frame(width: 300, height: 620)
	}

	// MARK: - Suggestion

	// MARK: - Unified Sections

	@ViewBuilder private var unifiedSections: some View {
		if let decision = appState.unifiedSurfaceDecision {
			VStack(alignment: .leading, spacing: 10) {
				SectionHeader(title: "Contextual Assistance")
				VStack(alignment: .leading, spacing: 10) {
					// We display the sections in order
					ForEach(UnifiedPanelSection.allCases, id: \.rawValue) { section in
						if let actions = decision.panelSections[section], !actions.isEmpty {
							panelSectionBlock(
								title: displayTitle(for: section),
								actions: actions,
								sectionKey: section.rawValue
							)
						}
					}

					let allEmpty = decision.panelSections.values.allSatisfy { $0.isEmpty }
					if allEmpty {
						Text(generatedProposalEmptyLine)
							.font(.caption)
							.foregroundStyle(.secondary)
							.frame(maxWidth: .infinity, alignment: .leading)
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
	}

	private func displayTitle(for section: UnifiedPanelSection) -> String {
		switch section {
		case .currentTask: return "Current Task"
		case .related: return "Related"
		case .backgroundWorkspace: return "Background Workspace"
		case .system: return "System"
		case .followups: return "Follow-ups"
		case .debug: return "Debug"
		}
	}

	@ViewBuilder
	private func panelSectionBlock(title: String, actions: [UnifiedSuggestion], sectionKey: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title)
				.font(.caption2.weight(.semibold))
				.foregroundStyle(.secondary)
				.padding(.horizontal, 8)
				.padding(.top, 4)
				.onAppear {
					print("[UnifiedPanelSection] section=\(sectionKey) count=\(actions.count)")
				}
			ForEach(actions) { action in
				UnifiedSuggestionRow(suggestion: action) {
					// Phase 64 — all clicks route through the unified dispatcher.
					appState.dispatchUnifiedSuggestion(action)
				}
			}
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
		} else if let surface = appState.activePanelResultSurface {
			ResultSurfaceCardContent(surface: surface, host: .panel)
				.environmentObject(appState)
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

	@ViewBuilder
	private var debugSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Toggle("Debug Mode", isOn: Binding(
				get: { DebugMode.isEnabled },
				set: { DebugMode.isEnabled = $0 }
			))
			.toggleStyle(.switch)
			.font(.caption)
			.onAppear {
				print("[DebugUIToggle] visible=yes state=\(DebugMode.isEnabled ? "on" : "off")")
				DebugMode.logUIVisibility(component: "AssistantPanelDebugSection", visible: DebugMode.isEnabled)
			}

			if DebugMode.isEnabled {
				DisclosureGroup(isExpanded: $debugExpanded) {
					VStack(alignment: .leading, spacing: 10) {

				// ── System ────────────────────────────────────────────────────────
				DisclosureGroup(isExpanded: $debugSystemExpanded) {
					VStack(alignment: .leading, spacing: 4) {
						Text("Local AI: \(appState.localAIEnabled ? "enabled" : "disabled") · state=\(appState.modelRuntimeState.debugLabel)")
						Text("Ollama model: \(appState.activeTaskInferenceModel ?? "none") · mode=\(appState.taskInferenceBatchMode ? "batch" : "stream")")
						Text("Inference disabled: \(appState.taskInferenceDisabled)")
						Text("Planner/executor: \(appState.plannerModelName)")
						Toggle("Enable UCR diagnostics", isOn: Binding(
							get: { appState.ucrDiagnosticsEnabled },
							set: { appState.setUCRDiagnosticsEnabled($0) }
						))
						Text("Test content acquisition action: \(UCRDogfoodMode.isEnabled ? "visible" : "hidden")")
						Button("Run dogfood matrix") {
							Task { @MainActor in
								let ok = await RescueDogfoodMatrix.run()
								print("[DogfoodMatrix] ui_run ok=\(ok)")
							}
						}
						.font(.caption)
						if !appState.auditDiscoveredModels.isEmpty {
							Text("Discovered: \(appState.auditDiscoveredModels.joined(separator: ", "))")
						}
					}
					.padding(.top, 4)
				} label: {
					Text("System")
						.font(.caption.weight(.medium))
						.foregroundStyle(.primary)
				}

				Divider().opacity(0.35)

				// ── Context ───────────────────────────────────────────────────────
				DisclosureGroup(isExpanded: $debugContextExpanded) {
					VStack(alignment: .leading, spacing: 4) {
						Text("Active app: \(debugCtx.activeAppName ?? "—")")
						windowTitleDebugLine(title: debugCtx.activeWindowTitle)
						Text("Selection: available=\(debugCtx.selectedTextAvailable) length=\(debugCtx.selectedTextLength)")
						Text("Clipboard: available=\(debugCtx.clipboardTextAvailable) length=\(debugCtx.clipboardTextLength)")
						Text("Screen capture: available=\(debugCtx.screenCaptureAvailable)")
						Text("OCR: available=\(debugCtx.screenOCRAvailable) chars=\(debugCtx.screenOCRTextLength) lines=\(debugCtx.screenOCRLineCount)")
						Text("Last trigger: \(debugCtx.lastSourceTrigger?.rawValue ?? "—")")
						Text("Recent apps: \(recentList(debugCtx.recentAppNames))")
						Text("Recent triggers: \(recentList(debugCtx.recentTriggers))")

						DisclosureGroup(isExpanded: $richContextDebugExpanded) {
							RichContextDebugView(summary: appState.richContextDebugSummary)
								.padding(.top, 4)
						} label: {
							Text("Rich context (internal)")
								.font(.caption.weight(.medium))
						}
					}
					.padding(.top, 4)
				} label: {
					Text("Context")
						.font(.caption.weight(.medium))
						.foregroundStyle(.primary)
				}

				Divider().opacity(0.35)

				// ── Intelligence ──────────────────────────────────────────────────
				DisclosureGroup(isExpanded: $debugIntelligenceExpanded) {
					VStack(alignment: .leading, spacing: 4) {
						Text(appState.generatedProposalDebugStatus.logLine)
							.fixedSize(horizontal: false, vertical: true)

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

						DisclosureGroup(isExpanded: $dynamicIntentDebugExpanded) {
							DynamicIntentDebugView(summary: appState.dynamicIntentDebugSummary)
								.padding(.top, 4)
						} label: {
							Text("Dynamic intent (internal)")
								.font(.caption.weight(.medium))
						}

						DisclosureGroup(isExpanded: $dynamicActionPreviewExpanded) {
							DynamicActionPreviewView(summary: appState.dynamicActionDisplaySummary)
								.padding(.top, 4)
						} label: {
							Text("Generated actions (internal)")
								.font(.caption.weight(.medium))
						}

						DisclosureGroup(isExpanded: $inlineAssistanceDebugExpanded) {
							InlineAssistanceDebugView(snapshot: appState.inlineAssistanceSnapshot)
								.padding(.top, 4)
						} label: {
							Text("Inline assistance (internal)")
								.font(.caption.weight(.medium))
						}

						DisclosureGroup(isExpanded: $actionLibraryDebugExpanded) {
							GeneratedActionLibraryDebugView(records: appState.actionLibrarySnapshot)
								.padding(.top, 4)
						} label: {
							let eligibleCount = appState.actionLibrarySnapshot.filter { $0.reuseEligibility == .eligible }.count
							let totalCount = appState.actionLibrarySnapshot.count
							Text(totalCount > 0
								 ? "Action library (\(eligibleCount)/\(totalCount) eligible)"
								 : "Action library (tap to load)")
								.font(.caption.weight(.medium))
						}
						.onChange(of: actionLibraryDebugExpanded) { expanded in
							if expanded { appState.refreshActionLibrarySnapshot() }
						}

						if DebugMode.isEnabled {
							DisclosureGroup(isExpanded: $visibleIntelligenceDebugExpanded) {
								VisibleIntelligenceDebugView(summary: appState.visibleIntelligenceDebugSummary)
									.padding(.top, 4)
							} label: {
								Text("Visible intelligence (internal)")
									.font(.caption.weight(.medium))
							}
						}
					}
					.padding(.top, 4)
				} label: {
					Text("Intelligence")
						.font(.caption.weight(.medium))
						.foregroundStyle(.primary)
				}

				Divider().opacity(0.35)

				// ── Performance ───────────────────────────────────────────────────
				DisclosureGroup(isExpanded: $debugPerformanceExpanded) {
					VStack(alignment: .leading, spacing: 4) {
						let s = appState.taskInferenceStats
						if s.attempts == 0 {
							Text("No inference attempts recorded yet.")
						} else {
							let pct = Int(s.successRate * 100)
							Text("Success: \(pct)% · timeout: \(Int(s.timeoutRate * 100))%")
								.foregroundStyle(s.timeoutRate > 0.15 ? Color.orange : Color.secondary)
							Text("p50=\(s.p50LatencyMs)ms")
						}
						DisclosureGroup(isExpanded: $taskInferenceStatsExpanded) {
							TaskInferenceStatsDebugView(stats: appState.taskInferenceStats)
								.padding(.top, 4)
						} label: {
							Text("Task inference detail")
								.font(.caption.weight(.medium))
						}
						.onChange(of: taskInferenceStatsExpanded) { expanded in
							if expanded { appState.refreshTaskInferenceStats() }
						}
					}
					.padding(.top, 4)
					.onAppear { appState.refreshTaskInferenceStats() }
				} label: {
					let s = appState.taskInferenceStats
					let perfLabel: String = {
						if s.attempts == 0 { return "Performance" }
						return "Performance · p50=\(s.p50LatencyMs)ms · \(Int(s.successRate * 100))% ok"
					}()
					Text(perfLabel)
						.font(.caption.weight(.medium))
						.foregroundStyle(s.timeoutRate > 0.15 ? Color.orange : Color.primary)
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
			} else {
				EmptyView()
					.onAppear {
						DebugMode.logUIVisibility(component: "AssistantPanelDebugInternals", visible: false)
					}
			}
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
