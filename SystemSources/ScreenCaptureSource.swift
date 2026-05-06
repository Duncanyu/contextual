import AppKit
import CoreGraphics

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

		let image = CGWindowListCreateImage(
			CGRect.infinite,
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
}

