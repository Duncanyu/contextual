import SwiftUI

/// Internal-only metadata view for inline assistance foundations (T16.6 + T18.6).
/// Shows anchor, presentation state, and candidate chips — no execution, no raw context.
struct InlineAssistanceDebugView: View {
	let snapshot: InlineAssistanceSnapshot

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			// T18.6 — Anchor + presentation state header.
			Text(anchorLine)
				.font(.caption2)
				.foregroundStyle(.tertiary)
				.lineLimit(1)
			if snapshot.candidateCount > 0 {
				ForEach(snapshot.candidates, id: \.id) { chip in
					Text(chipLine(for: chip))
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.lineLimit(2)
				}
			} else {
				Text("inline: none · \(snapshot.eligibility.reasonCodes.joined(separator: ","))")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.lineLimit(2)
			}
		}
	}

	private var anchorLine: String {
		let ps = snapshot.presentationState
		var parts = [
			"anchor=\(snapshot.anchor.anchorType.rawValue)",
			"confident=\(snapshot.anchor.isConfident ? "yes" : "no")",
		]
		if ps.isDeferredByTyping  { parts.append("deferred=typing") }
		if ps.isDeferredByPointer { parts.append("deferred=pointer") }
		if ps.isSuppressedByExecution { parts.append("suppressed=exec") }
		parts.append("preview_only=\(ps.isPreviewOnly ? "yes" : "no")")
		return parts.joined(separator: " · ")
	}

	private func chipLine(for chip: InlineAssistanceChipModel) -> String {
		[
			"surface=\(chip.surfaceType.rawValue)",
			"place=\(chip.placementHint.rawValue)",
			"cat=\(chip.categoryRaw)",
			"safety=\(chip.safetyBadgeRaw)",
			"label=\(chip.shortLabel)"
		].joined(separator: " · ")
	}
}
