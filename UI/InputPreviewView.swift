import SwiftUI

/// Metadata-only input summary and session input-source picker (no raw text).
struct InputPreviewView: View {
	@EnvironmentObject private var appState: AppState
	let context: ContextModel

	private static let largeInputThreshold = 10_000

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Input")
				.font(.subheadline)
				.fontWeight(.semibold)

			VStack(alignment: .leading, spacing: 6) {
				ForEach(InputSourceChoice.allCases, id: \.self) { choice in
					sourceRow(choice)
				}
			}

			Text(appState.inputSourceUsageDescription(for: context))
				.font(.caption2)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			if !hasAnyTextInput {
				emptyStateLines
			}

			if showsLargeInputWarning {
				Text("Large input may take longer")
					.font(.caption2)
					.foregroundStyle(Color(nsColor: .systemOrange))
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

	private var hasAnyTextInput: Bool {
		hasSelection || hasClipboard || hasOCR
	}

	private var hasSelection: Bool {
		context.selectedTextAvailable && context.selectedTextLength > 0
	}

	private var hasClipboard: Bool {
		context.clipboardTextAvailable && context.clipboardTextLength > 0
	}

	private var hasOCR: Bool {
		context.screenOCRAvailable && context.screenOCRTextLength > 0
	}

	private var showsLargeInputWarning: Bool {
		context.selectedTextLength > Self.largeInputThreshold
			|| context.clipboardTextLength > Self.largeInputThreshold
			|| context.screenOCRTextLength > Self.largeInputThreshold
	}

	private var emptyAppLabel: String {
		if let name = context.activeAppName, !name.isEmpty { return name }
		return "—"
	}

	@ViewBuilder private var emptyStateLines: some View {
		Text("No text input detected. Manual screen analysis may still be available after capture.")
			.font(.caption2)
			.foregroundStyle(.tertiary)
			.fixedSize(horizontal: false, vertical: true)
		Text("Current app · \(emptyAppLabel)")
			.font(.caption2)
			.foregroundStyle(.tertiary)
	}

	private func sourceRow(_ choice: InputSourceChoice) -> some View {
		let available = appState.isInputSourceChoiceAvailable(choice, context: context)
		let selected = appState.selectedInputSourceChoice == choice
		return Button {
			if available {
				appState.selectedInputSourceChoice = choice
			}
		} label: {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: selected ? "largecircle.fill.circle" : "circle")
					.font(.caption)
					.foregroundStyle(selected ? Color.accentColor : .secondary)
				Text(rowTitle(for: choice))
					.font(.caption)
					.multilineTextAlignment(.leading)
				Spacer(minLength: 4)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!available)
		.opacity(available ? 1 : 0.45)
	}

	private func rowTitle(for choice: InputSourceChoice) -> String {
		switch choice {
		case .automatic:
			return "Automatic"
		case .selectedText:
			return hasSelection
				? "Selected text · \(context.selectedTextLength) chars"
				: "Selected text · 0 chars"
		case .clipboard:
			return hasClipboard
				? "Clipboard · \(context.clipboardTextLength) chars"
				: "Clipboard · 0 chars"
		case .screenOCR:
			return hasOCR
				? "Screen text · \(context.screenOCRTextLength) chars · \(context.screenOCRLineCount) lines"
				: "Screen text · 0 chars · 0 lines"
		}
	}
}

#if DEBUG
struct InputPreviewView_Previews: PreviewProvider {
	static var previews: some View {
		var m = ContextModel()
		m.selectedTextAvailable = true
		m.selectedTextLength = 420
		m.clipboardTextAvailable = true
		m.clipboardTextLength = 1430
		m.screenOCRAvailable = true
		m.screenOCRTextLength = 2452
		m.screenOCRLineCount = 98
		return InputPreviewView(context: m)
			.environmentObject(AppState())
			.padding()
			.frame(width: 320)
	}
}
#endif
