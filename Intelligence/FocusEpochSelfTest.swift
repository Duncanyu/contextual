import Foundation

/// Phase 20G.2 — FocusEpoch tracker detects intra-workflow focus switches.
///
/// Trigger:
///   CONTEXTUAL_RUN_FOCUS_EPOCH_SELFTEST=1
@MainActor
enum FocusEpochSelfTest {
	static func run() async -> Bool {
		print("[FocusEpochSelfTest] starting")
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if ok { print("[FocusEpochSelfTest] pass case=\(name)") }
			else  { print("[FocusEpochSelfTest] fail case=\(name)"); failures.append(name) }
		}

		FocusEpochTracker.shared.resetForTests()
		let now = Date()
		let a = FocusEpochTracker.shared.observeSelectedTab(
			title: "Anker 521 power bank",
			workflowLabel: "shopping",
			at: now
		)
		check("first_observation_sets_entity", a.currentEntity.lowercased().contains("anker"))

		let b = FocusEpochTracker.shared.observeSelectedTab(
			title: "BLUETTI Elite 30 portable power",
			workflowLabel: "shopping",
			at: now.addingTimeInterval(3)
		)
		check("selected_tab_change_detected", b.focusChanged)
		check("low_overlap_focus_shift_detected", b.focusShiftDetected)

		let ok = failures.isEmpty
		print("[FocusEpochSelfTest] completed ok=\(ok) failures=\(failures.count)")
		return ok
	}
}

