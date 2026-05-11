import SwiftUI

/// Internal-only rich fused-context debug (metadata; no collection).
struct RichContextDebugView: View {
	let summary: RichContextDebugSummary

	var body: some View {
		Group {
			if summary.showsRichDebug {
				VStack(alignment: .leading, spacing: 6) {
					Text("Rich Context")
						.font(.caption2)
						.fontWeight(.semibold)
						.foregroundStyle(.secondary)
					Text(primaryLine)
						.font(.caption2)
						.foregroundStyle(.secondary)
					if !summary.availableSources.isEmpty {
						Text("Sources: \(summary.availableSources.joined(separator: ", "))")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(3)
					}
					if !summary.staleSources.isEmpty {
						Text("Stale: \(summary.staleSources.joined(separator: ", "))")
							.font(.caption2)
							.foregroundStyle(.tertiary)
					}
					if !summary.visualKinds.isEmpty {
						Text("Visual: \(summary.visualKinds.joined(separator: ", "))")
							.font(.caption2)
							.foregroundStyle(.tertiary)
					}
					activityLine
					if let s = summary.lastSamplingDecision, !s.isEmpty {
						Text("Sampling: \(s)")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(2)
					}
					if let b = summary.lastSamplingScoreBucket {
						Text("Sampling score: \(b)")
							.font(.caption2)
							.foregroundStyle(.tertiary)
					}
					if !summary.lastArbitrationReasons.isEmpty {
						Text("Arbitration: \(summary.lastArbitrationReasons.joined(separator: ", "))")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(2)
					}
					refreshBlock
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				Text("No fused context snapshot.")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
	}

	private var primaryLine: String {
		var parts: [String] = []
		if let p = summary.primarySource { parts.append("Primary: \(p)") }
		if let f = summary.freshnessLabel { parts.append(f) }
		if let c = summary.confidenceBucket { parts.append("confidence \(c)") }
		if let x = summary.conflictBucket { parts.append("conflict \(x)") }
		return parts.isEmpty ? "—" : parts.joined(separator: " · ")
	}

	@ViewBuilder private var activityLine: some View {
		let typing = summary.typingState.map { "typing \($0)" }
		let pointer = summary.pointerState.map { "pointer \($0)" }
		let parts = [typing, pointer].compactMap { $0 }
		if !parts.isEmpty {
			Text("Activity: \(parts.joined(separator: " · "))")
				.font(.caption2)
				.foregroundStyle(.tertiary)
		}
	}

	@ViewBuilder private var refreshBlock: some View {
		if summary.lastRefreshWasCancelled != nil || !summary.lastRefreshCollected.isEmpty || !summary.lastRefreshSkipped.isEmpty {
			VStack(alignment: .leading, spacing: 4) {
				if let c = summary.lastRefreshWasCancelled {
					Text("Refresh cancelled: \(c ? "yes" : "no")")
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				if let u = summary.lastRefreshUpdatedCanonical {
					Text("Canonical updated: \(u ? "yes" : "no")")
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				if !summary.lastRefreshCollected.isEmpty {
					Text("Collected: \(summary.lastRefreshCollected.joined(separator: ", "))")
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.lineLimit(2)
				}
				if !summary.lastRefreshSkipped.isEmpty {
					Text("Skipped: \(summary.lastRefreshSkipped.joined(separator: ", "))")
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.lineLimit(3)
				}
			}
		}
	}
}
