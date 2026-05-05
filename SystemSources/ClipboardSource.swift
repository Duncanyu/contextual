import AppKit
import CryptoKit

final class ClipboardSource: SystemSource {
	private let onEvent: (SourceEvent) -> Void
	private var pollTimer: Timer?

	private var lastChangeCount: Int?
	private var lastFingerprint: String?

	init(onEvent: @escaping (SourceEvent) -> Void) {
		self.onEvent = onEvent
	}

	func start() {
		pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
			self?.pollOnce()
		}

		pollOnce()
	}

	func stop() {
		pollTimer?.invalidate()
		pollTimer = nil
	}

	private func pollOnce() {
		let pasteboard = NSPasteboard.general
		let changeCount = pasteboard.changeCount

		if changeCount == lastChangeCount {
			return
		}
		lastChangeCount = changeCount

		let text = pasteboard.string(forType: .string)
		let fingerprint = fingerprintForText(text)

		guard fingerprint != lastFingerprint else { return }
		lastFingerprint = fingerprint

		onEvent(.sourceChanged(.clipboardTextChanged(text: text)))
	}

	private func fingerprintForText(_ text: String?) -> String? {
		guard let text else { return nil }
		let digest = SHA256.hash(data: Data(text.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}
}

