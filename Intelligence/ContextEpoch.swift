import Foundation

/// Phase 20G — represents a coherent run of related context. When the
/// `TemporalContextBuffer.medium.contextShift` flags a topic-distribution
/// shift, we close the current epoch and open a new one. WorkingMemoryBuilder
/// queries the tracker to drop entities that belong to a deprecated epoch.
public struct ContextEpoch: Sendable, Codable, Equatable {
    public let id: String
    public let startedAt: Date
    public let terms: [String]
    public let titles: [String]

    public init(id: String, startedAt: Date, terms: [String], titles: [String]) {
        self.id = id
        self.startedAt = startedAt
        self.terms = terms
        self.titles = titles
    }
}

/// Thread-safe singleton tracker. Synchronous so WorkingMemoryBuilder can stay
/// a pure static func without becoming async.
public final class ContextEpochTracker: @unchecked Sendable {

    public static let shared = ContextEpochTracker()

    private let lock = NSLock()
    private var _currentEpoch: ContextEpoch
    private var _previousEpoch: ContextEpoch?

    private init() {
        _currentEpoch = ContextEpoch(
            id: UUID().uuidString,
            startedAt: Date(),
            terms: [],
            titles: []
        )
    }

    // MARK: - Public API

    /// Observe a fresh medium-window snapshot. When the shift flag is set and
    /// the recent term set is non-empty, the current epoch is rolled and a
    /// new one is opened. Otherwise the current epoch absorbs the new terms.
    public func observe(
        contextShiftDetected: Bool,
        shiftReason: String = "topic_shift",
        earlyTopTerms: [String],
        recentTopTerms: [String],
        recentTitles: [String],
        at now: Date = Date()
    ) {
        lock.lock(); defer { lock.unlock() }

        if contextShiftDetected && !recentTopTerms.isEmpty {
            // When starting a new epoch, keep only titles that overlap the new
            // term distribution. This prevents "old epoch" titles (e.g. Anker
            // products) from being treated as part of the new epoch when the
            // user has shifted to a new topic (e.g. CISC/onQ course pages).
            let termTokenSet = Set(recentTopTerms.map { $0.lowercased() })
            let filteredTitles: [String] = {
                let kept = recentTitles.filter { title in
                    !Self.tokenize(title).intersection(termTokenSet).isEmpty
                }
                if !kept.isEmpty { return kept }
                // Fallback: keep the most recent titles so the epoch isn't empty.
                return Array(recentTitles.prefix(4))
            }()

            // Roll: archive previous, start new.
            _previousEpoch = _currentEpoch
            let newEpoch = ContextEpoch(
                id: UUID().uuidString,
                startedAt: now,
                terms: recentTopTerms,
                titles: filteredTitles
            )
            _currentEpoch = newEpoch

            print("[ContextEpoch] started id=\(newEpoch.id.prefix(8)) reason=\(shiftReason)")
            print("[ContextEpoch] old_terms=\(earlyTopTerms.prefix(5).joined(separator: ","))")
            print("[ContextEpoch] new_terms=\(recentTopTerms.prefix(5).joined(separator: ","))")
            print("[ContextEpoch] deprecated_previous=yes")
            return
        }

        // Same epoch — accumulate.
        let mergedTerms = Self.merged(_currentEpoch.terms, with: recentTopTerms, cap: 32)
        let mergedTitles = Self.merged(_currentEpoch.titles, with: recentTitles, cap: 16)
        _currentEpoch = ContextEpoch(
            id: _currentEpoch.id,
            startedAt: _currentEpoch.startedAt,
            terms: mergedTerms,
            titles: mergedTitles
        )
    }

    /// True when none of the title's tokens overlap with the current epoch's
    /// term set (and the title isn't already part of the epoch's title set).
    /// WorkingMemoryBuilder uses this to filter out previous-epoch entities.
    public func isStale(title: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // No epoch terms yet → nothing is stale.
        guard !_currentEpoch.terms.isEmpty || !_currentEpoch.titles.isEmpty else { return false }
        if _currentEpoch.titles.contains(title) { return false }
        let tokens = Self.tokenize(title)
        if tokens.isEmpty { return false }
        let epochTokenSet = Set(_currentEpoch.terms.map { $0.lowercased() })
            .union(Set(_currentEpoch.titles.flatMap { Self.tokenize($0) }))
        return tokens.intersection(epochTokenSet).isEmpty
    }

    public func currentEpoch() -> ContextEpoch {
        lock.lock(); defer { lock.unlock() }
        return _currentEpoch
    }

    public func previousEpoch() -> ContextEpoch? {
        lock.lock(); defer { lock.unlock() }
        return _previousEpoch
    }

    /// Reset state. Test-only.
    public func resetForTests() {
        lock.lock(); defer { lock.unlock() }
        _currentEpoch = ContextEpoch(
            id: UUID().uuidString, startedAt: Date(), terms: [], titles: []
        )
        _previousEpoch = nil
    }

    // MARK: - Helpers

    private static func tokenize(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }

    private static func merged(_ a: [String], with b: [String], cap: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in a + b {
            if seen.insert(term).inserted {
                out.append(term)
                if out.count >= cap { break }
            }
        }
        return out
    }
}
