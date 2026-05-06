import AppKit
import SwiftUI

struct ResultView: View {
	/// When true, shows a compact loading state in the result card (no copy/clear).
	var isLoading: Bool = false
	/// Shown when `isLoading` (e.g. "Processing Summarize…").
	var loadingTitle: String = ""
	let resultText: String
	let actionId: String?
	let timestamp: Date?
	let onClear: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text(isLoading ? "Working" : "Result")
					.font(.subheadline)
					.fontWeight(.semibold)

				Spacer()

				if !isLoading {
					Button("Copy") {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(resultText, forType: .string)
					}
					.buttonStyle(.borderless)
					.font(.caption)

					Button("Clear") {
						onClear()
					}
					.buttonStyle(.borderless)
					.font(.caption)
				}
			}

			if let actionId {
				Text(actionId)
					.font(.caption2)
					.foregroundStyle(.secondary)
			}

			if let timestamp, !isLoading {
				Text(timestamp.formatted(date: .abbreviated, time: .standard))
					.font(.caption2)
					.foregroundStyle(.secondary)
			}

			if isLoading {
				HStack(alignment: .center, spacing: 8) {
					ProgressView()
						.controlSize(.small)
						.scaleEffect(0.85)
					Text(loadingTitle.isEmpty ? "Processing…" : loadingTitle)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.frame(height: 160)
			} else {
				ScrollView {
					Text(resultText)
						.font(.body)
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.frame(height: 160)
			}
		}
		.padding(12)
		.background(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(Color(nsColor: .controlBackgroundColor))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
		)
	}
}

