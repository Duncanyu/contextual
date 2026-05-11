import SwiftUI

struct SuggestionCard: View {
	let title: String
	let primaryActionTitle: String
	let dismissTitle: String?
	/// When true, primary action is disabled (dismiss stays enabled).
	var primaryDisabled: Bool = false
	/// Optional one-line hint for which input source the primary action will use (metadata only).
	var inputSourceLine: String? = nil
	/// Lightweight proposal context (T16.2); when unavailable, layout matches pre–T16.2 cards.
	var proposalContext: ProposalContextSummary = .unavailable
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

			if let inputSourceLine, !inputSourceLine.isEmpty {
				Text(inputSourceLine)
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.fixedSize(horizontal: false, vertical: true)
			}

			if proposalContext.isAvailable {
				ProposalContextCardChrome(summary: proposalContext, style: .panel)
			}

			HStack(spacing: 8) {
				Button(primaryActionTitle) {
					onPrimary()
				}
				.buttonStyle(.borderedProminent)
				.disabled(primaryDisabled)
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

// MARK: - Proposal context (T16.2)

enum ProposalContextCardChromeStyle {
	case panel
	case floating
}

struct ProposalContextCardChrome: View {
	let summary: ProposalContextSummary
	var style: ProposalContextCardChromeStyle = .panel

	private var whyText: String? {
		let primary = summary.whyLine?.trimmingCharacters(in: .whitespacesAndNewlines)
		let hint = summary.explainHint?.trimmingCharacters(in: .whitespacesAndNewlines)
		if let p = primary, !p.isEmpty { return p }
		if let h = hint, !h.isEmpty { return h }
		return nil
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			if let line = summary.contextSubtitle, !line.isEmpty {
				Text(line)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			if !summary.chipDisplayLabels.isEmpty {
				HStack(spacing: 6) {
					ForEach(Array(summary.chipDisplayLabels.enumerated()), id: \.offset) { _, label in
						chipLabel(label)
					}
				}
				.fixedSize(horizontal: false, vertical: true)
			}

			if let why = whyText {
				Text("Why: \(why)")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	@ViewBuilder
	private func chipLabel(_ label: String) -> some View {
		switch style {
		case .panel:
			Text(label)
				.font(.caption2)
				.fontWeight(.medium)
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background(
					Capsule(style: .continuous)
						.fill(Color(nsColor: .quaternaryLabelColor).opacity(0.14))
				)
				.overlay(
					Capsule(style: .continuous)
						.stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
				)
		case .floating:
			Text(label)
				.font(.caption2)
				.fontWeight(.medium)
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background(
					Capsule(style: .continuous)
						.fill(Color.primary.opacity(0.06))
				)
				.overlay(
					Capsule(style: .continuous)
						.stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
				)
		}
	}
}

#if DEBUG
struct SuggestionCard_Previews: PreviewProvider {
	static var previews: some View {
		SuggestionCard(
			title: "Want me to help with the current context?",
			primaryActionTitle: "Open Actions",
			dismissTitle: "Dismiss",
			primaryDisabled: false,
			inputSourceLine: "Using: Clipboard",
			proposalContext: .unavailable,
			onPrimary: {},
			onDismiss: {}
		)
		.padding()
		.frame(width: 320)
	}
}
#endif
