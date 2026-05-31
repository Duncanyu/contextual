import AppKit
import ApplicationServices
import Foundation

/// Runtime AX probe — walks each browser's focused-window tree once and logs
/// exactly which attributes are reachable. This is the per-machine ground
/// truth the architecture report could not produce from a terminal probe.
///
/// Trigger:
///   CONTEXTUAL_RUN_BROWSER_AX_PROBE=1
///
/// Logs (one per browser, even when not running):
///   [BrowserAXProbe] browser=<name> running=yes/no
///   [BrowserAXProbe] browser=<name> url_available=yes/no source=<axurl|ax_textfield|none>
///   [BrowserAXProbe] browser=<name> tabs_available=yes/no count=<n>
///   [BrowserAXProbe] browser=<name> webarea_frame=<x,y,w,h>|none
///   [BrowserAXProbe] browser=<name> scrollarea_frame=<x,y,w,h>|none
enum BrowserAXProbe {

    private static let browsers: [(bundle: String, name: String)] = [
        ("com.apple.Safari", "Safari"),
        ("com.google.Chrome", "Chrome"),
        ("org.mozilla.firefox", "Firefox"),
        ("company.thebrowser.Browser", "Arc"),
    ]

    static func run() {
        print("[BrowserAXProbe] started ax_trusted=\(AXIsProcessTrusted())")
        for (bundle, name) in browsers {
            probe(bundle: bundle, name: name)
        }
        print("[BrowserAXProbe] completed")
    }

    private static func probe(bundle: String, name: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            print("[BrowserAXProbe] browser=\(name) running=no")
            return
        }
        print("[BrowserAXProbe] browser=\(name) running=yes pid=\(app.processIdentifier)")
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              focused != nil else {
            print("[BrowserAXProbe] browser=\(name) focused_window=no")
            return
        }
        let win = focused as! AXUIElement

        // Walk descendants (depth limit 6) — collect URLs, tab strings, and frames.
        let walk = walkDescendants(of: win, depthLimit: 6)
        let urlInfo = extractURL(walk: walk)
        let tabInfo = extractTabs(walk: walk)
        let webAreaFrame = walk.first(where: { $0.role == "AXWebArea" })?.frame
        let scrollAreaFrame = walk.first(where: { $0.role == "AXScrollArea" })?.frame

        print("[BrowserAXProbe] browser=\(name) url_available=\(urlInfo.found ? "yes" : "no") source=\(urlInfo.source)")
        print("[BrowserAXProbe] browser=\(name) tabs_available=\(tabInfo.count > 0 ? "yes" : "no") count=\(tabInfo.count)")
        print("[BrowserAXProbe] browser=\(name) webarea_frame=\(format(webAreaFrame))")
        print("[BrowserAXProbe] browser=\(name) scrollarea_frame=\(format(scrollAreaFrame))")
    }

    // MARK: - Tree walk

    struct AXNode { let role: String; let frame: CGRect?; let element: AXUIElement }

    private static func walkDescendants(of element: AXUIElement, depthLimit: Int, depth: Int = 0, maxNodes: Int = 600) -> [AXNode] {
        if depth >= depthLimit { return [] }
        var out: [AXNode] = []
        let role = stringAttr(element, kAXRoleAttribute as CFString) ?? ""
        let frame = frameAttr(element)
        out.append(AXNode(role: role, frame: frame, element: element))
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

    private static func extractURL(walk: [AXNode]) -> (found: Bool, source: String) {
        // 1. AXWebArea.AXURL (Safari/Chrome)
        if let webArea = walk.first(where: { $0.role == "AXWebArea" }) {
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(webArea.element, "AXURL" as CFString, &urlRef) == .success,
               urlRef != nil {
                return (true, "ax_webarea_axurl")
            }
        }
        // 2. Any AXTextField whose value starts with http (Firefox URL bar, Chrome omnibox)
        for node in walk where node.role == "AXTextField" || node.role == "AXComboBox" {
            if let v = stringAttr(node.element, kAXValueAttribute as CFString),
               v.hasPrefix("http") {
                return (true, "ax_textfield")
            }
        }
        return (false, "none")
    }

    private static func extractTabs(walk: [AXNode]) -> (count: Int, titles: [String]) {
        // 1. Tab group / Tabs — look for AXTabGroup with AXTabs attribute, or
        //    a contiguous run of AXRadioButton/AXButton siblings whose role
        //    description suggests "tab".
        for node in walk where node.role == "AXTabGroup" {
            var tabsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(node.element, "AXTabs" as CFString, &tabsRef) == .success,
               let arr = tabsRef as? [AXUIElement] {
                let titles = arr.compactMap { stringAttr($0, kAXTitleAttribute as CFString) }
                return (titles.count, titles)
            }
        }
        return (0, [])
    }

    // MARK: - AX helpers

    static func stringAttr(_ element: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    static func frameAttr(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, CFGetTypeID(p) == AXValueGetTypeID(),
              let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        guard size.width > 4, size.height > 4 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func format(_ r: CGRect?) -> String {
        guard let r = r else { return "none" }
        return "\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.size.width)),\(Int(r.size.height))"
    }
}
