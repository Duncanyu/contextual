import AppKit
import Foundation

// MARK: - Phase 36.2 — Runtime Workspace Friction Evaluator
//
// FrictionEngine watches active/browser transition signals. It does not detect layout
// friction from static runtime state (e.g. "Firefox and Preview are both open, both
// belong to the lease workspace, neither is arranged side by side"). That is the case
// where users want arrange_side_by_side most: the assistant can see the two related
// windows present, knows they belong together, and knows they aren't arranged.
//
// This evaluator generalises layout-friction detection over runtime inventory:
//   1. running apps (WorkspaceRuntimeInventory)
//   2. visible windows (WindowDiscovery)
//   3. durable workspace patterns (DurableMemory)
//   4. work-pair memory (WorkPairMemory)
//   5. compartment trust
//
// It is intentionally evidence-driven and contains no hardcoded app or title names.

struct RuntimeFrictionPair: Sendable {
    let primaryApp: String
    let secondaryApp: String
    let primaryWindow: WindowSnapshot?
    let secondaryWindow: WindowSnapshot?
    let workspaceID: String?           // durable workspace label/key, if any
    let evidenceType: ActionTargetEvidenceType
    let confidence: Double
}

struct RuntimeFrictionDecision: Sendable {
    let eligible: Bool
    let reason: String
    let pair: RuntimeFrictionPair?
    let layoutState: String            // already_arranged | overlapping | same_side | fullscreen | not_arranged | unknown
    let primaryTargetState: String     // present | missing | backgrounded | not_arranged
    let secondaryTargetState: String
    let expectedTimeSaved: String      // low | medium | high
}

enum RuntimeWorkspaceFrictionEvaluator {
	private static let debugContextApps: Set<String> = [
		"Xcode", "ChatGPT", "Claude", "Codex", "Terminal", "iTerm2"
	]

	private struct AppScore {
		let appName: String
		let visibleWindow: WindowSnapshot?
		let activeScreen: Bool
		let workspaceMatch: Bool
		let semanticMatch: Bool
		let presentNotArranged: Bool
		let debugContextPenalty: Bool
		let score: Double
	}

    static func evaluate(
        inventory: WorkspaceRuntimeInventory,
        workflow: String,
        compartmentLabel: String?,
        compartmentTrust: Double,
        currentEntity: String
    ) -> RuntimeFrictionDecision {

        // ── 1. Filter and collect eligible candidate windows ──
        let runningApps = inventory.runningApps
        let totalRunningApps = runningApps.count
        let totalWindowSnapshots = inventory.visibleWindows.count
        
        let runningAppNames = Set(inventory.runningApps.map(\.appName).filter { !$0.isEmpty })
        let visibleAppNames = Set(inventory.visibleWindows.map(\.appName).filter { !$0.isEmpty })
        let inventoryApps = runningAppNames.union(visibleAppNames)

        let durablePattern = DurableMemory.shared.bestDurableWorkspacePattern(
            workflow: workflow,
            compartment: compartmentLabel,
            currentApps: inventoryApps
        )
        let durableAppNames: [String] = durablePattern?.apps.map(\.appName).filter { !$0.isEmpty } ?? []
        let workspaceID: String? = durablePattern.map { "\($0.workflow)/\($0.compartment)" }

        let workPair = WorkPairMemory.shared.bestPair()
        let workPairApps = Set([workPair?.appA, workPair?.appB].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let semanticTokens = semanticTerms(currentEntity: currentEntity, compartmentLabel: compartmentLabel)

        let excludedApps: Set<String> = [
            "Control Center", "SystemUIServer", "Dock", "Spotlight", "universalaccessd", "Accessibility", "Notification Center", "Notification Centre", "Window Server", "Steam Helper"
        ]

        var eligibleWindows: [WindowSnapshot] = []
        var seenApps = Set<String>()

        for window in inventory.visibleWindows {
            let appName = window.appName
            
            // Check layer
            if window.layer != 0 {
                if LogControl.shared.shouldLog(category: .visibility_polling, level: .trace) {
                    print("[RuntimeFrictionCandidateFilter] app=\(appName) accepted=no reason=non_layer_0_layer_\(window.layer)")
                }
                continue
            }
            
            // Exclude helper/system apps
            let isExcluded = excludedApps.contains { appName.caseInsensitiveCompare($0) == .orderedSame }
                || appName.contains("Helper")
                || appName.contains("Daemon")
                || appName.contains("Assistant")
            if isExcluded {
                if LogControl.shared.shouldLog(category: .visibility_polling, level: .trace) {
                    print("[RuntimeFrictionCandidateFilter] app=\(appName) accepted=no reason=helper_or_system_app")
                }
                continue
            }
            
            // Meaningful non-empty title or known document/window role
            if window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if LogControl.shared.shouldLog(category: .visibility_polling, level: .trace) {
                    print("[RuntimeFrictionCandidateFilter] app=\(appName) accepted=no reason=empty_window_title")
                }
                continue
            }
            
            // Active screen or explicitly recently used or belongs to active task
            let isActiveScreen = window.isOnActiveScreen
            let isRecentWorkPair = workPairApps.contains(appName)
            let isWorkspaceMatch = durableAppNames.contains { $0.caseInsensitiveCompare(appName) == .orderedSame }
            let belongsToTask = isWorkspaceMatch || isRecentWorkPair
            
            if !isActiveScreen && !belongsToTask {
                if LogControl.shared.shouldLog(category: .visibility_polling, level: .trace) {
                    print("[RuntimeFrictionCandidateFilter] app=\(appName) accepted=no reason=not_active_screen_or_task_related")
                }
                continue
            }
            
            // Offscreen check
            if !window.isOnScreen {
                if LogControl.shared.shouldLog(category: .visibility_polling, level: .trace) {
                    print("[RuntimeFrictionCandidateFilter] app=\(appName) accepted=no reason=offscreen_window")
                }
                continue
            }
            
            if LogControl.shared.shouldLog(category: .visibility_polling, level: .trace) {
                print("[RuntimeFrictionCandidateFilter] app=\(appName) accepted=yes reason=eligible_window")
            }
            eligibleWindows.append(window)
            seenApps.insert(appName)
        }

        print("[RuntimeFrictionCandidateUniverse] total_running_apps=\(totalRunningApps) window_snapshots=\(totalWindowSnapshots) eligible_windows=\(eligibleWindows.count) eligible_apps=\(seenApps.count)")

        if eligibleWindows.count < 2 {
            print("[RuntimeFriction] no_candidate reason=insufficient_eligible_windows")
            return RuntimeFrictionDecision(
                eligible: false,
                reason: "no_related_pair",
                pair: nil,
                layoutState: "unknown",
                primaryTargetState: "missing",
                secondaryTargetState: "missing",
                expectedTimeSaved: "low"
            )
        }

        let eligibleAppsList = Array(seenApps).sorted()
        let appScores: [AppScore] = eligibleAppsList.map { appName in
            let windows = eligibleWindows.filter { $0.appName.caseInsensitiveCompare(appName) == .orderedSame }
            let visibleWindow = windows.first(where: \.isOnActiveScreen) ?? windows.first
            let activeScreen = windows.contains(where: \.isOnActiveScreen)
            let workspaceMatch = durableAppNames.contains { $0.caseInsensitiveCompare(appName) == .orderedSame }
            let semanticAligned = windows.contains { semanticMatch(window: $0, appName: appName, tokens: semanticTokens) }
                || semanticTokens.contains(where: { appName.lowercased().contains($0) })
            let presentNotArranged = visibleWindow != nil
            let debugPenalty = debugContextApps.contains(appName) && !workspaceMatch && !semanticAligned
            var score = 0.0
            if activeScreen { score += 4.0 }
            if workspaceMatch { score += 5.0 }
            if semanticAligned { score += 3.0 }
            if presentNotArranged { score += 3.0 }
            if workPairApps.contains(appName) { score += 1.5 }
            if debugPenalty { score -= 6.0 }
            if LogControl.shared.shouldLog(category: .runtime_pair_scoring, level: .trace) {
                print("[RuntimeFrictionCandidateScore] app=\(appName) active_screen=\(activeScreen ? "yes" : "no") workspace_match=\(workspaceMatch ? "yes" : "no") semantic_match=\(semanticAligned ? "yes" : "no") present_not_arranged=\(presentNotArranged ? "yes" : "no") debug_context_penalty=\(debugPenalty ? "yes" : "no") score=\(String(format: "%.2f", score))")
            }
            return AppScore(
                appName: appName,
                visibleWindow: visibleWindow,
                activeScreen: activeScreen,
                workspaceMatch: workspaceMatch,
                semanticMatch: semanticAligned,
                presentNotArranged: presentNotArranged,
                debugContextPenalty: debugPenalty,
                score: score
            )
        }

        let pairScores: [(primary: AppScore, secondary: AppScore, evidenceType: ActionTargetEvidenceType, confidence: Double, score: Double, reason: String)] = appScores.enumerated().flatMap { index, first in
            appScores.dropFirst(index + 1).map { second in
                let bothWorkspace = first.workspaceMatch && second.workspaceMatch
                let bothVisible = first.visibleWindow != nil && second.visibleWindow != nil
                let workPairMatch = workPairApps.contains(first.appName) && workPairApps.contains(second.appName)
                let semanticPair = (first.semanticMatch && second.semanticMatch) || (bothWorkspace && (first.semanticMatch || second.semanticMatch))
                let debugPenalty = first.debugContextPenalty || second.debugContextPenalty
                var score = first.score + second.score
                if bothVisible { score += 3.0 }
                if first.activeScreen && second.activeScreen { score += 2.5 }
                if bothWorkspace { score += 4.0 }
                if workPairMatch && !debugPenalty { score += 2.0 }
                if semanticPair { score += 2.0 }
                if debugPenalty { score -= 5.0 }
                let evidenceType: ActionTargetEvidenceType = bothWorkspace ? .workspace_pattern : (workPairMatch ? .work_pair : .active_window_pair)
                let confidence = min(0.95, 0.45 + (score / 30.0))
                let reason = bothWorkspace && semanticPair ? "workspace_semantic_pair" : (workPairMatch && !debugPenalty ? "work_pair_match" : "visible_runtime_pair")
                if LogControl.shared.shouldLog(category: .runtime_pair_scoring, level: .trace) {
                    print("[RuntimeFrictionPairScore] primary=\(first.appName) secondary=\(second.appName) score=\(String(format: "%.2f", score)) reason=\(reason)")
                }
                return (first, second, evidenceType, confidence, score, reason)
            }
        }.sorted { $0.score > $1.score }

        let candidatePair: (String, String, ActionTargetEvidenceType, Double, String)? = pairScores.first.map {
            ($0.primary.appName, $0.secondary.appName, $0.evidenceType, $0.confidence, $0.reason)
        }

        for rejected in pairScores.dropFirst() where rejected.primary.debugContextPenalty || rejected.secondary.debugContextPenalty {
            print("[RuntimeFriction] rejected_pair=\(rejected.primary.appName),\(rejected.secondary.appName) reason=background_or_debug_context_mismatch")
        }

        guard let (primaryApp, secondaryApp, evidenceType, baseConfidence, selectedReason) = candidatePair else {
            print("[RuntimeFriction] pair_exists=no layout_state=unknown active_user_friction=no eligible=no")
            print("[RuntimeFriction] capability=arrange_side_by_side eligible=no reason=no_related_pair apps=\(inventoryApps.sorted().prefix(6).joined(separator: ",")) windows=\(inventory.visibleWindows.count) workspace_id=\(workspaceID ?? "none")")
            return RuntimeFrictionDecision(
                eligible: false,
                reason: "no_related_pair",
                pair: nil,
                layoutState: "unknown",
                primaryTargetState: "missing",
                secondaryTargetState: "missing",
                expectedTimeSaved: "low"
            )
        }

        // ── 2. Locate the actual visible windows for the chosen pair ──
        let primaryWindow = inventory.visibleWindows.first { $0.appName.caseInsensitiveCompare(primaryApp) == .orderedSame }
        let secondaryWindow = inventory.visibleWindows.first { $0.appName.caseInsensitiveCompare(secondaryApp) == .orderedSame }

        let primaryState = targetState(for: primaryApp, window: primaryWindow, inventory: inventory)
        let secondaryState = targetState(for: secondaryApp, window: secondaryWindow, inventory: inventory)
        if LogControl.shared.shouldLog(category: .runtime_pair_scoring, level: .trace) {
            print("[RuntimeFriction] target_state primary=\(primaryState) secondary=\(secondaryState)")
        }

        // ── 3. Determine layout state from window geometry ──
        let layoutState = classifyLayout(primary: primaryWindow, secondary: secondaryWindow)
        if LogControl.shared.shouldLog(category: .runtime_pair_scoring, level: .trace) {
            print("[RuntimeFriction] layout_state=\(layoutState)")
        }

        // ── 4. Evaluate active user friction ──
        let hasAlternation = workPair != nil &&
            (primaryApp.lowercased() == workPair!.appA.lowercased() || primaryApp.lowercased() == workPair!.appB.lowercased()) &&
            (secondaryApp.lowercased() == workPair!.appA.lowercased() || secondaryApp.lowercased() == workPair!.appB.lowercased())
        let switches = hasAlternation ? workPair!.switches : 0
        let recentAlternation = switches >= 2
        
        let combinedText = "\(currentEntity) \(compartmentLabel ?? "") \(workflow)".lowercased()
        let hasComparisonIntent = combinedText.contains("compare") ||
                                  combinedText.contains("comparison") ||
                                  combinedText.contains("research") ||
                                  combinedText.contains("referencing") ||
                                  combinedText.contains("reference")
        
        let bothVisible = primaryWindow != nil && secondaryWindow != nil
        let workflowLower = workflow.lowercased()
        let isComparisonResearchWorkflow = workflowLower.contains("research") || workflowLower.contains("compare") || workflowLower.contains("comparison")
        
        // Phase 39: Strict friction requirement. Visibility alone is not enough.
        let isLayoutSuboptimal = layoutState == "overlapping" || layoutState == "same_side"
        
        let currentSessionResearchFriction = isComparisonResearchWorkflow && bothVisible && isLayoutSuboptimal
        
        let entityLower = currentEntity.lowercased()
        let entityReferencesBoth = !entityLower.isEmpty &&
            entityLower.contains(primaryApp.lowercased()) &&
            entityLower.contains(secondaryApp.lowercased())
            
        let activeUserFriction = recentAlternation || hasComparisonIntent || currentSessionResearchFriction || entityReferencesBoth

        // ── 5. Decide eligibility ──
        let anyMissing = (primaryState == "missing" || secondaryState == "missing")
        let alreadyArranged = (layoutState == "already_arranged")
        let bothPresent = !anyMissing
        let bothWindowsKnown = primaryWindow != nil && secondaryWindow != nil

        // Layout reliability: if we haven't proven we can arrange these specific apps/windows
        // without overlapping or same-side failure, we may quarantine auto-surface.
        let layoutReliabilityProven = true // Placeholder: in production this could track history

        let timeSaved: String = {
            switch evidenceType {
            case .workspace_pattern, .work_pair: return "high"
            case .active_window_pair: return "medium"
            default: return "medium"
            }
        }()
        
        let eligible = !anyMissing && !alreadyArranged && activeUserFriction && layoutReliabilityProven

        if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
            print("[ArrangeRequirement] target_validity=\(!anyMissing ? "pass" : "fail") active_friction=\(activeUserFriction ? "pass" : "fail") layout_reliability=\(layoutReliabilityProven ? "pass" : "fail") allowed=\(eligible ? "yes" : "no")")
        }

        if !eligible && LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
            let reason: String = {
                if anyMissing { return "target_missing" }
                if alreadyArranged { return "already_arranged" }
                if !activeUserFriction {
                    return isLayoutSuboptimal ? "overlap_without_user_friction" : "visibility_only_no_friction"
                }
                if !layoutReliabilityProven { return "layout_reliability_not_proven" }
                return "unknown"
            }()
            print("[ArrangeRequirement] blocked reason=\(reason)")
        } else if eligible && LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
            if recentAlternation {
                print("[ArrangeRequirement] passed reason=recent_exact_pair_alternation")
            } else if hasComparisonIntent {
                print("[ArrangeRequirement] passed reason=comparison_intent")
            } else if entityReferencesBoth {
                print("[ArrangeRequirement] passed reason=entity_references_both")
            } else if currentSessionResearchFriction {
                print("[ArrangeRequirement] passed reason=research_friction_suboptimal_layout")
            }
        }


        if anyMissing {
            let reason = "target_missing_at_runtime"
            print("[RuntimeFriction] capability=arrange_side_by_side eligible=no reason=\(reason) apps=\(primaryApp),\(secondaryApp) windows=\(inventory.visibleWindows.count) workspace_id=\(workspaceID ?? "none")")
            return RuntimeFrictionDecision(
                eligible: false,
                reason: reason,
                pair: RuntimeFrictionPair(primaryApp: primaryApp, secondaryApp: secondaryApp, primaryWindow: primaryWindow, secondaryWindow: secondaryWindow, workspaceID: workspaceID, evidenceType: evidenceType, confidence: baseConfidence),
                layoutState: layoutState,
                primaryTargetState: primaryState,
                secondaryTargetState: secondaryState,
                expectedTimeSaved: timeSaved
            )
        }

        if alreadyArranged {
            let reason = "already_arranged"
            print("[RuntimeFriction] capability=arrange_side_by_side eligible=no reason=\(reason) apps=\(primaryApp),\(secondaryApp) windows=\(inventory.visibleWindows.count) workspace_id=\(workspaceID ?? "none")")
            return RuntimeFrictionDecision(
                eligible: false,
                reason: reason,
                pair: RuntimeFrictionPair(primaryApp: primaryApp, secondaryApp: secondaryApp, primaryWindow: primaryWindow, secondaryWindow: secondaryWindow, workspaceID: workspaceID, evidenceType: evidenceType, confidence: baseConfidence),
                layoutState: layoutState,
                primaryTargetState: primaryState,
                secondaryTargetState: secondaryState,
                expectedTimeSaved: timeSaved
            )
        }

        if !activeUserFriction {
            let reason = "visibility_only_no_friction"
            print("[RuntimeFriction] not_eligible reason=\(reason)")
            print("[RuntimeFriction] capability=arrange_side_by_side eligible=no reason=\(reason) apps=\(primaryApp),\(secondaryApp) windows=\(inventory.visibleWindows.count) workspace_id=\(workspaceID ?? "none")")
            return RuntimeFrictionDecision(
                eligible: false,
                reason: reason,
                pair: RuntimeFrictionPair(primaryApp: primaryApp, secondaryApp: secondaryApp, primaryWindow: primaryWindow, secondaryWindow: secondaryWindow, workspaceID: workspaceID, evidenceType: evidenceType, confidence: baseConfidence),
                layoutState: layoutState,
                primaryTargetState: primaryState,
                secondaryTargetState: secondaryState,
                expectedTimeSaved: timeSaved
            )
        }

        guard bothPresent else {
            print("[RuntimeFriction] capability=arrange_side_by_side eligible=no reason=incomplete_pair workspace_id=\(workspaceID ?? "none")")
            return RuntimeFrictionDecision(
                eligible: false,
                reason: "incomplete_pair",
                pair: nil,
                layoutState: layoutState,
                primaryTargetState: primaryState,
                secondaryTargetState: secondaryState,
                expectedTimeSaved: timeSaved
            )
        }

        // Eligible — at least one target needs arrangement, both apps are present, layout
        // is not already side-by-side. Window-known vs. backgrounded-only is fine; arrange
        // can raise backgrounded windows before layout.
        var confidence = baseConfidence
        if bothWindowsKnown { confidence = min(0.95, confidence + 0.05) }
        if compartmentTrust >= 0.7 { confidence = min(0.95, confidence + 0.05) }
        let reason: String = {
            switch evidenceType {
            case .workspace_pattern: return "runtime_workspace_friction"
            case .work_pair: return "runtime_work_pair_friction"
            case .active_window_pair: return "runtime_visible_pair_friction"
            default: return "runtime_workspace_friction"
            }
        }()
        let pair = RuntimeFrictionPair(
            primaryApp: primaryApp,
            secondaryApp: secondaryApp,
            primaryWindow: primaryWindow,
            secondaryWindow: secondaryWindow,
            workspaceID: workspaceID,
            evidenceType: evidenceType,
            confidence: confidence
        )
		print("[RuntimeFriction] selected_pair=\(primaryApp),\(secondaryApp) reason=\(selectedReason)")
        print("[RuntimeFriction] capability=arrange_side_by_side eligible=yes reason=\(reason) apps=\(primaryApp),\(secondaryApp) windows=\(inventory.visibleWindows.count) workspace_id=\(workspaceID ?? "none")")
        return RuntimeFrictionDecision(
            eligible: true,
            reason: reason,
            pair: pair,
            layoutState: layoutState,
            primaryTargetState: primaryState,
            secondaryTargetState: secondaryState,
            expectedTimeSaved: timeSaved
        )
    }

    // MARK: - Helpers

    private static func targetState(
        for appName: String,
        window: WindowSnapshot?,
        inventory: WorkspaceRuntimeInventory
    ) -> String {
        if window != nil { return "present" }
        let running = inventory.runningApps.contains { $0.appName.caseInsensitiveCompare(appName) == .orderedSame }
        if running { return "backgrounded" }
        return "missing"
    }

    private static func classifyLayout(primary: WindowSnapshot?, secondary: WindowSnapshot?) -> String {
        guard let a = primary, let b = secondary else { return "unknown" }
        guard let screen = NSScreen.main else { return "unknown" }
        let screenFrame = screen.visibleFrame

        let frameA = a.frame
        let frameB = b.frame
        let fullA = isFullScreen(frameA, screen: screenFrame)
        let fullB = isFullScreen(frameB, screen: screenFrame)
        if fullA || fullB { return "fullscreen" }

        // Are they side by side (horizontal halves of the same screen)?
        let halfWidth = screenFrame.width / 2.0
        let centerA = frameA.midX
        let centerB = frameB.midX
        let onDifferentHalves =
            (centerA <= screenFrame.midX + 30 && centerB >= screenFrame.midX - 30) ||
            (centerB <= screenFrame.midX + 30 && centerA >= screenFrame.midX - 30)
        let widthsAreHalf = abs(frameA.width - halfWidth) < halfWidth * 0.30
            && abs(frameB.width - halfWidth) < halfWidth * 0.30
        if onDifferentHalves && widthsAreHalf { return "already_arranged" }

        // Overlap detection
        if frameA.intersects(frameB) {
            let overlap = frameA.intersection(frameB)
            let smaller = min(frameA.width * frameA.height, frameB.width * frameB.height)
            let frac = (overlap.width * overlap.height) / max(1, smaller)
            if frac > 0.30 { return "overlapping" }
        }

        // Same-side (both centered on the same half)
        let bothLeft = (centerA < screenFrame.midX) && (centerB < screenFrame.midX)
        let bothRight = (centerA >= screenFrame.midX) && (centerB >= screenFrame.midX)
        if bothLeft || bothRight { return "same_side" }

        return "not_arranged"
    }

    private static func isFullScreen(_ frame: CGRect, screen: CGRect) -> Bool {
        let widthMatch = abs(frame.width - screen.width) < 20
        let heightMatch = abs(frame.height - screen.height) < 50
        return widthMatch && heightMatch
    }

	private static func semanticTerms(currentEntity: String, compartmentLabel: String?) -> Set<String> {
		let combined = [currentEntity, compartmentLabel ?? ""].joined(separator: " ")
		return Set(
			combined
				.lowercased()
				.components(separatedBy: CharacterSet.alphanumerics.inverted)
				.filter { $0.count >= 4 }
		)
	}

	private static func semanticMatch(window: WindowSnapshot, appName: String, tokens: Set<String>) -> Bool {
		let haystack = "\(appName) \(window.title)".lowercased()
		return tokens.contains { haystack.contains($0) }
	}
}

// MARK: - Self-test

enum RuntimeWorkspaceFrictionSelfTest {

    static func run() -> Bool {
        print("[RuntimeWorkspaceFrictionSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[RuntimeWorkspaceFrictionSelfTest] pass case=\(name)") }
            else { print("[RuntimeWorkspaceFrictionSelfTest] fail case=\(name)"); failures.append(name) }
        }

        let saved = WorkspaceRuntimeInventoryProvider.testSnapshot
        defer { WorkspaceRuntimeInventoryProvider.testSnapshot = saved }

        // Build a runtime inventory with two visible windows from distinct apps
        let firefoxWindow = WindowSnapshot(
            windowID: 101,
            appName: "Firefox",
            bundleID: "org.mozilla.firefox",
            pid: 1001,
            title: "182 Montreal St - Lease - Google Docs",
            frame: CGRect(x: 0, y: 0, width: 800, height: 800),
            layer: 0,
            isOnScreen: true,
            isOnActiveScreen: true
        )
        let previewWindow = WindowSnapshot(
            windowID: 102,
            appName: "Preview",
            bundleID: "com.apple.Preview",
            pid: 1002,
            title: "_182_montreal_street_accommodation_agreement_final_version.pdf",
            frame: CGRect(x: 100, y: 100, width: 800, height: 800),
            layer: 0,
            isOnScreen: true,
            isOnActiveScreen: true
        )
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
            ],
            visibleWindows: [firefoxWindow, previewWindow],
            browserTabTitles: ["182 Montreal St - Lease - Google Docs"],
            currentURLs: ["https://docs.google.com/document/d/lease"],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )

        WorkPairMemory.shared.reset()
        // Record alternation between Firefox and Preview (overcounts WorkPair confidence)
        for _ in 0..<6 {
            WorkPairMemory.shared.recordSwitch(app: "Firefox", title: "182 Montreal St - Lease - Google Docs", pid: 1001)
            WorkPairMemory.shared.recordSwitch(app: "Preview", title: "_182_montreal_street_accommodation_agreement_final_version.pdf", pid: 1002)
        }

        let inv = WorkspaceRuntimeInventoryProvider.snapshot()
        let decision = RuntimeWorkspaceFrictionEvaluator.evaluate(
            inventory: inv,
            workflow: "researching",
            compartmentLabel: "lease",
            compartmentTrust: 0.85,
            currentEntity: "lease"
        )
        check("dogfood_pair_eligible", decision.eligible)
        check("dogfood_pair_apps", decision.pair?.primaryApp == "Firefox" || decision.pair?.secondaryApp == "Firefox")
        check("dogfood_pair_apps_preview", decision.pair?.primaryApp == "Preview" || decision.pair?.secondaryApp == "Preview")
        check("dogfood_layout_not_arranged", decision.layoutState != "already_arranged")

		WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
			runningApps: [
				WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
				WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview"),
				WorkspaceAppRecord(bundleID: "com.openai.chatgpt", appName: "ChatGPT"),
				WorkspaceAppRecord(bundleID: "com.apple.dt.Xcode", appName: "Xcode")
			],
			visibleWindows: [
				firefoxWindow,
				previewWindow,
				WindowSnapshot(windowID: 103, appName: "ChatGPT", bundleID: "com.openai.chatgpt", pid: 1003, title: "Contextual debug notes", frame: CGRect(x: 1800, y: 0, width: 600, height: 600), layer: 0, isOnScreen: true, isOnActiveScreen: false),
				WindowSnapshot(windowID: 104, appName: "Xcode", bundleID: "com.apple.dt.Xcode", pid: 1004, title: "Contextual.xcodeproj", frame: CGRect(x: 1820, y: 40, width: 700, height: 700), layer: 0, isOnScreen: true, isOnActiveScreen: false)
			],
			browserTabTitles: ["182 Montreal St - Lease - Google Docs"],
			currentURLs: ["https://docs.google.com/document/d/lease"],
			frontmostAppName: "Firefox",
			frontmostBundleID: "org.mozilla.firefox"
		)
		let debugDecision = RuntimeWorkspaceFrictionEvaluator.evaluate(
			inventory: WorkspaceRuntimeInventoryProvider.snapshot(),
			workflow: "researching",
			compartmentLabel: "lease",
			compartmentTrust: 0.85,
			currentEntity: "lease"
		)
		let debugPair = Set([debugDecision.pair?.primaryApp, debugDecision.pair?.secondaryApp].compactMap { $0 })
		check("debug_context_pair_prefers_workspace_windows", debugPair == Set(["Firefox", "Preview"]))

        // Now simulate already-arranged side-by-side
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let halfW = screen.width / 2.0
        let leftFrame = CGRect(x: screen.minX, y: screen.minY, width: halfW, height: screen.height)
        let rightFrame = CGRect(x: screen.minX + halfW, y: screen.minY, width: halfW, height: screen.height)
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: inv.runningApps,
            visibleWindows: [
                WindowSnapshot(windowID: 101, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 1001, title: "L", frame: leftFrame, layer: 0, isOnScreen: true, isOnActiveScreen: true),
                WindowSnapshot(windowID: 102, appName: "Preview", bundleID: "com.apple.Preview", pid: 1002, title: "R", frame: rightFrame, layer: 0, isOnScreen: true, isOnActiveScreen: true)
            ],
            browserTabTitles: [],
            currentURLs: [],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )
        let arrangedDecision = RuntimeWorkspaceFrictionEvaluator.evaluate(
            inventory: WorkspaceRuntimeInventoryProvider.snapshot(),
            workflow: "researching",
            compartmentLabel: "lease",
            compartmentTrust: 0.85,
            currentEntity: "lease"
        )
        check("already_arranged_not_eligible", !arrangedDecision.eligible)
        check("already_arranged_layout_state", arrangedDecision.layoutState == "already_arranged")

        // No related pair → not eligible
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [WorkspaceAppRecord(bundleID: "com.apple.finder", appName: "Finder")],
            visibleWindows: [],
            browserTabTitles: [],
            currentURLs: [],
            frontmostAppName: "Finder",
            frontmostBundleID: "com.apple.finder"
        )
        WorkPairMemory.shared.reset()
        let emptyDecision = RuntimeWorkspaceFrictionEvaluator.evaluate(
            inventory: WorkspaceRuntimeInventoryProvider.snapshot(),
            workflow: "idle",
            compartmentLabel: nil,
            compartmentTrust: 0.0,
            currentEntity: ""
        )
        check("no_pair_not_eligible", !emptyDecision.eligible)
        check("no_pair_reason", emptyDecision.reason == "no_related_pair")

        let ok = failures.isEmpty
        print("[RuntimeWorkspaceFrictionSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
