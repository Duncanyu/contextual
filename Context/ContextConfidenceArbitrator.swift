import Foundation

struct FusedContextSourceCandidate: Hashable, Sendable {
	let source: FusedContextSource
	let isPresent: Bool
	let freshness: Double
	let baseWeight: Double
}

struct ContextArbitrationResult: Hashable, Sendable {
	let confidence: Double
	let conflictScore: Double
	let primarySource: FusedContextSource?
	let suppressedSources: [FusedContextSource]
	let supportingSources: [FusedContextSource]
	let reasonCodes: [String]
}

final class ContextConfidenceArbitrator {
	static let shared = ContextConfidenceArbitrator()
	private let lastLock = NSLock()
	private var lastSnapshot: ContextArbitrationResult?

	private init() {}

	/// Latest arbitration output (metadata only) for debug UI.
	func lastArbitrationSnapshot() -> ContextArbitrationResult? {
		lastLock.lock()
		let s = lastSnapshot
		lastLock.unlock()
		return s
	}

	private func recordArbitrationSnapshot(_ r: ContextArbitrationResult) {
		lastLock.lock()
		lastSnapshot = r
		lastLock.unlock()
	}

	func arbitrate(
		candidates: [FusedContextSourceCandidate],
		basePacket: FusedContextPacket?,
		now _: Date = Date()
	) -> ContextArbitrationResult {
		let present = candidates.filter { $0.isPresent }
		if present.isEmpty {
			let r = ContextArbitrationResult(
				confidence: basePacket?.confidence ?? 0.0,
				conflictScore: basePacket?.conflictScore ?? 0.0,
				primarySource: nil,
				suppressedSources: [],
				supportingSources: [],
				reasonCodes: ["no_candidates"]
			)
			recordArbitrationSnapshot(r)
			return r
		}

		// Suppress clearly stale sources early.
		var suppressed = Set<FusedContextSource>()
		for c in present where c.freshness < 0.15 {
			suppressed.insert(c.source)
		}

		let hasSelection = present.contains(where: { $0.source == .selectedText && $0.freshness >= 0.30 })
		let axFresh = present.first(where: { $0.source == .axText })?.freshness ?? 0
		let clipFresh = present.first(where: { $0.source == .clipboardText })?.freshness ?? 0
		let ocrFresh = present.first(where: { $0.source == .screenOCR })?.freshness ?? 0

		if hasSelection {
			// Fresh selection is intentionally high priority: suppress stale clipboard/OCR so they don't distort confidence.
			if clipFresh < 0.25 { suppressed.insert(.clipboardText) }
			if ocrFresh < 0.25 { suppressed.insert(.screenOCR) }
		}

		// Stale clipboard vs fresh AX: suppress clipboard when AX is clearly fresher.
		if axFresh >= 0.45, clipFresh < 0.25 {
			suppressed.insert(.clipboardText)
		}

		// OCR vs editor-like metadata: if we have strong editor hints but OCR is aging, treat OCR as lower trust.
		if let basePacket {
			let editorHint = basePacket.visualKinds.contains(.editor) || basePacket.uiStructureHints.contains("ax_editor_like") || basePacket.uiStructureHints.contains("visual_monospace_region")
			if editorHint, ocrFresh < 0.30 {
				suppressed.insert(.screenOCR)
			}
		}

		// Compute weighted scores for candidates (excluding suppressed).
		let scored: [(FusedContextSource, Double)] = present.compactMap { c in
			if suppressed.contains(c.source) { return nil }
			let s = clamp01((c.baseWeight * 0.55) + (c.freshness * 0.45))
			return (c.source, s)
		}

		let primary: FusedContextSource? = scored.sorted(by: { $0.1 > $1.1 }).first?.0

		// Supporting sources: present but not suppressed or primary, with meaningful freshness.
		let supporting: [FusedContextSource] = present.compactMap { c in
			guard !suppressed.contains(c.source) else { return nil }
			guard c.source != primary else { return nil }
			guard c.freshness >= 0.20 else { return nil }
			return c.source
		}

		// Conflict: increase when multiple strong but disagreeing candidates coexist.
		var conflict = basePacket?.conflictScore ?? 0.0
		let strongCount = scored.filter { $0.1 >= 0.70 }.count
		if strongCount >= 2 { conflict += 0.15 }
		if suppressed.contains(.clipboardText), clipFresh > 0.10 { conflict += 0.06 }
		if suppressed.contains(.screenOCR), ocrFresh > 0.10 { conflict += 0.06 }
		conflict = clamp01(conflict)

		// Confidence: start from base and adjust by arbitration.
		var confidence = basePacket?.confidence ?? 0.0
		if let primary {
			let primaryScore = scored.first(where: { $0.0 == primary })?.1 ?? 0.0
			confidence = clamp01(max(confidence, primaryScore))
		}
		// Suppressions indicate disagreement/uncertainty.
		if !suppressed.isEmpty { confidence = clamp01(confidence - Double(suppressed.count) * 0.03) }
		// High conflict reduces confidence.
		confidence = clamp01(confidence * (1.0 - (conflict * 0.18)))

		var reasons: [String] = []
		if suppressed.contains(.clipboardText) { reasons.append("clipboard_suppressed") }
		if suppressed.contains(.screenOCR) { reasons.append("ocr_suppressed") }
		if hasSelection { reasons.append("selection_priority") }
		if axFresh >= 0.45, clipFresh < 0.25 { reasons.append("stale_clipboard_vs_ax") }
		if (basePacket?.visualKinds.contains(.editor) ?? false), ocrFresh < 0.30 { reasons.append("ocr_vs_editor_hint") }
		if reasons.isEmpty { reasons.append("no_change") }

		let out = ContextArbitrationResult(
			confidence: confidence,
			conflictScore: conflict,
			primarySource: primary,
			suppressedSources: Array(suppressed).sorted(by: { $0.rawValue < $1.rawValue }),
			supportingSources: supporting,
			reasonCodes: reasons
		)
		recordArbitrationSnapshot(out)
		return out
	}

	func selfTest() -> Bool {
		print("[ContextArbitration] selftest starting")

		func cand(_ s: FusedContextSource, present: Bool, fresh: Double, w: Double) -> FusedContextSourceCandidate {
			FusedContextSourceCandidate(source: s, isPresent: present, freshness: fresh, baseWeight: w)
		}

		let base = FusedContextPacket(
			id: UUID(),
			createdAt: Date(),
			primarySource: .none,
			availableSources: [.activeApp],
			staleSources: [],
			appName: "TestApp",
			bundleIdentifier: "test.bundle",
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
			visualKinds: [.editor],
			uiStructureHints: ["visual_monospace_region"],
			typingState: nil,
			pointerState: nil,
			confidence: 0.40,
			freshnessScore: 0.40,
			conflictScore: 0.10,
			isStale: false,
			suppressedSources: [],
			supportingSources: [],
			arbitrationReasons: ["selftest_base"],
			debugSummaryMetadata: ["selftest": "1"]
		)

		let r1 = arbitrate(
			candidates: [
				cand(.axText, present: true, fresh: 0.85, w: 0.75),
				cand(.clipboardText, present: true, fresh: 0.10, w: 0.40)
			],
			basePacket: base
		)
		print("[ContextArbitration] selftest case=stale_clip_vs_ax primary=\(r1.primarySource?.rawValue ?? "nil") suppressed=\(r1.suppressedSources.map(\.rawValue).joined(separator: ","))")

		let r2 = arbitrate(
			candidates: [
				cand(.screenOCR, present: true, fresh: 0.20, w: 0.60),
				cand(.axText, present: true, fresh: 0.70, w: 0.70)
			],
			basePacket: base
		)
		print("[ContextArbitration] selftest case=ocr_vs_editor primary=\(r2.primarySource?.rawValue ?? "nil") suppressed=\(r2.suppressedSources.map(\.rawValue).joined(separator: ","))")

		let ok = r1.suppressedSources.contains(FusedContextSource.clipboardText) && r1.primarySource == FusedContextSource.axText
		&& (r2.suppressedSources.contains(FusedContextSource.screenOCR) || r2.primarySource == FusedContextSource.axText)

		print("[ContextArbitration] selftest finished ok=\(ok)")
		return ok
	}
}

private func clamp01(_ x: Double) -> Double {
	min(1.0, max(0.0, x))
}

