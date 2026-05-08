import AppKit
import CoreGraphics
import Foundation

final class WindowSnapshotSource {
	static let shared = WindowSnapshotSource()

	private var lastSnapshot: WindowSnapshotContext?

	private init() {}

	func hasScreenRecordingPermission() -> Bool {
		ScreenCaptureSource.isScreenRecordingAuthorized()
	}

	/// Attempts to capture the frontmost application's most-likely active window.
	/// - Returns: A `WindowSnapshotContext` containing an in-memory `CGImage`, or `nil` if capture is not possible.
	func captureActiveWindowSnapshot() -> WindowSnapshotContext? {
		ContextDebugLogger.shared.log(stage: .snapshot, event: .collected, source: "activeWindowSnapshot", reason: "attempt")
		guard hasScreenRecordingPermission() else {
			print("[WindowSnapshot] skipped reason=permission_denied")
			ContextDebugLogger.shared.log(stage: .snapshot, event: .skipped, source: "activeWindowSnapshot", reason: "permission_denied")
			return nil
		}

		guard let app = NSWorkspace.shared.frontmostApplication else {
			print("[WindowSnapshot] skipped reason=no_active_window")
			ContextDebugLogger.shared.log(stage: .snapshot, event: .skipped, source: "activeWindowSnapshot", reason: "no_active_window")
			return nil
		}

		let bundleId = app.bundleIdentifier
		if bundleId == Bundle.main.bundleIdentifier {
			print("[WindowSnapshot] skipped reason=contextual_window")
			ContextDebugLogger.shared.log(stage: .snapshot, event: .skipped, source: "activeWindowSnapshot", reason: "contextual_window")
			return nil
		}

		let pid = app.processIdentifier
		guard let windowInfo = pickBestWindowInfo(frontmostPid: pid) else {
			print("[WindowSnapshot] skipped reason=no_matching_window")
			ContextDebugLogger.shared.log(stage: .snapshot, event: .skipped, source: "activeWindowSnapshot", reason: "no_matching_window")
			return nil
		}

		let windowId = windowInfo.windowId
		let bounds = windowInfo.bounds

		// Capture only the identified window. Do not fall back to full-screen capture in this ticket.
		let image = CGWindowListCreateImage(
			bounds,
			.optionIncludingWindow,
			windowId,
			[.bestResolution, .boundsIgnoreFraming]
		)

		guard let image else {
			print("[WindowSnapshot] skipped reason=capture_failed")
			ContextDebugLogger.shared.log(stage: .snapshot, event: .skipped, source: "activeWindowSnapshot", reason: "capture_failed")
			return nil
		}

		let ctx = WindowSnapshotContext(
			id: UUID(),
			capturedAt: Date(),
			appName: app.localizedName,
			bundleIdentifier: bundleId,
			windowTitleAvailable: windowInfo.titleAvailable,
			imageWidth: image.width,
			imageHeight: image.height,
			source: .activeWindow,
			image: image
		)
		lastSnapshot = ctx

		print("[WindowSnapshot] captured app=\(app.localizedName ?? "nil") size=\(image.width)x\(image.height)")
		ContextDebugLogger.shared.log(
			stage: .snapshot,
			event: .collected,
			source: "activeWindowSnapshot",
			cost: .medium,
			privacy: .high,
			meta: ["w": "\(image.width)", "h": "\(image.height)"]
		)
		return ctx
	}

	func clearSnapshot() {
		lastSnapshot = nil
		print("[WindowSnapshot] cleared")
		ContextDebugLogger.shared.log(stage: .snapshot, event: .updated, source: "activeWindowSnapshot", reason: "cleared")
	}

	// MARK: - Window picking

	private struct CandidateWindowInfo {
		let windowId: CGWindowID
		let bounds: CGRect
		let titleAvailable: Bool
		let area: CGFloat
	}

	private func pickBestWindowInfo(frontmostPid: pid_t) -> CandidateWindowInfo? {
		guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
			return nil
		}

		let candidates: [CandidateWindowInfo] = raw.compactMap { dict in
			guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int, ownerPid == Int(frontmostPid) else {
				return nil
			}

			guard let windowNumber = dict[kCGWindowNumber as String] as? Int else { return nil }
			let windowId = CGWindowID(windowNumber)

			let layer = dict[kCGWindowLayer as String] as? Int ?? 0
			guard layer == 0 else { return nil } // avoid menu bar / overlays

			let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
			guard isOnScreen else { return nil }

			let alpha = dict[kCGWindowAlpha as String] as? Double ?? 1.0
			guard alpha > 0.05 else { return nil }

			guard let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] else { return nil }
			let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) ?? .zero
			guard bounds.width >= 120, bounds.height >= 120 else { return nil }

			let titleAvailable: Bool
			if let name = dict[kCGWindowName as String] as? String {
				titleAvailable = !name.isEmpty
			} else {
				titleAvailable = false
			}

			let area = bounds.width * bounds.height
			return CandidateWindowInfo(windowId: windowId, bounds: bounds, titleAvailable: titleAvailable, area: area)
		}

		// Heuristic: choose the largest plausible window for the frontmost app.
		// (CGWindowList ordering isn't guaranteed; avoid assuming "first" is active.)
		return candidates.max(by: { $0.area < $1.area })
	}
}

#if DEBUG
extension WindowSnapshotSource {
	/// Manual debug hook. Call from LLDB:
	/// `expr -l Swift -- WindowSnapshotSource.shared._selfTest()`
	@discardableResult
	func _selfTest() -> Bool {
		let snap = captureActiveWindowSnapshot()
		return snap != nil
	}
}
#endif

