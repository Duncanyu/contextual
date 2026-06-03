import Foundation

// MARK: - FrictionType

/// Phase 26 — Types of detected user friction.
/// Each type maps to a pattern the user repeats that the assistant could eliminate.
enum FrictionType: String, Sendable, Codable, CaseIterable {
    case repeated_app_switching         // A→B→A→B within short window
    case repeated_tab_switching         // same tabs revisited repeatedly
    case repeated_reference_lookup      // same search terms or concepts re-searched
    case repeated_workspace_reconstruction  // same set of apps opened each session
    case repeated_copy_paste            // copy from one app, paste in another, repeat
    case repeated_window_restore        // user keeps reopening the same windows/documents
    case repeated_media_toggle          // play/pause cycling (focus music)
    case repeated_ai_assistant_usage    // user keeps invoking AI for similar queries
}

// MARK: - FrictionSignal

/// A detected friction event with confidence and supporting evidence.
struct FrictionSignal: Sendable {
    let type: FrictionType
    let confidence: Double          // 0..1
    let evidence: [String]          // human-readable evidence items
    let detectedAt: Date
    let involvedApps: [String]      // apps involved in the friction pattern
    let involvedURLs: [String]      // URLs involved (if browser-based)
}

// MARK: - ConceptSource

/// Where a concept observation originated — used to gate reference-lookup detection.
enum ConceptSource: String, Sendable {
    case editor_title       // Xcode, VS Code, etc. window titles / file names
    case browser_url        // browser page context
    case browser_search     // search engine query
    case docs_url           // documentation site
    case external_reference // other external source
    case unknown            // couldn't determine

    var isExternal: Bool {
        switch self {
        case .browser_url, .browser_search, .docs_url, .external_reference: return true
        case .editor_title, .unknown: return false
        }
    }
}

// MARK: - FrictionEngine

/// Phase 26 — Detects friction patterns from observed user behaviour.
///
/// The engine maintains a sliding window of recent app switches, tab visits,
/// and search terms. It detects oscillation patterns (A→B→A→B), repeated
/// lookups, and workspace reconstruction.
///
/// Thread-safe via internal DispatchQueue.
/// No persistent storage — patterns reset on app relaunch (intentional for v1).
///
/// Required logs: [FrictionEngine]
final class FrictionEngine {

    static let shared = FrictionEngine()

    // MARK: - Configuration

    private let oscillationWindowSeconds: TimeInterval = 120   // 2 min for A→B→A→B
    private let minOscillations = 2                             // need at least 2 full A→B cycles
    private let referenceWindowSeconds: TimeInterval = 300      // 5 min for repeated lookups
    private let minRepeatedConcepts = 3                         // concept seen 3+ times = friction
    private let workspaceCoOccurrenceThreshold = 3              // apps seen together 3+ sessions
    private let maxSwitchHistory = 60                           // ring buffer size for app switches

    private let queue = DispatchQueue(label: "FrictionEngine", qos: .userInitiated)

    // MARK: - State

    // App switch history: (appName, bundleID, timestamp)
    private var _appSwitches: [(app: String, bundle: String?, timestamp: Date)] = []

    // Concept search history: (concept, timestamp, source, sourceTitle)
    private var _conceptHistory: [(concept: String, timestamp: Date, source: ConceptSource, sourceTitle: String?)] = []

    // Tab visit history: (tabTitle, timestamp)
    private var _tabHistory: [(title: String, timestamp: Date)] = []
    private var _lastTabTitle: String?

    // MARK: - Public API

    /// Record an app switch event. Called from ContextEventProducer on activeAppChanged.
    func recordAppSwitch(appName: String, bundleID: String?, now: Date = Date()) {
        queue.async { [self] in
            _appSwitches.append((app: appName, bundle: bundleID, timestamp: now))
            // Prune old entries
            let cutoff = now.addingTimeInterval(-oscillationWindowSeconds * 3)
            _appSwitches = _appSwitches.filter { $0.timestamp >= cutoff }
            if _appSwitches.count > maxSwitchHistory {
                _appSwitches = Array(_appSwitches.suffix(maxSwitchHistory))
            }
        }
    }

    /// Record concepts observed this tick (from repeatedConcepts in working memory).
    func recordConcepts(_ concepts: [String], appName: String, bundleID: String?, windowTitle: String?, now: Date = Date()) {
        queue.async { [self] in
            let genericHostTokens: Set<String> = [
                "youtube", "google", "firefox", "new tab", "new", "tab", "gmail", "safari", "chrome",
                "editor", "viewer", "preview", "settings", "page", "site", "website", "tool",
                "home", "dashboard", "untitled", "loading", "welcome"
            ]
            let codingExtensions: Set<String> = ["swift", "py", "js", "java", "cpp", "h", "m", "ts", "go", "rs", "rb", "php", "cs", "kt", "swiftinterface"]
            let codingApps: Set<String> = ["xcode", "visual studio code", "cursor", "intellij", "pycharm", "sublime", "terminal"]
            let codingBundles: Set<String> = ["com.apple.dt.xcode", "com.microsoft.vscode", "com.todesktop.230313m78xv6l92", "com.jetbrains"]
            let browserApps: Set<String> = ["safari", "firefox", "google chrome", "chrome", "arc", "brave", "opera", "edge", "vivaldi"]
            let browserBundles: Set<String> = ["com.apple.safari", "org.mozilla.firefox", "com.google.chrome", "company.thebrowser.browser", "com.brave.browser", "com.microsoft.edgemac"]

            let isCodingApp = codingApps.contains(appName.lowercased())
                           || codingBundles.contains(where: { bundleID?.lowercased().contains($0) == true })
            let isBrowserApp = browserApps.contains(appName.lowercased())
                            || browserBundles.contains(where: { bundleID?.lowercased().contains($0) == true })

            let source: ConceptSource = isCodingApp ? .editor_title
                                      : isBrowserApp ? .browser_url
                                      : .unknown

            for c in concepts {
                let lowerConcept = c.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

                if genericHostTokens.contains(lowerConcept) || lowerConcept == "new tab" {
                    print("[FrictionEngine] suppressed reason=generic_host_token token=\(lowerConcept)")
                    continue
                }

                // Phase 27.2 — Fix 3: Suppress code file navigation and language names in coding context
                if isCodingApp {
                    // Suppress if the token IS a coding extension (e.g. "swift", "py")
                    if codingExtensions.contains(lowerConcept) {
                        print("[FrictionEngine] suppressed reason=coding_language_token_in_coding_context token=\(lowerConcept)")
                        continue
                    }

                    // In coding context, we are very skeptical of single-word tokens from filenames.
                    // Most filename-split tokens don't make good "reference lookup" signals.
                    // We only want to record if it's likely a real topic (4+ chars, not just a common word)
                    if lowerConcept.count < 4 {
                        print("[FrictionEngine] suppressed reason=short_token_in_coding_context token=\(lowerConcept)")
                        continue
                    }
                }

                // Suppress if it has a code extension (for tokens that weren't split)
                if codingExtensions.contains(where: { lowerConcept.hasSuffix(".\($0)") }) {
                    print("[FrictionEngine] suppressed reason=code_file_navigation_not_reference_lookup token=\(lowerConcept)")
                    continue
                }

                _conceptHistory.append((concept: lowerConcept, timestamp: now, source: source, sourceTitle: windowTitle))
            }
            let cutoff = now.addingTimeInterval(-referenceWindowSeconds * 2)
            _conceptHistory = _conceptHistory.filter { $0.timestamp >= cutoff }
        }
    }

    /// Record a browser tab visit.
    func recordTabVisit(title: String, now: Date = Date()) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async { [self] in
            guard _lastTabTitle != trimmed else { return }
            _lastTabTitle = trimmed
            _tabHistory.append((title: trimmed, timestamp: now))
            let cutoff = now.addingTimeInterval(-referenceWindowSeconds * 2)
            _tabHistory = _tabHistory.filter { $0.timestamp >= cutoff }
            if _tabHistory.count > maxSwitchHistory {
                _tabHistory = Array(_tabHistory.suffix(maxSwitchHistory))
            }
        }
    }

    /// Evaluate current state and return active friction signals.
    /// Called once per tick from ContextEventProducer / OpportunityEngine.
    func detectFriction(now: Date = Date()) -> [FrictionSignal] {
        queue.sync {
            var signals: [FrictionSignal] = []

            if let osc = detectOscillation(now: now) {
                signals.append(osc)
            }
            if let ref = detectRepeatedReferenceLookup(now: now) {
                signals.append(ref)
            }
            if let tab = detectRepeatedTabSwitching(now: now) {
                signals.append(tab)
            }

            for s in signals {
                print("[FrictionEngine] type=\(s.type.rawValue)"
                    + " confidence=\(String(format: "%.2f", s.confidence))"
                    + " evidence=[\(s.evidence.joined(separator: ","))]"
                    + " apps=[\(s.involvedApps.joined(separator: ","))]")
            }

            if signals.isEmpty {
                print("[FrictionEngine] no_friction_detected")
            }

            return signals
        }
    }

    // MARK: - Detection algorithms

    /// Detect A→B→A→B oscillation pattern in recent app switches.
    private func detectOscillation(now: Date) -> FrictionSignal? {
        let cutoff = now.addingTimeInterval(-oscillationWindowSeconds)
        let recent = _appSwitches.filter { $0.timestamp >= cutoff }
        guard recent.count >= 4 else { return nil }

        // Extract the app sequence
        let appSeq = recent.map { $0.app }

        // Count transitions: how many times do we see A→B→A?
        var oscillationPairs: [String: Int] = [:]  // "A|B" → count

        for i in 2..<appSeq.count {
            let a = appSeq[i - 2]
            let b = appSeq[i - 1]
            let c = appSeq[i]
            if a == c && a != b {
                let pairKey = [a, b].sorted().joined(separator: "|")
                oscillationPairs[pairKey, default: 0] += 1
            }
        }

        guard let (pairKey, count) = oscillationPairs.max(by: { $0.value < $1.value }),
              count >= minOscillations else { return nil }

        let apps = pairKey.components(separatedBy: "|")
        let confidence = min(0.95, 0.40 + Double(count) * 0.15)

        return FrictionSignal(
            type: .repeated_app_switching,
            confidence: confidence,
            evidence: ["oscillation \(apps.joined(separator: "↔")) x\(count) in \(Int(oscillationWindowSeconds))s"],
            detectedAt: now,
            involvedApps: apps,
            involvedURLs: []
        )
    }

    /// Detect the same concepts being searched/referenced repeatedly.
    /// Requires at least one concept from an external source (browser, docs, search).
    /// Editor-only concept repetition is normal code navigation, not reference lookup.
    /// Single-entity repetition (same app/site name over and over) is not reference lookup.
    private func detectRepeatedReferenceLookup(now: Date) -> FrictionSignal? {
        let cutoff = now.addingTimeInterval(-referenceWindowSeconds)
        let recent = _conceptHistory.filter { $0.timestamp >= cutoff }
        guard recent.count >= 3 else { return nil }

        // Gate: at least one concept must come from an external source
        let hasExternalSource = recent.contains { $0.source.isExternal }
        if !hasExternalSource {
            let editorCount = recent.filter { $0.source == .editor_title }.count
            if editorCount > 0 {
                print("[FrictionEngine] suppressed reason=editor_only_concepts_not_reference_lookup editor_concepts=\(editorCount)")
            }
            return nil
        }

        // Count concept frequency
        var freq: [String: Int] = [:]
        for entry in recent {
            freq[entry.concept, default: 0] += 1
        }

        let repeated = freq.filter { $0.value >= minRepeatedConcepts }
            .sorted { $0.value > $1.value }

        guard !repeated.isEmpty else { return nil }

        // Source-aware filtering: if all occurrences of the top repeated concepts
        // come from the same window title/source, it's not a reference lookup.
        let topToken = repeated[0].key
        let topEntries = recent.filter { $0.concept == topToken }
        let uniqueTitles = Set(topEntries.compactMap { $0.sourceTitle })

        if uniqueTitles.count <= 1 {
            let evidence = repeated.map { "\($0.key)x\($0.value)" }
            print("[FrictionEngine] suppressed reason=same_selected_title_repetition evidence=[\(evidence.joined(separator: ","))]")
            return nil
        }

        // Strip repeated concepts that are just the same entity/host/site name.
        // "piskelx8" or "youtubex8" is staying on one site, not doing reference lookup.
        // Also strip concepts where one is a substring of another (e.g., "piskel" + "new piskel").
        let independent = repeated.filter { entry in
            let k = entry.key
            if k == topToken { return false }
            if k.contains(topToken) || topToken.contains(k) { return false }
            return true
        }

        // If no independent concepts remain, check for editor→docs→editor pattern.
        // That pattern is the only valid single-concept reference lookup.
        if independent.isEmpty {
            let entries = recent.filter { $0.concept == topToken }
            let hasEditor = entries.contains { $0.source == ConceptSource.editor_title }
            let hasExternal = entries.contains { $0.source.isExternal }
            if hasEditor && hasExternal {
                // Genuine cross-app lookup for one concept (e.g., "urlsession" in Xcode + Safari)
                let topConcepts = repeated.prefix(3).map { "\($0.key)x\($0.value)" }
                let confidence = min(0.90, 0.35 + Double(repeated.first!.value) * 0.12)
                return FrictionSignal(
                    type: .repeated_reference_lookup,
                    confidence: confidence,
                    evidence: topConcepts,
                    detectedAt: now,
                    involvedApps: [],
                    involvedURLs: []
                )
            }
            let evidence = repeated.map { "\($0.key)x\($0.value)" }
            print("[FrictionEngine] suppressed reason=same_entity_repetition_not_reference_lookup evidence=[\(evidence.joined(separator: ","))]")
            return nil
        }

        // Phase 28.2 — Topical browsing exclusion.
        // Repeated topic words within the same browsing task are NOT reference lookup.
        // Reference lookup requires cross-category transitions (editor→browser, search→docs).
        // If ALL entries are browser-only and the source titles share a dominant theme,
        // this is same-topic browsing (e.g., rental listings, housing search pages).
        let hasEditorSource = recent.contains { $0.source == .editor_title }
        if !hasEditorSource {
            // All entries are browser/external only — check for topical coherence.
            // Extract terms from all source titles and see if repeated concepts ARE the title terms.
            let allSourceTitles = Set(recent.compactMap { $0.sourceTitle }).filter { !$0.isEmpty }
            if allSourceTitles.count >= 2 {
                let repeatedTermSet = Set(repeated.map { $0.key })
                let titleTerms = allSourceTitles.flatMap { title in
                    title.lowercased()
                        .components(separatedBy: CharacterSet.alphanumerics.inverted)
                        .filter { $0.count >= 3 }
                }
                let titleTermFreq = Dictionary(grouping: titleTerms, by: { $0 }).mapValues(\.count)
                // A term is "dominant" if it appears in most source titles
                let titleCount = allSourceTitles.count
                let dominantTerms = titleTermFreq.filter { Double($0.value) >= Double(titleCount) * 0.5 }.map(\.key)
                let dominantSet = Set(dominantTerms)
                // If all repeated concepts are also dominant title terms, this is topical browsing.
                // The same words appear because every page is about the same thing, not because
                // the user is doing reference lookups.
                let overlapCount = repeatedTermSet.intersection(dominantSet).count
                if overlapCount >= repeatedTermSet.count / 2 + 1 || (repeatedTermSet.count <= 3 && overlapCount >= repeatedTermSet.count) {
                    let evidence = repeated.map { "\($0.key)x\($0.value)" }
                    print("[FrictionEngine] suppressed reason=topical_browsing_not_reference_lookup dominant_terms=[\(dominantTerms.sorted().prefix(5).joined(separator: ","))] evidence=[\(evidence.joined(separator: ","))]")
                    return nil
                }
            }
        }

        // Multiple independent repeated concepts with cross-category evidence — genuine reference lookup.
        let topConcepts = repeated.prefix(3).map { "\($0.key)x\($0.value)" }
        let confidence = min(0.90, 0.35 + Double(repeated.first!.value) * 0.12)

        return FrictionSignal(
            type: .repeated_reference_lookup,
            confidence: confidence,
            evidence: topConcepts,
            detectedAt: now,
            involvedApps: [],
            involvedURLs: []
        )
    }

    /// Detect the same browser tabs being revisited repeatedly.
    private func detectRepeatedTabSwitching(now: Date) -> FrictionSignal? {
        let cutoff = now.addingTimeInterval(-referenceWindowSeconds)
        let recent = _tabHistory.filter { $0.timestamp >= cutoff }
        guard recent.count >= 4 else { return nil }

        let distinctTitles = Set(recent.map(\.title))
        guard distinctTitles.count >= 2 else { return nil }

        var transitionCount = 0
        for i in 1..<recent.count where recent[i].title != recent[i - 1].title {
            transitionCount += 1
        }
        guard transitionCount >= 3 else { return nil }

        var freq: [String: Int] = [:]
        for entry in recent {
            freq[entry.title, default: 0] += 1
        }

        let repeated = freq.filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }

        guard repeated.count >= 2 else { return nil }

        let topTabs = repeated.prefix(3).map { "\($0.key.prefix(30))x\($0.value)" }
        let confidence = min(0.85, 0.30 + Double(transitionCount) * 0.08)

        return FrictionSignal(
            type: .repeated_tab_switching,
            confidence: confidence,
            evidence: topTabs,
            detectedAt: now,
            involvedApps: [],
            involvedURLs: []
        )
    }

    // MARK: - Test helpers

    func reset() {
        queue.sync { [self] in
            _appSwitches = []
            _conceptHistory = []
            _tabHistory = []
            _lastTabTitle = nil
        }
    }
}
