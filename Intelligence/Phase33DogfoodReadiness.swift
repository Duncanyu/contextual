import Foundation
import AppKit

// MARK: - Part 1: Local Action Payload Validator

/// Phase 33 — Validates that a local action has the required payload before surfacing.
/// If invalid, the action must not be shown to the user.
enum LocalActionPayloadValidator {

    struct ValidationResult: Sendable {
        let capabilityId: String
        let valid: Bool
        let missing: [String]
        let targets: [String]
        let urls: [String]
        let reason: String
    }

    static func validate(
        capabilityId: String,
        involvedApps: [String],
        involvedURLs: [String],
        browserTabTitles: [String],
        compartmentLabel: String?,
        musicIntent: MusicIntent? = nil,
        focusShortcutAvailable: Bool? = nil
    ) -> ValidationResult {
        let apps = involvedApps.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var urls = involvedURLs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tabs = browserTabTitles.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var missing: [String] = []

        switch capabilityId {
        case "arrange_side_by_side":
            let targetCount = max(apps.count, tabs.count)
            if targetCount < 2 { missing.append("two_window_targets") }

        case "split_research_setup":
            if apps.isEmpty && tabs.isEmpty { missing.append("browser_name") }
            if urls.isEmpty { missing.append("target_url") }

        case "restore_workspace":
            if apps.isEmpty && urls.isEmpty { missing.append("apps_or_urls") }
            if (compartmentLabel ?? "").isEmpty { missing.append("compartment_label") }

        case "switch_to_paired_app", "open_paired_app":
            if apps.isEmpty { missing.append("target_app") }

        case "restore_research_tabs":
            if urls.isEmpty && tabs.isEmpty { missing.append("urls_or_tabs") }

        case "copy_current_url":
            if urls.isEmpty {
                let browsers = ["Safari", "Google Chrome", "Firefox", "Arc"]
                for browser in browsers {
                    if let context = BrowserContextExtractor.extract(appName: browser, activeAppPID: nil),
                       let u = context.selectedURL?.absoluteString ?? context.currentURL?.absoluteString {
                        if !u.isEmpty {
                            urls.append(u)
                            break
                        }
                    }
                }
            }
            if urls.isEmpty, let lastSelected = BrowserContextExtractor.lastSelectedURL, !lastSelected.isEmpty {
                urls.append(lastSelected)
            }
            if urls.isEmpty, let lastAcquired = ContextAcquisitionCoordinator.lastAcquiredBrowserURL, !lastAcquired.isEmpty {
                urls.append(lastAcquired)
            }
            if urls.isEmpty, let lastTick = TickReasoningLedger.lastTickBrowserURL, !lastTick.isEmpty {
                urls.append(lastTick)
            }
            if urls.isEmpty, let lastAssessed = BrowserContextStrategy.lastAssessedURL, !lastAssessed.isEmpty {
                urls.append(lastAssessed)
            }

            if urls.isEmpty { missing.append("current_url") }

        case "copy_all_related_links":
            if urls.isEmpty && tabs.isEmpty { missing.append("related_urls_or_tabs") }

        case "remember_workspace":
            if apps.count < 2 && urls.isEmpty && tabs.count < 2 { missing.append("workspace_context") }

        case "open_current_task_panel":
            break

        case "enable_reduce_interruptions":
            if focusShortcutAvailable == false { missing.append("focus_shortcut") }

        case "play_focus_media":
            // Music is generally always attemptable
            break

        default:
            break
        }

        let valid = missing.isEmpty
        let reason: String = {
            if valid && capabilityId == "copy_current_url" && !urls.isEmpty {
                return "current_url_available"
            }
            return valid ? "payload_complete" : "missing_\(missing.joined(separator: "+"))"
        }()

        let result = ValidationResult(
            capabilityId: capabilityId,
            valid: valid,
            missing: missing,
            targets: apps + tabs.prefix(4),
            urls: urls,
            reason: reason
        )
        emit(result)
        return result
    }

    private static func redactedOrDomainHash(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else {
            let hash = abs(urlString.hashValue)
            return String(format: "%08x", hash)
        }
        let hash = abs(urlString.hashValue)
        let hashStr = String(format: "%08x", hash).prefix(6)
        return "\(host)_\(hashStr)"
    }

    static func emit(_ result: ValidationResult) {
        let urlsStr: String = {
            if result.capabilityId == "copy_current_url" && result.valid {
                return result.urls.map { redactedOrDomainHash($0) }.joined(separator: ",")
            }
            return result.urls.isEmpty ? "none" : result.urls.prefix(3).map { String($0.prefix(40)) }.joined(separator: ",")
        }()
        print("[LocalActionPayload]"
            + " capability=\(result.capabilityId)"
            + " valid=\(result.valid ? "yes" : "no")"
            + " missing=\(result.missing.isEmpty ? "none" : result.missing.joined(separator: ","))"
            + " targets=\(result.targets.isEmpty ? "none" : result.targets.prefix(4).joined(separator: ","))"
            + " urls=\(urlsStr)"
            + " reason=\(result.reason)")
    }
}

// MARK: - Part 2: Payload Handoff Audit

/// Phase 33 — Verifies proposal payload survives from generation to click.
enum PayloadHandoffAudit {

    static func verify(
        proposalId: String,
        capabilityId: String,
        generatedTargets: [String],
        clickedTargets: [String],
        generatedURLs: [String],
        clickedURLs: [String]
    ) -> Bool {
        let targetsOK = generatedTargets.isEmpty
            || !clickedTargets.isEmpty
            || generatedTargets.allSatisfy { clickedTargets.contains($0) || true }
        let urlsOK = generatedURLs.isEmpty || !clickedURLs.isEmpty

        let genTargetStr = generatedTargets.isEmpty ? "none" : generatedTargets.prefix(3).joined(separator: ",")
        let clickTargetStr = clickedTargets.isEmpty ? "none" : clickedTargets.prefix(3).joined(separator: ",")
        let genURLStr = generatedURLs.isEmpty ? "none" : generatedURLs.prefix(2).map { String($0.prefix(40)) }.joined(separator: ",")
        let clickURLStr = clickedURLs.isEmpty ? "none" : clickedURLs.prefix(2).map { String($0.prefix(40)) }.joined(separator: ",")

        let missingParts: [String] = {
            var m: [String] = []
            if !generatedTargets.isEmpty && clickedTargets.isEmpty { m.append("targets_lost") }
            if !generatedURLs.isEmpty && clickedURLs.isEmpty { m.append("urls_lost") }
            return m
        }()
        let ok = missingParts.isEmpty

        print("[PayloadHandoff]"
            + " proposal_id=\(proposalId)"
            + " capability=\(capabilityId)"
            + " generated_targets=\(genTargetStr)"
            + " clicked_targets=\(clickTargetStr)"
            + " generated_urls=\(genURLStr)"
            + " clicked_urls=\(clickURLStr)"
            + " ok=\(ok ? "yes" : "no")"
            + " missing=\(missingParts.isEmpty ? "none" : missingParts.joined(separator: ","))")
        return ok
    }
}

// MARK: - Part 3: Family Selection with Local Action Priority

/// Phase 33 — When text has weak context and a local action is executable, local wins.
enum FamilySelectionPolicy {

    enum TextStrength: String {
        case weak       // title_only, grounded_facts=0, no selection/AX/OCR
        case medium     // browser_context or browser_tabs
        case strong     // selection, ax_content, ocr, or grounded_facts>0
    }

    struct SelectionDecision {
        let textWinner: String?
        let textStrength: TextStrength
        let localWinner: String?
        let localExecutable: Bool
        let selected: String?
        let reason: String
    }

    static func evaluateTextStrength(evidenceQuality: String, groundedFactsEstimate: Int) -> TextStrength {
        if groundedFactsEstimate > 0 { return .strong }
        switch evidenceQuality {
        case "selection", "ax_content", "ocr", "product_metadata", "public_web_research":
            return .strong
        case "browser_context", "browser_tabs":
            return .medium
        default:
            return .weak
        }
    }

    static func decide(
        textWinner: (capabilityId: String, score: Double)?,
        localWinner: (capabilityId: String, score: Double, payloadValid: Bool)?,
        evidenceQuality: String,
        groundedFactsEstimate: Int
    ) -> SelectionDecision {
        let strength = evaluateTextStrength(evidenceQuality: evidenceQuality, groundedFactsEstimate: groundedFactsEstimate)

        let selected: String?
        let reason: String

        if let local = localWinner, local.payloadValid {
            if strength == .weak {
                selected = local.capabilityId
                reason = "local_beats_weak_text"
            } else if let text = textWinner, text.score > local.score * 1.3 {
                selected = text.capabilityId
                reason = "strong_text_beats_local"
            } else {
                selected = local.capabilityId
                reason = "local_executable_preferred"
            }
        } else if let text = textWinner {
            selected = text.capabilityId
            reason = localWinner?.payloadValid == false ? "local_payload_invalid" : "no_local_candidate"
        } else {
            selected = nil
            reason = "no_candidates"
        }

        let decision = SelectionDecision(
            textWinner: textWinner?.capabilityId,
            textStrength: strength,
            localWinner: localWinner?.capabilityId,
            localExecutable: localWinner?.payloadValid ?? false,
            selected: selected,
            reason: reason
        )
        emit(decision)
        return decision
    }

    static func emit(_ d: SelectionDecision) {
        print("[FamilySelection]"
            + " text_winner=\(d.textWinner ?? "none")"
            + " text_strength=\(d.textStrength.rawValue)"
            + " local_winner=\(d.localWinner ?? "none")"
            + " local_executable=\(d.localExecutable ? "yes" : "no")"
            + " selected=\(d.selected ?? "none")"
            + " reason=\(d.reason)")
    }
}

// MARK: - Part 4: Debug Action Trigger

/// Phase 33 — Manual debug triggers for testing local actions.
/// Run with CONTEXTUAL_DEBUG_ACTION=<capability_id>
@MainActor
enum DebugActionTrigger {

    static func runIfTriggered() async {
        guard let action = ProcessInfo.processInfo.environment["CONTEXTUAL_DEBUG_ACTION"],
              !action.isEmpty else { return }
        print("[DebugActionTrigger] capability=\(action)")

        let browser = BrowserContextExtractor.extract(
            appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            activeAppPID: nil
        )
        let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let currentBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let tabTitles = browser?.recentTabTitles ?? []
        let selectedTitle = browser?.selectedTitle
        let selectedURL = browser?.selectedURL?.absoluteString ?? browser?.currentURL?.absoluteString
        let urls = [selectedURL].compactMap { $0 }
        let compartment = await TaskCompartmentTracker.shared.getActiveCompartment()

        print("[DebugActionTrigger] context_available=\(!currentApp.isEmpty ? "yes" : "no")"
            + " app=\(currentApp)"
            + " tabs=\(tabTitles.count)"
            + " url=\(selectedURL ?? "none")")

        let payload = LocalActionPayloadValidator.validate(
            capabilityId: action,
            involvedApps: [currentApp],
            involvedURLs: urls,
            browserTabTitles: tabTitles,
            compartmentLabel: compartment?.label,
            musicIntent: nil
        )
        guard payload.valid else {
            print("[DebugActionTrigger] result=unavailable reason=\(payload.reason)")
            return
        }

        let context: [String: Any] = [
            "apps": [currentApp],
            "tabTitles": tabTitles,
            "tabURLs": urls,
            "browserAppName": currentApp,
            "confirmation_satisfied": true,
            "currentEntity": selectedTitle ?? "",
            "windowTitleHint": selectedTitle ?? ""
        ]

        let registry = CognitiveCapabilityRegistry.shared
        let cap = registry.get(action)
            ?? CognitiveCapabilityRegistry.phase31Capabilities[action]
            ?? CognitiveCapability(
                id: action,
                label: action,
                inputRequirements: [],
                outputType: "system_action",
                evidenceThreshold: "none",
                riskLevel: .light_action,
                requiresConfirmation: false,
                executionMode: .local_action
            )

        let status = await CapabilityExecutor.shared.execute(capability: cap, context: context)
        print("[DebugActionTrigger] result=\(status.rawValue)")
    }
}

// MARK: - Part 6: Local Action Sanity Snapshot

/// Phase 33 — Compact per-tick summary of which local actions are valid.
enum LocalActionSanitySnapshot {

    static func emit(
        involvedApps: [String],
        involvedURLs: [String],
        browserTabTitles: [String],
        compartmentLabel: String?,
        musicPlaying: Bool,
        focusShortcutAvailable: Bool?
    ) {
        let actions: [(String, String)] = [
            ("arrange_side_by_side", sanity("arrange_side_by_side", apps: involvedApps, urls: involvedURLs, tabs: browserTabTitles, compartment: compartmentLabel, musicPlaying: musicPlaying, focusAvailable: focusShortcutAvailable)),
            ("split_research_setup", sanity("split_research_setup", apps: involvedApps, urls: involvedURLs, tabs: browserTabTitles, compartment: compartmentLabel, musicPlaying: musicPlaying, focusAvailable: focusShortcutAvailable)),
            ("restore_workspace", sanity("restore_workspace", apps: involvedApps, urls: involvedURLs, tabs: browserTabTitles, compartment: compartmentLabel, musicPlaying: musicPlaying, focusAvailable: focusShortcutAvailable)),
            ("switch_to_paired_app", sanity("switch_to_paired_app", apps: involvedApps, urls: involvedURLs, tabs: browserTabTitles, compartment: compartmentLabel, musicPlaying: musicPlaying, focusAvailable: focusShortcutAvailable)),
            ("copy_current_url", sanity("copy_current_url", apps: involvedApps, urls: involvedURLs, tabs: browserTabTitles, compartment: compartmentLabel, musicPlaying: musicPlaying, focusAvailable: focusShortcutAvailable)),
            ("remember_workspace", sanity("remember_workspace", apps: involvedApps, urls: involvedURLs, tabs: browserTabTitles, compartment: compartmentLabel, musicPlaying: musicPlaying, focusAvailable: focusShortcutAvailable)),
            ("open_current_task_panel", sanity("open_current_task_panel", apps: involvedApps, urls: involvedURLs, tabs: browserTabTitles, compartment: compartmentLabel, musicPlaying: musicPlaying, focusAvailable: focusShortcutAvailable)),
            ("focus", sanity("enable_reduce_interruptions", apps: involvedApps, urls: involvedURLs, tabs: browserTabTitles, compartment: compartmentLabel, musicPlaying: musicPlaying, focusAvailable: focusShortcutAvailable)),
            ("music", musicPlaying ? "invalid:already_playing" : "valid"),
        ]

        let items = actions.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        print("[LocalActionSanity] \(items)")
    }

    private static func sanity(
        _ capabilityId: String,
        apps: [String],
        urls: [String],
        tabs: [String],
        compartment: String?,
        musicPlaying: Bool,
        focusAvailable: Bool?
    ) -> String {
        let result = LocalActionPayloadValidator.validate(
            capabilityId: capabilityId,
            involvedApps: apps,
            involvedURLs: urls,
            browserTabTitles: tabs,
            compartmentLabel: compartment,
            musicIntent: nil,
            focusShortcutAvailable: focusAvailable
        )
        if result.valid { return "valid" }
        return "invalid:\(result.missing.first ?? "unknown")"
    }
}

// MARK: - Suggestion Surface Policy

enum SurfaceClassification: String, Sendable {
    case floatingInterrupt = "floating_interrupt"
    case panelOnly = "panel_only"
    case suppressed = "suppressed"
}

enum ExpectedFrictionReduction: String, Sendable {
    case low
    case medium
    case high
}

enum SuggestionSurfacePolicy: Sendable {
    
    static func computeUsefulnessScore(
        capabilityId: String,
        context: ContextModel,
        isMusicPlaying: Bool,
        isUserTyping: Bool,
        isLayoutAlreadyGood: Bool,
        recentFeedback: String?,
        isTargetAlreadyOpen: Bool,
        isUserActivelySwitching: Bool
    ) -> Double {
        var timeSaved = "low"
        var baseScore = 0.2
        
        switch capabilityId {
        case "restore_workspace", "restore_research_tabs":
            timeSaved = "high"
            baseScore = 0.8
        case "arrange_side_by_side", "split_research_setup":
            timeSaved = "medium"
            baseScore = 0.6
        case "play_focus_media":
            timeSaved = "medium"
            baseScore = 0.5
        case "collect_references":
            timeSaved = "medium"
            baseScore = 0.4
        default:
            timeSaved = "low"
            baseScore = 0.2
        }
        
        var frictionSignal = "none"
        var frictionModifier = 0.0
        
        if isUserActivelySwitching {
            frictionSignal = "strong"
            frictionModifier = 0.2
        } else if capabilityId == "arrange_side_by_side" && !isLayoutAlreadyGood {
            frictionSignal = "weak"
            frictionModifier = 0.1
        }
        
        var score = baseScore + frictionModifier
        
        // Penalties & satisfiability checks
        if isUserTyping {
            score -= 0.5
        }
        
        if (capabilityId == "play_focus_media" && isMusicPlaying) ||
           (capabilityId == "restore_workspace" && isTargetAlreadyOpen) ||
           (capabilityId == "restore_research_tabs" && isTargetAlreadyOpen) ||
           ((capabilityId == "arrange_side_by_side" || capabilityId == "split_research_setup") && isLayoutAlreadyGood) {
            score = 0.0
        }
        
        if recentFeedback == "dismissed" || recentFeedback == "ignored" {
            score -= 0.3
        }
        
        let finalScore = max(0.0, min(1.0, score))
        let feedbackStr = recentFeedback ?? "none"
        
        print("[UsefulnessScore] capability=\(capabilityId) time_saved=\(timeSaved) friction_signal=\(frictionSignal) recent_feedback=\(feedbackStr) final=\(String(format: "%.2f", finalScore))")
        
        return finalScore
    }
    
    private static func logAndReturn(
        capabilityId: String,
        surface: SurfaceClassification,
        reason: String,
        expectedFriction: ExpectedFrictionReduction
    ) -> (surface: SurfaceClassification, reason: String, expectedFriction: ExpectedFrictionReduction) {
        
        print("[SurfacePolicy] capability=\(capabilityId) surface=\(surface.rawValue) reason=\(reason) expected_friction_reduction=\(expectedFriction.rawValue)")
        
        if surface == .suppressed {
            var suppressedReason = "no_time_saved"
            if reason == "typing_active" || reason == "recently_dismissed" || reason == "already_done" || reason == "low_value_metadata" {
                suppressedReason = reason
            } else if reason == "no_prior_music_acceptance" {
                suppressedReason = "no_time_saved"
            }
            print("[SurfacePolicy] suppressed capability=\(capabilityId) reason=\(suppressedReason)")
        }
        
        if surface == .panelOnly && ["copy_current_url", "collect_references", "remember_workspace", "open_current_task_panel"].contains(capabilityId) {
            print("[PanelAction] added capability=\(capabilityId) reason=metadata_safe_low_interrupt")
            print("[AmbientFloatingSuggestion] suppressed capability=\(capabilityId) reason=panel_only_low_value_metadata")
        }
        
        return (surface, reason, expectedFriction)
    }

    static func evaluate(
        capabilityId: String,
        context: ContextModel,
        isMusicPlaying: Bool,
        isMusicSuppressed: Bool,
        isUserTyping: Bool,
        missing: DurableMemory.MissingWorkspaceCheck?,
        recentFeedback: String?, // "accepted", "dismissed", "ignored", nil
        frictionSignals: [FrictionSignal],
        hasDurablePattern: Bool,
        involvedURLs: [String],
        userAcceptedMusicBefore: Bool = false,
        isLayoutAlreadyGood: Bool = false
    ) -> (surface: SurfaceClassification, reason: String, expectedFriction: ExpectedFrictionReduction) {
        
        let isUserActivelySwitching = frictionSignals.contains { 
            $0.type == .repeated_app_switching || $0.type == .repeated_tab_switching 
        }
        let isTargetAlreadyOpen = missing != nil && !missing!.canRestore
        
        // 0. Compute Usefulness Score
        let _ = computeUsefulnessScore(
            capabilityId: capabilityId,
            context: context,
            isMusicPlaying: isMusicPlaying,
            isUserTyping: isUserTyping,
            isLayoutAlreadyGood: isLayoutAlreadyGood,
            recentFeedback: recentFeedback,
            isTargetAlreadyOpen: isTargetAlreadyOpen,
            isUserActivelySwitching: isUserActivelySwitching
        )
        
        // 1. Typing Active check — suppress floating, but keep panel for actionable/metadata-safe
        if isUserTyping {
            let panelSafeDuringTyping: Set<String> = [
                // Friction actions
                "arrange_side_by_side", "split_research_setup",
                "switch_to_paired_app", "open_paired_app",
                // Metadata-safe actions
                "copy_current_url", "copy_all_related_links",
                "collect_references", "remember_workspace", "open_current_task_panel"
            ]
            if panelSafeDuringTyping.contains(capabilityId) {
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "typing_active_panel_safe", expectedFriction: .medium)
            }
            return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "typing_active", expectedFriction: .low)
        }
        
        // 2. Recently Dismissed check
        if recentFeedback == "dismissed" || recentFeedback == "ignored" {
            return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "recently_dismissed", expectedFriction: .low)
        }
        
        // 3. Capability-specific rules
        switch capabilityId {
            
        case "play_focus_media":
            if isMusicPlaying {
                return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "already_done", expectedFriction: .low)
            }
            if isMusicSuppressed {
                return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "low_value_metadata", expectedFriction: .low)
            }
            
            // Music can float only when:
            // - music is not already playing
            // - user has accepted music in similar context before
            // - no recent dismiss/ignore for music
            // - user is idle or transitioning (not typing check passed above)
            // - current task context is compatible (not suppressed check passed above)
            if userAcceptedMusicBefore {
                return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "music_accepted_before", expectedFriction: .medium)
            } else {
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "no_prior_music_acceptance", expectedFriction: .low)
            }
            
        case "restore_workspace", "restore_research_tabs":
            // Restore can float only when an item is truly missing and executable.
            if let missing = missing, missing.canRestore {
                return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "missing_executable_workspace_items", expectedFriction: .high)
            } else {
                let reason = (missing?.reason == "workspace_items_present" || missing?.reason == "items_present_backgrounded") ? "already_done" : "no_time_saved"
                return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: reason, expectedFriction: .low)
            }
            
        case "arrange_side_by_side", "split_research_setup":
            // Arrange/split can float only when layout is actually suboptimal or repeated switching is proven.
            if isLayoutAlreadyGood {
                return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "already_done", expectedFriction: .low)
            }
            
            if isUserActivelySwitching {
                return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "layout_friction_proven", expectedFriction: .high)
            } else {
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "layout_not_proven", expectedFriction: .medium)
            }
            
        case "copy_current_url":
            // Can float only if user is clearly in a URL-sharing/citation/copying flow.
            let activeApp = (context.activeAppName ?? "").lowercased()
            let activeTitle = (context.activeWindowTitle ?? "").lowercased()
            let isSharingFlow = activeApp.contains("slack") || activeApp.contains("messages") || 
                                activeApp.contains("teams") || activeApp.contains("whatsapp") || 
                                activeApp.contains("mail") || activeTitle.contains("compose") || 
                                activeTitle.contains("draft") || activeTitle.contains("chat") || 
                                activeTitle.contains("message") || activeTitle.contains("share")
            
            if isSharingFlow {
                return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "sharing_flow_active", expectedFriction: .high)
            } else {
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "low_value_metadata", expectedFriction: .low)
            }
            
        case "collect_references":
            // Can float only if there are multiple relevant URLs and the user is clearly collecting sources/references.
            let isCollecting = involvedURLs.count >= 2 && (context.lastSourceTrigger == .activeAppChanged || context.lastSourceTrigger == .windowTitleChanged || context.selectedTextLength > 0)
            if isCollecting {
                return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "collecting_sources_active", expectedFriction: .high)
            } else {
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "low_value_metadata", expectedFriction: .low)
            }
            
        case "remember_workspace":
            // Can float only after repeated successful manual workspace use or explicit workspace setup behavior.
            if hasDurablePattern {
                return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "workspace_setup_detected", expectedFriction: .medium)
            } else {
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "low_value_metadata", expectedFriction: .low)
            }
            
        case "open_current_task_panel":
            // Can float only as a rare fallback after stable context + idle + no higher-value action.
            let isStableIdle = Date().timeIntervalSince(context.updatedAt) >= 30.0
            if isStableIdle {
                return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "idle_stable_fallback", expectedFriction: .low)
            } else {
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "low_value_metadata", expectedFriction: .low)
            }
            
        default:
            // Generic fallback for any other capability
            return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "default_allow", expectedFriction: .medium)
        }
    }
}
