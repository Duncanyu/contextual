import Foundation
import AppKit

// MARK: - Phase 36.2 Useful Action Repair Regression Tests
//
// Five scenarios:
//   1. Runtime workspace friction (Firefox + Preview, same workspace, not arranged)
//      -> RuntimeFriction eligible=yes, arrange_side_by_side candidate generated,
//         target contract attached, LivePathEnforcement + VisibleActionPath logs emitted.
//   2. Music suppressed by task_action_preferred -> backfill chooses arrange_side_by_side.
//   3. Live path logs emitted from CheapAlwaysOnPortfolio.
//   4. Target payload typing: arrange_side_by_side targets contain only the window pair —
//      not music, not unrelated tabs.
//   5. No useful friction -> no arrange candidate; music/metadata behave correctly.

@MainActor
public enum Phase362SelfTest {

    public static func run() async -> Bool {
        print("[Phase362SelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[Phase362SelfTest] pass case=\(name)") }
            else { print("[Phase362SelfTest] fail case=\(name)"); failures.append(name) }
        }

        let savedSnapshot = WorkspaceRuntimeInventoryProvider.testSnapshot
        defer {
            WorkspaceRuntimeInventoryProvider.testSnapshot = savedSnapshot
            WorkPairMemory.shared.reset()
        }

        // ── Scenario 1 — Runtime workspace friction ──
        print("[Phase362SelfTest] case=1_runtime_workspace_friction")
        WorkPairMemory.shared.reset()
        for _ in 0..<6 {
            WorkPairMemory.shared.recordSwitch(app: "Firefox", title: "Lease Doc", pid: 1001)
            WorkPairMemory.shared.recordSwitch(app: "Preview", title: "Lease PDF", pid: 1002)
        }
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [
                WorkspaceAppRecord(bundleID: "org.mozilla.firefox", appName: "Firefox"),
                WorkspaceAppRecord(bundleID: "com.apple.Preview", appName: "Preview")
            ],
            visibleWindows: [
                WindowSnapshot(windowID: 1, appName: "Firefox", bundleID: "org.mozilla.firefox", pid: 1001, title: "Lease Doc", frame: CGRect(x: 0, y: 0, width: 800, height: 800), layer: 0, isOnScreen: true, isOnActiveScreen: true),
                WindowSnapshot(windowID: 2, appName: "Preview", bundleID: "com.apple.Preview", pid: 1002, title: "Lease PDF", frame: CGRect(x: 200, y: 200, width: 800, height: 800), layer: 0, isOnScreen: true, isOnActiveScreen: true)
            ],
            browserTabTitles: ["Lease Doc"],
            currentURLs: ["https://docs.google.com/document/d/lease"],
            frontmostAppName: "Firefox",
            frontmostBundleID: "org.mozilla.firefox"
        )
        let inventory = WorkspaceRuntimeInventoryProvider.snapshot()
        let runtimeDecision = RuntimeWorkspaceFrictionEvaluator.evaluate(
            inventory: inventory,
            workflow: "researching",
            compartmentLabel: "lease",
            compartmentTrust: 0.85,
            currentEntity: "lease"
        )
        check("1_runtime_friction_eligible", runtimeDecision.eligible)
        check("1_runtime_pair_present", runtimeDecision.pair != nil)
        check("1_runtime_layout_not_arranged", runtimeDecision.layoutState != "already_arranged")

        if let pair = runtimeDecision.pair {
            let contract = ActionTargetContract.forLayoutApps(
                capabilityID: "arrange_side_by_side",
                appNames: [pair.primaryApp, pair.secondaryApp],
                evidenceType: pair.evidenceType,
                confidence: pair.confidence,
                fallbackAllowed: false
            )
            check("1_contract_id_present", !contract.contractID.isEmpty)
            check("1_contract_two_targets", contract.targets.count == 2)
        }

        // ── Scenario 2 — Music suppressed, arrange backfills ──
        print("[Phase362SelfTest] case=2_music_suppressed_arrange_backfills")
        let stableCtxWithTask = LivePathEvaluationContext(
            sourcePath: "phase362_test",
            contextStability: "stable",
            isMusicAlreadyPlaying: false,
            hasHigherPriorityTaskAction: true,
            recentFeedbackCooldownActive: false,
            userFeedbackHistory: "neutral",
            alreadySatisfied: false,
            evidenceAvailable: true,
            hasExplicitUsageSignal: false,
            activityMatch: true
        )
        let (musicDecision, _) = LivePathEnforcer.evaluate(
            capabilityID: "play_focus_media",
            involvedApps: ["Music"],
            attachedContract: nil,
            confidence: 0.9,
            evaluationContext: stableCtxWithTask
        )
        check("2_music_not_eligible_when_task_action", !musicDecision.eligibleForFloating)
        check("2_music_reason_task_action_preferred", musicDecision.reason == "secondary_to_active_task")

        let (arrangeDecision, arrangeContract) = LivePathEnforcer.evaluate(
            capabilityID: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            attachedContract: nil,
            confidence: 0.75,
            evaluationContext: stableCtxWithTask
        )
        check("2_arrange_backfill_eligible", arrangeDecision.eligibleForFloating)
        check("2_arrange_backfill_contract", arrangeContract != nil)

        // ── Scenario 3 — Live path logs emitted from CheapAlwaysOnPortfolio ──
        // We rely on the wired logs in CheapAlwaysOnPortfolio.evaluateDetailed; this scenario
        // executes a tick and verifies the result struct returns a candidate.
        print("[Phase362SelfTest] case=3_live_path_logs_emitted")
        let memory = WorkingMemorySnapshot(
            currentEntity: "lease",
            recentEntities: ["lease"],
            repeatedConcepts: [],
            inferredActivity: "researching",
            comparisonCandidates: [],
            relatedFocusEntities: []
        )
        let portfolioInput = CheapAlwaysOnPortfolioInput(
            reason: "phase362_test",
            workflow: .researching,
            modelReady: true,
            startupQuiet: false,
            frictionSignals: [],
            mediaState: EnvironmentMediaState(isMusicPlaying: false, visualMediaKind: .none, source: "test"),
            semanticState: nil,
            entityGrounding: nil,
            compartment: nil,
            memory: memory,
            activityState: nil,
            entityKey: "lease",
            currentApp: "Firefox",
            appCategory: nil,
            groundingResult: nil
        )
        let result = CheapAlwaysOnPortfolio.evaluateDetailed(portfolioInput)
        check("3_portfolio_produced_candidates", !result.allCandidates.isEmpty)
        let frictionCandidate = result.allCandidates.first { $0.capabilityId == "arrange_side_by_side" }
        check("3_arrange_generated_from_runtime_friction", frictionCandidate != nil)
        check("3_arrange_involved_apps_typed", (frictionCandidate?.involvedApps.count ?? 0) == 2)

        // ── Scenario 4 — Target payload typing ──
        print("[Phase362SelfTest] case=4_payload_typed_targets")
        let arrangePayload = LocalActionPayloadValidator.validate(
            capabilityId: "arrange_side_by_side",
            involvedApps: ["Firefox", "Preview"],
            involvedURLs: ["https://youtube.com/watch", "https://mail.google.com"],
            browserTabTitles: ["YouTube — Trailer", "Gmail Inbox", "182 Montreal St Lease"],
            compartmentLabel: "lease"
        )
        let targetsHavePollution = arrangePayload.targets.contains { tgt in
            let lower = tgt.lowercased()
            return lower.contains("music") || lower.contains("youtube") || lower.contains("gmail")
        }
        check("4_arrange_targets_only_window_pair", !targetsHavePollution)
        check("4_arrange_targets_two", arrangePayload.targets.count == 2)

        let musicPayload = LocalActionPayloadValidator.validate(
            capabilityId: "play_focus_media",
            involvedApps: ["Music"],
            involvedURLs: ["https://docs.google.com/lease"],
            browserTabTitles: ["Lease Doc"],
            compartmentLabel: "lease",
            musicIntent: MusicIntent(taskDomain: "coding", mood: .focus, query: "focus music", playlistName: nil, action: .resume)
        )
        check("4_music_target_only_music", musicPayload.targets == ["Music"])

        let copyPayload = LocalActionPayloadValidator.validate(
            capabilityId: "copy_current_url",
            involvedApps: ["Firefox"],
            involvedURLs: ["https://docs.google.com/lease"],
            browserTabTitles: ["Lease Doc"],
            compartmentLabel: "lease"
        )
        check("4_copy_url_no_app_targets", copyPayload.targets.isEmpty)
        check("4_copy_url_url_present", !copyPayload.urls.isEmpty)

        // ── Scenario 5 — No useful friction ──
        print("[Phase362SelfTest] case=5_no_useful_friction")
        WorkPairMemory.shared.reset()
        WorkspaceRuntimeInventoryProvider.testSnapshot = WorkspaceRuntimeInventory(
            runningApps: [WorkspaceAppRecord(bundleID: "com.apple.finder", appName: "Finder")],
            visibleWindows: [],
            browserTabTitles: [],
            currentURLs: [],
            frontmostAppName: "Finder",
            frontmostBundleID: "com.apple.finder"
        )
        let emptyInv = WorkspaceRuntimeInventoryProvider.snapshot()
        let emptyDecision = RuntimeWorkspaceFrictionEvaluator.evaluate(
            inventory: emptyInv,
            workflow: "idle",
            compartmentLabel: nil,
            compartmentTrust: 0.0,
            currentEntity: ""
        )
        check("5_no_pair_no_eligible", !emptyDecision.eligible)
        check("5_no_pair_reason", emptyDecision.reason == "no_related_pair")

        // ── Bundle runtime workspace friction self-test ──
        let runtimeOk = RuntimeWorkspaceFrictionSelfTest.run()
        check("runtime_friction_self_test", runtimeOk)

        let ok = failures.isEmpty
        print("[Phase362SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
