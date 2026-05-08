import Foundation

enum ContextFreshnessLabel: String, Hashable, Sendable, Codable, CaseIterable {
	case fresh
	case aging
	case stale
	case expired
}

/// Source identifiers for fusion freshness/decay policy.
/// Separate from `ContextCapabilityID` so we can express logical sources (e.g. AX text vs selected text).
enum FusedContextSource: String, Hashable, Sendable, Codable, CaseIterable {
	case selectedText
	case axText
	case screenOCR
	case clipboardText
	case activeWindowSnapshot
	case visualDescriptor
	case typingActivity
	case pointerActivity
	case activeApp
	case windowTitle
}

struct ContextFreshnessPolicy {
	// Thresholds (tunable, centralized)
	static let staleThreshold: Double = 0.30
	static let agingThreshold: Double = 0.70
	static let expiredMultiplier: Double = 1.25

	static func freshnessWindow(for source: FusedContextSource) -> TimeInterval {
		switch source {
		case .selectedText: return 20
		case .axText: return 20
		case .screenOCR: return 45
		case .clipboardText: return 60
		case .activeWindowSnapshot: return 20
		case .visualDescriptor: return 20
		case .typingActivity: return 6
		case .pointerActivity: return 6
		case .activeApp: return 30
		case .windowTitle: return 30
		}
	}

	static func freshnessScore(for source: FusedContextSource, capturedAt: Date, now: Date) -> Double {
		let window = freshnessWindow(for: source)
		let age = now.timeIntervalSince(capturedAt)
		if age <= 0 { return 1.0 }
		if age >= window * expiredMultiplier { return 0.0 }

		// Smooth-ish decay: start flat then roll off (quadratic ease-out).
		let t = max(0.0, min(1.0, age / window))
		let linear = 1.0 - t
		let eased = linear * linear
		return max(0.0, min(1.0, eased))
	}

	static func isStale(source: FusedContextSource, capturedAt: Date, now: Date) -> Bool {
		freshnessScore(for: source, capturedAt: capturedAt, now: now) < staleThreshold
	}

	static func isExpired(source: FusedContextSource, capturedAt: Date, now: Date) -> Bool {
		let window = freshnessWindow(for: source)
		return now.timeIntervalSince(capturedAt) >= window * expiredMultiplier
	}

	static func decayLabel(score: Double) -> ContextFreshnessLabel {
		if score <= 0.001 { return .expired }
		if score < staleThreshold { return .stale }
		if score < agingThreshold { return .aging }
		return .fresh
	}
}

