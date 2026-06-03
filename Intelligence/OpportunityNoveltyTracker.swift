import Foundation

/// Phase 22.2 — Per-entity suggestion history for opportunity diversity (Task C).
///
/// Tracks which capabilities have been shown for each entity/compartment and
/// returns a novelty score (0.0 = shown moments ago, 1.0 = never shown or long ago).
///
/// The novelty multiplier is applied inside OpportunityReasoner so that a
/// recently-shown capability loses the slot to a genuinely different useful action.
///
/// Design:
///   - Thread-safe via internal DispatchQueue (callable from any isolation context).
///   - Ring buffer: max 12 entries per entity key, oldest pruned first.
///   - Full novelty restored after 15 minutes.
///   - No persistent storage: history resets on app relaunch (intentional).
///
/// Required logs: [OpportunityNovelty]
final class OpportunityNoveltyTracker {

    static let shared = OpportunityNoveltyTracker()

    // MARK: - Config

    let fullNoveltyAfterSeconds: TimeInterval = 900      // 15 min
    private let suppressionWindowSeconds: TimeInterval = 120  // 2 min
    private let maxHistoryPerKey = 12
    private let queue = DispatchQueue(label: "OpportunityNoveltyTracker", qos: .userInteractive)

    // MARK: - Storage

    private var _history: [String: [(String, Date)]] = [:]

    // MARK: - Public API (all thread-safe via queue)

    func markShown(capabilityId: String, entityKey: String, now: Date = Date()) {
        queue.async { [self] in
            var entries = _history[entityKey] ?? []
            entries.append((capabilityId, now))
            let cutoff = now.addingTimeInterval(-(fullNoveltyAfterSeconds * 2))
            entries = entries.filter { $0.1 >= cutoff }
            if entries.count > maxHistoryPerKey {
                entries = Array(entries.suffix(maxHistoryPerKey))
            }
            _history[entityKey] = entries
        }
    }

    func noveltyScore(capabilityId: String, entityKey: String, now: Date = Date()) -> Double {
        if capabilityId == "play_focus_media" {
            return musicNoveltyScore(entityKey: entityKey, now: now)
        }
        
        return queue.sync {
            guard let entries = _history[entityKey] else { return 1.0 }
            let shownTimes = entries.filter { $0.0 == capabilityId }.map(\.1)
            guard let lastShown = shownTimes.max() else { return 1.0 }
            let age = now.timeIntervalSince(lastShown)
            if age < suppressionWindowSeconds {
                return 0.05 + 0.15 * (age / suppressionWindowSeconds)
            }
            let decayRange = fullNoveltyAfterSeconds - suppressionWindowSeconds
            let progress = (age - suppressionWindowSeconds) / decayRange
            return min(1.0, 0.20 + 0.80 * progress)
        }
    }

    private func musicNoveltyScore(entityKey: String, now: Date) -> Double {
        let musicSuppressionWindowSeconds: TimeInterval = 600
        let musicNukeWindowSeconds: TimeInterval = 120
        
        let lastShown = queue.sync {
            _history[entityKey]?.filter { $0.0 == "play_focus_media" }.map(\.1).max()
        }
        guard let last = lastShown else { return 1.0 }

        let age = now.timeIntervalSince(last)
        let cooldown = max(0, musicSuppressionWindowSeconds - age)
        
        // Music is less aggressively suppressed. 
        // Merely shown (0-120s ago) drops to 0.4 instead of 0.05.
        // It recovers to 1.0 over 10 minutes.
        let score: Double
        if age < musicNukeWindowSeconds {
            score = 0.40 + 0.20 * (age / musicNukeWindowSeconds)
        } else if age < musicSuppressionWindowSeconds {
            score = 0.60 + 0.40 * ((age - musicNukeWindowSeconds) / (musicSuppressionWindowSeconds - musicNukeWindowSeconds))
        } else {
            score = 1.0
        }

        print("[MusicNovelty] shown_recently=\(age < musicSuppressionWindowSeconds ? "yes" : "no") cooldown_state=\(Int(cooldown))s novelty=\(String(format: "%.2f", score))")
        return score
    }

    func recentlyShown(entityKey: String,
                       windowSeconds: TimeInterval = 300,
                       now: Date = Date()) -> [String] {
        queue.sync {
            let cutoff = now.addingTimeInterval(-windowSeconds)
            return (_history[entityKey] ?? [])
                .filter  { $0.1 >= cutoff }
                .map(\.0)
        }
    }

    func seenCapabilities(entityKey: String, now: Date = Date()) -> Set<String> {
        queue.sync {
            let cutoff = now.addingTimeInterval(-fullNoveltyAfterSeconds)
            return Set((_history[entityKey] ?? []).filter { $0.1 >= cutoff }.map(\.0))
        }
    }

    // MARK: - Test helpers

    func reset() { queue.sync { [self] in _history = [:] } }
    func reset(entityKey: String) { queue.sync { [self] in _ = _history.removeValue(forKey: entityKey) } }
}
