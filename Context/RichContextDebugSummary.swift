import Foundation

/// Metadata-only snapshot for internal rich-context debug UI (no raw user content).
struct RichContextDebugSummary: Equatable, Sendable {
	var hasCanonicalContext: Bool
	var primarySource: String?
	var availableSources: [String]
	var staleSources: [String]
	var freshnessLabel: String?
	var freshnessScoreBucket: String?
	var confidenceBucket: String?
	var conflictBucket: String?
	var visualKinds: [String]
	var typingState: String?
	var pointerState: String?
	var lastSamplingDecision: String?
	var lastSamplingScoreBucket: String?
	var lastArbitrationReasons: [String]
	var lastRefreshCollected: [String]
	var lastRefreshSkipped: [String]
	var lastRefreshWasCancelled: Bool?
	var lastRefreshUpdatedCanonical: Bool?
	var richContextActive: Bool

	static let empty = RichContextDebugSummary(
		hasCanonicalContext: false,
		primarySource: nil,
		availableSources: [],
		staleSources: [],
		freshnessLabel: nil,
		freshnessScoreBucket: nil,
		confidenceBucket: nil,
		conflictBucket: nil,
		visualKinds: [],
		typingState: nil,
		pointerState: nil,
		lastSamplingDecision: nil,
		lastSamplingScoreBucket: nil,
		lastArbitrationReasons: [],
		lastRefreshCollected: [],
		lastRefreshSkipped: [],
		lastRefreshWasCancelled: nil,
		lastRefreshUpdatedCanonical: nil,
		richContextActive: false
	)

	var showsRichDebug: Bool {
		hasCanonicalContext
			|| !(lastRefreshCollected.isEmpty && lastRefreshSkipped.isEmpty)
			|| (lastSamplingDecision != nil && !(lastSamplingDecision?.isEmpty ?? true))
			|| lastRefreshWasCancelled == true
	}
}

enum RichContextDebugSummaryBuilder {
	private static let maxList = 12

	static func build(
		canonical: FusedContextPacket?,
		refreshResult: RichContextRefreshResult?,
		samplingDecision: AdaptiveSamplingDecision?,
		lastArbitration: ContextArbitrationResult?
	) -> RichContextDebugSummary {
		guard let packet = canonical else {
			return mergeRefreshOnly(refreshResult, sampling: samplingDecision)
		}

		let freshLabel = ContextFreshnessPolicy.decayLabel(score: packet.freshnessScore).rawValue
		let freshBucket = freshLabel

		let confBucket = Self.confidenceBucket(packet.confidence)
		let conflictBucket = Self.conflictBucket(packet.conflictScore)

		let arbReasons: [String]
		if let a = lastArbitration?.reasonCodes, !a.isEmpty {
			arbReasons = capList(a.map(sanitizeToken), max: maxList)
		} else {
			arbReasons = capList(packet.arbitrationReasons.map(sanitizeToken), max: maxList)
		}

		let samplingLine = samplingDecision.map { Self.formatSamplingLine($0) }
		let scoreBucket = samplingDecision.map { Self.samplingScoreBucket($0.samplingScore) }

		let refreshCollected = refreshResult.map { capList($0.collectedSources.map(\.rawValue), max: maxList) } ?? []
		let refreshSkipped = refreshResult.map { Self.formatSkipped($0.skippedSources) } ?? []
		let wasCancelled = refreshResult?.wasCancelled
		let updatedCanon = refreshResult?.updatedCanonicalState

		let rich = packet.hasVisualDescriptor || packet.hasAXText || packet.hasWindowSnapshot || packet.hasOCRText

		return RichContextDebugSummary(
			hasCanonicalContext: true,
			primarySource: packet.primarySource.rawValue,
			availableSources: capList(packet.availableSources.map(\.rawValue).sorted(), max: maxList),
			staleSources: capList(packet.staleSources.map(\.rawValue).sorted(), max: maxList),
			freshnessLabel: freshLabel,
			freshnessScoreBucket: freshBucket,
			confidenceBucket: confBucket,
			conflictBucket: conflictBucket,
			visualKinds: capList(packet.visualKinds.map(\.rawValue).sorted(), max: maxList),
			typingState: packet.typingState?.rawValue,
			pointerState: packet.pointerState?.rawValue,
			lastSamplingDecision: samplingLine,
			lastSamplingScoreBucket: scoreBucket,
			lastArbitrationReasons: arbReasons,
			lastRefreshCollected: refreshCollected,
			lastRefreshSkipped: refreshSkipped,
			lastRefreshWasCancelled: wasCancelled,
			lastRefreshUpdatedCanonical: updatedCanon,
			richContextActive: rich
		)
	}

	// MARK: - Self-test

	static func runSelfTest() -> Bool {
		print("[RichContextDebugUI] selftest starting")
		var failures: [String] = []

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()
		let packet = FusedContextPacket(
			id: UUID(),
			createdAt: now,
			primarySource: .selectedText,
			availableSources: [.activeApp, .selectedText, .axWindowContent, .visualDescriptor],
			staleSources: [.screenOCR],
			appName: nil,
			bundleIdentifier: "com.selftest",
			windowTitleAvailable: false,
			primaryTextSource: .selectedText,
			textAvailability: true,
			textLength: 40,
			lineCount: 2,
			hasSelectedText: true,
			hasClipboardText: false,
			hasOCRText: true,
			hasAXText: true,
			hasWindowSnapshot: true,
			hasVisualDescriptor: true,
			hasTypingActivity: true,
			hasPointerActivity: true,
			visualKinds: [.editor, .dialog],
			uiStructureHints: [],
			typingState: .active,
			pointerState: .idle,
			confidence: 0.82,
			freshnessScore: 0.92,
			conflictScore: 0.18,
			isStale: false,
			suppressedSources: [],
			supportingSources: [],
			arbitrationReasons: ["selection_priority", "ocr_suppressed"],
			debugSummaryMetadata: ["selftest": "1"]
		)

		let sampling = AdaptiveSamplingDecision(
			allowedSources: [.typingActivity, .axWindowContent],
			deferredSources: [.visualDescriptor],
			deniedSources: [],
			reuseExistingSources: [.activeWindowSnapshot],
			reasonCodes: [.axWindowContent: "default_allow", .visualDescriptor: "adaptive_deferred"],
			samplingScore: 0.72
		)

		let refresh = RichContextRefreshResult(
			id: UUID(),
			startedAt: now,
			finishedAt: now,
			wasCancelled: false,
			collectedSources: [.typingActivity, .axText],
			skippedSources: [.activeWindowSnapshot: "adaptive_reuse", .visualDescriptor: "no_snapshot"],
			fusedPacket: packet,
			updatedCanonicalState: true,
			debugSummaryMetadata: [:]
		)

		let arb = ContextArbitrationResult(
			confidence: 0.8,
			conflictScore: 0.2,
			primarySource: .selectedText,
			suppressedSources: [.screenOCR],
			supportingSources: [.axText],
			reasonCodes: ["selection_priority"]
		)

		let s = build(canonical: packet, refreshResult: refresh, samplingDecision: sampling, lastArbitration: arb)

		assertCase("primary", s.primarySource == "selectedText")
		assertCase("fresh_bucket", s.freshnessScoreBucket == "fresh" || s.freshnessScoreBucket == "aging")
		assertCase("conf_high", s.confidenceBucket == "high")
		assertCase("conflict_low", s.conflictBucket == "low")
		assertCase("visual", s.visualKinds.contains("editor") && s.visualKinds.contains("dialog"))
		assertCase("typing", s.typingState == "active")
		assertCase("pointer", s.pointerState == "idle")
		assertCase("sampling", s.lastSamplingDecision != nil && (s.lastSamplingDecision?.contains("reused") ?? false))
		assertCase("sampling_bucket", s.lastSamplingScoreBucket == "medium" || s.lastSamplingScoreBucket == "high")
		assertCase("refresh_collected", s.lastRefreshCollected.contains("axText"))
		assertCase("refresh_skipped", !s.lastRefreshSkipped.isEmpty)
		assertCase("arb", s.lastArbitrationReasons.contains("selection_priority"))
		assertCase("lists_bounded", s.availableSources.count <= maxList && s.lastRefreshSkipped.count <= maxList)

		let joined = ([s.primarySource] + s.availableSources + s.lastArbitrationReasons + s.lastRefreshSkipped).compactMap { $0 }.joined()
		assertCase("no_http", !joined.contains("://"))

		let ok = failures.isEmpty
		print("[RichContextDebugUI] selftest summary primary=\(s.primarySource ?? "nil") sampling=\(s.lastSamplingDecision ?? "nil") refresh=\(s.lastRefreshCollected.joined(separator: ",")) ok=\(ok)")
		return ok
	}

	// MARK: - Private

	private static func mergeRefreshOnly(_ refresh: RichContextRefreshResult?, sampling: AdaptiveSamplingDecision?) -> RichContextDebugSummary {
		let refreshCollected = refresh.map { capList($0.collectedSources.map(\.rawValue), max: maxList) } ?? []
		let refreshSkipped = refresh.map { formatSkipped($0.skippedSources) } ?? []
		return RichContextDebugSummary(
			hasCanonicalContext: false,
			primarySource: nil,
			availableSources: [],
			staleSources: [],
			freshnessLabel: nil,
			freshnessScoreBucket: nil,
			confidenceBucket: nil,
			conflictBucket: nil,
			visualKinds: [],
			typingState: nil,
			pointerState: nil,
			lastSamplingDecision: sampling.map { formatSamplingLine($0) },
			lastSamplingScoreBucket: sampling.map { samplingScoreBucket($0.samplingScore) },
			lastArbitrationReasons: [],
			lastRefreshCollected: refreshCollected,
			lastRefreshSkipped: refreshSkipped,
			lastRefreshWasCancelled: refresh?.wasCancelled,
			lastRefreshUpdatedCanonical: refresh?.updatedCanonicalState,
			richContextActive: false
		)
	}

	private static func capList(_ items: [String], max: Int) -> [String] {
		if items.count <= max { return items }
		return Array(items.prefix(max))
	}

	private static func sanitizeToken(_ s: String) -> String {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if t.count > 48 { return String(t.prefix(48)) }
		return t
	}

	private static func formatSkipped(_ m: [FusedContextSource: String]) -> [String] {
		let lines = m.keys.sorted(by: { $0.rawValue < $1.rawValue }).map { src in
			"\(src.rawValue)=\(sanitizeToken(m[src] ?? ""))"
		}
		return capList(lines, max: maxList)
	}

	private static func confidenceBucket(_ c: Double) -> String {
		if c >= 0.67 { return "high" }
		if c >= 0.40 { return "medium" }
		if c > 0 { return "low" }
		return "unknown"
	}

	private static func conflictBucket(_ c: Double) -> String {
		if c < 0.25 { return "low" }
		if c < 0.55 { return "medium" }
		if c > 0 { return "high" }
		return "unknown"
	}

	private static func samplingScoreBucket(_ s: Double) -> String {
		if s >= 0.62 { return "high" }
		if s >= 0.42 { return "medium" }
		if s > 0 { return "low" }
		return "unknown"
	}

	private static func formatSamplingLine(_ d: AdaptiveSamplingDecision) -> String {
		var parts: [String] = []
		for id in d.reuseExistingSources.sorted(by: { $0.rawValue < $1.rawValue }) {
			parts.append("reused:\(id.rawValue)")
		}
		for id in d.deferredSources.sorted(by: { $0.rawValue < $1.rawValue }) {
			parts.append("deferred:\(id.rawValue)")
		}
		for id in d.deniedSources.sorted(by: { $0.rawValue < $1.rawValue }) {
			parts.append("denied:\(id.rawValue)")
		}
		return parts.prefix(4).joined(separator: " · ")
	}
}
