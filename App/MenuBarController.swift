import AppKit
import SwiftUI

@MainActor
final class MenuBarController {
	private let statusItem: NSStatusItem
	private let popover: NSPopover

	var isPopoverShown: Bool { popover.isShown }

	init(appState: AppState) {
		let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		let popover = NSPopover()
		self.statusItem = statusItem
		self.popover = popover

		let image = NSImage(
			systemSymbolName: "sparkles",
			accessibilityDescription: "Context Assistant"
		)
		image?.isTemplate = true
		statusItem.button?.image = image
		statusItem.button?.action = #selector(togglePopover(_:))
		statusItem.button?.target = self

		popover.behavior = .transient
		popover.contentSize = NSSize(width: 300, height: 620)
		popover.contentViewController = NSHostingController(
			rootView: AssistantPanelView()
				.environmentObject(appState)
		)
	}

	func revealPopoverIfNeeded() {
		guard !popover.isShown else { return }
		guard let button = statusItem.button else { return }
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
	}

	@objc private func togglePopover(_ sender: AnyObject?) {
		if popover.isShown {
			popover.performClose(sender)
			return
		}

		guard let button = statusItem.button else { return }
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
	}
}

