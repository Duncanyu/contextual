import SwiftUI

/// Internal-only metadata list for inline assistance foundations (T16.6). No execution, no raw context.
struct InlineAssistanceDebugView: View {
	let snapshot: InlineAssistanceSnapshot

	var body: some View {
		Group {
			if snapshot.candidateCount > 0 {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(snapshot.candidates, id: \.id) { chip in
						Text(line(for: chip))
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(2)
					}
				}
			} else {
				Text("Inline assistance: none · eligibility=\(snapshot.eligibility.reasonCodes.joined(separator: ","))")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.lineLimit(2)
			}
		}
	}

	private func line(for chip: InlineAssistanceChipModel) -> String {
		[
			"surface=\(chip.surfaceType.rawValue)",
			"place=\(chip.placementHint.rawValue)",
			"cat=\(chip.categoryRaw)",
			"safety=\(chip.safetyBadgeRaw)",
			"label=\(chip.shortLabel)"
		].joined(separator: " · ")
	}
}
