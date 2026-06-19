import AppKit
import Combine
import SwiftUI

/// Phase 67 (UI 2): persistent assistant-panel size. Pure + testable.
enum AssistantPanelFramePrefs {
	static let sizeKey = "ContextualAssistantPanelSize"
	static let defaultSize = NSSize(width: 440, height: 760)
	static let minSize = NSSize(width: 320, height: 420)
	static let maxSize = NSSize(width: 1000, height: 1400)

	static func loadSize() -> NSSize {
		guard let s = UserDefaults.standard.string(forKey: sizeKey) else { return defaultSize }
		let sz = NSSizeFromString(s)
		guard sz.width > 0, sz.height > 0 else { return defaultSize }
		return clamp(sz)
	}

	static func saveSize(_ size: NSSize) {
		UserDefaults.standard.set(NSStringFromSize(clamp(size)), forKey: sizeKey)
	}

	static func clamp(_ size: NSSize) -> NSSize {
		NSSize(
			width: min(max(size.width, minSize.width), maxSize.width),
			height: min(max(size.height, minSize.height), maxSize.height)
		)
	}
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate, NSWindowDelegate {
	private let statusItem: NSStatusItem
	private let popover: NSPopover
	private let appState: AppState
	private var cancellables = Set<AnyCancellable>()

	var isPopoverShown: Bool { popover.isShown }

	/// Called after the popover is shown (manual toggle or programmatic reveal).
	var onPopoverDidShow: (() -> Void)?
	/// Called after the popover is closed.
	var onPopoverDidClose: (() -> Void)?

	init(appState: AppState) {
		let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		let popover = NSPopover()
		self.statusItem = statusItem
		self.popover = popover
		self.appState = appState

        super.init()
        popover.delegate = self

		statusItem.button?.action = #selector(togglePopover(_:))
		statusItem.button?.target = self

		// Phase 69 (Issue 2): the panel is a fixed control center anchored to the
		// menu bar — moving/detaching was unreliable, so it is disabled. Large,
		// persisted size is kept.
		popover.behavior = .semitransient
		popover.contentSize = AssistantPanelFramePrefs.loadSize()
		print("[AssistantPanelLargeLayout] enabled=yes")
		print("[AssistantPanelFrame] loaded=\(Int(popover.contentSize.width))x\(Int(popover.contentSize.height))")
		print("[PanelMode] mode=control_center")
		print("[PanelMoveDisabled] reason=control_center_fixed")
		popover.contentViewController = NSHostingController(
			rootView: AssistantPanelView()
				.environmentObject(appState)
		)

		// Initialize/heal the icon image at start
		checkIconState(forceReapply: true)

		appState.$panelAttentionIndicatorVisible
			.removeDuplicates()
			.sink { [weak self] _ in
				self?.checkIconState(forceReapply: true)
			}
			.store(in: &cancellables)

		if let btn = statusItem.button {
			btn.publisher(for: \.effectiveAppearance)
				.map { $0.name.rawValue }
				.removeDuplicates()
				.sink { [weak self] appearanceName in
					guard let self else { return }
					let mode = appearanceName.contains("Dark") ? "dark" : "light"
					if LogControl.shared.shouldLog(category: .menu_bar_watchdog, level: .trace) {
						print("[MenuBarIcon] appearance_changed mode=\(mode) image_reapplied=yes")
					}
					self.checkIconState(forceReapply: true)
				}
				.store(in: &cancellables)
		}

		Timer.publish(every: 10, on: .main, in: .common)
			.autoconnect()
			.sink { [weak self] _ in
				self?.checkIconState()
			}
			.store(in: &cancellables)
	}

	/// Returns whether the reveal was allowed and attempted. NSPopover.isShown can
	/// stay false in headless contexts (no status-item window), so callers/tests
	/// should rely on the returned decision, not on isShown.
	@discardableResult
	func revealPopoverIfNeeded(source: PanelOpenSource = .menu_bar) -> Bool {
		let allowed = (source != .suggestion_auto)
		print("[PanelOpen] source=\(source.rawValue) allowed=\(allowed ? "yes" : "no")")
		if !allowed {
			print("[PanelOpen] blocked reason=suggestions_do_not_auto_open_panel")
			return false
		}
		guard !popover.isShown else { return true }
		guard let button = statusItem.button else { return true }
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
		onPopoverDidShow?()
		print("[AssistantPanelOpen] source=\(source.rawValue) visible=\(popover.isShown ? "yes" : "no")")
		return true
	}

	// Phase 69 (Issue 2): panel moving/detaching is disabled — the control center
	// stays anchored to the menu bar because detach/move did not work reliably.
	func popoverShouldDetach(_ popover: NSPopover) -> Bool {
		print("[PanelMoveDisabled] reason=control_center_fixed")
		return false
	}

	@objc private func togglePopover(_ sender: AnyObject?) {
		if popover.isShown {
			popover.performClose(sender)
			return
		}

		print("[PanelOpen] source=menu_bar allowed=yes")
		guard let button = statusItem.button else { return }
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
		onPopoverDidShow?()
	}

    public func popoverDidClose(_ notification: Notification) {
        onPopoverDidClose?()
    }

    // Phase 67 (UI 2): persist the detached panel window size + log move/resize.
    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        AssistantPanelFramePrefs.saveSize(w.frame.size)
        print("[AssistantPanelResize] size=\(Int(w.frame.width))x\(Int(w.frame.height))")
        print("[AssistantPanelFrame] saved=\(Int(w.frame.width))x\(Int(w.frame.height))")
    }

    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        print("[AssistantPanelMove] origin=\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y))")
    }

	private var healthyCheckCount = 0
	private var lastAppliedSymbol: String? = nil
	private var isReapplyingIcon = false

	func checkIconState(forceReapply: Bool = false) {
		guard !isReapplyingIcon else { return }
		isReapplyingIcon = true
		defer { isReapplyingIcon = false }

		guard let button = statusItem.button else {
			if LogControl.shared.shouldLog(category: .menu_bar_watchdog, level: .dogfood) {
				print("[MenuBarIcon] state_check button_exists=no visible=no template=no length=\(statusItem.length) reason=problem_detected")
			}
			return
		}
		
		let image = button.image
		let imageExists = image != nil
		let visible = button.window?.isVisible == true
		let template = image?.isTemplate == true
		let length = statusItem.length
		
		let highlighted = appState.panelAttentionIndicatorVisible
		let symbol = highlighted ? "sparkles.circle.fill" : "sparkles"
		
		let needsHeal = forceReapply || !imageExists || !template || length != NSStatusItem.squareLength || lastAppliedSymbol != symbol
		
		if !needsHeal && !forceReapply {
			healthyCheckCount += 1
			if LogControl.shared.shouldLog(category: .menu_bar_watchdog, level: .trace) {
				print("[MenuBarIcon] state_check button_exists=yes image_exists=yes visible=\(visible ? "yes" : "no") template=yes length=\(length)")
			}
			return
		}
		
		// Break potential infinite loop from setting the same image
		if imageExists && template && length == NSStatusItem.squareLength && lastAppliedSymbol == symbol && !forceReapply {
			return
		}

		if LogControl.shared.shouldLog(category: .menu_bar_watchdog, level: .trace) {
			let reason = forceReapply ? "appearance_changed" : "problem_detected"
			print("[MenuBarIcon] state_check button_exists=yes image_exists=\(imageExists ? "yes" : "no") visible=\(visible ? "yes" : "no") template=\(template ? "yes" : "no") length=\(length) reason=\(reason)")
		}
		
		let resolvedSymbol = symbol
		var newImage = NSImage(systemSymbolName: resolvedSymbol, accessibilityDescription: "Context Assistant")
		if newImage == nil {
			// Fallback: "sparkles.circle.fill" may not exist on older macOS; use "sparkles" to preserve icon visibility.
			newImage = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Context Assistant")
			print("[MenuBarIcon] symbol_fallback requested=\(resolvedSymbol) used=sparkles reason=nil_image")
		}
		newImage?.isTemplate = true
		button.image = newImage
		statusItem.length = NSStatusItem.squareLength
		lastAppliedSymbol = symbol
		print("[MenuBarIcon] applied symbol=\(resolvedSymbol) highlighted=\(highlighted ? "yes" : "no")")
		
		let restorationReason: String
		var isProblem = false
		if forceReapply {
			restorationReason = "appearance_changed"
		} else if !imageExists {
			restorationReason = "missing_image"
			isProblem = true
		} else if !template {
			restorationReason = "lost_template"
			isProblem = true
		} else if length != NSStatusItem.squareLength {
			restorationReason = "collapsed_length"
			isProblem = true
		} else {
			restorationReason = "state_mismatch"
			isProblem = true
		}
		
		if isProblem || LogControl.shared.shouldLog(category: .menu_bar_watchdog, level: .debug) {
			print("[MenuBarIcon] restored reason=\(restorationReason)")
		}
		
		if healthyCheckCount > 0 {
			if LogControl.shared.shouldLog(category: .menu_bar_watchdog, level: .dogfood) {
				print("[MenuBarIcon] healthy_suppressed_checks=\(healthyCheckCount)")
			}
			healthyCheckCount = 0
		}
	}
}

// MARK: - Panel Open Source

enum PanelOpenSource: String, Sendable {
	case menu_bar
	case shortcut
	case explicit_button
	case suggestion_auto
}
