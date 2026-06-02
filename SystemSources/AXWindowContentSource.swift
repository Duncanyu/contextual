import AppKit
import Foundation

final class AXWindowContentSource {
	static let shared = AXWindowContentSource()

	private var lastContext: AXWindowContentContext?

	// Bounds (conservative defaults)
	private let maxDepth: Int = 8
	private let maxNodes: Int = 220
	private let maxExtractedChars: Int = 6000
	private let maxFragments: Int = 60
	private let maxFragmentLength: Int = 180
	private let maxWallTimeSeconds: TimeInterval = 0.20

	private init() {}

	func hasAccessibilityPermission() -> Bool {
		SelectionSource.isAccessibilityTrusted()
	}

	func clear() {
		lastContext = nil
		print("[AXContent] cleared")
		ContextDebugLogger.shared.log(stage: .ax, event: .updated, source: "axText", reason: "cleared")
	}

	func extractActiveWindowContent() -> AXWindowContentContext? {
		ContextDebugLogger.shared.log(stage: .ax, event: .collected, source: "axText", reason: "attempt")
		guard hasAccessibilityPermission() else {
			print("[AXContent] skipped reason=permission_denied")
			ContextDebugLogger.shared.log(stage: .ax, event: .skipped, source: "axText", reason: "permission_denied")
			return nil
		}

		guard let app = NSWorkspace.shared.frontmostApplication else {
			print("[AXContent] skipped reason=no_focused_window")
			ContextDebugLogger.shared.log(stage: .ax, event: .skipped, source: "axText", reason: "no_focused_window")
			return nil
		}

		let bundleId = app.bundleIdentifier
		if bundleId == Bundle.main.bundleIdentifier {
			print("[AXContent] skipped reason=contextual_window")
			ContextDebugLogger.shared.log(stage: .ax, event: .skipped, source: "axText", reason: "contextual_window")
			return nil
		}
        
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = focusedWindow(for: axApp) else {
            print("[AXContent] skipped reason=no_focused_window")
            ContextDebugLogger.shared.log(stage: .ax, event: .skipped, source: "axText", reason: "no_focused_window")
            return nil
        }
        
        let title = copyAXString(window, attribute: kAXTitleAttribute as CFString) ?? ""
        let windowTitleAvailable = !title.isEmpty
        let url = BrowserContextExtractor.extract(appName: app.localizedName ?? "", activeAppPID: app.processIdentifier)?.currentURL?.absoluteString ?? ""
        
        if let cached = PerformanceBudgetManager.shared.getCachedAX(app: bundleId ?? "", url: url, title: title) {
            print("[PerformanceBudget] skipped reason=cached_context")
            return cached
        }

		let start = Date()

		var visited = 0
		var maxSeenDepth = 0

		var fragments: [String] = []
		var fragmentChars = 0

		var kindsSeen: [AXUIKind] = []
		var kindSet = Set<AXUIKind>()

		var interactiveCount = 0
		var hasScroll = false
		var hasEditor = false
		var hasForm = false
		var hasTable = false
		var hasToolbar = false
		var hasDialog = false

		var textFieldCount = 0
		var buttonCount = 0

		func recordKind(_ kind: AXUIKind) {
			if kindSet.insert(kind).inserted {
				kindsSeen.append(kind)
			}
		}

		func addFragment(_ s: String) {
			guard fragments.count < maxFragments else { return }
			guard fragmentChars < maxExtractedChars else { return }
			let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { return }
			let capped: String
			if trimmed.count > maxFragmentLength {
				let idx = trimmed.index(trimmed.startIndex, offsetBy: maxFragmentLength)
				capped = String(trimmed[..<idx])
			} else {
				capped = trimmed
			}
			// De-dupe exact repeats (common in AX trees)
			if fragments.last == capped { return }
			let remaining = maxExtractedChars - fragmentChars
			if capped.count > remaining { return }
			fragments.append(capped)
			fragmentChars += capped.count
		}

		// DFS with bounds + time budget.
		var stack: [(AXUIElement, Int)] = [(window, 0)]
		var didHitLimit = false

		while let (node, depth) = stack.popLast() {
			if visited >= maxNodes { didHitLimit = true; break }
			if depth > maxDepth { didHitLimit = true; break }
			if Date().timeIntervalSince(start) > maxWallTimeSeconds { didHitLimit = true; break }

			visited += 1
			maxSeenDepth = max(maxSeenDepth, depth)

			// Skip hidden nodes when possible.
			if let hidden = copyAXBool(node, attribute: "AXHidden" as CFString), hidden {
				continue
			}

			let role = copyAXString(node, attribute: kAXRoleAttribute as CFString) ?? "unknown"
			let subrole = copyAXString(node, attribute: kAXSubroleAttribute as CFString)

			switch role {
			case "AXButton":
				recordKind(.button)
				interactiveCount += 1
				buttonCount += 1
				if let t = copyAXString(node, attribute: kAXTitleAttribute as CFString) { addFragment(t) }
				if let d = copyAXString(node, attribute: kAXDescriptionAttribute as CFString) { addFragment(d) }

			case "AXTextField":
				recordKind(.textField)
				interactiveCount += 1
				textFieldCount += 1
				if let p = copyAXString(node, attribute: "AXPlaceholderValue" as CFString) { addFragment(p) }
				if let v = copyAXString(node, attribute: kAXValueAttribute as CFString), v.count <= 120 { addFragment(v) }

			case "AXStaticText":
				recordKind(.staticText)
				if let v = copyAXString(node, attribute: kAXValueAttribute as CFString) { addFragment(v) }

			case "AXScrollArea":
				recordKind(.scrollArea)
				hasScroll = true

			case "AXTable":
				recordKind(.table)
				hasTable = true

			case "AXRow":
				recordKind(.row)

			case "AXList":
				recordKind(.list)
				hasTable = true

			case "AXOutline":
				recordKind(.outline)
				hasTable = true

			case "AXToolbar":
				recordKind(.toolbar)
				hasToolbar = true

			case "AXTextArea":
				// Common editor/terminal role; do not dump full contents.
				recordKind(.editor)
				hasEditor = true
				if let selected = copyAXString(node, attribute: kAXSelectedTextAttribute as CFString), selected.count <= 180 {
					addFragment(selected)
				}
				if let v = copyAXString(node, attribute: kAXValueAttribute as CFString), v.count <= 180 {
					addFragment(v)
				}

			default:
				break
			}

			// Dialog-like hints from role/subrole.
			if role == "AXDialog" || subrole == "AXDialog" {
				hasDialog = true
				recordKind(.dialog)
			}

			// Form-like: multiple fields + buttons.
			if textFieldCount >= 2 && buttonCount >= 1 {
				hasForm = true
			}

			// Traverse children (bounded).
			if let children = copyAXElements(node, attribute: kAXChildrenAttribute as CFString) {
				// Push in reverse so natural order is preserved in DFS popLast.
				for child in children.reversed() {
					stack.append((child, depth + 1))
				}
			}
		}

		let estimatedTextLen = fragments.reduce(0) { $0 + $1.count }
		let controlKinds = kindsSeen.isEmpty ? [.unknown] : kindsSeen

		// Confidence: based on coverage and whether we found any useful signals.
		var conf: Double = 0.40
		if estimatedTextLen > 200 { conf += 0.15 }
		if interactiveCount >= 3 { conf += 0.10 }
		if hasEditor { conf += 0.10 }
		if hasToolbar { conf += 0.05 }
		if hasScroll { conf += 0.05 }
		if didHitLimit { conf -= 0.08 }
		conf = max(0.0, min(1.0, conf))

		let ctx = AXWindowContentContext(
			id: UUID(),
			extractedAt: Date(),
			appName: app.localizedName,
			bundleIdentifier: bundleId,
			sourceWindowTitleAvailable: windowTitleAvailable,
			visibleTextFragments: fragments,
			visibleControlKinds: controlKinds,
			estimatedVisibleTextLength: estimatedTextLen,
			estimatedInteractiveElementCount: interactiveCount,
			containsScrollableRegion: hasScroll,
			containsEditorLikeRegion: hasEditor,
			containsFormLikeRegion: hasForm,
			containsTableLikeRegion: hasTable,
			hierarchyDepthEstimate: maxSeenDepth,
			extractionConfidence: conf
		)

		lastContext = ctx
        
        PerformanceBudgetManager.shared.setCachedAX(app: bundleId ?? "", url: url, title: title, context: ctx)

		let c = String(format: "%.2f", conf)
		print("[AXContent] extracted app=\(app.localizedName ?? "nil") nodes=\(visited) textFragments=\(fragments.count) conf=\(c)")
		ContextDebugLogger.shared.log(
			stage: .ax,
			event: .collected,
			source: "axText",
			privacy: .moderate,
			confidence: conf,
			meta: [
				"nodes": "\(visited)",
				"fragments": "\(fragments.count)",
				"controls": "\(controlKinds.count)"
			]
		)
		if didHitLimit {
			print("[AXContent] skipped reason=depth_limit")
			ContextDebugLogger.shared.log(stage: .ax, event: .skipped, source: "axText", reason: "depth_limit")
		}

		return ctx
	}

	// MARK: - AX helpers

	private func focusedWindow(for axApp: AXUIElement) -> AXUIElement? {
		if let w = copyAXElement(axApp, attribute: kAXFocusedWindowAttribute as CFString) { return w }
		if let w = copyAXElement(axApp, attribute: kAXMainWindowAttribute as CFString) { return w }
		return nil
	}

	private func copyAXString(_ element: AXUIElement, attribute: CFString) -> String? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
		return value as? String
	}

	private func copyAXBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
		if let b = value as? Bool { return b }
		if CFGetTypeID(value) == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
		return nil
	}

	private func copyAXElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
		guard let value else { return nil }
		return (value as! AXUIElement)
	}

	private func copyAXElements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
		return value as? [AXUIElement]
	}
}

extension AXWindowContentSource {
	/// Manual debug hook. Call from LLDB:
	/// `expr -l Swift -- AXWindowContentSource.shared._selfTest()`
	@discardableResult
	func _selfTest() -> Bool {
		let ctx = extractActiveWindowContent()
		guard let ctx else { return false }
		let kinds = ctx.visibleControlKinds.map(\.rawValue).joined(separator: ",")
		let editor = ctx.containsEditorLikeRegion ? "yes" : "no"
		let form = ctx.containsFormLikeRegion ? "yes" : "no"
		let table = ctx.containsTableLikeRegion ? "yes" : "no"
		let scroll = ctx.containsScrollableRegion ? "yes" : "no"
		let conf = String(format: "%.2f", ctx.extractionConfidence)
		print("[AXContent] selftest ok nodes_hint_depth=\(ctx.hierarchyDepthEstimate) fragments=\(ctx.visibleTextFragments.count) kinds=\(kinds) editor=\(editor) form=\(form) table=\(table) scroll=\(scroll) conf=\(conf)")
		return true
	}
}

