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
	/// Stop: insufficient context to fulfil the goal.
	case stop_missing_context
	/// Stop: goal is satisfied; answer is ready.
	case stop_success

	/// True for terminal actions that end the loop.
	var isTerminal: Bool {
		switch self {
		case .stop_missing_context, .stop_success, .present_answer: return true
		default: return false
		}
	}

	/// True for actions that interact with the OS (bounded; not arbitrary external control).
	var isControlledInteraction: Bool {
		switch self {
		case .scroll_small, .find_on_page: return true
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
		semanticReadiness: SemanticReadiness? = nil,
		evidenceState: AgenticEvidenceState? = nil,
		evidenceObservations: [AgenticEvidenceObservation] = [],
		priorActions: [String] = [],
		ineffectiveControlCount: Int = 0,
		entities: [GroundedSemanticEntity] = [],
		facts: [StructuredFact] = []
	) async -> AgenticLoopDecision {
		let latestQuality = observations.last?.quality.rawValue ?? "none"
		let evGate: String = {
			guard let s = evidenceState else { return "n/a" }
			return s.allRequiredSatisfied ? "satisfied" : "missing:\(s.missing.map { $0.rawValue }.joined(separator: ","))"
		}()
		print("[AgenticDecide] started step=\(stepIndex) observations=\(observations.count) facts=\(extractedFacts.count) quality=\(latestQuality) evidence_gate=\(evGate) llm=\(llmCallsUsed)/\(llmCallsBudget) ocr=\(ocrCallsUsed)/\(ocrCallsBudget) legal=[\(legalActions.map(\.rawValue).sorted().joined(separator: ","))]")

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

		return AgenticLoopDecision(
			nextAction: heuristicFallback.nextAction,
			reason: heuristicFallback.reason + " (model_failed→heuristic_fallback)",
			confidence: heuristicFallback.confidence * 0.9,
			source: .fallback,
			findQuery: heuristicFallback.findQuery
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

		guard let action = AgenticNextAction(rawValue: actionStr),
			  legalActions.contains(action)
		else {
			rejectedReason = "illegal_action"
			return nil
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
}

// MARK: - Errors

enum AgenticDeciderError: Error {
	case timeout
}
