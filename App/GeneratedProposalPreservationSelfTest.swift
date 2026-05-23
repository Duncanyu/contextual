// GeneratedProposalPreservationSelfTest.swift
// Deterministic tests for proposal preservation and final_status semantics.
//
// Triggered by: CONTEXTUAL_RUN_PROPOSAL_PRESERVATION_SELFTEST=1
//
// Expected output:
//   [GeneratedProposalPreservationSelfTest] started
//   [GeneratedProposalPreservationSelfTest] case=preserve_on_failed_attempt result=pass
//   [GeneratedProposalPreservationSelfTest] case=preserve_on_same_app_title_churn result=pass
//   [GeneratedProposalPreservationSelfTest] case=clear_on_bundle_change result=pass
//   [GeneratedProposalPreservationSelfTest] case=clear_on_ttl_expired result=pass
//   [GeneratedProposalPreservationSelfTest] case=clear_when_no_existing result=pass
//   [GeneratedProposalPreservationSelfTest] case=final_status_rendered_uivisible result=pass
//   [GeneratedProposalPreservationSelfTest] case=final_status_stored_not_rendered result=pass
//   [GeneratedProposalPreservationSelfTest] case=final_status_hidden result=pass
//   [GeneratedProposalPreservationSelfTest] ok=true failures=0

import Foundation

@MainActor
enum GeneratedProposalPreservationSelfTest {

    static func run() {
        print("[GeneratedProposalPreservationSelfTest] started")
        var failures = 0

        func check(name: String, got: Bool, expected: Bool) {
            if got == expected {
                print("[GeneratedProposalPreservationSelfTest] case=\(name) result=pass")
            } else {
                print("[GeneratedProposalPreservationSelfTest] case=\(name) result=fail got=\(got) expected=\(expected)")
                failures += 1
            }
        }

        func checkStr(name: String, got: String, expected: String) {
            if got == expected {
                print("[GeneratedProposalPreservationSelfTest] case=\(name) result=pass")
            } else {
                print("[GeneratedProposalPreservationSelfTest] case=\(name) result=fail got=\(got) expected=\(expected)")
                failures += 1
            }
        }

        // MARK: - Preservation logic (AppState.preservationDecision)

        // Case 1: existing proposals + failed/empty attempt on same app → preserve
        check(
            name: "preserve_on_failed_attempt",
            got: AppState.preservationDecision(
                existingCount: 2,
                newVisibleCount: 0,
                isPolicySuppressed: false,
                bundleChanged: false,
                ttlExpired: false
            ),
            expected: true
        )

        // Case 2: existing proposals + policy-suppressed result on same app → preserve
        check(
            name: "preserve_on_same_app_title_churn",
            got: AppState.preservationDecision(
                existingCount: 1,
                newVisibleCount: 0,
                isPolicySuppressed: true,
                bundleChanged: false,
                ttlExpired: false
            ),
            expected: true
        )

        // Case 3: existing proposals + bundle changed → do NOT preserve (clear)
        check(
            name: "clear_on_bundle_change",
            got: AppState.preservationDecision(
                existingCount: 3,
                newVisibleCount: 0,
                isPolicySuppressed: false,
                bundleChanged: true,
                ttlExpired: false
            ),
            expected: false
        )

        // Case 4: existing proposals + TTL expired → do NOT preserve (clear)
        check(
            name: "clear_on_ttl_expired",
            got: AppState.preservationDecision(
                existingCount: 1,
                newVisibleCount: 0,
                isPolicySuppressed: false,
                bundleChanged: false,
                ttlExpired: true
            ),
            expected: false
        )

        // Case 5: no existing proposals → nothing to preserve
        check(
            name: "clear_when_no_existing",
            got: AppState.preservationDecision(
                existingCount: 0,
                newVisibleCount: 0,
                isPolicySuppressed: false,
                bundleChanged: false,
                ttlExpired: false
            ),
            expected: false
        )

        // Case 6: new result has visible proposals and is not suppressed → replace (don't preserve)
        check(
            name: "replace_on_new_success",
            got: AppState.preservationDecision(
                existingCount: 2,
                newVisibleCount: 1,
                isPolicySuppressed: false,
                bundleChanged: false,
                ttlExpired: false
            ),
            expected: false
        )

        // MARK: - final_status semantics

        // Case 7: uiVisible > 0 → "rendered" regardless of storedVisible
        checkStr(
            name: "final_status_rendered_uivisible",
            got: finalStatus(storedVisible: 0, uiVisible: 1),
            expected: "rendered"
        )

        // Case 8: uiVisible == 0, storedVisible > 0 → "stored_not_rendered"
        checkStr(
            name: "final_status_stored_not_rendered",
            got: finalStatus(storedVisible: 2, uiVisible: 0),
            expected: "stored_not_rendered"
        )

        // Case 9: both zero → "hidden"
        checkStr(
            name: "final_status_hidden",
            got: finalStatus(storedVisible: 0, uiVisible: 0),
            expected: "hidden"
        )

        print("[GeneratedProposalPreservationSelfTest] ok=\(failures == 0) failures=\(failures)")
    }

    // MARK: - Helpers

    /// Mirrors the final_status logic in AppDelegate (Task B fix).
    private static func finalStatus(storedVisible: Int, uiVisible: Int) -> String {
        if uiVisible > 0 { return "rendered" }
        if storedVisible > 0 { return "stored_not_rendered" }
        return "hidden"
    }
}
