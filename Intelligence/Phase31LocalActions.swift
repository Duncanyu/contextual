import Foundation
import AppKit

// MARK: - Phase 31 Part 5: New Local Actions

/// Lightweight local actions beyond music.
/// Each action has a concrete target, execution handler, verification log, and honest unavailable state.
@MainActor
enum Phase31LocalActions {

    // MARK: - A. Open Paired App

    /// Opens/focuses a specific app that the user's task uses.
    /// "Open Preview for this lease?" / "Open Firefox for housing research?"
    static func openPairedApp(appName: String, reason: String) -> CapabilityExecutionStatus {
        print("[LocalActionExecution] started capability=open_paired_app targets=\(appName)")
        guard !appName.isEmpty else {
            print("[LocalActionExecution] completed capability=open_paired_app status=unavailable reason=no_target_app")
            return .unavailable
        }
        if NSWorkspace.shared.launchApplication(appName) {
            print("[LocalActionExecution] completed capability=open_paired_app status=success reason=\(reason) target=\(appName)")
            return .success
        }
        print("[LocalActionExecution] completed capability=open_paired_app status=unavailable reason=app_not_found target=\(appName)")
        return .unavailable
    }

    // MARK: - B. Switch to Last Task Window

    /// Focuses a running app matching the given name/title.
    /// "Switch back to the lease PDF?" / "Switch back to Google Docs?"
    static func switchToLastTaskWindow(appName: String, windowTitleSubstring: String?) -> CapabilityExecutionStatus {
        print("[LocalActionExecution] started capability=switch_to_last_task_window targets=\(appName)")
        let running = NSWorkspace.shared.runningApplications
        guard let target = running.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
                || $0.bundleIdentifier?.lowercased().contains(appName.lowercased()) == true
        }) else {
            print("[LocalActionExecution] completed capability=switch_to_last_task_window status=unavailable reason=app_not_running target=\(appName)")
            return .unavailable
        }
        target.activate()
        print("[LocalActionExecution] completed capability=switch_to_last_task_window status=success target=\(target.localizedName ?? appName) pid=\(target.processIdentifier)")
        return .success
    }

    // MARK: - C. Copy Current URL

    /// Copies the selected browser URL to clipboard.
    /// "Copy this page link?" / "Copy housing page link?"
    static func copyCurrentURL(url: String?, title: String?) -> CapabilityExecutionStatus {
        print("[PanelActionDescription] capability=copy_current_url label=\"Copy current page URL\" description=\"Copies the active browser page URL to clipboard.\"")
        print("[LocalActionExecution] started capability=copy_current_url")
        guard let url = url, !url.isEmpty else {
            print("[LocalActionExecution] completed capability=copy_current_url status=unavailable reason=no_url_available")
            return .unavailable
        }
        let text: String
        if let t = title, !t.isEmpty {
            text = "[\(t)](\(url))"
        } else {
            text = url
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("[LocalActionExecution] completed capability=copy_current_url status=success chars=\(text.count)")
        return .success
    }

    // MARK: - D. Copy All Related Links

    /// Copies all known related URLs from browser tabs / compartment.
    /// "Copy links for the housing pages?" / "Copy all research links?"
    static func copyAllRelatedLinks(urls: [String], titles: [String]) -> CapabilityExecutionStatus {
        print("[PanelActionDescription] capability=copy_all_related_links label=\"Copy relevant open links\" description=\"Copies a small list of relevant open browser links.\"")
        print("[LocalActionExecution] started capability=copy_all_related_links count=\(urls.count)")
        guard !urls.isEmpty else {
            // Fallback: copy titles if we have them
            if !titles.isEmpty {
                let titleLines = titles.enumerated().map { "- \($1)" }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("# Related Pages\n\n\(titleLines)", forType: .string)
                print("[LocalActionExecution] completed capability=copy_all_related_links status=success mode=titles_only count=\(titles.count)")
                return .success
            }
            print("[LocalActionExecution] completed capability=copy_all_related_links status=unavailable reason=no_urls_or_titles")
            return .unavailable
        }
        var lines: [String] = ["# Related Research Links", ""]
        for (i, url) in urls.enumerated() {
            let title = i < titles.count ? titles[i] : "Link \(i + 1)"
            lines.append("- [\(title)](\(url))")
        }
        let markdown = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        print("[LocalActionExecution] completed capability=copy_all_related_links status=success chars=\(markdown.count) links=\(urls.count)")
        return .success
    }

    // MARK: - E. Open Focus Shortcut Setup

    /// Opens Shortcuts app or System Settings Focus page.
    /// Does NOT pretend Focus was enabled.
    static func openFocusShortcutSetup() -> CapabilityExecutionStatus {
        print("[LocalActionExecution] started capability=open_focus_shortcut_setup")
        // Try to open System Settings > Focus
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Focus")
        if let url = settingsURL {
            NSWorkspace.shared.open(url)
            print("[LocalActionExecution] completed capability=open_focus_shortcut_setup status=success target=system_settings_focus")
            return .success
        }
        // Fallback: open Shortcuts app
        if NSWorkspace.shared.launchApplication("Shortcuts") {
            print("[LocalActionExecution] completed capability=open_focus_shortcut_setup status=success target=shortcuts_app")
            return .success
        }
        print("[LocalActionExecution] completed capability=open_focus_shortcut_setup status=unavailable reason=cannot_open_settings_or_shortcuts")
        return .unavailable
    }
}

// MARK: - Capability Registration for New Actions

extension CognitiveCapabilityRegistry {

    /// Phase 31 capabilities. Called from the main registry init
    /// is impractical since it's already sealed, so callers check
    /// the ID directly in CapabilityExecutor's switch.
    static let phase31Capabilities: [String: CognitiveCapability] = [
        "open_paired_app": CognitiveCapability(
            id: "open_paired_app",
            label: "Open paired app",
            inputRequirements: [],
            outputType: "system_action",
            evidenceThreshold: "none",
            riskLevel: .light_action,
            requiresConfirmation: true,
            executionMode: .local_action
        ),
        "switch_to_last_task_window": CognitiveCapability(
            id: "switch_to_last_task_window",
            label: "Switch to task window",
            inputRequirements: [],
            outputType: "system_action",
            evidenceThreshold: "none",
            riskLevel: .light_action,
            requiresConfirmation: true,
            executionMode: .local_action
        ),
        // Part I: clearer user-facing labels and descriptions
        "copy_current_url": CognitiveCapability(
            id: "copy_current_url",
            label: "Copy current page URL",
            inputRequirements: [],
            outputType: "system_action",
            evidenceThreshold: "none",
            riskLevel: .light_action,
            requiresConfirmation: false,
            executionMode: .local_action
        ),
        "copy_all_related_links": CognitiveCapability(
            id: "copy_all_related_links",
            label: "Copy relevant open links",
            inputRequirements: [],
            outputType: "system_action",
            evidenceThreshold: "none",
            riskLevel: .light_action,
            requiresConfirmation: false,
            executionMode: .local_action
        ),
        "open_focus_shortcut_setup": CognitiveCapability(
            id: "open_focus_shortcut_setup",
            label: "Set up Focus shortcut",
            inputRequirements: [],
            outputType: "system_action",
            evidenceThreshold: "none",
            riskLevel: .light_action,
            requiresConfirmation: true,
            executionMode: .local_action
        )
    ]
}
