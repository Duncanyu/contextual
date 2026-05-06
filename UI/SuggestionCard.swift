import SwiftUI

struct SuggestionCard: View {
	@EnvironmentObject private var appState: AppState

	let proposal: ActionProposal
	let primaryButtonTitle: String

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .top, spacing: 8) {
				Text(proposal.title)
					.font(.subheadline)
					.fontWeight(.semibold)
					.fixedSize(horizontal: false, vertical: true)

				Spacer(minLength: 8)

				Button("Dismiss") {
					appState.dismissCurrentProposal()
				}
				.buttonStyle(.borderless)
				.font(.caption)
			}

			HStack(spacing: 8) {
				Button(primaryButtonTitle) {
					appState.acceptCurrentProposal()
				}
				.buttonStyle(.borderedProminent)
			}
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

