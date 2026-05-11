import Foundation

/// Panel rules for showing generated-action previews outside debug-only UI (T16.1).
/// Metadata-only: no raw user content, bounded list, no execution.
enum VisibleGeneratedActionPanelAdapter {
	static let maxVisiblePreviews = 2

	/// Up to `maxVisiblePreviews` non-blocked preview rows, excluding session-dismissed ids.
	static func visiblePreviews(from summary: DynamicActionDisplaySummary, excluding dismissed: Set<UUID>) -> [DynamicActionDisplayModel] {
		Array(summary.previewItems.filter { !dismissed.contains($0.id) }.prefix(maxVisiblePreviews))
	}

	/// Single-line “why” copy from existing display fields only (no raw context).
	static func whyAppearedLine(for model: DynamicActionDisplayModel) -> String {
		let extras = model.reasonChips.filter { $0 != "preview_only" }.prefix(5).joined(separator: " · ")
		let base = "\(model.workflowLabel) workflow · \(model.category.rawValue) · confidence \(model.confidenceBucket)"
		if extras.isEmpty { return base }
		return base + " · " + extras
	}

	// MARK: - Logging (metadata-only)

	private static let logLock = NSLock()
	private static var lastShownSig: String?
	private static var lastShownAt: Date?
	private static var lastHiddenSig: String?
	private static var lastHiddenAt: Date?
	private static var lastExpandSig: String?
	private static var lastExpandAt: Date?

	static func logPanelShownIfNeeded(rows: [DynamicActionDisplayModel], groupLabel: String? = nil) {
		let n = rows.count
		guard n > 0 else { return }
		let top = rows.first?.sourceIntentType ?? "none"
		let cat = rows.first?.category.rawValue ?? "none"
		let gl = groupLabel.map { String($0.prefix(48)) } ?? ""
		let sig = "\(n)|\(top)|\(cat)|\(gl)"
		let now = Date()
		logLock.lock()
		let skip: Bool
		if lastShownSig == sig, let t = lastShownAt, now.timeIntervalSince(t) < 1.4 {
			skip = true
		} else {
			lastShownSig = sig
			lastShownAt = now
			skip = false
		}
		logLock.unlock()
		if skip { return }
		print("[VisibleGeneratedAction] shown count=\(n) top=\(top) category=\(cat)")
		if let groupLabel, !groupLabel.isEmpty {
			print("[WorkflowActionOrdering] grouped label=\(String(groupLabel.prefix(48)))")
		}
	}

	static func logPanelHiddenIfNeeded() {
		let sig = "none"
		let now = Date()
		logLock.lock()
		let skip: Bool
		if lastHiddenSig == sig, let t = lastHiddenAt, now.timeIntervalSince(t) < 2.0 {
			skip = true
		} else {
			lastHiddenSig = sig
			lastHiddenAt = now
			skip = false
		}
		logLock.unlock()
		if skip { return }
		print("[VisibleGeneratedAction] hidden reason=no_items")
	}

	static func logDismissed(id: UUID) {
		let h = String(id.uuidString.prefix(8))
		print("[VisibleGeneratedAction] dismissed idHash=\(h)")
	}

	static func logExpanded(id: UUID) {
		let h = String(id.uuidString.prefix(8))
		let now = Date()
		logLock.lock()
		let skip: Bool
		if lastExpandSig == h, let t = lastExpandAt, now.timeIntervalSince(t) < 0.9 {
			skip = true
		} else {
			lastExpandSig = h
			lastExpandAt = now
			skip = false
		}
		logLock.unlock()
		if skip { return }
		print("[VisibleGeneratedAction] expanded idHash=\(h)")
	}

	// MARK: - DEBUG self-test

	static func runSelfTest() -> Bool {
		print("[VisibleGeneratedAction] selftest starting")
		var failures: [String] = []
		let t0 = Date(timeIntervalSince1970: 2_090_000_000)

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		func row(
			id: UUID,
			title: String,
			badge: DynamicActionDisplaySafetyBadge,
			review: Bool,
			chips: [String]
		) -> DynamicActionDisplayModel {
			DynamicActionDisplayModel(
				id: id,
				title: title,
				shortDescription: "Metadata-only short line.",
				category: .debugging,
				workflowLabel: "debugging",
				confidenceBucket: "medium",
				safetyBadge: badge,
				reviewRequired: review,
				primitiveLabels: ["explain"],
				reasonChips: chips,
				interruptionCostBucket: "medium",
				sourceIntentType: "explain_likely_error",
				source: .generatedAction,
				isExecutable: false,
				isPreviewOnly: true
			)
		}

		let empty = DynamicActionDisplaySummary(previewItems: [], blockedDebugLines: [], blockedSkippedTotal: 0, previewGroupLabel: nil)
		assertCase("no_items_empty", visiblePreviews(from: empty, excluding: []).isEmpty)

		let one = DynamicActionDisplaySummary(
			previewItems: [row(id: UUID(), title: "Explain likely error", badge: .safeReadOnly, review: false, chips: ["preview_only", "rule_debugging_base"])],
			blockedDebugLines: [],
			blockedSkippedTotal: 0,
			previewGroupLabel: "Debugging suggestions"
		)
		let v1 = visiblePreviews(from: one, excluding: [])
		assertCase("one_visible", v1.count == 1 && v1[0].isPreviewOnly && !v1[0].isExecutable)

		let idA = UUID(), idB = UUID(), idC = UUID()
		let three = DynamicActionDisplaySummary(
			previewItems: [
				row(id: idA, title: "A", badge: .safeReadOnly, review: false, chips: ["preview_only"]),
				row(id: idB, title: "B", badge: .safeReadOnly, review: false, chips: ["preview_only"]),
				row(id: idC, title: "C", badge: .safeReadOnly, review: false, chips: ["preview_only"])
			],
			blockedDebugLines: [],
			blockedSkippedTotal: 0,
			previewGroupLabel: nil
		)
		assertCase("max_two", visiblePreviews(from: three, excluding: []).count == maxVisiblePreviews)

		let vd = visiblePreviews(from: three, excluding: [idA])
		assertCase("dismiss_filters", !vd.contains { $0.id == idA } && vd.count <= maxVisiblePreviews)

		let reviewRow = row(id: UUID(), title: "Draft", badge: .reviewRequired, review: true, chips: ["preview_only", "draft"])
		let revSummary = DynamicActionDisplaySummary(previewItems: [reviewRow], blockedDebugLines: [], blockedSkippedTotal: 0, previewGroupLabel: nil)
		let vr = visiblePreviews(from: revSummary, excluding: [])[0]
		assertCase("review_badge", vr.safetyBadge == .reviewRequired && vr.reviewRequired)

		let why = whyAppearedLine(for: v1[0])
		assertCase("why_metadata", !why.contains("://") && !why.contains("\n") && why.contains("debugging"))

		assertCase("preview_flag", v1[0].isPreviewOnly && v1[0].isExecutable == false)

		let explainIntent = SynthesizedIntent(
			id: UUID(),
			type: .explainLikelyError,
			title: "Explain likely error",
			description: "D",
			confidence: 0.72,
			workflow: .debugging,
			requiredContext: [.textSnippet],
			supportingSignals: ["st"],
			interruptionCost: 0.33,
			freshness: 0.8,
			createdAt: t0,
			isStale: false,
			sourceReasonCodes: ["rule_debugging_base"]
		)
		if case .produced(let safeAct) = GeneratedActionFactory.materialize(from: explainIntent, referenceTime: t0, source: .selfTest) {
			var badProf = GeneratedActionSafetyProfile.profile(for: [.explain])
			badProf.usesShell = true
			let blockedAct = GeneratedAction(
				id: UUID(),
				title: "Blocked",
				description: "B",
				intentType: .explainLikelyError,
				confidence: 0.7,
				workflow: .debugging,
				requiredContext: [.textSnippet],
				primitives: [.explain],
				interruptionCost: 0.4,
				workflowRelevance: 0.7,
				sourceIntentId: UUID(),
				sourceReasonCodes: ["t"],
				createdAt: t0,
				expiresAt: t0.addingTimeInterval(120),
				isStale: false,
				safetyProfile: badProf,
				explainabilitySummary: "intent_type=explain|primitives=explain",
				source: .selfTest,
				structuredExplainability: nil
			)
			let built = DynamicActionDisplayBuilder.build(actions: [safeAct, blockedAct], plans: [], workflow: nil, session: nil)
			assertCase("builder_blocked_absent", !built.previewItems.contains { $0.id == blockedAct.id } && built.blockedSkippedTotal >= 1)
		} else {
			assertCase("builder_safe_materialize", false)
		}

		let ok = failures.isEmpty
		print("[VisibleGeneratedAction] selftest summary failures=\(failures.count) detail=\(failures.joined(separator: ";")) ok=\(ok)")
		return ok
	}
}
