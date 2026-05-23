import Foundation

// MARK: - Types (T16.9 session-local interaction tracking; no persistence)

enum GeneratedActionInteractionOutcome: String, Hashable, Sendable, Codable, CaseIterable {
	case shown
	case ignored
	case dismissed
	case expanded
	case acceptedProxy
	case repeatedUseful
	case expired
}

enum GeneratedActionInteractionSurface: String, Hashable, Sendable, Codable, CaseIterable {
	case generatedPreview
	case proposalCard
	case inlineCandidateDebug
	case debugOnly
	case unknown
}

struct GeneratedActionInteractionEvent: Equatable, Sendable {
	let id: UUID
	let targetIdPrefix: String
	let assistanceCategory: String
	let intentType: String
	let workflow: String
	let primitiveLabelsJoined: String
	let safetyBadge: String
	let timestamp: Date
	let outcome: GeneratedActionInteractionOutcome
	let surface: GeneratedActionInteractionSurface
	let relatedStaticActionId: String?
}

struct GeneratedActionUsefulnessSignal: Equatable, Sendable {
	let fingerprint: String
	let score: Double
	let lastUpdated: Date
}

struct GeneratedActionInteractionSnapshot: Equatable, Sendable {
	let recentEventCount: Int
	let topUsefulCategory: String?
	let recentDismissedCategory: String?
	let ignoredCount: Int
	let acceptedProxyCount: Int
	let expandedCount: Int
}

// MARK: - Tracker

/// In-memory, bounded interaction signals for generated preview UX (no persistence; no raw context).
final class GeneratedActionInteractionTracker {
	static let shared = GeneratedActionInteractionTracker()

	private let lock = NSLock()
	private var events: [GeneratedActionInteractionEvent] = []
	private let maxEvents = 50

	private var usefulnessByFingerprint: [String: GeneratedActionUsefulnessSignal] = [:]
	private var lastDecayAt: Date?

	private struct PendingImpression: Equatable {
		let shownAt: Date
		let fingerprint: String
		let assistanceCategory: String
		let intentType: String
		let workflow: String
		let primitiveLabels: String
		let safetyBadge: String
		let surface: GeneratedActionInteractionSurface
	}

	private var pendingByPreviewId: [UUID: PendingImpression] = [:]
	private var lastVisiblePreviewIds: Set<UUID> = []
	private var recentDismissedCategory: String?
	private var lastRepeatedUsefulEmit: [String: Date] = [:]

	static let ignoredWindowSecondsForTests: TimeInterval = 40
	private let ignoredWindowSeconds: TimeInterval = 40
	private let decayTauSeconds: TimeInterval = 320
	private let acceptedProxyWindow: TimeInterval = 95

	private init() {}

	func reset() {
		lock.lock()
		events.removeAll()
		usefulnessByFingerprint.removeAll()
		pendingByPreviewId.removeAll()
		lastVisiblePreviewIds.removeAll()
		recentDismissedCategory = nil
		lastRepeatedUsefulEmit.removeAll()
		lastDecayAt = nil
		lock.unlock()
	}

	/// Call once per display refresh before rebuilding previews (decay + ignored flush).
	func beginDisplayBuild(referenceTime: Date = Date()) {
		lock.lock()
		decayLocked(referenceTime: referenceTime)
		flushExpiredPendingLocked(referenceTime: referenceTime)
		lock.unlock()
	}

	func onPreviewRowsVisible(_ rows: [DynamicActionDisplayModel], surface: GeneratedActionInteractionSurface, referenceTime: Date = Date()) {
		let newRows = rows.filter { !lastVisiblePreviewIds.contains($0.id) }
		lock.lock()
		decayLocked(referenceTime: referenceTime)
		flushExpiredPendingLocked(referenceTime: referenceTime)
		let visibleSet = Set(rows.map(\.id))
		for row in newRows {
			let fp = Self.fingerprint(for: row)
			if pendingByPreviewId[row.id] == nil {
				pendingByPreviewId[row.id] = PendingImpression(
					shownAt: referenceTime,
					fingerprint: fp,
					assistanceCategory: row.category.rawValue,
					intentType: row.sourceIntentType,
					workflow: row.workflowLabel,
					primitiveLabels: Self.clampPrimitives(row.primitiveLabels),
					safetyBadge: row.safetyBadge.rawValue,
					surface: surface
				)
				appendEventLocked(outcome: .shown, row: row, surface: surface, relatedStatic: nil, at: referenceTime)
			}
		}
		lastVisiblePreviewIds = visibleSet
		lock.unlock()
		for row in newRows {
			logOutcome(.shown, row: row, relatedStatic: nil)
		}
	}

	func recordDismissed(row: DynamicActionDisplayModel, surface: GeneratedActionInteractionSurface = .generatedPreview, referenceTime: Date = Date(), quietLog: Bool = false) {
		lock.lock()
		decayLocked(referenceTime: referenceTime)
		let fp = Self.fingerprint(for: row)
		pendingByPreviewId.removeValue(forKey: row.id)
		recentDismissedCategory = row.category.rawValue
		appendEventLocked(
			outcome: .dismissed,
			row: row,
			surface: surface,
			relatedStatic: nil,
			at: referenceTime
		)
		bumpFingerprintLocked(fp, delta: -0.25, at: referenceTime, outcomeHint: .dismissed)
		lock.unlock()
		if !quietLog {
			logOutcome(.dismissed, row: row, relatedStatic: nil)
		}
	}

	func recordExpanded(row: DynamicActionDisplayModel, surface: GeneratedActionInteractionSurface = .generatedPreview, referenceTime: Date = Date()) {
		lock.lock()
		decayLocked(referenceTime: referenceTime)
		let fp = Self.fingerprint(for: row)
		pendingByPreviewId.removeValue(forKey: row.id)
		appendEventLocked(
			outcome: .expanded,
			row: row,
			surface: surface,
			relatedStatic: nil,
			at: referenceTime
		)
		bumpFingerprintLocked(fp, delta: 0.10, at: referenceTime, outcomeHint: .expanded)
		lock.unlock()
		logOutcome(.expanded, row: row, relatedStatic: nil)
	}

	/// Conservative proxy: static action shortly after a visible generated preview with aligned intent.
	func considerAcceptedProxy(staticActionId: String, referenceTime: Date = Date()) {
		lock.lock()
		decayLocked(referenceTime: referenceTime)
		var matchedPreviewId: UUID?
		var matchedPending: PendingImpression?
		for (pid, p) in pendingByPreviewId {
			if Self.staticActionIdsMatchingIntent(p.intentType).contains(staticActionId) {
				if referenceTime.timeIntervalSince(p.shownAt) <= acceptedProxyWindow {
					matchedPreviewId = pid
					matchedPending = p
					break
				}
			}
		}
		if let pid = matchedPreviewId, let pend = matchedPending {
			pendingByPreviewId.removeValue(forKey: pid)
			let row = syntheticRow(from: pend, previewId: pid)
			appendEventLocked(
				outcome: .acceptedProxy,
				row: row,
				surface: .generatedPreview,
				relatedStatic: staticActionId,
				at: referenceTime
			)
			bumpFingerprintLocked(pend.fingerprint, delta: 0.20, at: referenceTime, outcomeHint: .acceptedProxy)
			let scoreSnap = usefulnessByFingerprint[pend.fingerprint]?.score ?? 0
			lock.unlock()
			logOutcome(.acceptedProxy, row: row, relatedStatic: staticActionId)
			print("[GeneratedActionInteraction] usefulness category=\(pend.assistanceCategory) score=\(String(format: "%.2f", scoreSnap))")
			return
		}
		lock.unlock()
	}

	func snapshot(referenceTime: Date = Date()) -> GeneratedActionInteractionSnapshot {
		lock.lock()
		decayLocked(referenceTime: referenceTime)
		let ev = events
		let ignoredN = ev.filter { $0.outcome == .ignored }.count
		let proxyN = ev.filter { $0.outcome == .acceptedProxy }.count
		let expN = ev.filter { $0.outcome == .expanded }.count
		let topCat = usefulnessByFingerprint.max(by: { $0.value.score < $1.value.score })?.key.split(separator: "|").first.map(String.init)
		let snap = GeneratedActionInteractionSnapshot(
			recentEventCount: ev.count,
			topUsefulCategory: topCat,
			recentDismissedCategory: recentDismissedCategory,
			ignoredCount: ignoredN,
			acceptedProxyCount: proxyN,
			expandedCount: expN
		)
		lock.unlock()
		return snap
	}

	func debugSummaryLine(referenceTime: Date = Date()) -> String {
		lock.lock()
		let hasData = !events.isEmpty || !usefulnessByFingerprint.isEmpty
		lock.unlock()
		guard hasData else { return "" }
		let s = snapshot(referenceTime: referenceTime)
		let top = s.topUsefulCategory ?? "none"
		let dis = s.recentDismissedCategory ?? "none"
		return "GA interaction: events=\(s.recentEventCount) ignored=\(s.ignoredCount) expanded=\(s.expandedCount) proxies=\(s.acceptedProxyCount) topCat=\(top) lastDismissCat=\(dis)"
	}

	// MARK: - Ranking hooks

	func sortAdjustment(forAction a: GeneratedAction, referenceTime: Date = Date()) -> Double {
		lock.lock()
		decayLocked(referenceTime: referenceTime)
		let fp = Self.fingerprint(for: a)
		let raw = usefulnessByFingerprint[fp]?.score ?? 0.0
		var adj = min(0.38, max(-0.38, raw * 0.42))
		if let recent = recentDismissedCategory, recent == GeneratedAssistanceCategoryMapper.mapAction(a).category.rawValue {
			adj -= 0.12
		}
		lock.unlock()
		return adj
	}

	func sortAdjustment(forPlan p: GeneratedActionPlan, referenceTime: Date = Date()) -> Double {
		lock.lock()
		decayLocked(referenceTime: referenceTime)
		let fp = Self.fingerprint(for: p)
		let raw = usefulnessByFingerprint[fp]?.score ?? 0.0
		var adj = min(0.36, max(-0.36, raw * 0.40))
		lock.unlock()
		return adj
	}

	// MARK: - Self-test

	static func runSelfTest() -> Bool {
		print("[GeneratedActionInteraction] selftest starting")
		var failures: [String] = []
		func a(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let t0 = Date(timeIntervalSince1970: 2_130_000_000)
		let tr = shared
		tr.reset()

		let row = DynamicActionDisplayModel(
			id: UUID(),
			title: "Explain preview",
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
			isPreviewOnly: true,
			executionCandidateId: nil
		)

		tr.recordShownFromRow(row, surface: .generatedPreview, at: t0)
		a("shown_recorded", tr.eventsCountForTests() >= 1 && tr.lastOutcomeForTests() == .shown)

		tr.recordDismissed(row: row, surface: .generatedPreview, referenceTime: t0)
		a("dismiss_recorded", tr.lastOutcomeForTests() == .dismissed)

		let row2 = DynamicActionDisplayModel(
			id: UUID(),
			title: "Explain two",
			shortDescription: "m",
			category: .debugging,
			assistanceCategoryReason: .intent,
			workflowLabel: "debugging",
			confidenceBucket: "medium",
			safetyBadge: .safeReadOnly,
			reviewRequired: false,
			primitiveLabels: ["explain"],
			reasonChips: ["preview_only"],
			interruptionCostBucket: "low",
			sourceIntentType: SynthesizedIntentType.explainLikelyError.rawValue,
			source: .generatedAction,
			isExecutable: false,
			isPreviewOnly: true,
			executionCandidateId: nil
		)
		tr.recordShownFromRow(row2, surface: .generatedPreview, at: t0)
		let adjNeg = tr.sortAdjustment(forAction: Self.minimalGA(intent: .explainLikelyError, categoryWorkflow: .debugging, confidence: 0.9, at: t0), referenceTime: t0)
		a("dismiss_downrank", adjNeg < 0)

		tr.reset()
		tr.recordShownFromRow(row, surface: .generatedPreview, at: t0)
		tr.recordExpanded(row: row, surface: .generatedPreview, referenceTime: t0)
		let adjPos = tr.sortAdjustment(forAction: Self.minimalGA(intent: .explainLikelyError, categoryWorkflow: .debugging, confidence: 0.55, at: t0), referenceTime: t0)
		a("expand_boost", adjPos > 0)

		tr.reset()
		tr.recordShownFromRow(row, surface: .generatedPreview, at: t0)
		tr.considerAcceptedProxy(staticActionId: "explain_text", referenceTime: t0.addingTimeInterval(4))
		a("proxy_recorded", tr.lastOutcomeForTests() == .acceptedProxy)

		tr.reset()
		tr.recordShownFromRow(row, surface: .generatedPreview, at: t0)
		tr.beginDisplayBuild(referenceTime: t0.addingTimeInterval(Self.ignoredWindowSecondsForTests + 8))
		let ignoredN = tr.snapshot().ignoredCount
		a("ignored_after_window", ignoredN >= 1)

		for i in 0..<55 {
			let r = DynamicActionDisplayModel(
				id: UUID(),
				title: "T\(i)",
				shortDescription: "m",
				category: .research,
				assistanceCategoryReason: .workflow,
				workflowLabel: "research",
				confidenceBucket: "low",
				safetyBadge: .previewOnly,
				reviewRequired: false,
				primitiveLabels: ["summarize"],
				reasonChips: ["preview_only"],
				interruptionCostBucket: "low",
				sourceIntentType: SynthesizedIntentType.summarizeCurrentArticle.rawValue,
				source: .generatedAction,
				isExecutable: false,
				isPreviewOnly: true,
			executionCandidateId: nil
			)
			tr.recordDismissed(row: r, surface: .debugOnly, referenceTime: t0.addingTimeInterval(Double(i) * 0.01), quietLog: true)
		}
		a("ring_bounded", tr.eventsCountForTests() <= 50)

		tr.reset()
		a("reset_empty", tr.eventsCountForTests() == 0 && tr.snapshot().recentEventCount == 0)

		tr.recordShownFromRow(row, surface: .generatedPreview, at: t0)
		tr.recordDismissed(row: row, surface: .generatedPreview, referenceTime: t0)
		tr.bumpFingerprintForTests("debugging|explain_likely_error", 5.0, at: t0)
		tr.clampUsefulnessForTests(at: t0)
		let sc = tr.scoreForTests("debugging|explain_likely_error")
		a("score_clamped", sc <= 1.02 && sc >= -1.02)

		tr.reset()
		tr.recordShownFromRow(row, surface: .generatedPreview, at: t0)
		tr.recordExpanded(row: row, referenceTime: t0)
		tr.beginDisplayBuild(referenceTime: t0.addingTimeInterval(200))
		let sc2 = tr.scoreForTests("\(row.category.rawValue)|\(row.sourceIntentType)")
		a("decay_reduces", sc2 < 0.15)

		// `DynamicActionDisplayBuilder.build` calls `beginDisplayBuild` + `sortAdjustment` (integration smoke).
		tr.reset()
		let tOrd = Date(timeIntervalSince1970: 2_131_500_000)
		let wfOrd = WorkflowInferenceResult(
			workflow: .writing,
			confidence: 0.74,
			contributingSignals: ["w"],
			inferredAt: tOrd,
			isStale: false,
			summaryHint: nil,
			sourceFusedId: nil
		)
		let sessOrd = ContextualSessionState(
			continuityScore: 0.51,
			continuityConfidence: 0.54,
			patternConfidence: 0.53,
			dominantWorkflow: .writing,
			activeTrajectorySummary: "writing",
			contributingSignals: [],
			updatedAt: tOrd,
			isStale: false
		)
		let exIntent = SynthesizedIntent(
			id: UUID(),
			type: .explainLikelyError,
			title: "Explain",
			description: "D",
			confidence: 0.71,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.32,
			freshness: 0.78,
			createdAt: tOrd,
			isStale: false,
			sourceReasonCodes: ["r"]
		)
		let drIntent = SynthesizedIntent(
			id: UUID(),
			type: .draftReply,
			title: "Draft",
			description: "D",
			confidence: 0.69,
			workflow: .writing,
			requiredContext: [.textSnippet],
			supportingSignals: [],
			interruptionCost: 0.38,
			freshness: 0.8,
			createdAt: tOrd,
			isStale: false,
			sourceReasonCodes: ["r"]
		)
		if case .produced(let gaEx) = GeneratedActionFactory.materialize(from: exIntent, referenceTime: tOrd, source: .selfTest),
		   case .produced(let gaDr) = GeneratedActionFactory.materialize(from: drIntent, referenceTime: tOrd, source: .selfTest) {
			let sEx = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(gaEx)
			let eEx = GeneratedActionExplanationBuilder.buildForAction(action: gaEx, safety: sEx, referenceTime: tOrd, fusedOverride: nil)
			let gaExW = gaEx.withStructuredExplainability(eEx)
			let sDr = GeneratedActionSafetyPolicy.evaluateActionSnapshotForDebug(gaDr)
			let eDr = GeneratedActionExplanationBuilder.buildForAction(action: gaDr, safety: sDr, referenceTime: tOrd, fusedOverride: nil)
			let gaDrW = gaDr.withStructuredExplainability(eDr)
			let sumOrd1 = DynamicActionDisplayBuilder.build(actions: [gaExW, gaDrW], plans: [], workflow: wfOrd, session: sessOrd)
			a("display_builder_previews", !sumOrd1.previewItems.isEmpty)
			if let top = sumOrd1.previewItems.first {
				tr.recordDismissed(row: top, surface: .generatedPreview, referenceTime: tOrd)
			}
			let sumOrd2 = DynamicActionDisplayBuilder.build(actions: [gaExW, gaDrW], plans: [], workflow: wfOrd, session: sessOrd)
			a("display_builder_second_pass", sumOrd2.previewItems.count <= 2)
		} else {
			a("order_materialize", false)
		}

		let ok = failures.isEmpty
		print("[GeneratedActionInteraction] selftest failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}

	// MARK: - Test hooks (DEBUG only usage)

	private func eventsCountForTests() -> Int {
		lock.lock()
		let n = events.count
		lock.unlock()
		return n
	}

	private func lastOutcomeForTests() -> GeneratedActionInteractionOutcome? {
		lock.lock()
		let o = events.last?.outcome
		lock.unlock()
		return o
	}

	private func bumpFingerprintForTests(_ fp: String, _ delta: Double, at: Date) {
		lock.lock()
		bumpFingerprintLocked(fp, delta: delta, at: at, outcomeHint: .shown)
		lock.unlock()
	}

	private func clampUsefulnessForTests(at: Date) {
		lock.lock()
		for (k, v) in usefulnessByFingerprint {
			let c = min(1.0, max(-1.0, v.score))
			usefulnessByFingerprint[k] = GeneratedActionUsefulnessSignal(fingerprint: k, score: c, lastUpdated: at)
		}
		lock.unlock()
	}

	private func scoreForTests(_ fp: String) -> Double {
		lock.lock()
		let s = usefulnessByFingerprint[fp]?.score ?? 0
		lock.unlock()
		return s
	}

	// MARK: - Internal

	func recordShownFromRow(_ row: DynamicActionDisplayModel, surface: GeneratedActionInteractionSurface, at: Date = Date()) {
		onPreviewRowsVisible([row], surface: surface, referenceTime: at)
	}

	private func appendEventLocked(
		outcome: GeneratedActionInteractionOutcome,
		row: DynamicActionDisplayModel,
		surface: GeneratedActionInteractionSurface,
		relatedStatic: String?,
		at: Date
	) {
		let ev = GeneratedActionInteractionEvent(
			id: UUID(),
			targetIdPrefix: String(row.id.uuidString.prefix(8)),
			assistanceCategory: row.category.rawValue,
			intentType: row.sourceIntentType,
			workflow: row.workflowLabel,
			primitiveLabelsJoined: Self.clampPrimitives(row.primitiveLabels),
			safetyBadge: row.safetyBadge.rawValue,
			timestamp: at,
			outcome: outcome,
			surface: surface,
			relatedStaticActionId: relatedStatic
		)
		events.append(ev)
		if events.count > maxEvents {
			events.removeFirst(events.count - maxEvents)
		}
	}

	private func flushExpiredPendingLocked(referenceTime: Date) {
		var toRemove: [UUID] = []
		for (id, p) in pendingByPreviewId {
			if referenceTime.timeIntervalSince(p.shownAt) >= ignoredWindowSeconds {
				toRemove.append(id)
				let row = syntheticRow(from: p, previewId: id)
				appendEventLocked(outcome: .ignored, row: row, surface: p.surface, relatedStatic: nil, at: referenceTime)
				bumpFingerprintLocked(p.fingerprint, delta: -0.10, at: referenceTime, outcomeHint: .ignored)
				logOutcome(.ignored, row: row, relatedStatic: nil)
			}
		}
		for id in toRemove {
			pendingByPreviewId.removeValue(forKey: id)
		}
	}

	private func bumpFingerprintLocked(_ fp: String, delta: Double, at: Date, outcomeHint: GeneratedActionInteractionOutcome) {
		let cur = usefulnessByFingerprint[fp]?.score ?? 0
		var next = min(1.0, max(-1.0, cur + delta))
		usefulnessByFingerprint[fp] = GeneratedActionUsefulnessSignal(fingerprint: fp, score: next, lastUpdated: at)

		if next >= 0.22, cur < 0.18, outcomeHint == .acceptedProxy || outcomeHint == .expanded {
			let last = lastRepeatedUsefulEmit[fp] ?? .distantPast
			if at.timeIntervalSince(last) > 120 {
				lastRepeatedUsefulEmit[fp] = at
				let row = syntheticFingerprintRow(fp: fp, at: at)
				appendEventLocked(outcome: .repeatedUseful, row: row, surface: .debugOnly, relatedStatic: nil, at: at)
				next = min(1.0, next + 0.10)
				usefulnessByFingerprint[fp] = GeneratedActionUsefulnessSignal(fingerprint: fp, score: next, lastUpdated: at)
				print("[GeneratedActionInteraction] event=repeatedUseful category=\(fp.split(separator: "|").first.map(String.init) ?? "none")")
			}
		}
	}

	private func decayLocked(referenceTime: Date) {
		guard let last = lastDecayAt else {
			lastDecayAt = referenceTime
			return
		}
		let dt = referenceTime.timeIntervalSince(last)
		guard dt > 0.45 else { return }
		let factor = exp(-dt / decayTauSeconds)
		var nextMap: [String: GeneratedActionUsefulnessSignal] = [:]
		for (k, v) in usefulnessByFingerprint {
			let s = v.score * factor
			if abs(s) < 0.018 {
				continue
			}
			nextMap[k] = GeneratedActionUsefulnessSignal(fingerprint: k, score: s, lastUpdated: referenceTime)
		}
		usefulnessByFingerprint = nextMap
		lastDecayAt = referenceTime
	}

	private func syntheticRow(from p: PendingImpression, previewId: UUID) -> DynamicActionDisplayModel {
		DynamicActionDisplayModel(
			id: previewId,
			title: "proxy",
			shortDescription: "m",
			category: GeneratedAssistanceCategory(rawValue: p.assistanceCategory) ?? .utility,
			assistanceCategoryReason: .intent,
			workflowLabel: p.workflow,
			confidenceBucket: "medium",
			safetyBadge: DynamicActionDisplaySafetyBadge(rawValue: p.safetyBadge) ?? .previewOnly,
			reviewRequired: false,
			primitiveLabels: p.primitiveLabels.split(separator: ",").map(String.init),
			reasonChips: ["preview_only"],
			interruptionCostBucket: "low",
			sourceIntentType: p.intentType,
			source: .generatedAction,
			isExecutable: false,
			isPreviewOnly: true,
			executionCandidateId: nil
		)
	}

	private func syntheticFingerprintRow(fp: String, at: Date) -> DynamicActionDisplayModel {
		let parts = fp.split(separator: "|")
		let cat = parts.first.flatMap { GeneratedAssistanceCategory(rawValue: String($0)) } ?? .utility
		let intent = parts.dropFirst().first.map(String.init) ?? "unknown"
		return DynamicActionDisplayModel(
			id: UUID(),
			title: "signal",
			shortDescription: "m",
			category: cat,
			assistanceCategoryReason: .intent,
			workflowLabel: "mixed",
			confidenceBucket: "medium",
			safetyBadge: .safeReadOnly,
			reviewRequired: false,
			primitiveLabels: [],
			reasonChips: ["preview_only"],
			interruptionCostBucket: "low",
			sourceIntentType: intent,
			source: .generatedAction,
			isExecutable: false,
			isPreviewOnly: true,
			executionCandidateId: nil
		)
	}

	private static func clampPrimitives(_ labels: [String]) -> String {
		String(labels.prefix(4).joined(separator: ",").prefix(48))
	}

	private static func fingerprint(for row: DynamicActionDisplayModel) -> String {
		"\(row.category.rawValue)|\(row.sourceIntentType)"
	}

	private static func fingerprint(for a: GeneratedAction) -> String {
		let cat = GeneratedAssistanceCategoryMapper.mapAction(a).category.rawValue
		return "\(cat)|\(a.intentType.rawValue)"
	}

	private static func fingerprint(for p: GeneratedActionPlan) -> String {
		let cat = GeneratedAssistanceCategoryMapper.mapPlan(p).category.rawValue
		return "\(cat)|\(p.intentType.rawValue)"
	}

	private static func staticActionIdsMatchingIntent(_ intentRaw: String) -> [String] {
		guard let it = SynthesizedIntentType(rawValue: intentRaw) else { return [] }
		switch it {
		case .explainLikelyError, .identifyPossibleBugSource, .explainScreenContext, .explainApiResponse:
			return ["explain_text"]
		case .summarizeCurrentArticle:
			return ["summarize_text"]
		case .draftReply, .reviewSelectedText, .turnNotesIntoChecklist:
			return ["rewrite_text"]
		default:
			return []
		}
	}

	private func logOutcome(_ outcome: GeneratedActionInteractionOutcome, row: DynamicActionDisplayModel, relatedStatic: String?) {
		let cat = row.category.rawValue
		let intent = row.sourceIntentType
		switch outcome {
		case .shown:
			print("[GeneratedActionInteraction] event=shown category=\(cat) intent=\(intent)")
		case .dismissed:
			print("[GeneratedActionInteraction] event=dismissed category=\(cat)")
		case .expanded:
			print("[GeneratedActionInteraction] event=expanded category=\(cat)")
		case .ignored:
			print("[GeneratedActionInteraction] event=ignored category=\(cat) intent=\(intent)")
		case .acceptedProxy:
			let sid = relatedStatic ?? "none"
			print("[GeneratedActionInteraction] event=accepted_proxy staticAction=\(sid) category=\(cat)")
		default:
			break
		}
	}

	private static func minimalGA(intent: SynthesizedIntentType, categoryWorkflow: InferredWorkflow, confidence: Double, at: Date) -> GeneratedAction {
		GeneratedAction(
			id: UUID(),
			title: "T",
			description: "D",
			intentType: intent,
			confidence: confidence,
			workflow: categoryWorkflow,
			requiredContext: [.textSnippet],
			primitives: [.explain],
			interruptionCost: 0.3,
			workflowRelevance: 0.7,
			sourceIntentId: UUID(),
			sourceReasonCodes: ["t"],
			createdAt: at,
			expiresAt: at.addingTimeInterval(120),
			isStale: false,
			safetyProfile: .profile(for: [.explain]),
			explainabilitySummary: "intent",
			source: .selfTest,
			structuredExplainability: nil
		)
	}
}
