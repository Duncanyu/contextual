import Foundation

extension Notification.Name {
	/// Posted on the main queue when `CanonicalContextState` accepts a new fused packet (metadata only; no payload).
	static let contextualCanonicalContextUpdated = Notification.Name("com.contextual.notifications.canonicalContextUpdated")
}

/// Metadata-only summary for subtle context-awareness UI (no raw user content).
struct ContextAwarenessSummary: Equatable, Sendable {
	var isAvailable: Bool
	var primarySourceLabel: String?
	var freshnessLabel: String?
	var confidenceLabel: String?
	var activityLabel: String?
	var visualLabel: String?
	var staleLabel: String?
	var isRichContextActive: Bool
	var chips: [String]

	static let empty = ContextAwarenessSummary(
		isAvailable: false,
		primarySourceLabel: nil,
		freshnessLabel: nil,
		confidenceLabel: nil,
		activityLabel: nil,
		visualLabel: nil,
		staleLabel: nil,
		isRichContextActive: false,
		chips: []
	)

	var showsInPanel: Bool {
		!chips.isEmpty
	}

	var chipsJoined: String {
		chips.joined(separator: " · ")
	}
}

enum ContextAwarenessSummaryBuilder {
	private static let maxChips = 4

	/// Builds a compact chip list from canonical fused metadata and safe app hints from `ContextModel` (bundle/name only; no text channels).
	static func build(canonical: FusedContextPacket?, contextModel: ContextModel) -> ContextAwarenessSummary {
		guard let packet = canonical else {
			return .empty
		}

		let rich = packet.hasVisualDescriptor || packet.hasAXText || packet.hasWindowSnapshot || packet.hasOCRText

		let ocrStale = packet.staleSources.contains(.screenOCR)

		let typingState = packet.typingState
		let typingActive = Self.isTypingActive(typingState)

		let visualChip = Self.primaryVisualChip(from: packet.visualKinds)

		let freshnessChip: String? = {
			if ocrStale { return nil }
			if packet.isStale || packet.freshnessScore < 0.35 { return "stale" }
			if packet.freshnessScore >= 0.65 { return "fresh" }
			return nil
		}()

		let staleChip: String? = ocrStale ? "OCR stale" : nil

		let appChip = Self.shortAppToken(from: contextModel)

		let showIdleChip: Bool = {
			guard !typingActive else { return false }
			let idleLike = (typingState == nil || typingState == .idle || typingState == .stopped)
			guard idleLike else { return false }
			guard visualChip == "article" else { return false }
			return true
		}()

		var chips: [String] = []

		func appendUnique(_ s: String) {
			guard chips.count < maxChips, !chips.contains(s) else { return }
			chips.append(s)
		}

		if typingActive { appendUnique("typing") }
		if let staleChip { appendUnique(staleChip) }
		if rich { appendUnique("rich context") }
		if let v = visualChip { appendUnique(v) }
		if let a = appChip { appendUnique(a) }
		if let f = freshnessChip { appendUnique(f) }
		if showIdleChip { appendUnique("idle") }

		if chips.count > maxChips {
			chips = Array(chips.prefix(maxChips))
		}

		let activityLabel: String? = typingActive ? "typing" : (showIdleChip ? "idle" : nil)
		let visualOut = visualChip
		let freshnessOut = freshnessChip
		let staleOut = staleChip

		return ContextAwarenessSummary(
			isAvailable: rich || typingActive || visualOut != nil || freshnessOut != nil || staleOut != nil,
			primarySourceLabel: nil,
			freshnessLabel: freshnessOut,
			confidenceLabel: nil,
			activityLabel: activityLabel,
			visualLabel: visualOut,
			staleLabel: staleOut,
			isRichContextActive: rich,
			chips: chips
		)
	}

	// MARK: - Self-test (synthetic metadata only)

	static func runSelfTest() -> Bool {
		print("[ContextAwarenessUI] selftest starting")
		var failures: [String] = []

		func assertCase(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let now = Date()

		func basePacket(
			visualKinds: [VisualUIKind],
			typing: TypingState?,
			staleOCR: Bool,
			freshness: Double,
			isStale: Bool,
			hasOCR: Bool,
			hasAX: Bool,
			hasSnap: Bool,
			hasVis: Bool
		) -> FusedContextPacket {
			let staleSources: [ContextCapabilityID] = staleOCR ? [.screenOCR] : []
			return FusedContextPacket(
				id: UUID(),
				createdAt: now,
				primarySource: .selectedText,
				availableSources: [.activeApp, .selectedText],
				staleSources: staleSources,
				appName: nil,
				bundleIdentifier: "com.selftest",
				windowTitleAvailable: false,
				primaryTextSource: .selectedText,
				textAvailability: true,
				textLength: 12,
				lineCount: 2,
				hasSelectedText: true,
				hasClipboardText: false,
				hasOCRText: hasOCR,
				hasAXText: hasAX,
				hasWindowSnapshot: hasSnap,
				hasVisualDescriptor: hasVis,
				hasTypingActivity: typing != nil,
				hasPointerActivity: false,
				visualKinds: visualKinds,
				uiStructureHints: [],
				typingState: typing,
				pointerState: .idle,
				confidence: 0.7,
				freshnessScore: freshness,
				conflictScore: 0.1,
				isStale: isStale,
				suppressedSources: [],
				supportingSources: [],
				arbitrationReasons: ["selftest"],
				debugSummaryMetadata: ["selftest": "1"]
			)
		}

		let emptyModel = ContextModel()
		var model = ContextModel()
		model.activeAppBundleIdentifier = "com.apple.dt.Xcode"
		model.activeAppName = "Xcode"

		// editor + fresh
		let editorFresh = basePacket(
			visualKinds: [.editor],
			typing: .idle,
			staleOCR: false,
			freshness: 0.9,
			isStale: false,
			hasOCR: false,
			hasAX: false,
			hasSnap: false,
			hasVis: true
		)
		let s1 = build(canonical: editorFresh, contextModel: model)
		assertCase("editor_fresh", s1.chips.contains("editor") && s1.chips.contains("fresh") && s1.chips.count <= maxChips)

		// article + idle
		let articleIdle = basePacket(
			visualKinds: [.browser],
			typing: .idle,
			staleOCR: false,
			freshness: 0.5,
			isStale: false,
			hasOCR: false,
			hasAX: false,
			hasSnap: false,
			hasVis: false
		)
		let s2 = build(canonical: articleIdle, contextModel: model)
		assertCase("article_idle", s2.chips.contains("article") && s2.chips.contains("idle"))

		// typing active
		let typingBurst = basePacket(
			visualKinds: [],
			typing: .burst,
			staleOCR: false,
			freshness: 0.8,
			isStale: false,
			hasOCR: false,
			hasAX: false,
			hasSnap: false,
			hasVis: false
		)
		let s3 = build(canonical: typingBurst, contextModel: emptyModel)
		assertCase("typing", s3.chips.contains("typing"))

		// OCR stale
		let ocrStale = basePacket(
			visualKinds: [],
			typing: .idle,
			staleOCR: true,
			freshness: 0.8,
			isStale: false,
			hasOCR: true,
			hasAX: false,
			hasSnap: false,
			hasVis: false
		)
		let s4 = build(canonical: ocrStale, contextModel: emptyModel)
		assertCase("ocr_stale", s4.chips.contains("OCR stale"))

		// rich context active
		let rich = basePacket(
			visualKinds: [.terminal],
			typing: .idle,
			staleOCR: false,
			freshness: 0.7,
			isStale: false,
			hasOCR: true,
			hasAX: true,
			hasSnap: true,
			hasVis: true
		)
		let s5 = build(canonical: rich, contextModel: model)
		assertCase("rich", s5.isRichContextActive && s5.chips.contains("rich context"))

		// no canonical
		let s6 = build(canonical: nil, contextModel: model)
		assertCase("no_context", s6.chips.isEmpty && !s6.isAvailable)

		// chip length / no raw fields
		for s in [s1, s2, s3, s4, s5] {
			assertCase("max_chips_\(s.chipsJoined)", s.chips.count <= maxChips)
			for c in s.chips {
				assertCase("chip_short_\(c)", c.count <= 22)
				assertCase("no_http_\(c)", !c.contains("://"))
			}
		}

		let ok = failures.isEmpty
		print("[ContextAwarenessUI] selftest summaries editorFresh=\(s1.chipsJoined) articleIdle=\(s2.chipsJoined) typing=\(s3.chipsJoined) ocrStale=\(s4.chipsJoined) rich=\(s5.chipsJoined) empty=\(s6.chipsJoined)")
		print("[ContextAwarenessUI] selftest failures=\(failures.count) ok=\(ok)")
		return ok
	}

	// MARK: - Private

	private static func isTypingActive(_ state: TypingState?) -> Bool {
		guard let state else { return false }
		switch state {
		case .started, .active, .burst:
			return true
		case .idle, .stopped:
			return false
		}
	}

	private static func primaryVisualChip(from kinds: [VisualUIKind]) -> String? {
		let priority: [VisualUIKind] = [.editor, .terminal, .form, .dialog, .article, .browser, .chart, .media, .unknown]
		for p in priority {
			if kinds.contains(p) {
				return mapVisualKind(p)
			}
		}
		return nil
	}

	private static func mapVisualKind(_ kind: VisualUIKind) -> String? {
		switch kind {
		case .editor: return "editor"
		case .terminal: return "terminal"
		case .browser: return "article"
		case .article: return "article"
		case .form: return "form"
		case .dialog: return "dialog"
		case .chart, .media, .unknown:
			return nil
		}
	}

	private static func shortAppToken(from model: ContextModel) -> String? {
		if let bid = model.activeAppBundleIdentifier?.split(separator: ".").last, bid.count >= 2 {
			let s = String(bid)
			return s.count > 12 ? String(s.prefix(12)) : s
		}
		if let name = model.activeAppName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
			if name.contains("/") || name.contains("\\") { return nil }
			return name.count > 10 ? String(name.prefix(10)) : name
		}
		return nil
	}
}
