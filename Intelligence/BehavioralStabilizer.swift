import Foundation

/// Smooths the behavioral model's per-tick output into a stable BehavioralStateRecord.
///
/// Rules:
/// 1. Same state -> retain and accumulate stability.
/// 2. Strong confidence shift (>= 0.80) -> commit immediately.
/// 3. Weak confidence (< 0.50) -> retain current.
/// 4. Medium confidence shift -> require 2 confirmations before committing.
/// 5. Decay — after 5 minutes (300 seconds) without confirmation, state expires to .unknown.
public struct BehavioralStabilizer: Sendable {

    public static let strongConfidence: Double = 0.80
    public static let weakConfidence: Double = 0.50
    public static let requiredConfirmations: Int = 2
    public static let decaySeconds: TimeInterval = 300 // 5 minutes

    public private(set) var current: BehavioralStateRecord
    private var pendingCandidate: BehavioralStateRecord?
    private var pendingConfirmations: Int

    public init(initial: BehavioralStateRecord = .empty) {
        self.current = initial
        self.pendingCandidate = nil
        self.pendingConfirmations = 0
    }

    public mutating func ingest(
        candidate: BehavioralStateRecord,
        now: Date = Date()
    ) -> BehavioralStateRecord {

        // Phase 20B Deterministic Fallback Commit
        if candidate.reasoning == "deterministic_temporal_fallback" {
            current = BehavioralStateRecord(
                state: candidate.state,
                confidence: candidate.confidence,
                reasoning: candidate.reasoning,
                startedAt: now,
                lastUpdatedAt: now,
                stabilityScore: 0.5
            )
            pendingCandidate = nil
            pendingConfirmations = 0
            return current
        }

        // 5. Decay: drop established state if we've been silent too long.
        if current.state != .unknown {
            let sinceUpdate = now.timeIntervalSince(current.lastUpdatedAt)
            if sinceUpdate > Self.decaySeconds {
                print("[BehaviorState] decayed state=\(current.state.rawValue) elapsed_s=\(Int(sinceUpdate))")
                current = BehavioralStateRecord(
                    state: .unknown,
                    confidence: 0.0,
                    reasoning: "decayed",
                    startedAt: now,
                    lastUpdatedAt: now,
                    stabilityScore: 0.0
                )
                pendingCandidate = nil
                pendingConfirmations = 0
            }
        }

        // 1. Same behavior state -> retain and grow stability.
        if candidate.state == current.state && current.state != .unknown {
            let grown = min(current.stabilityScore + 0.10, 1.0)
            current = BehavioralStateRecord(
                state: current.state,
                confidence: candidate.confidence,
                reasoning: candidate.reasoning,
                startedAt: current.startedAt,
                lastUpdatedAt: now,
                stabilityScore: grown
            )
            pendingCandidate = nil
            pendingConfirmations = 0
            return current
        }

        // 2. Strong confidence -> immediate commit.
        if candidate.confidence >= Self.strongConfidence {
            current = BehavioralStateRecord(
                state: candidate.state,
                confidence: candidate.confidence,
                reasoning: candidate.reasoning,
                startedAt: now,
                lastUpdatedAt: now,
                stabilityScore: 0.5
            )
            pendingCandidate = nil
            pendingConfirmations = 0
            return current
        }

        // 3. Weak confidence -> retain.
        if candidate.confidence < Self.weakConfidence {
            return current
        }

        // 4. Medium confidence -> debounce.
        if let pending = pendingCandidate, pending.state == candidate.state {
            pendingConfirmations += 1
            if pendingConfirmations >= Self.requiredConfirmations {
                current = BehavioralStateRecord(
                    state: candidate.state,
                    confidence: candidate.confidence,
                    reasoning: candidate.reasoning,
                    startedAt: now,
                    lastUpdatedAt: now,
                    stabilityScore: 0.5
                )
                pendingCandidate = nil
                pendingConfirmations = 0
                return current
            }
            return current
        }

        // New medium-confidence direction — open a pending slot.
        pendingCandidate = candidate
        pendingConfirmations = 1
        return current
    }
}
