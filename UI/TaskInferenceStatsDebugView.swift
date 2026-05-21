import SwiftUI

/// Read-only debug view showing rolling TaskInference performance stats in the debug panel.
struct TaskInferenceStatsDebugView: View {
	let stats: TaskInferenceRollingStats

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			if stats.attempts == 0 {
				Text("No inference attempts recorded yet.")
					.font(.caption2)
					.foregroundStyle(.secondary)
			} else {
				statsBody
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var statsBody: some View {
		VStack(alignment: .leading, spacing: 6) {
			// Model
			HStack {
				Text("Model:").fontWeight(.medium)
				Text(stats.currentModel)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.font(.caption2)

			// Counts row
			HStack(spacing: 10) {
				statCell("Attempts", "\(stats.attempts)")
				statCell("✓", "\(stats.successCount)", color: .green)
				statCell("⏱", "\(stats.timeoutCount)", color: stats.timeoutCount > 0 ? .orange : .secondary)
				statCell("✗", "\(stats.malformedCount)", color: stats.malformedCount > 0 ? .red : .secondary)
				statCell("↩", "\(stats.cachedCount)")
			}

			// Rates
			HStack(spacing: 12) {
				Text("success=\(String(format: "%.0f%%", stats.successRate * 100))")
					.foregroundStyle(successRateColor)
				Text("timeout=\(String(format: "%.0f%%", stats.timeoutRate * 100))")
					.foregroundStyle(stats.timeoutRate <= 0.05 ? Color.secondary : Color.orange)
			}
			.font(.system(size: 10, weight: .medium))

			// Latency percentiles
			HStack(spacing: 12) {
				Text("p50=\(stats.p50LatencyMs)ms")
				Text("p90=\(stats.p90LatencyMs)ms")
				Text("p95=\(stats.p95LatencyMs)ms")
			}
			.font(.system(size: 10, design: .monospaced))
			.foregroundStyle(.secondary)

			// Last 20 outcome strip
			if !stats.last20Outcomes.isEmpty {
				VStack(alignment: .leading, spacing: 2) {
					Text("Last \(stats.last20Outcomes.count):")
						.font(.system(size: 9))
						.foregroundStyle(.tertiary)
					Text(stats.last20Outcomes.joined(separator: " "))
						.font(.system(size: 10, design: .monospaced))
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
			}

			// Updated at
			Text("Updated: \(timeAgoString(stats.updatedAt))")
				.font(.system(size: 9))
				.foregroundStyle(.tertiary)
		}
	}

	private var successRateColor: Color {
		if stats.successRate >= 0.9 { return .green }
		if stats.successRate >= 0.7 { return .orange }
		return .red
	}

	private func statCell(_ label: String, _ value: String, color: Color = .secondary) -> some View {
		VStack(spacing: 1) {
			Text(value)
				.font(.system(size: 11, weight: .semibold, design: .monospaced))
				.foregroundStyle(color)
			Text(label)
				.font(.system(size: 8))
				.foregroundStyle(.tertiary)
		}
	}

	private func timeAgoString(_ date: Date) -> String {
		let interval = Date().timeIntervalSince(date)
		if interval < 5 { return "just now" }
		if interval < 60 { return "\(Int(interval))s ago" }
		return "\(Int(interval / 60))m ago"
	}
}
