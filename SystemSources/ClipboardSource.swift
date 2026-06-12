import AppKit
import CryptoKit

struct SelectionTrustSnapshot: Sendable {
	let text: String
	let capturedAt: Date
	let appName: String
	let bundleID: String
}

struct ClipboardTrustSnapshot: Sendable {
	let text: String
	let capturedAt: Date
	let appName: String
	let bundleID: String
	let tiedToSelection: Bool
}

final class ContentTrustStore: @unchecked Sendable {
	static let shared = ContentTrustStore()

	private let lock = NSLock()
	private var lastSelection: SelectionTrustSnapshot?
	private var lastClipboard: ClipboardTrustSnapshot?

	private init() {}

	func recordSelection(text: String?, appName: String, bundleID: String) {
		guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2 else { return }
		lock.lock()
		lastSelection = SelectionTrustSnapshot(text: text, capturedAt: Date(), appName: appName, bundleID: bundleID)
		lock.unlock()
	}

	func recordClipboard(text: String?, appName: String, bundleID: String) {
		guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 2 else { return }
		lock.lock()
		let now = Date()
		let tiedToSelection: Bool = {
			guard let selection = lastSelection else { return false }
			guard selection.bundleID == bundleID else { return false }
			guard now.timeIntervalSince(selection.capturedAt) <= 4 else { return false }
			let ratio = Double(min(selection.text.count, text.count)) / Double(max(selection.text.count, text.count))
			return ratio >= 0.55
		}()
		lastClipboard = ClipboardTrustSnapshot(
			text: text,
			capturedAt: now,
			appName: appName,
			bundleID: bundleID,
			tiedToSelection: tiedToSelection
		)
		lock.unlock()
	}

	func latestSelection(frontmostBundleID: String?) -> SelectionTrustSnapshot? {
		lock.lock()
		defer { lock.unlock() }
		guard let snapshot = lastSelection else { return nil }
		if let frontmostBundleID, !frontmostBundleID.isEmpty, snapshot.bundleID != frontmostBundleID {
			return nil
		}
		return snapshot
	}

	func latestClipboard() -> ClipboardTrustSnapshot? {
		lock.lock()
		defer { lock.unlock() }
		return lastClipboard
	}
}

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
		let app = NSWorkspace.shared.frontmostApplication
		ContentTrustStore.shared.recordClipboard(
			text: text,
			appName: app?.localizedName ?? "unknown",
			bundleID: app?.bundleIdentifier ?? "unknown"
		)

		onEvent(.sourceChanged(.clipboardTextChanged(text: text)))
	}

	private func fingerprintForText(_ text: String?) -> String? {
		guard let text else { return nil }
		let digest = SHA256.hash(data: Data(text.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}
}
