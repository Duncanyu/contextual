import Foundation

/// Phase 20G.3 — Use current focus as a stronger signal than a stale,
/// stabilized workflow/behavior snapshot *for Jarvis suggestion generation*.
///
/// This does **not** mutate the committed `WorkflowState` stored by the
/// coordinator. It only produces an "effective" workflow/behavior pair
/// that Jarvis uses when:
/// - the selected browser tab changed with low overlap (FocusShift), and
/// - the selected tab's title terms strongly contradict the committed
///   workflow/behavior (e.g. shopping → course material).
///
/// No hardcoded app/site/brand rules — only generic title-term heuristics.
enum FocusOverride {

	struct Decision: Sendable, Equatable {
		let applied: Bool
		let effectiveWorkflow: WorkflowState
		let effectiveBehavior: BehavioralStateRecord
		let reason: String
	}

	private enum FocusCategory: String {
		case productLike
		case learningLike
		case researchLike
		case debuggingLike
		case writingLike
		case unknown
	}

	static func applyIfNeeded(
		workflowState: WorkflowState,
		behavioralRecord: BehavioralStateRecord,
		focusObservation: FocusEpochTracker.Observation,
		recentTabTitles: [String] = []
	) -> Decision {
		// Phase 20G.3/20G.4 — in ambient mode we gate on `focusShiftDetected`
		// (tab switches). For manual invoke / stable-reading refresh we also
		// want a "current focus contradicts committed workflow" escape hatch
		// even if no shift fired recently (e.g. user has already been reading
		// for minutes but workflow is still stale).
		let allowsNoShiftOverride = focusObservation.focusShiftDetected == false
		let shiftSatisfied = focusObservation.focusShiftDetected || allowsNoShiftOverride

		let committedWorkflow = workflowState.workflowType
		let committedBehavior = behavioralRecord.state

		let selectedTitle = focusObservation.currentEntity
		let selectedTerms = tokenize(selectedTitle)

		let category = classify(terms: selectedTerms, title: selectedTitle, tabTitles: recentTabTitles)

		// Decide whether the focus meaningfully contradicts the committed workflow.
		let committedIsProduct =
			committedWorkflow == .shopping || committedWorkflow == .comparing || committedBehavior == .shopping || committedBehavior == .comparing
		let committedIsLearning =
			committedWorkflow == .studying || committedWorkflow == .reading || committedWorkflow == .researching || committedBehavior == .learning || committedBehavior == .reading || committedBehavior == .researching

		let focusIsProduct = category == .productLike
		let focusIsLearning = category == .learningLike || category == .researchLike
		let focusIsDebugging = category == .debuggingLike
		let focusIsWriting = category == .writingLike

		let contradiction: Bool = {
			if committedIsProduct && (focusIsLearning || focusIsDebugging || focusIsWriting) { return true }
			if committedIsLearning && focusIsProduct { return true }
			return false
		}()

		guard shiftSatisfied && contradiction else {
			return Decision(
				applied: false,
				effectiveWorkflow: workflowState,
				effectiveBehavior: behavioralRecord,
				reason: contradiction ? "shift_not_satisfied" : "no_contradiction"
			)
		}

		let (newWorkflow, newBehavior): (AmbientWorkflowType, BehavioralState) = {
			switch category {
			case .learningLike:
				return (.studying, .learning)
			case .researchLike:
				return (.researching, .researching)
			case .debuggingLike:
				return (.debugging, .debugging)
			case .writingLike:
				return (.writing, .writing)
			case .productLike:
				// Contradiction says committed is learning-like, focus is product-like.
				return (.shopping, .shopping)
			case .unknown:
				// Avoid inventing a workflow; let Jarvis suppress rather than hallucinate.
				return (.unknown, .unknown)
			}
		}()

		let effectiveWorkflowState = WorkflowState(
			workflowType: newWorkflow,
			confidence: min(workflowState.confidence, 0.75),
			evidence: workflowState.evidence,
			uncertainty: "focus_override_current_focus_conflict",
			startedAt: workflowState.startedAt,
			lastUpdatedAt: workflowState.lastUpdatedAt,
			stabilityScore: min(workflowState.stabilityScore, 0.6),
			dominantApps: workflowState.dominantApps,
			repeatedTerms: workflowState.repeatedTerms,
			recentTransitions: workflowState.recentTransitions,
			suggestedIntentHints: workflowState.suggestedIntentHints,
			sourcePacketHash: workflowState.sourcePacketHash,
			provenanceCorrected: workflowState.provenanceCorrected,
			correctionStrength: "focus_override",
			volatilityScore: workflowState.volatilityScore
		)

		let now = Date()
		let effectiveBehaviorRecord = BehavioralStateRecord(
			state: newBehavior,
			confidence: min(behavioralRecord.confidence, 0.75),
			reasoning: "focus_override_current_focus_conflict",
			startedAt: behavioralRecord.startedAt,
			lastUpdatedAt: now,
			stabilityScore: min(behavioralRecord.stabilityScore, 0.6)
		)

		return Decision(
			applied: true,
			effectiveWorkflow: effectiveWorkflowState,
			effectiveBehavior: effectiveBehaviorRecord,
			reason: "current_focus_conflict"
		)
	}

	// MARK: - Heuristics

	private static func classify(terms: [String], title: String, tabTitles: [String]) -> FocusCategory {
		let lowerTitle = title.lowercased()
		// Phase 20G.4 — classification is primarily about the current focus
		// (selected tab), not the entire tab inventory. Tab titles can
		// *boost* confidence but must not override focus.
		let focusTerms = Set(terms.map { $0.lowercased() })
		let tabTerms = Set(tokenize(tabTitles.joined(separator: " ")).map { $0.lowercased() })

		// Generic signals (no app/site hardcoding).
		let productHints: Set<String> = [
			"price", "shipping", "delivery", "deal", "deals", "buy", "cart", "checkout",
			"spec", "specs", "review", "rating", "watt", "watts", "mah", "wh", "gb", "tb",
			"adapter", "charger", "dock", "docking", "battery", "portable"
			// NOTE: "power" removed — too ambiguous (TurboWarp, Scratch power blocks, etc.)
			// NOTE: "w" removed — single-char, tokenizer minimum is 3 chars
		]
		let learningHints: Set<String> = [
			"week", "lecture", "assignment", "homework", "problem", "quiz", "exam", "syllabus",
			"notes", "slides", "lesson", "chapter", "module", "tutorial", "lab", "course", "class",
			"intro", "introduction", "reading", "practice",
			// Creative coding / block-based programming and project demos.
			"scratch", "turbowarp", "sprite", "blocks", "block", "script", "project",
			"activity", "exercise", "coding", "program", "programming", "playground",
			"demo", "showcase", "prototype"
		]
		let researchHints: Set<String> = [
			"paper", "preprint", "arxiv", "doi", "pdf", "dataset", "method", "results", "analysis",
			"research", "survey", "experiment", "theory",
			// AI assistant tools — used for research/learning, not shopping.
			"gemini", "chatgpt", "claude", "copilot", "perplexity", "assistant", "chat"
		]
		let debuggingHints: Set<String> = [
			"error", "exception", "stack", "trace", "failed", "failure", "crash", "panic",
			"warning", "build", "compile", "runtime", "log", "issue"
		]
		let writingHints: Set<String> = [
			"draft", "outline", "edit", "editing", "revision", "essay", "proposal", "report",
			"rubric", "feedback", "paragraph"
		]

		func score(_ vocab: Set<String>) -> Int {
			let focus = focusTerms.intersection(vocab).count
			let boost = tabTerms.intersection(vocab).count
			// Focus is weighted higher than tab inventory.
			return (focus * 3) + boost
		}

		let productScore = score(productHints) + (lowerTitle.contains("$") || lowerTitle.contains("€") || lowerTitle.contains("£") ? 1 : 0)
		let learningScore = score(learningHints)
		let researchScore = score(researchHints)
		let debuggingScore = score(debuggingHints)
		let writingScore = score(writingHints)

		// Choose the strongest, requiring a small margin over productScore so
		// "power"/"portable" doesn't incorrectly dominate learning titles.
		let nonProductMax = max(learningScore, max(researchScore, max(debuggingScore, writingScore)))
		if debuggingScore >= max(productScore + 1, 1) { return .debuggingLike }
		if writingScore >= max(productScore + 1, 1) { return .writingLike }
		if researchScore >= max(productScore + 1, 1) { return .researchLike }
		if learningScore >= max(productScore + 1, 1) { return .learningLike }
		if productScore >= max(nonProductMax, 1) { return .productLike }
		return .unknown
	}

	private static func tokenize(_ s: String) -> [String] {
		let stop: Set<String> = ["the", "and", "for", "with", "from", "home", "page", "tab"]
		var out: [String] = []
		var seen = Set<String>()
		for w in s.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter({ $0.count >= 3 && $0.count <= 24 }) {
			if stop.contains(w) { continue }
			if Int(w) != nil { continue }
			if seen.insert(w).inserted { out.append(w) }
			if out.count >= 16 { break }
		}
		return out
	}
}
