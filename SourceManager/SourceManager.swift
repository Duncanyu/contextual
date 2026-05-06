import Foundation

final class SourceManager {
	private let emit: (SourceEvent) -> Void
	private var sources: [SystemSource] = []
	private var selectionSource: SelectionSource?

	init(emit: @escaping (SourceEvent) -> Void) {
		self.emit = emit
	}

	func start() {
		let activeAppSource = ActiveAppSource(onEvent: emit)
		let windowTitleSource = WindowTitleSource(onEvent: emit)
		let clipboardSource = ClipboardSource(onEvent: emit)
		let selectionSource = SelectionSource(onEvent: emit)
		self.selectionSource = selectionSource
		sources = [activeAppSource, windowTitleSource, clipboardSource, selectionSource]
		sources.forEach { $0.start() }
	}

	func stop() {
		sources.forEach { $0.stop() }
		sources.removeAll()
		selectionSource = nil
	}

	func refreshSelectionNow() {
		selectionSource?.refreshOnce()
	}
}

