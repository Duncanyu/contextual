import AppKit
import Foundation

final class TypingActivitySource {
	static let shared = TypingActivitySource()

	private let lock = NSLock()

	private var globalMonitor: Any?
	private var localMonitor: Any?

	private var isMonitoring: Bool = false

	// Metadata-only timestamps/counters (no key values stored).
	private var sessionStartedAt: Date?
	private var lastEventAt: Date?
	private var recentEventTimes: [Date] = []

	// Log throttling (state changes only).
	private var lastLoggedState: TypingState?
	private var lastStateLogAt: Date?

	// Tuning
	private let recentWindowSeconds: TimeInterval = 2.0
	private let burstWindowSeconds: TimeInterval = 0.8
	private let stopAfterSeconds: TimeInterval = 2.5
	private let idleAfterSeconds: TimeInterval = 6.0
	private let maxRecentEventsStored: Int = 80

	private init() {}

	func startMonitoring() {
		lock.lock()
		defer { lock.unlock() }
		guard !isMonitoring else { return }
		isMonitoring = true

		// Global monitor captures keyDown outside this app when permitted by macOS privacy settings.
		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
			self?.recordEventIfQualifies(event: event, source: "global")
		}

		// Local monitor captures keyDown when this app is frontmost.
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
			self?.recordEventIfQualifies(event: event, source: "local")
			return event
		}

		print("[TypingActivity] started_monitoring")
		ContextDebugLogger.shared.log(stage: .typing, event: .updated, source: "typingActivity", reason: "started_monitoring")
	}

	func stopMonitoring() {
		lock.lock()
		defer { lock.unlock() }
		guard isMonitoring else { return }
		isMonitoring = false

		if let globalMonitor {
			NSEvent.removeMonitor(globalMonitor)
			self.globalMonitor = nil
		}
		if let localMonitor {
			NSEvent.removeMonitor(localMonitor)
			self.localMonitor = nil
		}

		print("[TypingActivity] stopped_monitoring")
		ContextDebugLogger.shared.log(stage: .typing, event: .updated, source: "typingActivity", reason: "stopped_monitoring")
	}

	func reset() {
		lock.lock()
		sessionStartedAt = nil
		lastEventAt = nil
		recentEventTimes = []
		lastLoggedState = nil
		lastStateLogAt = nil
		lock.unlock()
		print("[TypingActivity] reset")
		ContextDebugLogger.shared.log(stage: .typing, event: .updated, source: "typingActivity", reason: "reset")
	}

	func currentContext() -> TypingActivityContext {
		lock.lock()
		let now = Date()
		pruneLocked(now: now)

		let sessionStart = sessionStartedAt ?? now
		let last = lastEventAt
		let recentCount = recentEventTimes.count

		let idleDuration: TimeInterval
		if let last {
			idleDuration = max(0, now.timeIntervalSince(last))
		} else {
			idleDuration = now.timeIntervalSince(sessionStart)
		}

		let isActive = (last != nil) && (idleDuration <= recentWindowSeconds)
		let state = computeStateLocked(now: now, last: last, recentCount: recentCount, idleDuration: idleDuration)
		let intensity = computeIntensityLocked(now: now)

		let sessionDuration = now.timeIntervalSince(sessionStart)
		let activity = estimatedEditingActivity(state: state, intensity: intensity, recentCount: recentCount)

		let (appName, bundleId) = frontmostAppMetadata()
		lock.unlock()

		maybeLogState(state: state, intensity: intensity, events: recentCount)

		return TypingActivityContext(
			id: UUID(),
			updatedAt: now,
			appName: appName,
			bundleIdentifier: bundleId,
			isTypingActive: isActive,
			typingState: state,
			recentEventCount: recentCount,
			burstIntensity: intensity,
			sessionDuration: sessionDuration,
			idleDuration: idleDuration,
			estimatedEditingActivity: activity
		)
	}

	// MARK: - Private

	private func recordEventIfQualifies(event: NSEvent, source: String) {
		// Only keyDown events arrive, but keep guard.
		if event.type != .keyDown { return }

		// Avoid logging or storing any key values or codes.
		// Filter: ignore pure modifier-only events (typically delivered as flagsChanged, not keyDown).
		// Keep this conservative—do not inspect characters.

		recordEventTimestamp(Date())
		_ = source // explicitly unused; do not log it (avoid noise)
	}

	private func recordEventTimestamp(_ now: Date) {
		lock.lock()
		if sessionStartedAt == nil { sessionStartedAt = now }
		lastEventAt = now
		recentEventTimes.append(now)
		if recentEventTimes.count > maxRecentEventsStored {
			recentEventTimes.removeFirst(recentEventTimes.count - maxRecentEventsStored)
		}
		lock.unlock()
	}

	private func pruneLocked(now: Date) {
		let cutoff = now.addingTimeInterval(-idleAfterSeconds)
		if recentEventTimes.isEmpty { return }
		recentEventTimes.removeAll { $0 < cutoff }
	}

	private func computeIntensityLocked(now: Date) -> TypingBurstIntensity {
		let cutoff = now.addingTimeInterval(-burstWindowSeconds)
		let burstCount = recentEventTimes.filter { $0 >= cutoff }.count
		switch burstCount {
		case 0:
			return .none
		case 1...3:
			return .low
		case 4...8:
			return .medium
		default:
			return .high
		}
	}

	private func computeStateLocked(now: Date, last: Date?, recentCount: Int, idleDuration: TimeInterval) -> TypingState {
		guard let last else { return .idle }

		if idleDuration > idleAfterSeconds { return .idle }
		if idleDuration > stopAfterSeconds { return .stopped }

		let intensity = computeIntensityLocked(now: now)
		if intensity == .high || intensity == .medium {
			return .burst
		}

		// "started" when we just entered activity.
		if recentCount == 1 && idleDuration <= 0.35 {
			return .started
		}
		return .active
	}

	private func estimatedEditingActivity(state: TypingState, intensity: TypingBurstIntensity, recentCount: Int) -> Double {
		var score: Double = 0.0
		switch state {
		case .idle:
			score = 0.0
		case .stopped:
			score = 0.15
		case .started:
			score = 0.45
		case .active:
			score = 0.55
		case .burst:
			score = 0.80
		}
		switch intensity {
		case .none:
			score += 0.0
		case .low:
			score += 0.05
		case .medium:
			score += 0.10
		case .high:
			score += 0.15
		}
		if recentCount >= 10 { score += 0.05 }
		return max(0.0, min(1.0, score))
	}

	private func frontmostAppMetadata() -> (String?, String?) {
		guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
		return (app.localizedName, app.bundleIdentifier)
	}

	private func maybeLogState(state: TypingState, intensity: TypingBurstIntensity, events: Int) {
		let now = Date()
		lock.lock()
		let prev = lastLoggedState
		let lastAt = lastStateLogAt
		let shouldLog: Bool
		if prev != state {
			shouldLog = true
		} else if let lastAt, now.timeIntervalSince(lastAt) < 2.0 {
			shouldLog = false
		} else {
			shouldLog = false
		}
		if shouldLog {
			lastLoggedState = state
			lastStateLogAt = now
		}
		lock.unlock()

		guard shouldLog else { return }
		print("[TypingActivity] state=\(state.rawValue) intensity=\(intensity.rawValue) events=\(events)")
		ContextDebugLogger.shared.log(
			stage: .typing,
			event: .updated,
			source: "typingActivity",
			meta: ["state": state.rawValue, "intensity": intensity.rawValue, "events": "\(events)"]
		)
	}
}

extension TypingActivitySource {
	/// DEBUG-only synthetic injection for non-interactive self-test.
	/// Records timestamps/counts only; never stores key values.
	func recordSyntheticKeyEventForTesting() {
		recordEventTimestamp(Date())
	}
}

