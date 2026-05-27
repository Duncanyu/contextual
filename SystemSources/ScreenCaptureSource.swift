import AppKit
import CoreGraphics
import ApplicationServices

final class ScreenCaptureSource: SystemSource {
	private let onEvent: (SourceEvent) -> Void
	private static var lastUnavailableLogAt: Date?

	init(onEvent: @escaping (SourceEvent) -> Void) {
		self.onEvent = onEvent
	}

	func start() {}
	func stop() {}

	static func isScreenRecordingAuthorized() -> Bool {
		CGPreflightScreenCaptureAccess()
	}

	static func openScreenRecordingSettings() {
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
			NSWorkspace.shared.open(url)
		} else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
			NSWorkspace.shared.open(url)
		}
	}

	/// One-shot screen frame for explicit execution requests (T17.8). Caller must discard `CGImage` immediately.
	static func captureSingleFrame() -> (image: CGImage, width: Int, height: Int)? {
		guard isScreenRecordingAuthorized() else { return nil }
		let (targetRect, _, logs) = findActiveWindowAndScreen()
		for log in logs {
			print(log)
		}
		let captureRect = targetRect ?? CGRect.infinite
		guard let image = CGWindowListCreateImage(
			captureRect,
			.optionOnScreenOnly,
			kCGNullWindowID,
			[.bestResolution]
		) else { return nil }
		return (image, image.width, image.height)
	}

	func captureNow() {
		print("[ScreenCapture] capture start")

		if !Self.isScreenRecordingAuthorized() {
			let now = Date()
			if Self.lastUnavailableLogAt == nil || now.timeIntervalSince(Self.lastUnavailableLogAt!) > 10 {
				Self.lastUnavailableLogAt = now
				print("[ScreenCapture] permission missing or capture unavailable")
			}
			return
		}

		let (targetRect, _, logs) = Self.findActiveWindowAndScreen()
		for log in logs {
			print(log)
		}
		let captureRect = targetRect ?? CGRect.infinite

		let image = CGWindowListCreateImage(
			captureRect,
			.optionOnScreenOnly,
			kCGNullWindowID,
			[.bestResolution]
		)

		guard let image else {
			let now = Date()
			if Self.lastUnavailableLogAt == nil || now.timeIntervalSince(Self.lastUnavailableLogAt!) > 10 {
				Self.lastUnavailableLogAt = now
				print("[ScreenCapture] permission missing or capture unavailable")
			}
			return
		}

		print("[ScreenCapture] captured \(image.width)x\(image.height)")
		onEvent(.screenCaptured(ScreenCapturePayload(image: image, timestamp: Date(), source: "screen_capture")))
	}

	// MARK: - Active Window & Display Targeting (Quartz Coordinate Space)

	static func findActiveWindowAndScreen() -> (rect: CGRect?, screen: NSScreen?, logs: [String]) {
		var logs: [String] = []
		let (activeApp, activeTitle) = getActiveAppAndTitle()
		logs.append("[VisualTarget] active_app=\(activeApp) active_title=\(activeTitle)")

		var axWindowFrame: CGRect? = nil
		var axFrameStr = "nil"

		if let app = NSWorkspace.shared.frontmostApplication {
			let axApp = AXUIElementCreateApplication(app.processIdentifier)
			var tempWindow: CFTypeRef?
			if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &tempWindow) == .success ||
			   AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &tempWindow) == .success {
				let windowElement = tempWindow as! AXUIElement
				
				var positionValue: CFTypeRef?
				var sizeValue: CFTypeRef?
				if AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue) == .success,
				   AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue) == .success {
					var position = CGPoint.zero
					var size = CGSize.zero
					
					if AXValueGetType(positionValue as! AXValue) == .cgPoint {
						AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
					}
					if AXValueGetType(sizeValue as! AXValue) == .cgSize {
						AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
					}
					
					let frame = CGRect(origin: position, size: size)
					if frame.width > 10 && frame.height > 10 {
						axWindowFrame = frame
						axFrameStr = "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width))x\(Int(frame.height))"
					}
				}
			}
		}

		logs.append("[VisualTarget] ax_window_frame=\(axFrameStr)")

		var targetRect: CGRect? = nil
		var targetScreen: NSScreen? = nil
		var selectionReason = "active_window_center"
		var selectedDisplayStr = "nil"

		let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080

		if let axFrame = axWindowFrame {
			targetRect = axFrame
			// Find the screen containing AX frame center
			let centerQuartz = CGPoint(x: axFrame.midX, y: axFrame.midY)
			let centerAppKit = CGPoint(x: centerQuartz.x, y: primaryScreenHeight - centerQuartz.y)
			if let screen = NSScreen.screens.first(where: { NSPointInRect(centerAppKit, $0.frame) }) {
				targetScreen = screen
			}
		} else {
			// AX not available, fall back to CGWindowList center to pick display
			var fallbackCenter: CGPoint? = nil
			if let app = NSWorkspace.shared.frontmostApplication,
			   let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
				
				let pid = app.processIdentifier
				let candidates: [CGRect] = raw.compactMap { dict in
					guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int, ownerPid == Int(pid) else { return nil }
					let layer = dict[kCGWindowLayer as String] as? Int ?? 0
					guard layer == 0 else { return nil }
					let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
					guard isOnScreen else { return nil }
					guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] else { return nil }
					let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) ?? .zero
					guard bounds.width >= 120, bounds.height >= 120 else { return nil }
					return bounds
				}
				if let bestBounds = candidates.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) {
					fallbackCenter = CGPoint(x: bestBounds.midX, y: bestBounds.midY)
				}
			}

			if let centerQuartz = fallbackCenter {
				let centerAppKit = CGPoint(x: centerQuartz.x, y: primaryScreenHeight - centerQuartz.y)
				if let screen = NSScreen.screens.first(where: { NSPointInRect(centerAppKit, $0.frame) }) {
					targetScreen = screen
				}
			}
		}

		if let screen = targetScreen {
			let frame = screen.frame
			let quartzY = primaryScreenHeight - frame.origin.y - frame.size.height
			let screenQuartzRect = CGRect(x: frame.origin.x, y: quartzY, width: frame.size.width, height: frame.size.height)
			if targetRect == nil {
				targetRect = screenQuartzRect
			}
			selectedDisplayStr = "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width))x\(Int(frame.size.height))"
		} else if targetRect == nil {
			// Complete fallback: main screen
			if let mainScreen = NSScreen.main {
				targetScreen = mainScreen
				let frame = mainScreen.frame
				let quartzY = primaryScreenHeight - frame.origin.y - frame.size.height
				targetRect = CGRect(x: frame.origin.x, y: quartzY, width: frame.size.width, height: frame.size.height)
				selectedDisplayStr = "main_display"
			}
		}

		if selectedDisplayStr != "nil" {
			logs.append("[VisualTarget] selected_display=\(selectedDisplayStr) reason=\(selectionReason)")
		}

		return (targetRect, targetScreen, logs)
	}

	static func getActiveAppAndTitle() -> (app: String, title: String) {
		let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
		var activeTitle = "unknown"

		if let app = NSWorkspace.shared.frontmostApplication {
			// 1. Try AX Window Title first
			let axApp = AXUIElementCreateApplication(app.processIdentifier)
			var tempWindow: CFTypeRef?
			var extractedTitle: String? = nil
			
			if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &tempWindow) == .success ||
			   AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &tempWindow) == .success {
				let windowElement = tempWindow as! AXUIElement
				var titleValue: CFTypeRef?
				if AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue) == .success,
				   let titleStr = titleValue as? String, !titleStr.isEmpty {
					extractedTitle = titleStr
				}
			}
			
			if let title = extractedTitle {
				activeTitle = title
			} else {
				// 2. Fall back to CGWindowListCopyWindowInfo
				if let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
					let pid = app.processIdentifier
					let candidates = raw.compactMap { dict -> (String, CGFloat)? in
						guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int, ownerPid == Int(pid) else { return nil }
						let layer = dict[kCGWindowLayer as String] as? Int ?? 0
						guard layer == 0 else { return nil }
						let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
						guard isOnScreen else { return nil }
						guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] else { return nil }
						let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) ?? .zero
						let title = dict[kCGWindowName as String] as? String ?? ""
						guard !title.isEmpty else { return nil }
						return (title, bounds.width * bounds.height)
					}
					if let best = candidates.max(by: { $0.1 < $1.1 }) {
						activeTitle = best.0
					}
				}
			}
		}

		if activeTitle == "unknown", let app = NSWorkspace.shared.frontmostApplication {
			activeTitle = app.localizedName ?? "unknown"
		}

		return (activeApp, activeTitle)
	}
}
