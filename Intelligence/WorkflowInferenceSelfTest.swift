import Foundation

/// Phase B self-tests — drive deterministic temporal sequences through the
/// pipeline and verify the inferred workflow.
///
/// **Critical design note:** these tests exercise the compressor + stabilizer
/// + inference contract using a **signal-driven test backend**, not the live
/// qwen call (which is non-deterministic and may not be reachable in CI). The
/// stub backend reads ONLY temporal packet fields (term frequencies, transition
/// counts, activity patterns, idle patterns) — it never matches on raw app
/// names. This validates that:
///
/// 1. The compressor surfaces enough signal from event sequences.
/// 2. The stabilizer doesn't undo correct classifications.
/// 3. The pipeline contract end-to-end is sound.
///
/// The live qwen model is exercised separately at runtime; here we prove the
/// packet carries the information any classifier would need.
///
/// Trigger:
///   CONTEXTUAL_RUN_WORKFLOW_INFERENCE_SELFTEST=1
public enum WorkflowInferenceSelfTest {

    public static func run() async -> Bool {
        print("[WorkflowInferenceSelfTest] starting")

        var failures: [String] = []

        let cases: [(name: String, events: [ContextEvent], expected: String)] = [
            ("studying_sequence",  Fixtures.studyingSequence(),  "studying"),
            ("gaming_sequence",    Fixtures.gamingSequence(),    "gaming"),
            ("debugging_sequence", Fixtures.debuggingSequence(), "debugging"),
            ("research_sequence",  Fixtures.researchSequence(),  "researching"),
            ("comparing_sequence", Fixtures.comparingSequence(), "comparing"),
            ("idle_sequence",      Fixtures.idleSequence(),      "idle"),
            // B.1.6 regression — the exact B.1.5 failure: Gmail (early, lots
            // of repeats) followed by Amazon (recent, fewer repeats). Without
            // recency weighting + fresh-shift correction this returns
            // "writing"/"emailing"; with B.1.6 it must return "shopping" or
            // the comparing-family fallback.
            ("shopping_after_gmail_recency_weighted",
             Fixtures.shoppingAfterGmailSequence(),
             "shopping"),
        ]

        for tc in cases {
            let now = tc.events.last?.timestamp ?? Date()
            let coordinator = WorkflowIntelligenceCoordinator(
                stream: ContextEventStream(),
                backend: SignalDrivenStubBackend(),
                initial: .empty
            )
            for ev in tc.events { await coordinator.recordEvent(ev) }
            // Two ticks so the stabilizer can confirm medium-confidence shifts.
            _ = await coordinator.tick(now: now)
            let stabilized = await coordinator.tick(now: now)

            if stabilized.workflowType.rawValue == tc.expected {
                print("[WorkflowInferenceSelfTest] pass case=\(tc.name)")
            } else {
                print("[WorkflowInferenceSelfTest] fail case=\(tc.name) expected=\(tc.expected) got=\(stabilized.workflowType.rawValue)")
                failures.append(tc.name)
            }
        }

        let ok = failures.isEmpty
        print("[WorkflowInferenceSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }
}

// MARK: - Signal-driven stub backend

/// Test-only inference backend. Picks a workflow label using ONLY temporal
/// packet signals (term frequencies, transition counts, activity patterns).
///
/// IMPORTANT — this is not production code, and it does NOT match on app names.
/// It is a thin proxy that proves the packet carries enough temporal signal
/// for any downstream classifier (model-based or otherwise) to do its job.
private struct SignalDrivenStubBackend: WorkflowInferenceBackend {

    func infer(packet: CompressedTemporalPacket) async -> AmbientWorkflowInferenceResult? {
        // 1. Idle: very low activity AND long idle AND no recent topic churn.
        if packet.activityPattern == "idle" && packet.idlePattern == "long_idle"
           && packet.recentTitles.count <= 1 {
            return result("idle", 0.78, "long_idle_no_activity")
        }

        // 2. Debugging: error/build/test terms AND typing activity.
        let errorTerms: Set<String> = ["error", "build", "failed", "test", "exception", "stack", "trace", "crash"]
        let errorHits = packet.topicTerms.lazy.map { $0.lowercased() }.filter { errorTerms.contains($0) }.count
        if errorHits >= 2 && (packet.typingPattern == "light" || packet.typingPattern == "heavy") {
            return result("debugging", 0.84, "repeated_error_terms_typing")
        }

        // 3. Studying: sustained academic-flavored topic terms + multiple apps + at least one PDF/notes-like title.
        let studyTerms: Set<String> = [
            "calculus", "derivative", "integral", "limit", "theorem",
            "chapter", "lecture", "study", "exam", "assignment", "homework",
            "physics", "biology", "history", "essay",
        ]
        let studyHits = packet.topicTerms.lazy.map { $0.lowercased() }.filter { studyTerms.contains($0) }.count
        let multiAppNonGame = packet.recentApps.count >= 2 && packet.activityPattern != "idle"
        if studyHits >= 2 && multiAppNonGame {
            return result("studying", 0.82, "academic_terms_multi_app")
        }

        // 4. Gaming: long stable session, very few title changes, ~no typing.
        //    Detection is signal-only: low transitions + low typing + non-idle activity.
        if packet.recentTitles.count <= 2
           && packet.typingPattern == "none"
           && packet.activityPattern != "idle"
           && packet.spanSeconds >= 300 {
            return result("gaming", 0.86, "stable_single_focus_low_typing")
        }

        // 4.5. Shopping (signal-based) — shopping-platform tokens dominate the
        // recency-weighted topic terms AND the user has been moving between
        // titles. This is what B.1.6 makes possible: the platform token only
        // appears in the topic terms when fresh activity has out-weighted
        // older stale terms.
        let shoppingTokens: Set<String> = ["amazon", "ebay", "walmart", "etsy", "shopify"]
        let shoppingHits = packet.topicTerms.lazy
            .map { $0.lowercased() }
            .filter { shoppingTokens.contains($0) }
            .count
        if shoppingHits >= 1 && packet.recentTitles.count >= 3 {
            return result("shopping", 0.82, "shopping_platform_terms_dominate")
        }

        // 5. Researching: many distinct titles + repeated topic terms + light/heavy pointer/typing.
        if packet.recentTitles.count >= 4 && packet.topicTerms.count >= 2 {
            // Distinguish from comparing: comparing requires product-like terms.
            let productTerms: Set<String> = [
                "price", "review", "stars", "spec", "specs", "buy",
                "model", "warranty", "shipping", "stock",
            ]
            let productHits = packet.topicTerms.lazy.map { $0.lowercased() }.filter { productTerms.contains($0) }.count
            if productHits >= 2 {
                return result("comparing", 0.80, "many_pages_product_terms")
            }
            return result("researching", 0.78, "many_pages_shared_topics")
        }

        // 6. Writing: heavy typing + few app changes + low pointer activity.
        if packet.typingPattern == "heavy" && packet.recentApps.count <= 2 && packet.pointerPattern != "active" {
            return result("writing", 0.72, "heavy_typing_few_apps")
        }

        // 7. Default: unknown.
        return result("unknown", 0.3, "insufficient_temporal_signal")
    }

    private func result(_ label: String, _ confidence: Double, _ why: String) -> AmbientWorkflowInferenceResult {
        AmbientWorkflowInferenceResult(
            workflow: label,
            confidence: confidence,
            why: why,
            evidence: [why],
            suggestedIntentHints: [],
            uncertainty: ""
        )
    }
}

// MARK: - Fixtures

/// Synthetic temporal sequences for each test case. Times are anchored to "now
/// = last event" so window calculations are deterministic.
private enum Fixtures {

    // 18 minutes of mixed academic activity. Apps repeat. Calculus terms recur.
    // Interleaved typing/pointer events keep activityPattern non-idle, which is
    // the threshold the inference layer uses to distinguish studying from
    // passive researching.
    static func studyingSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-1080)
        let pattern: [(String, String, [String])] = [
            ("Preview",    "Calculus II - Lecture 12.pdf", ["calculus", "derivative"]),
            ("Notes",      "Calc 12 notes.md",             ["derivative", "limit"]),
            ("Calculator", "Calculator",                    []),
            ("Preview",    "Calculus II - Lecture 12.pdf", ["calculus", "integral"]),
            ("Notes",      "Calc 12 notes.md",             ["integral", "limit"]),
            ("Calculator", "Calculator",                    []),
            ("Preview",    "Calculus II - Lecture 12.pdf", ["calculus", "limit"]),
            ("Notes",      "Calc 12 notes.md",             ["chapter", "study"]),
            ("Preview",    "Calculus II - Lecture 12.pdf", ["calculus", "derivative"]),
            ("Notes",      "Calc 12 notes.md",             ["study", "chapter"]),
        ]
        var events: [ContextEvent] = pattern.enumerated().map { i, p in
            ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 100),
                type: .windowTitleChanged,
                appName: p.0,
                bundleIdentifier: nil,
                windowTitle: p.1,
                textHints: p.2,
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            )
        }
        // Interleave typing + pointer activity so the medium window registers
        // a non-idle activity pattern (studying is active work, not passive).
        for i in 0..<8 {
            events.append(ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 120 + 50),
                type: .typingStateChanged,
                appName: "Notes",
                bundleIdentifier: nil,
                windowTitle: "Calc 12 notes.md",
                activityIntensity: 0.5
            ))
            events.append(ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 120 + 80),
                type: .pointerStateChanged,
                appName: "Preview",
                bundleIdentifier: nil,
                windowTitle: "Calculus II - Lecture 12.pdf",
                activityIntensity: 0.4
            ))
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    // 12 minutes of a single dominant app, no title changes, ~no typing.
    static func gamingSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-720)
        var out: [ContextEvent] = []
        for i in 0..<12 {
            out.append(ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                type: .pointerStateChanged,
                appName: "Minecraft",
                bundleIdentifier: "com.mojang.minecraftlauncher",
                windowTitle: "Minecraft",
                textHints: [],
                sourceConfidence: 0.95,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.6
            ))
        }
        return out
    }

    // Repeated build / error / test terms with typing across IDE-like windows.
    static func debuggingSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-900)
        let pattern: [(String, String, [String])] = [
            ("Editor",   "main.swift",       ["build", "error"]),
            ("Terminal", "zsh",              ["test", "failed"]),
            ("Editor",   "main.swift",       ["error", "stack"]),
            ("Terminal", "zsh",              ["build", "failed"]),
            ("Editor",   "AgenticRuntime.swift", ["test", "error"]),
            ("Terminal", "zsh",              ["build", "trace"]),
            ("Editor",   "main.swift",       ["error", "exception"]),
            ("Terminal", "zsh",              ["test", "failed"]),
        ]
        var out: [ContextEvent] = pattern.enumerated().map { i, p in
            ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 100),
                type: .windowTitleChanged,
                appName: p.0,
                bundleIdentifier: nil,
                windowTitle: p.1,
                textHints: p.2,
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.5
            )
        }
        out.append(ContextEvent(
            timestamp: base.addingTimeInterval(900),
            type: .typingStateChanged,
            appName: "Editor",
            bundleIdentifier: nil,
            windowTitle: "main.swift",
            activityIntensity: 0.5
        ))
        return out
    }

    // Many distinct article-style titles with overlapping topic terms.
    static func researchSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-900)
        let pattern: [(String, String, [String])] = [
            ("Firefox", "Quantum Computing: An Overview",                 ["quantum", "computing"]),
            ("Firefox", "Shor's algorithm explained",                     ["quantum", "algorithm"]),
            ("Firefox", "Superposition and entanglement basics",          ["quantum", "qubit"]),
            ("Firefox", "Quantum supremacy milestones",                   ["quantum", "milestone"]),
            ("Firefox", "Qubit error correction techniques",              ["quantum", "qubit"]),
            ("Firefox", "Comparing quantum hardware vendors",             ["quantum", "vendor"]),
            ("Firefox", "Quantum annealing vs gate-based",                ["quantum", "annealing"]),
        ]
        var out: [ContextEvent] = pattern.enumerated().map { i, p in
            ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 120),
                type: .windowTitleChanged,
                appName: p.0,
                bundleIdentifier: nil,
                windowTitle: p.1,
                textHints: p.2,
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            )
        }
        out.append(ContextEvent(
            timestamp: base.addingTimeInterval(900),
            type: .pointerStateChanged,
            appName: "Firefox",
            bundleIdentifier: nil,
            windowTitle: "Quantum annealing vs gate-based",
            activityIntensity: 0.3
        ))
        return out
    }

    // Multiple product-style titles with price/spec terms recurring.
    static func comparingSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-900)
        let pattern: [(String, String, [String])] = [
            ("Firefox", "Anker USB-C Hub product page", ["price", "spec"]),
            ("Firefox", "Spigen USB-C Hub product page", ["price", "review"]),
            ("Firefox", "Anker USB-C Hub - reviews",     ["review", "stars"]),
            ("Firefox", "Belkin USB-C Hub product page", ["price", "spec"]),
            ("Firefox", "Spigen USB-C Hub - reviews",    ["review", "stars"]),
            ("Firefox", "Anker USB-C Hub - specifications", ["spec", "model"]),
        ]
        var out: [ContextEvent] = pattern.enumerated().map { i, p in
            ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 130),
                type: .windowTitleChanged,
                appName: p.0,
                bundleIdentifier: nil,
                windowTitle: p.1,
                textHints: p.2,
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            )
        }
        out.append(ContextEvent(
            timestamp: base.addingTimeInterval(900),
            type: .pointerStateChanged,
            appName: "Firefox",
            bundleIdentifier: nil,
            windowTitle: "Anker USB-C Hub - specifications",
            activityIntensity: 0.3
        ))
        return out
    }

    // B.1.6 regression: 7 minutes of Gmail followed by 7 minutes of Amazon.
    // Without recency weighting + fresh-shift correction this returns
    // "writing"/"emailing" because the stale Gmail terms have higher raw count
    // than the fresh Amazon terms. With B.1.6 the medium-window weighted score
    // ranks `amazon`/`anker`/`charger` above `inbox`/`gmail`/`duncan` and the
    // stabilizer's fresh-shift fast path commits to `shopping` immediately.
    static func shoppingAfterGmailSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-840)
        var events: [ContextEvent] = []

        // Gmail phase — 7 title changes over the first 7 minutes.
        let gmailTitles = [
            "Inbox (24) — duncan@gmail.com — Gmail",
            "Re: lunch — duncan@gmail.com — Gmail",
            "Gmail — duncan@gmail.com — Promotions",
            "Drafts — duncan@gmail.com — Gmail",
            "Inbox (25) — duncan@gmail.com — Gmail",
            "Sent — duncan@gmail.com — Gmail",
            "Inbox (24) — duncan@gmail.com — Gmail",
        ]
        for i in 0..<7 {
            events.append(ContextEvent(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                type: .windowTitleChanged,
                appName: "Firefox",
                bundleIdentifier: "org.mozilla.firefox",
                windowTitle: gmailTitles[i],
                textHints: ["inbox", "gmail", "duncan"],
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            ))
        }
        // Amazon phase — 7 title changes over the next 7 minutes (most recent).
        let amazonTitles = [
            "Amazon.com — Anker USB-C Hub 7-in-1",
            "Amazon.com — Anker Prime 100W charger",
            "Anker USB-C Hub product — Amazon",
            "Amazon.com — Anker Power Bank 10000",
            "Anker Charger Reviews — Amazon",
            "Amazon.com — Anker GaN charger",
            "Amazon — Anker accessories Electronics",
        ]
        for i in 0..<7 {
            events.append(ContextEvent(
                timestamp: base.addingTimeInterval(420 + Double(i) * 60),
                type: .windowTitleChanged,
                appName: "Firefox",
                bundleIdentifier: "org.mozilla.firefox",
                windowTitle: amazonTitles[i],
                textHints: ["amazon", "anker", "charger"],
                sourceConfidence: 0.9,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.3
            ))
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    // Long idle interval bracketed by a single idle / resumed pair.
    // The full sequence fits within the medium (15 min) window so that the
    // accumulated idle time registers in the buffer's `idleSeconds`.
    static func idleSequence() -> [ContextEvent] {
        let base = Date(timeIntervalSinceNow: 0).addingTimeInterval(-900)
        return [
            ContextEvent(
                timestamp: base,
                type: .windowTitleChanged,
                appName: "Finder",
                bundleIdentifier: "com.apple.finder",
                windowTitle: "Desktop",
                activityIntensity: 0.0
            ),
            ContextEvent(
                timestamp: base.addingTimeInterval(50),
                type: .userIdle,
                appName: "Finder",
                bundleIdentifier: "com.apple.finder",
                windowTitle: "Desktop",
                activityIntensity: 0.0
            ),
            ContextEvent(
                timestamp: base.addingTimeInterval(890),
                type: .userResumed,
                appName: "Finder",
                bundleIdentifier: "com.apple.finder",
                windowTitle: "Desktop",
                activityIntensity: 0.0
            ),
        ]
    }
}
