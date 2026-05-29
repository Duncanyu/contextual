import Foundation

// MARK: - Action Menu

/// Legal actions for the Phase 4D controlled observe-act loop.
///
/// Phase 4D adds two bounded controlled-interaction actions:
///   - scroll_small  (read-only page navigation, max 2 per session)
///   - find_on_page  (browser Cmd+F with deterministic query, max 1 per session)
///
/// Still disallowed (forever unless explicitly enabled by a future phase):
///   click, type into forms, navigate to URL, switch tabs, submit, purchase, login.
enum AgenticNextAction: String, Sendable, CaseIterable {
	/// Read the current context from the snapshot.
	case observe_once
	/// Extract structured facts from accumulated observations.
	case extract_facts
	/// Extract relevant raw text lines matching the goal.
	case extract_relevant_text
	/// Produce a coherent summary from observations and facts.
	case summarize_observation
	/// Build and surface the final answer to the user.
	case present_answer
	/// Scroll the current page/window down by a small bounded amount.
	/// Max 2 per session; only in browser/research workflows.
	case scroll_small
	/// Open the browser find-bar with a deterministic keyword from the goal.
	/// Max 1 per session; only in supported browsers.
	case find_on_page
	/// Direct Agent: Observe the screen (alias for observe_once in V0).
	case observe_screen
	/// Direct Agent: Click a specific UI element or coordinate.
	case click_element
	/// Direct Agent: Scroll the window/view (generalized).
	case scroll
	/// Direct Agent: Type text into the focused element.
	case type_text
	/// Direct Agent: Press a specific key or shortcut.
	case press_key
	/// Direct Agent: Wait for a short period for UI to settle.
	case wait
	/// Direct Agent: Final answer to the user.
	case answer
	/// Stop: insufficient context to fulfil the goal.
	case stop_missing_context
	/// Stop: goal is satisfied; answer is ready.
	case stop_success

	/// True for terminal actions that end the loop.
	var isTerminal: Bool {
		switch self {
		case .stop_missing_context, .stop_success, .present_answer, .answer: return true
		default: return false
		}
	}

	/// True for actions that interact with the OS (bounded; not arbitrary external control).
	var isControlledInteraction: Bool {
		switch self {
		case .scroll_small, .find_on_page, .click_element, .scroll, .type_text, .press_key, .wait: return true
		default: return false
		}
	}

	/// Phase 4D: none of these actions perform unrestricted external control
	/// (arbitrary click, type, navigate, submit). Controlled interactions require policy check.
	var requiresExternalControl: Bool { false }
}

// MARK: - Decision

/// Structured output from the AgenticDecider for one loop step.
struct AgenticLoopDecision: Sendable {
	let nextAction: AgenticNextAction
	let reason: String
	let confidence: Double
	let source: AgenticLoopDecisionSource
	/// For find_on_page: the deterministic query string to use.
	let findQuery: String?
	/// For click_element: natural-language description of the element to click.
	let clickTarget: String?
	/// For type_text: the text to type into the focused element.
	let typeText: String?
	/// For press_key: key name or shortcut (e.g. "return", "escape", "cmd+a").
	let keyName: String?

	/// Explicit init so all existing callsites that omit the V1 fields continue to compile.
	init(
		nextAction:  AgenticNextAction,
		reason:      String,
		confidence:  Double,
		source:      AgenticLoopDecisionSource,
		findQuery:   String? = nil,
		clickTarget: String? = nil,
		typeText:    String? = nil,
		keyName:     String? = nil
	) {
		self.nextAction  = nextAction
		self.reason      = reason
		self.confidence  = confidence
		self.source      = source
		self.findQuery   = findQuery
		self.clickTarget = clickTarget
		self.typeText    = typeText
		self.keyName     = keyName
	}
}

enum AgenticLoopDecisionSource: String, Sendable {
	case heuristic
	case model
	/// Model was called but failed; fell back to heuristic result.
	case fallback
}

// MARK: - Decider

/// Micro decider for the Phase 4D observe → decide → act loop.
///
/// Decision priority (heuristic fast path):
///   0. forceObserveNext == true → observe_once (post-control observation)
///   1. No observations yet → observe_once
///   2. Observations have no usable content AND find available → find_on_page
///   3. Observations have no usable content AND find NOT available → stop_missing_context
///   4. Goal implies reviews/ratings and text lacks them AND find available → find_on_page
///   5. Find used and still missing target content AND scroll available → scroll_small
///   6. Observations have content but no facts → extract_facts
///   7. Near step budget → present_answer
///   8. Have 2+ facts → summarize_observation
///   9. Have 1 fact → present_answer
///
/// Model path (optional):
///   - Only if heuristic confidence < 0.85 AND LLM budget remains
///   - Model: phi4-mini, numPredict: 100, temperature: 0.1
///   - Hard timeout: 5 seconds; no retries
///   - On failure: deterministic heuristic fallback
///
/// Hard constraint: model response is validated against the legal actions set.
/// Model cannot invent new actions or override policy.
struct AgenticDecider: Sendable {

	static let deciderSchema: [String: Any] = [
		"type": "object",
		"properties": [
			"next_action": [
				"type": "string",
				"enum": AgenticNextAction.allCases.map(\.rawValue)
			],
			"reason": [
				"type": "string",
				"maxLength": 300
			] as [String: Any],
			"expected_change": [
				"type": "string",
				"maxLength": 200
			] as [String: Any],
			"confidence": [
				"type": "number"
			]
		],
		"required": [
			"next_action",
			"reason",
			"expected_change",
			"confidence"
		]
	]

	func decide(
		goal: String,
		workflow: String = "",
		observations: [AgenticObservation],
		extractedFacts: [String],
		stepIndex: Int,
		maxSteps: Int,
		llmCallsUsed: Int,
		llmCallsBudget: Int,
		ocrCallsUsed: Int,
		ocrCallsBudget: Int,
		legalActions: Set<AgenticNextAction> = Set(AgenticNextAction.allCases),
		forceObserveNext: Bool = false,
		forceDirectAgentDecider: Bool = false,
		semanticReadiness: SemanticReadiness? = nil,
		evidenceState: AgenticEvidenceState? = nil,
		evidenceObservations: [AgenticEvidenceObservation] = [],
		priorActions: [String] = [],
		ineffectiveControlCount: Int = 0,
		entities: [GroundedSemanticEntity] = [],
		facts: [StructuredFact] = [],
		explorationMemory: ExplorationMemory? = nil
	) async -> AgenticLoopDecision {
		let latestQuality = observations.last?.quality.rawValue ?? "none"
		let evGate: String = {
			guard let s = evidenceState else { return "n/a" }
			return s.allRequiredSatisfied ? "satisfied" : "missing:\(s.missing.map { $0.rawValue }.joined(separator: ","))"
		}()
		print("[AgenticDecide] started step=\(stepIndex) observations=\(observations.count) facts=\(extractedFacts.count) quality=\(latestQuality) evidence_gate=\(evGate) llm=\(llmCallsUsed)/\(llmCallsBudget) ocr=\(ocrCallsUsed)/\(ocrCallsBudget) legal=[\(legalActions.map(\.rawValue).sorted().joined(separator: ","))]")

		// Direct-agent routing must never depend on the global pivot flag alone:
		// the direct runtime can be forced on even when the pivot flag is off.
		if forceDirectAgentDecider || AgenticPivot.useDirectAgentRuntime {
			print("[DirectAgentPlannerRouting] path=direct_agent_decide")
			print("[DirectAgentPlannerRouting] modern_pipeline=yes repair_enabled=yes")
			return await directAgentDecide(
				goal: goal,
				stepIndex: stepIndex,
				maxSteps: maxSteps,
				legalActions: legalActions,
				observations: observations,
				llmCallsUsed: llmCallsUsed,
				llmCallsBudget: llmCallsBudget,
				explorationMemory: explorationMemory
			)
		}

		if stepIndex == 1 && AgenticDecider.isAmbiguousOrSoftGoal(goal) {
			if legalActions.contains(.observe_once) {
				print("[AgenticDecide] forced ambiguous/soft goal first action=observe_once")
				print("[AgenticDecide] source=heuristic next_action=observe_once reason=ambiguous_or_soft_goal_first_observe confidence=0.99")
				return AgenticLoopDecision(
					nextAction: .observe_once,
					reason: "Ambiguous/soft goal first action — read page context via observe_once before any execution",
					confidence: 0.99,
					source: .heuristic,
					findQuery: nil
				)
			}
		}

		let heuristicDecision = heuristic(
			goal: goal,
			workflow: workflow,
			observations: observations,
			extractedFacts: extractedFacts,
			stepIndex: stepIndex,
			maxSteps: maxSteps,
			legalActions: legalActions,
			forceObserveNext: forceObserveNext,
			semanticReadiness: semanticReadiness,
			evidenceState: evidenceState,
			evidenceObservations: evidenceObservations,
			priorActions: priorActions,
			ineffectiveControlCount: ineffectiveControlCount,
			entities: entities,
			facts: facts
		)

		// Heuristic acts as fallback when LLM budget is exhausted
		if llmCallsUsed >= llmCallsBudget {
			print("[AgenticDecide] source=heuristic next_action=\(heuristicDecision.nextAction.rawValue) reason=llm_budget_exhausted confidence=\(String(format: "%.2f", heuristicDecision.confidence))")
			
			// StopGate check on heuristic output
			var finalDecision = heuristicDecision
			if finalDecision.nextAction == .present_answer || finalDecision.nextAction == .stop_success {
				// Phase 4U — bypass StopGate when budget is exhausted with no
				// gathering action remaining in the legal menu. Forcing
				// observe_once / scroll / find when none of them are legal
				// (or when the loop has no steps left) just stalls the loop
				// without improving evidence. A partial present is the right
				// outcome — the answer renderer surfaces the missing evidence
				// honestly.
				let stepsRemaining = maxSteps - stepIndex
				let gatheringActions: Set<AgenticNextAction> = [
					.observe_once, .scroll_small, .find_on_page, .extract_facts,
				]
				let hasGatheringAction = !legalActions.intersection(gatheringActions).isEmpty
				let perceptionBudgetExhausted = ocrCallsUsed >= ocrCallsBudget
				let budgetExhausted = stepsRemaining <= 1 || perceptionBudgetExhausted
				// If we cannot perceive again (OCR budget exhausted), control actions
				// cannot improve evidence because we cannot observe the result.
				let canActuallyGather = hasGatheringAction && !perceptionBudgetExhausted
				if budgetExhausted || !canActuallyGather {
					print("[StopGate] bypassed reason=budget_exhausted_or_no_gathering steps_remaining=\(stepsRemaining) gathering_available=\(hasGatheringAction)")
					return finalDecision
				}

				var blockReason: String? = nil
				if isStopGateBlocked(
					goal: goal,
					observations: observations,
					evidenceObservations: evidenceObservations,
					entities: entities,
					facts: facts,
					evidenceState: evidenceState,
					reason: &blockReason
				) {
					let forcedAction: AgenticNextAction
					if legalActions.contains(.observe_once) {
						forcedAction = .observe_once
					} else if legalActions.contains(.scroll_small) {
						forcedAction = .scroll_small
					} else if legalActions.contains(.find_on_page) {
						forcedAction = .find_on_page
					} else if legalActions.contains(.extract_facts) {
						forcedAction = .extract_facts
					} else {
						forcedAction = .stop_missing_context
					}

					print("[StopGate] allowed=no reason=\(blockReason ?? "unknown")")
					finalDecision = AgenticLoopDecision(
						nextAction: forcedAction,
						reason: "Stop blocked by StopGate: \(blockReason ?? "unknown") — forcing further gathering",
						confidence: 0.90,
						source: heuristicDecision.source,
						findQuery: forcedAction == .find_on_page ? AgenticControlPolicy.determineFindQuery(goal: goal) : nil
					)
				}
			}
			return finalDecision
		}

		print("[AgenticLLMDecide] started")
		// Try model
		let modelDecision = await tryModel(
			goal: goal,
			workflow: workflow,
			observations: observations,
			extractedFacts: extractedFacts,
			stepIndex: stepIndex,
			maxSteps: maxSteps,
			llmCallsUsed: llmCallsUsed,
			llmCallsBudget: llmCallsBudget,
			ocrCallsUsed: ocrCallsUsed,
			ocrCallsBudget: ocrCallsBudget,
			legalActions: legalActions,
			evidenceState: evidenceState,
			evidenceObservations: evidenceObservations,
			priorActions: priorActions,
			entities: entities,
			facts: facts,
			heuristicFallback: heuristicDecision
		)

		var finalDecision = modelDecision
		if finalDecision.nextAction == .present_answer || finalDecision.nextAction == .stop_success {
			var blockReason: String? = nil
			if isStopGateBlocked(
				goal: goal,
				observations: observations,
				evidenceObservations: evidenceObservations,
				entities: entities,
				facts: facts,
				evidenceState: evidenceState,
				reason: &blockReason
			) {
				let forcedAction: AgenticNextAction
				if legalActions.contains(.observe_once) {
					forcedAction = .observe_once
				} else if legalActions.contains(.scroll_small) {
					forcedAction = .scroll_small
				} else if legalActions.contains(.find_on_page) {
					forcedAction = .find_on_page
				} else if legalActions.contains(.extract_facts) {
					forcedAction = .extract_facts
				} else {
					forcedAction = .stop_missing_context
				}
				
				print("[StopGate] allowed=no reason=\(blockReason ?? "unknown")")
				finalDecision = AgenticLoopDecision(
					nextAction: forcedAction,
					reason: "Stop blocked by StopGate: \(blockReason ?? "unknown") — forcing further gathering",
					confidence: 0.90,
					source: finalDecision.source,
					findQuery: forcedAction == .find_on_page ? AgenticControlPolicy.determineFindQuery(goal: goal) : nil
				)
			}
		}

		print("[AgenticDecide] source=\(finalDecision.source.rawValue) next_action=\(finalDecision.nextAction.rawValue) reason=\(finalDecision.reason.prefix(80))")
		return finalDecision
	}

	// MARK: - Action alias normalization

	/// Extract the VLM caption embedded in a contextSummary string, returning
	/// `(caption, cleanedSummary)`. The VLM line is stored as:
	///   "vlm_caption: <text> (category=<cat>)"
	/// The cleaned summary has that line stripped so the AX section shown to the
	/// model does not duplicate what's already in the [VISUAL] section.
	nonisolated static func extractVLMCaption(from contextSummary: String) -> (caption: String, axClean: String) {
		let prefix = "vlm_caption: "
		let lines  = contextSummary.components(separatedBy: "\n")
		var caption = ""
		var kept: [String] = []
		for line in lines {
			if line.hasPrefix(prefix) {
				// Strip trailing "(category=...)" annotation — caption is the text before it.
				var text = String(line.dropFirst(prefix.count))
				if let catRange = text.range(of: " (category=") {
					text = String(text[..<catRange.lowerBound])
				}
				caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
			} else {
				kept.append(line)
			}
		}
		let axClean = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		return (caption, axClean)
	}

	/// Map model-generated action aliases to canonical AgenticNextAction raw values.
	///
	/// Called BEFORE legality validation so the legal-menu check operates on
	/// normalized names only. Does not expand the legal action set — unknown aliases
	/// pass through unchanged and will fail the legality check as before.
	///
	/// Intentionally NOT mapping find_on_page → it must remain illegal in direct-agent mode.
	///
	/// Canonical mappings (all inputs are already lowercased):
	///   scroll_small / scroll_down / scroll_up / page_down → scroll
	///   click                                               → click_element
	///   type                                                → type_text
	///   key_press / press                                   → press_key
	///   present_answer / give_answer / summarize            → answer
	///   finish / done / complete / task_done                → stop_success
	///   observe / look / read_screen                        → observe_screen
	nonisolated static func normalizeActionAlias(_ lower: String) -> String {
		switch lower {
		// Scroll aliases
		case "scroll_small", "scroll_down", "scroll_up", "page_down",
		     "scroll_page", "page_scroll":                                 return "scroll"
		// Click aliases
		case "click":                                                       return "click_element"
		// Type aliases
		case "type", "type_input", "input_text", "enter_text":             return "type_text"
		// Key aliases
		case "key_press", "press", "press_key_combination":                return "press_key"
		// Answer aliases — model may emit present_answer from its training priors
		case "present_answer", "give_answer", "provide_answer",
		     "present_result", "report", "summarize":                      return "answer"
		// Success stop aliases
		case "finish", "done", "complete", "completed",
		     "task_complete", "task_done":                                  return "stop_success"
		// Observe aliases
		case "observe", "look", "read_screen", "capture":                  return "observe_screen"
		default:                                                            return lower
		}
	}

	// MARK: - Direct Agent Mode

	/// Observe → think → act loop decision engine for the direct-agent runtime.
	/// Uses phi4-mini to pick the next action from a bounded, computer-wide legal set.
	/// Browser-specific actions (find_on_page, extract_facts, scroll_small, …) are
	/// explicitly excluded from both the prompt vocabulary and the legal menu.
	private func directAgentDecide(
		goal: String,
		stepIndex: Int,
		maxSteps: Int,
		legalActions: Set<AgenticNextAction>,
		observations: [AgenticObservation],
		llmCallsUsed: Int,
		llmCallsBudget: Int,
		explorationMemory: ExplorationMemory?
	) async -> AgenticLoopDecision {
		print("[DirectAgentLoop] step=\(stepIndex) started")

		// 1. Force initial observation when no screen state exists yet.
		if observations.isEmpty && legalActions.contains(.observe_screen) {
			return AgenticLoopDecision(
				nextAction: .observe_screen,
				reason: "Initial observation to establish context",
				confidence: 1.0,
				source: .heuristic
			)
		}

		let latestObs = observations.last
		let ocrRaw = latestObs?.ocrExcerpt    ?? "none"
		let axRaw  = latestObs?.contextSummary ?? "none"
		let window = latestObs?.windowTitle    ?? "unknown"
		let app    = latestObs?.activeApp      ?? "unknown"

		// Extract VLM caption from contextSummary where it's stored as
		// "vlm_caption: <text> (category=<cat>)". Surface it first in the prompt
		// so the model reasons from visual grounding before OCR text.
		let (vlmCaption, axClean) = Self.extractVLMCaption(from: axRaw)

		// Task 3: Actionable UI Detection
		let analysis = ActionableUIAnalyzer.analyze(ocr: ocrRaw, contextSummary: axRaw, vlmCaption: vlmCaption, goal: goal)
		let actionableControlsExist = !analysis.actionableControls.isEmpty

		let clicksMade = explorationMemory?.clickedControls.count ?? 0
		let scrollCount = explorationMemory?.scrollHistory.count ?? 0
		let interactionAttempts = clicksMade + scrollCount
		let hasUnexploredScroll = scrollCount == 0

		// Task 1: Hard Planning Policy Layer
		let lowerGoal = goal.lowercased()
		let referencesInteraction = lowerGoal.contains("find") || lowerGoal.contains("open") || lowerGoal.contains("navigate") || lowerGoal.contains("click") || lowerGoal.contains("search") || lowerGoal.contains("go to") || lowerGoal.contains("look up") || lowerGoal.contains("install") || lowerGoal.contains("download")
		let pageNotFullyExplored = scrollCount < 2

		var isAnswerIllegal = false
		if actionableControlsExist && pageNotFullyExplored && (clicksMade == 0 || referencesInteraction) {
			isAnswerIllegal = true
		}

		// Task 2: Answer Readiness Gate
		let gateResult = AnswerReadinessGate.shouldAllowAnswer(
			interactionAttempts: interactionAttempts,
			explorationScore: analysis.explorationScore,
			unexploredActionableControlsCount: analysis.actionableControls.count,
			hasUnexploredScroll: hasUnexploredScroll
		)

		var stepLegalActions = legalActions
		if isAnswerIllegal || !gateResult.allowed {
			stepLegalActions.remove(.answer)
			stepLegalActions.remove(.stop_success)
			stepLegalActions.remove(.present_answer)
			stepLegalActions.remove(.summarize_observation)
		}

		// Task 5: Force Click Path Exercise (Interaction Pressure)
		var appliedPressure = false
		let repeatedObserveAnswer = (explorationMemory?.observedWindows.count ?? 0) >= 2
		let noClicksYet = clicksMade == 0

		if actionableControlsExist && noClicksYet && repeatedObserveAnswer {
			print("[InteractionPressure] applied=yes reason=no_clicks_yet")
			appliedPressure = true
			stepLegalActions.remove(.observe_screen)
			stepLegalActions.remove(.observe_once)
		}

		// Prevent observe-observe loop (Task 6)
		if let isLooping = explorationMemory?.isStuckInObserveLoop(), isLooping {
			stepLegalActions.remove(.observe_screen)
			stepLegalActions.remove(.observe_once)
			if actionableControlsExist {
				stepLegalActions.remove(.answer)
				stepLegalActions.remove(.stop_success)
			}
		}

		// 2. Model-driven "Think" phase if LLM budget remains.
		if llmCallsUsed < llmCallsBudget {
			// Build the canonical legal-action list to show in the prompt.
			let legalList = stepLegalActions.map { $0.rawValue }.sorted().joined(separator: "\n  ")

			// Task 4: Interaction Motivation Score
			let interactionPotentialScore = actionableControlsExist ? (analysis.explorationScore * 100.0) : 0.0

			let prompt = """
			You are operating a REAL desktop computer.
			Your primary objective is to INTERACT with software and navigate interfaces.
			Do NOT answer prematurely.
			Prefer interacting with the UI over summarizing it.

			GOAL: \(goal)
			Step \(stepIndex)/\(maxSteps) | App: \(app) | Window: \(window)

			[VISUAL — What the screen shows right now]
			\(vlmCaption.isEmpty ? "(VLM not available — rely on OCR below)" : vlmCaption)

			[OCR — Raw text extracted from screen]
			\(ocrRaw.prefix(900))

			[AX — Accessibility tree excerpt]
			\(axClean.prefix(400))

			[OPERATOR STATE]
			Interaction Potential Score: \(String(format: "%.1f", interactionPotentialScore))/100
			Exploration Status: Scrolls=\(scrollCount), Clicks=\(clicksMade)
			Unexplored Actionable Controls: \(analysis.actionableControls.count)
			Active Operator Motivation: \(isAnswerIllegal ? "HIGH EXPLORATION MODE (Answer is blocked/illegal right now)" : "BALANCED")

			\(appliedPressure ? """
			[INTERACTION PRESSURE — CRITICAL]
			You have observed the screen multiple times but have NOT clicked any elements yet.
			There are visible actionable controls on screen: \(analysis.actionableControls.prefix(3).map { "\"\($0.label)\"" }.joined(separator: ", ")).
			Summarizing or observing again is blocked. You MUST choose click_element to interact and progress.
			""" : "")

			VALID ACTIONS (use ONLY one of these):
			  \(legalList)

			OPERATOR RULES:
			1. PREFER INTERACTION: You must actively navigate, scroll, type, and click elements to locate information. Do NOT try to answer based on static/partial screens if navigation/interaction is possible.
			2. CLICKING IS EXPECTED: If there are buttons, links, search bars, tabs, or menus, you are expected to click them to explore and reveal information.
			3. NO PREMATURE ANSWERS: The "answer" action is a LAST RESORT. Only use it when you have fully verified the information by interacting, or there are absolutely no interactable elements left.
			4. SCROLL TO REVEAL: Use "scroll" if there is potentially more content below the fold.
			5. REQUIRED FIELDS:
			   - click_element REQUIRES a "target" field with the visible element label/text to click.
			   - type_text REQUIRES a "text" field to type into the focused element.
			   - press_key REQUIRES a "key" field (e.g. "return", "escape", "cmd+a").
			6. NEVER click: buy, purchase, checkout, delete, sign in, install, submit payment.

			GOOD EXAMPLE OF OPERATOR BEHAVIOR:
			Goal: Find the pricing of Premium Plan on an app
			- Step 1: "observe_screen" (read the initial state)
			- Step 2: "click_element" with target "Pricing" (to navigate to the pricing page)
			- Step 3: "observe_screen" (observe the new page)
			- Step 4: "scroll" (scroll down to see the premium plan cost)
			- Step 5: "observe_screen" (observe the scrolled content showing the price)
			- Step 6: "answer" with the price (success!)

			BAD EXAMPLE of summarizes-only (FORBIDDEN):
			- Step 1: "observe_screen" (sees home page)
			- Step 2: "answer" stating "I see the home page, pricing is not visible" (FAIL! You should have clicked!)

			Respond with JSON only:
			{"thought":"<one sentence describing your interaction plan>","action":"<valid action>","target":"<label if click>","text":"<if type>","key":"<if key>","reason":"<one sentence explaining why this interaction helps>","confidence":0.9}
			"""

			print("[DirectAgentThink] goal=\"\(goal.prefix(60))\" step=\(stepIndex)")

			do {
				let response = try await withTimeout(seconds: 7.0) {
					try await LocalAIClient.shared.generate(
						prompt: prompt,
						model: "phi4-mini",
						numPredict: 300,
						temperature: 0.1,
						purpose: "direct_agent_think"
					)
				}

				if let data = response.data(using: .utf8),
				   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				   let actionStr = json["action"] as? String {

					let trimmed    = actionStr.trimmingCharacters(in: .whitespacesAndNewlines)
					let lower      = trimmed.lowercased()

					// Normalize aliases BEFORE legality check.
					print("[DirectAgentNormalizationPath] path=main_think")
					let normalized = Self.normalizeActionAlias(lower)
					print("[DirectAgentActionNormalization] proposed=\"\(lower)\" normalized=\"\(normalized)\"")

					let nextAction = AgenticNextAction(rawValue: normalized) ?? AgenticNextAction(rawValue: trimmed)
					let isLegal    = nextAction.map { stepLegalActions.contains($0) } ?? false

					let clickTarget = (json["target"] as? String)
						.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
					let typeText    = json["text"] as? String
					let keyName     = json["key"]  as? String
					let thought     = json["thought"] as? String ?? ""

					print("[DirectAgentActionValidation] proposed=\(trimmed) normalized=\(normalized) legal=\(isLegal) target=\(clickTarget ?? "nil") text=\(typeText ?? "nil") key=\(keyName ?? "nil")")

					if let action = nextAction, isLegal {

						// click_element MUST carry a non-empty target.
						if action == .click_element && clickTarget == nil {
							print("[DirectAgentActionValidation] rejected reason=missing_click_target retry=yes")
							return await repairMissingClickTarget(
								goal: goal, window: window, ocr: ocrRaw, thought: thought,
								legalActions: stepLegalActions
							)
						}

						// Context sufficiency guard (TASK 5):
						if action == .stop_missing_context {
							let ocrChars  = latestObs?.ocrExcerpt?.count ?? 0
							let axCharsN  = axClean.count
							let vlmChars  = vlmCaption.count
							let hasEnoughOCR = ocrChars > 300
							let hasEnoughVLM = vlmChars > 40
							let hasEnoughAX  = axCharsN > 150
							if hasEnoughOCR || hasEnoughVLM || hasEnoughAX {
								let override: AgenticNextAction = stepLegalActions.contains(.answer) ? .answer : .observe_screen
								print("[DirectAgentContextGuard] stop_missing_context overridden to=\(override.rawValue) reason=sufficient_context ocr=\(ocrChars) vlm=\(vlmChars) ax=\(axCharsN)")
								return AgenticLoopDecision(
									nextAction:  override,
									reason:      "Sufficient context available (ocr=\(ocrChars) vlm=\(vlmChars) ax=\(axCharsN)) — overriding stop_missing_context",
									confidence:  0.80,
									source:      .heuristic
								)
							}
						}

						print("[DirectAgentThink] thought=\"\(thought.prefix(100))\" action=\(action.rawValue)")

						// Visual Grounding Activation Telemetry (Task 8)
						let clickCandidate = action == .click_element ? "yes" : "no"
						let blockedReasonVal = (action == .answer || action == .stop_success) ? "none" : (isAnswerIllegal ? "interaction_required" : "none")
						let actionableControlsStr = analysis.actionableControls.prefix(3).map { $0.label }.joined(separator: ", ")
						print("[InteractionDecision] click_candidate=\(clickCandidate) blocked_reason=\(blockedReasonVal) exploration_score=\(String(format: "%.2f", analysis.explorationScore)) actionable_controls=\(actionableControlsStr)")

						return AgenticLoopDecision(
							nextAction:  action,
							reason:      "Model: \(thought)",
							confidence:  (json["confidence"] as? Double) ?? 0.90,
							source:      .model,
							clickTarget: clickTarget,
							typeText:    typeText,
							keyName:     keyName
						)

					} else {
						// TASK 3 — illegal action: attempt one repair retry before falling back.
						let illegalName = normalized.isEmpty ? trimmed : normalized
						print("[DirectAgentActionRepair] retry=yes illegal_action=\"\(illegalName)\"")
						return await repairIllegalAction(
							illegalAction: illegalName,
							legalActions:  stepLegalActions,
							goal: goal, window: window, ocr: ocrRaw
						)
					}
				}
			} catch {
				print("[DirectAgentThink] model_failed reason=\(error)")
			}
		}

		// 3. Heuristic fallback — reached when model budget is exhausted or model call failed.
		let heuristicAction: AgenticNextAction
		let heuristicReason: String
		let heuristicConf: Double

		if stepIndex <= 1 {
			heuristicAction = .observe_screen
			heuristicReason = "Initial observation"
			heuristicConf   = 1.0
		} else if stepIndex == 2 && stepLegalActions.contains(.scroll) {
			heuristicAction = .scroll
			heuristicReason = "Scroll to reveal more content"
			heuristicConf   = 0.90
		} else if stepLegalActions.contains(.click_element) && actionableControlsExist {
			heuristicAction = .click_element
			heuristicReason = "Actionable controls visible — proceed to click"
			heuristicConf   = 0.85
		} else {
			heuristicAction = .answer
			heuristicReason = "Sufficient observations gathered"
			heuristicConf   = 0.85
		}

		let safeAction = stepLegalActions.contains(heuristicAction)
			? heuristicAction
			: (stepLegalActions.contains(.answer) ? .answer : .stop_success)

		print("[AgentExecutor] next_action=\(safeAction.rawValue) source=heuristic")

		// Visual Grounding Activation Telemetry (Task 8)
		let clickCandidate = safeAction == .click_element ? "yes" : "no"
		let blockedReasonVal = (safeAction == .answer || safeAction == .stop_success) ? "none" : (isAnswerIllegal ? "interaction_required" : "none")
		let actionableControlsStr = analysis.actionableControls.prefix(3).map { $0.label }.joined(separator: ", ")
		print("[InteractionDecision] click_candidate=\(clickCandidate) blocked_reason=\(blockedReasonVal) exploration_score=\(String(format: "%.2f", analysis.explorationScore)) actionable_controls=\(actionableControlsStr)")

		return AgenticLoopDecision(
			nextAction: safeAction,
			reason:     "Direct Agent heuristic: \(heuristicReason)",
			confidence: heuristicConf,
			source:     .heuristic
		)
	}

	// MARK: - Repair helpers

	/// Repair an illegal model action by asking the model once to pick a legal alternative.
	///
	/// - Returns: a legal `AgenticLoopDecision`, or `observe_screen` on failure.
	///
	/// Logs: `[DirectAgentActionRepair] retry_succeeded action="..."` or
	///       `[DirectAgentActionRepair] retry_failed fallback=observe_screen`
	private func repairIllegalAction(
		illegalAction: String,
		legalActions:  Set<AgenticNextAction>,
		goal:   String,
		window: String,
		ocr:    String
	) async -> AgenticLoopDecision {
		print("[DirectAgentNormalizationPath] path=illegal_repair")
		print("[DirectAgentActionRepair] started reason=illegal_action illegal=\"\(illegalAction)\"")

		let legalList = legalActions.map { $0.rawValue }.sorted().joined(separator: ", ")

		let repairPrompt = """
		Your previous response chose "\(illegalAction)" which is NOT a valid action.

		Valid actions for this session (ONLY these):
		  \(legalList)

		Common mistakes to avoid:
		  "find_on_page"  is not available — use observe_screen + scroll instead
		  "scroll_small"  is not available — use "scroll"
		  "extract_facts" is not available — use "answer" when ready

		Goal: \(goal)
		Window: \(window)
		OCR: \(ocr.prefix(500))

		Respond with JSON using ONLY a valid action from the list above:
		{"thought":"...","action":"<valid action>","reason":"...","confidence":0.0}
		"""

		do {
			let repairResponse = try await withTimeout(seconds: 7.0) {
				try await LocalAIClient.shared.generate(
					prompt: repairPrompt,
					model: "phi4-mini",
					numPredict: 160,
					temperature: 0.1,
					purpose: "direct_agent_repair"
				)
			}
			print("[DirectAgentActionRepair] raw_retry_response=\"\(repairResponse.prefix(200).replacingOccurrences(of: "\n", with: " "))\"")

			if let data   = repairResponse.data(using: .utf8),
			   let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			   let actStr = json["action"] as? String {
				let lower      = actStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
				print("[DirectAgentNormalizationPath] path=illegal_repair_response")
				let normalized = Self.normalizeActionAlias(lower)
				print("[DirectAgentActionNormalization] proposed=\"\(lower)\" normalized=\"\(normalized)\"")
				if let repaired = AgenticNextAction(rawValue: normalized),
				   legalActions.contains(repaired) {
					let repairTarget = (json["target"] as? String)
						.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
					let repairThought = json["thought"] as? String ?? ""
					print("[DirectAgentActionRepair] retry_succeeded action=\"\(repaired.rawValue)\"")
					return AgenticLoopDecision(
						nextAction:  repaired,
						reason:      "Model (repair): \(repairThought)",
						confidence:  (json["confidence"] as? Double) ?? 0.75,
						source:      .model,
						clickTarget: repairTarget,
						typeText:    json["text"] as? String,
						keyName:     json["key"]  as? String
					)
				} else {
					print("[DirectAgentActionRepair] retry_failed reason=repaired_action_still_illegal normalized=\"\(normalized)\"")
				}
			} else {
				print("[DirectAgentActionRepair] retry_failed reason=unparseable_repair_response")
			}
		} catch {
			print("[DirectAgentActionRepair] retry_failed reason=model_error detail=\"\(error)\"")
		}

		let fallback = legalActions.contains(.observe_screen) ? AgenticNextAction.observe_screen : .answer
		print("[DirectAgentActionRepair] retry_failed fallback=\(fallback.rawValue)")
		return AgenticLoopDecision(
			nextAction:  fallback,
			reason:      "Illegal action '\(illegalAction)' could not be repaired — falling back",
			confidence:  0.60,
			source:      .heuristic
		)
	}

	/// Repair a `click_element` response that is missing a `target` field.
	///
	/// Asks the model once more with an explicit prompt. On failure falls back to `observe_screen`.
	///
	/// Logs: `[DirectAgentActionRepair] retry_succeeded action="click_element" target="..."`
	///       `[DirectAgentActionRepair] retry_failed fallback=observe_screen`
	private func repairMissingClickTarget(
		goal:         String,
		window:       String,
		ocr:          String,
		thought:      String,
		legalActions: Set<AgenticNextAction>
	) async -> AgenticLoopDecision {
		print("[DirectAgentNormalizationPath] path=click_repair")
		print("[DirectAgentActionRepair] started reason=missing_click_target")

		let repairPrompt = """
		Your previous response chose "click_element" but omitted the required "target" field.
		"target" is MANDATORY — it must name the visible label/text of the element to click \
		(e.g. "Search", "Download", "Next page link").

		Respond again with the corrected JSON. You MUST include "target" this time.

		Goal: \(goal)
		Window: \(window)
		OCR context (look here for visible element labels):
		\(ocr.prefix(700))

		{
		  "thought": "one sentence",
		  "action": "click_element",
		  "target": "<visible label of the element to click>",
		  "reason": "one sentence",
		  "confidence": 0.0
		}
		"""

		do {
			let retryResponse = try await withTimeout(seconds: 7.0) {
				try await LocalAIClient.shared.generate(
					prompt: repairPrompt,
					model: "phi4-mini",
					numPredict: 180,
					temperature: 0.1,
					purpose: "direct_agent_click_repair"
				)
			}
			// Log raw repair response before parsing so we can debug whether model
			// responded correctly or parser is dropping the target field.
			print("[DirectAgentActionRepair] raw_retry_response=\"\(retryResponse.prefix(200).replacingOccurrences(of: "\n", with: " "))\"")

			if let data        = retryResponse.data(using: .utf8),
			   let json        = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			   let retryTarget = json["target"] as? String,
			   !retryTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				let retryThought = json["thought"] as? String ?? thought
				print("[DirectAgentActionRepair] retry_succeeded action=\"click_element\" target=\"\(retryTarget.prefix(60))\"")
				return AgenticLoopDecision(
					nextAction:  .click_element,
					reason:      "Model (repair): \(retryThought)",
					confidence:  (json["confidence"] as? Double) ?? 0.80,
					source:      .model,
					clickTarget: retryTarget
				)
			} else {
				// JSON parsed but target still missing or empty.
				print("[DirectAgentActionRepair] retry_failed reason=target_still_missing_after_repair")
			}
		} catch {
			print("[DirectAgentActionRepair] retry_failed reason=model_error detail=\"\(error)\"")
		}

		let fallback = legalActions.contains(.observe_screen) ? AgenticNextAction.observe_screen : .answer
		print("[DirectAgentActionRepair] retry_failed fallback=\(fallback.rawValue)")
		return AgenticLoopDecision(
			nextAction:  fallback,
			reason:      "click_element had no target after repair retry — falling back",
			confidence:  0.65,
			source:      .heuristic
		)
	}

	// MARK: - Heuristic

	private func heuristic(
		goal: String,
		workflow: String,
		observations: [AgenticObservation],
		extractedFacts: [String],
		stepIndex: Int,
		maxSteps: Int,
		legalActions: Set<AgenticNextAction>,
		forceObserveNext: Bool,
		semanticReadiness: SemanticReadiness?,
		evidenceState: AgenticEvidenceState? = nil,
		evidenceObservations: [AgenticEvidenceObservation] = [],
		priorActions: [String] = [],
		ineffectiveControlCount: Int = 0,
		entities: [GroundedSemanticEntity] = [],
		facts: [StructuredFact] = []
	) -> AgenticLoopDecision {

		// 0. Post-control forced observation
		if forceObserveNext && legalActions.contains(.observe_once) {
			return AgenticLoopDecision(
				nextAction: .observe_once,
				reason: "Forced observe after control action — read updated page context",
				confidence: 0.98,
				source: .heuristic,
				findQuery: nil
			)
		}

		// 1. No observations yet → observe first
		if observations.isEmpty {
			if legalActions.contains(.observe_once) {
				return AgenticLoopDecision(
					nextAction: .observe_once,
					reason: "No observations yet — read current context first",
					confidence: 0.95,
					source: .heuristic,
					findQuery: nil
				)
			}
		}

		let latestObs = observations.last
		let browserGoal = isBrowserProductGoal(goal: goal, workflow: workflow)
		let stepsRemainingNow = maxSteps - stepIndex
		let budgetExhausted = stepsRemainingNow <= 1

		// 1.5 Phase 4S/4T — Evidence-first / Quality-Gated Loop Decisions
		if let ev = evidenceState {
			if ev.allRequiredSatisfied {
				// Quality Gate Check (Phase 4T)
				let quality = EvidenceQualityGate.evaluate(
					goal: goal,
					state: ev,
					observations: evidenceObservations,
					entities: entities,
					facts: facts
				)

				let isCompareGoal = AgenticEvidenceRequirementsInferrer.classifyFamily(goal: goal.lowercased(), workflow: "") == .compare
				let hasValidComparison = !isCompareGoal || ComparisonEvidenceValidator.validate(state: ev, observations: evidenceObservations, entities: entities, facts: facts).isValid

				if quality.overallScore < EvidenceQualityGate.overallScoreThreshold {
					print("[LoopTermination] requested=evidence_satisfied allowed=no reason=low_evidence_quality")
					if !budgetExhausted {
						if legalActions.contains(.scroll_small) {
							return AgenticLoopDecision(
								nextAction: .scroll_small,
								reason: "Evidence satisfied but blocked by Quality Gate: low overall score (score=\(String(format: "%.2f", quality.overallScore))) — try scroll_small to improve",
								confidence: 0.90,
								source: .heuristic,
								findQuery: nil
							)
						} else if legalActions.contains(.observe_once) {
							return AgenticLoopDecision(
								nextAction: .observe_once,
								reason: "Evidence satisfied but blocked by Quality Gate: low overall score — observe again",
								confidence: 0.90,
								source: .heuristic,
								findQuery: nil
							)
						}
					}
				} else if !hasValidComparison {
					print("[LoopTermination] requested=evidence_satisfied allowed=no reason=invalid_comparison_candidates")
					if !budgetExhausted {
						if legalActions.contains(.scroll_small) {
							return AgenticLoopDecision(
								nextAction: .scroll_small,
								reason: "Evidence satisfied but blocked by Quality Gate: invalid comparison candidates — try scroll_small to find another candidate",
								confidence: 0.90,
								source: .heuristic,
								findQuery: nil
							)
						}
					}
				} else {
					print("[LoopTermination] requested=evidence_satisfied allowed=yes reason=quality_gate_passed")

					// Evidence satisfied and quality gate passed! extract/summarize/present
					if extractedFacts.isEmpty && legalActions.contains(.extract_facts) {
						print("[AgenticDecision] mode=evidence_satisfied action=extract_facts")
						return AgenticLoopDecision(
							nextAction: .extract_facts,
							reason: "Evidence satisfied — proceed to extract facts",
							confidence: 0.95,
							source: .heuristic,
							findQuery: nil
						)
					} else if legalActions.contains(.summarize_observation) && !extractedFacts.contains(where: { $0.hasPrefix("Summary:") }) {
						print("[AgenticDecision] mode=evidence_satisfied action=summarize_observation")
						return AgenticLoopDecision(
							nextAction: .summarize_observation,
							reason: "Evidence satisfied — summarize observations",
							confidence: 0.93,
							source: .heuristic,
							findQuery: nil
						)
					} else if legalActions.contains(.present_answer) {
						print("[AgenticDecision] mode=evidence_satisfied action=present_answer")
						return AgenticLoopDecision(
							nextAction: .present_answer,
							reason: "Evidence satisfied — present final answer",
							confidence: 0.95,
							source: .heuristic,
							findQuery: nil
						)
					}
				}
			} else if budgetExhausted {
				// Budget exhausted with missing evidence — present useful partial answer
				if legalActions.contains(.present_answer) {
					print("[AgenticDecision] mode=partial_budget_exhausted action=present_answer")
					return AgenticLoopDecision(
						nextAction: .present_answer,
						reason: "Budget exhausted with missing evidence: \(ev.missing.map { $0.rawValue }.joined(separator: ",")) — present partial answer",
						confidence: 0.92,
						source: .heuristic,
						findQuery: nil
					)
				}
			} else if ev.shouldGatherMore {
				// If evidence is missing and safe actions remain, gather!
				let missingKind = ev.firstMissing?.kind ?? .unknown
				let missingList = ev.missing.map { $0.rawValue }.joined(separator: ",")
				
				let queryPlan = Self.determineEvidenceFindQuery(
					missingKind: missingKind,
					evidenceObservations: evidenceObservations,
					goal: goal
				)
				let preferredQuery = queryPlan.query

				let isLastFind = (priorActions.last == AgenticNextAction.find_on_page.rawValue)
				let isLastScroll = (priorActions.last == AgenticNextAction.scroll_small.rawValue)
				let lastControlIneffective = (ineffectiveControlCount > 0) && (isLastFind || isLastScroll)

				let findUsed = priorActions.contains(AgenticNextAction.find_on_page.rawValue)
				
				let preferredAction: AgenticNextAction
				let reason: String
				let query: String?

				if lastControlIneffective {
					// Previous control action was ineffective. Switch strategies or safe action!
					if isLastScroll && missingKind == .comparisonCandidate && legalActions.contains(.find_on_page) {
						preferredAction = .find_on_page
						let strategyQuery = "similar"
						query = strategyQuery
						reason = "Previous scroll_small was ineffective — try find_on_page to search for similar comparison candidates"
						print("[AgenticDecision] mode=strategy_switch previous=scroll_small ineffective=yes next=find_on_page missing=comparison_candidate")
						print("[FindQuery] kind=comparison_candidate query=\(strategyQuery) source=evidence_requirement")
					} else if isLastFind && legalActions.contains(.scroll_small) {
						preferredAction = .scroll_small
						reason = "Previous find_on_page was ineffective — try scroll_small to reveal more content"
						query = nil
					} else if isLastScroll && legalActions.contains(.find_on_page) && !findUsed {
						preferredAction = .find_on_page
						reason = "Previous scroll_small was ineffective — try find_on_page to search"
						query = preferredQuery
					} else {
						// Ineffective control safety fallback: do not keep control-looping blindly
						if extractedFacts.isEmpty && legalActions.contains(.extract_facts) {
							preferredAction = .extract_facts
							reason = "Previous controls ineffective — extract what facts we have"
							query = nil
						} else if legalActions.contains(.observe_once) {
							preferredAction = .observe_once
							reason = "Previous controls ineffective — observe again"
							query = nil
						} else {
							preferredAction = .present_answer
							reason = "Previous controls ineffective — present partial answer"
							query = nil
						}
					}
				} else if findUsed && legalActions.contains(.scroll_small) {
					// find_on_page already used, prefer scroll down to find next candidate
					preferredAction = .scroll_small
					reason = "find_on_page already used — prefer scroll_small to reveal lower-page content"
					query = nil
				} else {
					let recommended = ev.recommendedAction
					if recommended == .findOnPage && legalActions.contains(.find_on_page) {
						preferredAction = .find_on_page
						reason = "Evidence gate: missing \(missingKind.rawValue) — search for \(preferredQuery)"
						query = preferredQuery
					} else if recommended == .scrollSmall && legalActions.contains(.scroll_small) {
						preferredAction = .scroll_small
						reason = "Evidence gate: missing \(missingKind.rawValue) — scroll down to revealspecs/candidates"
						query = nil
					} else if legalActions.contains(.find_on_page) {
						preferredAction = .find_on_page
						reason = "Evidence gate (fallback): missing \(missingKind.rawValue) — search for \(preferredQuery)"
						query = preferredQuery
					} else if legalActions.contains(.scroll_small) {
						preferredAction = .scroll_small
						reason = "Evidence gate (fallback): missing \(missingKind.rawValue) — scroll down"
						query = nil
					} else {
						if extractedFacts.isEmpty && legalActions.contains(.extract_facts) {
							preferredAction = .extract_facts
							reason = "Evidence gate: missing \(missingKind.rawValue) but no control actions left — extract facts"
							query = nil
						} else if legalActions.contains(.observe_once) {
							preferredAction = .observe_once
							reason = "Evidence gate: missing \(missingKind.rawValue) — observe again"
							query = nil
						} else {
							preferredAction = .present_answer
							reason = "Evidence gate: missing \(missingKind.rawValue) — present partial answer"
							query = nil
						}
					}
				}

				print("[AgenticDecision] mode=evidence_gathering missing=\(missingKind.rawValue) action=\(preferredAction.rawValue)")
				return AgenticLoopDecision(
					nextAction: preferredAction,
					reason: reason,
					confidence: 0.92,
					source: .heuristic,
					findQuery: query
				)
			}
		}

		// 2. Quality-aware control routing for browser/product/review goals.
		//    metadata_only or weak quality means no real page text (no selectedText, no ocrExcerpt).
		//    For browser goals: do NOT extract_facts yet — try control actions first.
		if let obs = latestObs, obs.quality.requiresControlForBrowserGoal, browserGoal {
			if legalActions.contains(.find_on_page) {
				let query = AgenticControlPolicy.determineFindQuery(goal: goal)
				print("[AgenticControlDecision] selected_control action=find_on_page reason=quality_\(obs.quality.rawValue)_browser_goal query=\(query)")
				return AgenticLoopDecision(
					nextAction: .find_on_page,
					reason: "Quality \(obs.quality.rawValue) — no real page text for browser/product goal; search for relevant content before extracting",
					confidence: 0.93,
					source: .heuristic,
					findQuery: query
				)
			}
			if legalActions.contains(.scroll_small) {
				print("[AgenticControlDecision] selected_control action=scroll_small reason=quality_\(obs.quality.rawValue)_browser_goal find_unavailable=true")
				return AgenticLoopDecision(
					nextAction: .scroll_small,
					reason: "Quality \(obs.quality.rawValue) — no real page text for browser/product goal; scroll to reveal content",
					confidence: 0.88,
					source: .heuristic,
					findQuery: nil
				)
			}
			// No control available — must stop; don't extract from metadata for browser goal
			print("[AgenticControlDecision] skipped_control reason=no_control_in_menu quality=\(obs.quality.rawValue) browser_goal=true → stop_missing_context")
			return AgenticLoopDecision(
				nextAction: .stop_missing_context,
				reason: "Quality \(obs.quality.rawValue) for browser/product goal — no usable page text and no control actions available in policy menu",
				confidence: 0.95,
				source: .heuristic,
				findQuery: nil
			)
		}

		// 3–4. No usable content in latest observation (non-browser goal, or metadata_only/weak non-browser)
		if let obs = latestObs, !obs.hasUsableContent {
			if legalActions.contains(.find_on_page) {
				let query = AgenticControlPolicy.determineFindQuery(goal: goal)
				print("[AgenticControlDecision] selected_control action=find_on_page reason=no_usable_content quality=\(obs.quality.rawValue) query=\(query)")
				return AgenticLoopDecision(
					nextAction: .find_on_page,
					reason: "No usable page text visible — search page for relevant terms",
					confidence: 0.88,
					source: .heuristic,
					findQuery: query
				)
			}
			if legalActions.contains(.scroll_small) {
				print("[AgenticControlDecision] selected_control action=scroll_small reason=no_usable_content quality=\(obs.quality.rawValue)")
				return AgenticLoopDecision(
					nextAction: .scroll_small,
					reason: "No usable page text visible — scroll to reveal more page content",
					confidence: 0.82,
					source: .heuristic,
					findQuery: nil
				)
			}
			print("[AgenticControlDecision] skipped_control reason=no_control_in_menu quality=\(obs.quality.rawValue) → stop_missing_context")
			return AgenticLoopDecision(
				nextAction: .stop_missing_context,
				reason: "No usable context and no control actions available",
				confidence: 0.95,
				source: .heuristic,
				findQuery: nil
			)
		}

		// 5. Goal implies reviews/ratings/specs and latest obs lacks them → find_on_page
		if let obs = latestObs, obs.hasUsableContent, legalActions.contains(.find_on_page) {
			let missingTarget = goalRequiresMissingContent(goal: goal, observation: obs)
			if let target = missingTarget {
				let query = AgenticControlPolicy.determineFindQuery(goal: goal)
				print("[AgenticControlDecision] selected_control action=find_on_page reason=missing_\(target) quality=\(obs.quality.rawValue) query=\(query)")
				return AgenticLoopDecision(
					nextAction: .find_on_page,
					reason: "Goal needs \(target) but not visible in current view — use browser find",
					confidence: 0.87,
					source: .heuristic,
					findQuery: query
				)
			}
		}

		// 6. Find used but still missing target; try scroll
		if let obs = latestObs, obs.hasUsableContent, legalActions.contains(.scroll_small) {
			let findAlreadyUsed = !legalActions.contains(.find_on_page)
			let missingTarget = goalRequiresMissingContent(goal: goal, observation: obs)
			if findAlreadyUsed, missingTarget != nil {
				print("[AgenticControlDecision] selected_control action=scroll_small reason=missing_target_after_find quality=\(obs.quality.rawValue)")
				return AgenticLoopDecision(
					nextAction: .scroll_small,
					reason: "Find used but target content still not visible — scroll to reveal more",
					confidence: 0.83,
					source: .heuristic,
					findQuery: nil
				)
			}
		}

		// 7. Have real page content but no extracted facts → extract
		//    Only reached when quality is usable or rich (hasUsableContent = true).
		if let obs = latestObs, obs.hasUsableContent, extractedFacts.isEmpty {
			if legalActions.contains(.extract_facts) {
				// Log if control was skipped because quality was sufficient
				if obs.quality >= .usable {
					print("[AgenticControlDecision] skipped_control reason=quality_sufficient_for_extraction quality=\(obs.quality.rawValue)")
				}
				return AgenticLoopDecision(
					nextAction: .extract_facts,
					reason: "Real page content available (quality=\(obs.quality.rawValue)) — extract key facts relevant to goal",
					confidence: 0.88,
					source: .heuristic,
					findQuery: nil
				)
			}
		}

		// 7.5 Semantic readiness quality gate continuation check
		if let readiness = semanticReadiness, !readiness.readyForFinalAnswer {
			if legalActions.contains(.find_on_page) {
				let query = AgenticControlPolicy.determineFindQuery(goal: goal)
				return AgenticLoopDecision(
					nextAction: .find_on_page,
					reason: "Semantic readiness is LOW (\(readiness.reason)) — search for more context using find",
					confidence: 0.90,
					source: .heuristic,
					findQuery: query
				)
			}
			if legalActions.contains(.scroll_small) {
				return AgenticLoopDecision(
					nextAction: .scroll_small,
					reason: "Semantic readiness is LOW (\(readiness.reason)) — scroll page to find more specifications or price",
					confidence: 0.85,
					source: .heuristic,
					findQuery: nil
				)
			}
			if legalActions.contains(.present_answer) {
				return AgenticLoopDecision(
					nextAction: .present_answer,
					reason: "Semantic readiness is LOW and no perception actions remain — presenting partial answer",
					confidence: 0.95,
					source: .heuristic,
					findQuery: nil
				)
			}
		}

		// 8. Near step budget → present
		let stepsRemaining = maxSteps - stepIndex
		if stepsRemaining <= 1 {
			if legalActions.contains(.present_answer) {
				return AgenticLoopDecision(
					nextAction: .present_answer,
					reason: "Near step budget (\(stepsRemaining) remaining) — present extracted facts",
					confidence: 0.92,
					source: .heuristic,
					findQuery: nil
				)
			}
		}

		// 9. Have 2+ facts → summarize
		if extractedFacts.count >= 2 {
			if legalActions.contains(.summarize_observation) {
				return AgenticLoopDecision(
					nextAction: .summarize_observation,
					reason: "Have \(extractedFacts.count) facts — summarize into coherent answer",
					confidence: 0.85,
					source: .heuristic,
					findQuery: nil
				)
			}
		}

		// 10. Have 1 fact → present
		if !extractedFacts.isEmpty {
			if legalActions.contains(.present_answer) {
				return AgenticLoopDecision(
					nextAction: .present_answer,
					reason: "Have \(extractedFacts.count) fact(s) — present answer to user",
					confidence: 0.80,
					source: .heuristic,
					findQuery: nil
				)
			}
		}

		// Fallback: stop
		return AgenticLoopDecision(
			nextAction: .stop_missing_context,
			reason: "No actionable path available from current state",
			confidence: 0.75,
			source: .heuristic,
			findQuery: nil
		)
	}

	// MARK: - Goal Classification

	/// True when the goal and/or workflow suggests a browser-based product/review/research task.
	///
	/// For these goals, weak/metadata_only observations should trigger controlled page acquisition
	/// (find_on_page or scroll_small) rather than premature extract_facts from metadata.
	///
	/// Workflows: browsing, research, product, review, shopping, reading.
	/// Goal keywords: review, rating, price, spec, compat, compare, product, buy, recommend, cost.
	private func isBrowserProductGoal(goal: String, workflow: String) -> Bool {
		let browserWorkflows: Set<String> = [
			"browsing", "research", "product", "review", "shopping", "reading"
		]
		if browserWorkflows.contains(workflow.lowercased()) { return true }
		let g = goal.lowercased()
		let productTerms = [
			"review", "rating", "star", "price", "cost", "$", "spec", "dimension",
			"compat", "compare", "product", "buy", "recommend", "feature", "warranty",
			"battery", "material", "color", "weight", "issue", "complaint"
		]
		return productTerms.contains { g.contains($0) }
	}

	// MARK: - Goal Content Matching

	/// Returns the missing content type if the goal implies it and the observation lacks it, else nil.
	private func goalRequiresMissingContent(
		goal: String,
		observation: AgenticObservation
	) -> String? {
		let g = goal.lowercased()
		let content = [
			observation.contextSummary,
			observation.selectedText,
			observation.ocrExcerpt
		].compactMap { $0 }.joined(separator: " ").lowercased()

		if (g.contains("review") || g.contains("rating") || g.contains("testimonial"))
			&& !content.contains("review") && !content.contains("rating") && !content.contains("star") {
			return "reviews"
		}
		if (g.contains("spec") || g.contains("dimension") || g.contains("measurement"))
			&& !content.contains("spec") && !content.contains("dimension") && !content.contains("mm") {
			return "specs"
		}
		if (g.contains("price") || g.contains("cost") || g.contains("$"))
			&& !content.contains("$") && !content.contains("price") && !content.contains("usd") {
			return "price"
		}
		if (g.contains("compat") || g.contains("works with"))
			&& !content.contains("compat") && !content.contains("works with") {
			return "compatibility"
		}
		return nil
	}

	// MARK: - Model (optional, single call, tight timeout)

	private func tryModel(
		goal: String,
		workflow: String,
		observations: [AgenticObservation],
		extractedFacts: [String],
		stepIndex: Int,
		maxSteps: Int,
		llmCallsUsed: Int,
		llmCallsBudget: Int,
		ocrCallsUsed: Int,
		ocrCallsBudget: Int,
		legalActions: Set<AgenticNextAction>,
		evidenceState: AgenticEvidenceState?,
		evidenceObservations: [AgenticEvidenceObservation],
		priorActions: [String],
		entities: [GroundedSemanticEntity],
		facts: [StructuredFact],
		heuristicFallback: AgenticLoopDecision
	) async -> AgenticLoopDecision {
		let priorActionsStr = priorActions.isEmpty ? "none" : priorActions.joined(separator: " -> ")
		let obsText = observations.map { o -> String in
			let ocr = o.ocrExcerpt ?? "(none)"
			let ax = o.contextSummary ?? "(none)"
			let sel = o.selectedText ?? "(none)"
			return "App: \(o.activeApp) | Window: \(o.windowTitle.prefix(60)) | Quality: \(o.quality.rawValue)\n- OCR Excerpt: \(ocr.prefix(300))\n- AX Summary: \(ax.prefix(300))\n- Selected Text: \(sel.prefix(200))"
		}.joined(separator: "\n---\n")

		let entitiesStr = entities.isEmpty ? "none" : entities.map { "\($0.text) (type: \($0.type.rawValue), confidence: \($0.confidence))" }.prefix(10).joined(separator: "; ")
		let factsStr = facts.isEmpty ? "none" : facts.map { "\($0.title) (category: \($0.category))" }.prefix(10).joined(separator: "; ")
		let evidenceStateStr = evidenceState.map { ev in
			"Satisfied: \(ev.satisfied.map(\.rawValue).joined(separator: ", ")), Missing: \(ev.missing.map(\.rawValue).joined(separator: ", ")), Confidence: \(ev.confidence)"
		} ?? "none"

		let legalList = legalActions.map(\.rawValue).sorted().joined(separator: ", ")

		let prompt = """
		You are a safe, local-first agentic decider choosing the next action in a bounded loop.
		Goal: \(goal)
		Workflow: \(workflow)

		[Budgets]
		- Current Step: \(stepIndex) / \(maxSteps)
		- LLM Calls Used: \(llmCallsUsed) / \(llmCallsBudget)
		- OCR Calls Used: \(ocrCallsUsed) / \(ocrCallsBudget)

		[History]
		- Previous Actions: \(priorActionsStr)
		- Extracted Facts: \(extractedFacts.joined(separator: "; "))

		[Current Evidence State]
		\(evidenceStateStr)

		[Discovered Entities & Facts]
		- Entities: \(entitiesStr)
		- Facts: \(factsStr)

		[Observations (Recent First)]
		\(obsText.prefix(2000))

		[Legal Actions Menu]
		\(legalList)

		Choose exactly ONE action from the Legal Actions Menu. Do NOT choose click, type, navigate, or any action not in the list.
		If quality is metadata_only or weak and this is a browser/product goal, prefer find_on_page or scroll_small over extract_facts.
		If all required evidence is satisfied and quality is high, choose present_answer or stop_success to terminate.
		
		Respond with JSON only, matching this schema:
		{
		  "next_action": "...",
		  "reason": "...",
		  "expected_change": "...",
		  "confidence": 0.0
		}
		"""

		do {
			let response = try await withTimeout(seconds: 5.0) {
				try await LocalAIClient.shared.generate(
					prompt: prompt,
					model: "phi4-mini",
					numPredict: 150,
					temperature: 0.1,
					purpose: "agentic_loop_decide",
					schema: Self.deciderSchema
				)
			}

			var rejectedReason: String? = nil
			if let parsed = parseModelDecision(response, legalActions: legalActions, rejectedReason: &rejectedReason) {
				print("[AgenticLLMDecide] accepted action=\(parsed.nextAction.rawValue) reason=\(parsed.reason)")
				return AgenticLoopDecision(
					nextAction: parsed.nextAction,
					reason: parsed.reason,
					confidence: parsed.confidence,
					source: .model,
					findQuery: parsed.nextAction == .find_on_page
						? AgenticControlPolicy.determineFindQuery(goal: goal)
						: nil
				)
			} else {
				let reason = rejectedReason ?? "parse_failed"
				print("[AgenticLLMDecide] rejected reason=\(reason)")
				print("[AgenticLLMDecide] fallback=heuristic reason=\(reason)")
			}
		} catch {
			print("[AgenticLLMDecide] fallback=heuristic reason=model_failed_or_timeout")
		}

		// Context sufficiency guard on the legacy-path fallback:
		// If the heuristic wants stop_missing_context but we have usable observations,
		// redirect to observe_screen. This mirrors the guard in directAgentDecide.
		let safeHeuristic: AgenticLoopDecision = {
			guard heuristicFallback.nextAction == .stop_missing_context else { return heuristicFallback }
			let ocrChars = observations.last?.ocrExcerpt?.count ?? 0
			let axChars  = observations.last?.contextSummary?.count ?? 0
			if ocrChars > 300 || axChars > 150 {
				let fallbackAction: AgenticNextAction = legalActions.contains(.observe_screen) ? .observe_screen : .answer
				print("[DirectAgentContextGuard] legacy_path stop_missing_context overridden to=\(fallbackAction.rawValue) reason=sufficient_context ocr=\(ocrChars) ax=\(axChars)")
				return AgenticLoopDecision(
					nextAction: fallbackAction,
					reason: "Sufficient context present (ocr=\(ocrChars) ax=\(axChars)) — redirecting legacy heuristic fallback",
					confidence: 0.70,
					source: .heuristic
				)
			}
			return heuristicFallback
		}()

		return AgenticLoopDecision(
			nextAction: safeHeuristic.nextAction,
			reason: safeHeuristic.reason + " (model_failed→heuristic_fallback)",
			confidence: safeHeuristic.confidence * 0.9,
			source: .fallback,
			findQuery: safeHeuristic.findQuery
		)
	}

	// MARK: - JSON Parsing

	func parseModelDecision(
		_ json: String,
		legalActions: Set<AgenticNextAction>,
		rejectedReason: inout String?
	) -> (nextAction: AgenticNextAction, reason: String, confidence: Double)? {
		guard let start = json.range(of: "{"),
			  let end = json.range(of: "}", options: .backwards)
		else {
			rejectedReason = "parse_failed"
			return nil
		}

		let jsonStr = String(json[start.lowerBound..<end.upperBound])
		guard let data = jsonStr.data(using: .utf8),
			  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			rejectedReason = "parse_failed"
			return nil
		}

		guard let actionStr = obj["next_action"] as? String else {
			rejectedReason = "parse_failed"
			return nil
		}

		let raw        = actionStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		// Run through the canonical alias table before enum conversion —
		// same normalizer used by directAgentDecide to ensure consistent behavior.
		print("[DirectAgentNormalizationPath] path=legacy_decide raw=\"\(raw)\"")
		let normalized = Self.normalizeActionAlias(raw)
		print("[DirectAgentActionNormalization] proposed=\"\(raw)\" normalized=\"\(normalized)\"")
		let action = AgenticNextAction(rawValue: normalized)
		let isLegal = action.map { legalActions.contains($0) } ?? false
		// Use a distinct tag so legacy-path validation is identifiable in logs.
		print("[AgenticLLMDecideValidation] proposed=\"\(actionStr)\" normalized=\"\(normalized)\" legal=\(isLegal)")

		guard let action,
			  legalActions.contains(action)
		else {
			rejectedReason = "illegal_action"
			return nil
		}

		// click_element from the legacy path lacks a target field (schema uses "next_action" only).
		// Reject it here — the direct-agent path handles click_element with its own target-repair.
		if action == .click_element {
			let legacyTarget = (obj["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
			if legacyTarget == nil || legacyTarget!.isEmpty {
				print("[AgenticLLMDecideValidation] rejected reason=click_element_no_target path=legacy_decide")
				rejectedReason = "click_element_no_target"
				return nil
			}
		}

		let reason = (obj["reason"] as? String) ?? "model decision"
		let confidence = min(1.0, max(0.0, (obj["confidence"] as? Double) ?? 0.75))
		return (action, reason, confidence)
	}

	// MARK: - Timeout

	private func withTimeout<T: Sendable>(
		seconds: Double,
		operation: @escaping @Sendable () async throws -> T
	) async throws -> T {
		try await withThrowingTaskGroup(of: T.self) { group in
			group.addTask { try await operation() }
			group.addTask {
				try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
				throw AgenticDeciderError.timeout
			}
			let result = try await group.next()!
			group.cancelAll()
			return result
		}
	}

	// MARK: - Phase 4P: Evidence-aware query planning

	private struct EvidenceQueryPlan {
		let query: String
		let reason: String
	}

	private static func determineEvidenceFindQuery(
		missingKind: AgenticEvidenceKind,
		evidenceObservations: [AgenticEvidenceObservation],
		goal: String
	) -> EvidenceQueryPlan {
		let plan: EvidenceQueryPlan
		switch missingKind {
		case .productTitle:
			if let candidate = evidenceObservations
				.filter({ $0.kind == .productTitle })
				.sorted(by: { $0.confidence > $1.confidence })
				.first {
				if let token = firstUsefulToken(candidate.text) {
					plan = EvidenceQueryPlan(query: token, reason: "window_title_entity")
					print("[FindQuery] kind=productTitle query=\(token) source=evidence_requirement")
					return plan
				}
			}
			let fallback = AgenticControlPolicy.determineFindQuery(goal: goal)
			let q = fallback == "product" ? "details" : fallback
			plan = EvidenceQueryPlan(query: q, reason: "goal_fallback")
			print("[FindQuery] kind=productTitle query=\(q) source=evidence_requirement")
			return plan

		case .specs:
			// Check if goal has "wattage" or "ports"
			let g = goal.lowercased()
			if g.contains("wattage") || g.contains("watt") {
				plan = EvidenceQueryPlan(query: "wattage", reason: "goal_specs")
			} else if g.contains("port") || g.contains("ports") {
				plan = EvidenceQueryPlan(query: "ports", reason: "goal_specs")
			} else if let spec = evidenceObservations
				.filter({ $0.kind == .specs })
				.sorted(by: { $0.confidence > $1.confidence })
				.first, let token = firstUsefulToken(spec.text) {
				plan = EvidenceQueryPlan(query: token, reason: "missing_specs")
			} else {
				plan = EvidenceQueryPlan(query: "details", reason: "missing_specs")
			}
			print("[FindQuery] kind=specs query=\(plan.query) source=evidence_requirement")
			return plan

		case .reviewCount, .reviewText:
			plan = EvidenceQueryPlan(query: "reviews", reason: "missing_reviews")
			print("[FindQuery] kind=\(missingKind.rawValue) query=reviews source=evidence_requirement")
			return plan

		case .rating:
			plan = EvidenceQueryPlan(query: "rating", reason: "missing_rating")
			print("[FindQuery] kind=rating query=rating source=evidence_requirement")
			return plan

		case .price:
			plan = EvidenceQueryPlan(query: "price", reason: "missing_price")
			print("[FindQuery] kind=price query=price source=evidence_requirement")
			return plan

		case .comparisonCandidate:
			plan = EvidenceQueryPlan(query: "compare", reason: "missing_comparison")
			print("[FindQuery] kind=comparisonCandidate query=compare source=evidence_requirement")
			return plan

		default:
			let q = AgenticControlPolicy.determineFindQuery(forMissingKind: missingKind, goal: goal)
			plan = EvidenceQueryPlan(query: q, reason: "default_kind_mapping")
			print("[FindQuery] kind=\(missingKind.rawValue) query=\(q) source=evidence_requirement")
			return plan
		}
	}

	private static func firstUsefulToken(_ text: String) -> String? {
		let t = text.lowercased()
		let tokens = t
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter { !$0.isEmpty }
		for tok in tokens {
			if tok.count < 3 { continue }
			if AgenticControlPolicy.findQueryBlocklist.contains(tok) { continue }
			return tok
		}
		return nil
	}

	func isStopGateBlocked(
		goal: String,
		observations: [AgenticObservation],
		evidenceObservations: [AgenticEvidenceObservation],
		entities: [GroundedSemanticEntity],
		facts: [StructuredFact],
		evidenceState: AgenticEvidenceState?,
		reason: inout String?
	) -> Bool {
		// 1. Check if final answer would contain "Unknown Product"
		var productTitle = "Unknown Product"
		if let pt = facts.first(where: { $0.category == "product" })?.title {
			productTitle = pt
		} else if let titleEntity = entities.first(where: { $0.type == .productTitle })?.text {
			productTitle = titleEntity
		} else if let ptObs = evidenceObservations.first(where: { $0.kind == .productTitle })?.text {
			productTitle = ptObs
		} else if let windowTitle = observations.last?.windowTitle {
			productTitle = windowTitle
		}

		// Apply title cleaning just like answer synthesis to test correct final value
		let noiseSuffixes = [
			" - Google Search", " - Google Chrome", " - Firefox", " - Safari",
			": Amazon.ca: Electronics", " : Amazon.ca", " : Amazon.com", " : Amazon.ca: Electronics",
			"Amazon.com:", "Amazon.ca:", " | Amazon", " - Amazon"
		]
		var cleaned = productTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		for suffix in noiseSuffixes {
			if let range = cleaned.range(of: suffix, options: [.caseInsensitive, .backwards]) {
				cleaned = String(cleaned[..<range.lowerBound])
			}
		}
		cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

		if EvidenceQualityGate.detectTruncation(cleaned) || EvidenceQualityGate.detectChromeLeak(cleaned) || (cleaned.split(separator: " ").count == 1 && cleaned.count <= 3) {
			cleaned = "Unknown Product"
		}

		if cleaned == "Unknown Product" || cleaned.isEmpty {
			reason = "unknown_product"
			return true
		}

		// 2. Check evidence quality groundedness
		let evState = evidenceState ?? AgenticEvidenceState(goal: goal, requirements: [], satisfied: [], missing: [], missingOptional: [], confidence: 0, shouldGatherMore: false, recommendedAction: .present)
		let quality = EvidenceQualityGate.evaluate(
			goal: goal,
			state: evState,
			observations: evidenceObservations,
			entities: entities,
			facts: facts
		)

		if quality.groundedness < 0.60 {
			reason = "low_groundedness"
			return true
		}

		// 3. Check chrome leak
		var chromeLeak = false
		for text in (observations.compactMap { $0.selectedText } + observations.compactMap { $0.ocrExcerpt } + evidenceObservations.map { $0.text } + entities.map { $0.text } + facts.map { $0.title }) {
			if EvidenceQualityGate.detectChromeLeak(text) {
				chromeLeak = true
				break
			}
		}
		if chromeLeak {
			reason = "chrome_leak_detected"
			return true
		}

		// 4. Required evidence is weak/short/noisy tokens (cleanliness)
		if quality.cleanliness < 0.85 {
			reason = "noisy_or_truncated_evidence"
			return true
		}

		// 5. Comparison validation for comparison family
		let isCompareGoal = AgenticEvidenceRequirementsInferrer.classifyFamily(goal: goal.lowercased(), workflow: "") == .compare
		if isCompareGoal {
			var reasonsList: [String] = []
			let comparisonValid = EvidenceQualityGate.validateComparisonCandidates(
				observations: evidenceObservations,
				entities: entities,
				facts: facts,
				reasons: &reasonsList
			)
			if !comparisonValid {
				reason = "invalid_comparison_candidates"
				return true
			}
		}

		return false
	}

	static func isAmbiguousOrSoftGoal(_ goal: String) -> Bool {
		let lower = goal.lowercased()
		// If it's a generic inspect/review/summarize page goal, it's ambiguous/soft
		let genericVerbs = ["inspect", "review", "summarize", "evaluate", "analyze"]
		let genericNouns = ["page", "permissions", "active permissions", "content", "details"]
		
		let hasGenericVerb = genericVerbs.contains { lower.contains($0) }
		let hasGenericNoun = genericNouns.contains { lower.contains($0) }
		
		// If it doesn't contain product terms, it's ambiguous
		let productTerms = ["charger", "hub", "gan", "usb", "case", "specs", "price", "rating", "comparison"]
		let hasProductTerms = productTerms.contains { lower.contains($0) }
		
		return (hasGenericVerb && hasGenericNoun) || !hasProductTerms
	}
}

// MARK: - Errors

enum AgenticDeciderError: Error {
	case timeout
}
