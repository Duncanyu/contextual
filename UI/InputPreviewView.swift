import SwiftUI

/// Metadata-only summary of input sources from `ContextModel`. Does not render clipboard, selection, or OCR body text.
struct InputPreviewView: View {
	let context: ContextModel

	private static let largeInputThreshold = 10_000

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Input")
				.font(.subheadline)
				.fontWeight(.semibold)

			ForEach(displayLines, id: \.self) { line in
				Text(line)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			if showsLargeInputWarning {
				Text("Large input may take longer")
					.font(.caption2)
					.foregroundStyle(Color(nsColor: .systemOrange))
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

	private var showsLargeInputWarning: Bool {
		context.selectedTextLength > Self.largeInputThreshold
			|| context.clipboardTextLength > Self.largeInputThreshold
			|| context.screenOCRTextLength > Self.largeInputThreshold
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

	private var hasAnyTextInput: Bool {
		hasSelection || hasClipboard || hasOCR
	}

	/// Display order matches `ActionInputCapture` for text actions: selection, then clipboard; screen OCR is shown in addition when present.
	private var displayLines: [String] {
		if !hasAnyTextInput {
			let appLabel: String
			if let name = context.activeAppName, !name.isEmpty {
				appLabel = name
			} else {
				appLabel = "—"
			}
			return [
				"No text input detected. Manual screen analysis may still be available after capture.",
				"Current app · \(appLabel)"
			]
		}

		var lines: [String] = []

		if hasSelection {
			lines.append("Primary: Selected text · \(context.selectedTextLength) chars")
			if hasClipboard {
				lines.append("Also available: Clipboard · \(context.clipboardTextLength) chars")
			}
			if hasOCR {
				lines.append("Also available: Screen text · \(context.screenOCRTextLength) chars · \(context.screenOCRLineCount) lines")
			}
		} else if hasClipboard {
			lines.append("Primary: Clipboard · \(context.clipboardTextLength) chars")
			if hasOCR {
				lines.append("Also available: Screen text · \(context.screenOCRTextLength) chars · \(context.screenOCRLineCount) lines")
			}
		} else if hasOCR {
			lines.append("Primary: Screen text · \(context.screenOCRTextLength) chars · \(context.screenOCRLineCount) lines")
		}

		return lines
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
			.padding()
			.frame(width: 320)
	}
}
#endif
