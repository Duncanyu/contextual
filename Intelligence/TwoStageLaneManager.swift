// TwoStageLaneManager.swift
import Foundation

/// In‑process lane manager to serialize router and planner calls.
/// It does NOT persist state; it is purely to ensure OLLAMA_NUM_PARALLEL=1 semantics.
actor TwoStageLaneManager {
    static let shared = TwoStageLaneManager()

    private var currentPurpose: String? = nil

    /// Acquire exclusive access for a given purpose ("router" or "planner").
    /// Returns `true` if the lane was acquired, `false` if busy.
    func acquire(purpose: String) async -> Bool {
        // Keepalive purpose is a special low‑priority request that should be dropped if busy.
        if purpose == "keepalive" {
            if currentPurpose != nil {
                print("[TwoStageLane] skipped purpose=keepalive reason=busy")
                return false
            }
        }
        // Wait until the lane is free.
        while currentPurpose != nil {
            if Task.isCancelled { return false }
            // Small back‑off to avoid busy‑loop.
            try? await Task.sleep(nanoseconds: 20 * 1_000_000) // 20 ms
        }
        currentPurpose = purpose
        print("[TwoStageLane] acquired purpose=\(purpose)")
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
