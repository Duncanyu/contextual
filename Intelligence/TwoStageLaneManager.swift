// TwoStageLaneManager.swift
import Foundation

/// In-process lane manager to serialize router and planner calls.
/// It does NOT persist state; it is purely to ensure OLLAMA_NUM_PARALLEL=1 semantics.
actor TwoStageLaneManager {
    static let shared = TwoStageLaneManager()

    private var currentPurpose: String? = nil
    /// Number of callers currently blocked waiting to acquire the lane.
    private var waitingCount: Int = 0

    /// Acquire exclusive access for a given purpose ("router" or "planner").
    /// Returns `true` if the lane was acquired, `false` if busy or cancelled.
    func acquire(purpose: String) async -> Bool {
        // Keepalive is low-priority: drop silently if lane is busy.
        if purpose == "keepalive" {
            if currentPurpose != nil {
                print("[TwoStageLane] skipped purpose=keepalive reason=busy")
                return false
            }
        }
        // Log queue depth before blocking so contention is visible in logs.
        if currentPurpose != nil {
            waitingCount += 1
            print("[TwoStageLane] queue_depth=\(waitingCount) purpose=\(purpose) blocked_by=\(currentPurpose ?? "none")")
        }
        // Wait until the lane is free.
        while currentPurpose != nil {
            if Task.isCancelled {
                waitingCount = max(0, waitingCount - 1)
                return false
            }
            // Small back-off to avoid busy-loop.
            try? await Task.sleep(nanoseconds: 20 * 1_000_000) // 20 ms
        }
        if waitingCount > 0 { waitingCount -= 1 }
        currentPurpose = purpose
        print("[TwoStageLane] acquired purpose=\(purpose) queue_depth=\(waitingCount)")
        return true
    }

    /// Release the lane, providing the elapsed milliseconds for logging.
    func release(purpose: String, elapsedMs: Int) async {
        if currentPurpose == purpose {
            currentPurpose = nil
            print("[TwoStageLane] released purpose=\(purpose) elapsed_ms=\(elapsedMs)")
        }
    }
}
