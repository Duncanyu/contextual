import AppKit
import CoreGraphics
import Foundation

// MARK: - AXClickableElement

/// A clickable UI element discovered by walking the AX accessibility tree.
/// Frame and center are in Quartz/CGEvent screen coordinates (origin: top-left of screen).
struct AXClickableElement: Sendable {
    let label:    String      // primary human-readable label (title / description / value)
    let role:     String      // AX role string e.g. "AXButton", "AXLink"
    let frame:    CGRect      // element bounding rect in screen coords
    let center:   CGPoint     // midpoint for click delivery
    let isLink:   Bool
    let isButton: Bool
    let isField:  Bool        // text input

    var shortDescription: String {
        "role=\(role) label=\"\(label.prefix(40))\" frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"
    }
}

// MARK: - Grounded click target

/// Result of matching a natural-language click target against enumerated AX elements.
struct GroundedClickTarget: Sendable {
    let element:    AXClickableElement
    let confidence: Float         // 0–1; how well the label matched the target description
    let matchReason: String       // e.g. "exact_substring", "word_overlap_0.80"
}

// MARK: - DirectAgentGrounder

/// Grounds natural-language click targets against real UI elements.
///
/// Pipeline:
///   1. Walk the active window's AX tree (bounded: 150 elements, 0.15s wall-time)
///   2. Collect interactive elements (buttons, links, text fields, cells, menu items)
///      with their screen-coordinate frames
///   3. Score each element against the target string using text similarity
///   4. Apply safety filter — block if target implies financial/destructive action
///
/// Logs:
///   [DirectAgentGrounder] enumerated count=...
///   [DirectAgentGrounder] matched=yes source=ax role=... label=... frame=...
///   [DirectAgentGrounder] matched=no reason=...
///   [DirectAgentGrounder] blocked reason=unsafe_target target=...
enum DirectAgentGrounder {

    // MARK: - Safety

    /// Unsafe keyword phrases. If the target description contains any of these (case-insensitive)
    /// the click is blocked regardless of whether an element was found.
    ///
    /// Philosophy: false positives (blocking a safe click) are better than false negatives
    /// (executing a financial or destructive action). The user can always re-invoke.
    private static let unsafePhrases: [String] = [
        // Financial
        "buy", "purchase", "checkout", "place order", "confirm order",
        "pay now", "pay ", "submit payment", "add to cart", "add to bag",
        // Destructive
        "delete", "remove account", "uninstall", "erase",
        // Auth
        "sign in", "log in", "login", "create account", "register",
        // System / permissions
        "install", "allow permissions", "grant access", "allow access",
        "enable location", "enable camera", "enable microphone",
        // Misc high-risk
        "send", "submit form",
    ]

    /// Returns true if the target description is safe to click.
    static func isSafeTarget(_ target: String) -> Bool {
        let t = target.lowercased()
        for phrase in unsafePhrases where t.contains(phrase) {
            print("[DirectAgentGrounder] blocked reason=unsafe_target matched_phrase=\"\(phrase)\" target=\"\(target.prefix(80))\"")
            return false
        }
        return true
    }

    // MARK: - AX Fallback Quality Gate

    /// Browser chrome noise labels — toolbar/tab-strip elements that should never be
    /// accepted as AX fallback click targets.
    private static let browserChromeLabels: Set<String> = [
        "back", "forward", "reload", "refresh", "stop", "home",
        "new tab", "close tab", "bookmark", "bookmarks", "bookmark bar",
        "address", "address bar", "url", "search bar", "tab bar",
        "close", "minimize", "maximize", "zoom",
        "sidebar", "reading list", "downloads", "history",
        "favorites bar", "toolbar",
    ]

    /// Returns false for AX fallback targets that are garbage: very short labels,
    /// known browser chrome noise, or elements positioned inside the top browser
    /// chrome region (tab bar / address bar / bookmarks bar).
    ///
    /// Logs `[DirectAgentClickSafety] rejected_ax_target reason=...` when rejecting.
    static func isQualityAXTarget(_ el: AXClickableElement) -> Bool {
        let label = el.label.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reject labels shorter than 3 characters (catches single letters like "u").
        guard label.count >= 3 else {
            print("[DirectAgentClickSafety] rejected_ax_target reason=garbage_label label=\"\(label)\"")
            return false
        }

        // Reject labels whose non-whitespace content is still < 3 characters.
        let nonSpace = label.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined()
        guard nonSpace.count >= 3 else {
            print("[DirectAgentClickSafety] rejected_ax_target reason=garbage_label label=\"\(label)\"")
            return false
        }

        // Reject known browser chrome noise labels.
        if browserChromeLabels.contains(label.lowercased()) {
            print("[DirectAgentClickSafety] rejected_ax_target reason=browser_chrome_noise label=\"\(label)\"")
            return false
        }

        // Reject elements sitting inside the top browser chrome strip (y < 150, height < 36).
        // This covers the tab bar, address bar, and bookmarks bar on most displays.
        let topChromeThreshold: CGFloat = 150
        if el.frame.origin.y < topChromeThreshold && el.frame.size.height < 36 {
            print("[DirectAgentClickSafety] rejected_ax_target reason=browser_chrome_region frame=\(Int(el.frame.origin.x)),\(Int(el.frame.origin.y)) \(Int(el.frame.size.width))x\(Int(el.frame.size.height))")
            return false
        }

        return true
    }

    /// Returns true when the element's label shares at least one meaningful word (3+ chars)
    /// with the goal description. Used to gate AX fallback after VLM grounding failure —
    /// rejects elements with no semantic connection to what the user is trying to click.
    static func isGoalAligned(_ el: AXClickableElement, goal: String) -> Bool {
        let labelWords = Set(
            el.label.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
        let goalWords = Set(
            goal.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
        guard !labelWords.isEmpty, !goalWords.isEmpty else { return false }
        return !labelWords.intersection(goalWords).isEmpty
    }

    // MARK: - AX enumeration

    /// Walk the frontmost application's AX tree and return clickable interactive elements.
    /// All coordinates are in Quartz screen space (origin: top-left).
    static func enumerateClickableElements(
        maxElements: Int = 150,
        timeLimit:   TimeInterval = 0.15
    ) -> [AXClickableElement] {
        guard AXIsProcessTrusted() else {
            print("[DirectAgentGrounder] skipped reason=ax_not_trusted")
            return []
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            print("[DirectAgentGrounder] skipped reason=no_frontmost_app")
            return []
        }

        let axApp  = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = focusedWindow(for: axApp) else {
            print("[DirectAgentGrounder] skipped reason=no_focused_window")
            return []
        }

        let start    = Date()
        var visited  = 0
        var elements = [AXClickableElement]()

        // Interactive roles we care about for click grounding
        let targetRoles: Set<String> = [
            "AXButton", "AXLink", "AXTextField", "AXTextArea",
            "AXCell", "AXMenuItem", "AXRadioButton", "AXCheckBox",
            "AXPopUpButton", "AXComboBox", "AXTab",
        ]

        // DFS
        var stack: [AXUIElement] = [window]
        while let node = stack.popLast() {
            if visited >= maxElements { break }
            if Date().timeIntervalSince(start) > timeLimit { break }
            visited += 1

            // Skip hidden nodes
            var hiddenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, "AXHidden" as CFString, &hiddenRef) == .success,
               let hv = hiddenRef as? Bool, hv { continue }

            let role = axString(node, kAXRoleAttribute as CFString) ?? ""

            if targetRoles.contains(role) {
                if let el = buildElement(node: node, role: role) {
                    elements.append(el)
                }
            }

            // Push children
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children.reversed() { stack.append(child) }
            }
        }

        print("[DirectAgentGrounder] enumerated count=\(elements.count) visited=\(visited) elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        return elements
    }

    // MARK: - Grounding

    /// Find the best AX element matching a natural-language target description.
    static func ground(
        target:   String,
        elements: [AXClickableElement]
    ) -> GroundedClickTarget? {
        guard !target.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard !elements.isEmpty else { return nil }

        var best: (element: AXClickableElement, score: Float, reason: String)? = nil

        let normTarget = normalise(target)
        let targetWords = Set(normTarget.split(separator: " ").map(String.init))

        for el in elements {
            let normLabel = normalise(el.label)
            guard !normLabel.isEmpty else { continue }

            // Score 1: exact substring
            if normLabel.contains(normTarget) || normTarget.contains(normLabel) {
                let score: Float = normLabel == normTarget ? 1.0 : 0.92
                if best == nil || score > best!.score {
                    best = (el, score, "exact_substring")
                }
                continue
            }

            // Score 2: word overlap
            let labelWords = Set(normLabel.split(separator: " ").map(String.init))
            let shared = targetWords.intersection(labelWords)
            if !shared.isEmpty {
                let recall    = Float(shared.count) / Float(targetWords.count)
                let precision = Float(shared.count) / Float(labelWords.count)
                let f1        = 2 * recall * precision / (recall + precision + 1e-6)
                if f1 >= 0.30 {
                    if best == nil || f1 > best!.score {
                        best = (el, f1, "word_overlap_\(String(format: "%.2f", f1))")
                    }
                }
            }
        }

        guard let winner = best, winner.score >= 0.30 else {
            print("[DirectAgentGrounder] matched=no reason=no_element_above_threshold target=\"\(target.prefix(60))\"")
            return nil
        }

        print("[DirectAgentGrounder] matched=yes source=ax \(winner.element.shortDescription) score=\(String(format: "%.2f", winner.score)) reason=\(winner.reason)")
        return GroundedClickTarget(
            element:     winner.element,
            confidence:  winner.score,
            matchReason: winner.reason
        )
    }

    // MARK: - Private helpers

    private static func focusedWindow(for axApp: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              ref != nil else {
            // Fall back to main window
            var mainRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainRef) == .success,
                  let w = mainRef else { return nil }
            return (w as! AXUIElement)
        }
        return (ref as! AXUIElement)
    }

    private static func buildElement(node: AXUIElement, role: String) -> AXClickableElement? {
        // Collect frame (position + size in Quartz screen coords)
        var posRef:  CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(node, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pr = posRef, CFGetTypeID(pr) == AXValueGetTypeID(),
              let sr = sizeRef, CFGetTypeID(sr) == AXValueGetTypeID() else { return nil }
        let posAX  = pr as! AXValue
        let sizeAX = sr as! AXValue

        var pos  = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posAX,  .cgPoint, &pos)
        AXValueGetValue(sizeAX, .cgSize,  &size)

        // Reject invisible/zero-size elements
        guard size.width >= 4, size.height >= 4 else { return nil }
        let frame  = CGRect(origin: pos, size: size)
        let center = CGPoint(x: frame.midX, y: frame.midY)

        // Primary label — try title, then description, then value, then placeholder
        let label = [
            axString(node, kAXTitleAttribute as CFString),
            axString(node, kAXDescriptionAttribute as CFString),
            axString(node, kAXValueAttribute as CFString),
            axString(node, "AXPlaceholderValue" as CFString),
        ].compactMap { $0 }.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""

        return AXClickableElement(
            label:    label,
            role:     role,
            frame:    frame,
            center:   center,
            isLink:   role == "AXLink",
            isButton: role == "AXButton",
            isField:  role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
        )
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let str = ref as? String, !str.isEmpty else { return nil }
        return str
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased()
         .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
         .components(separatedBy: .whitespaces)
         .filter { !$0.isEmpty }
         .joined(separator: " ")
    }
}
