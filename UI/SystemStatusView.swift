import AppKit
import SwiftUI

/// Readiness summary for Accessibility, Screen Recording, and Local AI. Displays state only; uses existing permission helpers.
struct SystemStatusView: View {
	@EnvironmentObject private var appState: AppState

	/// Bumps when the app becomes active so permission checks re-evaluate after returning from Settings.
	@State private var activationEpoch: Int = 0

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			SectionHeader(title: "System Status")
			VStack(alignment: .leading, spacing: 12) {
				accessibilitySection
				Divider().opacity(0.35)
				screenRecordingSection
				Divider().opacity(0.35)
				localAISection
			}
			.contextualPanelCard()
		}
		.id(activationEpoch)
		.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
			activationEpoch += 1
		}
	}

	// MARK: - Accessibility

	private var accessibilityTrusted: Bool {
		SelectionSource.isAccessibilityTrusted()
	}

	private var accessibilitySection: some View {
		VStack(alignment: .leading, spacing: 8) {
			statusTitleRow(
				icon: "accessibility",
				title: "Accessibility",
				isGood: accessibilityTrusted,
				statusText: accessibilityTrusted ? "Enabled" : "Not enabled"
			)
			if !accessibilityTrusted {
				Button("Enable Accessibility") {
					openAccessibilitySettings()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
		}
	}

	private func openAccessibilitySettings() {
		SelectionSource.requestAccessibilityPermissionIfNeeded()
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
			NSWorkspace.shared.open(url)
		}
	}

	// MARK: - Screen Recording

	private var screenRecordingAuthorized: Bool {
		ScreenCaptureSource.isScreenRecordingAuthorized()
	}

	private var screenRecordingSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			statusTitleRow(
				icon: "record.circle",
				title: "Screen Recording",
				isGood: screenRecordingAuthorized,
				statusText: screenRecordingAuthorized ? "Enabled" : "Not enabled"
			)
			if !screenRecordingAuthorized {
				Button("Enable Screen Recording") {
					ScreenCaptureSource.openScreenRecordingSettings()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
		}
	}

	// MARK: - Local AI

	@ViewBuilder private var localAISection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: "cpu")
					.foregroundStyle(.secondary)
					.frame(width: 18, alignment: .center)
				Text("Local AI")
					.font(.caption)
					.fontWeight(.medium)
				Spacer(minLength: 8)
				Circle()
					.fill(Color(nsColor: localAIDotColor))
					.frame(width: 8, height: 8)
					.accessibilityHidden(true)
				Text(localAIHeadlineStatus)
					.font(.caption)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.trailing)
					.lineLimit(3)
					.fixedSize(horizontal: false, vertical: true)
			}

			localAIDetailAndButtons
		}
	}

	private var localAIDotColor: NSColor {
		guard appState.localAIEnabled else { return .systemOrange }
		switch appState.modelRuntimeState {
		case .ready:
			return .systemGreen
		case .checking, .starting, .installing:
			return .systemOrange
		case .unavailable, .modelMissing:
			return .systemOrange
		case .notInstalled, .error:
			return .systemRed
		}
	}

	private var localAIHeadlineStatus: String {
		if !appState.localAIEnabled {
			return "Disabled"
		}
		switch appState.modelRuntimeState {
		case .ready:
			return "Running"
		case .checking:
			return "Checking…"
		case .starting:
			return "Starting…"
		case .unavailable:
			return "Unavailable"
		case .notInstalled:
			return "Not installed"
		case .installing:
			return "Downloading model…"
		case .modelMissing(let model):
			return "Model missing (\(model))"
		case .error:
			return "Error"
		}
	}

	@ViewBuilder private var localAIDetailAndButtons: some View {
		if !appState.localAIEnabled {
			Button("Enable Local AI") {
				appState.enableLocalAI()
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
		} else {
			switch appState.modelRuntimeState {
			case .notInstalled:
				Button("Open Ollama Download") {
					appState.openOllamaDownloadPage()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			case .unavailable:
				HStack(spacing: 8) {
					Button("Start Ollama") {
						appState.startOllamaNow()
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
					Button("Start automatically") {
						appState.enableAutoStartOllama()
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
				}
				Text("If Ollama is still launching, wait a few seconds or start it from the menu bar.")
					.font(.caption2)
					.foregroundStyle(.secondary)
			case .modelMissing(let model):
				VStack(alignment: .leading, spacing: 6) {
					Text("Install the configured model with Ollama, or pull it here.")
						.font(.caption2)
						.foregroundStyle(.secondary)
					Button("Download model (\(model))") {
						appState.pullLocalAIModel()
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
				}
			case .checking, .starting:
				Text("Connecting to local inference…")
					.font(.caption2)
					.foregroundStyle(.secondary)
			case .installing:
				Text("Downloading — this can take several minutes.")
					.font(.caption2)
					.foregroundStyle(.secondary)
			case .ready:
				EmptyView()
			case .error(let message):
				Text(message)
					.font(.caption2)
					.foregroundStyle(Color(nsColor: .systemRed))
					.fixedSize(horizontal: false, vertical: true)
			}

			Button("Disable Local AI") {
				appState.disableLocalAI()
			}
			.font(.caption)
			.buttonStyle(.borderless)
		}
	}

	// MARK: - Shared row chrome

	private func statusTitleRow(icon: String, title: String, isGood: Bool, statusText: String) -> some View {
		HStack(alignment: .center, spacing: 8) {
			Image(systemName: icon)
				.foregroundStyle(.secondary)
				.frame(width: 18, alignment: .center)
			Text(title)
				.font(.caption)
				.fontWeight(.medium)
			Spacer(minLength: 8)
			Circle()
				.fill(Color(nsColor: isGood ? .systemGreen : .systemOrange))
				.frame(width: 8, height: 8)
				.accessibilityHidden(true)
			Text(statusText)
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(2)
				.multilineTextAlignment(.trailing)
		}
	}
}
