import Foundation

/// Phase 20G.2 — short-lived "what the user is focused on right now" epoch.
///
/// Distinct from `ContextEpoch` (broad topic/workflow cluster). A FocusEpoch
/// updates whenever the selected browser tab changes meaningfully. It is used
/// to:
/// - prioritize the current entity in WorkingMemory
/// - detect intra-workflow focus shifts (product A → product B)
/// - invalidate stale visible suggestions
public struct FocusEpoch: Sendable, Equatable {
	public let id: String
	public let startedAt: Date
	public let entityTitle: String
	public let terms: [String]
}

public final class FocusEpochTracker: @unchecked Sendable {
	public static let shared = FocusEpochTracker()

	private let lock = NSLock()
	private var _current: FocusEpoch?
	private var _previous: FocusEpoch?

	private init() {}

	public struct Observation: Sendable, Equatable {
		public let focusChanged: Bool
		public let focusShiftDetected: Bool
		public let previousEntity: String?
		public let currentEntity: String
		public let selectedAgeSeconds: Int
		public let selectedTerms: [String]
	}

	public func observeSelectedTab(
		title: String,
		workflowLabel: String,
		at now: Date = Date()
	) -> Observation {
		let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
		let terms = Array(Self.tokenize(cleanedTitle).prefix(6))

		lock.lock(); defer { lock.unlock() }

		let prev = _current
		let focusChanged = prev?.entityTitle != cleanedTitle && !cleanedTitle.isEmpty
		let previousEntity = prev?.entityTitle
		let age: Int = {
			guard let cur = _current else { return 0 }
			return Int(max(0, now.timeIntervalSince(cur.startedAt)))
		}()

		var focusShiftDetected = false
		if focusChanged, let prev {
			let prevTerms = Set(prev.terms)
			let curTerms = Set(terms)
			let inter = prevTerms.intersection(curTerms).count
			let union = prevTerms.union(curTerms).count
			let jaccard: Double = union > 0 ? Double(inter) / Double(union) : 1.0
			focusShiftDetected = jaccard < 0.25 && !prevTerms.isEmpty && !curTerms.isEmpty
		}

		if focusChanged {
			_previous = _current
			let epoch = FocusEpoch(
				id: UUID().uuidString,
				startedAt: now,
				entityTitle: cleanedTitle,
				terms: terms
			)
			_current = epoch
			print("[FocusEpoch] started id=\(epoch.id.prefix(8)) reason=selected_tab_changed")
			print("[FocusEpoch] current_entity=\"\(cleanedTitle.prefix(120))\"")
			if let previousEntity {
				print("[FocusEpoch] previous_entity=\"\(previousEntity.prefix(120))\"")
			}
			print("[FocusEpoch] workflow_unchanged=yes")
			if focusShiftDetected, let prev {
				print("[FocusShift] detected=yes reason=selected_tab_low_overlap")
				print("[FocusShift] previous_terms=\(prev.terms.prefix(4).joined(separator: ","))")
				print("[FocusShift] current_terms=\(terms.prefix(4).joined(separator: ","))")
			}
		}

		let selectedAge: Int = {
			guard let cur = _current else { return 0 }
			return Int(max(0, now.timeIntervalSince(cur.startedAt)))
		}()

		return Observation(
			focusChanged: focusChanged,
			focusShiftDetected: focusShiftDetected,
			previousEntity: previousEntity,
			currentEntity: cleanedTitle.isEmpty ? (prev?.entityTitle ?? "") : cleanedTitle,
			selectedAgeSeconds: selectedAge,
			selectedTerms: terms
		)
	}

	public func resetForTests() {
		lock.lock(); defer { lock.unlock() }
		_current = nil
		_previous = nil
	}

	private static func tokenize(_ s: String) -> [String] {
		let stop: Set<String> = ["the", "and", "for", "with", "from", "home", "page", "tab"]
		var out: [String] = []
		var seen = Set<String>()
		for w in s.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.filter({ $0.count >= 3 && $0.count <= 20 }) {
			if stop.contains(w) { continue }
			if seen.insert(w).inserted { out.append(w) }
			if out.count >= 8 { break }
		}
		return out
	}
}

