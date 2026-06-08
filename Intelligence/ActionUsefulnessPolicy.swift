import Foundation

// MARK: - Surface Recommendation

enum ActionSurface: String, Sendable {
    case floating
    case panelOnly = "panel_only"
    case suppressed
}

// MARK: - Usefulness Decision

struct ActionUsefulnessDecision: Sendable {
    let capabilityID: String
    let targetPresent: Bool
    let alreadySatisfied: Bool
    let timeSavedEstimate: String
    let interruptionCost: String
    let eligible: Bool
    let surface: ActionSurface
    let reason: String

    func log() {
        if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
            print("[ActionUsefulness] capability=\(capabilityID) target_present=\(targetPresent ? "yes" : "no") already_satisfied=\(alreadySatisfied ? "yes" : "no") time_saved=\(timeSavedEstimate) interruption_cost=\(interruptionCost) eligible=\(eligible ? "yes" : "no") surface=\(surface.rawValue) reason=\(reason)")
        }
    }
}

// MARK: - Metadata utility IDs (panel-only by default)

private let metadataUtilityIDs: Set<String> = [
    "copy_current_url",
    "collect_references",
    "copy_all_related_links",
    "remember_workspace",
    "open_current_task_panel",
    "extract_and_organize"
]

// MARK: - Usefulness Policy

enum ActionUsefulnessPolicy {

    static func evaluate(
        capabilityID: String,
        targetPresent: Bool,
        alreadySatisfied: Bool,
        contractFresh: Bool,
        activityMatch: Bool,
        userFeedbackHistory: String,
        confidence: Double,
        evidenceAvailable: Bool,
        hasExplicitUsageSignal: Bool
    ) -> ActionUsefulnessDecision {
        let decision: ActionUsefulnessDecision = {
            if !targetPresent {
                return make(capabilityID, present: false, satisfied: false, saved: "low", cost: "low", eligible: false, surface: .suppressed, reason: "target_missing")
            }
            if alreadySatisfied {
                return make(capabilityID, present: true, satisfied: true, saved: "low", cost: "low", eligible: false, surface: .suppressed, reason: "already_satisfied")
            }
            if !contractFresh {
                return make(capabilityID, present: true, satisfied: false, saved: "low", cost: "low", eligible: false, surface: .suppressed, reason: "stale_contract")
            }
            if !evidenceAvailable {
                return make(capabilityID, present: true, satisfied: false, saved: "low", cost: "low", eligible: false, surface: .suppressed, reason: "insufficient_evidence")
            }

            // Metadata utilities: panel_only by default unless explicit signal
            if metadataUtilityIDs.contains(capabilityID) {
                if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
                    logMetadataDemotion(capabilityID)
                }
                if hasExplicitUsageSignal {
                    return make(capabilityID, present: true, satisfied: false, saved: "medium", cost: "low", eligible: true, surface: .floating, reason: "metadata_utility_explicit_signal")
                }
                return make(capabilityID, present: true, satisfied: false, saved: "low", cost: "low", eligible: true, surface: .panelOnly, reason: "metadata_utility_low_interrupt")
            }

            if userFeedbackHistory == "negative" {
                return make(capabilityID, present: true, satisfied: false, saved: "low", cost: "high", eligible: false, surface: .suppressed, reason: "negative_feedback_history")
            }

            let (saved, cost) = estimateCosts(capabilityID: capabilityID, confidence: confidence, activityMatch: activityMatch)
            let canFloat = saved == "high" && (cost == "low" || cost == "medium")
            let surface: ActionSurface = canFloat ? .floating : .panelOnly
            return make(capabilityID, present: true, satisfied: false, saved: saved, cost: cost, eligible: true, surface: surface, reason: canFloat ? "high_usefulness_low_cost" : "moderate_usefulness")
        }()

        if metadataUtilityIDs.contains(capabilityID) {
            if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
                print("[UtilityAction] capability=\(capabilityID) surface=\(decision.surface.rawValue) reason=\(decision.reason)")
            }
        }
        return decision
    }

    static func evaluateMediaUsefulness(
        capabilityID: String,
        mediaState: EnvironmentMediaState,
        isWatching: Bool
    ) -> Bool {
        let foregroundMedia = mediaState.visualMediaKind != .none || isWatching
        let backgroundMusic = mediaState.isMusicPlaying ? "playing" : "stopped"
        let conflict = foregroundMedia && mediaState.isMusicPlaying
        
        if LogControl.shared.shouldLog(category: .runtime_pair_scoring, level: .trace) {
            print("[MediaAwareness] foreground_media=\(foregroundMedia ? "yes" : "no") confidence=high background_music=\(backgroundMusic) conflict=\(conflict ? "yes" : "no")")
        }
        
        if capabilityID == "pause_media" {
            let eligible = conflict
            if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
                print("[MediaUsefulness] capability=pause_media eligible=\(eligible ? "yes" : "no") reason=\(eligible ? "conflict_detected" : "no_conflict")")
            }
            if eligible {
                print("[MusicSuggestion] generated capability=pause_media reason=foreground_media_active")
            }
            return eligible
        } else if capabilityID == "play_focus_media" || capabilityID == "resume_focus_media" {
            let eligible = !foregroundMedia && !mediaState.isMusicPlaying
            if LogControl.shared.shouldLog(category: .selection_reasoning, level: .dogfood) {
                print("[MediaUsefulness] capability=\(capabilityID) eligible=\(eligible ? "yes" : "no") reason=\(eligible ? "stable_work_context" : (foregroundMedia ? "foreground_media_active" : "music_already_playing"))")
            }
            if foregroundMedia {
                if LogControl.shared.shouldLog(category: .selection_reasoning, level: .trace) {
                    print("[MusicSuggestion] suppressed reason=foreground_media_no_music_needed")
                }
            } else if eligible {
                print("[MusicSuggestion] generated capability=\(capabilityID) reason=stable_work_context")
            }
            return eligible
        }
        return true
    }

    static func getUsefulnessLevel(capabilityID: String, lane: String) -> String {
        let highValue: Set<String> = [
            "arrange_side_by_side", "switch_to_paired_app", "restore_workspace",
            "explicit_visible_capture_summary", "extract_action_items", "create_checklist",
            "rewrite_text", "explain_context", "draft_reply", "diagnose_error", "improve_text"
        ]
        if highValue.contains(capabilityID) || lane == "friction" || lane == "workspace" || lane == "cognitive" || lane == "research" || lane == "coding" || lane == "communication" {
            return "high"
        }
        
        let lowValue: Set<String> = [
            "copy_current_url", "collect_references", "copy_all_related_links", "remember_workspace", "open_current_task_panel", "extract_and_organize"
        ]
        if lowValue.contains(capabilityID) || lane == "metadata" {
            return "low"
        }
        
        return "medium"
    }

    static func compareUsefulnessAndScore(
        capA: String, laneA: String, scoreA: Double,
        capB: String, laneB: String, scoreB: Double
    ) -> Bool {
        let useA = getUsefulnessLevel(capabilityID: capA, lane: laneA)
        let useB = getUsefulnessLevel(capabilityID: capB, lane: laneB)
        
        let rank: [String: Int] = ["high": 3, "medium": 2, "low": 1]
        let rankA = rank[useA] ?? 0
        let rankB = rank[useB] ?? 0
        
        if rankA != rankB {
            return rankA > rankB
        }
        return scoreA > scoreB
    }

    private static func make(
        _ id: String, present: Bool, satisfied: Bool,
        saved: String, cost: String,
        eligible: Bool, surface: ActionSurface, reason: String
    ) -> ActionUsefulnessDecision {
        let d = ActionUsefulnessDecision(
            capabilityID: id, targetPresent: present, alreadySatisfied: satisfied,
            timeSavedEstimate: saved, interruptionCost: cost,
            eligible: eligible, surface: surface, reason: reason
        )
        d.log()
        return d
    }

    private static func logMetadataDemotion(_ capabilityID: String) {
        switch capabilityID {
        case "copy_current_url":
            print("[ActionUsefulness] capability=copy_current_url surface=panel_only reason=metadata_utility_low_interrupt")
        case "collect_references", "copy_all_related_links":
            print("[ActionUsefulness] capability=collect_references surface=panel_only reason=metadata_utility_low_interrupt")
        case "remember_workspace":
            print("[ActionUsefulness] capability=remember_workspace surface=panel_only reason=metadata_utility_low_interrupt")
        case "open_current_task_panel":
            print("[ActionUsefulness] capability=open_current_task_panel surface=panel_only reason=metadata_utility_low_interrupt")
        default:
            break
        }
    }

    private static func estimateCosts(capabilityID: String, confidence: Double, activityMatch: Bool) -> (String, String) {
        let highValue: Set<String> = [
            "arrange_side_by_side", "switch_to_paired_app", "split_research_setup",
            "play_focus_media", "pause_media", "restore_workspace", "launch_recent_workspace"
        ]
        let mediumValue: Set<String> = [
            "restore_research_tabs", "open_related_app_set", "open_paired_app",
            "switch_to_last_task_window", "enable_reduce_interruptions"
        ]
        let lowInterrupt: Set<String> = [
            "arrange_side_by_side", "switch_to_paired_app", "play_focus_media",
            "pause_media", "restore_workspace", "launch_recent_workspace",
            "switch_to_last_task_window", "open_paired_app"
        ]

        let saved: String
        if highValue.contains(capabilityID) && activityMatch { saved = "high" }
        else if mediumValue.contains(capabilityID) || confidence > 0.7 { saved = "medium" }
        else { saved = "low" }

        let cost = lowInterrupt.contains(capabilityID) ? "low" : "medium"
        return (saved, cost)
    }
}

// MARK: - Proposal Freshness

struct ProposalFreshnessResult: Sendable {
    let fresh: Bool
    let ageSeconds: Double
    let contextShift: Bool
    let targetValid: Bool

    func log(capabilityID: String) {
        print("[ProposalFreshness] capability=\(capabilityID) fresh=\(fresh ? "yes" : "no") age_s=\(Int(ageSeconds)) context_shift=\(contextShift ? "yes" : "no") target_valid=\(targetValid ? "yes" : "no")")
    }
}

enum ProposalFreshnessChecker {

    static let maxAgeSeconds: TimeInterval = 120

    static func check(
        capabilityID: String,
        generatedAt: Date,
        contract: ActionTargetContract?,
        currentContextSignature: String,
        proposalContextSignature: String
    ) -> ProposalFreshnessResult {
        let age = Date().timeIntervalSince(generatedAt)
        let contextShift = currentContextSignature != proposalContextSignature
        let targetValid = contract.map { !$0.isExpired } ?? true
        let fresh = age < maxAgeSeconds && !contextShift && targetValid

        let result = ProposalFreshnessResult(fresh: fresh, ageSeconds: age, contextShift: contextShift, targetValid: targetValid)
        result.log(capabilityID: capabilityID)

        if !fresh {
            if !targetValid {
                print("[ProposalFunnelAudit] not_generated capability=\(capabilityID) reason=target_missing")
            } else if contextShift {
                print("[ProposalFunnelAudit] not_generated capability=\(capabilityID) reason=context_shifted")
            } else {
                print("[ProposalFunnelAudit] not_generated capability=\(capabilityID) reason=low_usefulness")
            }
        }
        return result
    }
}

// MARK: - Self-test

enum ActionUsefulnessPolicySelfTest {

    static func run() -> Bool {
        print("[ActionUsefulnessPolicySelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[ActionUsefulnessPolicySelfTest] pass case=\(name)") }
            else { print("[ActionUsefulnessPolicySelfTest] fail case=\(name)"); failures.append(name) }
        }

        // Metadata utilities default to panel_only
        let copyURL = ActionUsefulnessPolicy.evaluate(
            capabilityID: "copy_current_url",
            targetPresent: true, alreadySatisfied: false, contractFresh: true,
            activityMatch: true, userFeedbackHistory: "neutral",
            confidence: 0.9, evidenceAvailable: true, hasExplicitUsageSignal: false
        )
        check("copy_url_panel_only_by_default", copyURL.surface == .panelOnly)

        let remWS = ActionUsefulnessPolicy.evaluate(
            capabilityID: "remember_workspace",
            targetPresent: true, alreadySatisfied: false, contractFresh: true,
            activityMatch: true, userFeedbackHistory: "neutral",
            confidence: 0.9, evidenceAvailable: true, hasExplicitUsageSignal: false
        )
        check("remember_workspace_panel_only", remWS.surface == .panelOnly)

        // Metadata with explicit signal can float
        let copyURLExplicit = ActionUsefulnessPolicy.evaluate(
            capabilityID: "copy_current_url",
            targetPresent: true, alreadySatisfied: false, contractFresh: true,
            activityMatch: true, userFeedbackHistory: "neutral",
            confidence: 0.9, evidenceAvailable: true, hasExplicitUsageSignal: true
        )
        check("copy_url_explicit_signal_floats", copyURLExplicit.surface == .floating)

        // Missing target → suppressed
        let missing = ActionUsefulnessPolicy.evaluate(
            capabilityID: "arrange_side_by_side",
            targetPresent: false, alreadySatisfied: false, contractFresh: true,
            activityMatch: true, userFeedbackHistory: "neutral",
            confidence: 0.9, evidenceAvailable: true, hasExplicitUsageSignal: false
        )
        check("missing_target_suppressed", missing.surface == .suppressed)

        // Already satisfied → suppressed
        let satisfied = ActionUsefulnessPolicy.evaluate(
            capabilityID: "arrange_side_by_side",
            targetPresent: true, alreadySatisfied: true, contractFresh: true,
            activityMatch: true, userFeedbackHistory: "neutral",
            confidence: 0.9, evidenceAvailable: true, hasExplicitUsageSignal: false
        )
        check("already_satisfied_suppressed", satisfied.surface == .suppressed)

        // High-value layout action can float
        let layout = ActionUsefulnessPolicy.evaluate(
            capabilityID: "arrange_side_by_side",
            targetPresent: true, alreadySatisfied: false, contractFresh: true,
            activityMatch: true, userFeedbackHistory: "neutral",
            confidence: 0.9, evidenceAvailable: true, hasExplicitUsageSignal: false
        )
        check("layout_high_value_floating", layout.surface == .floating)

        // Proposal freshness: old proposal → stale
        let oldFreshness = ProposalFreshnessChecker.check(
            capabilityID: "arrange_side_by_side",
            generatedAt: Date().addingTimeInterval(-200),
            contract: nil,
            currentContextSignature: "ctx_a",
            proposalContextSignature: "ctx_a"
        )
        check("old_proposal_not_fresh", !oldFreshness.fresh)

        // Context shift → stale
        let shiftedFreshness = ProposalFreshnessChecker.check(
            capabilityID: "arrange_side_by_side",
            generatedAt: Date(),
            contract: nil,
            currentContextSignature: "ctx_b",
            proposalContextSignature: "ctx_a"
        )
        check("context_shift_not_fresh", !shiftedFreshness.fresh)

        let ok = failures.isEmpty
        print("[ActionUsefulnessPolicySelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
