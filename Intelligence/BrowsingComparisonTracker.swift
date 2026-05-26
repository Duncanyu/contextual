// BrowsingComparisonTracker.swift
// Detects when the user is rapidly switching between product-like browser tabs,
// building a comparison context that the planner can use.
//
// Aggregation window: 90 seconds, up to 8 distinct titles.
// When ≥2 distinct page titles appear within the window, the tracker returns a
// comparison hint string that is injected into the planner prompt.
//
// Logs:
//   [BrowsingComparison] recorded title=... distinct=N
//   [BrowsingComparison] comparison_detected pages=[A | B | ...]

import Foundation

actor BrowsingComparisonTracker {

    static let shared = BrowsingComparisonTracker()

    // MARK: - Configuration

    private let windowSeconds: TimeInterval = 90
    private let maxEntries = 8
    /// Minimum number of distinct pages to consider it a comparison session.
    private let minDistinctPages = 2

    // MARK: - State

    private struct TitleEntry {
        let title: String
        let at: Date
    }

    private var entries: [TitleEntry] = []

    // MARK: - Recording

    /// Record a new page title observed in a browsing workflow.
    /// Called whenever a title_changed event is detected for the browsing workflow.
    func record(title: String, at: Date = Date()) {
        let normalized = normalizeTitle(title)
        guard !normalized.isEmpty else { return }

        // Prune stale entries
        entries = entries.filter { at.timeIntervalSince($0.at) <= windowSeconds }

        // Skip consecutive-duplicate (title didn't actually change)
        if entries.last?.title == normalized { return }

        entries.append(TitleEntry(title: normalized, at: at))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        let distinct = Set(entries.map(\.title)).count
        print("[BrowsingComparison] recorded title=\(String(normalized.prefix(40))) distinct=\(distinct)")
    }

    // MARK: - Query

    /// Returns a compact comparison hint for the planner if ≥2 distinct pages are active,
    /// or nil when there's insufficient signal.
    func comparisonSummary(at referenceTime: Date = Date()) -> String? {
        let recent = entries.filter { referenceTime.timeIntervalSince($0.at) <= windowSeconds }
        var seen: [String] = []
        for entry in recent.reversed() {
            if !seen.contains(entry.title) { seen.append(entry.title) }
            if seen.count >= 4 { break }
        }
        guard seen.count >= minDistinctPages else { return nil }
        let listed = seen.reversed().prefix(4).joined(separator: " | ")
        let hint = "user_comparing=yes recent_pages=[\(listed)]"
        print("[BrowsingComparison] comparison_detected pages=[\(listed)]")
        return hint
    }

	/// Phase 4P: expose distinct recent titles as evidence candidates (metadata-only).
	func distinctRecentTitles(at referenceTime: Date = Date(), limit: Int = 4) -> [String] {
		let recent = entries.filter { referenceTime.timeIntervalSince($0.at) <= windowSeconds }
		var seen: [String] = []
		for entry in recent.reversed() {
			if !seen.contains(entry.title) { seen.append(entry.title) }
			if seen.count >= limit { break }
		}
		return seen.reversed()
	}

    // MARK: - Helpers

    private func normalizeTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip common " - Site Name" suffixes (≤4 words after the last dash/pipe)
        for separator in [" - ", " | ", " – ", " — "] {
            if let range = t.range(of: separator, options: .backwards) {
                let suffix = t[range.upperBound...]
                let wordCount = suffix.split(separator: " ").count
                if wordCount <= 4 {
                    t = String(t[..<range.lowerBound])
                    break
                }
            }
        }
        return String(t.prefix(80))
    }
}
