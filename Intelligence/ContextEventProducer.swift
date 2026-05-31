import AppKit
import Foundation

/// Converts existing Contextual context snapshots into `ContextEvent`s and feeds
/// them into `WorkflowIntelligenceCoordinator`. This is the Phase B.1 wiring —
/// nothing else in the app needs to know about Phase B.
///
/// Design constraints:
/// - Producer NEVER stores raw clipboard contents or full selected text.
/// - OCR is distilled to a small set of repeated topic tokens.
/// - Window titles are stored verbatim only on `ContextEvent` (already
///   user-visible chrome); logs use FNV-1a hashes / truncations.
/// - All work is debounced — no inference is started for every keystroke.
/// - A kill switch (`CONTEXTUAL_WORKFLOW_INTELLIGENCE_ENABLED=0`) disables
///   the entire pipeline cleanly.
@MainActor
final class ContextEventProducer {

    // MARK: - Dependencies

    private let coordinator: WorkflowIntelligenceCoordinator
    private let behavioralCoordinator: BehavioralIntelligenceCoordinator?
    public var onAmbientJarvisSuggestionGenerated: (@Sendable (AmbientJarvisSuggestion?) -> Void)?

    // MARK: - Diff state (so we don't emit duplicate events)

    private var lastAppName: String?
    private var lastBundleID: String?
    private var lastTitleHash: String?
    private var lastOCRHash: String?
    private var lastSelectedHash: String?

    // MARK: - Debounce

    private var tickTask: Task<Void, Never>?
    private let debounceSeconds: Double

    // MARK: - One-shot logging

    private var didLogPrivacyBanner = false
	nonisolated(unsafe) private static var didDeferTickForModelNotReady: Bool = false
	nonisolated(unsafe) private static var didLogTickResumed: Bool = false

    // MARK: - Init

    init(
        coordinator: WorkflowIntelligenceCoordinator,
        behavioralCoordinator: BehavioralIntelligenceCoordinator? = nil,
        debounceSeconds: Double = 2.5
    ) {
        self.coordinator = coordinator
        self.behavioralCoordinator = behavioralCoordinator
        self.debounceSeconds = max(0.5, debounceSeconds)
    }

    // MARK: - Public API

    /// Feed one canonical snapshot to the producer. Diffs against the prior
    /// snapshot, emits only meaningful events, and schedules a debounced tick.
    func ingest(snapshot: CanonicalGeneratedExecutionContextSnapshot, now: Date = Date()) async {

        // Kill switch.
        if !WorkflowIntelligencePipeline.isEnabled {
            WorkflowIntelligencePipeline.logDisabledOnce()
            return
        }
        logPrivacyBannerOnce()

        var producedAny = false

        // 1. activeAppChanged
        let appKey = "\(snapshot.activeApp)|\(snapshot.bundleIdentifier ?? "")"
        let prevAppKey = "\(lastAppName ?? "")|\(lastBundleID ?? "")"
        if appKey != prevAppKey && !snapshot.activeApp.isEmpty {
            let event = ContextEvent(
                timestamp: now,
                type: .activeAppChanged,
                appName: snapshot.activeApp,
                bundleIdentifier: snapshot.bundleIdentifier,
                windowTitle: snapshot.windowTitle,
                textHints: [],
                sourceConfidence: 0.95,
                privacyLevel: .publicMetadata,
                activityIntensity: 0.0
            )
            await emit(event)
            lastAppName = snapshot.activeApp
            lastBundleID = snapshot.bundleIdentifier
            producedAny = true
        }

        // 2. windowTitleChanged
        let title = snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            let titleHash = Self.fnv1a(title)
            if titleHash != lastTitleHash {
                let event = ContextEvent(
                    timestamp: now,
                    type: .windowTitleChanged,
                    appName: snapshot.activeApp,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    windowTitle: title,
                    textHints: Self.titleTopicHints(title),
                    sourceConfidence: 0.9,
                    privacyLevel: .publicMetadata,
                    activityIntensity: 0.0
                )
                await emit(event)
                lastTitleHash = titleHash
                producedAny = true
            } else {
                print("[ContextEventProducer] skipped reason=duplicate_event type=windowTitleChanged")
            }
        }

        // 3. ocrAvailable — distill topic tokens, never store raw OCR.
        if let ocrRaw = snapshot.recentOCRExcerpt,
           !ocrRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ocrHash = Self.fnv1a(ocrRaw)
            if ocrHash != lastOCRHash {
                let hints = Self.ocrTopicHints(ocrRaw)
                let event = ContextEvent(
                    timestamp: now,
                    type: .ocrAvailable,
                    appName: snapshot.activeApp,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    windowTitle: title,
                    textHints: hints,
                    sourceConfidence: 0.85,
                    privacyLevel: .redactedSummary,
                    activityIntensity: 0.0
                )
                await emit(event, extra: "chars=\(ocrRaw.count)")
                print("[WorkflowPrivacy] ocr_excerpt_truncated=yes chars=\(min(ocrRaw.count, 0))")
                lastOCRHash = ocrHash
                producedAny = true
            } else {
                print("[ContextEventProducer] skipped reason=duplicate_event type=ocrAvailable")
            }
        }

        // 4. selectedTextChanged — METADATA only. Length is the signal; the
        //    content is never copied into the event or the logs.
        if let selRaw = snapshot.selectedText,
           !selRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let selHash = Self.fnv1a(selRaw)
            if selHash != lastSelectedHash {
                let intensity = min(Double(selRaw.count) / 1000.0, 1.0)
                let event = ContextEvent(
                    timestamp: now,
                    type: .selectedTextChanged,
                    appName: snapshot.activeApp,
                    bundleIdentifier: snapshot.bundleIdentifier,
                    windowTitle: title,
                    textHints: [],
                    sourceConfidence: 0.9,
                    privacyLevel: .restricted,
                    activityIntensity: intensity
                )
                await emit(event, extra: "len_bucket=\(Self.lengthBucket(selRaw.count))")
                lastSelectedHash = selHash
                producedAny = true
            } else {
                print("[ContextEventProducer] skipped reason=duplicate_event type=selectedTextChanged")
            }
        }

        if producedAny {
            scheduleTick(oldInferenceLabel: snapshot.inferredWorkflow.rawValue)
        } else {
            print("[WorkflowPipeline] tick_skipped reason=no_meaningful_events")
        }
    }

    /// Direct event passthrough — used by the typing/pointer/proposal hooks
    /// when they want to feed events without going through a snapshot.
    func ingest(event: ContextEvent, oldInferenceLabel: String? = nil) async {
        if !WorkflowIntelligencePipeline.isEnabled {
            WorkflowIntelligencePipeline.logDisabledOnce()
            return
        }
        await emit(event)
        scheduleTick(oldInferenceLabel: oldInferenceLabel)
    }

    /// Record that the user accepted a proposal (used by the inference packet).
    func recordProposalAccepted(_ title: String) async {
        await coordinator.recordProposalAccepted(title)
    }

    /// Record that the user dismissed/ignored a proposal.
    func recordProposalDismissed(_ title: String) async {
        await coordinator.recordProposalDismissed(title)
    }

    // Actor-isolated state for concurrency control
    private var inferenceInFlight: Bool = false
    private var tickPending: Bool = false

    // MARK: - Internal emission

    private func emit(_ event: ContextEvent, extra: String = "") async {
        await coordinator.recordEvent(event)

        let hashPrefix = Self.fnv1a(event.windowTitle).prefix(8)
        let extras = extra.isEmpty ? "" : " \(extra)"
        print("[ContextEventProducer] produced type=\(event.type.rawValue) app=\(event.appName) title_hash=\(hashPrefix)\(extras)")
        print("[WorkflowPipeline] event_recorded type=\(event.type.rawValue)")
    }

    private func scheduleTick(oldInferenceLabel: String?) {
        tickTask?.cancel()
        let delayMs = Int(debounceSeconds * 1000)
        print("[WorkflowPipeline] tick_scheduled delay_ms=\(delayMs) reason=meaningful_event")
        let oldLabel = oldInferenceLabel
        let delay = debounceSeconds
        tickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self else { return }

            if self.inferenceInFlight {
                self.tickPending = true
                print("[WorkflowPipeline] tick_coalesced reason=inference_in_flight")
                return
            }

            await self.executeTick(oldInferenceLabel: oldLabel)
        }
    }

    private func executeTick(oldInferenceLabel: String?) async {
        inferenceInFlight = true
        tickPending = false
        defer {
            inferenceInFlight = false
            if tickPending {
                print("[WorkflowPipeline] pending_tick_started reason=coalesced_updates")
                scheduleTick(oldInferenceLabel: oldInferenceLabel)
            }
        }

        // Phase B.1.8 — Startup quiet period: collect events, but do not run local models yet.
        if ModelManager.shared.isWithinStartupQuietPeriod() {
            let elapsed = ModelManager.shared.secondsSinceLaunch() ?? 0
            print("[StartupBudget] heavy_inference_deferred reason=startup_quiet_period elapsed_s=\(elapsed)")
            return
        }

        // Phase B.1.8 — Gate workflow inference on model readiness.
        let ready = await ModelManager.shared.isGenerationAvailable()
        if !ready {
            Self.didDeferTickForModelNotReady = true
            print("[WorkflowPipeline] tick_deferred reason=model_not_ready")
            return
        }
        if Self.didDeferTickForModelNotReady, !Self.didLogTickResumed {
            Self.didLogTickResumed = true
            print("[WorkflowPipeline] tick_resumed reason=model_ready")
        }

        // Phase B.1.8 — Single local model lane backpressure.
        let acquired = await LocalAIBackpressure.shared.acquire(purpose: "workflow_inference")
        if !acquired {
            print("[LocalAIBackpressure] deferred workflow_inference reason=goal_generator_active")
            return
        }
        defer {
            Task { await LocalAIBackpressure.shared.release(purpose: "workflow_inference") }
        }

        print("[WorkflowPipeline] tick_started")
        let state = await coordinator.tick(now: Date(), oldInferenceLabel: oldInferenceLabel)
        let confStr = String(format: "%.2f", state.confidence)
        print("[WorkflowPipeline] tick_completed workflow=\(state.workflowType.rawValue) confidence=\(confStr)")

        if let behavioral = self.behavioralCoordinator {
            let events = await coordinator.getEventStreamSnapshot()
            let buffer = TemporalContextBuffer.build(from: events, now: Date())
            let stabilized = await behavioral.tick(
                workflowState: state,
                shortWindow: buffer.short,
                now: Date()
            )
                
                // Phase 20D.5 — eligibility is now any workflow + behavior
                // that are both actionable (neither `.unknown` nor `.idle`).
                // The actual gate still lives inside JarvisSuggestionGenerator;
                // this is just the user-visible "I would have surfaced but the
                // mode is off" trace.
                let workflowActionable = state.workflowType != .unknown && state.workflowType != .idle
                let behaviorActionable = stabilized.state != .unknown && stabilized.state != .idle
                let isEligible = workflowActionable && behaviorActionable
                if isEligible && !AmbientMVPMode.isEnabled {
                    print("[AmbientMVPMode] warning=eligible_context_but_mode_disabled workflow=\(state.workflowType.rawValue) behavior=\(stabilized.state.rawValue)")
                }

                if AmbientMVPMode.isEnabled {
                    let compressor = TemporalContextCompressor.compress(buffer: buffer)
                    let suggestion = await JarvisSuggestionGenerator.generate(
                        workflowState: state,
                        behavioralRecord: stabilized,
                        packet: compressor,
                        recentTitles: buffer.short.recentTitles,
                        repeatedTerms: buffer.short.repeatedTerms
                    )
                    self.onAmbientJarvisSuggestionGenerated?(suggestion)
                }
            }
    }

    // MARK: - One-shot privacy banner

    private func logPrivacyBannerOnce() {
        guard !didLogPrivacyBanner else { return }
        didLogPrivacyBanner = true
        print("[WorkflowPrivacy] clipboard_content_logged=no")
        print("[WorkflowPrivacy] selected_text_mode=metadata_only")
        print("[WorkflowPrivacy] ocr_topic_extraction=enabled")
    }

    // MARK: - Helpers (deterministic, internal-accessible for tests)

    /// Stable FNV-1a hash over UTF-8 bytes.
    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return String(h, radix: 16)
    }

    /// Distill repeated topic terms from an OCR excerpt. Returns at most 6
    /// lowercase tokens, each 4–20 chars, appearing at least twice. Numbers,
    /// punctuation, and very short tokens are dropped. Raw OCR is NEVER
    /// returned, only term tokens.
    static func ocrTopicHints(_ ocr: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for",
            "is", "are", "was", "be", "with", "by", "from", "this", "that",
            "it", "as", "but", "if", "so", "do", "did", "has", "have", "had",
            "will", "can", "get", "your", "you", "our", "their", "they", "all",
            "one", "two", "three", "out", "up", "not", "into", "than", "then",
            "what", "when", "where", "which", "who", "how",
        ]
        let words = ocr.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { token in
                guard token.count >= 4, token.count <= 20 else { return false }
                if stopwords.contains(token) { return false }
                if Int(token) != nil { return false }
                return true
            }
        var counts: [String: Int] = [:]
        for w in words { counts[w, default: 0] += 1 }
        return counts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map(\.key)
    }

    /// Title hints — short, low-volume topic distillation from the title only.
    static func titleTopicHints(_ title: String) -> [String] {
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && $0.count <= 20 }
        var unique: [String] = []
        var seen = Set<String>()
        for w in words where seen.insert(w).inserted {
            unique.append(w)
            if unique.count >= 4 { break }
        }
        return unique
    }

    /// Coarse length bucket so logs never reveal exact selection sizes.
    static func lengthBucket(_ n: Int) -> String {
        switch n {
        case 0...20: return "0-20"
        case 21...100: return "21-100"
        case 101...500: return "101-500"
        case 501...2000: return "501-2000"
        default: return "2000+"
        }
    }
}

// MARK: - Pipeline kill switch

/// Process-wide on/off for the Workflow Intelligence pipeline. Default ON.
/// Disable with `CONTEXTUAL_WORKFLOW_INTELLIGENCE_ENABLED=0`.
enum WorkflowIntelligencePipeline {

    static var isEnabled: Bool {
        return ValidationConfiguration.workflowIntelligenceEnabled
    }

    nonisolated(unsafe) private static var didLogDisabled = false

    /// Log the disabled-state banner exactly once per process.
    static func logDisabledOnce() {
        if didLogDisabled { return }
        didLogDisabled = true
        print("[WorkflowPipeline] disabled reason=user_or_env")
    }
}
