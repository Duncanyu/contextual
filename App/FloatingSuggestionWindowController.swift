import AppKit
import Combine
import SwiftUI

/// Hosts `FloatingSuggestionView` in a borderless floating `NSPanel` (T10.1).
@MainActor
final class FloatingSuggestionWindowController {
	private let appState: AppState
	private let panel: NSPanel
	private var cancellables = Set<AnyCancellable>()

	init(appState: AppState) {
		self.appState = appState

		let contentSize = NSSize(width: 320, height: 200)
		let panel = NSPanel(
			contentRect: NSRect(origin: .zero, size: contentSize),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.level = .floating
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.isMovable = false
		panel.hidesOnDeactivate = false
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
		self.panel = panel

		let host = NSHostingController(
			rootView: FloatingSuggestionView()
				.environmentObject(appState)
		)
		host.view.wantsLayer = true
		host.view.layer?.backgroundColor = NSColor.clear.cgColor
		host.view.layer?.isOpaque = false
		panel.contentViewController = host

		appState.$isFloatingSuggestionVisible
			.receive(on: DispatchQueue.main)
			.sink { [weak self] visible in
				guard let self else { return }
				if visible {
					self.positionPanel()
					self.panel.orderFrontRegardless()
				} else {
					self.panel.orderOut(nil)
				}
			}
			.store(in: &cancellables)
	}

	private func positionPanel() {
		guard let screen = NSScreen.main else { return }
		let vf = screen.visibleFrame
		let margin: CGFloat = 20
		let width: CGFloat = 320
		let height: CGFloat = 200
		let origin = NSPoint(
			x: vf.maxX - width - margin,
			y: vf.maxY - height - margin
		)
		panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
	}
}
