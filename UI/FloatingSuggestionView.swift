import SwiftUI

/// Non-panel floating suggestion surface (reads `AppState` only).
struct FloatingSuggestionView: View {
	@EnvironmentObject private var appState: AppState

	var body: some View {
		Group {
			if let vm = appState.unifiedSurfaceDecision?.floating {
				VStack(alignment: .leading, spacing: 10) {
					Text(vm.title)
						.font(.subheadline)
						.fontWeight(.semibold)
						.foregroundStyle(.primary)
						.fixedSize(horizontal: false, vertical: true)

					if appState.floatingProposalContextSummary.isAvailable {
						ProposalContextCardChrome(summary: appState.floatingProposalContextSummary, style: .floating)
					}

					if !(vm.subtitle ?? "").isEmpty {
						Text(vm.subtitle ?? "")
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

// MARK: - Floating Result Card View

/// Phase 44 — Typed result cards. Each cognitive action shows a card matched to its output type.
struct FloatingResultCardView: View {
	@EnvironmentObject private var appState: AppState

	var body: some View {
		Group {
			if let surface = appState.activeFloatingResultSurface {
				ResultSurfaceCardContent(surface: surface, host: .floating)
					.environmentObject(appState)
			}
		}
	}
}

struct ResultSurfaceCardContent: View {
	@EnvironmentObject private var appState: AppState

	let surface: ResultSurfaceCardState
	let host: ResultSurfaceHost

	var body: some View {
		Group {
			switch surface {
			case .result(let card):
				resultCard(card)
			case .captureNeeded(let card):
				issueCard(
					title: card.title,
					text: card.text,
					cardType: card.cardType,
					capabilityID: card.capabilityID,
					failureReason: card.failureReason,
					contentSource: card.contentSource ?? "unknown",
					acquiredChars: card.acquiredChars,
					nextStep: card.nextStep,
					actions: card.actions
				)
			case .failure(let card):
				issueCard(
					title: card.title,
					text: card.text,
					cardType: card.cardType,
					capabilityID: card.capabilityID,
					failureReason: card.failureReason,
					contentSource: card.contentSource ?? "unknown",
					acquiredChars: card.acquiredChars,
					nextStep: card.nextStep,
					actions: card.actions
				)
			case .blocked(let card):
				issueCard(
					title: card.title,
					text: card.text,
					cardType: card.cardType,
					capabilityID: card.capabilityID,
					failureReason: card.failureReason,
					contentSource: "target_contract",
					acquiredChars: 0,
					nextStep: card.nextStep,
					actions: card.actions
				)
			}
		}
		.background(
			GeometryReader { proxy in
				Color.clear
					.onAppear {
						DispatchQueue.main.async {
							appState.reportResultSurfaceRender(
								host: host,
								attached: true,
								onScreen: true,
								alpha: 1.0,
								frame: proxy.frame(in: .global),
								stillPresented: true
							)
						}
					}
			}
		)
	}

	// MARK: - Layout budget (Phase 58.6 — floating is glanceable, panel is detailed)

	private var isFloating: Bool { host == .floating }

	private var maxButtons: Int {
		ResultCardPresentationPolicy.budget(for: isFloating ? .floating : .panel).maxButtons
	}

	// MARK: - Failure / Capture Card

	@ViewBuilder
	private func issueCard(
		title: String,
		text: String,
		cardType: ResultCardType,
		capabilityID: String,
		failureReason: String?,
		contentSource: String,
		acquiredChars: Int,
		nextStep: String?,
		actions: [ResultCardAction]
	) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Image(systemName: cardIcon(cardType))
					.foregroundStyle(cardAccentColor(cardType))
					.imageScale(.medium)
				Text(title)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.primary)
					.fixedSize(horizontal: false, vertical: true)
				Spacer()
				Button {
					appState.dismissResultSurface(reason: "user")
				} label: {
					Image(systemName: "xmark.circle.fill")
						.symbolRenderingMode(.hierarchical)
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}

			// What's missing and why it matters — no debug enums, no char counts.
			Text(text)
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			// How to fix it.
			if let instruction = surface.nextStepText, !instruction.isEmpty {
				VStack(alignment: .leading, spacing: 2) {
					Text("Next best move")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.secondary)
					Text(instruction)
						.font(.callout)
						.foregroundStyle(.primary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}

			contextScopeChip

			cardButtons(actions, capabilityID: capabilityID, copyText: nil)
		}
		.padding(14)
		.frame(width: isFloating ? 300 : nil)
		.frame(maxWidth: isFloating ? 300 : .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 14, style: .continuous)
				.stroke(Color.orange.opacity(0.3), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.18), radius: 14, y: 6)
	}

	// MARK: - Main Result Card

	@ViewBuilder
	private func resultCard(_ card: ResearchResultCardState) -> some View {
		let expanded = isFloating && appState.isFloatingResultExpanded(for: card.capabilityID)
		let compactBody = (card.floatingText ?? "").isEmpty ? card.text : (card.floatingText ?? "")
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Image(systemName: cardIcon(card.cardType))
					.foregroundStyle(cardAccentColor(card.cardType))
					.imageScale(.medium)
				Text(card.title)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.primary)
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 4)
				Button {
					appState.dismissResultSurface(reason: "user")
				} label: {
					Image(systemName: "xmark.circle.fill")
						.symbolRenderingMode(.hierarchical)
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}

			contextScopeChip

			if isFloating && expanded {
				ScrollView {
					Text(card.text)
						.font(.callout)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textSelection(.enabled)
				}
				.frame(maxHeight: 360)
			} else if isFloating {
				Text(compactBody)
					.font(.callout)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.fixedSize(horizontal: false, vertical: true)
					.textSelection(.enabled)
			} else {
				ScrollView {
					Text(card.text)
						.font(.callout)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textSelection(.enabled)
				}
				.frame(maxHeight: 280)
			}

			if isFloating {
				floatingExpandControl(for: card.capabilityID)
			}

			if let next = card.nextStepText, !next.isEmpty {
				VStack(alignment: .leading, spacing: 2) {
					Text("Next")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.secondary)
					Text(next)
						.font(.callout)
						.foregroundStyle(.primary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}

			cardButtons(card.actions, capabilityID: card.capabilityID, copyText: card.text)
		}
		.padding(14)
		.frame(width: isFloating ? (expanded ? 420 : 300) : nil)
		.frame(maxWidth: isFloating ? (expanded ? 420 : 300) : .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 14, style: .continuous)
				.stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.18), radius: 14, y: 6)
	}

	@ViewBuilder
	private var contextScopeChip: some View {
		let chip = appState.contextChipDisplay(for: surface)
		Menu {
			ForEach(appState.contextScopeOptions(for: surface), id: \.rawValue) { option in
				Button {
					appState.selectContextScope(option, for: surface)
				} label: {
					Label(option.menuLabel, systemImage: option.systemImage)
				}
			}
		} label: {
			HStack(spacing: 5) {
				if chip.isPending {
					ProgressView().controlSize(.mini)
				} else {
					Image(systemName: chip.systemImage)
						.font(.caption2)
				}
				Text(chip.label)
					.font(.caption2.weight(.medium))
				Image(systemName: "chevron.down")
					.font(.system(size: 8, weight: .semibold))
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(Color(nsColor: .controlBackgroundColor).opacity(0.9), in: Capsule())
		}
		.menuStyle(.borderlessButton)
		.fixedSize()
	}

	// MARK: - Shared sections (Phase 58.6)

	/// Follow-up buttons below the body, capped per surface, never mixed into it.
	@ViewBuilder
	private func cardButtons(_ actions: [ResultCardAction], capabilityID: String, copyText: String?) -> some View {
		let visible = Array(actions.prefix(maxButtons))
		VStack(alignment: .leading, spacing: 6) {
			ForEach(0..<visible.count, id: \.self) { index in
                let action = visible[index]
				if index == 0 {
					Button(action.title) {
						appState.handleResultCardAction(action, for: surface)
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.small)
				} else {
					Button(action.title) {
						appState.handleResultCardAction(action, for: surface)
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
				}
			}
			if copyText != nil {
				Button("Copy summary") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(copyText ?? "", forType: .string)
					print("[ClipboardWrite] capability=\(capabilityID) reason=user_clicked_copy")
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
		}
	}

	@ViewBuilder
	private func floatingExpandControl(for capabilityID: String) -> some View {
		let expanded = appState.isFloatingResultExpanded(for: capabilityID)
		HStack {
			Spacer()
			Button {
				appState.toggleFloatingResultExpanded(for: capabilityID)
			} label: {
				Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
					.font(.body.weight(.medium))
					.foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)
			.help(expanded ? "Collapse result" : "Expand full result")
		}
		.padding(.top, 2)
	}

	/// One human source line — what the assistant actually read.
	@ViewBuilder
	private var sourceFooter: some View {
		if !surface.sourceLabel.isEmpty {
			Text("Source: \(surface.sourceLabel)")
				.font(.caption2)
				.foregroundStyle(.tertiary)
		}
	}

	// MARK: - Helpers

	private func cardIcon(_ type: ResultCardType) -> String {
		switch type {
		case .summary:     return "doc.text.magnifyingglass"
		case .checklist:   return "checklist"
		case .actionItems: return "list.bullet.clipboard"
		case .draft:       return "square.and.pencil"
		case .explanation: return "lightbulb"
		case .compare:     return "rectangle.split.2x1"
		case .captureNeeded: return "eye.slash.circle"
		case .error:       return "exclamationmark.triangle"
		case .blockedAction: return "hand.raised.circle"
		case .result:      return "checkmark.circle"
		}
	}

	private func cardAccentColor(_ type: ResultCardType) -> Color {
		switch type {
		case .summary, .explanation: return .blue
		case .checklist, .actionItems: return .green
		case .draft: return .purple
		case .compare: return .orange
		case .captureNeeded, .error, .blockedAction: return .orange
		case .result: return .green
		}
	}

}
