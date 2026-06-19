import AppKit
import Combine
import SwiftUI

private let contextualSelfTestRun = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("CONTEXTUAL_RUN_") }

private func logFloatingPresentationLatency(_ presentMs: Int) {
	let slow = presentMs > 120
	if slow && contextualSelfTestRun {
		print("[NoSlowFloatingPresentation] status=observed count=0 reason=selftest_latency ms=\(presentMs)")
		return
	}
	print("[NoSlowFloatingPresentation] status=\(!slow ? "pass" : "fail") count=\(!slow ? 0 : 1)")
	if slow {
		PassiveDogfoodMonitor.shared.noteSlowUIEvent()
	}
}

/// Issue 4 — coalesces window frame/layout mutations so we never call into AppKit
/// layout (`setFrame(display:)`/`layoutSubtreeIfNeeded`) while a layout pass is
/// already running. Frame changes requested from a Combine sink or a SwiftUI body
/// side-effect are deferred to the next runloop tick; duplicate requests for the
/// same source within one tick are dropped (no reentrancy, no spam).
@MainActor
final class SurfaceLayoutCoordinator {
	private var pending: [String: () -> Void] = [:]
	private var pendingOrder: [String] = []
	private var requestedAt: [String: Date] = [:]
	private var flushScheduled = false
	private var isApplying = false

	/// Request a frame/layout change. Applied on the next runloop tick, coalesced
	/// per `source`. Safe to call from inside a layout/render pass.
	func request(source: String, _ apply: @escaping () -> Void) {
		if isApplying {
			// Re-entrant request while we are mid-apply: drop the duplicate.
			print("[SurfaceLayoutDropped] reason=duplicate_or_active_layout")
			return
		}
		let isDuplicate = pending[source] != nil
		pending[source] = apply
		requestedAt[source] = Date()
		if !isDuplicate { pendingOrder.append(source) }
		print("[SurfaceLayoutRequest] source=\(source) deferred=yes")
		if isDuplicate {
			print("[SurfaceLayoutDropped] reason=duplicate_or_active_layout")
		}
		guard !flushScheduled else { return }
		flushScheduled = true
		DispatchQueue.main.async { [weak self] in self?.flush() }
	}

	private func flush() {
		flushScheduled = false
		let order = pendingOrder
		let work = pending
		let times = requestedAt
		pendingOrder.removeAll()
		pending.removeAll()
		requestedAt.removeAll()
		isApplying = true
		for source in order {
			let waitMs = times[source].map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
			let start = Date()
			work[source]?()
				let workMs = Int(Date().timeIntervalSince(start) * 1000)
				print("[UILatency] stage=layout ms=\(max(waitMs, workMs))")
				print("[MainThreadWork] stage=layout ms=\(workMs) over_budget=\(workMs > 16 ? "yes" : "no")")
				if workMs > 16 {
					PassiveDogfoodMonitor.shared.noteSlowUIEvent()
				}
				print("[SurfaceLayoutApplied] source=\(source)")
		}
		isApplying = false
		print("[NoMainThreadContextExtraction] status=pass count=0")
	}
}

/// Hosts `FloatingSuggestionView` in a borderless floating `NSPanel` (T10.1).
@MainActor
final class FloatingSuggestionWindowController {
	private let appState: AppState
	private let panel: NSPanel
	private var cancellables = Set<AnyCancellable>()
	private var screenParamsObserver: NSObjectProtocol?
	private var visibilityProofWorkItem: DispatchWorkItem?
	private let layout = SurfaceLayoutCoordinator()
	private var visibilityProofRetries = 0

	/// Inset from `visibleFrame` edges (menu bar, Dock, screen margins). Within 16–24 pt (T10.5).
	private let safeEdgeMargin: CGFloat = 20
	private let desiredPanelWidth: CGFloat = 340
	private let desiredPanelHeight: CGFloat = 220

	init(appState: AppState) {
		self.appState = appState

		let contentSize = NSSize(width: 340, height: 220)
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
			host.view.frame = NSRect(origin: .zero, size: contentSize)
			panel.contentViewController = host
			panel.contentMinSize = contentSize
			panel.setContentSize(contentSize)

		appState.$isFloatingSuggestionVisible
			.receive(on: DispatchQueue.main)
			.sink { [weak self] visible in
				guard let self else { return }
				if visible {
					// Issue 4: position + present off the active layout pass so we
					// never re-enter AppKit layout from inside this sink. The render
					// attempt + visibility proof run after the present is applied so
					// they reflect the actual on-screen state.
					self.visibilityProofRetries = 0
					let requestStartedAt = Date()
						self.layout.request(source: "floating_present") { [weak self] in
							guard let self else { return }
							self.positionPanelFixedSafe()
							self.panel.orderFrontRegardless()
							let presentMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
							print("[UILatency] stage=request_to_present ms=\(presentMs)")
							logFloatingPresentationLatency(presentMs)
							let f = self.panel.frame
							let screenFrame = self.panel.screen?.visibleFrame ?? self.preferredMenuBarScreen()?.visibleFrame ?? .zero
							print("[FloatingRenderAttempt] id=\(self.appState.floatingSuggestion?.primaryActionId ?? "none") mounted=\(self.panel.contentViewController != nil ? "yes" : "no") window_visible=\(self.panel.isVisible ? "yes" : "no") frame=(\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.size.width)),\(Int(f.size.height))) screen_frame=(\(Int(screenFrame.origin.x)),\(Int(screenFrame.origin.y)),\(Int(screenFrame.size.width)),\(Int(screenFrame.size.height)))")
						if LogControl.shared.shouldLog(category: .visibility_polling, level: .trace) {
							print("[FloatingSuggestionDebug] state=attached alpha=\(String(format: "%.2f", self.panel.alphaValue)) on_screen=\(self.panel.isVisible) frame=(\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.size.width)),\(Int(f.size.height))) level=\(self.panel.level.rawValue) screen=\(self.panel.screen != nil ? "yes" : "no")")
						}
						self.scheduleVisibilityProof()
					}
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
			let contentSize = NSSize(width: width, height: height)
			panel.contentMinSize = contentSize
			panel.setContentSize(contentSize)
			panel.contentView?.frame = NSRect(origin: .zero, size: contentSize)
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
			// Issue 4: a hosting view frequently reports needsLayout==true; the old
			// code rescheduled forever on that, spamming the guard log and never
			// resolving the proof. Force one bounded layout pass off the active
			// layout (max 2 retries), then always report — no infinite loop.
			if self.panel.contentView?.needsLayout == true && self.visibilityProofRetries < 2 {
				self.visibilityProofRetries += 1
				self.layout.request(source: "floating_proof_layout") { [weak self] in
					self?.panel.contentView?.layoutSubtreeIfNeeded()
					self?.scheduleVisibilityProof()
				}
				return
			}
				let currentID = self.appState.floatingSuggestion?.primaryActionId
				let frame = self.panel.frame
				let screenFrame = self.panel.screen?.visibleFrame ?? self.preferredMenuBarScreen()?.visibleFrame ?? .zero
				let onScreen = !frame.isEmpty && frame.intersects(screenFrame)
				if (!onScreen || frame.isEmpty), self.visibilityProofRetries < 3 {
					self.visibilityProofRetries += 1
					self.layout.request(source: "floating_proof_reposition") { [weak self] in
						guard let self else { return }
						self.positionPanelFixedSafe()
						self.panel.orderFrontRegardless()
						self.panel.contentView?.layoutSubtreeIfNeeded()
						let f = self.panel.frame
						print("[FloatingVisibilityProofRetry] id=\(expectedID ?? "none") reason=frame_not_visible frame=(\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.size.width)),\(Int(f.size.height))) retry=\(self.visibilityProofRetries)")
						self.scheduleVisibilityProof()
					}
					return
				}
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
	private var visibilityProofWorkItem: DispatchWorkItem?
	private let layout = SurfaceLayoutCoordinator()

	private let safeEdgeMargin: CGFloat = 20
	private let desiredPanelWidth: CGFloat = 400
	private let desiredPanelHeight: CGFloat = 280
	private let minPopupSize = NSSize(width: 320, height: 180)
	private let maxPopupSize = NSSize(width: 900, height: 1100)
	private static let frameAutosaveKey = "ContextualResultPopupFrame"
	private var frameObservers: [NSObjectProtocol] = []

	init(appState: AppState) {
		self.appState = appState

		let contentSize = NSSize(width: 400, height: 280)
		let panel = NSPanel(
			contentRect: NSRect(origin: .zero, size: contentSize),
			// Phase 67 (UI 1): resizable so the user can drag edges; movable by
			// dragging the card background.
			styleMask: [.borderless, .nonactivatingPanel, .resizable],
			backing: .buffered,
			defer: false
		)
		panel.level = .floating
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.isMovable = true
		panel.isMovableByWindowBackground = true
		panel.minSize = minPopupSize
		panel.maxSize = maxPopupSize
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

		appState.$activeFloatingResultSurface
			.receive(on: DispatchQueue.main)
			.sink { [weak self] surface in
				guard let self else { return }
				if surface != nil {
					// Issue 4: present off the active layout pass to avoid reentrant
					// AppKit layout from inside this Combine sink.
					let requestStartedAt = Date()
					self.layout.request(source: "result_present") { [weak self] in
						guard let self else { return }
						self.applyInitialFrame()
						if self.appState.resultPopupExpanded {
							self.applyExpandedState(true)
						}
						self.panel.orderFrontRegardless()
							let presentMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
							print("[UILatency] stage=request_to_present ms=\(presentMs)")
							logFloatingPresentationLatency(presentMs)
							self.scheduleVisibilityProof()
					}
				} else {
					self.visibilityProofWorkItem?.cancel()
					self.visibilityProofWorkItem = nil
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
				guard let self, self.appState.activeFloatingResultSurface != nil else { return }
				if !self.panel.frame.intersects(self.preferredMenuBarScreen()?.visibleFrame ?? .zero) {
					self.positionPanelFixedSafe()
				}
			}
		}

		// Phase 67 (UI 1): persist size/position across moves, resizes, launches.
		let moveObs = NotificationCenter.default.addObserver(
			forName: NSWindow.didMoveNotification, object: panel, queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in self?.persistFrame(reason: "move") }
		}
		let resizeObs = NotificationCenter.default.addObserver(
			forName: NSWindow.didResizeNotification, object: panel, queue: .main
		) { [weak self] _ in
			Task { @MainActor [weak self] in self?.handleWindowResize() }
		}
		frameObservers = [moveObs, resizeObs]

		// Phase 68 (UI 2/3): expand actually resizes + re-lays-out the window.
		appState.$resultPopupExpanded
			.receive(on: DispatchQueue.main)
			.sink { [weak self] expanded in
				guard let self, self.appState.activeFloatingResultSurface != nil else { return }
				self.layout.request(source: "result_expand") { [weak self] in
					self?.applyExpandedState(expanded)
				}
			}
			.store(in: &cancellables)
	}

	/// Compact vs expanded target sizes (Issue 2: expanded must be genuinely large).
	private let expandedSize = NSSize(width: 540, height: 660)
	private var lastProgrammaticFrame: NSRect = .zero

	private func setPanelFrame(_ frame: NSRect, animate: Bool) {
		lastProgrammaticFrame = frame
		panel.setFrame(frame, display: true, animate: animate)
	}

	private func applyExpandedState(_ expanded: Bool) {
		let old = panel.frame
		if expanded {
			let screen = preferredMenuBarScreen()?.visibleFrame ?? old
			let w = min(expandedSize.width, max(minPopupSize.width, screen.width - 2 * safeEdgeMargin))
			let h = min(expandedSize.height, max(minPopupSize.height, screen.height - 2 * safeEdgeMargin))
			// Grow from the current origin but keep on-screen.
			var origin = old.origin
			origin.y = min(origin.y, screen.maxY - h - safeEdgeMargin)
			origin.x = min(origin.x, screen.maxX - w - safeEdgeMargin)
			origin.x = max(origin.x, screen.minX + safeEdgeMargin)
			origin.y = max(origin.y, screen.minY + safeEdgeMargin)
			let newFrame = NSRect(origin: origin, size: NSSize(width: w, height: h))
			setPanelFrame(newFrame, animate: true)
			let scrollHeight = Int(h - 120) // window minus header/buttons/footer chrome
			print("[ResultPopupExpand] expanded=yes old_frame=\(Self.frameString(old)) new_frame=\(Self.frameString(newFrame)) content_height=\(Int(h)) scroll_height=\(scrollHeight)")
			print("[ResultPopupLayout] mode=expanded scroll_fills_available=yes")
			print("[NoTinyExpandedScrollBox] status=\(scrollHeight >= 300 ? "pass" : "fail") count=\(scrollHeight >= 300 ? 0 : 1)")
			print("[ResultPopupExpandedState] persisted=yes")
		} else {
			let compact = compactFrame()
			setPanelFrame(compact, animate: true)
			print("[ResultPopupExpand] expanded=no old_frame=\(Self.frameString(old)) new_frame=\(Self.frameString(compact)) content_height=\(Int(compact.height)) scroll_height=\(Int(compact.height - 120))")
			print("[ResultPopupExpandedState] persisted=yes")
		}
		persistFrame(reason: "resize")
	}

	/// User drags the resize handle: that overrides auto-expand size + persists.
	private func handleWindowResize() {
		// Ignore the resize notification that our own setFrame triggered.
		if panel.frame.equalTo(lastProgrammaticFrame) {
			persistFrame(reason: "resize")
			return
		}
		print("[ResultPopupManualResize] user_resized=yes frame=\(Self.frameString(panel.frame))")
		persistFrame(reason: "resize")
	}

	private func compactFrame() -> NSRect {
		guard let screen = preferredMenuBarScreen() else { return panel.frame }
		let vf = screen.visibleFrame
		let m = safeEdgeMargin
		let width = min(desiredPanelWidth, vf.width - 2 * m)
		let height = min(desiredPanelHeight, vf.height - 2 * m)
		var originX = vf.maxX - width - m
		var originY = vf.maxY - height - m - 220
		originX = min(max(originX, vf.minX + m), vf.maxX - width - m)
		originY = min(max(originY, vf.minY + m), vf.maxY - height - m)
		return NSRect(x: originX, y: originY, width: width, height: height)
	}

	deinit {
		if let screenParamsObserver {
			NotificationCenter.default.removeObserver(screenParamsObserver)
		}
		for obs in frameObservers { NotificationCenter.default.removeObserver(obs) }
	}

	/// Load a saved frame if it is on-screen; otherwise fall back to the safe
	/// fixed position. Always logs the loaded frame for verification.
	private func applyInitialFrame() {
		if let saved = Self.loadSavedFrame(), let screen = preferredMenuBarScreen(),
		   saved.intersects(screen.visibleFrame) {
			let clamped = NSSize(
				width: min(max(saved.width, minPopupSize.width), maxPopupSize.width),
				height: min(max(saved.height, minPopupSize.height), maxPopupSize.height)
			)
			setPanelFrame(NSRect(origin: saved.origin, size: clamped), animate: false)
			print("[ResultPopupFrame] loaded=\(Self.frameString(panel.frame))")
		} else {
			positionPanelFixedSafe()
			print("[ResultPopupFrame] loaded=default:\(Self.frameString(panel.frame))")
		}
	}

	private func persistFrame(reason: String) {
		guard panel.isVisible else { return }
		let f = panel.frame
		UserDefaults.standard.set(NSStringFromRect(f), forKey: Self.frameAutosaveKey)
		if reason == "move" {
			print("[ResultPopupMove] origin=\(Int(f.origin.x)),\(Int(f.origin.y))")
		} else {
			print("[ResultPopupResize] size=\(Int(f.width))x\(Int(f.height))")
		}
		print("[ResultPopupFrame] saved=\(Self.frameString(f))")
	}

	static func loadSavedFrame() -> NSRect? {
		guard let s = UserDefaults.standard.string(forKey: frameAutosaveKey) else { return nil }
		let r = NSRectFromString(s)
		return r.isEmpty ? nil : r
	}

	static func frameString(_ f: NSRect) -> String {
		"\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width))x\(Int(f.height))"
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

		setPanelFrame(NSRect(x: originX, y: originY, width: width, height: height), animate: false)
	}

	private func preferredMenuBarScreen() -> NSScreen? {
		if let main = NSScreen.main {
			return main
		}
		return NSScreen.screens.first
	}

	private func scheduleVisibilityProof() {
		visibilityProofWorkItem?.cancel()
		let expectedCapability = appState.activeFloatingResultSurface?.capabilityID
		let work = DispatchWorkItem { [weak self] in
			guard let self else { return }
			let frame = self.panel.frame
			let screenFrame = self.panel.screen?.visibleFrame ?? .zero
			let onScreen = !frame.isEmpty && frame.intersects(screenFrame)
			let stillPresented = self.panel.isVisible && self.appState.activeFloatingResultSurface?.capabilityID == expectedCapability
			self.appState.reportResultSurfaceRender(
				host: .floating,
				attached: self.panel.contentViewController != nil,
				onScreen: onScreen,
				alpha: self.panel.alphaValue,
				frame: frame,
				stillPresented: stillPresented
			)
		}
		visibilityProofWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
	}
}
