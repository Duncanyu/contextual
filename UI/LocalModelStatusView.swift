import SwiftUI

/// Compact model management panel showing tier assignments, validation state, and action buttons.
/// Appears inside System Status when Local AI is enabled and ready.
struct LocalModelStatusView: View {
	@EnvironmentObject private var appState: AppState

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			// ── Tier assignments ──────────────────────────────────────────────────
			modelTierSection

			// ── Warning when no inference model selected ───────────────────────
			if appState.taskInferenceDisabled {
				noModelWarning
			}

			Divider().opacity(0.3)

			// ── Action buttons ────────────────────────────────────────────────
			actionButtons
		}
	}

	// MARK: - Tier rows

	private var modelTierSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text("Model Tiers")
					.font(.caption.weight(.medium))
					.foregroundStyle(.secondary)
				Spacer()
				Text("Two-Stage: \(appState.twoStageTaskInferenceEnabled ? "ON" : "OFF")")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(appState.twoStageTaskInferenceEnabled ? .green : .secondary)
					.padding(.horizontal, 5)
					.padding(.vertical, 2)
					.background((appState.twoStageTaskInferenceEnabled ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
			}

			// Task inference tier
			modelTierRow(
				icon: "bolt.fill",
				tierLabel: "Task Inference",
				modelName: appState.activeTaskInferenceModel ?? "— none —",
				badge: taskInferenceBadge,
				badgeColor: taskInferenceBadgeColor
			)

			// Planner/executor tier
			modelTierRow(
				icon: "brain",
				tierLabel: "Planner / Executor",
				modelName: appState.plannerModelName,
				badge: "active",
				badgeColor: .secondary
			)

			// Toggle for two-stage mode
			Toggle("Enable Two-Stage Inference", isOn: $appState.twoStageTaskInferenceEnabled)
				.toggleStyle(.checkbox)
				.font(.system(size: 10))
				.padding(.top, 2)
		}
	}

	private var taskInferenceBadge: String {
		if appState.twoStageTaskInferenceEnabled { return "two-stage" }
		if appState.taskInferenceDisabled { return "unavailable" }
		if appState.taskInferenceBatchMode { return "batch" }
		return "stream"
	}

	private var taskInferenceBadgeColor: Color {
		if appState.twoStageTaskInferenceEnabled { return .blue }
		if appState.taskInferenceDisabled { return .red }
		return .green
	}

	private func modelTierRow(
		icon: String, tierLabel: String, modelName: String, badge: String, badgeColor: Color
	) -> some View {
		HStack(spacing: 6) {
			Image(systemName: icon)
				.font(.system(size: 10))
				.foregroundStyle(.secondary)
				.frame(width: 14)
			VStack(alignment: .leading, spacing: 1) {
				Text(tierLabel)
					.font(.system(size: 9))
					.foregroundStyle(.tertiary)
				Text(modelName)
					.font(.system(size: 11, weight: .medium, design: .monospaced))
					.foregroundStyle(.primary)
					.lineLimit(1)
			}
			Spacer(minLength: 4)
			Text(badge)
				.font(.system(size: 9, weight: .semibold))
				.foregroundStyle(badgeColor)
				.padding(.horizontal, 5)
				.padding(.vertical, 2)
				.background(badgeColor.opacity(0.12), in: Capsule())
		}
	}

	// MARK: - Warning

	private var noModelWarning: some View {
		HStack(spacing: 6) {
			Image(systemName: "exclamationmark.triangle.fill")
				.font(.caption)
				.foregroundStyle(.orange)
			VStack(alignment: .leading, spacing: 1) {
				Text("No viable task inference model")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.primary)
				Text("Install qwen2.5:0.5b (390 MB) or re-run benchmark.")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		}
		.padding(8)
		.background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
	}

	// MARK: - Action buttons

	private var actionButtons: some View {
		VStack(alignment: .leading, spacing: 6) {
			if appState.taskInferenceDisabled || appState.activeTaskInferenceModel == nil {
				Button {
					appState.installRecommendedInferenceModel()
				} label: {
					Label("Install qwen2.5:0.5b (recommended)", systemImage: "arrow.down.circle")
						.font(.caption)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
				.disabled(appState.modelAuditRunning)
			}

			HStack(spacing: 8) {
				Button {
					appState.triggerModelBenchmark()
				} label: {
					if appState.modelAuditRunning {
						HStack(spacing: 4) {
							ProgressView().scaleEffect(0.6)
							Text("Benchmarking…")
						}
					} else {
						Label("Re-run Benchmark", systemImage: "speedometer")
					}
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.disabled(appState.modelAuditRunning)

				Button {
					copyInstallCommand()
				} label: {
					Label("Copy Install Command", systemImage: "doc.on.clipboard")
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.font(.caption)
			}
			.font(.caption)

			if !appState.auditDiscoveredModels.isEmpty {
				Text("Installed: \(appState.auditDiscoveredModels.joined(separator: ", "))")
					.font(.system(size: 9))
					.foregroundStyle(.tertiary)
					.lineLimit(2)
			}
		}
	}

	private func copyInstallCommand() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString("ollama pull qwen2.5:0.5b", forType: .string)
	}
}
