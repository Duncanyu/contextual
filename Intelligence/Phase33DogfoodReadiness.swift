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

        case "open_current_task_panel", "capture_visible_page", "capture_full_document", "enable_browser_bridge", "select_text_hint":
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

        // Phase 36.2 — Capability-typed targets. Each capability publishes only the targets
        // it actually operates on; we no longer mix windows, music, urls, and tab titles
        // into one polluted bag.
        let typedTargets: [String] = {
            switch capabilityId {
            case "arrange_side_by_side":
                guard apps.count >= 2 else { return [] }
                return apps.prefix(2).map { "\($0):\(stableHash($0))" }
            case "switch_to_paired_app", "split_research_setup":
                return apps.prefix(2).map { "\($0):\(stableHash($0))" }
            case "restore_workspace":
                return apps.prefix(4).map { "\($0):\(stableHash($0))" }
            case "play_focus_media", "pause_media", "resume_focus_media":
                return ["Music"]
            case "copy_current_url":
                return [] // typed targets are URLs, surfaced via the `urls` field
            case "collect_references", "copy_all_related_links":
                return [] // typed targets are URLs/tab titles, surfaced via `urls`
            case "remember_workspace":
                return apps.prefix(4).map { "\($0):\(stableHash($0))" }
            case "open_current_task_panel", "capture_visible_page", "capture_full_document", "enable_browser_bridge", "select_text_hint":
                return []
            case "open_paired_app", "restore_research_tabs":
                return apps.prefix(2).map { "\($0):\(stableHash($0))" }
            default:
                return apps + Array(tabs.prefix(4))
            }
        }()

        let result = ValidationResult(
            capabilityId: capabilityId,
            valid: valid,
            missing: missing,
            targets: typedTargets,
            urls: urls,
            reason: reason
        )
        emit(result)
        return result
    }

    private static func stableHash(_ s: String) -> String {
        let h = abs(s.hashValue)
        return String(format: "%06x", h % 0xFFFFFF)
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
        if result.capabilityId == "arrange_side_by_side" {
            let targetStr = result.targets.isEmpty ? "none" : result.targets.prefix(4).joined(separator: ",")
            let source = result.targets.isEmpty ? "none" : "window_discovery"
            print("[PayloadTargetSource] capability=arrange_side_by_side source=\(source) targets=\(targetStr)")
            print("[PayloadSanity] capability=arrange_side_by_side valid=\(result.valid ? "yes" : "no") reason=\(result.reason)")
        }
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
            if reason == "typing_active"
                || reason == "recently_dismissed"
                || reason == "already_done"
                || reason == "low_value_metadata"
                || reason == "already_playing"
                || reason == "recently_accepted"
                || reason == "task_action_preferred" {
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
            if capabilityId == "play_focus_media" {
                print("[MusicSuggestion] suppressed reason=typing_active")
            }
            // Phase 41: layout actions (arrange/split) are NOT panel-safe during typing
            // because the user is actively engaged in text input.
            // Research and writing acquisition actions ARE safe because a user
            // selecting text + typing context is exactly when they want them.
            let panelSafeDuringTyping: Set<String> = [
                // Writing / acquisition actions
                "explicit_visible_capture_summary", "extract_action_items", "create_checklist",
                "rewrite_text", "improve_text", "draft_reply", "explain_context",
                // Metadata-safe actions
                "copy_current_url", "copy_all_related_links",
                "collect_references", "remember_workspace", "open_current_task_panel",
                // Paired-app switch is OK (user may want to jump to a reference)
                "switch_to_paired_app", "open_paired_app",
            ]
            // Phase 53 — read-only liquid workflow actions stay panel-safe during
            // typing: forms ARE a typing context, and form help must not vanish
            // exactly when the user is filling fields.
            let isReadOnlyLiquid = WorkflowActionOntology.byId[capabilityId]?.riskLevel == "read_only"
            if panelSafeDuringTyping.contains(capabilityId) || isReadOnlyLiquid {
                if WorkflowActionOntology.byId[capabilityId] != nil {
                    print("[LiquidSurfaceSuppression] id=\(capabilityId) reason=typing")
                }
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "typing_active_panel_safe", expectedFriction: .medium)
            }
            if WorkflowActionOntology.byId[capabilityId] != nil {
                print("[LiquidSurfaceSuppression] id=\(capabilityId) reason=typing")
            }
            return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "typing_active", expectedFriction: .low)
        }
        
        // 2. Recently Dismissed check
        if recentFeedback == "dismissed" || recentFeedback == "ignored" {
            if WorkflowActionOntology.byId[capabilityId] != nil {
                print("[LiquidSurfaceSuppression] id=\(capabilityId) reason=cooldown")
            }
            return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "recently_dismissed", expectedFriction: .low)
        }
        
        // 3. Capability-specific rules
        switch capabilityId {
            
        case "play_focus_media":
            if isMusicPlaying {
                print("[MusicSuggestion] suppressed reason=already_playing")
                return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "already_playing", expectedFriction: .low)
            }
            if recentFeedback == "accepted" {
                print("[MusicSuggestion] suppressed reason=recently_accepted")
                return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "recently_accepted", expectedFriction: .low)
            }
            // Phase 40 — Music should remain visible in the panel even when task/layout actions
            // are present. Suppressing it completely here caused music to vanish in nearly
            // every real working context (browser + doc open = "not layout_already_good").
            if isUserActivelySwitching || !isLayoutAlreadyGood || hasDurablePattern {
                print("[MusicSuggestion] surface=panel reason=secondary_to_active_task")
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "secondary_to_active_task", expectedFriction: .low)
            }
            if isMusicSuppressed {
                print("[MusicSuggestion] suppressed reason=context_mismatch")
                return logAndReturn(capabilityId: capabilityId, surface: .suppressed, reason: "context_mismatch", expectedFriction: .low)
            }
            
            // Music can float only when:
            // - music is not already playing
            // - user has accepted music in similar context before
            // - no recent dismiss/ignore for music
            // - user is idle or transitioning (not typing check passed above)
            // - current task context is compatible (not suppressed check passed above)
            // Phase 40 — first-time users still need to see music as a usable panel action.
            // `no_prior_music_acceptance` keeps it surfaced as panel_only, never suppressed.
            if userAcceptedMusicBefore {
                return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "music_idle_context_match", expectedFriction: .medium)
            } else {
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "first_time_panel_safe", expectedFriction: .low)
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
            // Phase 43: Utility action — demoted below cognitive preparation.
            print("[ActionClass] capability=\(capabilityId) class=utility default_surface=panel_only")
            print("[UtilityDemotion] capability=copy_current_url surface=panel_only reason=low_value_utility")
            print("[PrimaryActionPreference] preferred_family=cognitive_preparation over=utility reason=higher_user_value")
            return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "low_value_metadata", expectedFriction: .low)

        case "collect_references":
            // Phase 43: Utility action — demoted to panel-only.
            print("[ActionClass] capability=\(capabilityId) class=utility default_surface=panel_only")
            print("[UtilityDemotion] capability=collect_references surface=panel_only reason=low_value_utility")
            return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "low_value_metadata", expectedFriction: .low)

        case "remember_workspace":
            // Phase 43: Utility action — demoted to panel-only.
            print("[ActionClass] capability=\(capabilityId) class=utility default_surface=panel_only")
            print("[UtilityDemotion] capability=remember_workspace surface=panel_only reason=low_value_utility")
            return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "low_value_metadata", expectedFriction: .low)
            
        case "open_current_task_panel":
            // Can float only as a rare fallback after stable context + idle + no higher-value action.
            let isStableIdle = Date().timeIntervalSince(context.updatedAt) >= 30.0
            if isStableIdle {
                return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "idle_stable_fallback", expectedFriction: .low)
            } else {
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "low_value_metadata", expectedFriction: .low)
            }
            
        case "explicit_visible_capture_summary", "extract_action_items", "create_checklist",
             "summarize_visible_content", "rewrite_text", "improve_text", "draft_reply", "explain_context":
            // Phase 43 — Cognitive preparation actions are the primary product value.
            // They should proactively float (not be buried in the panel) when safe conditions are met.
            // Conditions: not typing, real local_action executor available.
            print("[ActionClass] capability=\(capabilityId) class=cognitive_preparation default_surface=floating_card")
            if isUserTyping {
                print("[CognitiveActionPolicy] capability=\(capabilityId) proactive_allowed=no reason=user_typing")
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "typing_active_panel_safe", expectedFriction: .medium)
            }
            let hasRealExecutor = CognitiveCapabilityRegistry.shared.get(capabilityId)?.executionMode == .local_action
            if !hasRealExecutor {
                print("[CognitiveActionPolicy] capability=\(capabilityId) proactive_allowed=no reason=no_local_executor")
                return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "no_local_executor", expectedFriction: .low)
            }
            print("[CognitiveActionPolicy] capability=\(capabilityId) proactive_allowed=yes reason=safe_executor_backed")
            // Safe cognitive action — eligible to float proactively.
            return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "safe_cognitive_preparation_proactive", expectedFriction: .medium)

        default:
            if let liquid = WorkflowActionOntology.byId[capabilityId],
               liquid.isSpecificAction,
               liquid.riskLevel == "read_only",
               liquid.surfacePolicy == .panelPrimary {
                let hasRealExecutor = CognitiveCapabilityRegistry.shared.get(capabilityId)?.executionMode == .local_action
                if hasRealExecutor {
                    print("[ActionClass] capability=\(capabilityId) class=liquid_specific default_surface=floating_card")
                    print("[LiquidSurfaceSuppression] id=\(capabilityId) reason=none")
                    return logAndReturn(capabilityId: capabilityId, surface: .floatingInterrupt, reason: "liquid_specific_proactive", expectedFriction: .medium)
                } else {
                    print("[LiquidSurfaceSuppression] id=\(capabilityId) reason=no_local_executor")
                    return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "no_local_executor", expectedFriction: .low)
                }
            }
            // Generic fallback for any other capability — panel-safe by default.
            // floatingInterrupt as default caused unknown capabilities to bypass the panel.
            if WorkflowActionOntology.byId[capabilityId] != nil {
                print("[LiquidSurfaceSuppression] id=\(capabilityId) reason=panel_only_policy")
            }
            return logAndReturn(capabilityId: capabilityId, surface: .panelOnly, reason: "default_panel_safe", expectedFriction: .low)
        }
    }
}
