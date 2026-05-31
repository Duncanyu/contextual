import Foundation

/// Minimal single-lane backpressure for local model work.
///
/// Goal: prevent workflow inference and proposal goal generation from competing
/// during startup (or any busy period) and causing long CPU spikes / timeouts.
///
/// This is intentionally simple: one purpose owns the lane at a time.
actor LocalAIBackpressure {
	static let shared = LocalAIBackpressure()

	private var activePurpose: String?

	func acquire(purpose: String) -> Bool {
		if purpose == "workflow_inference" && activePurpose == "goal_generator" {
			print("[LocalAIBackpressure] cancelled goal_generator reason=workflow_inference_priority")
			print("[LocalAIBackpressure] workflow_inference_priority=yes")
			activePurpose = purpose
			return true
		}
		if let activePurpose, activePurpose != purpose { return false }
		activePurpose = purpose
		return true
	}

	func release(purpose: String) {
		guard activePurpose == purpose else { return }
		activePurpose = nil
	}

	func currentActivePurpose() -> String? {
		activePurpose
	}
}

