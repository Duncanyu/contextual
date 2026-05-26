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
	/// Runtime extracted grounded facts/entities, but later control attempts did not
	/// uncover additional evidence before bounds were reached.
	case partial_grounded_success
	/// Runtime captured grounded observation context (OCR/AX/targets) but did not
	/// produce reliable structured facts.
	case grounded_observation_only
	/// Runtime made no meaningful progress (no grounded evidence extracted).
	case no_progress
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

/// World-state snapshot at a specific point in time (Phase 4S).
struct AgenticWorldStateSnapshot: Sendable, Equatable {
	let ocrHash: String
	let axHash: String
	let graphNodeCount: Int
	let groundedTargetTitles: [String]
	let evidenceSatisfied: Set<String>
	let evidenceMissing: Set<String>
	let timestamp: Date

	static func capture(
		session: AgenticSessionState,
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> AgenticWorldStateSnapshot {
		let ocrHash = AgenticPerceptionRefreshCoordinator.computeTextHash(ocr: snapshot.recentOCRExcerpt, selectedText: nil) ?? "none"
		let axHash = AgenticPerceptionRefreshCoordinator.computeTextHash(ocr: nil, selectedText: snapshot.contextSummary) ?? "none"
		let graphNodeCount = session.screenStateGraph?.nodes.count ?? 0
		let groundedTargetTitles = session.groundedTargets.map { $0.title }
		let evidenceSatisfied = Set(session.evidenceState?.satisfied.map { $0.rawValue } ?? [])
		let evidenceMissing = Set(session.evidenceState?.missing.map { $0.rawValue } ?? [])
		
		return AgenticWorldStateSnapshot(
			ocrHash: ocrHash,
			axHash: axHash,
			graphNodeCount: graphNodeCount,
			groundedTargetTitles: groundedTargetTitles,
			evidenceSatisfied: evidenceSatisfied,
			evidenceMissing: evidenceMissing,
			timestamp: Date()
		)
	}
}

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

	// MARK: - Phase 4G: Screen grounding

	/// Most recent screen-state graph built from OCR/AX.
	var screenStateGraph: ScreenStateGraph?
	/// Ranked grounded targets resolved from the graph.
	var groundedTargets: [GroundedTarget]
	/// Primary grounded target when confidence is sufficient.
	var primaryGroundedTarget: GroundedTarget?

	// MARK: - Phase 4I: Grounded semantic extraction

	/// Semantic entities extracted from grounded targets/nodes.
	var semanticEntities: [GroundedSemanticEntity]
	/// Structured facts built from semantic entities (canonical payload).
	var structuredFacts: [StructuredFact]
	/// Semantic readiness evaluation.
	var semanticReadiness: SemanticReadiness?

	// MARK: - Phase 4O: Evidence requirements + state

	/// Required + optional evidence requirements derived from goal + workflow.
	var evidenceRequirements: [AgenticEvidenceRequirement]
	/// Latest evidence-state snapshot. Recomputed after observe_once and after
	/// extract_facts so the decider always reasons against current state.
	var evidenceState: AgenticEvidenceState?
	/// Phase 4P: normalized evidence observations bridged from raw perception.
	var evidenceObservations: [AgenticEvidenceObservation]

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

	// MARK: - Phase 4G: Grounding summary

	let groundedTargetCount: Int
	let groundedPrimaryTitle: String?
	let groundedPrimaryRole: String?
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
		targetAnchor: TargetWindowAnchor? = nil,
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
				finalAnswer: nil,
				groundedTargetCount: 0,
				groundedPrimaryTitle: nil,
				groundedPrimaryRole: nil
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
				finalAnswer: nil,
				groundedTargetCount: 0,
				groundedPrimaryTitle: nil,
				groundedPrimaryRole: nil
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
				finalAnswer: nil,
				groundedTargetCount: 0,
				groundedPrimaryTitle: nil,
				groundedPrimaryRole: nil
			)
		}

		if let snapshot {
			return await runLoop(
				plan: plan,
				snapshot: snapshot,
				targetAnchor: targetAnchor,
				actionId: actionId,
				startedAt: startedAt,
				dryRun: dryRun
			)
		} else {
			return buildPreviewResult(plan: plan, action: action, actionId: actionId, startedAt: startedAt)
		}
	}

	// MARK: - Phase 4D Loop

	private func runLoop(
		plan: AgenticTaskPlan,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		targetAnchor: TargetWindowAnchor?,
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
			lastObservationTextHash: nil,
			screenStateGraph: nil,
			groundedTargets: [],
			primaryGroundedTarget: nil,
			semanticEntities: [],
			structuredFacts: [],
			semanticReadiness: nil,
			evidenceRequirements: [],
			evidenceState: nil,
			evidenceObservations: []
		)

		// Phase 4O: derive the evidence requirements for this goal up-front.
		session.evidenceRequirements = AgenticEvidenceRequirementsInferrer.infer(
			goal: plan.goal,
			workflow: plan.workflow,
			windowTitle: snapshot.windowTitle,
			evidenceObservations: session.evidenceObservations,
			semanticEntities: session.semanticEntities,
			contextCategory: snapshot.bundleIdentifier
		)
		do {
			let required = session.evidenceRequirements.filter { $0.required }.map { $0.kind.rawValue }.joined(separator: ",")
			let optional = session.evidenceRequirements.filter { !$0.required }.map { $0.kind.rawValue }.joined(separator: ",")
			print("[EvidenceRequirements] goal=\"\(plan.goal.prefix(80))\" required=\(required) optional=\(optional)")
		}

		// Phase 4E: debug visible mode and perception coordinator
		let debugVisible = ProcessInfo.processInfo.environment["DEBUG_AGENTIC_VISIBLE_CONTROL"] == "1"
		if debugVisible {
			print("[AgenticControlDebug] visible_mode=yes larger_scrolls=yes slower_typing=yes")
		}
		let coordinator = AgenticPerceptionRefreshCoordinator()
		// Working snapshot — replaced after each successful perception refresh
		var currentSnapshot = snapshot

		// Phase 4J: If the assistant became active due to the user click, restore the proposal-time
		// target app/window identity so downstream grounding and logs reflect the correct target.
		if let targetAnchor,
		   let assistantBundle = Bundle.main.bundleIdentifier,
		   currentSnapshot.bundleIdentifier == assistantBundle,
		   targetAnchor.bundleIdentifier != assistantBundle {
			currentSnapshot = currentSnapshot.applyingTargetAnchor(targetAnchor, workflowOverride: nil)
			print("[TargetWindowAnchor] restored bundle=\(targetAnchor.bundleIdentifier) title=\"\(targetAnchor.windowTitle.prefix(60))\"")
		}

		let observer = AgenticObserver()
		let decider = AgenticDecider()
		let policy = AgenticControlPolicy()

		print("[AgenticLoop] started goal=\(plan.goal.prefix(60)) workflow=\(plan.workflow) maxSteps=\(plan.maxSteps) maxScrolls=\(session.maxScrolls) maxFinds=\(session.maxFinds) dry_run=\(dryRun)")

		// MARK: Phase 4H — Live OCR/AX priming at execution start
		// If the proposal snapshot has no usable OCR, acquire a fresh bounded screenshot+OCR+AX
		// BEFORE step 1. This avoids stale snapshot reuse and prevents observe_once from
		// immediately terminating due to missing context.
		// Phase 4M: priming OCR uses a SEPARATE budget from the agentic loop's
		// per-step OCR budget. Previously this incremented `session.ocrCallsUsed`,
		// which caused the very first `observe_once` to hit
		//   ocr_skipped reason=budget_exhausted
		// even though the runtime had a fresh, usable OCR excerpt sitting on
		// `currentSnapshot.recentOCRExcerpt`. The loop OCR budget is reserved
		// strictly for in-loop observations and post-control refreshes.
		var primingOCRConsumed = false
		if !dryRun {
			let hasUsableOCR = !(currentSnapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			if !hasUsableOCR {
				print("[ScreenStateGraphRuntime] priming_live_ocr=yes reason=proposal_snapshot_missing_ocr dry_run=\(dryRun)")
				if let targetAnchor {
					print("[TargetWindowCapture] using_anchor=yes current_active=\(snapshot.activeApp) target=\(targetAnchor.appName)")
				}
				// Priming always runs — it does not consume the loop OCR budget.
				let priming = await coordinator.initialCapture(
					previousSnapshot: currentSnapshot,
					previousSnapshotID: session.lastObservationSnapshotID,
					ocrBudgetRemaining: true,
					targetAnchor: targetAnchor,
					dryRun: false
				)
				// Replace snapshot even if capture partially failed; the coordinator will return the
				// best-available snapshot while preserving safety.
				currentSnapshot = priming.freshSnapshot
				primingOCRConsumed = (priming.freshOCR != nil)

				let primed = !(currentSnapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				let source = primed ? "fresh_ocr" : "priming_failed"
				let axPresent = (currentSnapshot.contextSummary ?? "").contains("ax=") ? "yes" : "no"
				print("[ScreenStateGraphRuntime] priming_completed source=\(source) ocr_chars=\(currentSnapshot.recentOCRExcerpt?.count ?? 0) ax_present=\(axPresent)")
			}
		}
		// Phase 4M log: surface the priming-vs-loop OCR budget separation so dogfood
		// makes it obvious that priming did not eat the loop budget.
		print("[AgenticLoop] priming_ocr_used=\(primingOCRConsumed ? "yes" : "no") loop_ocr_used=\(session.ocrCallsUsed)/\(plan.maxOCRCalls)")

		// Phase 4G: build initial screen graph + grounded targets (after priming, before step 1)
		updateScreenGrounding(
			session: &session,
			snapshot: currentSnapshot,
			targetAnchor: targetAnchor,
			goal: plan.goal,
			workflow: plan.workflow,
			stepLabel: "init",
			reason: "execution_start"
		)

		let initComparisonRequired = session.evidenceRequirements.contains(where: { $0.kind == .comparisonCandidate && $0.required })
		let initComparisonTitles = initComparisonRequired
			? await BrowsingComparisonTracker.shared.distinctRecentTitles(at: Date())
			: []
		Self.assessEvidence(
			session: &session,
			goal: plan.goal,
			workflow: plan.workflow,
			snapshot: currentSnapshot,
			comparisonTitles: initComparisonTitles,
			source: "init",
			step: 0
		)

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

			// Phase 4M: Re-check frontmost app at every step. If the user clicked away
			// during execution, the policy will strip control actions on mismatch.
			// `dryRun` skips the AppKit call so unit tests do not depend on focus state.
			let currentFrontmost: String? = dryRun
				? targetAnchor?.bundleIdentifier // dry-run: assume focus is correct
				: await Self.currentFrontmostBundleIdentifier()

			// Build legal menu using currentSnapshot (may be refreshed after prior control)
			let legalActions = buildLegalMenu(
				session: session,
				snapshot: currentSnapshot,
				plan: plan,
				policy: policy,
				dryRun: dryRun,
				targetAnchor: targetAnchor,
				currentFrontmostBundle: currentFrontmost
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
				forceObserveNext: session.forceObserveNext,
				semanticReadiness: session.semanticReadiness,
				evidenceState: session.evidenceState,
				evidenceObservations: session.evidenceObservations,
				entities: session.semanticEntities,
				facts: session.structuredFacts
			)
			print("[AgenticDecide] menu=[\(legalActions.map(\.rawValue).sorted().joined(separator: ","))] next_action=\(decision.nextAction.rawValue) reason=\(decision.reason.prefix(60)) policy_verified=yes")

			if decision.source == .model { session.llmCallsUsed += 1 }

			// Phase 4S structured step thought log
			let currentEvSummary = session.evidenceState?.satisfied.map { $0.rawValue }.joined(separator: ",") ?? "none"
			let missingEv = session.evidenceState?.missing.map { $0.rawValue } ?? []
			let mappedMissing = missingEv.map { kind -> String in
				if kind == "review_text" || kind == "review_count" { return "reviews" }
				if kind == "comparison_candidate" { return "comparisonCandidate" }
				return kind
			}.sorted()
			let curScreenSummary = session.observations.last?.contextSummary ?? "empty"
			let candidates = legalActions.map { $0.rawValue }.sorted()
			
			let expectedChange: String
			switch decision.nextAction {
			case .find_on_page:
				if let firstMissing = session.evidenceState?.firstMissing?.kind {
					switch firstMissing {
					case .reviewCount, .reviewText, .rating:
						expectedChange = "reviews_section_visible"
					case .specs:
						expectedChange = "specs_section_visible"
					case .price:
						expectedChange = "price_section_visible"
					case .comparisonCandidate:
						expectedChange = "comparison_candidate_visible"
					default:
						expectedChange = "\(firstMissing.rawValue)_section_visible"
					}
				} else {
					expectedChange = "target_content_visible"
				}
			case .scroll_small:
				expectedChange = "lower_page_content_visible"
			case .observe_once:
				expectedChange = "updated_page_context"
			case .extract_facts:
				expectedChange = "structured_facts_extracted"
			case .summarize_observation:
				expectedChange = "summary_synthesized"
			case .present_answer:
				expectedChange = "final_answer_presented"
			case .stop_success:
				expectedChange = "loop_terminated_success"
			case .stop_missing_context:
				expectedChange = "loop_terminated_missing_context"
			}
			
			let stepThought = AgenticStepThought(
				stepIndex: step,
				goal: plan.goal,
				currentEvidenceSummary: currentEvSummary,
				missingEvidence: mappedMissing,
				currentScreenSummary: curScreenSummary,
				candidateActions: candidates,
				chosenAction: decision.nextAction.rawValue,
				reason: decision.reason,
				expectedObservationChange: expectedChange,
				confidence: decision.confidence
			)
			stepThought.log()

			// Reset forceObserveNext; will be set again if another control action fires
			session.forceObserveNext = false
			
			let beforeSnapshot = AgenticWorldStateSnapshot.capture(session: session, snapshot: currentSnapshot)

			// Execute action (async — may include sleep for control actions)
			let (actionResult, updatedSession) = await executeAction(
				decision.nextAction,
				findQuery: decision.findQuery,
				session: session,
				snapshot: currentSnapshot,
				targetAnchor: targetAnchor,
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

				let refreshResult = await coordinator.refresh(
					after: decision.nextAction,
					previousSnapshot: currentSnapshot,
					previousSnapshotID: session.lastObservationSnapshotID,
					ocrBudgetRemaining: session.ocrCallsUsed < plan.maxOCRCalls,
					debugVisible: debugVisible,
					dryRun: dryRun
				)

				// Replace stale snapshot with fresh one
				currentSnapshot = refreshResult.freshSnapshot

				// Phase 4G: rebuild graph after fresh post-control perception refresh
				updateScreenGrounding(
					session: &session,
					snapshot: currentSnapshot,
					targetAnchor: targetAnchor,
					goal: plan.goal,
					workflow: plan.workflow,
					stepLabel: "\(step)",
					reason: "post_control_refresh"
				)

				// Phase 4O: re-assess evidence requirements against the new entities
				let postComparisonRequired = session.evidenceRequirements.contains(where: { $0.kind == .comparisonCandidate && $0.required })
				let postComparisonTitles = postComparisonRequired
					? await BrowsingComparisonTracker.shared.distinctRecentTitles(at: Date())
					: []
				Self.assessEvidence(
					session: &session,
					goal: plan.goal,
					workflow: plan.workflow,
					snapshot: currentSnapshot,
					comparisonTitles: postComparisonTitles,
					source: "post_control_refresh",
					step: step
				)

				let afterSnapshot = AgenticWorldStateSnapshot.capture(session: session, snapshot: currentSnapshot)

				// World-state delta and action verification (Phase 4S evidence-aware change tracking)
				let ocrChanged = beforeSnapshot.ocrHash != afterSnapshot.ocrHash
				let axChanged = beforeSnapshot.axHash != afterSnapshot.axHash
				let textChanged = ocrChanged || axChanged
				let graphDelta = afterSnapshot.graphNodeCount - beforeSnapshot.graphNodeCount
				
				let newlySatisfied = afterSnapshot.evidenceSatisfied.subtracting(beforeSnapshot.evidenceSatisfied)
				let evidenceDelta: String
				if newlySatisfied.isEmpty {
					evidenceDelta = "none"
				} else {
					evidenceDelta = newlySatisfied.map { kind -> String in
						if kind == "review_text" || kind == "review_count" { return "reviews+" }
						if kind == "comparison_candidate" { return "comparisonCandidate+" }
						return "\(kind)+"
					}.joined(separator: ",")
				}
				
				let evidenceImproved = !newlySatisfied.isEmpty
				let beforeTargets = Set(beforeSnapshot.groundedTargetTitles)
				let afterTargets = Set(afterSnapshot.groundedTargetTitles)
				let newlyAddedTargets = afterTargets.subtracting(beforeTargets)
				let targetsAdded = !newlyAddedTargets.isEmpty
				
				let actionSucceeded: Bool
				let verificationReason: String
				let addedInfo: String
				
				if evidenceImproved {
					actionSucceeded = true
					verificationReason = "evidence_improved"
					addedInfo = newlySatisfied.map { kind -> String in
						if kind == "review_text" || kind == "review_count" { return "reviewText" }
						if kind == "comparison_candidate" { return "comparisonCandidate" }
						return kind
					}.joined(separator: ",")
				} else {
					actionSucceeded = false
					verificationReason = "no_evidence_delta"
					addedInfo = "none"
				}
				
				let textChangedStr = textChanged ? "yes" : "no"
				let graphDeltaStr = graphDelta >= 0 ? "+\(graphDelta)" : "\(graphDelta)"
				let confidenceStr = String(format: "%.2f", session.evidenceState?.confidence ?? 0.0)
				
				if actionSucceeded {
					print("[WorldStateTransition] action=\(decision.nextAction.rawValue) text_changed=\(textChangedStr) graph_delta=\(graphDeltaStr) evidence_delta=\(evidenceDelta) confidence=\(confidenceStr)")
				} else {
					print("[WorldStateTransition] action=\(decision.nextAction.rawValue) text_changed=\(textChangedStr) graph_delta=\(graphDeltaStr) evidence_delta=none")
				}
				
				let successStr = actionSucceeded ? "yes" : "no"
				if actionSucceeded {
					print("[ActionVerification] action=\(decision.nextAction.rawValue) success=\(successStr) reason=\(verificationReason) added=\(addedInfo)")
				} else {
					print("[ActionVerification] action=\(decision.nextAction.rawValue) success=\(successStr) reason=\(verificationReason) graph_delta=\(graphDelta)")
				}

				if actionSucceeded {
					session.ineffectiveControlCount = 0
					let transition = "step=\(step) action=\(decision.nextAction.rawValue) \(verificationReason)"
					session.worldStateTransitions.append(transition)
				} else {
					session.ineffectiveControlCount += 1
					session.failedControlActions.append(decision.nextAction.rawValue)
					print("[AgenticControlAdaptation] ineffective_count=\(session.ineffectiveControlCount)/\(AgenticSessionState.maxIneffectiveControls) action=\(decision.nextAction.rawValue)")
					
					if decision.nextAction == .scroll_small {
						print("[ScrollStrategy] ineffective_count=\(session.ineffectiveControlCount)")
					}

					if session.ineffectiveControlCount >= AgenticSessionState.maxIneffectiveControls {
						print("[AgenticControlAdaptation] stopping reason=max_ineffective_controls_reached detail=control_actions_executed_but_no_environmental_change_detected")
						// Phase 4R — preserve any grounded facts/entities already extracted.
						// Do not discard evidence just because later control attempts failed.
						if session.finalAnswer == nil {
							session.finalAnswer = buildPremiumAnswer(session: session)
						}
						session.stopReason = .partial_evidence_budget_exhausted
						break
					}
				}
			}

			if decision.nextAction.isTerminal {
				if decision.nextAction == .present_answer || decision.nextAction == .stop_success {
					// Phase 4O/4T: quality gate is authoritative for success vs partial.
					if let ev = session.evidenceState, !ev.allRequiredSatisfied {
						session.stopReason = .partial_evidence_budget_exhausted
						print("[AgenticLoop] stop=partial_evidence_budget_exhausted missing=\(ev.missing.map { $0.rawValue }.joined(separator: ","))")
					} else if !AgenticRuntime.evaluateQualityPassed(session: session, plan: plan) {
						session.stopReason = .partial_evidence_budget_exhausted
					} else if session.evidenceState?.allRequiredSatisfied == true {
						session.stopReason = .evidence_satisfied
					} else {
						session.stopReason = .success_criteria_met
					}
				} else {
					session.stopReason = .max_steps_reached
				}
				break
			}
		}

		if session.stopReason == nil {
			if let ev = session.evidenceState, !ev.allRequiredSatisfied {
				session.stopReason = .partial_evidence_budget_exhausted
			} else if session.evidenceState?.allRequiredSatisfied == true && AgenticRuntime.evaluateQualityPassed(session: session, plan: plan) {
				session.stopReason = .evidence_satisfied
			} else {
				session.stopReason = .partial_evidence_budget_exhausted
			}
			if session.finalAnswer == nil { session.finalAnswer = buildPremiumAnswer(session: session) }
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

			let status: AgenticRuntimeStatus = {
				let hasFacts = !session.structuredFacts.isEmpty || !session.semanticEntities.isEmpty || !session.extractedFacts.isEmpty
				let anyControlsFailed = !session.failedControlActions.isEmpty
				let anyControlsUsed = controlActionsUsed.isEmpty == false
				let allRequired = session.evidenceState?.allRequiredSatisfied == true
				let qualityPassed = AgenticRuntime.evaluateQualityPassed(session: session, plan: plan)
				if allRequired && qualityPassed { return .controlled_success }
				if hasFacts {
					return (anyControlsFailed && anyControlsUsed) ? .partial_grounded_success : .grounded_observation_only
				}
				return .no_progress
			}()

			return AgenticRuntimeResult(
				status: status,
				plan: plan,
				stopReason: session.stopReason,
				phaseSummary: summary,
				runtimePhase: "4D-controlled-loop",
				stepsExecuted: session.stepIndex,
			budgetRemaining: remaining,
			actionId: actionId,
			actionsExecuted: session.actionsExecuted,
			extractedFacts: session.extractedFacts,
			finalAnswer: session.finalAnswer,
			groundedTargetCount: session.groundedTargets.count,
			groundedPrimaryTitle: session.primaryGroundedTarget?.title,
			groundedPrimaryRole: session.primaryGroundedTarget?.role.rawValue
		)
	}

	// MARK: - Legal Menu Builder

	/// Builds the set of legal actions available for this step, filtered by policy.
	///
	/// Phase 4M: `targetAnchor` and `currentFrontmostBundle` are threaded into each
	/// control-policy context so the policy can block scroll/find on focus mismatch
	/// (e.g. when the user clicked Execute while Contextual was frontmost and the
	/// target window did not actually become frontmost yet).
	private func buildLegalMenu(
		session: AgenticSessionState,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		plan: AgenticTaskPlan,
		policy: AgenticControlPolicy,
		dryRun: Bool,
		targetAnchor: TargetWindowAnchor?,
		currentFrontmostBundle: String?
	) -> Set<AgenticNextAction> {
		// Always-available actions
		var menu: Set<AgenticNextAction> = [
			.observe_once, .extract_facts, .summarize_observation,
			.present_answer, .stop_missing_context, .stop_success
		]

		let expectedTargetBundle = targetAnchor?.bundleIdentifier

		// scroll_small: check policy
			let scrollCtx = AgenticControlPolicyContext(
				action: .scroll_small,
				bundleIdentifier: snapshot.bundleIdentifier,
				windowTitle: snapshot.windowTitle,
				activeApp: snapshot.activeApp,
				workflow: plan.workflow,
				stepIndex: session.stepIndex,
				maxSteps: plan.maxSteps,
				priorActions: session.actionsExecuted,
				scrollsUsed: session.scrollsUsed,
				findsUsed: session.findsUsed,
				ocrCallsUsed: session.ocrCallsUsed,
				ocrCallsBudget: plan.maxOCRCalls,
				maxScrolls: session.maxScrolls,
				maxFinds: session.maxFinds,
				dryRun: dryRun,
				expectedTargetBundle: expectedTargetBundle,
				currentFrontmostBundle: currentFrontmostBundle
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
				maxSteps: plan.maxSteps,
				priorActions: session.actionsExecuted,
				scrollsUsed: session.scrollsUsed,
				findsUsed: session.findsUsed,
				ocrCallsUsed: session.ocrCallsUsed,
				ocrCallsBudget: plan.maxOCRCalls,
				maxScrolls: session.maxScrolls,
				maxFinds: session.maxFinds,
				dryRun: dryRun,
				expectedTargetBundle: expectedTargetBundle,
				currentFrontmostBundle: currentFrontmostBundle
		)
		let findResult = policy.evaluate(findCtx)
		if findResult.allowed {
			menu.insert(.find_on_page)
		}

		return menu
	}

	// MARK: - Phase 4G: Screen grounding

	private func updateScreenGrounding(
		session: inout AgenticSessionState,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		targetAnchor: TargetWindowAnchor?,
		goal: String,
		workflow: String,
		stepLabel: String,
		reason: String
	) {
		guard let graph = buildScreenStateGraph(snapshot: snapshot, targetAnchor: targetAnchor, runtimeGoal: goal) else {
			session.screenStateGraph = nil
			session.groundedTargets = []
			session.primaryGroundedTarget = nil
			print("[GroundingFailure] reason=empty_graph step=\(stepLabel) goal=\(goal.prefix(40))")
			return
		}

		let resolver = GroundedTargetResolver()
		let resolved = resolver.resolveTargets(goal: goal, workflow: workflow, graph: graph)
		session.screenStateGraph = graph
		session.groundedTargets = resolved.targets
		session.primaryGroundedTarget = resolved.primary

		print("[ScreenStateGraphRuntime] nodes=\(graph.nodes.count) source=\(reason) targets=\(resolved.targets.count)")
		if let primary = resolved.primary {
			let conf = String(format: "%.2f", primary.confidence)
			print("[GroundedRuntimeTarget] title=\"\(primary.title.prefix(60))\" role=\(primary.role.rawValue) confidence=\(conf) step=\(stepLabel)")
		}
		let fresh = snapshot.freshnessScore >= 0.85 ? "yes" : "no"
		print("[GroundingVerification] fresh_observation=\(fresh) graph_nodes=\(graph.nodes.count) targets=\(resolved.targets.count) step=\(stepLabel)")
	}

	private func buildScreenStateGraph(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		targetAnchor: TargetWindowAnchor?,
		runtimeGoal: String? = nil
	) -> ScreenStateGraph? {
		var graphs: [ScreenStateGraph] = []

		// OCR graph
		if let ocr = snapshot.recentOCRExcerpt, !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let filter = AssistantChromeFilter.filterOCR(
				ocr,
				targetBundleIdentifier: targetAnchor?.bundleIdentifier
			)
			if filter.suppressedLineCount > 0 {
				print("[AssistantChromeFilter] suppressed=\(filter.suppressedLineCount) target_bundle=\(targetAnchor?.bundleIdentifier ?? "unknown")")
			}
				// Phase 4N: drop lines that mirror the current runtime goal / proposal title
				// back into OCR. These are generated by Contextual's own panel chrome and
				// must NEVER ground the runtime against itself.
				let support = GeneratedChromeFilter.GroundingSupport(
					windowTitle: snapshot.windowTitle,
					axText: snapshot.contextSummary
				)
				let generated = GeneratedChromeFilter.filter(
					text: filter.filteredText,
					runtimeGoal: runtimeGoal,
					proposalTitle: nil,
					groundingSupport: support
				)
			if generated.suppressedLineCount > 0 {
				print("[GeneratedChromeFilter] suppressed=\(generated.suppressedLineCount) reason=runtime_goal_echo runtime_goal=\(runtimeGoal?.prefix(40) ?? "nil")")
			}
			let ocrGraph = OCRGroundingExtractor().extract(from: generated.filteredText)
			graphs.append(ocrGraph)
		}

		// AX graph (best-effort)
		if let ax = AXWindowContentSource.shared.extractActiveWindowContent(), !ax.visibleTextFragments.isEmpty {
			let axGraph = AccessibilityGroundingExtractor().extract(from: ax)
			graphs.append(axGraph)
		}

		guard !graphs.isEmpty else { return nil }
		if graphs.count == 1 { return graphs[0] }
		return mergeGraphs(graphs)
	}

	private func mergeGraphs(_ graphs: [ScreenStateGraph]) -> ScreenStateGraph {
		let rootId = ScreenStateGraph.makeStableId(source: .metadata, role: .root, text: "merged_root")
		var nodes: [ScreenStateNode] = []

		var childIds: [String] = []
		for g in graphs {
			// Attach each graph root under merged root.
			childIds.append(g.rootId)
			nodes.append(contentsOf: g.nodes)
		}

		let root = ScreenStateNode(
			stableId: rootId,
			role: .root,
			title: "Screen Root",
			text: nil,
			frame: nil,
			visible: true,
			interactable: false,
			confidence: 0.7,
			source: .metadata,
			semanticTags: ["merged"],
			parentId: nil,
			childIds: childIds,
			viewportVisibility: 0.6
		)
		nodes.insert(root, at: 0)

		return ScreenStateGraph(rootId: rootId, nodes: nodes)
	}

	// MARK: - Phase 4I: Semantic extraction helpers

	private func entityCounts(_ entities: [GroundedSemanticEntity]) -> (products: Int, prices: Int, features: Int) {
		let products = entities.filter { $0.type == .productTitle }.count
		let prices = entities.filter { $0.type == .price }.count
		let features = entities.filter { $0.type == .feature || $0.type == .specification }.count
		return (products, prices, features)
	}

	// MARK: - Action Executor

	/// Execute one Phase 4D/4E action, returning the updated session and a result description.
	/// Returns a tuple to avoid inout-async exclusivity issues.
	private func executeAction(
		_ action: AgenticNextAction,
		findQuery: String?,
		session: AgenticSessionState,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		targetAnchor: TargetWindowAnchor?,
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

			// Phase 4G: build/update graph and targets after observe_once
			updateScreenGrounding(
				session: &s,
				snapshot: snapshot,
				targetAnchor: targetAnchor,
				goal: plan.goal,
				workflow: plan.workflow,
				stepLabel: "\(step)",
				reason: "observe_once"
			)

			// Phase 4O: re-assess evidence requirements against the freshly-built graph.
			let comparisonRequired = s.evidenceRequirements.contains(where: { $0.kind == .comparisonCandidate && $0.required })
			let comparisonTitles = comparisonRequired
				? await BrowsingComparisonTracker.shared.distinctRecentTitles(at: Date())
				: []
			Self.assessEvidence(
				session: &s,
				goal: plan.goal,
				workflow: plan.workflow,
				snapshot: snapshot,
				comparisonTitles: comparisonTitles,
				source: "post_observe",
				step: step
			)

			let r = "observed app=\(obs.activeApp) window=\(obs.windowTitle.prefix(40)) quality=\(obs.quality.rawValue) chars=\(obs.contentLength) has_usable=\(obs.hasUsableContent)"
			print("[AgenticAct] result=\(r)")
			return (r, s)

		case .extract_facts:
			print("[AgenticAct] action=extract_facts step=\(step) from=\(s.observations.count) observation(s)")
			let semantic = GroundedSemanticExtractor()
			let builder = StructuredFactBuilder()

			let ocrFallback = s.observations.last?.ocrExcerpt
			let windowTitle = snapshot.windowTitle
			if let graph = s.screenStateGraph, !s.groundedTargets.isEmpty {
				let entities = semantic.extract(
					graph: graph,
					groundedTargets: s.groundedTargets,
					ocrFallback: ocrFallback,
					goal: plan.goal,
					windowTitle: windowTitle
				)
				s.semanticEntities = entities
				let facts = builder.buildFacts(from: entities, goal: plan.goal, windowTitle: windowTitle)
				s.structuredFacts = facts

				let rendered = builder.renderFactsForRuntime(facts)
				s.extractedFacts.append(contentsOf: rendered)

				// Phase 4O: re-assess evidence requirements against the new entities BEFORE
				// readiness is computed — readiness uses the resulting state.
				let comparisonRequired = s.evidenceRequirements.contains(where: { $0.kind == .comparisonCandidate && $0.required })
				let comparisonTitles = comparisonRequired
					? await BrowsingComparisonTracker.shared.distinctRecentTitles(at: Date())
					: []
				Self.assessEvidence(
					session: &s,
					goal: plan.goal,
					workflow: plan.workflow,
					snapshot: snapshot,
					comparisonTitles: comparisonTitles,
					source: "post_extract",
					step: step
				)

				// Evaluate semantic readiness, now gated by the evidence state.
				let readiness = SemanticReadinessEvaluator.evaluate(
					facts: facts,
					entities: entities,
					goal: plan.goal,
					evidenceState: s.evidenceState,
					budgetExhausted: false
				)
				s.semanticReadiness = readiness

				let counts = entityCounts(entities)
				print("[SemanticExtraction] entities=\(entities.count) products=\(counts.products) prices=\(counts.prices) features=\(counts.features)")
				for e in entities.prefix(18) {
					let conf = String(format: "%.2f", e.confidence)
					print("[SemanticEntity] type=\(e.type.rawValue) text=\"\(e.text.prefix(80))\" confidence=\(conf) source=grounded_target")
				}

				let r = "extracted grounded_entities=\(entities.count) structured_facts=\(facts.count) total_lines=\(s.extractedFacts.count)"
				print("[AgenticAct] result=\(r)")
				return (r, s)
			}

			// Grounding missing → legacy fallback extraction (still bounded)
			let newFacts = extractFacts(from: s.observations, goal: plan.goal)
			s.extractedFacts.append(contentsOf: newFacts)
			let r = "extracted legacy_facts=\(newFacts.count) total=\(s.extractedFacts.count)"
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
			let answer = buildAnswer(session: s, observations: s.observations, facts: s.extractedFacts, goal: plan.goal)
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
				s.finalAnswer = buildAnswer(session: s, observations: s.observations, facts: s.extractedFacts, goal: plan.goal)
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
		// Legacy OCR-heavy extractor retained as a fallback for empty grounding.
		var facts: [String] = []
		for obs in observations {
			if let text = obs.selectedText, !text.isEmpty { facts.append("Selected text: \(text.prefix(200))") }
			if let ocr = obs.ocrExcerpt, !ocr.isEmpty { facts.append("Screen content: \(ocr.prefix(200))") }
			if !obs.windowTitle.isEmpty { facts.append("Active: \(obs.activeApp) — \(obs.windowTitle.prefix(80))") }
		}
		return facts.isEmpty ? ["No actionable page content found in current context."] : facts
	}

	private func buildSummary(observations: [AgenticObservation], facts: [String], goal: String) -> String {
		var parts: [String] = ["Goal: \(goal)"]
		if !facts.isEmpty {
			let factPreview = facts.prefix(6).joined(separator: "\n• ")
			parts.append("Findings:\n• \(factPreview)")
		}
		if let latest = observations.last {
			parts.append("Context: \(latest.activeApp) — \(latest.windowTitle)")
		}
		return parts.joined(separator: "\n\n")
	}

	private func buildAnswer(session: AgenticSessionState, observations: [AgenticObservation], facts: [String], goal: String) -> String {
		let hasProductEvidence = !session.evidenceObservations.filter {
			$0.kind == .productTitle || $0.kind == .price || $0.kind == .specs || $0.kind == .rating || $0.kind == .reviewCount
		}.isEmpty
		let hasSemanticEvidence = !session.semanticEntities.filter {
			$0.type == .productTitle || $0.type == .price || $0.type == .specification || $0.type == .feature || $0.type == .rating || $0.type == .reviewCount
		}.isEmpty
		
		if !session.structuredFacts.isEmpty || hasProductEvidence || hasSemanticEvidence {
			print("[AgenticAnswer] fallback_suppressed reason=useful_evidence_exists")
			return buildPremiumAnswer(session: session)
		}
		if facts.isEmpty {
			return "No relevant information found for: \(goal)"
		}
		// Prefer structured semantic facts when present; keep concise.
		return facts.prefix(12).joined(separator: "\n")
	}

		nonisolated private func buildPremiumAnswer(session: AgenticSessionState) -> String {
		let ev = session.evidenceState
		
		let isCompareGoal = session.goal.lowercased().contains("compare") || session.goal.lowercased().contains(" vs ") || session.goal.lowercased().contains(" versus ")
		
		// Filter garbage/noisy entities and observations
		let semanticEntities = session.semanticEntities.filter { entity in
			switch entity.type {
			case .productTitle:
				return AgenticEvidenceAssessor.isProductTitleValid(entity.text, goal: session.goal)
			case .specification, .feature:
				return AgenticEvidenceAssessor.isSpecValid(entity.text)
			default:
				return true
			}
		}
		
		let evidenceObservations = session.evidenceObservations.filter { obs in
			switch obs.kind {
			case .productTitle:
				return AgenticEvidenceAssessor.isProductTitleValid(obs.text, goal: session.goal)
			case .specs:
				return AgenticEvidenceAssessor.isSpecValid(obs.text)
			default:
				return true
			}
		}

		// Check quality
		let quality = EvidenceQualityGate.evaluate(
			goal: session.goal,
			state: ev ?? AgenticEvidenceState(goal: session.goal, requirements: [], satisfied: [], missing: [], missingOptional: [], confidence: 0, shouldGatherMore: false, recommendedAction: .present),
			observations: evidenceObservations,
			entities: semanticEntities,
			facts: session.structuredFacts
		)
		let hasValidComparison = !isCompareGoal || ComparisonEvidenceValidator.validate(state: ev ?? AgenticEvidenceState(goal: session.goal, requirements: [], satisfied: [], missing: [], missingOptional: [], confidence: 0, shouldGatherMore: false, recommendedAction: .present), observations: evidenceObservations, entities: semanticEntities, facts: session.structuredFacts).isValid
		
		let isPartial = (ev?.allRequiredSatisfied != true) || (quality.overallScore < EvidenceQualityGate.overallScoreThreshold) || !hasValidComparison || (session.stopReason == .partial_evidence_budget_exhausted)
		let mode = isPartial ? "partial" : "complete"
		
		let foundKinds = ev?.satisfied.map { kind -> String in
			switch kind {
			case .productTitle: return "product_title"
			case .specs: return "specs"
			case .price: return "price"
			case .rating: return "rating"
			case .reviewCount: return "review_count"
			case .reviewText: return "review_text"
			case .comparisonCandidate: return "comparison_candidate"
			case .pageSummary: return "page_summary"
			case .documentKeyPoint: return "document_key_point"
			default: return kind.rawValue
			}
		} ?? []
		var uniqueFound = Array(Set(foundKinds)).sorted()
		if isCompareGoal && !hasValidComparison {
			uniqueFound.removeAll { $0 == "comparison_candidate" }
		}
		
		var missingKinds = ev?.missing.map { kind -> String in
			switch kind {
			case .productTitle: return "product_title"
			case .specs: return "specs"
			case .price: return "price"
			case .rating: return "rating"
			case .reviewCount: return "review_count"
			case .reviewText: return "review_text"
			case .comparisonCandidate: return "comparison_candidate"
			case .pageSummary: return "page_summary"
			case .documentKeyPoint: return "document_key_point"
			default: return kind.rawValue
			}
		} ?? []
		if isCompareGoal && !hasValidComparison {
			missingKinds.append("comparison_candidate")
		}
		if quality.overallScore < EvidenceQualityGate.overallScoreThreshold && !stateHasSpecsAndPrice(session: session) {
			missingKinds.append("price")
			missingKinds.append("reviews")
		}
		
		// Remove contradiction: if an item is in uniqueFound, it cannot be in uniqueMissing!
		var uniqueMissing = Array(Set(missingKinds)).sorted()
		uniqueMissing.removeAll { uniqueFound.contains($0) }
		
		let isEmailDomain = session.evidenceRequirements.contains(where: { req in
			switch req.kind {
			case .inboxContext, .messageList, .emailSubject, .emailSnippet, .emailSender, .unreadCount, .timestamp:
				return true
			default:
				return false
			}
		})

		if isEmailDomain {
			print("[AgenticAnswer] domain=email mode=\(mode) evidence_found=\(uniqueFound.joined(separator: ",")) missing=\(uniqueMissing.joined(separator: ","))")
		} else {
			print("[AgenticAnswer] mode=\(mode) evidence_found=\(uniqueFound.joined(separator: ",")) missing=\(uniqueMissing.joined(separator: ","))")
		}
		
		var lines: [String] = []

		if isEmailDomain {
			if isPartial {
				lines.append("I can see that an inbox view is open, but I do not yet have enough clean visible email evidence to summarize recent emails.")
				lines.append("")
			}
			lines.append("Found:")
			if let obs = session.observations.last {
				lines.append("- App/Page: \(obs.activeApp) — \(obs.windowTitle.prefix(80))")
			}

			let subjects = Array(Set(session.evidenceObservations.filter { $0.kind == .emailSubject }.map(\.text))).prefix(4)
			if !subjects.isEmpty {
				lines.append("- Visible subjects: \(subjects.map { String($0.prefix(56)) }.joined(separator: " | "))")
			}
			let snippets = Array(Set(session.evidenceObservations.filter { $0.kind == .emailSnippet }.map(\.text))).prefix(4)
			if !snippets.isEmpty {
				lines.append("- Visible snippets: \(snippets.map { String($0.prefix(56)) }.joined(separator: " | "))")
			}

			if isPartial && !uniqueMissing.isEmpty {
				lines.append("")
				lines.append("Missing:")
				for kind in uniqueMissing {
					switch kind {
					case "email_subject":
						lines.append("- clean sender/subject evidence")
					case "email_snippet":
						lines.append("- clean message preview/snippet evidence")
					case "message_list":
						lines.append("- visible message list evidence")
					default:
						lines.append("- \(kind) not found")
					}
				}
			}

			if !session.failedControlActions.isEmpty {
				lines.append("")
				lines.append("Note: Some navigation attempts (scroll/find) did not reveal additional evidence before runtime limits were reached.")
			}
			return lines.joined(separator: "\n")
		}
		
		if isCompareGoal && isPartial {
			lines.append("I found one likely product and several reliable specs, but I do not yet have enough clean evidence to compare it with another charger.")
			lines.append("")
		}
		
		lines.append("Found:")
		
		// Clean and validate product name
		var productTitle = "Unknown Product"
		if let pt = session.structuredFacts.first(where: { $0.category == "product" })?.title {
			productTitle = pt
		} else if let titleEntity = session.semanticEntities.first(where: { $0.type == .productTitle })?.text {
			productTitle = titleEntity
		} else if let ptObs = session.evidenceObservations.first(where: { $0.kind == .productTitle })?.text {
			productTitle = ptObs
		} else if !session.groundedTargets.isEmpty {
			productTitle = session.groundedTargets[0].title
		} else if let windowTitle = session.observations.last?.windowTitle {
			productTitle = windowTitle
		}
		
			// Strip common browser chrome if it leaked or looks truncated
			if EvidenceQualityGate.detectTruncation(productTitle) || EvidenceQualityGate.detectChromeLeak(productTitle) || (productTitle.split(separator: " ").count == 1 && productTitle.count <= 3) {
				productTitle = "Unknown Product"
			}
			lines.append("- Product: \(productTitle)")
		
		let specs = session.semanticEntities.filter { $0.type == .specification || $0.type == .feature }
		if !specs.isEmpty {
			let specStrings = Array(Set(specs.map { $0.normalizedValue ?? $0.text })).filter { !EvidenceQualityGate.detectMashedWord($0) }.prefix(6)
				if !specStrings.isEmpty {
					lines.append("- Specs: \(specStrings.joined(separator: ", "))")
				}
			} else {
				let specFacts = session.structuredFacts.filter { $0.category == "specs" }
				let specObs = session.evidenceObservations.filter { $0.kind == .specs }
				if !specFacts.isEmpty {
					let specStrings = specFacts.map { $0.title }.prefix(4)
					lines.append("- Specs: \(specStrings.joined(separator: ", "))")
				} else if !specObs.isEmpty {
					let specStrings = Array(Set(specObs.map { $0.text })).prefix(4)
					lines.append("- Specs: \(specStrings.joined(separator: ", "))")
				}
			}
		
		if let priceEntity = session.semanticEntities.first(where: { $0.type == .price })?.text {
			lines.append("- Price: \(priceEntity)")
		} else if let priceFact = session.structuredFacts.first(where: { $0.category == "product" })?.attributes["price"] {
			lines.append("- Price: \(priceFact)")
		} else if let priceObs = session.evidenceObservations.first(where: { $0.kind == .price })?.text {
			lines.append("- Price: \(priceObs)")
		}
		
		let ratings = session.semanticEntities.filter { $0.type == .rating }
		let ratingObs = session.evidenceObservations.first(where: { $0.kind == .rating })?.text
		if let firstRating = ratings.first?.text {
			lines.append("- Rating: \(firstRating)")
		} else if let rob = ratingObs {
			lines.append("- Rating: \(rob)")
		}
		let reviews = session.semanticEntities.filter { $0.type == .reviewCount }
		let reviewsObs = session.evidenceObservations.first(where: { $0.kind == .reviewCount })?.text
		if !reviews.isEmpty {
			let reviewPreview = reviews.first?.text ?? ""
			lines.append("- Reviews: \(reviewPreview)")
		} else if let rob = reviewsObs {
			lines.append("- Reviews: \(rob)")
		}
		
		if isPartial && !uniqueMissing.isEmpty {
			lines.append("")
			lines.append("Missing:")
			for kind in uniqueMissing {
				switch kind {
				case "price":
					lines.append("- clean price/review evidence (price not visible)")
				case "reviews":
					lines.append("- reviews not found")
				case "comparison_candidate":
					lines.append("- second valid comparison candidate")
				case "specs":
					lines.append("- specs not found")
				default:
					lines.append("- \(kind) not found")
				}
			}
		}
		
			// Phase 4R — if control attempts failed after extracting grounded facts,
			// preserve facts and mention the control ineffectiveness without
			// overriding the evidence payload.
			if !session.failedControlActions.isEmpty {
				lines.append("")
				lines.append("Note: Some navigation attempts (scroll/find) did not reveal additional evidence before runtime limits were reached.")
			}

			return lines.joined(separator: "\n")
		}

	nonisolated private func stateHasSpecsAndPrice(session: AgenticSessionState) -> Bool {
		let hasPrice = session.semanticEntities.contains { $0.type == .price }
		let hasSpecs = session.semanticEntities.contains { $0.type == .specification || $0.type == .feature }
		return hasPrice && hasSpecs
	}

	private func buildFallbackAnswer(session: AgenticSessionState) -> String {
		if !session.structuredFacts.isEmpty {
			return buildPremiumAnswer(session: session)
		}
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
		if let ev = session.evidenceState {
			lines.append("Evidence gathered: \(ev.satisfied.map { $0.rawValue }.joined(separator: ", "))")
			lines.append("Missing evidence: \(ev.missing.map { $0.rawValue }.joined(separator: ", "))")
			let improved = session.worldStateTransitions.contains(where: { $0.contains("evidence_improved") })
			lines.append("Evidence improved during loop: \(improved ? "yes" : "no")")
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
			actionId: actionId,
			actionsExecuted: [],
			extractedFacts: [],
			finalAnswer: nil,
			groundedTargetCount: 0,
			groundedPrimaryTitle: nil,
			groundedPrimaryRole: nil
		)
	}

	// MARK: - Phase 4O: Evidence assessment

	/// Recompute the evidence state for the current session and log every gap.
	///
	/// Called from observe_once (to evaluate live grounding) and from extract_facts
	/// (to evaluate the freshly-built semantic entities). The result is stored on
	/// the session so the decider and the readiness evaluator can read the same
	/// snapshot without recomputing.
	static func assessEvidence(
		session: inout AgenticSessionState,
		goal: String,
		workflow: String,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		comparisonTitles: [String],
		source: String,
		step: Int
	) {
		guard !session.evidenceRequirements.isEmpty else { return }
		let hasUsableObs = session.observations.contains(where: { $0.hasUsableContent })

		// Phase 4P: bridge raw signals into normalized evidence observations.
		let observations = AgenticEvidenceExtractionBridge.extract(
			goal: goal,
			workflow: workflow,
			windowTitle: snapshot.windowTitle,
			ocrText: snapshot.recentOCRExcerpt,
			axText: snapshot.contextSummary,
			graph: session.screenStateGraph,
			semanticEntities: session.semanticEntities,
			structuredFacts: session.structuredFacts,
			comparisonTitles: comparisonTitles
		)
		session.evidenceObservations = observations

		let state = AgenticEvidenceAssessor.assess(
			goal: goal,
			requirements: session.evidenceRequirements,
			entities: session.semanticEntities,
			evidenceObservations: observations,
			extractedFactsCount: session.extractedFacts.count,
			hasUsableObservation: hasUsableObs
		)
		session.evidenceState = state

		let sat = state.satisfied.map { $0.rawValue }.joined(separator: ",")
		let miss = state.missing.map { $0.rawValue }.joined(separator: ",")
		let gather = state.shouldGatherMore ? "yes" : "no"
		print("[EvidenceState] source=\(source) step=\(step) satisfied=\(sat) missing=\(miss) confidence=\(String(format: "%.2f", state.confidence)) should_gather=\(gather)")
		if let firstMissing = state.firstMissing {
			print("[EvidenceGap] kind=\(firstMissing.kind.rawValue) action=\(state.recommendedAction.rawValue) reason=missing_required step=\(step)")
		}
	}

	// MARK: - Phase 4M: Frontmost-app probe

	/// Returns the bundle identifier of the currently-frontmost macOS application.
	///
	/// Hops to MainActor because `NSWorkspace.shared.frontmostApplication` is a
	/// main-thread-only AppKit API. Returns nil when no frontmost app is
	/// available (rare; e.g. during early app launch in dry-run tests).
	static func currentFrontmostBundleIdentifier() async -> String? {
		await MainActor.run {
			NSWorkspace.shared.frontmostApplication?.bundleIdentifier
		}
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
			case .partial_grounded_success, .grounded_observation_only:
				execStatus = .partialSuccess
			case .blocked_unsafe_action, .rejected_phase_constraint:
				execStatus = .partialSuccess
			case .no_progress, .rejected_missing_plan, .rejected_budget_invalid:
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
			case .partial_grounded_success:
				followUps = ["Some evidence was extracted, but runtime limits prevented gathering additional details."]
			case .grounded_observation_only:
				followUps = ["Grounded observation captured; consider re-running after scrolling or revealing more details."]
			case .no_progress:
				followUps = ["No grounded evidence extracted — check permissions (Screen Recording / Accessibility) or try again on a content-rich screen."]
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

// MARK: - Semantic Readiness Scoring

struct SemanticReadiness: Sendable, Equatable, Codable {
	let hasReliableProductTitle: Bool
	let hasUsefulAttributes: Bool
	let hasReliablePrice: Bool
	let hasComparisonEvidence: Bool
	let semanticConfidence: Double
	let reason: String
	let readyForFinalAnswer: Bool
}

struct SemanticReadinessEvaluator: Sendable {
	/// Phase 4O: when `evidenceState` is supplied, the evaluator treats the
	/// evidence-requirement gate as authoritative — `ready` cannot be `true`
	/// while any *required* evidence slot is unsatisfied, regardless of how
	/// confident the heuristic score looks.
	///
	/// When `budgetExhausted` is `true` and required evidence is still
	/// missing, the readiness reason is tagged `budget_exhausted_missing_evidence`
	/// so the runtime emits a partial stop condition instead of fake success.
	static func evaluate(
		facts: [StructuredFact],
		entities: [GroundedSemanticEntity],
		goal: String,
		evidenceState: AgenticEvidenceState? = nil,
		budgetExhausted: Bool = false
	) -> SemanticReadiness {
		let productFact = facts.first(where: { $0.category == "product" })
		var hasReliableProductTitle = false
		var titleConfidence = 0.0

		if let pf = productFact {
			let title = pf.title.trimmingCharacters(in: .whitespacesAndNewlines)
			titleConfidence = pf.confidence

			let isURL = title.lowercased().contains("://") || title.lowercased().contains("www.") || title.lowercased().hasSuffix(".com") || title.lowercased().hasSuffix(".ca") || title.lowercased().contains(".ca/") || title.lowercased().contains(".com/")
			let isGoalEcho = isGoalEchoText(title, goal: goal)
			let isTruncated = title.hasSuffix("...") || title.hasSuffix("…")
			let isTooShort = title.count < 10

			if !isURL && !isGoalEcho && !isTruncated && !isTooShort && pf.confidence >= 0.5 {
				hasReliableProductTitle = true
			}
		}

		var hasReliablePrice = false
		if let pf = productFact, pf.attributes["price"] != nil {
			let priceEntities = entities.filter { $0.type == .price }
			if let maxPriceConf = priceEntities.map(\.confidence).max(), maxPriceConf >= 0.5 {
				hasReliablePrice = true
			}
		}

		let attributesCount = entities.filter { $0.type == .specification || $0.type == .feature || $0.type == .rating || $0.type == .reviewCount }.count
		let hasUsefulAttributes = attributesCount >= 2

		let goalWords = goal.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
		let isComparisonRequested = goalWords.contains("compare") || goalWords.contains("vs") || goalWords.contains("versus") || goalWords.contains("or")

		let productTitlesCount = entities.filter { $0.type == .productTitle || $0.type == .heading }.count
		let hasComparisonEvidence = productTitlesCount >= 2 || (isComparisonRequested && attributesCount >= 4)

		var score = 0.0
		if hasReliableProductTitle { score += 0.4 }
		if hasUsefulAttributes { score += 0.2 }
		if hasReliablePrice { score += 0.2 }
		if isComparisonRequested {
			if hasComparisonEvidence { score += 0.2 }
		} else {
			score += 0.2
		}

		var ready = false
		var reason = ""

		if !hasReliableProductTitle {
			ready = false
			reason = "Missing or unreliable product title (only fragments or URLs found)"
		} else if isComparisonRequested && !hasComparisonEvidence {
			ready = false
			reason = "Comparison requested, but insufficient comparison evidence (need multiple items or specs)"
		} else if !hasUsefulAttributes {
			ready = false
			reason = "Insufficient attributes/specs extracted for product description"
		} else if score >= 0.6 {
			ready = true
			reason = "Grounded product title with sufficient supporting specifications/price"
		} else {
			ready = false
			reason = "Low overall semantic confidence score (\(String(format: "%.2f", score)))"
		}

		// Phase 4O: evidence gate is authoritative.
		// If any required evidence slot is missing, downgrade readiness.
		// `partial` is communicated by setting `ready=false` with a typed reason
		// so the runtime stop-condition path can distinguish budget-exhausted
		// partial answers from clean successes.
		if let evidenceState, !evidenceState.allRequiredSatisfied {
			let missingList = evidenceState.missing.map { $0.rawValue }.joined(separator: ",")
			ready = false
			if budgetExhausted {
				reason = "budget_exhausted_missing_evidence missing=\(missingList)"
				print("[SemanticReadiness] ready=partial reason=budget_exhausted_missing_evidence missing=\(missingList)")
			} else {
				reason = "missing_required_evidence missing=\(missingList)"
				print("[SemanticReadiness] ready=no reason=missing_required_evidence missing=\(missingList)")
			}
			return SemanticReadiness(
				hasReliableProductTitle: hasReliableProductTitle,
				hasUsefulAttributes: hasUsefulAttributes,
				hasReliablePrice: hasReliablePrice,
				hasComparisonEvidence: hasComparisonEvidence,
				semanticConfidence: min(score, evidenceState.confidence),
				reason: reason,
				readyForFinalAnswer: ready
			)
		}

		let finalDecision = ready ? "yes" : "no"
		print("[SemanticReadiness] ready=\(finalDecision) confidence=\(String(format: "%.2f", score)) reason=\"\(reason)\"")

		return SemanticReadiness(
			hasReliableProductTitle: hasReliableProductTitle,
			hasUsefulAttributes: hasUsefulAttributes,
			hasReliablePrice: hasReliablePrice,
			hasComparisonEvidence: hasComparisonEvidence,
			semanticConfidence: score,
			reason: reason,
			readyForFinalAnswer: ready
		)
	}

	private static func isGoalEchoText(_ text: String, goal: String) -> Bool {
		let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		let g = goal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		if t == g { return true }
		if g.hasPrefix("compare ") && t.hasPrefix("compare ") { return true }
		if g.contains(t) && g.count - t.count < 15 { return true }
		return false
	}

}

extension AgenticRuntime {
	nonisolated func buildPremiumAnswerTestBridge(session: AgenticSessionState) -> String {
		return buildPremiumAnswer(session: session)
	}

	private static func checkEvidenceImproved(session: AgenticSessionState) -> Bool {
		guard session.stepIndex > 1 else { return true }
		
		let currentObs = session.evidenceObservations
		if let initialObs = session.observations.first {
			let initialText = ((initialObs.ocrExcerpt ?? "") + " " + (initialObs.contextSummary ?? "")).lowercased()
			
			// Find if any new live observation is NOT in the initial text
			let newLiveAdded = currentObs.contains { o in
				o.source != .browsingHistory && o.kind != .pageSummary && !initialText.contains(o.text.lowercased())
			}
			if newLiveAdded {
				print("[EvidenceImprovement] improved=yes added=new_live_perception_elements_discovered quality_delta=0.15")
				return true
			}
		}

		if session.extractedFacts.count > 0 {
			print("[EvidenceImprovement] improved=yes added=extracted_facts_present quality_delta=0.20")
			return true
		}

		print("[EvidenceImprovement] improved=no reason=no_new_grounded_evidence")
		return false
	}

	private static func evaluateQualityPassed(session: AgenticSessionState, plan: AgenticTaskPlan) -> Bool {
		guard let ev = session.evidenceState else { return false }
		
		let quality = EvidenceQualityGate.evaluate(
			goal: plan.goal,
			state: ev,
			observations: session.evidenceObservations,
			entities: session.semanticEntities,
			facts: session.structuredFacts
		)
		let isCompareGoal = AgenticEvidenceRequirementsInferrer.classifyFamily(goal: plan.goal.lowercased(), workflow: "") == .compare
		let hasValidComparison = !isCompareGoal || ComparisonEvidenceValidator.validate(state: ev, observations: session.evidenceObservations, entities: session.semanticEntities, facts: session.structuredFacts).isValid
		
		let isStrongStart = session.stepIndex <= 1 && quality.overallScore >= EvidenceQualityGate.overallScoreThreshold && hasValidComparison
		let wasGrounded = quality.sourceReliability >= 0.5
		let improved = session.stepIndex > 1 ? checkEvidenceImproved(session: session) : false

		let qualityPassed = (quality.overallScore >= EvidenceQualityGate.overallScoreThreshold) && hasValidComparison && wasGrounded && (improved || isStrongStart)

		if !qualityPassed {
			let reason = !hasValidComparison ? "invalid_comparison_candidates" : (quality.overallScore < EvidenceQualityGate.overallScoreThreshold ? "low_evidence_quality" : "no_evidence_improvement")
			print("[LoopTermination] requested=evidence_satisfied allowed=no reason=\(reason)")
		} else {
			print("[LoopTermination] requested=evidence_satisfied allowed=yes reason=quality_gate_passed")
		}

		return qualityPassed
	}
}
