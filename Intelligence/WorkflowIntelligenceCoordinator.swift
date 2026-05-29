import Foundation

/// Top-level orchestrator for Phase B Workflow Intelligence.
///
/// Pipeline:
/// ```
///   ContextEventStream
///     ↓
///   TemporalContextBuffer (5/15/30 min windows)
///     ↓
///   TemporalContextCompressor (compact packet)
///     ↓
///   WorkflowInferenceModel (qwen2.5:0.5b via injected backend)
///     ↓
///   WorkflowStabilizer (debounce / decay / continuity)
///     ↓
///   WorkflowState
///     ↓
///   AmbientOpportunityDetector
///     ↓
///   WorkflowDebugSurface
/// ```
///
/// This coordinator is intentionally a standalone actor. It does NOT touch
/// existing generated proposals, nor does it modify `AgenticRuntime`. Wiring
/// it into the app is a separate step (call `recordEvent(...)` on context
/// changes and `tick(...)` after meaningful updates).
public actor WorkflowIntelligenceCoordinator {

    private let stream: ContextEventStream
    private let backend: WorkflowInferenceBackend
    private var stabilizer: WorkflowStabilizer
    private var cooldowns: [String: Date]
    private var recentAccepts: [String]
    private var recentIgnores: [String]

    public init(
        stream: ContextEventStream = ContextEventStream(),
        backend: WorkflowInferenceBackend = OllamaWorkflowInferenceBackend(),
        initial: WorkflowState = .empty
    ) {
        self.stream = stream
        self.backend = backend
        self.stabilizer = WorkflowStabilizer(initial: initial)
        self.cooldowns = [:]
        self.recentAccepts = []
        self.recentIgnores = []
    }

    // MARK: - Event ingestion

    public func recordEvent(_ event: ContextEvent) async {
        await stream.append(event)
    }

    /// Test-only accessor. Production code MUST NOT depend on this; it exists
    /// so the producer self-test can verify the event stream state.
    public func eventStreamSnapshotForTesting() async -> [ContextEvent] {
        await stream.snapshot()
    }

    public func recordProposalAccepted(_ title: String) {
        recentAccepts.append(title)
        if recentAccepts.count > 5 { recentAccepts.removeFirst() }
    }

    public func recordProposalDismissed(_ title: String) {
        recentIgnores.append(title)
        if recentIgnores.count > 5 { recentIgnores.removeFirst() }
    }

    // MARK: - Tick

    /// Run one inference pass. Call this after meaningful context updates
    /// (e.g. once every few seconds, or on app/title change). It does NOT
    /// block the caller for long — the backend has its own timeout budget.
    ///
    /// `oldInferenceLabel` is the prior system's workflow label (e.g.
    /// `snapshot.inferredWorkflow.rawValue`). When supplied, this method
    /// emits a `[WorkflowCompare]` line so we can evaluate improvement
    /// without removing the old pipeline.
    @discardableResult
    public func tick(
        now: Date = Date(),
        oldInferenceLabel: String? = nil,
        clipboardKind: String? = nil,
        clipboardLength: Int? = nil
    ) async -> WorkflowState {

        let events = await stream.snapshot()
        let buffer = TemporalContextBuffer.build(from: events, now: now)
        let packet = TemporalContextCompressor.compress(
            buffer: buffer,
            recentAccepts: recentAccepts,
            recentIgnores: recentIgnores,
            clipboardKind: clipboardKind,
            clipboardLength: clipboardLength
        )

        let inferred = await WorkflowInferenceModel.infer(packet: packet, backend: backend)

        // B.1.5: evidence post-mortem. Show which packet sources contained
        // terms aligned with the picked workflow, and which sources contained
        // terms aligned with COMPETING workflows that were not chosen. This
        // is diagnostic-only — these maps are NOT used for classification.
        Self.diagnoseEvidence(picked: inferred.workflow, packet: packet)

        let candidate = WorkflowState(
            workflowType: AmbientWorkflowType(rawString: inferred.workflow),
            confidence: inferred.confidence,
            evidence: inferred.evidence.isEmpty ? [inferred.why] : inferred.evidence,
            uncertainty: inferred.uncertainty,
            startedAt: now,
            lastUpdatedAt: now,
            stabilityScore: 0.0,
            dominantApps: buffer.medium.dominantApps,
            repeatedTerms: buffer.long.repeatedTerms,
            recentTransitions: buffer.medium.transitions,
            suggestedIntentHints: inferred.suggestedIntentHints,
            sourcePacketHash: Self.hash(packet: packet)
        )

        let stabilized = stabilizer.ingest(
            candidate: candidate,
            now: now,
            freshShiftSignal: packet.contextShiftDetected
        )
        stabilized.log()

        // Task 8: compare with old inference if supplied.
        if let old = oldInferenceLabel {
            let agreement = Self.compareAgreement(
                old: old,
                new: stabilized.workflowType.rawValue
            )
            print("[WorkflowCompare] old=\(old) new=\(stabilized.workflowType.rawValue) agreement=\(agreement)")
        }

        // Opportunities (logged-only).
        let opportunities = AmbientOpportunityDetector.detect(
            state: stabilized,
            packet: packet,
            cooldowns: cooldowns,
            now: now
        )
        for opp in opportunities { cooldowns[opp.cooldownKey] = now }

        WorkflowDebugSurface.log(
            state: stabilized,
            packet: packet,
            opportunities: opportunities
        )

        return stabilized
    }

    // MARK: - Comparison

    /// Loose mapping between the prior `InferredWorkflow` labels and the
    /// Phase B label set. Returns "yes" / "partial" / "no".
    nonisolated static func compareAgreement(old: String, new: String) -> String {
        let o = old.lowercased()
        let n = new.lowercased()
        if o == n { return "yes" }
        let partialPairs: [(String, String)] = [
            ("research", "researching"),
            ("research", "studying"),
            ("browsing", "researching"),
            ("editing", "writing"),
            ("editing", "coding"),
            ("reviewing", "researching"),
            ("reviewing", "reading"),
            ("debugging", "coding"),
            ("writing", "writing"),
            ("unknown", "unknown"),
        ]
        if partialPairs.contains(where: { $0.0 == o && $0.1 == n }) ||
           partialPairs.contains(where: { $0.0 == n && $0.1 == o }) {
            return "partial"
        }
        return "no"
    }

    // MARK: - Hashing

    // MARK: - B.1.5 evidence post-mortem (diagnostic-only)

    /// Diagnostic keyword hints. These are **not** used to classify; they
    /// label which packet-field terms commonly co-occur with each workflow.
    /// The coordinator uses these to surface where the model's chosen label
    /// did or did not find supporting evidence in the packet, and where
    /// competing labels were also supported but ignored.
    nonisolated static let diagnosticKeywords: [String: [String]] = [
        "shopping":    ["amazon", "ebay", "walmart", "target", "best", "cart", "checkout", "price", "stock", "shipping"],
        "comparing":   ["compare", "specs", "spec", "review", "stars", "model", "vs"],
        "researching": ["wiki", "article", "blog", "search", "results", "paper"],
        "studying":    ["calculus", "physics", "biology", "chapter", "lecture", "exam", "assignment", "homework", "notes"],
        "writing":     ["draft", "document", "essay", "letter", "paragraph", "outline", "memo"],
        "emailing":    ["inbox", "gmail", "outlook", "mail", "compose", "reply", "subject", "thread"],
        "coding":      ["function", "class", "import", "return", "struct", "enum", "method"],
        "debugging":   ["error", "build", "failed", "test", "exception", "stack", "trace", "crash", "warning"],
        "reading":     ["chapter", "article", "essay"],
        "watching":    ["youtube", "video", "netflix", "stream", "episode"],
        "gaming":      ["minecraft", "steam", "discord", "twitch", "epic", "roblox"],
        "meeting":     ["zoom", "meet", "teams", "webex"],
    ]

    /// Tokenize a list of titles into 4+ char alphanumeric lowercase words.
    nonisolated static func titleTokens(_ titles: [String]) -> [String] {
        titles.flatMap { title -> [String] in
            title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 }
        }
    }

    nonisolated static func matched(in tokens: [String], for keys: [String]) -> [String] {
        let tokenSet = Set(tokens.map { $0.lowercased() })
        return keys.filter { tokenSet.contains($0) }
    }

    nonisolated static func diagnoseEvidence(picked: String, packet: CompressedTemporalPacket) {
        print("[WorkflowEvidence] picked=\(picked)")

        // Sources we inspect.
        let topicTokens = packet.topicTerms.map { $0.lowercased() }
        let ocrTokens   = packet.ocrHints.map { $0.lowercased() }
        let appTokens   = packet.recentApps.map { $0.lowercased() }
        let titleTokens = Self.titleTokens(packet.recentTitles)

        // Evidence supporting the picked label.
        if let keys = diagnosticKeywords[picked] {
            let t = matched(in: topicTokens, for: keys)
            let o = matched(in: ocrTokens, for: keys)
            let a = matched(in: appTokens, for: keys)
            let r = matched(in: titleTokens, for: keys)
            print("[WorkflowEvidence] picked=\(picked) source=topic_terms matched=\(t.isEmpty ? "none" : t.joined(separator: ","))")
            print("[WorkflowEvidence] picked=\(picked) source=ocr_hints matched=\(o.isEmpty ? "none" : o.joined(separator: ","))")
            print("[WorkflowEvidence] picked=\(picked) source=recent_apps matched=\(a.isEmpty ? "none" : a.joined(separator: ","))")
            print("[WorkflowEvidence] picked=\(picked) source=recent_titles matched=\(r.isEmpty ? "none" : r.joined(separator: ","))")
        }

        // Competing labels that ALSO had supporting evidence in the packet.
        // Sort by total match strength so the strongest competitors are visible.
        var competitors: [(label: String, t: [String], o: [String], a: [String], r: [String], score: Int)] = []
        for (label, keys) in diagnosticKeywords where label != picked {
            let t = matched(in: topicTokens, for: keys)
            let o = matched(in: ocrTokens, for: keys)
            let a = matched(in: appTokens, for: keys)
            let r = matched(in: titleTokens, for: keys)
            let score = t.count + o.count + a.count + r.count
            if score > 0 {
                competitors.append((label, t, o, a, r, score))
            }
        }
        let sorted = competitors.sorted { $0.score > $1.score }.prefix(4)
        for c in sorted {
            if !c.t.isEmpty { print("[WorkflowEvidence] competing=\(c.label) source=topic_terms matched=\(c.t.joined(separator: ","))") }
            if !c.o.isEmpty { print("[WorkflowEvidence] competing=\(c.label) source=ocr_hints matched=\(c.o.joined(separator: ","))") }
            if !c.a.isEmpty { print("[WorkflowEvidence] competing=\(c.label) source=recent_apps matched=\(c.a.joined(separator: ","))") }
            if !c.r.isEmpty { print("[WorkflowEvidence] competing=\(c.label) source=recent_titles matched=\(c.r.joined(separator: ","))") }
        }
    }

    /// FNV-1a hash of the packet bytes — stable, cheap, deterministic.
    nonisolated static func hash(packet: CompressedTemporalPacket) -> String {
        guard let data = try? JSONEncoder().encode(packet) else { return "" }
        var h: UInt64 = 0xcbf29ce484222325
        for b in data {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return String(h, radix: 16)
    }
}
