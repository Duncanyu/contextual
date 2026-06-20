import AppKit
import ApplicationServices
import Foundation

/// Read-only browser context via Accessibility (AX) API.
/// Restricted to non-agentic reading of current tab URL and tab titles.
///
/// Phase 20D upgrade — proper AXWebArea descendant traversal, real `AXURL`
/// query, real `AXTabs` query, and exposes the AXWebArea / AXScrollArea
/// frames so `SurgicalOCR` can crop to actual page content instead of using a
/// hardcoded rectangle.
public struct BrowserContextExtractor: Sendable {

    public struct BrowserContext: Sendable {
        public let appName: String
        public let selectedTitle: String?
        public let currentURL: URL?
        /// Best-effort "selected tab" URL. Most browsers expose only the
        /// frontmost web area URL; treat that as the selected URL.
        public let selectedURL: URL?
        public let recentTabTitles: [String]
        public let webAreaFrame: CGRect?
        public let scrollAreaFrame: CGRect?
    }

    private static let browserNames: Set<String> = [
        "Safari", "Google Chrome", "Firefox", "Arc",
    ]

    public static var lastExtractedURL: String? = nil
    public static var lastSelectedURL: String? = nil

    public static var mockResult: BrowserContext?

    public static func extract(appName: String, activeAppPID: pid_t?) -> BrowserContext? {
        #if DEBUG
        if let mock = mockResult {
            return mock
        }
        #endif
        
        guard browserNames.contains(appName) else { return nil }
        let app = NSWorkspace.shared.runningApplications.first { $0.localizedName == appName }
        guard let pid = activeAppPID ?? app?.processIdentifier else { return nil }

        print("[BrowserContextExtractor] started app=\(appName) pid=\(pid)")
        guard AXIsProcessTrusted() else {
            print("[BrowserContextExtractor] current_url_found=no source=none reason=ax_not_trusted")
            return nil
        }

        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              focused != nil else {
            print("[BrowserContextExtractor] current_url_found=no source=none reason=no_focused_window")
            return nil
        }
        let win = focused as! AXUIElement

        let walk = walkDescendants(of: win, depthLimit: 6)

        // 1. URL — try AXWebArea.AXURL first (Safari/Chrome), then any
        //    AXTextField/AXComboBox whose value starts with http (Firefox URL
        //    bar, Chrome omnibox before the address shortens).
        var url: URL? = nil
        var urlSource = "none"
        if let webArea = walk.first(where: { $0.role == "AXWebArea" }) {
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(webArea.element, "AXURL" as CFString, &urlRef) == .success,
               let any = urlRef {
                if let u = any as? URL {
                    url = u; urlSource = "ax_webarea_axurl"
                } else if let s = any as? String, let u = URL(string: s) {
                    url = u; urlSource = "ax_webarea_axurl"
                } else if let n = any as? NSURL {
                    url = n as URL; urlSource = "ax_webarea_axurl"
                }
            }
        }
        if url == nil {
            for node in walk where node.role == "AXTextField" || node.role == "AXComboBox" {
                if let v = BrowserAXProbe.stringAttr(node.element, kAXValueAttribute as CFString),
                   v.hasPrefix("http"),
                   let u = URL(string: v) {
                    url = u; urlSource = "ax_textfield"
                    break
                }
            }
        }
        if let u = url {
            lastExtractedURL = u.absoluteString
            lastSelectedURL = u.absoluteString
        }
        print("[BrowserContextExtractor] current_url_found=\(url != nil ? "yes" : "no") source=\(urlSource)")

        // 2. Tabs — AXTabGroup with AXTabs attribute.
        var tabTitles: [String] = []
        var selectedTabTitle: String? = nil
        if let tabGroup = walk.first(where: { $0.role == "AXTabGroup" }) {
            var tabsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(tabGroup.element, "AXTabs" as CFString, &tabsRef) == .success,
               let arr = tabsRef as? [AXUIElement] {
                for tab in arr {
                    if let title = BrowserAXProbe.stringAttr(tab, kAXTitleAttribute as CFString) {
                        tabTitles.append(title)
                        var selRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(tab, "AXSelected" as CFString, &selRef) == .success,
                           let sel = selRef as? Bool, sel {
                            selectedTabTitle = title
                        }
                    }
                }
            }
        }
        print("[BrowserContextExtractor] tab_titles=[\(tabTitles.joined(separator: ", "))]")

        if let st = selectedTabTitle {
            print("[BrowserTabs] selected_title=\"\(st.prefix(120))\"")
        }
		print("[BrowserTabs] selected_url_found=\(url != nil ? "yes" : "no")")

        // 3. Frames for surgical OCR.
        let webAreaFrame = walk.first(where: { $0.role == "AXWebArea" })?.frame
        let scrollAreaFrame = walk.first(where: { $0.role == "AXScrollArea" })?.frame

        return BrowserContext(
            appName: appName,
            selectedTitle: selectedTabTitle,
            currentURL: url,
            selectedURL: url,
            recentTabTitles: tabTitles,
            webAreaFrame: webAreaFrame,
            scrollAreaFrame: scrollAreaFrame
        )
    }

    /// Best-effort article/body text from AX static text under the focused web area.
    /// Beats OCR when the browser exposes readable body copy.
    public static func visibleBodyText(appName: String, activeAppPID: pid_t?) -> String? {
        guard browserNames.contains(appName) else { return nil }
        guard AXIsProcessTrusted() else { return nil }
        let app = NSWorkspace.shared.runningApplications.first { $0.localizedName == appName }
        guard let pid = activeAppPID ?? app?.processIdentifier else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              focused != nil else { return nil }
        let win = focused as! AXUIElement
        let walk = walkDescendants(of: win, depthLimit: 10, maxNodes: 1200)
        guard let webArea = walk.first(where: { $0.role == "AXWebArea" })?.element else { return nil }

        var fragments: [String] = []
        collectStaticText(from: webArea, depth: 0, depthLimit: 14, out: &fragments, maxFragments: 400)
        let joined = fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
            .joined(separator: "\n")
        let chars = joined.count
        guard chars >= 120 else {
            print("[BrowserVisibleBodyText] app=\(appName) chars=\(chars) status=insufficient")
            return nil
        }
        let quality = ContentQualityModel.evaluate(text: joined, source: "browser_ax_body")
        guard quality.type == .mainContent else {
            print("[BrowserVisibleBodyText] app=\(appName) chars=\(chars) status=rejected reason=\(quality.type.rawValue)")
            return nil
        }
        print("[BrowserVisibleBodyText] app=\(appName) chars=\(chars) status=accepted")
        return joined
    }

    private static func collectStaticText(from element: AXUIElement, depth: Int, depthLimit: Int, out: inout [String], maxFragments: Int) {
        if out.count >= maxFragments || depth >= depthLimit { return }
        let role = BrowserAXProbe.stringAttr(element, kAXRoleAttribute as CFString) ?? ""
        if role == "AXStaticText" || role == "AXHeading" || role == "AXTextArea" {
            if let value = BrowserAXProbe.stringAttr(element, kAXValueAttribute as CFString), value.count >= 8 {
                out.append(value)
            } else if let title = BrowserAXProbe.stringAttr(element, kAXTitleAttribute as CFString), title.count >= 8 {
                out.append(title)
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collectStaticText(from: child, depth: depth + 1, depthLimit: depthLimit, out: &out, maxFragments: maxFragments)
            if out.count >= maxFragments { return }
        }
    }

    private static func walkDescendants(of element: AXUIElement, depthLimit: Int, depth: Int = 0, maxNodes: Int = 600) -> [BrowserAXProbe.AXNode] {
        if depth >= depthLimit { return [] }
        var out: [BrowserAXProbe.AXNode] = []
        let role = BrowserAXProbe.stringAttr(element, kAXRoleAttribute as CFString) ?? ""
        let frame = BrowserAXProbe.frameAttr(element)
        out.append(BrowserAXProbe.AXNode(role: role, frame: frame, element: element))
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                out.append(contentsOf: walkDescendants(of: child, depthLimit: depthLimit, depth: depth + 1, maxNodes: maxNodes))
                if out.count >= maxNodes { return out }
            }
        }
        return out
    }
}
