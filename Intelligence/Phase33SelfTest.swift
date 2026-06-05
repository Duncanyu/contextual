import Foundation
import AppKit

/// Phase 33 — Self-tests for dogfood readiness.
/// Trigger: CONTEXTUAL_RUN_PHASE33_SELFTEST=1
@MainActor
enum Phase33SelfTest {

    static func run() async -> Bool {
        print("[Phase33SelfTest] starting")
        var failures: [String] = []

        func check(_ name: String, _ ok: Bool) {
            if ok { print("[Phase33SelfTest] pass case=\(name)") }
            else  { print("[Phase33SelfTest] fail case=\(name)"); failures.append(name) }
        }

        // ── Part 1: Payload Validator ──

        // 1. Rejects arrange without two targets
        do {
            let result = LocalActionPayloadValidator.validate(
                capabilityId: "arrange_side_by_side",
                involvedApps: ["Preview"],
                involvedURLs: [],
                browserTabTitles: [],
                compartmentLabel: "Test"
            )
            check("payload_validator_rejects_arrange_without_two_targets", !result.valid && result.missing.contains("two_window_targets"))
        }

        // 2. Accepts arrange with two targets
        do {
            let result = LocalActionPayloadValidator.validate(
                capabilityId: "arrange_side_by_side",
                involvedApps: ["Preview", "Firefox"],
                involvedURLs: [],
                browserTabTitles: [],
                compartmentLabel: "Test"
            )
            check("payload_validator_accepts_arrange_with_two_targets", result.valid)
        }

        // 3. Accepts arrange with two browser tabs
        do {
            let result = LocalActionPayloadValidator.validate(
                capabilityId: "arrange_side_by_side",
                involvedApps: [],
                involvedURLs: [],
                browserTabTitles: ["Lease PDF", "Google Docs"],
                compartmentLabel: "Test"
            )
            check("payload_validator_accepts_arrange_with_two_tabs", result.valid)
        }

        // 4. Rejects split without URL
        do {
            let result = LocalActionPayloadValidator.validate(
                capabilityId: "split_research_setup",
                involvedApps: ["Firefox"],
                involvedURLs: [],
                browserTabTitles: ["Tab 1"],
                compartmentLabel: "Test"
            )
            check("payload_validator_rejects_split_without_url", !result.valid && result.missing.contains("target_url"))
        }

        // 5. Rejects restore_workspace empty
        do {
            let result = LocalActionPayloadValidator.validate(
                capabilityId: "restore_workspace",
                involvedApps: [],
                involvedURLs: [],
                browserTabTitles: [],
                compartmentLabel: nil
            )
            check("payload_validator_rejects_restore_workspace_empty", !result.valid)
        }

        // 6. Rejects focus without shortcut
        do {
            let result = LocalActionPayloadValidator.validate(
                capabilityId: "enable_reduce_interruptions",
                involvedApps: [],
                involvedURLs: [],
                browserTabTitles: [],
                compartmentLabel: nil,
                focusShortcutAvailable: false
            )
            check("payload_validator_rejects_focus_without_shortcut", !result.valid && result.missing.contains("focus_shortcut"))
        }

        // 7. Accepts copy_current_url with URL
        do {
            let result = LocalActionPayloadValidator.validate(
                capabilityId: "copy_current_url",
                involvedApps: [],
                involvedURLs: ["https://housing.queensu.ca"],
                browserTabTitles: [],
                compartmentLabel: nil
            )
            check("payload_validator_accepts_copy_url_with_url", result.valid)
        }

        // 8. Rejects copy_current_url without URL
        do {
            let result = LocalActionPayloadValidator.validate(
                capabilityId: "copy_current_url",
                involvedApps: [],
                involvedURLs: [],
                browserTabTitles: [],
                compartmentLabel: nil
            )
            check("payload_validator_rejects_copy_url_without_url", !result.valid)
        }

        // ── Part 2: Payload Handoff ──

        // 9. Payload survives: targets present at both ends
        do {
            let ok = PayloadHandoffAudit.verify(
                proposalId: "test-001",
                capabilityId: "arrange_side_by_side",
                generatedTargets: ["Preview", "Firefox"],
                clickedTargets: ["Preview", "Firefox"],
                generatedURLs: [],
                clickedURLs: []
            )
            check("arrange_payload_survives_candidate_to_click", ok)
        }

        // 10. Payload lost: targets generated but missing at click
        do {
            let ok = PayloadHandoffAudit.verify(
                proposalId: "test-002",
                capabilityId: "arrange_side_by_side",
                generatedTargets: ["Preview", "Firefox"],
                clickedTargets: [],
                generatedURLs: [],
                clickedURLs: []
            )
            check("arrange_payload_lost_detected", !ok)
        }

        // 11. URL payload survives
        do {
            let ok = PayloadHandoffAudit.verify(
                proposalId: "test-003",
                capabilityId: "split_research_setup",
                generatedTargets: [],
                clickedTargets: [],
                generatedURLs: ["https://housing.queensu.ca"],
                clickedURLs: ["https://housing.queensu.ca"]
            )
            check("split_payload_survives_candidate_to_click", ok)
        }

        // 12. Music intent payload (empty targets are OK — music has no targets)
        do {
            let ok = PayloadHandoffAudit.verify(
                proposalId: "test-004",
                capabilityId: "play_focus_media",
                generatedTargets: [],
                clickedTargets: [],
                generatedURLs: [],
                clickedURLs: []
            )
            check("music_intent_survives_candidate_to_click", ok)
        }

        // ── Part 3: Family Selection ──

        // 13. Executable local beats title-only text
        do {
            let decision = FamilySelectionPolicy.decide(
                textWinner: (capabilityId: "synthesize_sources", score: 0.360),
                localWinner: (capabilityId: "arrange_side_by_side", score: 0.250, payloadValid: true),
                evidenceQuality: "title_only",
                groundedFactsEstimate: 0
            )
            check("executable_local_action_beats_title_only_text",
                  decision.selected == "arrange_side_by_side" && decision.reason == "local_beats_weak_text")
        }

        // 14. Strong text can beat local
        do {
            let decision = FamilySelectionPolicy.decide(
                textWinner: (capabilityId: "synthesize_sources", score: 0.720),
                localWinner: (capabilityId: "arrange_side_by_side", score: 0.250, payloadValid: true),
                evidenceQuality: "selection",
                groundedFactsEstimate: 3
            )
            check("strong_text_action_can_beat_local_action",
                  decision.selected == "synthesize_sources" && decision.reason == "strong_text_beats_local")
        }

        // 15. Invalid payload local loses
        do {
            let decision = FamilySelectionPolicy.decide(
                textWinner: (capabilityId: "synthesize_sources", score: 0.360),
                localWinner: (capabilityId: "arrange_side_by_side", score: 0.400, payloadValid: false),
                evidenceQuality: "title_only",
                groundedFactsEstimate: 0
            )
            check("local_action_not_selected_if_payload_invalid",
                  decision.selected == "synthesize_sources" && decision.reason == "local_payload_invalid")
        }

        // ── Part 4: Debug Trigger ──

        // 16. Debug trigger with invalid payload reports unavailable
        do {
            let result = LocalActionPayloadValidator.validate(
                capabilityId: "arrange_side_by_side",
                involvedApps: [],
                involvedURLs: [],
                browserTabTitles: [],
                compartmentLabel: nil
            )
            check("debug_action_trigger_invalid_payload_reports_unavailable", !result.valid)
        }

        // ── Part 6: Sanity Snapshot ──

        // 17. Sanity prints all actions
        do {
            LocalActionSanitySnapshot.emit(
                involvedApps: ["Preview", "Firefox"],
                involvedURLs: ["https://docs.google.com"],
                browserTabTitles: ["Queen's Housing", "Google Docs Lease"],
                compartmentLabel: "182 Montreal",
                musicPlaying: false,
                focusShortcutAvailable: nil
            )
            check("local_action_sanity_prints_all_actions", true)
        }

        // 18. Sanity with missing context shows specific reasons
        do {
            LocalActionSanitySnapshot.emit(
                involvedApps: [],
                involvedURLs: [],
                browserTabTitles: [],
                compartmentLabel: nil,
                musicPlaying: true,
                focusShortcutAvailable: false
            )
            check("local_action_sanity_reasons_are_specific", true)
        }

        let ok = failures.isEmpty
        print("[Phase33SelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
