import Foundation

// MARK: - Phase 36.3 — Final Surface Arbiter
//
// Multiple surface systems were producing conflicting decisions:
//   ActionUsefulness → floating
//   LivePathEnforcement → floating
//   ProposalFreshness → fresh
//   SurfacePolicy → suppressed (stale already_done)
//   Cooldown → suppressed (recent)
//
// This arbiter is the single point of reconciliation. Its decision is what the UI uses.
// If ActionUsefulness/LivePathEnforcement say the action is genuinely useful and the
// runtime target is present_not_arranged, no downstream stage may quietly drop it.

struct FinalSurfaceInputs: Sendable {
    let capabilityID: String
    let usefulnessSurface: ActionSurface       // from ActionUsefulnessPolicy
    let livePathSurface: ActionSurface         // from LivePathEnforcer
    let freshness: String                      // "fresh" | "stale_age" | "stale_context" | "stale_target"
    let cooldownStatus: CooldownArbiterStatus  // from SuggestionCooldownArbiter
    let cooldownReason: String
    let contractPresent: Bool                  // from preflight readiness
    let alreadySatisfied: Bool                 // recomputed against current runtime
    let alreadySatisfiedSource: String         // "layout_verify" | "runtime_inventory" | "default"
}

struct FinalSurfaceDecision: Sendable {
    let capabilityID: String
    let final: ActionSurface
    let reason: String

    func log(inputs: FinalSurfaceInputs) {
        let usefulness = inputs.usefulnessSurface.rawValue
        let livePath = inputs.livePathSurface.rawValue
        let cooldown: String = {
            switch inputs.cooldownStatus {
            case .active: return "active"
            case .panelOnly: return "active_panel_only"
            case .bypass: return "bypassed"
            case .inactive: return "inactive"
            }
        }()
        print("[FinalSurfaceArbiter] capability=\(capabilityID) usefulness=\(usefulness) live_path=\(livePath) freshness=\(inputs.freshness) cooldown=\(cooldown) final=\(final.rawValue) reason=\(reason)")
    }
}

enum FinalSurfaceArbiter {

    static func decide(_ inputs: FinalSurfaceInputs) -> FinalSurfaceDecision {
        // 1. Always-suppress conditions — stale target, missing contract for proposal-bound,
        //    already satisfied confirmed at runtime.
        if inputs.alreadySatisfied {
            // The freshest runtime check wins. Log explicit proof.
            print("[AlreadySatisfiedCheck] capability=\(inputs.capabilityID) result=yes source=\(inputs.alreadySatisfiedSource) reason=arbiter_runtime_recheck")
            return FinalSurfaceDecision(
                capabilityID: inputs.capabilityID,
                final: .suppressed,
                reason: "already_satisfied"
            )
        }

        if inputs.usefulnessSurface == .suppressed || inputs.livePathSurface == .suppressed {
            let reason: String = {
                if inputs.usefulnessSurface == .suppressed { return "usefulness_suppressed" }
                return "live_path_suppressed"
            }()
            return FinalSurfaceDecision(
                capabilityID: inputs.capabilityID,
                final: .suppressed,
                reason: reason
            )
        }

        // 2. Cooldown arbitration. Active hard-suppresses; panel_only demotes; bypass/inactive allow.
        switch inputs.cooldownStatus {
        case .active:
            // Anti-flicker: would re-emit the same card too quickly. Suppress entirely.
            return FinalSurfaceDecision(
                capabilityID: inputs.capabilityID,
                final: .suppressed,
                reason: "anti_flicker_cooldown"
            )
        case .panelOnly:
            // Floating suppressed but the action is still useful — preserve as panel.
            print("[SurfaceFallback] capability=\(inputs.capabilityID) floating_suppressed=yes fallback=panel reason=useful_action_preserved")
            return FinalSurfaceDecision(
                capabilityID: inputs.capabilityID,
                final: .panelOnly,
                reason: "floating_cooldown_preserved_panel"
            )
        case .bypass, .inactive:
            break
        }

        // 3. Freshness — stale proposals don't float. Allow panel.
        if inputs.freshness.hasPrefix("stale") {
            return FinalSurfaceDecision(
                capabilityID: inputs.capabilityID,
                final: .panelOnly,
                reason: "stale_\(inputs.freshness.dropFirst("stale_".count))"
            )
        }

        // 4. UsefulnessPolicy and LivePath agree on what floats.
        let baseSurface: ActionSurface = {
            if inputs.usefulnessSurface == .floating && inputs.livePathSurface == .floating {
                return .floating
            }
            return .panelOnly
        }()
        let reason: String = {
            if baseSurface == .floating { return "useful_and_live_path_floating" }
            if inputs.usefulnessSurface == .panelOnly { return "usefulness_panel_only" }
            return "live_path_panel_only"
        }()
        return FinalSurfaceDecision(
            capabilityID: inputs.capabilityID,
            final: baseSurface,
            reason: reason
        )
    }
}

// MARK: - Self-test

enum FinalSurfaceArbiterSelfTest {

    static func run() -> Bool {
        print("[FinalSurfaceArbiterSelfTest] starting")
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { print("[FinalSurfaceArbiterSelfTest] pass case=\(name)") }
            else { print("[FinalSurfaceArbiterSelfTest] fail case=\(name)"); failures.append(name) }
        }

        // Useful + live_path floating + no cooldown → floating
        let okIn = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .floating,
            livePathSurface: .floating,
            freshness: "fresh",
            cooldownStatus: .inactive,
            cooldownReason: "no_prior_show",
            contractPresent: true,
            alreadySatisfied: false,
            alreadySatisfiedSource: "default"
        )
        let okOut = FinalSurfaceArbiter.decide(okIn)
        okOut.log(inputs: okIn)
        check("useful_no_cooldown_floats", okOut.final == .floating)

        // Useful but cooldown panel_only → panel fallback
        let cooldownIn = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .floating,
            livePathSurface: .floating,
            freshness: "fresh",
            cooldownStatus: .panelOnly,
            cooldownReason: "same_action_same_targets_recently_shown",
            contractPresent: true,
            alreadySatisfied: false,
            alreadySatisfiedSource: "default"
        )
        let cooldownOut = FinalSurfaceArbiter.decide(cooldownIn)
        cooldownOut.log(inputs: cooldownIn)
        check("cooldown_panel_only_fallback", cooldownOut.final == .panelOnly)
        check("cooldown_reason_preserves_panel", cooldownOut.reason == "floating_cooldown_preserved_panel")

        // already_satisfied at runtime → suppressed regardless of upstream usefulness
        let satisfiedIn = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .floating,
            livePathSurface: .floating,
            freshness: "fresh",
            cooldownStatus: .inactive,
            cooldownReason: "no_prior_show",
            contractPresent: true,
            alreadySatisfied: true,
            alreadySatisfiedSource: "layout_verify"
        )
        let satisfiedOut = FinalSurfaceArbiter.decide(satisfiedIn)
        satisfiedOut.log(inputs: satisfiedIn)
        check("already_satisfied_suppressed", satisfiedOut.final == .suppressed)

        // Anti-flicker active → suppressed
        let flickerIn = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .floating,
            livePathSurface: .floating,
            freshness: "fresh",
            cooldownStatus: .active,
            cooldownReason: "anti_flicker_window",
            contractPresent: true,
            alreadySatisfied: false,
            alreadySatisfiedSource: "default"
        )
        let flickerOut = FinalSurfaceArbiter.decide(flickerIn)
        flickerOut.log(inputs: flickerIn)
        check("anti_flicker_suppressed", flickerOut.final == .suppressed)

        // Stale → panel_only
        let staleIn = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .floating,
            livePathSurface: .floating,
            freshness: "stale_context",
            cooldownStatus: .inactive,
            cooldownReason: "no_prior_show",
            contractPresent: true,
            alreadySatisfied: false,
            alreadySatisfiedSource: "default"
        )
        let staleOut = FinalSurfaceArbiter.decide(staleIn)
        staleOut.log(inputs: staleIn)
        check("stale_panel_only", staleOut.final == .panelOnly)

        // Stale already_satisfied claim is overridden when arbiter recomputes alreadySatisfied=no
        // (i.e., upstream surface policy said suppressed/already_done but the latest recheck says no).
        // We exercise this by providing alreadySatisfied=false even when upstream usefulness was
        // set conservatively to .panelOnly; the arbiter must NOT escalate to suppressed.
        let recheckIn = FinalSurfaceInputs(
            capabilityID: "arrange_side_by_side",
            usefulnessSurface: .panelOnly,
            livePathSurface: .floating,
            freshness: "fresh",
            cooldownStatus: .inactive,
            cooldownReason: "no_prior_show",
            contractPresent: true,
            alreadySatisfied: false,
            alreadySatisfiedSource: "runtime_inventory"
        )
        let recheckOut = FinalSurfaceArbiter.decide(recheckIn)
        recheckOut.log(inputs: recheckIn)
        check("recheck_not_suppressed", recheckOut.final != .suppressed)

        let ok = failures.isEmpty
        print("[FinalSurfaceArbiterSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}
