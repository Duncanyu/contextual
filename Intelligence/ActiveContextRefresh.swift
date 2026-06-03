import AppKit
import Foundation

/// Adaptive context refresh — wakes the pipeline when the user has been on a
/// stable context for a while so cognition does not go cold during long reads.
///
/// Design constraints (Phase 20F):
/// - No fixed "every N seconds" timer that fires regardless of state.
/// - Cheap-first: re-read window title, then `BrowserContextExtractor`, then
///   surgical OCR (only if budget allows). The cheap tiers are always logged.
/// - Cooldowns: backs off after a recent refresh, recent suggestion, or while
///   the local model is busy.
/// - Workflow-aware: when the engine has no idea what the user is doing
///   (`workflow == .unknown || .idle`), refresh is suppressed — there's no
///   point waking the engine when there is no current activity to deepen.
public actor ActiveContextRefresh {

    public static let shared = ActiveContextRefresh()

    // MARK: - Decision

    public struct Decision: Sendable, Equatable {
        public enum Action: String, Sendable, Equatable {
            case skip
            case refresh
            case suppress
        }
        public let action: Action
        public let reason: String
		public let cheapEnvironmentAllowed: Bool

		public init(action: Action, reason: String, cheapEnvironmentAllowed: Bool = false) {
			self.action = action
			self.reason = reason
			self.cheapEnvironmentAllowed = cheapEnvironmentAllowed
		}
    }

    // MARK: - Adaptive thresholds (tunable, but logged when changed)

    /// Minimum seconds between two refreshes — even if the page is stable.
    public static let refreshCooldownSeconds: TimeInterval = 15

    /// Suppress refresh when a suggestion was shown within this many seconds.
    public static let suggestionCooldownSeconds: TimeInterval = 60

    /// When evidence is weak and the page has been stable this long, refresh.
    public static let weakEvidenceStaleSeconds: TimeInterval = 20

    /// When evidence is strong but the page has been stable this long, still
    /// refresh occasionally so AX/URL state can be re-read.
    public static let strongEvidenceStaleSeconds: TimeInterval = 45

    // MARK: - State

    private var lastSignature: String = ""
    private var lastMeaningfulEventAt: Date = Date()
    private var lastSuggestionAt: Date?
    private var lastRefreshAt: Date?

    /// Latest workflow/behavior the engine reported — set by the producer
    /// after each tick so the refresh loop can be workflow-aware without
    /// having to read from AppState.
    private var latestWorkflow: AmbientWorkflowType = .unknown
    private var latestBehavior: BehavioralState = .unknown
    private var latestEvidenceQuality: String = "title_only"

    // MARK: - Pure decision (testable; no side effects)

    nonisolated public static func decide(
        now: Date,
        workflow: AmbientWorkflowType,
        behavior: BehavioralState,
        evidenceQuality: String,
        lastMeaningfulEventAge: TimeInterval,
        lastSuggestionAge: TimeInterval?,
        lastRefreshAge: TimeInterval?,
        modelBusy: Bool,
        determinerSignal: DeterminerSignal? = nil,
        activityState: ActivityState? = nil,
        compartmentDwellSeconds: TimeInterval = 0
    ) -> Decision {
        // Phase 21.1 — DeterminerSignal can pre-empt the workflow/behavior
        // suppression gates when structural context (compartment/memory) is
        // already strong enough, even if the temporal model hasn't stabilised.
        let determinerActionable = determinerSignal?.actionable == true
		// Phase 25.2 — Task D: Cheap environment allowed if determiner says actionable
		// or if we have high compartment trust (simulated here by stable active context).
			let cheapEnvAllowed = determinerActionable
				|| (activityState?.isActive == true && compartmentDwellSeconds >= 20)
				|| (activityState?.isActive == true && (activityState?.dwellSeconds ?? 0) >= 20)

		let actionabilityScore: Double = {
			var score = determinerActionable ? (determinerSignal?.confidence ?? 0.0) : 0.0
			if workflow != .unknown && workflow != .idle { score = max(score, 0.55) }
			if activityState?.isActive == true && compartmentDwellSeconds >= 120 { score = max(score, 0.70) }
			return score
		}()
		let actionabilityReason: String = {
			if determinerActionable { return "determiner_signal" }
			if activityState?.isActive == true && compartmentDwellSeconds >= 120 { return "stable_active_context" }
			if workflow != .unknown && workflow != .idle { return "workflow_known" }
			return "workflow_not_actionable"
		}()
		print("[WorkflowActionability] workflow=\(workflow.rawValue) score=\(String(format: "%.2f", actionabilityScore)) reason=\(actionabilityReason)")

        // Phase 21.4 — Task E: Dwell-based refresh trigger.
        // An actively engaged user in a stable compartment (dwell ≥ 2 min)
        // should trigger a refresh even when workflow=unknown — they may be
        // in a canvas/game/editor that produces no navigation events.
        // This check runs BEFORE the workflow suppression gate so that
        // active-unknown contexts are never silently frozen.
        let userIsActiveNow = activityState?.isActive == true && activityState?.state != .idle
        if userIsActiveNow && compartmentDwellSeconds >= 120 && !modelBusy {
            let withinCooldown: Bool = {
                guard let age = lastRefreshAge else { return false }
                return age < refreshCooldownSeconds
            }()
            if !withinCooldown {
                print("[ActiveContextRefresh] scheduled reason=stable_active_context dwell_s=\(String(format: "%.0f", compartmentDwellSeconds))")
                return Decision(action: .refresh, reason: "stable_active_context", cheapEnvironmentAllowed: true)
            }
        }

        // Suppress when there is no actionable workflow / behavior. This is
        // the same "unknown / idle" gate the suggestion generator uses, so
        // refresh logic and surface logic share a single notion of "actionable".
        if workflow == .unknown || workflow == .idle {
            if determinerActionable {
                print("[ActiveContextRefresh] allowed reason=determiner_signal_sufficient workflow=\(workflow.rawValue)")
                // Fall through — do not suppress.
            } else {
					if cheapEnvAllowed {
						print("[ActiveContextRefresh] cheap_lanes_allowed=yes reason=unknown_but_context_trusted")
						print("[ActiveContextRefresh] heavy_skipped=yes reason=workflow_unknown")
						return Decision(action: .skip, reason: "workflow_not_actionable", cheapEnvironmentAllowed: true)
					}
                return Decision(action: .suppress, reason: "workflow_not_actionable")
            }
        }
        if behavior == .unknown || behavior == .idle {
            if determinerActionable {
                // Already logged above; fall through.
            } else {
				if cheapEnvAllowed {
					print("[ActiveContextRefresh] cheap_environment_allowed=yes reason=determiner_or_compartment_trust")
					return Decision(action: .skip, reason: "behavior_not_actionable", cheapEnvironmentAllowed: true)
				}
                return Decision(action: .suppress, reason: "behavior_not_actionable")
            }
        }

        // Model busy / backpressure — coalesce.
        if modelBusy {
			if cheapEnvAllowed {
				print("[ActiveContextRefresh] cheap_environment_allowed=yes reason=determiner_or_compartment_trust")
				print("[ActiveContextRefresh] skipped_heavy=yes reason=budget")
				return Decision(action: .skip, reason: "low_budget", cheapEnvironmentAllowed: true)
			}
            return Decision(action: .skip, reason: "low_budget")
        }

        // Recent refresh — give it room.
        if let age = lastRefreshAge, age < refreshCooldownSeconds {
            return Decision(action: .skip, reason: "cooldown")
        }

        // Recent suggestion — back off so we don't pile up surfaces.
        if let age = lastSuggestionAge, age < suggestionCooldownSeconds {
            return Decision(action: .skip, reason: "recent_suggestion")
        }

        // The actual refresh signal: weak evidence + stable for ≥ 20s, OR
        // strong evidence + stable for ≥ 45s.
        if evidenceQuality == "title_only" && lastMeaningfulEventAge >= weakEvidenceStaleSeconds {
            return Decision(action: .refresh, reason: "weak_evidence_stable_page", cheapEnvironmentAllowed: true)
        }
        if lastMeaningfulEventAge >= strongEvidenceStaleSeconds {
            return Decision(action: .refresh, reason: "long_stable_page", cheapEnvironmentAllowed: true)
        }

		if cheapEnvAllowed {
			print("[ActiveContextRefresh] cheap_environment_allowed=yes reason=determiner_or_compartment_trust")
			print("[ActiveContextRefresh] environment_eval=yes")
			return Decision(action: .skip, reason: "no_meaningful_context", cheapEnvironmentAllowed: true)
		}

        return Decision(action: .skip, reason: "no_meaningful_context")
    }

    // MARK: - Actor API

    public func noteSignature(_ signature: String, now: Date = Date()) {
        if signature != lastSignature {
            lastSignature = signature
            lastMeaningfulEventAt = now
        }
    }

    public func noteSuggestion(at date: Date = Date()) {
        lastSuggestionAt = date
    }

    public func noteWorkflowAndBehavior(
        workflow: AmbientWorkflowType,
        behavior: BehavioralState,
        evidenceQuality: String = "title_only"
    ) {
        latestWorkflow = workflow
        latestBehavior = behavior
        latestEvidenceQuality = evidenceQuality
    }

    /// Decide-only entry. Logs the decision and returns it. Stateful (records
    /// `lastRefreshAt` on `.refresh`). Used by the production loop.
    @discardableResult
    public func tick(
        now: Date = Date(),
        modelBusy: Bool,
        determinerSignal: DeterminerSignal? = nil,
        activityState: ActivityState? = nil,
        compartmentDwellSeconds: TimeInterval = 0
    ) -> Decision {
        let eventAge = now.timeIntervalSince(lastMeaningfulEventAt)
        let suggestionAge = lastSuggestionAt.map { now.timeIntervalSince($0) }
        let refreshAge = lastRefreshAt.map { now.timeIntervalSince($0) }
        let d = Self.decide(
            now: now,
            workflow: latestWorkflow,
            behavior: latestBehavior,
            evidenceQuality: latestEvidenceQuality,
            lastMeaningfulEventAge: eventAge,
            lastSuggestionAge: suggestionAge,
            lastRefreshAge: refreshAge,
            modelBusy: modelBusy,
            determinerSignal: determinerSignal,
            activityState: activityState,
            compartmentDwellSeconds: compartmentDwellSeconds
        )
        switch d.action {
        case .suppress: print("[ActiveContextRefresh] suppressed reason=\(d.reason)")
        case .skip:
			print("[ActiveContextRefresh] skipped reason=\(d.reason)")
			if d.cheapEnvironmentAllowed {
				lastRefreshAt = now
			}
        case .refresh:
            print("[ActiveContextRefresh] scheduled reason=\(d.reason)")
            lastRefreshAt = now
        }
        return d
    }

    /// Performs the cheap-first refresh tiers. Cheap tier is always attempted;
    /// AX tier is best-effort via `BrowserContextExtractor`; OCR tier is
    /// deliberately deferred until a real budget signal exists.
    public func performRefresh(
        activeApp: String,
        windowTitle: String?,
        bundleIdentifier: String?
    ) async -> (url: URL?, tabTitles: [String]) {
        print("[ActiveContextRefresh] started tier=cheap")
        // Tier 1 (cheap): app + title — already captured by the snapshot.
        // Tier 2 (ax):    BrowserContextExtractor reads AX URL + tabs.
        print("[ActiveContextRefresh] started tier=ax")
        let browser = BrowserContextExtractor.extract(appName: activeApp, activeAppPID: nil)
        let url = browser?.currentURL
        let tabs = browser?.recentTabTitles ?? []
        // Tier 3 (ocr): deferred — `SurgicalOCR` currently returns empty regions
        //              outside of an AX-trusted browser frame. We log the
        //              skip so dogfooders can see we did not run OCR.
        print("[ActiveContextRefresh] started tier=ocr")
        print("[ActiveContextRefresh] skipped tier=ocr reason=no_capture_in_phase20f_scope")

        let evidenceQuality: String = url != nil ? "browser_context" : "title_only"
        let eventsCount = (url != nil ? 1 : 0) + (tabs.isEmpty ? 0 : 1) + (windowTitle?.isEmpty == false ? 1 : 0)
        print("[ActiveContextRefresh] completed events=\(eventsCount) evidence_quality=\(evidenceQuality)")
        return (url, tabs)
    }

    // MARK: - Reset (test-only)

    public func resetForTests() {
        lastSignature = ""
        lastMeaningfulEventAt = Date(timeIntervalSince1970: 0)
        lastSuggestionAt = nil
        lastRefreshAt = nil
        latestWorkflow = .unknown
        latestBehavior = .unknown
        latestEvidenceQuality = "title_only"
    }
}
