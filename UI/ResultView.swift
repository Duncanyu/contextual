import AppKit
import SwiftUI

struct ResultView: View {
	let resultText: String
	let actionId: String?
	let timestamp: Date?
	let onClear: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text("Result")
					.font(.subheadline)
					.fontWeight(.semibold)

				Spacer()

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

			if let actionId {
				Text(actionId)
					.font(.caption2)
					.foregroundStyle(.secondary)
			}

			if let timestamp {
				Text(timestamp.formatted(date: .abbreviated, time: .standard))
					.font(.caption2)
					.foregroundStyle(.secondary)
			}

			ScrollView {
				Text(resultText)
					.font(.body)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(height: 160)
		}
		.padding(12)
		.background(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.fill(Color(nsColor: .controlBackgroundColor))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.stroke(Color(nsColor: .separatorColor), lineWidth: 1)
		)
	}
}

