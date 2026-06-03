import Foundation

// MARK: - Packet

/// Compact summary of recent user behavior, sized for a small local model
/// (qwen2.5:0.5b). The packet IS the only thing the inference layer sees.
///
/// It must:
/// - stay under ~1 KB serialized
/// - carry temporal patterns, not raw text dumps
/// - never include clipboard payloads or full OCR contents
public struct CompressedTemporalPacket: Sendable, Codable, Equatable {
    public let currentApp: String
    public let recentApps: [String]
    public let recentTitles: [String]
    public let topicTerms: [String]
    public let activityPattern: String   // bursty | steady | idle
    public let idlePattern: String       // active | intermittent | long_idle
    public let typingPattern: String     // heavy | light | none
    public let pointerPattern: String    // active | occasional | none
    public let ocrHints: [String]
    public let selectionHints: [String]
    public let clipboardMetadata: String
    public let recentUserAccepts: [String]
    public let recentUserIgnores: [String]
    public let spanSeconds: Int
    public let eventCount: Int
    /// B.1.6: set when the medium window detected a recent topic-distribution
    /// shift. The stabilizer uses this to allow faster workflow correction
    /// after a clear context change (e.g. Gmail → Amazon).
    public let contextShiftDetected: Bool
}

// MARK: - Compressor

/// Folds a `TemporalContextBuffer` into a `CompressedTemporalPacket`.
///
/// The compressor is the privacy boundary: raw OCR / selection / clipboard
/// payloads NEVER cross from event hints into the packet. Only counts,
/// distilled topic terms, and metadata strings do.
public enum TemporalContextCompressor {

    public static func compress(
        buffer: TemporalContextBuffer,
        recentAccepts: [String] = [],
        recentIgnores: [String] = [],
        clipboardKind: String? = nil,
        clipboardLength: Int? = nil,
        now: Date = Date()
    ) -> CompressedTemporalPacket {
        let medium = buffer.medium
        let long = buffer.long

        // B.1.5 input counts.
        let mediumOCR = medium.eventCountsByType[ContextEventType.ocrAvailable.rawValue] ?? 0
        let mediumSelections = medium.eventCountsByType[ContextEventType.selectedTextChanged.rawValue] ?? 0
        let mediumTyping = medium.eventCountsByType[ContextEventType.typingStateChanged.rawValue] ?? 0
        let mediumPointer = medium.eventCountsByType[ContextEventType.pointerStateChanged.rawValue] ?? 0
        print("[WorkflowPacket] titles=\(medium.recentTitles.count) ocr_events=\(mediumOCR) selection_events=\(mediumSelections) typing_events=\(mediumTyping) pointer_events=\(mediumPointer)")
        print("[WorkflowPacket] repeated_terms_medium=\(medium.repeatedTerms.count) repeated_terms_long=\(long.repeatedTerms.count) dominant_apps_medium=\(medium.dominantApps.count)")

        // B.1.6: declare packet source policy explicitly.
        print("[WorkflowPacket] topic_source=medium_weighted")
        print("[WorkflowPacket] ocr_source=fresh_ocr_terms")
        print("[WorkflowPacket] long_window_role=continuity_only")

        // Apps: medium window.
        let recentApps = Array(medium.dominantApps.prefix(5))
        let currentApp = recentApps.first ?? "unknown"

        // Titles: medium window, most-recent-first, sanitized, capped.
        let recentTitlesInput = medium.recentTitles
            .reversed()
            .map { sanitizeTitle($0) }
        let recentTitles = Array(recentTitlesInput.prefix(8))
        let discardedTitles = max(0, recentTitlesInput.count - recentTitles.count)

        // B.1.6 FIX: topic terms come from the MEDIUM window's weighted-sorted
        // list. The long window is no longer the primary source — it stays
        // available for continuity callers (none yet) but does not feed
        // workflow classification.
        let topicTerms = Array(medium.repeatedTerms.prefix(8))
        let discardedTerms = max(0, medium.repeatedTerms.count - topicTerms.count)
        print("[WorkflowPacket] discarded_titles=\(discardedTitles) discarded_terms=\(discardedTerms)")

        // B.1.6 FIX: OCR hints come ONLY from terms that actually appeared in
        // ocrAvailable events. No more `formUnion(long.repeatedTerms)` duplication.
        let ocrHints = Array(medium.ocrEventTerms.prefix(8))
        if ocrHints.isEmpty {
            print("[WorkflowPacket] ocr_hints_source=ocr_events_only ocr_hints_count=0 reason=no_ocr_events_or_below_threshold")
        } else {
            print("[WorkflowPacket] ocr_hints_source=ocr_events_only ocr_hints_count=\(ocrHints.count)")
        }

        // B.1.6 per-term diagnostic — surfaces raw count vs. weighted score
        // and age at packet build time. This makes recency dominance visible.
        for term in topicTerms {
            let raw = medium.termRawCounts[term] ?? 0
            let weighted = medium.termWeightedScores[term] ?? 0
            let firstAge = medium.termFirstSeen[term].map { Int(now.timeIntervalSince($0)) } ?? -1
            let lastAge  = medium.termLastSeen[term].map { Int(now.timeIntervalSince($0)) } ?? -1
            let weightedStr = String(format: "%.2f", weighted)
            print("[WorkflowTermScore] term=\(term) raw=\(raw) weighted=\(weightedStr) first_age_s=\(firstAge) last_age_s=\(lastAge)")
        }

        // Pattern classification — purely signal-derived strings.
        let activityPattern = classifyActivity(medium)
        let idlePattern = classifyIdle(medium)
        let typingPattern = classifyTyping(medium)
        let pointerPattern = classifyPointer(medium)

        // B.1.6: `ocrHints` is already computed above from `medium.ocrEventTerms`.
        // The previous `formUnion(long.repeatedTerms)` block was the duplication bug.

        // Selection / clipboard: METADATA only.
        let selectionHints: [String] = {
            var hints: [String] = []
            if mediumSelections > 0 {
                hints.append("selected_text_available=true")
                hints.append("selection_events=\(mediumSelections)")
            }
            if medium.titleTransitions > 0 {
                hints.append("recent_title_changes=\(medium.titleTransitions)")
            }
            return hints
        }()

        let clipboardMeta: String = {
            if let k = clipboardKind, let len = clipboardLength {
                return "kind=\(k) len=\(len)"
            }
            return "none"
        }()

        let packet = CompressedTemporalPacket(
            currentApp: currentApp,
            recentApps: recentApps,
            recentTitles: Array(recentTitles),
            topicTerms: topicTerms,
            activityPattern: activityPattern,
            idlePattern: idlePattern,
            typingPattern: typingPattern,
            pointerPattern: pointerPattern,
            ocrHints: Array(ocrHints),
            selectionHints: selectionHints,
            clipboardMetadata: clipboardMeta,
            recentUserAccepts: Array(recentAccepts.suffix(5)),
            recentUserIgnores: Array(recentIgnores.suffix(5)),
            spanSeconds: Int(long.durationSeconds),
            eventCount: long.eventCount,
            contextShiftDetected: medium.contextShift.detected
        )

        let encodedChars = (try? JSONEncoder().encode(packet))?.count ?? 0
        print("[TemporalContextCompressor] packet_chars=\(encodedChars) events_used=\(packet.eventCount)")

        // Phase 20G — feed the epoch tracker. This is the single canonical
        // observation point: every caller of `compress` (producer, coordinator,
        // ManualInvokeJarvis, tests) advances the tracker uniformly.
        ContextEpochTracker.shared.observe(
            contextShiftDetected: medium.contextShift.detected,
            shiftReason: medium.contextShift.reason,
            earlyTopTerms: medium.contextShift.earlyTopTerms,
            recentTopTerms: medium.contextShift.recentTopTerms,
            recentTitles: Array(recentTitles),
            at: now
        )

        // B.1.5: freshness for every term/title in the packet, now sourced from
        // the medium window (the same window topicTerms come from after B.1.6).
        for term in topicTerms {
            if let firstSeen = medium.termFirstSeen[term] {
                let age = Int(now.timeIntervalSince(firstSeen))
                let lastAge: Int = medium.termLastSeen[term].map { Int(now.timeIntervalSince($0)) } ?? -1
                print("[WorkflowFreshness] term=\(term) age_s=\(age) last_seen_age_s=\(lastAge)")
            } else {
                print("[WorkflowFreshness] term=\(term) age_s=unknown last_seen_age_s=unknown")
            }
        }
        for title in recentTitles {
            // Compressor sanitizes titles to 80 chars; firstSeen keys store the
            // pre-sanitized title. Look both up to be robust.
            let firstSeen = medium.titleFirstSeen[title]
                ?? medium.titleFirstSeen.first(where: { sanitizeTitle($0.key) == title })?.value
            let lastSeen = medium.titleLastSeen[title]
                ?? medium.titleLastSeen.first(where: { sanitizeTitle($0.key) == title })?.value
            if let firstSeen {
                let age = Int(now.timeIntervalSince(firstSeen))
                let lastAge = lastSeen.map { Int(now.timeIntervalSince($0)) } ?? -1
                print("[WorkflowFreshness] title=\"\(title.prefix(40))\" age_s=\(age) last_seen_age_s=\(lastAge)")
            } else {
                print("[WorkflowFreshness] title=\"\(title.prefix(40))\" age_s=unknown")
            }
        }

        var sources: [String] = ["apps", "titles", "activity"]
        if !ocrHints.isEmpty { sources.append("ocr_terms") }
        if !selectionHints.isEmpty { sources.append("selection") }
        if clipboardKind != nil { sources.append("clipboard_meta") }
        if !packet.recentUserAccepts.isEmpty { sources.append("accepts") }
        if !packet.recentUserIgnores.isEmpty { sources.append("ignores") }
        print("[TemporalContextCompressor] sources=\(sources.joined(separator: ","))")

        return packet
    }

    // MARK: - Pattern classifiers

    private static func classifyActivity(_ w: TemporalContextWindow) -> String {
        let blended = (w.typingScore + w.pointerScore) / 2
        if w.activityBursts >= 2 && blended >= 0.4 { return "bursty" }
        if blended >= 0.15 { return "steady" }
        return "idle"
    }

    private static func classifyIdle(_ w: TemporalContextWindow) -> String {
        let ratio = w.idleSeconds / max(1, w.durationSeconds)
        if ratio >= 0.6 { return "long_idle" }
        if ratio >= 0.2 { return "intermittent" }
        return "active"
    }

    private static func classifyTyping(_ w: TemporalContextWindow) -> String {
        if w.typingScore >= 0.4 { return "heavy" }
        if w.typingScore >= 0.1 { return "light" }
        return "none"
    }

    private static func classifyPointer(_ w: TemporalContextWindow) -> String {
        if w.pointerScore >= 0.4 { return "active" }
        if w.pointerScore >= 0.1 { return "occasional" }
        return "none"
    }

    // MARK: - Privacy helpers

    /// Trim a title to a safe length. Producers are expected to have already
    /// stripped any sensitive substrings before emitting the event.
    private static func sanitizeTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(80))
    }
}
