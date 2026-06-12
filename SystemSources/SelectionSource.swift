import AppKit
import CryptoKit

final class SelectionSource: SystemSource {
	private let onEvent: (SourceEvent) -> Void

	private var pollTimer: Timer?

	private var lastFingerprint: String?
	private var didLogMissingPermission: Bool = false
	private var didPromptForPermission: Bool = false
	private var lastLogSignature: String?
	private var lastLogAt: Date?
	private static let logThrottleSeconds: TimeInterval = 10

	private static let maxCaptureChars = 24_000
	private static let minNonTrivialChars = 2
	private static let minUsefulChars = 30
	private static let maxChildSearchVisited = 80
	private static let maxChildSearchDepth = 4
	private static let maxParentDepth = 3

	init(onEvent: @escaping (SourceEvent) -> Void) {
		self.onEvent = onEvent
	}

	func start() {
		pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
			self?.pollOnce()
		}
		pollOnce()
	}

	func stop() {
		pollTimer?.invalidate()
		pollTimer = nil
	}

	private func pollOnce() {
		let trusted = Self.isAccessibilityTrusted()
		if !trusted {
			if !didLogMissingPermission {
				didLogMissingPermission = true
				print("[SelectionSource] Accessibility permission not granted. Selected text will not be available.")
			}
			return
		}
		didLogMissingPermission = false

		guard let app = NSWorkspace.shared.frontmostApplication else { return }
		let pid = app.processIdentifier
		let appName = app.localizedName ?? "unknown"
		let bundleId = app.bundleIdentifier ?? "unknown"

		let selectedText = fetchSelectedText(forPid: pid, bundleId: bundleId)
		ContentTrustStore.shared.recordSelection(text: selectedText, appName: appName, bundleID: bundleId)
		let fingerprint = fingerprintForText(selectedText)

		guard fingerprint != lastFingerprint else { return }
		lastFingerprint = fingerprint

		onEvent(.sourceChanged(.selectedTextChanged(text: selectedText)))
	}

	static func isAccessibilityTrusted() -> Bool {
		AXIsProcessTrusted()
	}

	static func requestAccessibilityPermissionIfNeeded() {
		if AXIsProcessTrusted() { return }
		let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
		_ = AXIsProcessTrustedWithOptions(options)
	}

	func refreshOnce() {
		if !Self.isAccessibilityTrusted() {
			if !didPromptForPermission {
				didPromptForPermission = true
				Self.requestAccessibilityPermissionIfNeeded()
			}
			return
		}
		pollOnce()
	}

	private func fetchSelectedText(forPid pid: pid_t) -> String? {
		return fetchSelectedText(forPid: pid, bundleId: "unknown")
	}

	private func fetchSelectedText(forPid pid: pid_t, bundleId: String) -> String? {
		let appAX = AXUIElementCreateApplication(pid)

		var focusedElement: CFTypeRef?
		let focusedResult = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &focusedElement)
		guard focusedResult == .success, let focusedElement else {
			print("[SelectionSource] unavailable reason=noFocusedElement bundle=\(bundleId)")
			return nil
		}
		let focusedElementAX = focusedElement as! AXUIElement

		let role = copyAXString(focusedElementAX, attribute: kAXRoleAttribute as CFString) ?? "unknown"

		let result = extractSelection(from: focusedElementAX)
		if let text = result.text, text.count >= Self.minUsefulChars {
			logExtractThrottled(bundleId: bundleId, focusedRole: role, source: result.source, visited: nil, emittedLen: text.count, directLen: result.directLen, rangeLoc: result.rangeLoc, rangeLen: result.rangeLen, valueLen: result.valueLen)
			return cap(text)
		}

		if let found = searchParents(start: focusedElementAX) {
			let text = found.text ?? ""
			logExtractThrottled(bundleId: bundleId, focusedRole: role, source: found.source, visited: nil, emittedLen: text.count, directLen: found.directLen, rangeLoc: found.rangeLoc, rangeLen: found.rangeLen, valueLen: found.valueLen)
			return cap(text)
		}

		let (childFound, visited) = searchChildren(start: focusedElementAX)
		if let childFound {
			let text = childFound.text ?? ""
			logExtractThrottled(bundleId: bundleId, focusedRole: role, source: childFound.source, visited: visited, emittedLen: text.count, directLen: childFound.directLen, rangeLoc: childFound.rangeLoc, rangeLen: childFound.rangeLen, valueLen: childFound.valueLen)
			return cap(text)
		}

		logExtractThrottled(bundleId: bundleId, focusedRole: role, source: "none", visited: visited, emittedLen: 0, directLen: result.directLen, rangeLoc: result.rangeLoc, rangeLen: result.rangeLen, valueLen: result.valueLen)
		return nil
	}

	private struct ExtractResult {
		let text: String?
		let source: String
		let directLen: Int
		let rangeLoc: Int?
		let rangeLen: Int?
		let valueLen: Int?
	}

	private func extractSelection(from element: AXUIElement) -> ExtractResult {
		let direct = copyAXString(element, attribute: kAXSelectedTextAttribute as CFString)
		let directLen = direct?.count ?? 0
		if let direct, direct.count >= Self.minNonTrivialChars {
			return ExtractResult(text: direct, source: "focused/direct", directLen: directLen, rangeLoc: nil, rangeLen: nil, valueLen: nil)
		}

		let derived = deriveSelectedTextFromRangeAndValue(element: element)
		if let text = derived.text, text.count >= Self.minNonTrivialChars {
			return ExtractResult(text: text, source: "focused/range", directLen: directLen, rangeLoc: derived.rangeLoc, rangeLen: derived.rangeLen, valueLen: derived.valueLen)
		}

		return ExtractResult(text: nil, source: "focused/none", directLen: directLen, rangeLoc: derived.rangeLoc, rangeLen: derived.rangeLen, valueLen: derived.valueLen)
	}

	private func searchParents(start: AXUIElement) -> ExtractResult? {
		var current: AXUIElement? = start
		var depth = 0
		while let el = current, depth < Self.maxParentDepth {
			let role = copyAXString(el, attribute: kAXRoleAttribute as CFString) ?? "unknown"
			let extracted = extractSelectionFromElement(el, label: "parentDepth=\(depth)", role: role)
			if let extracted, let text = extracted.text, text.count >= Self.minUsefulChars {
				return extracted
			}
			current = copyAXElement(el, attribute: kAXParentAttribute as CFString)
			depth += 1
		}
		return nil
	}

	private func searchChildren(start: AXUIElement) -> (ExtractResult?, Int) {
		var queue: [(AXUIElement, Int)] = [(start, 0)]
		var visited = 0

		while !queue.isEmpty && visited < Self.maxChildSearchVisited {
			let (el, depth) = queue.removeFirst()
			visited += 1
			if depth > Self.maxChildSearchDepth { continue }

			let role = copyAXString(el, attribute: kAXRoleAttribute as CFString) ?? "unknown"
			if isTextBearingRole(role) {
				let extracted = extractSelectionFromElement(el, label: "childSearch", role: role)
				if let extracted, let text = extracted.text, text.count >= Self.minUsefulChars {
					return (extracted, visited)
				}
			}

			if let children = copyAXElements(el, attribute: kAXChildrenAttribute as CFString) {
				for child in children {
					queue.append((child, depth + 1))
				}
			}
		}

		return (nil, visited)
	}

	private func extractSelectionFromElement(_ element: AXUIElement, label: String, role: String) -> ExtractResult? {
		let direct = copyAXString(element, attribute: kAXSelectedTextAttribute as CFString)
		let directLen = direct?.count ?? 0
		if let direct, direct.count >= Self.minUsefulChars {
			return ExtractResult(text: direct, source: "\(label)/direct", directLen: directLen, rangeLoc: nil, rangeLen: nil, valueLen: nil)
		}

		let derived = deriveSelectedTextFromRangeAndValue(element: element)
		if let text = derived.text, text.count >= Self.minUsefulChars {
			return ExtractResult(text: text, source: "\(label)/range", directLen: directLen, rangeLoc: derived.rangeLoc, rangeLen: derived.rangeLen, valueLen: derived.valueLen)
		}

		return nil
	}

	private func isTextBearingRole(_ role: String) -> Bool {
		switch role {
		case "AXTextArea", "AXTextField", "AXStaticText", "AXWebArea", "AXGroup", "AXOutline", "AXRow", "AXCell":
			return true
		default:
			return false
		}
	}

	private func cap(_ text: String) -> String {
		if text.count <= Self.maxCaptureChars { return text }
		let idx = text.index(text.startIndex, offsetBy: Self.maxCaptureChars)
		return String(text[..<idx])
	}

	private func logExtract(bundleId: String, focusedRole: String, source: String, visited: Int?, emittedLen: Int, directLen: Int, rangeLoc: Int?, rangeLen: Int?, valueLen: Int?) {
		let visitedStr = visited.map(String.init) ?? "nil"
		print("[SelectionSource] focusedRole=\(focusedRole) extractionSource=\(source) visitedCount=\(visitedStr) directLen=\(directLen) rangeLoc=\(rangeLoc.map(String.init) ?? "nil") rangeLen=\(rangeLen.map(String.init) ?? "nil") valueLen=\(valueLen.map(String.init) ?? "nil") emittedLen=\(emittedLen) bundle=\(bundleId)")
	}

	private func logExtractThrottled(bundleId: String, focusedRole: String, source: String, visited: Int?, emittedLen: Int, directLen: Int, rangeLoc: Int?, rangeLen: Int?, valueLen: Int?) {
		let visitedStr = visited.map(String.init) ?? "nil"
		let sig = "\(bundleId)|\(focusedRole)|\(source)|\(visitedStr)|\(directLen)|\(rangeLoc ?? -1)|\(rangeLen ?? -1)|\(valueLen ?? -1)|\(emittedLen)"
		let now = Date()
		if sig == lastLogSignature, let at = lastLogAt, now.timeIntervalSince(at) < Self.logThrottleSeconds {
			return
		}
		lastLogSignature = sig
		lastLogAt = now
		logExtract(bundleId: bundleId, focusedRole: focusedRole, source: source, visited: visited, emittedLen: emittedLen, directLen: directLen, rangeLoc: rangeLoc, rangeLen: rangeLen, valueLen: valueLen)
	}

	private func deriveSelectedTextFromRangeAndValue(element: AXUIElement) -> (text: String?, rangeLoc: Int?, rangeLen: Int?, valueLen: Int?) {
		var rangeValueRef: CFTypeRef?
		let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValueRef)
		guard rangeResult == .success, let rangeValueRef else { return (nil, nil, nil, nil) }
		let axValue = rangeValueRef as! AXValue

		var cfRange = CFRange()
		guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return (nil, nil, nil, nil) }
		let loc = cfRange.location
		let len = cfRange.length

		var valueRef: CFTypeRef?
		let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
		guard valueResult == .success, let fullValue = valueRef as? String else {
			return (nil, loc, len, nil)
		}

		let ns = fullValue as NSString
		let valueLength = ns.length

		guard loc >= 0, len > 0, loc <= valueLength else {
			return (nil, loc, len, valueLength)
		}
		let maxLen = valueLength - loc
		let safeLen = min(len, maxLen)
		guard safeLen > 0 else { return (nil, loc, len, valueLength) }
		let extracted = ns.substring(with: NSRange(location: loc, length: safeLen))
		if extracted.count < Self.minNonTrivialChars {
			return (nil, loc, len, valueLength)
		}
		return (extracted, loc, len, valueLength)
	}

	private func copyAXString(_ element: AXUIElement, attribute: CFString) -> String? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
		return value as? String
	}

	private func copyAXElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
		guard let value else { return nil }
		return value as! AXUIElement
	}

	private func copyAXElements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
		guard let arr = value as? [AXUIElement] else { return nil }
		return arr
	}

	private func fingerprintForText(_ text: String?) -> String? {
		guard let text else { return nil }
		let digest = SHA256.hash(data: Data(text.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}
}
