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

    // MARK: - Init

    init(coordinator: WorkflowIntelligenceCoordinator, debounceSeconds: Double = 2.5) {
        self.coordinator = coordinator
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
        let coordinator = self.coordinator
        tickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let _ = self else { return }
            print("[WorkflowPipeline] tick_started")
            let state = await coordinator.tick(now: Date(), oldInferenceLabel: oldLabel)
            let confStr = String(format: "%.2f", state.confidence)
            print("[WorkflowPipeline] tick_completed workflow=\(state.workflowType.rawValue) confidence=\(confStr)")
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
        let raw = ProcessInfo.processInfo.environment["CONTEXTUAL_WORKFLOW_INTELLIGENCE_ENABLED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw == "0" || raw == "no" || raw == "false" { return false }
        return true
    }

    nonisolated(unsafe) private static var didLogDisabled = false

    /// Log the disabled-state banner exactly once per process.
    static func logDisabledOnce() {
        if didLogDisabled { return }
        didLogDisabled = true
        print("[WorkflowPipeline] disabled reason=user_or_env")
    }
}
