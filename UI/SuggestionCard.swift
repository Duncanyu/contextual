import SwiftUI

struct SuggestionCard: View {
	let title: String
	let primaryActionTitle: String
	let dismissTitle: String?
	let onPrimary: () -> Void
	let onDismiss: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .top, spacing: 8) {
				Text(title)
					.font(.subheadline)
					.fontWeight(.semibold)
					.fixedSize(horizontal: false, vertical: true)

				Spacer(minLength: 8)

				if let dismissTitle {
					Button(dismissTitle) {
						onDismiss()
					}
					.buttonStyle(.borderless)
					.font(.caption)
				}
			}

			HStack(spacing: 8) {
				Button(primaryActionTitle) {
					onPrimary()
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

#if DEBUG
struct SuggestionCard_Previews: PreviewProvider {
	static var previews: some View {
		SuggestionCard(
			title: "Want me to help with the current context?",
			primaryActionTitle: "Open Actions",
			dismissTitle: "Dismiss",
			onPrimary: {},
			onDismiss: {}
		)
		.padding()
		.frame(width: 320)
	}
}
#endif

