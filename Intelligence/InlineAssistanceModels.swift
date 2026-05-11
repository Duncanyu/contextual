import Foundation

// MARK: - Surface & placement (T16.6 foundations; metadata-only; no inline UI)

enum InlineAssistanceSurfaceType: String, Hashable, Sendable, Codable, CaseIterable {
	case selectionChip
	case contextChip
	case generatedSuggestionChip
	case explainChip
	case summarizeChip
	case reviewChip
	case disabledPreviewChip
	case none
}

enum InlineAssistancePlacementHint: String, Hashable, Sendable, Codable, CaseIterable {
	case nearSelection
	case nearCaret
	case assistantPanelOnly
	case floatingSuggestionOnly
	case unavailable
	case unknown
}

/// Lightweight chip metadata derived from a candidate (for debug / future chips).
struct InlineAssistanceChipModel: Equatable, Sendable, Identifiable {
	var id: String { candidateId.uuidString }
	let candidateId: UUID
	let shortLabel: String
	let surfaceType: InlineAssistanceSurfaceType
	let placementHint: InlineAssistancePlacementHint
	let categoryRaw: String
	let safetyBadgeRaw: String
}

/// Coarse eligibility for whether any inline assistance may be considered (metadata-only).
struct InlineAssistanceEligibility: Equatable, Sendable {
	let allowsCandidates: Bool
	let reasonCodes: [String]
}

/// One bounded, non-executable inline assistance candidate (no raw user content).
struct InlineAssistanceCandidate: Equatable, Sendable, Identifiable {
	let id: UUID
	let sourceActionId: String?
	let generatedActionId: String?
	let title: String
	let shortLabel: String
	let category: GeneratedAssistanceCategory
	let confidenceBucket: String
	let safetyBadge: DynamicActionDisplaySafetyBadge
	let previewOnly: Bool
	/// Always false in this phase; reserved for future policy checks.
	let executable: Bool
	let surfaceType: InlineAssistanceSurfaceType
	let placementHint: InlineAssistancePlacementHint
	let reasonCodes: [String]
	let createdAt: Date
	let expiresAt: Date?
	let isStale: Bool
	let dismissalKey: String
	let explanationLine: String
}

struct InlineAssistanceSnapshot: Equatable, Sendable {
	let candidates: [InlineAssistanceChipModel]
	let rows: [InlineAssistanceCandidate]
	let eligibility: InlineAssistanceEligibility

	static let empty = InlineAssistanceSnapshot(candidates: [], rows: [], eligibility: InlineAssistanceEligibility(allowsCandidates: false, reasonCodes: ["empty"]))

	var candidateCount: Int { rows.count }
}

// MARK: - Safety (static rules only)

enum InlineAssistanceSafetyPolicy {
	static let maxCandidates = 2

	static func isKnownReadOnlyStaticAction(_ actionId: String) -> Bool {
		switch actionId {
		case "summarize_text", "explain_text", "rewrite_text", ScreenAnalyzeAction.analyzeScreenId:
			return true
		default:
			return false
		}
	}

	static func surfaceType(forStaticActionId id: String) -> InlineAssistanceSurfaceType {
		switch id {
		case "explain_text": return .explainChip
		case "summarize_text": return .summarizeChip
		case "rewrite_text": return .reviewChip
		case ScreenAnalyzeAction.analyzeScreenId: return .contextChip
		default: return .contextChip
		}
	}
}

// MARK: - Builder inputs (lifecycle passes metadata only)

struct InlineAssistanceBuildInput: Sendable {
	let context: ContextModel
	let staticActions: [(id: String, name: String)]
	let currentProposal: ActionProposal?
	let currentProposalKey: String?
	let generatedPreviewItems: [DynamicActionDisplayModel]
	let isManualInvocation: Bool
	let isActionExecuting: Bool
	let lastDismissedProposalActionId: String?
	let typing: TypingActivityContext?
	let pointer: PointerActivityContext?
	let fused: FusedContextPacket?
}

// MARK: - Builder

enum InlineAssistanceCandidateBuilder {
	private static var lastLogSig: String?
	private static var lastLogAt: Date?

	static func build(input: InlineAssistanceBuildInput) -> InlineAssistanceSnapshot {
		let eligibility = evaluateEligibility(input: input)
		guard eligibility.allowsCandidates else {
			logSkipped(reasons: eligibility.reasonCodes)
			return InlineAssistanceSnapshot(candidates: [], rows: [], eligibility: eligibility)
		}

		var rows: [InlineAssistanceCandidate] = []
		let now = Date()

		// Static selection-adjacent chips (metadata only).
		let strongSel = input.context.selectedTextAvailable
			&& input.context.selectedTextLength >= TriggerEngine.selectedTextMinCharacterCount
		let isSelPrimary = input.fused?.primaryTextSource == .selectedText

		let timing = ProposalTimingGate.evaluate(
			isManualInvocation: input.isManualInvocation,
			isActionExecuting: input.isActionExecuting,
			hasStrongSelectedText: strongSel,
			isSelectedTextPrimary: isSelPrimary,
			canonicalFreshness: input.fused?.freshnessScore,
			canonicalConfidence: input.fused?.confidence,
			typing: input.typing,
			pointer: input.pointer,
			proposalStrengthHint: input.currentProposal?.confidence
		)

		if strongSel {
			for s in input.staticActions where rows.count < InlineAssistanceSafetyPolicy.maxCandidates {
				guard InlineAssistanceSafetyPolicy.isKnownReadOnlyStaticAction(s.id) else {
					print("[InlineAssistance] skipped reason=unsafe")
					continue
				}
				guard s.id != input.lastDismissedProposalActionId else { continue }
				let dupProposal = input.currentProposal?.primaryActionId == s.id
				let placement: InlineAssistancePlacementHint = dupProposal
					? .assistantPanelOnly
					: (strongSel && isSelPrimary ? .nearSelection : .assistantPanelOnly)

				if timing.outcome == .suppress, !strongSel { continue }
				if timing.outcome == .deferred, !strongSel { continue }

				let specific = InlineAssistanceSafetyPolicy.surfaceType(forStaticActionId: s.id)
				let surface: InlineAssistanceSurfaceType = (strongSel && isSelPrimary) ? .selectionChip : specific
				let dismissKey = "static:\(s.id)"
				let row = InlineAssistanceCandidate(
					id: UUID(),
					sourceActionId: s.id,
					generatedActionId: nil,
					title: clampMeta(s.name, 48),
					shortLabel: clampMeta(s.name, 22),
					category: categoryForStaticAction(s.id),
					confidenceBucket: "static",
					safetyBadge: .safeReadOnly,
					previewOnly: false,
					executable: false,
					surfaceType: surface,
					placementHint: placement,
					reasonCodes: ["static_eligible", "selection_metadata"],
					createdAt: now,
					expiresAt: now.addingTimeInterval(120),
					isStale: false,
					dismissalKey: dismissKey,
					explanationLine: "Read-only static assist (preview chip only in future UI)."
				)
				rows.append(row)
			}
		}

		// Generated previews (already safety-filtered upstream).
		for item in input.generatedPreviewItems where rows.count < InlineAssistanceSafetyPolicy.maxCandidates {
			let weakGen = item.confidenceBucket == "low" || item.confidenceBucket == "unknown"
			if weakGen, timing.outcome != .allow {
				if timing.reason.contains("burst") || timing.reason.contains("interaction") {
					print("[InlineAssistance] skipped reason=interaction_burst")
				}
				continue
			}

			let gid = String(item.id.uuidString.prefix(8))
			let dup = input.currentProposal?.primaryActionId == intentToStaticPrimary(item.sourceIntentType)
			let placement: InlineAssistancePlacementHint = dup ? .assistantPanelOnly : .floatingSuggestionOnly
			let surface: InlineAssistanceSurfaceType = item.reviewRequired ? .disabledPreviewChip : .generatedSuggestionChip
			let row = InlineAssistanceCandidate(
				id: UUID(),
				sourceActionId: nil,
				generatedActionId: gid,
				title: clampMeta(item.title, 52),
				shortLabel: clampMeta(item.title, 24),
				category: item.category,
				confidenceBucket: item.confidenceBucket,
				safetyBadge: item.safetyBadge,
				previewOnly: true,
				executable: false,
				surfaceType: surface,
				placementHint: placement,
				reasonCodes: ["generated_preview", item.reviewRequired ? "review_gate" : "safe_preview"],
				createdAt: now,
				expiresAt: now.addingTimeInterval(90),
				isStale: false,
				dismissalKey: "generated:\(gid)",
				explanationLine: "Non-executable generated assistance preview."
			)
			if !rows.contains(where: { $0.dismissalKey == row.dismissalKey }) {
				rows.append(row)
			}
		}

		rows = Array(rows.prefix(InlineAssistanceSafetyPolicy.maxCandidates))
		let chips = rows.map(chipFromCandidate)
		logCandidates(rows)
		return InlineAssistanceSnapshot(candidates: chips, rows: rows, eligibility: eligibility)
	}

	// MARK: - Eligibility

	private static func evaluateEligibility(input: InlineAssistanceBuildInput) -> InlineAssistanceEligibility {
		var reasons: [String] = []
		if input.isActionExecuting {
			reasons.append("action_executing")
			return InlineAssistanceEligibility(allowsCandidates: false, reasonCodes: reasons)
		}
		guard let fused = input.fused else {
			reasons.append("no_fused_packet")
			return InlineAssistanceEligibility(allowsCandidates: false, reasonCodes: reasons)
		}
		if fused.isStale, !input.isManualInvocation {
			reasons.append("stale_context")
			return InlineAssistanceEligibility(allowsCandidates: false, reasonCodes: reasons)
		}
		if fused.freshnessScore < 0.20, !input.isManualInvocation {
			reasons.append("low_freshness")
			return InlineAssistanceEligibility(allowsCandidates: false, reasonCodes: reasons)
		}
		return InlineAssistanceEligibility(allowsCandidates: true, reasonCodes: ["ok"])
	}

	// MARK: - Helpers

	private static func categoryForStaticAction(_ id: String) -> GeneratedAssistanceCategory {
		switch id {
		case "explain_text": return .debugging
		case "summarize_text": return .research
		case "rewrite_text": return .writing
		case ScreenAnalyzeAction.analyzeScreenId: return .utility
		default: return .utility
		}
	}

	private static func intentToStaticPrimary(_ intentRaw: String) -> String? {
		switch intentRaw {
		case SynthesizedIntentType.explainLikelyError.rawValue,
			SynthesizedIntentType.identifyPossibleBugSource.rawValue,
			SynthesizedIntentType.explainScreenContext.rawValue,
			SynthesizedIntentType.explainApiResponse.rawValue:
			return "explain_text"
		case SynthesizedIntentType.summarizeCurrentArticle.rawValue:
			return "summarize_text"
		case SynthesizedIntentType.draftReply.rawValue,
			SynthesizedIntentType.reviewSelectedText.rawValue,
			SynthesizedIntentType.turnNotesIntoChecklist.rawValue:
			return "rewrite_text"
		default:
			return nil
		}
	}

	private static func chipFromCandidate(_ c: InlineAssistanceCandidate) -> InlineAssistanceChipModel {
		InlineAssistanceChipModel(
			candidateId: c.id,
			shortLabel: c.shortLabel,
			surfaceType: c.surfaceType,
			placementHint: c.placementHint,
			categoryRaw: c.category.rawValue,
			safetyBadgeRaw: c.safetyBadge.rawValue
		)
	}

	private static func clampMeta(_ s: String, _ n: Int) -> String {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		guard t.count > n else { return t }
		return String(t.prefix(n))
	}

	private static func logSkipped(reasons: [String]) {
		for r in reasons.prefix(3) {
			print("[InlineAssistance] skipped reason=\(r)")
		}
	}

	private static func logCandidates(_ rows: [InlineAssistanceCandidate]) {
		guard !rows.isEmpty else {
			print("[InlineAssistance] candidate count=0 top=none surface=none")
			return
		}
		let top = rows.first?.surfaceType.rawValue ?? "none"
		let place = rows.first?.placementHint.rawValue ?? "unknown"
		let sig = "\(rows.count)|\(top)|\(place)"
		let now = Date()
		if lastLogSig == sig, let t = lastLogAt, now.timeIntervalSince(t) < 1.6 { return }
		lastLogSig = sig
		lastLogAt = now
		print("[InlineAssistance] candidate count=\(rows.count) top=\(top) surface=\(rows.first?.surfaceType.rawValue ?? "none")")
		print("[InlineAssistance] placement hint=\(place)")
	}
}

// MARK: - Self-test

extension InlineAssistanceCandidateBuilder {
	static func runSelfTest() -> Bool {
		print("[InlineAssistance] selftest starting")
		var failures: [String] = []
		func a(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let t0 = Date(timeIntervalSince1970: 2_100_000_000)
		var ctx = ContextModel()
		ctx.selectedTextAvailable = true
		ctx.selectedTextLength = TriggerEngine.selectedTextMinCharacterCount + 10

		let fusedFresh = FusedContextPacket(
			id: UUID(),
			createdAt: t0,
			primarySource: .selectedText,
			availableSources: [.selectedText, .activeApp],
			staleSources: [],
			appName: "Xcode",
			bundleIdentifier: "com.apple.dt.Xcode",
			windowTitleAvailable: false,
			primaryTextSource: .selectedText,
			textAvailability: true,
			textLength: 120,
			lineCount: 4,
			hasSelectedText: true,
			hasClipboardText: false,
			hasOCRText: false,
			hasAXText: false,
			hasWindowSnapshot: false,
			hasVisualDescriptor: false,
			hasTypingActivity: false,
			hasPointerActivity: false,
			visualKinds: [],
			uiStructureHints: [],
			typingState: .idle,
			pointerState: .idle,
			confidence: 0.78,
			freshnessScore: 0.74,
			conflictScore: 0.05,
			isStale: false,
			suppressedSources: [],
			supportingSources: [],
			arbitrationReasons: [],
			debugSummaryMetadata: ["selftest": "1"]
		)

		let staticActs: [(id: String, name: String)] = [
			("explain_text", "Explain"),
			("summarize_text", "Summarize")
		]
		let proposal = ActionProposal(title: "E", sourceCaption: "", primaryActionId: "summarize_text", secondaryActionIds: [], confidence: 0.8, reason: "t")

		let snapStrong = build(input: InlineAssistanceBuildInput(
			context: ctx,
			staticActions: staticActs,
			currentProposal: proposal,
			currentProposalKey: "k1",
			generatedPreviewItems: [],
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: nil,
			pointer: nil,
			fused: fusedFresh
		))
		a("static_selection", snapStrong.rows.contains { $0.surfaceType == .selectionChip || $0.surfaceType == .explainChip })
		a("static_near", snapStrong.rows.contains { $0.placementHint == .nearSelection || $0.placementHint == .assistantPanelOnly })
		a("static_not_exec", snapStrong.rows.allSatisfy { !$0.executable })

		let genRow = DynamicActionDisplayModel(
			id: UUID(),
			title: "Explain likely error preview",
			shortDescription: "meta",
			category: .debugging,
			assistanceCategoryReason: .intent,
			workflowLabel: "debugging",
			confidenceBucket: "high",
			safetyBadge: .safeReadOnly,
			reviewRequired: false,
			primitiveLabels: ["explain"],
			reasonChips: ["preview_only"],
			interruptionCostBucket: "low",
			sourceIntentType: SynthesizedIntentType.explainLikelyError.rawValue,
			source: .generatedAction,
			isExecutable: false,
			isPreviewOnly: true
		)
		let snapGen = build(input: InlineAssistanceBuildInput(
			context: ctx,
			staticActions: [],
			currentProposal: nil,
			currentProposalKey: nil,
			generatedPreviewItems: [genRow],
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: nil,
			pointer: nil,
			fused: fusedFresh
		))
		a("gen_chip", snapGen.rows.contains { $0.surfaceType == .generatedSuggestionChip })
		a("gen_has_id", snapGen.rows.contains { $0.generatedActionId != nil })

		let reviewRow = DynamicActionDisplayModel(
			id: UUID(),
			title: "Draft preview",
			shortDescription: "meta",
			category: .writing,
			assistanceCategoryReason: .intent,
			workflowLabel: "writing",
			confidenceBucket: "medium",
			safetyBadge: .reviewRequired,
			reviewRequired: true,
			primitiveLabels: ["draft"],
			reasonChips: ["preview_only"],
			interruptionCostBucket: "low",
			sourceIntentType: SynthesizedIntentType.draftReply.rawValue,
			source: .generatedAction,
			isExecutable: false,
			isPreviewOnly: true
		)
		let snapRev = build(input: InlineAssistanceBuildInput(
			context: ctx,
			staticActions: [],
			currentProposal: nil,
			currentProposalKey: nil,
			generatedPreviewItems: [reviewRow],
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: nil,
			pointer: nil,
			fused: fusedFresh
		))
		a("review_preview", snapRev.rows.contains { $0.previewOnly && $0.surfaceType == .disabledPreviewChip })

		let typingBurst = TypingActivityContext(
			id: UUID(),
			updatedAt: t0,
			appName: "T",
			bundleIdentifier: "t",
			isTypingActive: true,
			typingState: .burst,
			recentEventCount: 30,
			burstIntensity: .high,
			sessionDuration: 4,
			idleDuration: 0.05,
			estimatedEditingActivity: 0.95
		)
		let weakGen = DynamicActionDisplayModel(
			id: UUID(),
			title: "Weak",
			shortDescription: "m",
			category: .research,
			assistanceCategoryReason: .workflow,
			workflowLabel: "research",
			confidenceBucket: "low",
			safetyBadge: .safeReadOnly,
			reviewRequired: false,
			primitiveLabels: ["summarize"],
			reasonChips: ["preview_only"],
			interruptionCostBucket: "low",
			sourceIntentType: SynthesizedIntentType.summarizeCurrentArticle.rawValue,
			source: .generatedAction,
			isExecutable: false,
			isPreviewOnly: true
		)
		let snapBurst = build(input: InlineAssistanceBuildInput(
			context: ctx,
			staticActions: [],
			currentProposal: nil,
			currentProposalKey: nil,
			generatedPreviewItems: [weakGen],
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: typingBurst,
			pointer: nil,
			fused: fusedFresh
		))
		a("burst_weak_suppressed", snapBurst.rows.isEmpty)

		let fusedStale = FusedContextPacket(
			id: UUID(),
			createdAt: t0,
			primarySource: .selectedText,
			availableSources: [.selectedText],
			staleSources: [.selectedText],
			appName: "Xcode",
			bundleIdentifier: "com.apple.dt.Xcode",
			windowTitleAvailable: false,
			primaryTextSource: .selectedText,
			textAvailability: true,
			textLength: 40,
			lineCount: 2,
			hasSelectedText: true,
			hasClipboardText: false,
			hasOCRText: false,
			hasAXText: false,
			hasWindowSnapshot: false,
			hasVisualDescriptor: false,
			hasTypingActivity: false,
			hasPointerActivity: false,
			visualKinds: [],
			uiStructureHints: [],
			typingState: .idle,
			pointerState: .idle,
			confidence: 0.2,
			freshnessScore: 0.1,
			conflictScore: 0.4,
			isStale: true,
			suppressedSources: [],
			supportingSources: [],
			arbitrationReasons: [],
			debugSummaryMetadata: [:]
		)
		let snapStale = build(input: InlineAssistanceBuildInput(
			context: ctx,
			staticActions: staticActs,
			currentProposal: nil,
			currentProposalKey: nil,
			generatedPreviewItems: [],
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: nil,
			pointer: nil,
			fused: fusedStale
		))
		a("stale_eligibility", snapStale.rows.isEmpty && !snapStale.eligibility.reasonCodes.isEmpty)

		let snapCap = build(input: InlineAssistanceBuildInput(
			context: ctx,
			staticActions: staticActs,
			currentProposal: nil,
			currentProposalKey: nil,
			generatedPreviewItems: [genRow, reviewRow, weakGen],
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: nil,
			pointer: nil,
			fused: fusedFresh
		))
		a("max_two", snapCap.rows.count <= InlineAssistanceSafetyPolicy.maxCandidates)

		a("chips_align", snapCap.candidates.count == snapCap.rows.count)
		a("all_non_exec", snapCap.rows.allSatisfy { !$0.executable } && snapStrong.rows.allSatisfy { !$0.executable })

		let snapDup = build(input: InlineAssistanceBuildInput(
			context: ctx,
			staticActions: [],
			currentProposal: ActionProposal(title: "E", sourceCaption: "", primaryActionId: "explain_text", secondaryActionIds: [], confidence: 0.75, reason: "t"),
			currentProposalKey: "dup",
			generatedPreviewItems: [genRow],
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: nil,
			pointer: nil,
			fused: fusedFresh
		))
		a("dup_panel_only", snapDup.rows.contains { $0.generatedActionId != nil && $0.placementHint == .assistantPanelOnly })

		let snapUnsafe = build(input: InlineAssistanceBuildInput(
			context: ctx,
			staticActions: [("malicious_action", "Bad")],
			currentProposal: nil,
			currentProposalKey: nil,
			generatedPreviewItems: [],
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: nil,
			pointer: nil,
			fused: fusedFresh
		))
		a("unsafe_skipped", !snapUnsafe.rows.contains { $0.sourceActionId == "malicious_action" })

		let wfUnknown = WorkflowInferenceResult(
			workflow: .unknown,
			confidence: 0.12,
			contributingSignals: [],
			inferredAt: t0,
			isStale: false,
			summaryHint: nil,
			sourceFusedId: nil
		)
		_ = wfUnknown
		var ctxWeak = ContextModel()
		ctxWeak.selectedTextAvailable = false
		ctxWeak.selectedTextLength = 0
		let fusedWeak = FusedContextPacket(
			id: UUID(),
			createdAt: t0,
			primarySource: .none,
			availableSources: [.activeApp],
			staleSources: [],
			appName: "Xcode",
			bundleIdentifier: "com.apple.dt.Xcode",
			windowTitleAvailable: false,
			primaryTextSource: .none,
			textAvailability: false,
			textLength: 0,
			lineCount: 0,
			hasSelectedText: false,
			hasClipboardText: false,
			hasOCRText: false,
			hasAXText: false,
			hasWindowSnapshot: false,
			hasVisualDescriptor: false,
			hasTypingActivity: false,
			hasPointerActivity: false,
			visualKinds: [],
			uiStructureHints: [],
			typingState: .idle,
			pointerState: .idle,
			confidence: 0.14,
			freshnessScore: 0.42,
			conflictScore: 0.5,
			isStale: false,
			suppressedSources: [],
			supportingSources: [],
			arbitrationReasons: [],
			debugSummaryMetadata: ["weak": "1"]
		)
		let snapUnknownWeak = build(input: InlineAssistanceBuildInput(
			context: ctxWeak,
			staticActions: [],
			currentProposal: nil,
			currentProposalKey: nil,
			generatedPreviewItems: [],
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: nil,
			pointer: nil,
			fused: fusedWeak
		))
		a("unknown_weak_empty", snapUnknownWeak.rows.isEmpty)

		let tBlocked = Date(timeIntervalSince1970: 2_070_000_000)
		let wfB = WorkflowInferenceResult(
			workflow: .research,
			confidence: 0.7,
			contributingSignals: ["t"],
			inferredAt: tBlocked,
			isStale: false,
			summaryHint: nil,
			sourceFusedId: nil
		)
		let sessionB = ContextualSessionState(
			continuityScore: 0.5,
			continuityConfidence: 0.5,
			patternConfidence: 0.5,
			dominantWorkflow: .research,
			activeTrajectorySummary: "r",
			contributingSignals: [],
			updatedAt: tBlocked,
			isStale: false
		)
		var badProf = GeneratedActionSafetyProfile.profile(for: [.explain])
		badProf.usesShell = true
		let blockedAct = GeneratedAction(
			id: UUID(),
			title: "Blocked action title",
			description: "Blocked description",
			intentType: .explainLikelyError,
			confidence: 0.7,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			primitives: [.explain],
			interruptionCost: 0.4,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["t"],
			createdAt: tBlocked,
			expiresAt: tBlocked.addingTimeInterval(120),
			isStale: false,
			safetyProfile: badProf,
			explainabilitySummary: "intent_type=explain|primitives=explain",
			source: .selfTest,
			structuredExplainability: nil
		)
		let sumBlockedOnly = DynamicActionDisplayBuilder.build(actions: [blockedAct], plans: [], workflow: wfB, session: sessionB)
		a("blocked_not_in_preview", sumBlockedOnly.previewItems.isEmpty)
		let snapBlockedInline = build(input: InlineAssistanceBuildInput(
			context: ctx,
			staticActions: [],
			currentProposal: nil,
			currentProposalKey: nil,
			generatedPreviewItems: sumBlockedOnly.previewItems,
			isManualInvocation: false,
			isActionExecuting: false,
			lastDismissedProposalActionId: nil,
			typing: nil,
			pointer: nil,
			fused: fusedFresh
		))
		a("blocked_no_candidate", snapBlockedInline.rows.isEmpty)

		a("preview_only_policy", (snapCap.rows + snapStrong.rows + snapGen.rows).allSatisfy { row in
			if row.previewOnly { return true }
			guard let sid = row.sourceActionId else { return false }
			return InlineAssistanceSafetyPolicy.isKnownReadOnlyStaticAction(sid)
		})

		let ok = failures.isEmpty
		print("[InlineAssistance] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}
