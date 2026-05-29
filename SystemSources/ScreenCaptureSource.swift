import AppKit
import CoreGraphics
import ApplicationServices
import Foundation

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

	// MARK: - Self-tests (pure helpers)

	static func shouldRestoreTargetAnchor(
		currentFrontmostBundleIdentifier: String?,
		targetAnchor: TargetWindowAnchor?,
		assistantBundleIdentifier: String?
	) -> Bool {
		guard
			let targetAnchor,
			let assistantBundleIdentifier,
			currentFrontmostBundleIdentifier == assistantBundleIdentifier,
			targetAnchor.bundleIdentifier != assistantBundleIdentifier
		else { return false }
		return true
	}

	static func openScreenRecordingSettings() {
		if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
			NSWorkspace.shared.open(url)
		} else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
			NSWorkspace.shared.open(url)
		}
	}

	/// One-shot screen frame for explicit execution requests (T17.8). Caller must discard `CGImage` immediately.
	static func captureSingleFrame(targetAnchor: TargetWindowAnchor? = nil) -> (image: CGImage, width: Int, height: Int)? {
		guard isScreenRecordingAuthorized() else { return nil }
		if let anchor = targetAnchor {
			print("[TargetAnchorTrace] stage=screen_capture_single_frame anchor_nil=no")
			print("[TargetAnchorTrace] bundle=\(anchor.bundleIdentifier)")
			print("[TargetAnchorTrace] title=\"\(anchor.windowTitle.prefix(80))\"")
		} else {
			print("[TargetAnchorTrace] stage=screen_capture_single_frame anchor_nil=yes")
		}
		let assistantBundle = Bundle.main.bundleIdentifier
		let (targetRect, _, targetWindowId, logs) = findActiveWindowAndScreen(
			targetAnchor: targetAnchor,
			assistantBundleIdentifier: assistantBundle
		)
		for log in logs {
			print(log)
		}
		if targetAnchor != nil, targetWindowId == nil {
			// Hard fail for anchored capture: falling back to display capture risks self-panel pixels.
			return nil
		}
		let image: CGImage?
		if let targetWindowId {
			image = CGWindowListCreateImage(
				.null,
				.optionIncludingWindow,
				targetWindowId,
				[.bestResolution]
			)
		} else {
			let captureRect = targetRect ?? CGRect.infinite
			image = CGWindowListCreateImage(
				captureRect,
				.optionOnScreenOnly,
				kCGNullWindowID,
				[.bestResolution]
			)
		}
		guard let image else { return nil }
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

		let assistantBundle = Bundle.main.bundleIdentifier
		let (targetRect, _, targetWindowId, logs) = Self.findActiveWindowAndScreen(
			targetAnchor: nil,
			assistantBundleIdentifier: assistantBundle
		)
		for log in logs {
			print(log)
		}
		let image: CGImage?
		if let targetWindowId {
			image = CGWindowListCreateImage(
				.null,
				.optionIncludingWindow,
				targetWindowId,
				[.bestResolution]
			)
		} else {
			let captureRect = targetRect ?? CGRect.infinite
			image = CGWindowListCreateImage(
				captureRect,
				.optionOnScreenOnly,
				kCGNullWindowID,
				[.bestResolution]
			)
		}

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

	static func findActiveWindowAndScreen(
		targetAnchor: TargetWindowAnchor? = nil,
		assistantBundleIdentifier: String? = nil
	) -> (rect: CGRect?, screen: NSScreen?, windowId: CGWindowID?, logs: [String]) {
		var logs: [String] = []
		let (activeApp, activeTitle) = getActiveAppAndTitle()
		logs.append("[VisualTarget] active_app=\(activeApp) active_title=\(activeTitle)")
		if let targetAnchor {
			logs.append("[VisualTarget] target_bundle=\(targetAnchor.bundleIdentifier)")
			logs.append("[VisualTarget] target_title=\"\(targetAnchor.windowTitle.prefix(80))\"")
		}

		// Prefer a specific target window capture when an anchor exists.
		// This must happen BEFORE any display-level fallback to avoid self-panel pixels.
		if let targetAnchor,
		   let assistantBundleIdentifier,
		   targetAnchor.bundleIdentifier != assistantBundleIdentifier {
			logs.append("[TargetWindowResolve] attempted=yes bundle=\(targetAnchor.bundleIdentifier) title=\"\(targetAnchor.windowTitle.prefix(80))\"")
			let resolution = resolveTargetWindowId(
				targetBundleIdentifier: targetAnchor.bundleIdentifier,
				targetWindowTitle: targetAnchor.windowTitle,
				assistantBundleIdentifier: assistantBundleIdentifier
			)
			logs.append(contentsOf: resolution.logs)
			if let resolvedId = resolution.windowId {
				// When capturing a specific window id, we still return bounds so downstream
				// display selection (for logging/telemetry) remains consistent.
				let b = resolution.bounds
				let hasBounds = b != .zero && b.width > 10 && b.height > 10
				let rect = hasBounds ? b : nil
				logs.append("[VisualTarget] capture_mode=target_window")
				logs.append("[SelfWindowExclusion] capture_verified=yes")
				// We return early — no need to compute AX fallback rect when a window id exists.
				return (rect, nil, resolvedId, logs)
			} else {
				logs.append("[TargetWindowResolve] matched=no reason=not_found")
			}
		}

		// Self-window exclusion visibility (Quartz window list).
		if let assistantBundleIdentifier,
		   let assistantApp = NSRunningApplication.runningApplications(withBundleIdentifier: assistantBundleIdentifier).first,
		   let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
			let selfCount = raw.filter { dict in
				let ownerPid = dict[kCGWindowOwnerPID as String] as? Int ?? -1
				let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
				let layer = dict[kCGWindowLayer as String] as? Int ?? 0
				return ownerPid == Int(assistantApp.processIdentifier) && isOnScreen && layer == 0
			}.count
			logs.append("[SelfWindowExclusion] excluded=yes bundle=\(assistantBundleIdentifier) windows=\(selfCount)")
			logs.append("[VisualTarget] self_panel_visible=\(selfCount > 0 ? "yes" : "no")")
		}

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
		let selectionReason = "active_window_center"
		var selectedDisplayStr = "nil"
		let captureExcludesSelf = false

		let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080

		if let axFrame = axWindowFrame {
			if targetRect == nil {
				targetRect = axFrame
			}
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
		logs.append("[VisualTarget] capture_mode=display")
		logs.append("[VisualTarget] capture_excludes_self=no")

		// Warn if we are not excluding self and the assistant is frontmost.
		if !captureExcludesSelf,
		   let assistantBundleIdentifier,
		   NSWorkspace.shared.frontmostApplication?.bundleIdentifier == assistantBundleIdentifier {
			logs.append("[SelfWindowExclusion] warning=self_panel_detected_in_capture")
			logs.append("[SelfWindowExclusion] warning=self_pixels_detected")
		}

		return (targetRect, targetScreen, nil, logs)
	}

	// MARK: - Target-window resolution

	private static func resolveTargetWindowId(
		targetBundleIdentifier: String,
		targetWindowTitle: String,
		assistantBundleIdentifier: String
	) -> (windowId: CGWindowID?, bounds: CGRect, logs: [String]) {
		var logs: [String] = []
		guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleIdentifier).first else {
			logs.append("[TargetWindowResolve] matched=no reason=target_app_not_running")
			return (nil, .zero, logs)
		}

		guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
			logs.append("[TargetWindowResolve] matched=no reason=window_list_unavailable")
			return (nil, .zero, logs)
		}

		let assistantPid = NSRunningApplication.runningApplications(withBundleIdentifier: assistantBundleIdentifier).first?.processIdentifier
		let pid = Int(app.processIdentifier)
		let trimmedTitle = targetWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		let normalizedTarget = normalizeWindowTitle(trimmedTitle)

		logs.append("[TargetWindowResolve] fallback_level=1 exact_title")

		struct Candidate {
			let id: CGWindowID
			let bounds: CGRect
			let name: String
			let area: Double
			let exactTitleMatch: Bool
			let containsTitleMatch: Bool
		}

		let candidates: [Candidate] = raw.compactMap { dict in
			guard (dict[kCGWindowOwnerPID as String] as? Int) == pid else { return nil }
			let layer = dict[kCGWindowLayer as String] as? Int ?? 0
			let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
			let alpha = dict[kCGWindowAlpha as String] as? Double ?? 1.0
			guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] else { return nil }
			let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) ?? .zero

			let idInt = dict[kCGWindowNumber as String] as? Int ?? 0
			if idInt <= 0 { return nil }

			let ownerPid = dict[kCGWindowOwnerPID as String] as? Int ?? -1
			if let assistantPid, ownerPid == Int(assistantPid) { return nil }

			let name = (dict[kCGWindowName as String] as? String ?? "")
				.trimmingCharacters(in: .whitespacesAndNewlines)

			// Diagnostics for *every* enumerated window for this bundle.
			logs.append("[TargetWindowResolve] candidate bundle=\(targetBundleIdentifier) title=\"\(name.prefix(80))\" layer=\(layer) onscreen=\(isOnScreen) alpha=\(String(format: "%.2f", alpha)) bounds=\(Int(bounds.origin.x)),\(Int(bounds.origin.y)),\(Int(bounds.size.width))x\(Int(bounds.size.height))")

			// Keep only likely-real windows.
			guard isOnScreen, layer == 0, alpha > 0.05, bounds.width >= 120, bounds.height >= 120 else {
				return nil
			}

			let normalizedName = normalizeWindowTitle(name)
			let exact = !normalizedTarget.isEmpty && !normalizedName.isEmpty
				&& (normalizedName == normalizedTarget || normalizedName.hasPrefix(normalizedTarget) || normalizedTarget.hasPrefix(normalizedName))
			let contains = !normalizedTarget.isEmpty && !normalizedName.isEmpty
				&& (normalizedName.contains(normalizedTarget) || normalizedTarget.contains(normalizedName))

			let area = Double(bounds.width * bounds.height)
			return Candidate(
				id: CGWindowID(idInt),
				bounds: bounds,
				name: name,
				area: area,
				exactTitleMatch: exact,
				containsTitleMatch: contains
			)
		}

		guard !candidates.isEmpty else {
			logs.append("[TargetWindowResolve] matched=no reason=no_visible_windows_for_bundle")
			return (nil, .zero, logs)
		}

		if let exact = candidates.first(where: { $0.exactTitleMatch }) {
			logs.append("[TargetWindowResolve] matched=yes method=exact_title window_id=\(exact.id)")
			return (exact.id, exact.bounds, logs)
		}

		logs.append("[TargetWindowResolve] fallback_level=2 normalized_contains")
		if let contains = candidates.first(where: { $0.containsTitleMatch }) {
			logs.append("[TargetWindowResolve] matched=yes method=normalized_contains window_id=\(contains.id)")
			return (contains.id, contains.bounds, logs)
		}

		logs.append("[TargetWindowResolve] fallback_level=3 bundle_largest_visible")
		if let largest = candidates.max(by: { $0.area < $1.area }) {
			logs.append("[TargetWindowResolve] matched=yes method=bundle_largest_visible window_id=\(largest.id)")
			return (largest.id, largest.bounds, logs)
		}

		logs.append("[TargetWindowResolve] matched=no reason=selection_failed")
		return (nil, .zero, logs)
	}

	private static func normalizeWindowTitle(_ s: String) -> String {
		let lowered = s.lowercased()
		let folded = lowered.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
		let cleaned = folded
			.replacingOccurrences(of: "—", with: "-")
			.replacingOccurrences(of: "–", with: "-")
		let allowed = cleaned.unicodeScalars.map { scalar -> Character in
			if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
			if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
			if scalar == "-" { return "-" }
			return " "
		}
		let collapsed = String(allowed)
			.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return collapsed
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
