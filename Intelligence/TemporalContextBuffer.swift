import Foundation

// MARK: - Context shift analysis (B.1.6)

/// Result of an early-half vs recent-half topic distribution comparison over
/// the medium window. Used to detect when the user's activity has shifted
/// (e.g. Gmail → Amazon) so the compressor can downweight stale terms and the
/// stabilizer can allow a faster correction.
///
/// Signal-only — NEVER references app or workflow names.
public struct ContextShiftAnalysis: Sendable, Codable, Equatable {
    public let detected: Bool
    /// Age in seconds of the boundary between "early" and "recent" halves.
    public let boundaryAgeSeconds: Int
    public let earlyTopTerms: [String]
    public let recentTopTerms: [String]
    /// |early ∩ recent| / |early ∪ recent|. Low jaccard = strong shift.
    public let jaccard: Double
    public let reason: String
    /// Terms present in the early half but not in the recent half — these get
    /// the staleness penalty applied to their weighted scores.
    public let downweightedTerms: [String]

    public static let noShift = ContextShiftAnalysis(
        detected: false,
        boundaryAgeSeconds: 0,
        earlyTopTerms: [],
        recentTopTerms: [],
        jaccard: 1.0,
        reason: "no_shift",
        downweightedTerms: []
    )

    /// Compare early-half topic distribution to recent-half. Returns a
    /// `detected=true` analysis when the jaccard overlap is low AND the app
    /// changed OR the topic distribution clearly drifted.
    public static func analyze(events: [ContextEvent], now: Date) -> ContextShiftAnalysis {
        guard events.count >= 6 else { return .noShift }
        guard let first = events.first?.timestamp, let last = events.last?.timestamp else {
            return .noShift
        }
        let midpoint = first.addingTimeInterval(last.timeIntervalSince(first) / 2)

        var earlyCounts: [String: Int] = [:]
        var recentCounts: [String: Int] = [:]
        var earlyApps: [String: Int] = [:]
        var recentApps: [String: Int] = [:]

        for ev in events {
            let recent = ev.timestamp >= midpoint
            for term in ev.textHints {
                let n = term.lowercased()
                guard n.count >= 3 else { continue }
                if recent { recentCounts[n, default: 0] += 1 }
                else      { earlyCounts[n, default: 0] += 1 }
            }
            if recent { recentApps[ev.appName, default: 0] += 1 }
            else      { earlyApps[ev.appName, default: 0] += 1 }
        }

        let earlyTop = Set(earlyCounts.sorted { $0.value > $1.value }.prefix(8).map(\.key))
        let recentTop = Set(recentCounts.sorted { $0.value > $1.value }.prefix(8).map(\.key))

        let inter = earlyTop.intersection(recentTop).count
        let union = earlyTop.union(recentTop).count
        let jaccard: Double = union > 0 ? Double(inter) / Double(union) : 1.0

        let dominantEarly = earlyApps.max(by: { $0.value < $1.value })?.key
        let dominantRecent = recentApps.max(by: { $0.value < $1.value })?.key
        let appChanged = dominantEarly != nil && dominantRecent != nil && dominantEarly != dominantRecent

        let topicDrift = jaccard < 0.30 && !earlyTop.isEmpty && !recentTop.isEmpty
        let appDrift   = appChanged && jaccard < 0.50 && !earlyTop.isEmpty

        let detected = topicDrift || appDrift
        let reason: String = {
            if topicDrift { return "topic_distribution_changed" }
            if appDrift   { return "app_changed_with_topic_drift" }
            return "no_shift"
        }()
        let downweighted = detected
            ? Array(earlyTop.subtracting(recentTop)).sorted()
            : []
        let boundaryAge = Int(max(0, now.timeIntervalSince(midpoint)))

        return ContextShiftAnalysis(
            detected: detected,
            boundaryAgeSeconds: boundaryAge,
            earlyTopTerms: Array(earlyTop).sorted(),
            recentTopTerms: Array(recentTop).sorted(),
            jaccard: jaccard,
            reason: reason,
            downweightedTerms: downweighted
        )
    }
}

// MARK: - Window

/// A rolling-window view over recent `ContextEvent`s plus derived aggregates.
///
/// The buffer never owns the events — it borrows the latest snapshot from
/// `ContextEventStream` and folds it into windowed signals (5 min / 15 min /
/// 30 min). All aggregates are signal-level (counts, EMAs, term frequencies)
/// — no raw text blobs.
public struct TemporalContextWindow: Sendable, Codable, Equatable {
    public let durationSeconds: TimeInterval
    public let eventCount: Int
    public let dominantApps: [String]
    public let titleTransitions: Int
    public let appTransitions: Int
    public let repeatedTerms: [String]
    public let activityBursts: Int
    public let idleSeconds: TimeInterval
    public let typingScore: Double
    public let pointerScore: Double
    /// Last few title changes in temporal order (most recent first). Trimmed.
    public let recentTitles: [String]
    /// Detected "App→App" transitions in temporal order. Trimmed.
    public let transitions: [String]
    // MARK: Provenance (B.1.5 diagnostics) — first-seen timestamps for each
    // retained term / title in this window. Used by the compressor and the
    // coordinator to log `[WorkflowFreshness]` ages. NOT used for scoring.
    public let termFirstSeen: [String: Date]
    public let termLastSeen: [String: Date]
    public let titleFirstSeen: [String: Date]
    public let titleLastSeen: [String: Date]
    /// Per-type event counts in this window (event_type.rawValue → count).
    public let eventCountsByType: [String: Int]
    /// Events the stream offered but fell outside this window's cutoff.
    public let droppedOutsideWindow: Int
    // MARK: B.1.6 recency-weighted scoring
    /// Weighted score for each term: sum of `exp(-age / halfLife)` per occurrence.
    /// Used for ranking; lets fresh activity dominate stale activity.
    public let termWeightedScores: [String: Double]
    /// Raw occurrence count for each term (for diagnostics + filtering noise).
    public let termRawCounts: [String: Int]
    /// Terms drawn ONLY from `ocrAvailable` events in this window, sorted by
    /// weighted score descending. This is the new authoritative source for
    /// `ocrHints` — it stops OCR hints from duplicating topic terms.
    public let ocrEventTerms: [String]
    /// Weighted scores for the OCR-event terms.
    public let ocrEventTermScores: [String: Double]
    /// Context shift analysis for this window. Only computed on the medium
    /// window; short/long windows always return `.noShift`.
    public let contextShift: ContextShiftAnalysis
}

// MARK: - Buffer

/// Three windowed views over the same temporal event stream.
///
/// Short / Medium / Long give the compressor and stabilizer multiple time
/// horizons to reason over: a single tab-switch may flip "short" but should
/// not flip "long". The Stabilizer uses these to debounce noise.
public struct TemporalContextBuffer: Sendable, Codable, Equatable {
    public let short: TemporalContextWindow     // 5 min
    public let medium: TemporalContextWindow    // 15 min
    public let long: TemporalContextWindow      // 30 min

    public static func build(from events: [ContextEvent], now: Date = Date()) -> TemporalContextBuffer {
        let s = makeWindow(events: events, seconds: 300,  now: now, label: "short_5m")
        let m = makeWindow(events: events, seconds: 900,  now: now, label: "medium_15m")
        let l = makeWindow(events: events, seconds: 1800, now: now, label: "long_30m")

        print("[TemporalContextBuffer] updated events=\(events.count) span_s=\(Int(l.durationSeconds))")
        let dom = l.dominantApps.prefix(3).joined(separator: ",")
        print("[TemporalContextBuffer] dominant_apps=\(dom)")
        let repeated = l.repeatedTerms.prefix(5).joined(separator: ",")
        print("[TemporalContextBuffer] repeated_terms=\(repeated)")

        return TemporalContextBuffer(short: s, medium: m, long: l)
    }

    // MARK: - Window construction

    // MARK: - B.1.6 weighting helpers

    /// `exp(-age / halfLife)` per occurrence. Older events contribute less.
    private static func recencyWeight(eventTime: Date, now: Date, halfLife: TimeInterval) -> Double {
        let age = max(0, now.timeIntervalSince(eventTime))
        return exp(-age / halfLife)
    }

    /// Half-life seconds, chosen so each window has a different memory horizon:
    /// short → 90 s, medium → 300 s, long → 900 s. Spec values from B.1.6.
    private static func halfLife(forWindowSeconds seconds: TimeInterval) -> TimeInterval {
        if seconds <= 300 { return 90 }
        if seconds <= 900 { return 300 }
        return 900
    }

    private static func makeWindow(
        events: [ContextEvent],
        seconds: TimeInterval,
        now: Date,
        label: String = "window"
    ) -> TemporalContextWindow {
        let cutoff = now.addingTimeInterval(-seconds)
        let windowed = events.filter { $0.timestamp >= cutoff }
        let halfLifeSeconds = halfLife(forWindowSeconds: seconds)

        var appCounts: [String: Int] = [:]
        var termRawCounts: [String: Int] = [:]
        var termWeightedScores: [String: Double] = [:]
        // B.1.6: OCR aggregation is now SEPARATE from general topic aggregation.
        // This is the fix for the OCR-hint duplication bug.
        var ocrRawCounts: [String: Int] = [:]
        var ocrWeightedScores: [String: Double] = [:]
        var lastApp: String? = nil
        var lastTitle: String? = nil
        var appTransitions = 0
        var titleTransitions = 0
        var typingTotal: Double = 0
        var pointerTotal: Double = 0
        var typingEventCount = 0
        var pointerEventCount = 0
        var transitions: [String] = []
        var recentTitles: [String] = []
        var idleAccumulated: TimeInterval = 0
        var idleAnchor: Date? = nil

        // B.1.5 provenance — first-seen / last-seen timestamps per term and title.
        var termFirstSeen: [String: Date] = [:]
        var termLastSeen: [String: Date] = [:]
        var titleFirstSeen: [String: Date] = [:]
        var titleLastSeen: [String: Date] = [:]
        var eventCountsByType: [String: Int] = [:]

        for ev in windowed {
            let weight = recencyWeight(eventTime: ev.timestamp, now: now, halfLife: halfLifeSeconds)
            eventCountsByType[ev.type.rawValue, default: 0] += 1
            appCounts[ev.appName, default: 0] += 1
            for term in ev.textHints {
                let normalized = term.lowercased()
                guard normalized.count >= 3 else { continue }
                termRawCounts[normalized, default: 0] += 1
                termWeightedScores[normalized, default: 0] += weight
                if termFirstSeen[normalized] == nil { termFirstSeen[normalized] = ev.timestamp }
                termLastSeen[normalized] = ev.timestamp

                // Separate OCR-only aggregation: ONLY ocrAvailable contributes.
                if ev.type == .ocrAvailable {
                    ocrRawCounts[normalized, default: 0] += 1
                    ocrWeightedScores[normalized, default: 0] += weight
                }
            }
            if let prevApp = lastApp, prevApp != ev.appName {
                appTransitions += 1
                transitions.append("\(prevApp)→\(ev.appName)")
            }
            if let prevTitle = lastTitle, prevTitle != ev.windowTitle {
                titleTransitions += 1
                recentTitles.append(ev.windowTitle)
            }
            if titleFirstSeen[ev.windowTitle] == nil { titleFirstSeen[ev.windowTitle] = ev.timestamp }
            titleLastSeen[ev.windowTitle] = ev.timestamp
            lastApp = ev.appName
            lastTitle = ev.windowTitle

            if ev.type == .typingStateChanged {
                typingTotal += ev.activityIntensity
                typingEventCount += 1
            } else if ev.type == .pointerStateChanged {
                pointerTotal += ev.activityIntensity
                pointerEventCount += 1
            }
            if ev.type == .userIdle { idleAnchor = ev.timestamp }
            if ev.type == .userResumed, let start = idleAnchor {
                idleAccumulated += ev.timestamp.timeIntervalSince(start)
                idleAnchor = nil
            }
        }
        if let start = idleAnchor {
            idleAccumulated += now.timeIntervalSince(start)
        }

        // MARK: B.1.6 context-shift analysis — medium window only.
        // The medium window is the one feeding `topicTerms` after B.1.6, so
        // that's the window where a fresh shift matters most.
        let isMediumWindow = (label == "medium_15m")
        var shift: ContextShiftAnalysis = .noShift
        if isMediumWindow {
            shift = ContextShiftAnalysis.analyze(events: windowed, now: now)
            if shift.detected {
                let stale = shift.downweightedTerms.prefix(6).joined(separator: ",")
                print("[WorkflowContextShift] detected=yes reason=\(shift.reason)")
                print("[WorkflowContextShift] shifted_at_age_s=\(shift.boundaryAgeSeconds)")
                print("[WorkflowContextShift] downweighted_stale_terms=\(stale)")
                // Apply staleness penalty to terms that disappeared after the shift.
                // 0.30x mirrors B.1.5 root-cause spec — strong enough to demote
                // a stale dominator but not zero so continuity is preserved.
                for term in shift.downweightedTerms {
                    if let w = termWeightedScores[term] { termWeightedScores[term] = w * 0.30 }
                    if let w = ocrWeightedScores[term] { ocrWeightedScores[term] = w * 0.30 }
                }
            } else {
                print("[WorkflowContextShift] detected=no reason=\(shift.reason)")
            }
        }

        let dominantApps = appCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)

        // B.1.6: filter by rawCount >= 2 (noise gate), sort by WEIGHTED score.
        let repeatedTerms = termRawCounts
            .filter { $0.value >= 2 }
            .keys
            .sorted { a, b in (termWeightedScores[a] ?? 0) > (termWeightedScores[b] ?? 0) }
            .prefix(8)
            .map { String($0) }

        // B.1.6: OCR-only terms sorted by weighted score. Same noise gate
        // applied separately so an OCR-only term repeated once is filtered out.
        let ocrEventTerms = ocrRawCounts
            .filter { $0.value >= 2 }
            .keys
            .sorted { a, b in (ocrWeightedScores[a] ?? 0) > (ocrWeightedScores[b] ?? 0) }
            .prefix(8)
            .map { String($0) }

        var bursts = 0
        var inBurst = false
        for ev in windowed {
            if ev.activityIntensity >= 0.5 {
                if !inBurst { bursts += 1; inBurst = true }
            } else if ev.activityIntensity < 0.3 {
                inBurst = false
            }
        }

        let typingScore: Double = typingEventCount == 0 ? 0 : min(typingTotal / Double(typingEventCount), 1.0)
        let pointerScore: Double = pointerEventCount == 0 ? 0 : min(pointerTotal / Double(pointerEventCount), 1.0)
        let dropped = events.count - windowed.count

        let typeBreakdown = eventCountsByType
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        print("[WorkflowRetention] window=\(label) events_total=\(events.count) events_in=\(windowed.count) dropped=\(dropped) reason=outside_window_cutoff")
        print("[WorkflowRetention] window=\(label) types=[\(typeBreakdown)] title_transitions=\(titleTransitions) app_transitions=\(appTransitions)")

        return TemporalContextWindow(
            durationSeconds: seconds,
            eventCount: windowed.count,
            dominantApps: dominantApps,
            titleTransitions: titleTransitions,
            appTransitions: appTransitions,
            repeatedTerms: repeatedTerms,
            activityBursts: bursts,
            idleSeconds: idleAccumulated,
            typingScore: typingScore,
            pointerScore: pointerScore,
            recentTitles: Array(recentTitles.suffix(8)),
            transitions: Array(transitions.suffix(8)),
            termFirstSeen: termFirstSeen,
            termLastSeen: termLastSeen,
            titleFirstSeen: titleFirstSeen,
            titleLastSeen: titleLastSeen,
            eventCountsByType: eventCountsByType,
            droppedOutsideWindow: dropped,
            termWeightedScores: termWeightedScores,
            termRawCounts: termRawCounts,
            ocrEventTerms: ocrEventTerms,
            ocrEventTermScores: ocrWeightedScores,
            contextShift: shift
        )
    }
}
