import Foundation
import AppKit

// MARK: - Phase 32.1: LiveActionPath log

/// One unified log per click — the most important log for dogfooding.
enum LiveActionPath {
    static func emit(
        capability: String,
        route: String,
        executor: String,
        snapshotAge: TimeInterval,
        hasTargets: Bool,
        hasURLs: Bool,
        willExecute: Bool,
        reason: String
    ) {
        print("[LiveActionPath]"
            + " capability=\(capability)"
            + " route=\(route)"
            + " executor=\(executor)"
            + " snapshot_age=\(String(format: "%.0f", snapshotAge))s"
            + " has_targets=\(hasTargets ? "yes" : "no")"
            + " has_urls=\(hasURLs ? "yes" : "no")"
            + " will_execute=\(willExecute ? "yes" : "no")"
            + " reason=\(reason)")
    }
}

// MARK: - Part 1: AX Permission Probe

/// Phase 32 — Probes Accessibility permission state at startup and before window actions.
/// Logs once at startup; subsequent checks are cached for 30s.
enum AXPermissionProbe {

    private static var lastCheck: (trusted: Bool, at: Date)?

    /// Check and log AX permission state. Call at startup and before window actions.
    @discardableResult
    static func check(reason: String = "startup") -> Bool {
        if let cached = lastCheck, Date().timeIntervalSince(cached.at) < 30 {
            return cached.trusted
        }
        let trusted = AXIsProcessTrusted()
        let promptAvailable = true // macOS always allows prompting
        lastCheck = (trusted, Date())
        print("[AXPermission]"
            + " trusted=\(trusted ? "yes" : "no")"
            + " prompt_available=\(promptAvailable ? "yes" : "no")"
            + " reason=\(reason)")
        return trusted
    }

    /// Request AX permission prompt if not trusted.
    static func requestIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        print("[AXPermission] prompt_shown=yes")
    }
}

// MARK: - Part 2: WindowManager with Detailed Logging

/// Phase 32 — Wraps real AX window operations with structured logging.
/// All window management in CapabilityExecutor already uses AX APIs;
/// this provides the [WindowManager] log layer the spec requires.
@MainActor
enum WindowManager {

    struct WindowInfo {
        let app: String
        let bundleId: String
        let title: String
        let frame: CGRect
        let element: AXUIElement
    }

    // MARK: - Enumerate

    /// List all windows for a running app.
    static func enumerateWindows(appName: String) -> [WindowInfo] {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
        }) else {
            print("[WindowManager] action=enumerate app=\(appName) windows=0 reason=app_not_running")
            return []
        }

        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else {
            print("[WindowManager] action=enumerate app=\(appName) windows=0 reason=ax_query_failed")
            return []
        }

        var results: [WindowInfo] = []
        for element in elements {
            let title = copyString(element, attribute: kAXTitleAttribute as CFString) ?? ""
            let frame = getFrame(element)
            results.append(WindowInfo(
                app: appName,
                bundleId: running.bundleIdentifier ?? "",
                title: title,
                frame: frame,
                element: element
            ))
        }

        let titles = results.map { "\($0.title.prefix(30))" }.joined(separator: "|")
        print("[WindowManager] action=enumerate app=\(appName) windows=\(results.count) titles=[\(titles)]")
        return results
    }

    // MARK: - Find

    /// Find a window matching app name and optional title substring.
    static func findWindow(appName: String, titleContains: String? = nil) -> WindowInfo? {
        let windows = enumerateWindows(appName: appName)
        let match: WindowInfo?
        if let needle = titleContains?.lowercased() {
            match = windows.first { $0.title.lowercased().contains(needle) }
        } else {
            match = windows.first
        }

        if let found = match {
            print("[WindowManager] action=find app=\(appName) title_contains=\(titleContains ?? "any") found=yes title=\"\(found.title.prefix(40))\"")
        } else {
            print("[WindowManager] action=find app=\(appName) title_contains=\(titleContains ?? "any") found=no")
        }
        return match
    }

    // MARK: - Set Frame

    /// Move and resize a window, then verify.
    static func setFrame(_ window: WindowInfo, frame: CGRect) -> Bool {
        var position = CGPoint(x: frame.minX, y: frame.minY)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let posValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            print("[WindowManager] action=set_frame app=\(window.app) status=failed reason=value_creation_failed")
            return false
        }

        let posSet = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, posValue) == .success
        let sizeSet = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue) == .success

        guard posSet && sizeSet else {
            print("[WindowManager] action=set_frame app=\(window.app)"
                + " x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
                + " status=failed reason=\(!posSet ? "position_set_failed" : "size_set_failed")")
            return false
        }

        let verified = verifyFrame(window, expectedFrame: frame)
        let actual = getFrame(window.element)
        print("[WindowManager] action=set_frame app=\(window.app)"
            + " x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
            + " status=\(verified ? "success" : "failed")")
        print("[WindowManager] action=verify_frame app=\(window.app)"
            + " expected=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
            + " actual=\(Int(actual.minX)),\(Int(actual.minY)),\(Int(actual.width)),\(Int(actual.height))"
            + " ok=\(verified ? "yes" : "no")")
        return verified
    }

    // MARK: - Raise / Focus

    /// Bring a window to front.
    static func raiseWindow(_ window: WindowInfo) -> Bool {
        let result = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        let ok = result == .success
        print("[WindowManager] action=raise app=\(window.app) title=\"\(window.title.prefix(30))\" ok=\(ok ? "yes" : "no")")
        return ok
    }

    // MARK: - Arrange Side by Side (high-level)

    struct ArrangeResult {
        let targetA: String
        let targetB: String
        let status: String  // "success", "partial", "failed"
        let reason: String
    }

    /// Arrange two apps/windows side by side using real AX APIs.
    static func arrangeSideBySide(appA: String, appB: String, titleHintA: String? = nil, titleHintB: String? = nil) -> ArrangeResult {
        guard AXPermissionProbe.check(reason: "arrange_side_by_side") else {
            return ArrangeResult(targetA: appA, targetB: appB, status: "failed", reason: "accessibility_permission_required")
        }

        guard let screen = NSScreen.main?.visibleFrame else {
            return ArrangeResult(targetA: appA, targetB: appB, status: "failed", reason: "no_screen")
        }

        let leftFrame = CGRect(x: screen.minX, y: screen.minY, width: floor(screen.width / 2.0), height: screen.height)
        let rightFrame = CGRect(x: screen.minX + floor(screen.width / 2.0), y: screen.minY, width: ceil(screen.width / 2.0), height: screen.height)

        let windowA = findWindow(appName: appA, titleContains: titleHintA)
        let windowB = appA == appB
            ? enumerateWindows(appName: appB).dropFirst().first.map { WindowInfo(app: $0.app, bundleId: $0.bundleId, title: $0.title, frame: $0.frame, element: $0.element) }
            : findWindow(appName: appB, titleContains: titleHintB)

        let aFound = windowA != nil
        let bFound = windowB != nil
        print("[WindowArrange] targetA_found=\(aFound ? "yes" : "no") targetB_found=\(bFound ? "yes" : "no")")
        print("[WindowArrange] layout=left_right")

        guard let wA = windowA else {
            return ArrangeResult(targetA: appA, targetB: appB, status: "failed", reason: "window_a_not_found")
        }
        guard let wB = windowB else {
            // Partial: arrange A to left half, B missing
            let _ = setFrame(wA, frame: leftFrame)
            let _ = raiseWindow(wA)
            return ArrangeResult(targetA: appA, targetB: appB, status: "partial", reason: "window_b_not_found")
        }

        let leftOK = setFrame(wA, frame: leftFrame)
        let rightOK = setFrame(wB, frame: rightFrame)
        let _ = raiseWindow(wA)
        let _ = raiseWindow(wB)

        let status = (leftOK && rightOK) ? "success" : ((leftOK || rightOK) ? "partial" : "failed")
        let reason = (leftOK && rightOK) ? "windows_arranged" :
                     (!leftOK && !rightOK) ? "both_set_frame_failed" :
                     (!leftOK ? "left_set_frame_failed" : "right_set_frame_failed")

        print("[ActionVerification] capability=arrange_side_by_side status=\(status)")
        return ArrangeResult(targetA: wA.title, targetB: wB.title, status: status, reason: reason)
    }

    // MARK: - Helpers

    private static func copyString(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func getFrame(_ element: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else {
            return .zero
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(posVal as! AXValue) == .cgPoint,
              AXValueGetType(sizeVal as! AXValue) == .cgSize,
              AXValueGetValue(posVal as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else {
            return .zero
        }
        return CGRect(origin: point, size: size)
    }

    private static func verifyFrame(_ window: WindowInfo, expectedFrame: CGRect) -> Bool {
        let actual = getFrame(window.element)
        return abs(actual.minX - expectedFrame.minX) < 12
            && abs(actual.minY - expectedFrame.minY) < 12
            && abs(actual.width - expectedFrame.width) < 24
            && abs(actual.height - expectedFrame.height) < 24
    }
}

// MARK: - Part 4: Browser Split Strategies

/// Phase 32 — Documents per-browser split strategies explicitly.
enum BrowserSplitStrategy {

    struct SplitResult {
        let browser: String
        let strategy: String
        let openedNewWindow: Bool
        let reason: String
    }

    /// Determine strategy for a browser.
    static func strategy(for browser: String) -> String {
        let lower = browser.lowercased()
        if lower.contains("firefox") { return "open_url_new_window" }
        if lower.contains("chrome") || lower.contains("brave") || lower.contains("edge") || lower.contains("arc") { return "chromium_new_window" }
        if lower.contains("safari") { return "safari_new_document" }
        return "generic_open"
    }

    /// Open a URL in a new browser window using the appropriate strategy.
    static func openInNewWindow(url: String, browser: String) -> SplitResult {
        guard let parsed = URL(string: url) else {
            print("[TabSplit] browser=\(browser) strategy=none url_valid=no")
            return SplitResult(browser: browser, strategy: "none", openedNewWindow: false, reason: "invalid_url")
        }
        let strat = strategy(for: browser)
        print("[TabSplit] browser=\(browser) strategy=\(strat) url=\(String(url.prefix(60)))")

        let success: Bool
        switch strat {
        case "open_url_new_window":
            // Firefox: open -na Firefox --args -new-window <url>
            success = runShell("/usr/bin/open", args: ["-na", browser, "--args", "-new-window", parsed.absoluteString])
        case "chromium_new_window":
            // Chrome/Brave/Edge: open -a <browser> --args --new-window <url>
            success = runShell("/usr/bin/open", args: ["-a", browser, "--args", "--new-window", parsed.absoluteString])
        case "safari_new_document":
            let script = "tell application \"Safari\" to make new document with properties {URL:\"\(parsed.absoluteString)\"}"
            success = runShell("/usr/bin/osascript", args: ["-e", script])
        default:
            success = NSWorkspace.shared.open(parsed)
        }

        print("[TabSplit] opened_new_window=\(success ? "yes" : "no")")
        return SplitResult(
            browser: browser,
            strategy: strat,
            openedNewWindow: success,
            reason: success ? "opened" : "open_failed"
        )
    }

    private static func runShell(_ path: String, args: [String]) -> Bool {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - Part 6: Focus Shortcut Detection

/// Phase 32 — Explicit Focus shortcut detection and logging.
enum FocusShortcutDetector {

    struct DetectionResult {
        let available: Bool
        let shortcutName: String?
        let allShortcuts: [String]
    }

    /// Detect whether a Focus-related shortcut exists.
    static func detect() -> DetectionResult {
        let task = Process()
        task.launchPath = "/usr/bin/shortcuts"
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                print("[FocusShortcut] available=no reason=shortcuts_command_failed")
                return DetectionResult(available: false, shortcutName: nil, allShortcuts: [])
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let shortcuts = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let focusNames = ["Contextual Focus", "Contextual Focus On", "Work Focus", "Focus On", "Do Not Disturb"]
            let match = focusNames.first { name in
                shortcuts.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }

            if let found = match {
                print("[FocusShortcut] available=yes shortcut=\(found)")
            } else {
                print("[FocusShortcut] available=no reason=no_matching_shortcut searched=\(focusNames.joined(separator: ","))")
            }
            return DetectionResult(available: match != nil, shortcutName: match, allShortcuts: shortcuts)
        } catch {
            print("[FocusShortcut] available=no reason=process_error")
            return DetectionResult(available: false, shortcutName: nil, allShortcuts: [])
        }
    }

    /// Run a named shortcut and report result.
    static func run(shortcutName: String) -> Bool {
        print("[FocusAction] started shortcut=\(shortcutName)")
        let task = Process()
        task.launchPath = "/usr/bin/shortcuts"
        task.arguments = ["run", shortcutName]
        let errPipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            let exitCode = task.terminationStatus
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let ok = exitCode == 0
            print("[FocusAction] exit_code=\(exitCode) status=\(ok ? "success" : "failed")")
            if !ok && !stderr.isEmpty {
                print("[FocusAction] stderr=\(stderr.prefix(100))")
            }
            return ok
        } catch {
            print("[FocusAction] exit_code=-1 status=failed reason=\(error.localizedDescription.prefix(80))")
            return false
        }
    }
}
