import Foundation

/// Smooths the model's per-tick output into a stable `WorkflowState`.
///
/// Rules:
/// 1. **Same workflow → retain** and accumulate stability.
/// 2. **Strong confidence shift** (`>= strongConfidence`) → commit immediately.
/// 3. **Weak confidence** (`< weakConfidence`) → retain current (single weak
///    tab-shift cannot override an established workflow).
/// 4. **Medium confidence shift** → require `requiredConfirmations` consecutive
///    same-label readings before committing.
/// 5. **Decay** — after `decaySeconds` without confirmation, the workflow
///    expires back to `.unknown`.
///
/// The stabilizer is intentionally a value type — owners hold one instance per
/// session and call `ingest` once per inference tick.
public struct WorkflowStabilizer: Sendable {

    public static let strongConfidence: Double = 0.85
    public static let weakConfidence: Double = 0.55
    public static let requiredConfirmations: Int = 2
    public static let decaySeconds: TimeInterval = 600
    /// B.1.6: the minimum candidate confidence at which a fresh context-shift
    /// signal is allowed to bypass the normal debounce path and commit
    /// immediately. This is what stops a wrong "writing" state from sticking
    /// after the user moves from Gmail to Amazon.
    public static let freshShiftCorrectionConfidence: Double = 0.70

    public private(set) var current: WorkflowState
    private var pendingCandidate: WorkflowState?
    private var pendingConfirmations: Int

    public init(initial: WorkflowState = .empty) {
        self.current = initial
        self.pendingCandidate = nil
        self.pendingConfirmations = 0
    }

    /// Fold one inference reading into the stabilized state.
    ///
    /// `freshShiftSignal` (B.1.6) — set to `true` when the compressor detected a
    /// recent topic-distribution shift. Lets a moderate-confidence candidate
    /// override the current committed state immediately, instead of waiting
    /// for the normal `requiredConfirmations` debounce or the decay window.
    @discardableResult
    public mutating func ingest(
        candidate: WorkflowState,
        now: Date = Date(),
        freshShiftSignal: Bool = false
    ) -> WorkflowState {

        // 5. Decay: drop established state if we've been silent too long.
        if current.workflowType != .unknown {
            let sinceUpdate = now.timeIntervalSince(current.lastUpdatedAt)
            if sinceUpdate > Self.decaySeconds {
                print("[WorkflowStability] decayed previous=\(current.workflowType.rawValue) elapsed_s=\(Int(sinceUpdate))")
                current = WorkflowState.empty
                pendingCandidate = nil
                pendingConfirmations = 0
            }
        }

        // 1. Same workflow → retain and grow stability.
        if candidate.workflowType == current.workflowType && current.workflowType != .unknown {
            let grown = min(current.stabilityScore + 0.05, 1.0)
            current = WorkflowState(
                workflowType: current.workflowType,
                confidence: candidate.confidence,
                evidence: candidate.evidence.isEmpty ? current.evidence : candidate.evidence,
                uncertainty: candidate.uncertainty,
                startedAt: current.startedAt,
                lastUpdatedAt: now,
                stabilityScore: grown,
                dominantApps: candidate.dominantApps,
                repeatedTerms: candidate.repeatedTerms,
                recentTransitions: candidate.recentTransitions,
                suggestedIntentHints: candidate.suggestedIntentHints,
                sourcePacketHash: candidate.sourcePacketHash
            )
            pendingCandidate = nil
            pendingConfirmations = 0
            print("[WorkflowStability] current=\(current.workflowType.rawValue) candidate=\(candidate.workflowType.rawValue) retained=yes")
            return current
        }

        // 2. Strong confidence → immediate commit.
        if candidate.confidence >= Self.strongConfidence {
            current = WorkflowState(
                workflowType: candidate.workflowType,
                confidence: candidate.confidence,
                evidence: candidate.evidence,
                uncertainty: candidate.uncertainty,
                startedAt: now,
                lastUpdatedAt: now,
                stabilityScore: 0.5,
                dominantApps: candidate.dominantApps,
                repeatedTerms: candidate.repeatedTerms,
                recentTransitions: candidate.recentTransitions,
                suggestedIntentHints: candidate.suggestedIntentHints,
                sourcePacketHash: candidate.sourcePacketHash
            )
            pendingCandidate = nil
            pendingConfirmations = 0
            print("[WorkflowStability] committed=\(current.workflowType.rawValue) reason=high_confidence_shift")
            return current
        }

        // 2.5. B.1.6 fast correction: a fresh context-shift signal + moderate
        // confidence bypasses both the debounce and the decay window. Without
        // this branch, a wrong "writing" commit would persist for up to 10 min
        // even after the user clearly switched activities.
        if freshShiftSignal
           && candidate.confidence >= Self.freshShiftCorrectionConfidence
           && candidate.workflowType != current.workflowType {
            let previous = current.workflowType.rawValue
            current = WorkflowState(
                workflowType: candidate.workflowType,
                confidence: candidate.confidence,
                evidence: candidate.evidence,
                uncertainty: candidate.uncertainty,
                startedAt: now,
                lastUpdatedAt: now,
                stabilityScore: 0.4,
                dominantApps: candidate.dominantApps,
                repeatedTerms: candidate.repeatedTerms,
                recentTransitions: candidate.recentTransitions,
                suggestedIntentHints: candidate.suggestedIntentHints,
                sourcePacketHash: candidate.sourcePacketHash
            )
            pendingCandidate = nil
            pendingConfirmations = 0
            print("[WorkflowStability] corrected=\(current.workflowType.rawValue) previous=\(previous) reason=fresh_context_shift")
            return current
        }

        // 3. Weak confidence → retain. Distinguish the "no fresh shift" reason
        // when one was specifically NOT detected, so dogfood logs can see why
        // the stabilizer didn't take the candidate.
        if candidate.confidence < Self.weakConfidence {
            let reason = freshShiftSignal ? "weak_confidence_despite_shift" : "weak_single_tab_shift"
            print("[WorkflowStability] current=\(current.workflowType.rawValue) candidate=\(candidate.workflowType.rawValue) retained=yes reason=\(reason)")
            return current
        }

        // 3.5. B.1.6: if a candidate is mid-confidence but there is NO fresh
        // shift, retain the current state explicitly with a clear reason.
        if !freshShiftSignal
           && candidate.workflowType != current.workflowType
           && candidate.confidence < Self.strongConfidence
           && current.workflowType != .unknown
           && pendingCandidate == nil {
            // Fall through to the standard debounce path below; this log makes
            // the "no_fresh_counterevidence" decision visible.
            print("[WorkflowStability] retained=\(current.workflowType.rawValue) reason=no_fresh_counterevidence")
        }

        // 4. Medium confidence → debounce.
        if let pending = pendingCandidate, pending.workflowType == candidate.workflowType {
            pendingConfirmations += 1
            if pendingConfirmations >= Self.requiredConfirmations {
                current = WorkflowState(
                    workflowType: candidate.workflowType,
                    confidence: candidate.confidence,
                    evidence: candidate.evidence,
                    uncertainty: candidate.uncertainty,
                    startedAt: now,
                    lastUpdatedAt: now,
                    stabilityScore: 0.4,
                    dominantApps: candidate.dominantApps,
                    repeatedTerms: candidate.repeatedTerms,
                    recentTransitions: candidate.recentTransitions,
                    suggestedIntentHints: candidate.suggestedIntentHints,
                    sourcePacketHash: candidate.sourcePacketHash
                )
                pendingCandidate = nil
                pendingConfirmations = 0
                print("[WorkflowStability] committed=\(current.workflowType.rawValue) reason=debounced_confirmed")
                return current
            }
            print("[WorkflowStability] current=\(current.workflowType.rawValue) candidate=\(candidate.workflowType.rawValue) retained=yes reason=awaiting_confirmation count=\(pendingConfirmations)")
            return current
        }

        // New medium-confidence direction — open a pending slot.
        pendingCandidate = candidate
        pendingConfirmations = 1
        print("[WorkflowStability] current=\(current.workflowType.rawValue) candidate=\(candidate.workflowType.rawValue) retained=yes reason=new_pending")
        return current
    }
}
