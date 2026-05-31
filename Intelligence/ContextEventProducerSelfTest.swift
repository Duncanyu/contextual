import Foundation

/// Deterministic self-tests for `ContextEventProducer`.
///
/// Validates:
///   1. Active-app change emits an `activeAppChanged` event.
///   2. Window-title change emits a `windowTitleChanged` event.
///   3. OCR excerpt emits an `ocrAvailable` event with redacted topic hints
///      (raw OCR never reaches the event).
///   4. Selected-text change emits a `restricted`-privacy event with no
///      content in the event's `textHints`.
///   5. Duplicate snapshots do NOT emit duplicate events.
///   6. Privacy: full OCR text never appears in event hints; length buckets
///      hide selection sizes.
///
/// Trigger:
///   CONTEXTUAL_RUN_CONTEXT_EVENT_PRODUCER_SELFTEST=1
@MainActor
enum ContextEventProducerSelfTest {

    static func run() async -> Bool {
        print("[ContextEventProducerSelfTest] starting")

        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok {
                print("[ContextEventProducerSelfTest] pass case=\(name)")
            } else {
                print("[ContextEventProducerSelfTest] fail case=\(name)")
                failures.append(name)
            }
        }

        // Shared collector — captures every event recorded into the coordinator
        let collector = EventCollector()
        let coordinator = WorkflowIntelligenceCoordinator(
            stream: ContextEventStream(),
            backend: NoOpBackend()
        )
        let producer = ContextEventProducer(coordinator: coordinator, debounceSeconds: 0.5)

        // Hook: we can't directly observe coordinator-stream events synchronously,
        // but the producer's emit() logs are deterministic. For the self-test we
        // verify behavior at the producer level by checking which events the
        // producer would generate from a series of snapshots, using a parallel
        // observation buffer (we attach via the public `ingest(event:)` path).
        //
        // Strategy: build snapshots, pass to producer, then snapshot the coordinator's
        // stream and inspect the resulting events.

        // Case 1: active-app change
        let now = Date()
        let snapA = makeSnapshot(app: "Preview", title: "Calculus.pdf", ocr: nil, sel: nil, at: now)
        await producer.ingest(snapshot: snapA, now: now)
        var events = await coordinator.streamSnapshot()
        check("active_app_change_emits_activeAppChanged",
            events.contains { $0.type == .activeAppChanged && $0.appName == "Preview" })
        check("window_title_event",
            events.contains { $0.type == .windowTitleChanged && $0.windowTitle == "Calculus.pdf" })
        collector.absorb(events)

        // Case 2: duplicate snapshot → no new events
        await producer.ingest(snapshot: snapA, now: now.addingTimeInterval(1))
        events = await coordinator.streamSnapshot()
        check("duplicate_suppression",
            events.count == collector.lastCount)
        collector.absorb(events)

        // Case 3: title change only — should add ONE new event (windowTitleChanged)
        let snapB = makeSnapshot(app: "Preview", title: "Calculus Lecture 13.pdf", ocr: nil, sel: nil,
                                  at: now.addingTimeInterval(5))
        await producer.ingest(snapshot: snapB, now: now.addingTimeInterval(5))
        events = await coordinator.streamSnapshot()
        let titleEventsCount = events.filter { $0.type == .windowTitleChanged }.count
        check("title_change_event", titleEventsCount == 2)
        collector.absorb(events)

        // Case 4: OCR available with repeated terms → ocrAvailable event with hints,
        //         but no raw OCR text in hints.
        let ocrText = """
        Calculus II — Derivatives and integrals.
        Derivatives of polynomial functions. Integrals of polynomial functions.
        Practice problems on derivatives. Practice problems on integrals.
        Chapter 12 derivatives summary.
        """
        let snapC = makeSnapshot(app: "Preview", title: "Calculus Lecture 13.pdf",
                                  ocr: ocrText, sel: nil,
                                  at: now.addingTimeInterval(10))
        await producer.ingest(snapshot: snapC, now: now.addingTimeInterval(10))
        events = await coordinator.streamSnapshot()
        guard let ocrEvent = events.last(where: { $0.type == .ocrAvailable }) else {
            check("ocr_metadata_event", false)
            return false
        }
        check("ocr_metadata_event", true)
        check("ocr_privacy_redacted_summary", ocrEvent.privacyLevel == .redactedSummary)
        check("ocr_hints_present", !ocrEvent.textHints.isEmpty)
        check("ocr_hints_contain_repeated_term",
            ocrEvent.textHints.contains("derivatives") || ocrEvent.textHints.contains("integrals"))

        // Privacy: no full sentence from ocrText must appear in hints.
        let leakPhrases: [String] = ["derivatives and integrals", "practice problems on"]
        let hintsJoined = ocrEvent.textHints.joined(separator: " ").lowercased()
        let leaked = leakPhrases.contains(where: { hintsJoined.contains($0) })
        check("ocr_no_raw_text_leak", !leaked)
        collector.absorb(events)

        // Case 5: selected-text event — restricted privacy, no content in hints,
        //         intensity reflects bucketed length.
        let selText = String(repeating: "x", count: 250)
        let snapD = makeSnapshot(app: "Preview", title: "Calculus Lecture 13.pdf",
                                  ocr: ocrText, sel: selText,
                                  at: now.addingTimeInterval(15))
        await producer.ingest(snapshot: snapD, now: now.addingTimeInterval(15))
        events = await coordinator.streamSnapshot()
        guard let selEvent = events.last(where: { $0.type == .selectedTextChanged }) else {
            check("selected_text_event", false)
            return false
        }
        check("selected_text_event", true)
        check("selected_text_restricted", selEvent.privacyLevel == .restricted)
        check("selected_text_no_content_hint", selEvent.textHints.isEmpty)
        check("selected_text_intensity_clamped", selEvent.activityIntensity >= 0 && selEvent.activityIntensity <= 1)

        // Length bucket helper — direct unit check on the static helper.
        check("length_bucket_short", ContextEventProducer.lengthBucket(15) == "0-20")
        check("length_bucket_medium", ContextEventProducer.lengthBucket(150) == "101-500")
        check("length_bucket_long", ContextEventProducer.lengthBucket(10_000) == "2000+")

        // Case 6: typing event passthrough.
        await producer.ingest(event: ContextEvent(
            timestamp: now.addingTimeInterval(20),
            type: .typingStateChanged,
            appName: "Notes",
            bundleIdentifier: nil,
            windowTitle: "Calc 13 notes.md",
            activityIntensity: 0.4
        ))
        events = await coordinator.streamSnapshot()
        check("typing_activity_event",
            events.contains { $0.type == .typingStateChanged && $0.appName == "Notes" })

        // Privacy log sanity — verify the helper logs once.
        ContextEventProducer.assertPrivacyHelperContracts(check: check)

        // Case 7: rapid title changes trigger coalescing logic.
        // Send a burst of snapshots to trigger inferenceInFlight / tickPending coalescing.
        for i in 1...10 {
            let snapRapid = makeSnapshot(app: "Firefox", title: "Rapid Title \(i)", ocr: nil, sel: nil, at: now.addingTimeInterval(25 + Double(i)*0.01))
            await producer.ingest(snapshot: snapRapid, now: now.addingTimeInterval(25 + Double(i)*0.01))
        }
        // Small wait to allow async tick tasks to resolve and log.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let ok = failures.isEmpty
        print("[ContextEventProducerSelfTest] completed ok=\(ok) failures=\(failures.count)")
        return ok
    }

    // MARK: - Helpers

    private static func makeSnapshot(
        app: String,
        title: String,
        ocr: String?,
        sel: String?,
        at: Date
    ) -> CanonicalGeneratedExecutionContextSnapshot {
        CanonicalGeneratedExecutionContextSnapshot(
            activeApp: app,
            windowTitle: title,
            bundleIdentifier: "test.\(app.lowercased())",
            inferredWorkflow: .browsing,
            inferredIntent: nil,
            selectedText: sel,
            clipboardText: nil,
            recentOCRExcerpt: ocr,
            contextSummary: "test_snapshot",
            availableContextTypes: [.textSnippet],
            generatedAt: at
        )
    }

    private final class EventCollector {
        var lastCount: Int = 0
        func absorb(_ events: [ContextEvent]) { lastCount = events.count }
    }
}

// MARK: - Producer privacy-helper assertions

extension ContextEventProducer {

    /// Test-only: assert the static privacy helpers behave correctly. Called
    /// from `ContextEventProducerSelfTest.run`. Keeps the assertion surface
    /// next to the helpers so future renames keep tests in sync.
    static func assertPrivacyHelperContracts(
        check: (String, Bool) -> Void
    ) {
        // OCR hints: must NOT echo full sentences, must lowercase, must filter stopwords.
        let hints = ocrTopicHints("The derivative of sin is cos. The derivative of cos is -sin. derivative derivative.")
        check("ocr_hints_lowercase", hints.allSatisfy { $0 == $0.lowercased() })
        check("ocr_hints_filters_stopwords", !hints.contains("the"))
        check("ocr_hints_returns_repeated", hints.contains("derivative"))
        check("ocr_hints_capped", hints.count <= 6)

        // Title hints: small and unique.
        let titleHints = titleTopicHints("Calculus II - Derivatives and Integrals.pdf")
        check("title_hints_lowercase", titleHints.allSatisfy { $0 == $0.lowercased() })
        check("title_hints_capped", titleHints.count <= 4)
    }
}

// MARK: - Test infrastructure

/// No-op backend used by the producer self-test — keeps the model out of the
/// loop so the test is deterministic.
private struct NoOpBackend: WorkflowInferenceBackend {
    func infer(packet: CompressedTemporalPacket) async -> AmbientWorkflowInferenceResult? { nil }
}

/// Public test hook on the coordinator that exposes the stream's current
/// snapshot. Lives here (not in the production coordinator) to keep that
/// surface clean.
extension WorkflowIntelligenceCoordinator {
    func streamSnapshot() async -> [ContextEvent] {
        await self.eventStreamSnapshotForTesting()
    }
}
