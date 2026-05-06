import Foundation

final class SourceManager {
	private let emit: (SourceEvent) -> Void
	private var sources: [SystemSource] = []
	private var selectionSource: SelectionSource?
	private var screenCaptureSource: ScreenCaptureSource?

	init(emit: @escaping (SourceEvent) -> Void) {
		self.emit = emit
	}

	func start() {
		let activeAppSource = ActiveAppSource(onEvent: emit)
		let windowTitleSource = WindowTitleSource(onEvent: emit)
		let clipboardSource = ClipboardSource(onEvent: emit)
		let selectionSource = SelectionSource(onEvent: emit)
		let screenCaptureSource = ScreenCaptureSource(onEvent: emit)
		self.selectionSource = selectionSource
		self.screenCaptureSource = screenCaptureSource
		sources = [activeAppSource, windowTitleSource, clipboardSource, selectionSource, screenCaptureSource]
		sources.forEach { $0.start() }
	}

	func stop() {
		sources.forEach { $0.stop() }
		sources.removeAll()
		selectionSource = nil
		screenCaptureSource = nil
	}

	func refreshSelectionNow() {
		selectionSource?.refreshOnce()
	}

	func captureScreenNow() {
		screenCaptureSource?.captureNow()
	}
}

