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
	private var visibilityProofWorkItem: DispatchWorkItem?

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
					let f = self.panel.frame
					if LogControl.shared.shouldLog(category: .visibility_polling, level: .trace) {
						print("[FloatingSuggestionDebug] state=attached alpha=\(String(format: "%.2f", self.panel.alphaValue)) on_screen=\(self.panel.isVisible) frame=(\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.size.width)),\(Int(f.size.height))) level=\(self.panel.level.rawValue) screen=\(self.panel.screen != nil ? "yes" : "no")")
					}
					self.scheduleVisibilityProof()
				} else {
					self.visibilityProofWorkItem?.cancel()
					self.visibilityProofWorkItem = nil
					if LogControl.shared.shouldLog(category: .visibility_polling, level: .trace) {
						print("[FloatingSuggestionDebug] state=detached")
					}
					self.panel.orderOut(nil)
				}
			}
			.store(in: &cancellables)

		screenParamsObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self, self.appState.isFloatingSuggestionVisible else { return }
				self.positionPanelFixedSafe()
			}
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

	private func scheduleVisibilityProof() {
		visibilityProofWorkItem?.cancel()
		let expectedID = appState.floatingSuggestion?.primaryActionId
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			if self.panel.contentView?.needsLayout == true {
				print("[SurfaceLayoutGuard] deferred reason=avoid_layout_recursion")
				print("[VisibilityProof] disabled reason=layout_recursion_detected")
				self.scheduleVisibilityProof()
				return
			}
			let currentID = self.appState.floatingSuggestion?.primaryActionId
			let frame = self.panel.frame
			let screenFrame = self.panel.screen?.visibleFrame ?? .zero
			let onScreen = !frame.isEmpty && frame.intersects(screenFrame)
			self.appState.reportFloatingVisibilityProof(
				attached: self.panel.contentViewController != nil,
				onScreen: onScreen,
				alpha: self.panel.alphaValue,
				frame: frame,
				hiddenByPanel: self.appState.isPanelVisible,
				dwellMs: 2500,
				stillPresented: self.panel.isVisible && currentID == expectedID
			)
		}
		visibilityProofWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
	}
}

// MARK: - Floating Result Card Window Controller

@MainActor
final class FloatingResultCardWindowController {
	private let appState: AppState
	private let panel: NSPanel
	private var cancellables = Set<AnyCancellable>()
	private var screenParamsObserver: NSObjectProtocol?

	private let safeEdgeMargin: CGFloat = 20
	private let desiredPanelWidth: CGFloat = 320
	private let desiredPanelHeight: CGFloat = 220

	init(appState: AppState) {
		self.appState = appState

		let contentSize = NSSize(width: 320, height: 220)
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
			rootView: FloatingResultCardView()
				.environmentObject(appState)
		)
		host.view.wantsLayer = true
		host.view.layer?.backgroundColor = NSColor.clear.cgColor
		host.view.layer?.isOpaque = false
		panel.contentViewController = host

		appState.$activeResearchResultCard
			.receive(on: DispatchQueue.main)
			.sink { [weak self] card in
				guard let self else { return }
				if card != nil {
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
			Task { @MainActor [weak self] in
				guard let self, self.appState.activeResearchResultCard != nil else { return }
				self.positionPanelFixedSafe()
			}
		}
	}

	deinit {
		if let screenParamsObserver {
			NotificationCenter.default.removeObserver(screenParamsObserver)
		}
	}

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
		var originY = vf.maxY - height - m - 220

		originX = min(max(originX, vf.minX + m), vf.maxX - width - m)
		originY = min(max(originY, vf.minY + m), vf.maxY - height - m)

		panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
	}

	private func preferredMenuBarScreen() -> NSScreen? {
		if let main = NSScreen.main {
			return main
		}
		return NSScreen.screens.first
	}
}
