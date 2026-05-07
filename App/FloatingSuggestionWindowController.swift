import AppKit
import Combine
import SwiftUI

/// Hosts `FloatingSuggestionView` in a borderless floating `NSPanel` (T10.1).
@MainActor
final class FloatingSuggestionWindowController {
	private let appState: AppState
	private let panel: NSPanel
	private var cancellables = Set<AnyCancellable>()
	private var screenParamsObserver: NSObjectProtocol?

	/// Inset from `visibleFrame` edges (menu bar, Dock, screen margins). Within 16–24 pt (T10.5).
	private let safeEdgeMargin: CGFloat = 20
	private let desiredPanelWidth: CGFloat = 320
	private let desiredPanelHeight: CGFloat = 200

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
					self.positionPanelFixedSafe()
					self.panel.orderFrontRegardless()
				} else {
					self.panel.orderOut(nil)
				}
			}
			.store(in: &cancellables)

		screenParamsObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			guard let self, self.appState.isFloatingSuggestionVisible else { return }
			self.positionPanelFixedSafe()
		}
	}

	deinit {
		if let screenParamsObserver {
			NotificationCenter.default.removeObserver(screenParamsObserver)
		}
	}

	/// Fixed top-right placement on the menu-bar screen using `visibleFrame` only (no selection/cursor anchoring).
	private func positionPanelFixedSafe() {
		guard let screen = preferredMenuBarScreen() else { return }
		let vf = screen.visibleFrame
		let m = safeEdgeMargin

		let maxContentW = vf.width - 2 * m
		let maxContentH = vf.height - 2 * m
		guard maxContentW > 0, maxContentH > 0 else { return }

		let width = min(desiredPanelWidth, maxContentW)
		let height = min(desiredPanelHeight, maxContentH)

		var originX = vf.maxX - width - m
		var originY = vf.maxY - height - m

		originX = min(max(originX, vf.minX + m), vf.maxX - width - m)
		originY = min(max(originY, vf.minY + m), vf.maxY - height - m)

		panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
	}

	/// Screen that owns the menu bar (respects notch/safe area via `visibleFrame`). Falls back if needed.
	private func preferredMenuBarScreen() -> NSScreen? {
		if let main = NSScreen.main {
			return main
		}
		return NSScreen.screens.first
	}
}
