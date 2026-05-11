import Foundation

/// Bounded, metadata-only context for proposal cards (T16.2). No raw user content.
struct ProposalContextSummary: Equatable, Sendable {
	/// When false, UI should match pre–T16.2 proposal card (no extra lines).
	let isAvailable: Bool
	/// Single subtitle line, e.g. `Debugging · confidence high · generated signal`.
	let contextSubtitle: String?
	/// At most three short chips (sanitized tokens).
	let chips: [String]
	/// One short “why” line, metadata-only.
	let whyLine: String?
	/// Optional line from generated-action explainability when it matches the primary static action.
	let explainHint: String?
	let hasGeneratedInfluence: Bool
	let hasIntentAlignment: Bool

	/// Human-readable chip labels for compact UI (no raw user content).
	var chipDisplayLabels: [String] {
		chips.map { ProposalContextSummary.chipDisplayText($0) }
	}

	private static func chipDisplayText(_ chip: String) -> String {
		if chip.hasPrefix("confidence_") {
			let rest = String(chip.dropFirst("confidence_".count))
			return "confidence \(rest)"
		}
		if chip.hasPrefix("assist_"), let cat = GeneratedAssistanceCategory(rawValue: String(chip.dropFirst("assist_".count))) {
			return "Assistance · \(cat.userFacingLabel)"
		}
		switch chip {
		case "contextual": return "generated signal"
		case "intent_aligned": return "intent signal"
		case "continuity": return "workflow continuity"
		default:
			return chip.replacingOccurrences(of: "_", with: " ")
		}
	}

	static let unavailable = ProposalContextSummary(
		isAvailable: false,
		contextSubtitle: nil,
		chips: [],
		whyLine: nil,
		explainHint: nil,
		hasGeneratedInfluence: false,
		hasIntentAlignment: false
	)
}

/// Builds `ProposalContextSummary` from existing singleton metadata (Intelligence + context engines only).
enum ProposalContextSummaryBuilder {
	private static let minWorkflowConfidence: Double = 0.42
	private static let minIntentAlignmentConfidence: Double = 0.48
	private static let maxChips = 3
	private static let maxWhyLength = 118
	private static let maxExplainHint = 88

	static func build(for proposal: ActionProposal) -> ProposalContextSummary {
		compose(
			proposal: proposal,
			wfInf: WorkflowInferenceEngine.shared.latestResult(),
			intentResult: IntentSynthesisEngine.shared.latestResult(),
			ranking: WorkflowAwareProposalRanker.latestRankingSnapshot(),
			gas: GeneratedActionEngine.shared.latestActions()
		)
	}

	// MARK: - Core composition

	private static func compose(
		proposal: ActionProposal,
		wfInf: WorkflowInferenceResult?,
		intentResult: IntentSynthesisResult?,
		ranking: WorkflowAwareProposalRankingResult?,
		gas: [GeneratedAction]
	) -> ProposalContextSummary {
		let wfShows = wfInf.map { inf in
			inf.workflow != .unknown && inf.confidence >= minWorkflowConfidence && !inf.isStale
		} ?? false
		let wfLabel = wfShows ? (wfInf?.workflow.rawValue ?? "") : ""

		let session = ContextualSessionTracker.shared.currentState()
		let continuityShows = {
			guard let s = session, !s.isStale else { return false }
			guard wfShows, let wf = wfInf else { return false }
			guard s.dominantWorkflow == wf.workflow, s.dominantWorkflow != .unknown else { return false }
			return s.continuityScore >= 0.45 && s.continuityConfidence >= 0.38
		}()

		let confBucket = confidenceBucket(proposal.confidence)

		let hasGenInfl = ranking.map { r in
			r.adjustment.reasonCodes.contains(.generatedPrimitiveBoost) && r.suggestedStaticPrimary == proposal.primaryActionId
		} ?? false

		let topIntent = intentResult.flatMap { res -> SynthesizedIntent? in
			guard let t = res.topIntentType else { return nil }
			return res.intents.first { $0.type == t && !$0.isStale }
		}
		let intentAligned = topIntent.map { intent in
			intentAlignsPrimary(proposal.primaryActionId, intent.type) && intent.confidence >= minIntentAlignmentConfidence
		} ?? false

		let explainHintRaw = explainHintFromGeneratedActions(gas, primaryId: proposal.primaryActionId)
		let explainHint = explainHintRaw.map(sanitizeExplainHint)

		var chips: [String] = []
		if wfShows, !wfLabel.isEmpty {
			chips.append(sanitizeToken(wfLabel))
		}
		chips.append("confidence_\(sanitizeToken(confBucket))")
		if hasGenInfl {
			if let cat = GeneratedAssistanceCategoryMapper.categoryForPrimaryStaticAction(
				primaryActionId: proposal.primaryActionId,
				actions: gas
			), cat != .unknown {
				chips.append("assist_\(cat.rawValue)")
			} else {
				chips.append("contextual")
			}
		} else if intentAligned {
			chips.append("intent_aligned")
		} else if continuityShows {
			chips.append("continuity")
		}
		chips = Array(chips.prefix(maxChips))

		let subtitleParts: [String] = {
			var p: [String] = []
			if wfShows, !wfLabel.isEmpty { p.append(wfLabel) }
			p.append("confidence \(confBucket)")
			if hasGenInfl { p.append("generated signal") }
			else if intentAligned { p.append("intent signal") }
			return p
		}()

		let contextSubtitle: String? = {
			guard !subtitleParts.isEmpty else { return nil }
			let s = subtitleParts.joined(separator: " · ")
			return s.count <= 120 ? s : String(s.prefix(120))
		}()

		let baseWhyLine: String? = {
			var s: String?
			if hasGenInfl {
				s = "Suggested from workflow ranking with generated signal."
			} else if intentAligned, let wf = wfInf, wfShows {
				s = "Suggested from \(wf.workflow.rawValue) workflow and aligned intent."
			} else if wfShows, let wf = wfInf {
				s = "Suggested from \(wf.workflow.rawValue) workflow context."
			} else if continuityShows {
				s = "Suggested from workflow continuity."
			}
			return s.map(clampWhy)
		}()

		let whyLine: String? = {
			guard let h = explainHint, !h.isEmpty else { return baseWhyLine }
			guard let w = baseWhyLine, !w.isEmpty else { return clampWhy(h) }
			let spacer = w.hasSuffix(".") ? " " : " "
			return clampWhy(w + spacer + h)
		}()

		let isAvailable = wfShows || hasGenInfl || intentAligned || continuityShows || !(explainHint?.isEmpty ?? true)
		if !isAvailable {
			return .unavailable
		}

		return ProposalContextSummary(
			isAvailable: true,
			contextSubtitle: contextSubtitle,
			chips: chips,
			whyLine: whyLine,
			explainHint: (explainHint?.isEmpty ?? true) ? nil : explainHint,
			hasGeneratedInfluence: hasGenInfl,
			hasIntentAlignment: intentAligned
		)
	}

	private static func confidenceBucket(_ c: Double) -> String {
		let x = min(1.0, max(0.0, c))
		if x >= 0.68 { return "high" }
		if x >= 0.48 { return "medium" }
		if x > 0 { return "low" }
		return "unknown"
	}

	private static func intentAlignsPrimary(_ primary: String, _ type: SynthesizedIntentType) -> Bool {
		switch (primary, type) {
		case ("explain_text", .explainLikelyError),
			("explain_text", .identifyPossibleBugSource),
			("explain_text", .explainApiResponse),
			("explain_text", .explainScreenContext):
			return true
		case ("summarize_text", .summarizeCurrentArticle):
			return true
		case ("rewrite_text", .reviewSelectedText),
			("rewrite_text", .draftReply),
			("rewrite_text", .turnNotesIntoChecklist):
			return true
		default:
			return false
		}
	}

	private static func mapPrimitiveToStaticId(_ p: GeneratedActionPrimitive) -> String? {
		switch p {
		case .explain: return "explain_text"
		case .summarize: return "summarize_text"
		case .rewrite, .draft, .review, .checklist: return "rewrite_text"
		case .compare, .classify, .extract, .structure: return nil
		}
	}

	private static func explainHintFromGeneratedActions(_ actions: [GeneratedAction], primaryId: String) -> String? {
		let match = actions
			.filter { !$0.isStale }
			.filter { ga in ga.primitives.contains { mapPrimitiveToStaticId($0) == primaryId } }
			.max(by: { $0.confidence < $1.confidence })
		guard let m = match, let expl = m.structuredExplainability else { return nil }
		let t = expl.shortSummary.trimmingCharacters(in: .whitespacesAndNewlines)
		return t.isEmpty ? nil : t
	}

	private static func sanitizeToken(_ s: String) -> String {
		var out = ""
		for ch in s.lowercased().prefix(24) {
			if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_") {
				out.append(ch)
			}
		}
		return out.isEmpty ? "meta" : out
	}

	private static func clampWhy(_ s: String) -> String {
		let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.count > maxWhyLength else { return t }
		return String(t.prefix(maxWhyLength))
	}

	private static func sanitizeExplainHint(_ s: String) -> String {
		var t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
		if t.contains("://") { return "" }
		if t.count > maxExplainHint { t = String(t.prefix(maxExplainHint)) }
		return t
	}

	// MARK: - DEBUG self-test

	static func runSelfTest() -> Bool {
		print("[ProposalContext] selftest starting")
		var failures: [String] = []

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let pStatic = ActionProposal(
			title: "T",
			sourceCaption: "",
			primaryActionId: "summarize_text",
			secondaryActionIds: [],
			confidence: 0.55,
			reason: "static"
		)

		let sUnknown = compose(
			proposal: pStatic,
			wfInf: nil,
			intentResult: nil,
			ranking: nil,
			gas: []
		)
		assertCase("static_no_claim", !sUnknown.isAvailable)

		let rankGenMismatch = WorkflowAwareProposalRankingResult(
			adjustedScores: [],
			rankedGeneratedActionIds: [],
			primaryCategory: .staticAction,
			suggestedStaticPrimary: "explain_text",
			confidence: 0.7,
			interruptionCost: 0.2,
			reasonCodes: [.generatedPrimitiveBoost],
			adjustment: WorkflowProposalAdjustment(scoreDeltasByActionId: [:], reasonCodes: [.generatedPrimitiveBoost])
		)
		let sBoostWrong = compose(
			proposal: ActionProposal(title: "S", sourceCaption: "", primaryActionId: "summarize_text", secondaryActionIds: [], confidence: 0.6, reason: "r"),
			wfInf: nil,
			intentResult: nil,
			ranking: rankGenMismatch,
			gas: []
		)
		assertCase("boost_wrong_primary_no_gen", !sBoostWrong.hasGeneratedInfluence && !sBoostWrong.isAvailable)

		let wfDbg = WorkflowInferenceResult(
			workflow: .debugging,
			confidence: 0.68,
			contributingSignals: ["t"],
			inferredAt: Date(),
			isStale: false,
			summaryHint: nil,
			sourceFusedId: UUID()
		)
		let rankGen = WorkflowAwareProposalRankingResult(
			adjustedScores: [],
			rankedGeneratedActionIds: [],
			primaryCategory: .staticAction,
			suggestedStaticPrimary: "explain_text",
			confidence: 0.7,
			interruptionCost: 0.2,
			reasonCodes: [.generatedPrimitiveBoost],
			adjustment: WorkflowProposalAdjustment(scoreDeltasByActionId: [:], reasonCodes: [.generatedPrimitiveBoost])
		)
		let gaAssistDebug = GeneratedAction(
			id: UUID(),
			title: "G",
			description: "D",
			intentType: .explainLikelyError,
			confidence: 0.68,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			primitives: [.explain],
			interruptionCost: 0.4,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: [],
			createdAt: Date(),
			expiresAt: Date().addingTimeInterval(120),
			isStale: false,
			safetyProfile: .profile(for: [.explain]),
			explainabilitySummary: "x",
			source: .selfTest,
			structuredExplainability: nil
		)
		let sDebug = compose(
			proposal: ActionProposal(title: "E", sourceCaption: "", primaryActionId: "explain_text", secondaryActionIds: [], confidence: 0.72, reason: "r"),
			wfInf: wfDbg,
			intentResult: IntentSynthesisResult(
				intents: [
					SynthesizedIntent(
						id: UUID(),
						type: .explainLikelyError,
						title: "x",
						description: "y",
						confidence: 0.62,
						workflow: .debugging,
						requiredContext: [.textSnippet],
						supportingSignals: [],
						interruptionCost: 0.4,
						freshness: 0.8,
						createdAt: Date(),
						isStale: false,
						sourceReasonCodes: []
					)
				],
				suppressedReason: nil,
				skippedReason: nil,
				synthesizedAt: Date(),
				suppression: nil
			),
			ranking: rankGen,
			gas: [gaAssistDebug]
		)
		assertCase("debugging_chips", sDebug.isAvailable && sDebug.chips.count <= maxChips)
		assertCase("debugging_wf", sDebug.contextSubtitle?.contains("debugging") == true)
		assertCase("debug_gen_infl", sDebug.hasGeneratedInfluence)
		assertCase("debug_assist_chip", sDebug.chips.contains(where: { $0.hasPrefix("assist_") }))

		let wfRes = WorkflowInferenceResult(
			workflow: .research,
			confidence: 0.55,
			contributingSignals: ["r"],
			inferredAt: Date(),
			isStale: false,
			summaryHint: nil,
			sourceFusedId: UUID()
		)
		let sResearch = compose(
			proposal: ActionProposal(title: "S", sourceCaption: "", primaryActionId: "summarize_text", secondaryActionIds: [], confidence: 0.6, reason: "r"),
			wfInf: wfRes,
			intentResult: IntentSynthesisResult(
				intents: [
					SynthesizedIntent(
						id: UUID(),
						type: .summarizeCurrentArticle,
						title: "x",
						description: "y",
						confidence: 0.58,
						workflow: .research,
						requiredContext: [.textSnippet],
						supportingSignals: [],
						interruptionCost: 0.3,
						freshness: 0.8,
						createdAt: Date(),
						isStale: false,
						sourceReasonCodes: []
					)
				],
				suppressedReason: nil,
				skippedReason: nil,
				synthesizedAt: Date(),
				suppression: nil
			),
			ranking: nil,
			gas: []
		)
		assertCase("research_chips", sResearch.isAvailable && sResearch.chips.contains { $0.contains("research") })

		let wfLow = WorkflowInferenceResult(
			workflow: .debugging,
			confidence: 0.28,
			contributingSignals: ["t"],
			inferredAt: Date(),
			isStale: false,
			summaryHint: nil,
			sourceFusedId: UUID()
		)
		let sLowWf = compose(proposal: pStatic, wfInf: wfLow, intentResult: nil, ranking: nil, gas: [])
		assertCase("low_wf_hidden", !sLowWf.isAvailable)

		let longWhy = String(repeating: "word ", count: 40)
		assertCase("why_short", clampWhy(longWhy).count <= maxWhyLength)

		let gaExpl = GeneratedActionExplanation(
			shortSummary: "Short meta summary.",
			workflowSummary: "w",
			confidenceSummary: "c",
			influencingSignals: [],
			requiredContextSummary: "r",
			interruptionSummary: "i",
			freshnessSummary: "f",
			safetySummary: "s",
			sourceReasonCodes: [],
			generatedAt: Date(),
			isStale: false,
			workflowReasoning: GeneratedActionWorkflowReasoning(primaryCode: "wf", secondaryCodes: ""),
			influence: GeneratedActionInfluenceSummary(
				workflowLabel: "debugging",
				visualCategoryCodes: "terminal",
				interactionStateCode: "idle",
				sessionContinuityBand: "m",
				fusionFreshnessBand: "m",
				multimodalAgreementBand: "m",
				proposalContinuityBand: "m",
				activeSurfaceCategory: "code",
				intentTypeCode: "explain_likely_error",
				primitiveCompositionCode: "explain"
			),
			templateReasons: []
		)
		let ga = GeneratedAction(
			id: UUID(),
			title: "Explain",
			description: "D",
			intentType: .explainLikelyError,
			confidence: 0.7,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			primitives: [.explain],
			interruptionCost: 0.4,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["t"],
			createdAt: Date(),
			expiresAt: Date().addingTimeInterval(120),
			isStale: false,
			safetyProfile: .profile(for: [.explain]),
			explainabilitySummary: "x",
			source: .selfTest,
			structuredExplainability: gaExpl
		)
		let sHint = compose(
			proposal: ActionProposal(title: "E", sourceCaption: "", primaryActionId: "explain_text", secondaryActionIds: [], confidence: 0.7, reason: "r"),
			wfInf: nil,
			intentResult: nil,
			ranking: nil,
			gas: [ga]
		)
		assertCase("explain_hint", sHint.explainHint?.isEmpty == false)

		let ok = failures.isEmpty
		print("[ProposalContext] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}
