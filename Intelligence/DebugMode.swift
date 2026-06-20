import Foundation
import AppKit

/// Manages the unified Debug Mode for the application.
enum DebugMode {
    private static let userDefaultsKey = "contextual_debug_mode_enabled"
    
    /// Whether debug mode is currently enabled.
    static var isEnabled: Bool {
        get {
            let enabled = UserDefaults.standard.bool(forKey: userDefaultsKey)
            // It will default to false if not set.
            return enabled
        }
        set {
            UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
            print("[DebugMode] enabled=\(newValue ? "yes" : "no") source=ui")
            print("[DebugToggleSideEffectCheck] product_rebuild=no allowed=no")
            logFilterState()
        }
    }
    
    /// Initializes and logs the current debug mode state from UserDefaults.
    static func initialize() {
        let stored = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool
        if stored == nil {
            UserDefaults.standard.set(false, forKey: userDefaultsKey)
            print("[DebugModeDefault] enabled=no source=default")
        } else if stored == true {
            UserDefaults.standard.set(false, forKey: userDefaultsKey)
            print("[DebugModeDefault] enabled=no source=reset_userdefaults")
        } else {
            print("[DebugModeDefault] enabled=no source=userdefaults")
        }
        let enabled = isEnabled
        print("[DebugMode] enabled=\(enabled ? "yes" : "no") source=userdefaults")
        logFilterState()
    }
    
    private static func logFilterState() {
        let mode = isEnabled ? "debug" : "normal"
        let suppressed = isEnabled ? "none" : "action_ontology,primitive_registry,window_discovery,selftests,suppressions,capabilities"
        print("[DebugLogFilter] mode=\(mode) suppressed_categories=\(suppressed)")
    }
    
    /// Helper to log when a UI component's visibility is determined by debug mode.
    static func logUIVisibility(component: String, visible: Bool) {
        print("[DebugUIVisibility] component=\(component) visible=\(visible ? "yes" : "no") reason=\(isEnabled ? "debug_mode_on" : "debug_mode_off")")
    }
    
    /// Helper to determine if a noisy log should be suppressed in dogfood mode.
    static var shouldSuppressNoisyLogs: Bool {
        return !isEnabled
    }
}

/// Hard product reset: what the assistant is allowed to put on the normal,
/// user-facing surface. Manual utilities (capture/refresh/copy-url/collect-refs/
/// remember-workspace/internal acquisition) are control-center capabilities, not
/// proactive assistance. Contextual workspace friction and media/focus actions
/// are not manual utilities by trait alone; they still have to pass usefulness,
/// live-path, cooldown, and router gates before they can surface.
enum ProductSurfacePolicy {
    struct ManualUtilityDecision {
        let capabilityID: String
        let traits: Set<CapabilityPolicyTrait>
        let manualUtility: Bool
        let contextualAction: Bool
        let reason: String

        var traitsLabel: String {
            let values = traits.map(\.rawValue).sorted()
            return values.isEmpty ? "none" : values.joined(separator: ",")
        }
    }

    /// Manual control utilities are visible as product actions only in debug mode.
    /// In the normal/dogfood product surface they are suppressed entirely — the
    /// panel is honestly quiet rather than a toolbox.
    static var manualControlsVisible: Bool { DebugMode.isEnabled }

    /// UI-only manual commands that are not registry capabilities.
    private static let manualUtilityCommandIDs: Set<String> = ["refresh_context"]

    static func classify(capabilityID: String) -> ManualUtilityDecision {
        if manualUtilityCommandIDs.contains(capabilityID) {
            return ManualUtilityDecision(
                capabilityID: capabilityID,
                traits: [],
                manualUtility: true,
                contextualAction: false,
                reason: "manual_command"
            )
        }
        let traits = CapabilityPolicyResolver.resolve(capabilityID: capabilityID)
        let contextualTraits = traits.contains(.workspaceArrangement)
            || traits.contains(.mediaOrFocusSupport)
            || traits.contains(.frictionReduction)
        let reason: String
        let manual: Bool
        if traits.contains(.internalAcquisitionAction) {
            manual = true
            reason = "internal_acquisition"
        } else if traits.contains(.metadataUtility) {
            manual = true
            reason = "metadata_utility"
        } else if traits.contains(.unverifiedBrowserMutator) {
            manual = true
            reason = "unverified_browser_mutator"
        } else if traits.contains(.dangerousOrManualUtility) {
            manual = true
            reason = "dangerous_or_manual"
        } else if contextualTraits {
            manual = false
            reason = "contextual_action"
        } else {
            manual = false
            reason = "product_action"
        }
        return ManualUtilityDecision(
            capabilityID: capabilityID,
            traits: traits,
            manualUtility: manual,
            contextualAction: contextualTraits && !manual,
            reason: reason
        )
    }

    /// Whether a capability is a manual environment utility that must not surface
    /// as a product action in normal mode.
    static func isManualUtility(_ capabilityID: String) -> Bool {
        classify(capabilityID: capabilityID).manualUtility
    }

    @discardableResult
    static func logClassification(capabilityID: String) -> ManualUtilityDecision {
        let decision = classify(capabilityID: capabilityID)
        print("[ContextualActionClassification] capability=\(capabilityID) traits=\(decision.traitsLabel) manual_utility=\(decision.manualUtility ? "yes" : "no") reason=\(decision.reason)")
        return decision
    }

    static func logSuppressionAudit(
        candidate: String,
        suppressed: Bool,
        reason: String,
        classification: ManualUtilityDecision? = nil
    ) {
        let decision = classification ?? classify(capabilityID: candidate)
        print("[ManualUtilitySuppressionAudit] candidate=\(candidate) suppressed=\(suppressed ? "yes" : "no") reason=\(reason) contextual=\(decision.contextualAction ? "yes" : "no")")
        if suppressed && decision.contextualAction {
            PassiveDogfoodMonitor.shared.noteContextualActionMisclassifiedManual()
            print("[NoContextualActionMisclassifiedAsManualUtility] status=fail count=1")
        } else {
            print("[NoContextualActionMisclassifiedAsManualUtility] status=pass count=0")
        }
    }

    static func logManualUtilityOnlyInvariant(suppressed: Bool, contextualUseful: Bool) {
        let fail = suppressed && contextualUseful
        if fail {
            PassiveDogfoodMonitor.shared.noteManualUtilityOnlySuppression()
        }
        print("[NoOnlyCandidateWasManualUtilityWhenContextualActionUseful] status=\(fail ? "fail" : "pass") count=\(fail ? 1 : 0)")
    }
}

/// Part 2 — explicit permission/access health. The assistant must never claim to
/// be working while it cannot read the current focus's content. This probes the
/// real TCC state (Accessibility, Screen Recording) plus the per-focus content
/// availability, logs it greppably, and lets the decision path emit a precise
/// "blocked by missing permission" reason instead of silently classifying unknown.
enum PermissionHealth {
    enum ScreenState: String { case granted, missing, notRequired = "not_required" }
    enum BrowserAXState: String { case working, missing, blocked, unknown }
    enum AvailState: String { case available, missing, disabled, unknown }

    struct Status {
        let axTrusted: Bool
        let screenRecording: ScreenState
        let browserAX: BrowserAXState
        let selectedURL: AvailState
        let axText: AvailState
        let ocr: AvailState

        /// Whether the app can read ANY current-focus content at all.
        var contentReadable: Bool {
            axTrusted && (browserAX == .working || selectedURL == .available || axText == .available)
        }
        /// The process-level gate: without Accessibility the app cannot read the
        /// active app/window/content, so it must not pretend to assist.
        var canReadActiveContext: Bool { axTrusted }
    }

    private static var didPromptAccessibility = false

    /// Probe and log. `signals` (when provided) fills the per-focus content fields;
    /// without it only process-level access (AX/screen recording) is reported.
    @discardableResult
    static func checkAndLog(reason: String, signals: WorkflowSignals? = nil) -> Status {
        let axTrusted = AXIsProcessTrusted()
        let screen: ScreenState = {
            if #available(macOS 10.15, *) {
                return CGPreflightScreenCaptureAccess() ? .granted : .missing
            }
            return .notRequired
        }()

        // Per-focus content availability (only knowable with live signals).
        let appIsBrowser: Bool = {
            guard let s = signals else { return false }
            return AppContextAnalyzer.analyze(appName: s.activeApp, bundleID: nil, windowTitle: s.windowTitle).isBrowser
        }()
        let urlPresent = (signals.map { !$0.urlHost.isEmpty || !$0.urlPath.isEmpty }) ?? false
        let axTextPresent = (signals.map { ($0.enrichedContext?.chars ?? 0) > 0 || $0.enrichedTextLength > 0 || $0.selectedTextLength >= 40 }) ?? false

        let selectedURL: AvailState = signals == nil ? .unknown : (urlPresent ? .available : .missing)
        let axText: AvailState = signals == nil ? .unknown : (axTextPresent ? .available : .missing)
        let browserAX: BrowserAXState = {
            guard signals != nil else { return .unknown }
            if !appIsBrowser { return .unknown }
            if !axTrusted { return .blocked }
            if urlPresent || axTextPresent { return .working }
            return .missing            // browser frontmost but only title metadata came back
        }()
        let ocr: AvailState = screen == .granted ? .available : (screen == .missing ? .missing : .unknown)

        let status = Status(axTrusted: axTrusted, screenRecording: screen, browserAX: browserAX,
                            selectedURL: selectedURL, axText: axText, ocr: ocr)
        print("[PermissionHealth] ax=\(axTrusted ? "granted" : "missing") screen_recording=\(screen.rawValue) browser_ax=\(browserAX.rawValue) selected_url=\(selectedURL.rawValue) ax_text=\(axText.rawValue) ocr=\(ocr.rawValue) reason=\(reason)")

        // If Accessibility is missing, request it once (visible system prompt) so
        // the user is never left with a silently-dead assistant.
        if !axTrusted && reason == "startup" && !didPromptAccessibility {
            didPromptAccessibility = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            print("[PermissionRequest] type=accessibility shown=yes reason=ax_missing_at_startup")
        }
        return status
    }

    /// Decision-path gate: returns a blocker string when a CONTENT suggestion must
    /// be suppressed because content permission is missing. Only blocks when the
    /// app genuinely cannot read content (Accessibility untrusted AND no readable
    /// content arrived by any path) — if content is present, permission is not the
    /// problem and we proceed. Emits the visible blocked-suggestion markers.
    static func contentSuggestionBlocker(hasReadableContent: Bool) -> String? {
        if !AXIsProcessTrusted() && !hasReadableContent {
            print("[PermissionBlockedSuggestion] reason=missing_ax")
            print("[NoContentSuggestionWithoutContentPermission] status=pass count=0")
            return "content_permission_missing"
        }
        print("[NoContentSuggestionWithoutContentPermission] status=pass count=0")
        return nil
    }
}
