import SwiftUI

/// Non-panel floating suggestion surface (reads `AppState` only).
struct FloatingSuggestionView: View {
	@EnvironmentObject private var appState: AppState

	var body: some View {
		Group {
			if let vm = appState.floatingSuggestion {
				VStack(alignment: .leading, spacing: 10) {
					Text(vm.title)
						.font(.subheadline)
						.fontWeight(.semibold)
						.foregroundStyle(.primary)
						.fixedSize(horizontal: false, vertical: true)

					if appState.floatingProposalContextSummary.isAvailable {
						ProposalContextCardChrome(summary: appState.floatingProposalContextSummary, style: .floating)
					}

					if !vm.sourceCaption.isEmpty {
						Text(vm.sourceCaption)
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.fixedSize(horizontal: false, vertical: true)
					}

					HStack(spacing: 10) {
						Button(appState.floatingPrimaryButtonTitle(for: vm)) {
							appState.acceptFloatingProposal()
						}
						.buttonStyle(.borderedProminent)
						.controlSize(.small)

						Button {
							appState.dismissFloatingSuggestion(reason: .manual)
						} label: {
							Image(systemName: "xmark.circle.fill")
								.symbolRenderingMode(.hierarchical)
								.foregroundStyle(.secondary)
						}
						.buttonStyle(.plain)
						.help("Dismiss")
					}
				}
				.padding(14)
				.frame(width: 300)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
				.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
				.overlay(
					RoundedRectangle(cornerRadius: 14, style: .continuous)
						.stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
				)
				.shadow(color: .black.opacity(0.18), radius: 14, y: 6)
			}
		}
	}
}
