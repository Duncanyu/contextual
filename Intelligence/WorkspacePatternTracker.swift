import Foundation

// MARK: - WorkspacePattern

/// Phase 26 — A learned pattern of apps/URLs/documents used together.
/// Built from observed co-occurrence, not hardcoded mappings.
struct WorkspacePattern: Sendable, Codable {
    let id: String                      // stable hash of sorted app set
    var apps: [String]                  // app names used together
    var bundleIDs: [String]             // corresponding bundle IDs (when known)
    var urls: [String]                  // URLs frequently visited in this workspace
    var tabTitles: [String]             // browser tab titles associated
    var frequency: Int                  // how many sessions this pattern appeared
    var lastUsed: Date                  // when the pattern was last active
    var avgDwellMinutes: Double         // average time spent in this workspace
    var dominantConcepts: [String]      // repeated terms associated with this workspace

    /// A short label derived from the app names (e.g. "TurboWarp + Gemini + Docs").
    var label: String {
        let shortApps = apps.prefix(3).map { app in
            // Trim common suffixes for readability
            app.replacingOccurrences(of: ".app", with: "")
        }
        return shortApps.joined(separator: " + ")
    }
}

// MARK: - WorkspacePatternTracker

/// Phase 26 — Learns workspace patterns from observed app co-occurrence.
///
/// Each tick, the tracker receives the set of apps that are currently relevant
/// (foreground app + apps in the current compartment). It groups these into
/// workspace patterns and tracks frequency.
///
/// No hardcoded app→workflow mapping. Patterns emerge from observation.
///
/// Thread-safe via DispatchQueue.
/// Required logs: [WorkspacePattern]
final class WorkspacePatternTracker {

    static let shared = WorkspacePatternTracker()

    private let queue = DispatchQueue(label: "WorkspacePatternTracker", qos: .utility)

    // MARK: - Configuration

    private let minAppsForPattern = 2            // need at least 2 apps to form a pattern
    private let maxPatterns = 20                 // max learned patterns
    private let patternDecayDays: TimeInterval = 7 * 86400  // patterns decay after 7 days

    // MARK: - State

    // Current session's observed co-occurring apps: compartment → Set<appName>
    private var _sessionApps: [String: Set<String>] = [:]   // compartmentID → apps
    private var _sessionBundles: [String: [String: String]] = [:]  // compartmentID → app→bundle
    private var _sessionURLs: [String: Set<String>] = [:]   // compartmentID → URLs
    private var _sessionConcepts: [String: [String]] = [:]  // compartmentID → concepts

    // Learned patterns (across sessions — currently in-memory, not persistent)
    private var _patterns: [String: WorkspacePattern] = [:]

    // MARK: - Public API

    /// Record that an app was observed in the given compartment.
    /// Phase 26.1 — Filters system apps (UserNotificationCenter, loginwindow, etc.)
    /// so they are never learned as workspace pattern members.
    func recordApp(appName: String, bundleID: String?, compartmentID: String, now: Date = Date()) {
        // Phase 26.1 — Skip system/background apps
        if WorkspaceAppFilter.isSystemApp(appName) {
            return
        }
        if let bid = bundleID, WorkspaceAppFilter.isSystemBundle(bid) {
            return
        }

        queue.async { [self] in
            var apps = _sessionApps[compartmentID] ?? []
            apps.insert(appName)
            _sessionApps[compartmentID] = apps

            if let bid = bundleID {
                var bundles = _sessionBundles[compartmentID] ?? [:]
                bundles[appName] = bid
                _sessionBundles[compartmentID] = bundles
            }
        }
    }

    /// Record a URL observed in the given compartment.
    func recordURL(_ url: String, compartmentID: String) {
        queue.async { [self] in
            var urls = _sessionURLs[compartmentID] ?? []
            urls.insert(url)
            _sessionURLs[compartmentID] = urls
        }
    }

    /// Record concepts observed in the given compartment.
    func recordConcepts(_ concepts: [String], compartmentID: String) {
        queue.async { [self] in
            var existing = _sessionConcepts[compartmentID] ?? []
            existing.append(contentsOf: concepts.map { $0.lowercased() })
            _sessionConcepts[compartmentID] = existing
        }
    }

    /// Consolidate this compartment's observations into a learned pattern.
    /// Called when a compartment has been stable for a while (e.g. dwell > 5 min).
    func consolidate(compartmentID: String, dwellMinutes: Double, now: Date = Date()) {
        queue.sync { [self] in
            guard let apps = _sessionApps[compartmentID], apps.count >= minAppsForPattern else {
                return
            }

            let sortedApps = apps.sorted()
            let patternID = sortedApps.joined(separator: "+").lowercased()

            let bundles = _sessionBundles[compartmentID] ?? [:]
            let urls = Array((_sessionURLs[compartmentID] ?? []).prefix(10))
            let concepts = topConcepts(_sessionConcepts[compartmentID] ?? [], limit: 5)

            if var existing = _patterns[patternID] {
                // Update existing pattern
                existing.frequency += 1
                existing.lastUsed = now
                existing.avgDwellMinutes = (existing.avgDwellMinutes * Double(existing.frequency - 1) + dwellMinutes) / Double(existing.frequency)
                // Merge URLs and concepts
                let mergedURLs = Set(existing.urls + urls)
                existing.urls = Array(mergedURLs.prefix(15))
                let mergedConcepts = Set(existing.dominantConcepts + concepts)
                existing.dominantConcepts = Array(mergedConcepts.prefix(8))
                _patterns[patternID] = existing

                print("[WorkspacePattern] updated pattern=\"\(existing.label)\""
                    + " frequency=\(existing.frequency)"
                    + " avg_dwell=\(String(format: "%.0f", existing.avgDwellMinutes))min")
            } else {
                // Create new pattern
                let bundleIDs = sortedApps.compactMap { bundles[$0] }
                let pattern = WorkspacePattern(
                    id: patternID,
                    apps: sortedApps,
                    bundleIDs: bundleIDs,
                    urls: urls,
                    tabTitles: [],
                    frequency: 1,
                    lastUsed: now,
                    avgDwellMinutes: dwellMinutes,
                    dominantConcepts: concepts
                )
                _patterns[patternID] = pattern

                print("[WorkspacePattern] learned pattern=\"\(pattern.label)\""
                    + " apps=[\(sortedApps.joined(separator: ","))]"
                    + " concepts=[\(concepts.joined(separator: ","))]")

                // Prune if too many patterns
                prunePatterns(now: now)
            }
        }
    }

    /// Return known workspace patterns, sorted by recency and frequency.
    func knownPatterns(now: Date = Date()) -> [WorkspacePattern] {
        queue.sync {
            let cutoff = now.addingTimeInterval(-patternDecayDays)
            return _patterns.values
                .filter { $0.lastUsed >= cutoff }
                .sorted {
                    // Score by frequency × recency
                    let aAge = now.timeIntervalSince($0.lastUsed) / 3600
                    let bAge = now.timeIntervalSince($1.lastUsed) / 3600
                    let aScore = Double($0.frequency) / (1 + aAge * 0.1)
                    let bScore = Double($1.frequency) / (1 + bAge * 0.1)
                    return aScore > bScore
                }
        }
    }

    /// Find the best matching pattern for the current set of active apps.
    func matchPattern(activeApps: Set<String>, now: Date = Date()) -> WorkspacePattern? {
        queue.sync {
            let cutoff = now.addingTimeInterval(-patternDecayDays)
            let lower = Set(activeApps.map { $0.lowercased() })

            return _patterns.values
                .filter { $0.lastUsed >= cutoff }
                .filter { pattern in
                    let patternLower = Set(pattern.apps.map { $0.lowercased() })
                    // At least half the pattern's apps are currently active
                    let overlap = patternLower.intersection(lower)
                    return overlap.count >= max(1, patternLower.count / 2)
                }
                .max(by: { $0.frequency < $1.frequency })
        }
    }

    /// Return apps from a known pattern that are NOT currently running.
    func missingApps(from pattern: WorkspacePattern, currentApps: Set<String>) -> [String] {
        let currentLower = Set(currentApps.map { $0.lowercased() })
        return pattern.apps.filter { !currentLower.contains($0.lowercased()) }
    }

    // MARK: - Helpers

    private func topConcepts(_ all: [String], limit: Int) -> [String] {
        var freq: [String: Int] = [:]
        for c in all { freq[c, default: 0] += 1 }
        return freq.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    private func prunePatterns(now: Date) {
        let cutoff = now.addingTimeInterval(-patternDecayDays)
        _patterns = _patterns.filter { $0.value.lastUsed >= cutoff }
        if _patterns.count > maxPatterns {
            // Keep most frequent
            let sorted = _patterns.sorted { $0.value.frequency > $1.value.frequency }
            _patterns = Dictionary(uniqueKeysWithValues: sorted.prefix(maxPatterns).map { ($0.key, $0.value) })
        }
    }

    // MARK: - Test helpers

    func reset() {
        queue.sync { [self] in
            _sessionApps = [:]
            _sessionBundles = [:]
            _sessionURLs = [:]
            _sessionConcepts = [:]
            _patterns = [:]
        }
    }

    func patternCount() -> Int {
        queue.sync { _patterns.count }
    }
}
