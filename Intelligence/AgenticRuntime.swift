import Foundation
import AppKit        // AXIsProcessTrusted
import CoreGraphics  // CGEvent for controlled interactions

// MARK: - Status

/// Outcome of AgenticRuntime.execute().
enum AgenticRuntimeStatus: String, Sendable, Equatable, Codable, CaseIterable {
	/// Plan validated; active execution not yet implemented in this phase.
	case preview_ready
	/// Runtime completed a bounded step sequence successfully.
	case controlled_success
	/// Stopped because an unsafe action was required and not allowed.
	case blocked_unsafe_action
	/// No AgenticTaskPlan was provided.
	case rejected_missing_plan
	/// Budget limits are out of range (misconfigured).
	case rejected_budget_invalid
	/// Plan references execution families not allowed in this phase.
	case rejected_phase_constraint
}

// MARK: - Session State

/// Mutable state threaded through the Phase 4D loop.
struct AgenticSessionState: Sendable {
	let planId: String
	let goal: String
	let workflow: String
	var stepIndex: Int
	let maxSteps: Int
	var llmCallsUsed: Int
	var ocrCallsUsed: Int
	var scrollsUsed: Int
	var findsUsed: Int
	let maxScrolls: Int
	let maxFinds: Int
	let startedAt: Date
	var observations: [AgenticObservation]
	var extractedFacts: [String]
	var finalAnswer: String?
	var stopReason: AgenticStopCondition?
	var actionsExecuted: [String]
	/// Set to true after any controlled interaction; forces next step to observe_once.
	var forceObserveNext: Bool
	/// True when the most recent completed action was a controlled interaction (scroll/find).
	/// Passed to the observer so it can log stale snapshot reuse.
	var lastActionWasControl: Bool
	/// Control actions that were blocked by policy (for result card).
	var blockedActions: [String]
	/// Decision log entries for control selection/skip (for result card).
	var controlDecisionLog: [String]

	// MARK: - Phase 4E: World-State / Adaptation

	/// Number of consecutive control actions that caused no world-state change.
	/// When this reaches `maxIneffectiveControls`, the loop stops.
	var ineffectiveControlCount: Int
	/// Control actions that produced no measurable world-state change.
	var failedControlActions: [String]
	/// Descriptions of detected world-state transitions (for summary).
	var worldStateTransitions: [String]
	/// Entities discovered during fact extraction (goal-relevant terms).
	var discoveredEntities: [String]
	/// The snapshotID of the most recently completed observation.
	/// Used to link observations for delta tracking.
	var lastObservationSnapshotID: UUID?
	/// Text hash of the most recently completed observation.
	var lastObservationTextHash: String?

	/// After this many consecutive ineffective controls, stop the loop.
	static let maxIneffectiveControls = 2
}

// MARK: - Result

struct AgenticRuntimeResult: Sendable, Equatable {
	let status: AgenticRuntimeStatus
	let plan: AgenticTaskPlan?
	let stopReason: AgenticStopCondition?
	let phaseSummary: String
	let runtimePhase: String
	let stepsExecuted: Int
	let budgetRemaining: AgenticBudgetRemaining
	let actionId: UUID?
	/// Actions taken in order (for result card).
	let actionsExecuted: [String]
	/// Facts extracted during the loop (for result card).
	let extractedFacts: [String]
	/// Final answer produced by the loop (nil if stopped without answer).
	let finalAnswer: String?
}

struct AgenticBudgetRemaining: Sendable, Equatable {
	let steps: Int
	let llmCalls: Int
	let ocrCalls: Int
	let runtimeSeconds: Int
}

// MARK: - Phase Constraints

/// Action families allowed in Phase 4D (includes scroll and find_on_page).
private let phase4DAllowedFamilies: Set<AgenticActionFamily> = [
	.observe,
	.read_screen,
	.extract,
	.summarize,
	.present,
	.stop,
	.scroll,
	.find_on_page
]

/// Action families that require unrestricted external control (still blocked in Phase 4D).
private let externalControlFamilies: Set<AgenticActionFamily> = [
	.click,
	.type,
	.navigate,
	.switch_tab
]

// MARK: - Budget Constants

private enum BudgetValidation {
	static let maxAllowedSteps = 20
	static let maxAllowedLLMCalls = 20
	static let maxAllowedOCRCalls = 10
	static let maxAllowedRuntimeSeconds = 120
	static let minRuntimeSeconds = 1
}

// MARK: - Supported Browser Bundles

private let supportedBrowserBundles: Set<String> = AgenticControlPolicy.supportedBrowserBundles

// MARK: - Runtime

/// Bounded agentic runtime for Phase 4D: controlled observe-act loop.
///
/// Phase 4D adds two bounded controlled-interaction actions to the Phase 4C loop:
///   - scroll_small: posts a CGEvent scroll wheel event (max 2 per session)
///   - find_on_page: posts Cmd+F + deterministic query to the browser find bar (max 1 per session)
///
/// All Phase 4C actions remain: observe_once, extract_facts, summarize_observation,
/// present_answer, stop_missing_context, stop_success.
///
/// Phase 4D hard constraints:
///   - No click, type, navigate, switch_tab, submit, purchase, login, or app control
///   - scroll_small requires AX permission and browser/research workflow
///   - find_on_page requires AX permission and a supported browser
///   - Policy blocks checkout/login/banking/medical/government page contexts
///   - After any control action, next step is forced to observe_once
///   - Hard budget caps: steps ≤ 5, LLM ≤ 5, OCR ≤ 2, scrolls ≤ 2, finds ≤ 1, time ≤ 15s
actor AgenticRuntime {

	// MARK: - Public API

	/// Execute the agentic loop (Phase 4D when snapshot present; Phase 4B shell otherwise).
	func execute(
		plan: AgenticTaskPlan?,
		action: GeneratedExecutionAction?,
		snapshot: CanonicalGeneratedExecutionContextSnapshot? = nil,
		referenceTime: Date = Date(),
		dryRun: Bool = false
	) async -> AgenticRuntimeResult {
		let startedAt = referenceTime
		let actionId = action?.id

		print("[AgenticRuntime] execute_start action_id=\(actionId?.uuidString.prefix(8) ?? "nil") plan_id=\(plan?.id.prefix(8) ?? "nil") has_snapshot=\(snapshot != nil ? "yes" : "no") dry_run=\(dryRun)")

		guard let plan else {
			print("[AgenticRuntime] rejected reason=missing_plan")
			return AgenticRuntimeResult(
				status: .rejected_missing_plan,
				plan: nil,
				stopReason: nil,
				phaseSummary: "No AgenticTaskPlan was provided. Cannot route to agentic execution.",
				runtimePhase: "4B-shell",
				stepsExecuted: 0,
				budgetRemaining: AgenticBudgetRemaining(steps: 0, llmCalls: 0, ocrCalls: 0, runtimeSeconds: 0),
				actionId: actionId,
				actionsExecuted: [],
				extractedFacts: [],
				finalAnswer: nil
			)
		}

		if let budgetError = validateBudget(plan) {
			print("[AgenticRuntime] rejected reason=budget_invalid detail=\(budgetError)")
			return AgenticRuntimeResult(
				status: .rejected_budget_invalid,
				plan: plan,
				stopReason: nil,
				phaseSummary: "Budget limits are misconfigured: \(budgetError). Cannot safely execute.",
				runtimePhase: "4B-shell",
				stepsExecuted: 0,
				budgetRemaining: AgenticBudgetRemaining(
					steps: plan.maxSteps,
					llmCalls: plan.maxLLMCalls,
					ocrCalls: plan.maxOCRCalls,
					runtimeSeconds: plan.maxRuntimeSeconds
				),
				actionId: actionId,
				actionsExecuted: [],
				extractedFacts: [],
				finalAnswer: nil
			)
		}

		let blockedFamilies = plan.allowedActionFamilies.filter { externalControlFamilies.contains($0) }
		if !blockedFamilies.isEmpty && plan.safetyLevel != .preview_only {
			print("[AgenticRuntime] rejected reason=phase_constraint blocked_families=\(blockedFamilies.map(\.rawValue))")
			return AgenticRuntimeResult(
				status: .rejected_phase_constraint,
				plan: plan,
				stopReason: .unsafe_action_required,
				phaseSummary: "Phase 4D blocks unrestricted external control families: \(blockedFamilies.map(\.rawValue).joined(separator: ", ")).",
				runtimePhase: "4B-shell",
				stepsExecuted: 0,
				budgetRemaining: AgenticBudgetRemaining(
					steps: plan.maxSteps,
					llmCalls: plan.maxLLMCalls,
					ocrCalls: plan.maxOCRCalls,
					runtimeSeconds: plan.maxRuntimeSeconds
				),
				actionId: actionId,
				actionsExecuted: [],
				extractedFacts: [],
				finalAnswer: nil
			)
		}

		if let snapshot {
			return await runLoop(plan: plan, snapshot: snapshot, actionId: actionId, startedAt: startedAt, dryRun: dryRun)
		} else {
			return buildPreviewResult(plan: plan, action: action, actionId: actionId, startedAt: startedAt)
		}
	}

	// MARK: - Phase 4D Loop

	private func runLoop(
		plan: AgenticTaskPlan,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		actionId: UUID?,
		startedAt: Date,
		dryRun: Bool
	) async -> AgenticRuntimeResult {
		var session = AgenticSessionState(
			planId: plan.id,
			goal: plan.goal,
			workflow: plan.workflow,
			stepIndex: 0,
			maxSteps: plan.maxSteps,
			llmCallsUsed: 0,
			ocrCallsUsed: 0,
			scrollsUsed: 0,
			findsUsed: 0,
			maxScrolls: AgenticControlPolicy.maxScrollsDefault,
			maxFinds: AgenticControlPolicy.maxFindsDefault,
			startedAt: startedAt,
			observations: [],
			extractedFacts: [],
			finalAnswer: nil,
			stopReason: nil,
			actionsExecuted: [],
			forceObserveNext: false,
			lastActionWasControl: false,
			blockedActions: [],
			controlDecisionLog: [],
			ineffectiveControlCount: 0,
			failedControlActions: [],
			worldStateTransitions: [],
			discoveredEntities: [],
			lastObservationSnapshotID: nil,
			lastObservationTextHash: nil
		)

		// Phase 4E: debug visible mode and perception coordinator
		let debugVisible = ProcessInfo.processInfo.environment["DEBUG_AGENTIC_VISIBLE_CONTROL"] == "1"
		if debugVisible {
			print("[AgenticControlDebug] visible_mode=yes larger_scrolls=yes slower_typing=yes")
		}
		let coordinator = AgenticPerceptionRefreshCoordinator()
		// Working snapshot — replaced after each successful perception refresh
		var currentSnapshot = snapshot

		let observer = AgenticObserver()
		let decider = AgenticDecider()
		let policy = AgenticControlPolicy()

		print("[AgenticLoop] started goal=\(plan.goal.prefix(60)) workflow=\(plan.workflow) maxSteps=\(plan.maxSteps) maxScrolls=\(session.maxScrolls) maxFinds=\(session.maxFinds) dry_run=\(dryRun)")

		for step in 1...plan.maxSteps {
			session.stepIndex = step

			let elapsed = Date().timeIntervalSince(startedAt)
			if elapsed >= Double(plan.maxRuntimeSeconds) {
				session.stopReason = .max_steps_reached
				print("[AgenticLoop] budget_exceeded reason=time step=\(step) elapsed=\(formatElapsed(elapsed))")
				if session.finalAnswer == nil { session.finalAnswer = buildFallbackAnswer(session: session) }
				break
			}

			print("[AgenticLoop] step=\(step)/\(plan.maxSteps) llm=\(session.llmCallsUsed)/\(plan.maxLLMCalls) ocr=\(session.ocrCallsUsed)/\(plan.maxOCRCalls) scrolls=\(session.scrollsUsed)/\(session.maxScrolls) finds=\(session.findsUsed)/\(session.maxFinds) elapsed=\(formatElapsed(elapsed)) snapshot_fresh=\(currentSnapshot.freshnessScore >= 0.85 ? "yes" : "no")")

			// Build legal menu using currentSnapshot (may be refreshed after prior control)
			let legalActions = buildLegalMenu(
				session: session,
				snapshot: currentSnapshot,
				plan: plan,
				policy: policy,
				dryRun: dryRun
			)
			print("[AgenticActionMenu] actions=[\(legalActions.map(\.rawValue).sorted().joined(separator: ","))]")

			let decision = await decider.decide(
				goal: plan.goal,
				workflow: plan.workflow,
				observations: session.observations,
				extractedFacts: session.extractedFacts,
				stepIndex: step,
				maxSteps: plan.maxSteps,
				llmCallsUsed: session.llmCallsUsed,
				llmCallsBudget: plan.maxLLMCalls,
				ocrCallsUsed: session.ocrCallsUsed,
				ocrCallsBudget: plan.maxOCRCalls,
				legalActions: legalActions,
				forceObserveNext: session.forceObserveNext
			)
			print("[AgenticDecide] menu=[\(legalActions.map(\.rawValue).sorted().joined(separator: ","))] next_action=\(decision.nextAction.rawValue) reason=\(decision.reason.prefix(60)) policy_verified=yes")

			if decision.source == .model { session.llmCallsUsed += 1 }

			// Reset forceObserveNext; will be set again if another control action fires
			session.forceObserveNext = false

			// Execute action (async — may include sleep for control actions)
			let (actionResult, updatedSession) = await executeAction(
				decision.nextAction,
				findQuery: decision.findQuery,
				session: session,
				snapshot: currentSnapshot,
				observer: observer,
				plan: plan,
				step: step,
				debugVisible: debugVisible,
				dryRun: dryRun
			)
			session = updatedSession
			session.actionsExecuted.append(decision.nextAction.rawValue)

			// Track observation identity for delta detection
			if decision.nextAction == .observe_once, let lastObs = session.observations.last {
				let prevQuality = session.observations.dropLast().last?.quality
				let newQuality = lastObs.quality
				if let prev = prevQuality, newQuality > prev {
					print("[ObservationQuality] transition \(prev.rawValue)→\(newQuality.rawValue) step=\(step)")
				}
				session.lastObservationSnapshotID = lastObs.snapshotID
				session.lastObservationTextHash = lastObs.textHash
			}

			let controlTag = decision.nextAction.isControlledInteraction ? " [CONTROL]" : ""
			print("[AgenticLoop] step=\(step) action=\(decision.nextAction.rawValue)\(controlTag) result=\(actionResult.prefix(80))")

			// MARK: Phase 4E — Post-control perception refresh
			if decision.nextAction.isControlledInteraction {
				print("[AgenticLoop] control_action=\(decision.nextAction.rawValue) forcing_observe_after_control=yes launching_perception_refresh=yes")
				let previousOCRChars = currentSnapshot.recentOCRExcerpt?.count ?? 0

				let refreshResult = await coordinator.refresh(
					after: decision.nextAction,
					previousSnapshot: currentSnapshot,
					previousSnapshotID: session.lastObservationSnapshotID,
					ocrBudgetRemaining: session.ocrCallsUsed < plan.maxOCRCalls,
					debugVisible: debugVisible,
					dryRun: dryRun
				)

				// World-state delta and action verification
				let newOCRChars = refreshResult.freshOCR?.count ?? previousOCRChars
				let (textChanged, ocrGrew, deltaReason) = AgenticPerceptionRefreshCoordinator.detectDelta(
					previousHash: session.lastObservationTextHash,
					newHash: refreshResult.textHash,
					previousOCRChars: previousOCRChars,
					newOCRChars: newOCRChars,
					action: decision.nextAction.rawValue
				)
				let actionSucceeded = refreshResult.success && (textChanged || ocrGrew)
				print("[ActionVerification] action=\(decision.nextAction.rawValue) success=\(actionSucceeded) reason=\(deltaReason)")

				if actionSucceeded {
					// World state changed — reset ineffective count, record transition
					session.ineffectiveControlCount = 0
					let transition = "step=\(step) action=\(decision.nextAction.rawValue) \(deltaReason)"
					session.worldStateTransitions.append(transition)
				} else {
					session.ineffectiveControlCount += 1
					session.failedControlActions.append(decision.nextAction.rawValue)
					print("[AgenticControlAdaptation] ineffective_count=\(session.ineffectiveControlCount)/\(AgenticSessionState.maxIneffectiveControls) action=\(decision.nextAction.rawValue)")

					if session.ineffectiveControlCount >= AgenticSessionState.maxIneffectiveControls {
						print("[AgenticControlAdaptation] stopping reason=max_ineffective_controls_reached detail=control_actions_executed_but_no_environmental_change_detected")
						session.finalAnswer = "Control actions executed but no meaningful environmental change was detected. The page content did not update after \(session.failedControlActions.count) attempt(s)."
						session.stopReason = .max_steps_reached
						break
					}
				}

				// Replace stale snapshot with fresh one
				currentSnapshot = refreshResult.freshSnapshot
			}

			if decision.nextAction.isTerminal {
				if decision.nextAction == .present_answer || decision.nextAction == .stop_success {
					session.stopReason = .success_criteria_met
				} else {
					session.stopReason = .max_steps_reached
				}
				break
			}
		}

		if session.stopReason == nil {
			session.stopReason = .max_steps_reached
			if session.finalAnswer == nil { session.finalAnswer = buildFallbackAnswer(session: session) }
		}

		let elapsed = Date().timeIntervalSince(startedAt)
		let remaining = AgenticBudgetRemaining(
			steps: plan.maxSteps - session.stepIndex,
			llmCalls: plan.maxLLMCalls - session.llmCallsUsed,
			ocrCalls: plan.maxOCRCalls - session.ocrCallsUsed,
			runtimeSeconds: max(0, plan.maxRuntimeSeconds - Int(elapsed))
		)

		let summary = buildLoopSummary(session: session, plan: plan, elapsed: elapsed)
		let controlActionsUsed = session.actionsExecuted.filter {
			$0 == AgenticNextAction.scroll_small.rawValue || $0 == AgenticNextAction.find_on_page.rawValue
		}
		print("[AgenticLoop] completed steps=\(session.stepIndex) actions=\(session.actionsExecuted.joined(separator: "→")) control_used=[\(controlActionsUsed.joined(separator: ","))] stop=\(session.stopReason?.rawValue ?? "none") elapsed=\(formatElapsed(elapsed))")

		return AgenticRuntimeResult(
			status: .controlled_success,
			plan: plan,
			stopReason: session.stopReason,
			phaseSummary: summary,
			runtimePhase: "4D-controlled-loop",
			stepsExecuted: session.stepIndex,
			budgetRemaining: remaining,
			actionId: actionId,
			actionsExecuted: session.actionsExecuted,
			extractedFacts: session.extractedFacts,
			finalAnswer: session.finalAnswer
		)
	}

	// MARK: - Legal Menu Builder

	/// Builds the set of legal actions available for this step, filtered by policy.
	private func buildLegalMenu(
		session: AgenticSessionState,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		plan: AgenticTaskPlan,
		policy: AgenticControlPolicy,
		dryRun: Bool
	) -> Set<AgenticNextAction> {
		// Always-available actions
		var menu: Set<AgenticNextAction> = [
			.observe_once, .extract_facts, .summarize_observation,
			.present_answer, .stop_missing_context, .stop_success
		]

		// scroll_small: check policy
		let scrollCtx = AgenticControlPolicyContext(
			action: .scroll_small,
			bundleIdentifier: snapshot.bundleIdentifier,
			windowTitle: snapshot.windowTitle,
			activeApp: snapshot.activeApp,
			workflow: plan.workflow,
			stepIndex: session.stepIndex,
			priorActions: session.actionsExecuted,
			scrollsUsed: session.scrollsUsed,
			findsUsed: session.findsUsed,
			maxScrolls: session.maxScrolls,
			maxFinds: session.maxFinds,
			dryRun: dryRun
		)
		let scrollResult = policy.evaluate(scrollCtx)
		if scrollResult.allowed {
			menu.insert(.scroll_small)
		}

		// find_on_page: check policy
		let findCtx = AgenticControlPolicyContext(
			action: .find_on_page,
			bundleIdentifier: snapshot.bundleIdentifier,
			windowTitle: snapshot.windowTitle,
			activeApp: snapshot.activeApp,
			workflow: plan.workflow,
			stepIndex: session.stepIndex,
			priorActions: session.actionsExecuted,
			scrollsUsed: session.scrollsUsed,
			findsUsed: session.findsUsed,
			maxScrolls: session.maxScrolls,
			maxFinds: session.maxFinds,
			dryRun: dryRun
		)
		let findResult = policy.evaluate(findCtx)
		if findResult.allowed {
			menu.insert(.find_on_page)
		}

		return menu
	}

	// MARK: - Action Executor

	/// Execute one Phase 4D/4E action, returning the updated session and a result description.
	/// Returns a tuple to avoid inout-async exclusivity issues.
	private func executeAction(
		_ action: AgenticNextAction,
		findQuery: String?,
		session: AgenticSessionState,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		observer: AgenticObserver,
		plan: AgenticTaskPlan,
		step: Int,
		debugVisible: Bool = false,
		dryRun: Bool
	) async -> (result: String, session: AgenticSessionState) {
		var s = session

		switch action {

		case .observe_once:
			print("[AgenticAct] action=observe_once step=\(step) post_control=\(s.lastActionWasControl)")
			if s.lastActionWasControl {
				print("[AgenticLoop] stale_snapshot_reuse_blocked=yes reason=fresh_capture_not_available_post_control snapshot_unchanged=yes")
			}
			let obs = observer.observe(
				stepIndex: step,
				snapshot: snapshot,
				ocrCallsUsed: s.ocrCallsUsed,
				ocrCallsBudget: plan.maxOCRCalls,
				isPostControl: s.lastActionWasControl,
				goal: plan.goal,
				previousSnapshotID: s.lastObservationSnapshotID
			)
			if obs.ocrExcerpt != nil { s.ocrCallsUsed += 1 }
			s.observations.append(obs)
			s.lastActionWasControl = false  // reset after the forced post-control observe
			let r = "observed app=\(obs.activeApp) window=\(obs.windowTitle.prefix(40)) quality=\(obs.quality.rawValue) chars=\(obs.contentLength) has_usable=\(obs.hasUsableContent)"
			print("[AgenticAct] result=\(r)")
			return (r, s)

		case .extract_facts:
			print("[AgenticAct] action=extract_facts step=\(step) from=\(s.observations.count) observation(s)")
			let newFacts = extractFacts(from: s.observations, goal: plan.goal)
			s.extractedFacts.append(contentsOf: newFacts)
			let r = "extracted \(newFacts.count) fact(s) total=\(s.extractedFacts.count)"
			print("[AgenticAct] result=\(r)")
			return (r, s)

		case .summarize_observation:
			print("[AgenticAct] action=summarize_observation step=\(step) facts=\(s.extractedFacts.count)")
			let summary = buildSummary(observations: s.observations, facts: s.extractedFacts, goal: plan.goal)
			s.extractedFacts.append("Summary: \(String(summary.prefix(200)))")
			s.finalAnswer = summary
			let r = "summarized chars=\(summary.count)"
			print("[AgenticAct] result=\(r)")
			return (r, s)

		case .present_answer:
			print("[AgenticAct] action=present_answer step=\(step) facts=\(s.extractedFacts.count)")
			let answer = buildAnswer(observations: s.observations, facts: s.extractedFacts, goal: plan.goal)
			s.finalAnswer = answer
			let r = "answer_chars=\(answer.count) preview=\(answer.prefix(60))"
			print("[AgenticAct] produced=\(r)")
			return (r, s)

		case .stop_missing_context:
			print("[AgenticAct] action=stop_missing_context step=\(step)")
			s.finalAnswer = "Insufficient context to complete goal: \(plan.goal.prefix(80)). No usable text or relevant content was visible."
			print("[AgenticAct] produced=stop_missing_context")
			return ("stop_missing_context", s)

		case .stop_success:
			print("[AgenticAct] action=stop_success step=\(step)")
			if s.finalAnswer == nil {
				s.finalAnswer = buildAnswer(observations: s.observations, facts: s.extractedFacts, goal: plan.goal)
			}
			let r = "stop_success answer_chars=\(s.finalAnswer?.count ?? 0)"
			print("[AgenticAct] produced=\(r)")
			return (r, s)

		case .scroll_small:
			print("[AgenticControl] action=scroll_small started step=\(step) dry_run=\(dryRun) debug_visible=\(debugVisible)")
			let scrollResult = await executeScrollSmall(debugVisible: debugVisible, dryRun: dryRun)
			s.scrollsUsed += 1
			s.forceObserveNext = true
			s.lastActionWasControl = true
			let r = "scroll_small \(scrollResult) scrolls_used=\(s.scrollsUsed)/\(s.maxScrolls)"
			print("[AgenticControl] action=scroll_small completed result=\(scrollResult)")
			return (r, s)

		case .find_on_page:
			let query = findQuery ?? AgenticControlPolicy.determineFindQuery(goal: plan.goal)
			print("[AgenticControl] action=find_on_page query=\(query) started step=\(step) dry_run=\(dryRun) debug_visible=\(debugVisible)")
			let findResult = await executeFindOnPage(query: query, debugVisible: debugVisible, dryRun: dryRun)
			s.findsUsed += 1
			s.forceObserveNext = true
			s.lastActionWasControl = true
			let r = "find_on_page query=\(query) \(findResult) finds_used=\(s.findsUsed)/\(s.maxFinds)"
			print("[AgenticControl] action=find_on_page completed result=\(findResult)")
			return (r, s)
		}
	}

	// MARK: - Control Executors

	/// Scroll the currently focused window down by a small bounded amount.
	///
	/// Phase 4D implementation: posts a CGEvent scroll wheel event.
	/// Requires AX trusted process. Falls back gracefully if not trusted.
	/// In dry_run mode, logs the action without posting any events.
	private func executeScrollSmall(debugVisible: Bool = false, dryRun: Bool) async -> String {
		guard AXIsProcessTrusted() else {
			print("[AgenticControl] action=scroll_small skipped reason=ax_not_trusted")
			return "skipped_ax_not_trusted"
		}

		// Debug visible mode: larger scrolls, longer pauses, human-visible dogfooding
		let scrollLines: Int32 = debugVisible ? -14 : -3
		let settleNs: UInt64 = debugVisible ? 800_000_000 : 300_000_000

		if dryRun {
			print("[AgenticControl] action=scroll_small dry_run=yes would_scroll=\(abs(scrollLines))_lines_down debug_visible=\(debugVisible)")
			return "dry_run_simulated"
		}

		let source = CGEventSource(stateID: .hidSystemState)
		guard let scrollEvent = CGEvent(
			scrollWheelEvent2Source: source,
			units: .line,
			wheelCount: 1,
			wheel1: scrollLines,
			wheel2: 0,
			wheel3: 0
		) else {
			print("[AgenticControl] action=scroll_small failed reason=event_creation_failed")
			return "failed_event_creation"
		}

		scrollEvent.post(tap: .cghidEventTap)
		try? await Task.sleep(nanoseconds: settleNs)

		print("[AgenticControl] action=scroll_small posted lines=\(scrollLines) tap=cghid debug_visible=\(debugVisible)")
		return "scrolled_\(abs(scrollLines))_lines_down"
	}

	/// Open the browser find bar (Cmd+F) and type a deterministic query.
	///
	/// Phase 4D implementation:
	///   1. Post Cmd+F key event to open find bar
	///   2. Wait 0.3s for find bar to appear
	///   3. Type the query using CGEvent Unicode key events (one char at a time)
	///   4. Leave find bar open for the next observe step to capture
	///
	/// Requires AX trusted process and a supported browser in focus.
	/// In dry_run mode, logs without posting events.
	/// Query is always deterministic (from goal), never arbitrary user input.
	private func executeFindOnPage(query: String, debugVisible: Bool = false, dryRun: Bool) async -> String {
		guard AXIsProcessTrusted() else {
			print("[AgenticControl] action=find_on_page skipped reason=ax_not_trusted query=\(query)")
			return "skipped_ax_not_trusted"
		}

		// Debug visible mode: slower typing, longer pauses for human-visible dogfooding
		let findBarWaitNs: UInt64 = debugVisible ? 700_000_000 : 350_000_000
		let charDelayNs:  UInt64 = debugVisible ? 100_000_000 : 30_000_000

		if dryRun {
			print("[AgenticControl] action=find_on_page dry_run=yes would_type_query=\(query) via_cmd_f debug_visible=\(debugVisible)")
			return "dry_run_simulated query=\(query)"
		}

		let source = CGEventSource(stateID: .hidSystemState)

		// Step 1: Post Cmd+F (virtual key 0x03 = 'f')
		guard let cmdFDown = CGEvent(keyboardEventSource: source, virtualKey: 0x03, keyDown: true),
			  let cmdFUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x03, keyDown: false)
		else {
			print("[AgenticControl] action=find_on_page failed reason=cmd_f_event_creation_failed")
			return "failed_cmd_f_event"
		}
		cmdFDown.flags = .maskCommand
		cmdFDown.post(tap: .cghidEventTap)
		cmdFUp.flags = .maskCommand
		cmdFUp.post(tap: .cghidEventTap)

		// Step 2: Wait for the find bar to open
		try? await Task.sleep(nanoseconds: findBarWaitNs)

		// Step 3: Type query character by character via Unicode key events
		let safeQuery = String(query.prefix(20).filter { $0.isLetter || $0 == " " })
		for char in safeQuery {
			var uniChar = UniChar(char.unicodeScalars.first!.value)
			guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
				  let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
			else { continue }
			keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uniChar)
			keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uniChar)
			keyDown.post(tap: .cghidEventTap)
			keyUp.post(tap: .cghidEventTap)
			try? await Task.sleep(nanoseconds: charDelayNs)
		}

		print("[AgenticControl] action=find_on_page posted cmd_f + typed query=\(safeQuery) chars=\(safeQuery.count) debug_visible=\(debugVisible)")
		return "find_bar_opened query=\(safeQuery)"
	}

	// MARK: - Content Extractors

	private func extractFacts(from observations: [AgenticObservation], goal: String) -> [String] {
		var facts: [String] = []
		for obs in observations {
			// Only extract real page content — selectedText and ocrExcerpt.
			// contextSummary is pipeline-generated metadata, not direct page evidence.
			if let text = obs.selectedText, !text.isEmpty {
				facts.append("Selected text: \(text.prefix(200))")
			}
			if let ocr = obs.ocrExcerpt, !ocr.isEmpty {
				facts.append("Screen content: \(ocr.prefix(200))")
			}
			// Window context is factual (where the user is)
			if !obs.windowTitle.isEmpty {
				facts.append("Active: \(obs.activeApp) — \(obs.windowTitle.prefix(80))")
			}
		}
		if facts.isEmpty {
			facts.append("No actionable page content found in current context.")
		}
		return facts
	}

	private func buildSummary(observations: [AgenticObservation], facts: [String], goal: String) -> String {
		var parts: [String] = ["Goal: \(goal)"]
		if !facts.isEmpty {
			let factPreview = facts.prefix(3).joined(separator: "\n• ")
			parts.append("Findings:\n• \(factPreview)")
		}
		if let latest = observations.last {
			parts.append("Context: \(latest.activeApp) — \(latest.windowTitle)")
		}
		return parts.joined(separator: "\n\n")
	}

	private func buildAnswer(observations: [AgenticObservation], facts: [String], goal: String) -> String {
		if facts.isEmpty {
			return "No relevant information found for: \(goal)"
		}
		return facts.prefix(5).joined(separator: "\n")
	}

	private func buildFallbackAnswer(session: AgenticSessionState) -> String {
		if !session.extractedFacts.isEmpty {
			return session.extractedFacts.prefix(3).joined(separator: "\n")
		}
		if let obs = session.observations.last {
			// Prefer real page content; fall back to contextSummary as last resort
			if let text = obs.selectedText { return "Partial: \(text.prefix(300))" }
			if let ocr = obs.ocrExcerpt { return "Partial: \(ocr.prefix(300))" }
			if let summary = obs.contextSummary { return "Context only: \(summary.prefix(200))" }
			return "Partial observation: \(obs.activeApp) — \(obs.windowTitle)"
		}
		return "Goal could not be completed within the step budget."
	}

	// MARK: - Timing

	/// Format elapsed time so it is never misleadingly displayed as "0.00s".
	/// Uses ms suffix for sub-second durations; seconds with 2dp otherwise.
	private func formatElapsed(_ s: TimeInterval) -> String {
		if s < 0.001 { return "<1ms" }
		if s < 1.0 { return "\(Int(s * 1000))ms" }
		return String(format: "%.2fs", s)
	}

	// MARK: - Summary Builder

	private func buildLoopSummary(session: AgenticSessionState, plan: AgenticTaskPlan, elapsed: Double) -> String {
		let controlActions = session.actionsExecuted.filter {
			$0 == "scroll_small" || $0 == "find_on_page"
		}
		var lines: [String] = []
		lines.append("Goal: \(session.goal)")
		lines.append("Workflow: \(session.workflow)")
		lines.append("Steps: \(session.stepIndex)/\(session.maxSteps)")
		lines.append("Actions: \(session.actionsExecuted.joined(separator: " → "))")
		if !controlActions.isEmpty {
			lines.append("Control actions used: \(controlActions.joined(separator: ", "))")
		}
		if !session.blockedActions.isEmpty {
			lines.append("Blocked by policy: \(session.blockedActions.joined(separator: ", "))")
		}
		if !session.worldStateTransitions.isEmpty {
			lines.append("World-state changes: \(session.worldStateTransitions.count)")
		}
		if session.ineffectiveControlCount > 0 {
			lines.append("Ineffective controls: \(session.failedControlActions.joined(separator: ", "))")
		}
		if !session.extractedFacts.isEmpty {
			lines.append("Facts extracted: \(session.extractedFacts.count)")
		}
		if let answer = session.finalAnswer {
			lines.append("")
			lines.append("Answer:\n\(answer)")
		}
		lines.append("")
		lines.append("Completed in \(formatElapsed(elapsed)) | Stop: \(session.stopReason?.rawValue ?? "step_limit")")
		return lines.joined(separator: "\n")
	}

	// MARK: - Phase 4B Shell (fallback when no snapshot)

	private func buildPreviewResult(
		plan: AgenticTaskPlan,
		action: GeneratedExecutionAction?,
		actionId: UUID?,
		startedAt: Date
	) -> AgenticRuntimeResult {
		let elapsed = Date().timeIntervalSince(startedAt)
		let allowedFamilyList = plan.allowedActionFamilies
			.filter { phase4DAllowedFamilies.contains($0) }
			.map(\.rawValue)
			.joined(separator: ", ")
		var lines: [String] = [
			"Agentic plan validated — context snapshot unavailable.",
			"",
			"Goal: \(plan.goal)",
			"Workflow: \(plan.workflow)"
		]
		if !allowedFamilyList.isEmpty { lines.append("Allowed families: \(allowedFamilyList)") }
		lines.append("Limits: \(plan.maxSteps) steps, \(plan.maxLLMCalls) LLM, \(plan.maxOCRCalls) OCR, \(plan.maxRuntimeSeconds)s")
		lines.append("")
		lines.append("Phase 4D: observe → find/scroll → observe → extract → summarize → present.")
		print("[AgenticRuntime] preview_ready plan_id=\(plan.id.prefix(8)) elapsed=\(formatElapsed(elapsed))")
		return AgenticRuntimeResult(
			status: .preview_ready,
			plan: plan,
			stopReason: nil,
			phaseSummary: lines.joined(separator: "\n"),
			runtimePhase: "4B-shell",
			stepsExecuted: 0,
			budgetRemaining: AgenticBudgetRemaining(
				steps: plan.maxSteps, llmCalls: plan.maxLLMCalls,
				ocrCalls: plan.maxOCRCalls, runtimeSeconds: plan.maxRuntimeSeconds
			),
			actionId: actionId, actionsExecuted: [], extractedFacts: [], finalAnswer: nil
		)
	}

	// MARK: - Budget Validation

	private func validateBudget(_ plan: AgenticTaskPlan) -> String? {
		if plan.maxSteps < 1 || plan.maxSteps > BudgetValidation.maxAllowedSteps {
			return "maxSteps=\(plan.maxSteps) out of range [1, \(BudgetValidation.maxAllowedSteps)]"
		}
		if plan.maxLLMCalls < 0 || plan.maxLLMCalls > BudgetValidation.maxAllowedLLMCalls {
			return "maxLLMCalls=\(plan.maxLLMCalls) out of range [0, \(BudgetValidation.maxAllowedLLMCalls)]"
		}
		if plan.maxOCRCalls < 0 || plan.maxOCRCalls > BudgetValidation.maxAllowedOCRCalls {
			return "maxOCRCalls=\(plan.maxOCRCalls) out of range [0, \(BudgetValidation.maxAllowedOCRCalls)]"
		}
		if plan.maxRuntimeSeconds < BudgetValidation.minRuntimeSeconds || plan.maxRuntimeSeconds > BudgetValidation.maxAllowedRuntimeSeconds {
			return "maxRuntimeSeconds=\(plan.maxRuntimeSeconds) out of range [\(BudgetValidation.minRuntimeSeconds), \(BudgetValidation.maxAllowedRuntimeSeconds)]"
		}
		return nil
	}
}

// MARK: - Result → ExecutionResult Bridge

extension AgenticRuntimeResult {

	func toExecutionResult(actionId: UUID, confidence: Double, startedAt: Date) -> ExecutionResult {
		let execStatus: ExecutionResultStatus
		switch self.status {
		case .preview_ready, .controlled_success:
			execStatus = .success
		case .blocked_unsafe_action, .rejected_phase_constraint:
			execStatus = .partialSuccess
		case .rejected_missing_plan, .rejected_budget_invalid:
			execStatus = .failed
		}

		var sections: [ExecutionResultSection] = []
		sections.append(ExecutionResultSection(
			title: "Runtime Phase",
			body: "\(runtimePhase) — \(self.status.rawValue)",
			order: 0
		))

		if runtimePhase.hasSuffix("-loop") {
			// Phase 4C/4D loop sections
			let controlActions = actionsExecuted.filter { $0 == "scroll_small" || $0 == "find_on_page" }
			if !actionsExecuted.isEmpty {
				sections.append(ExecutionResultSection(
					title: "Actions Taken",
					body: actionsExecuted.joined(separator: " → "),
					order: 1
				))
			}
			if !controlActions.isEmpty {
				sections.append(ExecutionResultSection(
					title: "Controlled Interactions",
					body: "Used: \(controlActions.joined(separator: ", "))",
					order: 2
				))
			} else {
				// Control was not used — note why
				let noControlReason = "Page content was sufficient (quality usable/rich) — no controlled interactions needed"
				sections.append(ExecutionResultSection(
					title: "Controlled Interactions",
					body: "None used — \(noControlReason)",
					order: 2
				))
			}
			if !extractedFacts.isEmpty {
				let factsBody = extractedFacts.prefix(5)
					.enumerated()
					.map { "\($0.offset + 1). \($0.element)" }
					.joined(separator: "\n")
				sections.append(ExecutionResultSection(
					title: "Extracted Facts",
					body: factsBody,
					order: 3
				))
			}
			if let answer = finalAnswer {
				sections.append(ExecutionResultSection(
					title: "Answer",
					body: answer,
					order: 4
				))
			}
			sections.append(ExecutionResultSection(
				title: "Summary",
				body: phaseSummary,
				order: 5
			))
		} else {
			sections.append(ExecutionResultSection(
				title: "Details",
				body: phaseSummary,
				order: 1
			))
		}

		let controlActions = actionsExecuted.filter { $0 == "scroll_small" || $0 == "find_on_page" }
		var metadata: [String: String] = [
			"runtimePhase": runtimePhase,
			"agenticStatus": self.status.rawValue,
			"stepsExecuted": "\(stepsExecuted)",
			"budgetSteps": "\(budgetRemaining.steps)",
			"budgetLLM": "\(budgetRemaining.llmCalls)",
			"budgetOCR": "\(budgetRemaining.ocrCalls)",
			"budgetSeconds": "\(budgetRemaining.runtimeSeconds)",
			"actionsCount": "\(actionsExecuted.count)",
			"factsCount": "\(extractedFacts.count)",
			"controlActionsCount": "\(controlActions.count)"
		]
		if let plan { metadata["goal"] = String(plan.goal.prefix(120)); metadata["workflow"] = plan.workflow }
		if let stop = stopReason { metadata["stopReason"] = stop.rawValue }
		if !actionsExecuted.isEmpty { metadata["actionsExecuted"] = actionsExecuted.joined(separator: ",") }
		metadata["controlActionsUsed"] = controlActions.isEmpty ? "none" : controlActions.joined(separator: ",")
		if !controlActions.isEmpty { metadata["controlActions"] = controlActions.joined(separator: ",") }
		// Phase 4E metadata
		if let plan { _ = plan }  // suppress unused warning


		let followUps: [String]
		switch self.status {
		case .controlled_success:
			if !controlActions.isEmpty {
				followUps = ["Controlled interactions: \(controlActions.joined(separator: ", "))"]
			} else {
				followUps = []
			}
		case .preview_ready:
			followUps = ["Provide a context snapshot to activate the Phase 4D loop"]
		case .blocked_unsafe_action, .rejected_phase_constraint:
			followUps = ["Only observe/extract/present/scroll/find families are allowed in Phase 4D"]
		case .rejected_missing_plan, .rejected_budget_invalid:
			followUps = ["Check proposal synthesis pipeline for plan generation"]
		}

		return ExecutionResult(
			actionId: actionId,
			status: execStatus,
			startedAt: startedAt,
			completedAt: Date(),
			generatedContent: finalAnswer ?? phaseSummary,
			generatedSections: sections,
			warnings: [],
			executionMetadata: metadata,
			confidence: confidence,
			followUpSuggestions: followUps
		)
	}
}
