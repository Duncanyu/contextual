import Foundation
import AppKit

/// Phase 41: Panel Publication Bridge + Side-by-Side Bypass Fix.
/// Verifies panel surface routing, arrange bypass gating, monitor suppression,
/// selected-text writing bridge, and icon symbol correctness.
@MainActor
struct Phase41SelfTest {

    private static var failures: [String] = []

    static func check(_ label: String, _ condition: Bool) {
        if condition {
            print("[Phase41SelfTest] pass case=\(label)")
        } else {
            print("[Phase41SelfTest] FAIL case=\(label)")
            failures.append(label)
        }
    }

    static func run() async -> Bool {
        print("[Phase41SelfTest] starting")
        failures = []

        let ctx = ContextModel()

        // T1: Research capabilities can float proactively when executor is backed (Phase 43).
        // Phase 41 originally expected panelOnly; Phase 43 changed cognitive to floatingInterrupt
        // when not typing and a local_action executor is registered.
        let researchCaps = ["explicit_visible_capture_summary", "extract_action_items", "create_checklist"]
        for cap in researchCaps {
            let r = SuggestionSurfacePolicy.evaluate(
                capabilityId: cap,
                context: ctx,
                isMusicPlaying: false,
                isMusicSuppressed: false,
                isUserTyping: false,
                missing: nil,
                recentFeedback: nil,
                frictionSignals: [],
                hasDurablePattern: false,
                involvedURLs: [],
                userAcceptedMusicBefore: false,
                isLayoutAlreadyGood: false
            )
            // Phase 43: cognitive capabilities now float when executor available.
            let surfacesOnPanel = r.surface == .panelOnly || r.surface == .floatingInterrupt
            check("t1_research_routes_to_panel_\(cap)", surfacesOnPanel)
        }

        // T2: Writing capabilities route to panel or float (Phase 43 allows float when executor backed).
        let writingCaps = ["rewrite_text", "improve_text", "draft_reply", "explain_context"]
        for cap in writingCaps {
            let r = SuggestionSurfacePolicy.evaluate(
                capabilityId: cap,
                context: ctx,
                isMusicPlaying: false,
                isMusicSuppressed: false,
                isUserTyping: false,
                missing: nil,
                recentFeedback: nil,
                frictionSignals: [],
                hasDurablePattern: false,
                involvedURLs: [],
                userAcceptedMusicBefore: false,
                isLayoutAlreadyGood: false
            )
            // Phase 43: cognitive capabilities now float when executor available.
            let surfacesOnPanel = r.surface == .panelOnly || r.surface == .floatingInterrupt
            check("t2_writing_routes_to_panel_\(cap)", surfacesOnPanel)
        }

        // T3: Default (unknown capability) goes to panelOnly, not floatingInterrupt.
        let unknownR = SuggestionSurfacePolicy.evaluate(
            capabilityId: "some_hypothetical_future_capability",
            context: ctx,
            isMusicPlaying: false,
            isMusicSuppressed: false,
            isUserTyping: false,
            missing: nil,
            recentFeedback: nil,
            frictionSignals: [],
            hasDurablePattern: false,
            involvedURLs: [],
            userAcceptedMusicBefore: false,
            isLayoutAlreadyGood: false
        )
        check("t3_default_goes_to_panel_not_floating", unknownR.surface == .panelOnly)

        // T4: arrange_side_by_side is suppressed when user is typing.
        let arrangeTypingR = SuggestionSurfacePolicy.evaluate(
            capabilityId: "arrange_side_by_side",
            context: ctx,
            isMusicPlaying: false,
            isMusicSuppressed: false,
            isUserTyping: true,
            missing: nil,
            recentFeedback: nil,
            frictionSignals: [],
            hasDurablePattern: false,
            involvedURLs: [],
            userAcceptedMusicBefore: false,
            isLayoutAlreadyGood: false
        )
        check("t4_arrange_not_safe_during_typing", arrangeTypingR.surface == .suppressed)

        // T5: Research IS safe during typing.
        let researchTypingR = SuggestionSurfacePolicy.evaluate(
            capabilityId: "explicit_visible_capture_summary",
            context: ctx,
            isMusicPlaying: false,
            isMusicSuppressed: false,
            isUserTyping: true,
            missing: nil,
            recentFeedback: nil,
            frictionSignals: [],
            hasDurablePattern: false,
            involvedURLs: [],
            userAcceptedMusicBefore: false,
            isLayoutAlreadyGood: false
        )
        check("t5_research_safe_during_typing", researchTypingR.surface == .panelOnly)

        // T6: DeterministicPanelActionPlanner gates arrange_side_by_side on active switching.
        // When activeSwitching=false, arrange_side_by_side must NOT appear in valid candidates.
        let frictionInput = DeterministicPanelPlannerInput(
            activeAppName: "Firefox",
            windowTitle: "Rental Postings",
            browserAppName: "Firefox",
            currentURL: "https://example.com/rentals",
            tabTitles: ["Rental Postings"],
            visibleApps: ["Firefox"],
            workflow: "researching",
            compartmentLabel: "researching",
            compartment: nil,
            evidenceLevel: .metadata_rich,
            browserAssessment: BrowserContextStrategy.assess(
                title: "Rental Postings",
                url: URL(string: "https://example.com/rentals"),
                tabTitles: [],
                hasAXText: false,
                hasOCR: false
            ),
            hasDurablePattern: false,
            frictionSignals: []   // no active switching friction
        )
        let plannerResult = DeterministicPanelActionPlanner.evaluate(frictionInput)
        let arrangeInPanel = plannerResult.validCandidates.contains { $0.candidate.capabilityId == "arrange_side_by_side" }
        check("t6_arrange_not_in_panel_without_friction", !arrangeInPanel)

        // T7: WorkPairMemory suppression — suppressForSystemRestore blocks switches from counting.
        WorkPairMemory.shared.reset()
        WorkPairMemory.shared.suppressForSystemRestore(seconds: 60)
        for i in 0..<4 {
            let pid: pid_t = i % 2 == 0 ? 900 : 901
            let app = i % 2 == 0 ? "Firefox" : "Preview"
            WorkPairMemory.shared.recordSwitch(app: app, title: "Test", pid: pid, source: "monitor_reconnect")
        }
        let suppressedPair = WorkPairMemory.shared.bestPair(withinSeconds: 120)
        check("t7_suppression_blocks_friction_pair", suppressedPair == nil)
        WorkPairMemory.shared.reset()

        // T8: WorkPairMemory — without suppression, 4 alternating switches produce a friction pair.
        WorkPairMemory.shared.reset()
        for i in 0..<4 {
            let pid: pid_t = i % 2 == 0 ? 200 : 201
            let app = i % 2 == 0 ? "Firefox" : "Preview"
            WorkPairMemory.shared.recordSwitch(app: app, title: "Work", pid: pid, source: "user_switch")
        }
        let unsuppressedPair = WorkPairMemory.shared.bestPair(withinSeconds: 120)
        check("t8_unsuppressed_switches_create_pair", unsuppressedPair != nil)
        WorkPairMemory.shared.reset()

        let ok = failures.isEmpty
        print("[Phase41SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
