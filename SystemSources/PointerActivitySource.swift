import AppKit
import Foundation

final class PointerActivitySource {
	static let shared = PointerActivitySource()

	private let lock = NSLock()

	private var globalMonitor: Any?
	private var localMonitor: Any?
	private var isMonitoring: Bool = false

	private enum PointerEventKind {
		case move
		case click
		case scrollOrDrag
	}

	private var sessionStartedAt: Date?
	private var lastEventAt: Date?

	private var recentMoveTimes: [Date] = []
	private var recentClickTimes: [Date] = []
	private var recentInteractTimes: [Date] = [] // scroll/drag treated as interaction

	private var lastLoggedState: PointerState?
	private var lastStateLogAt: Date?

	// Tuning windows (no polling; context computed lazily)
	private let recentWindowSeconds: TimeInterval = 2.0
	private let burstWindowSeconds: TimeInterval = 0.7
	private let stopAfterSeconds: TimeInterval = 2.6
	private let idleAfterSeconds: TimeInterval = 6.0

	private let maxRecentEventsStored: Int = 120

	private init() {}

	func startMonitoring() {
		lock.lock()
		defer { lock.unlock() }
		guard !isMonitoring else { return }
		isMonitoring = true

		let mask: NSEvent.EventTypeMask = [
			.mouseMoved,
			.leftMouseDown,
			.rightMouseDown,
			.otherMouseDown,
			.scrollWheel,
			.leftMouseDragged,
			.rightMouseDragged,
			.otherMouseDragged
		]

		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
			self?.recordEvent(event)
		}

		localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
			self?.recordEvent(event)
			return event
		}

		print("[PointerActivity] started_monitoring")
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

		print("[PointerActivity] stopped_monitoring")
	}

	func reset() {
		lock.lock()
		sessionStartedAt = nil
		lastEventAt = nil
		recentMoveTimes = []
		recentClickTimes = []
		recentInteractTimes = []
		lastLoggedState = nil
		lastStateLogAt = nil
		lock.unlock()
		print("[PointerActivity] reset")
	}

	func currentContext() -> PointerActivityContext {
		lock.lock()
		let now = Date()
		pruneLocked(now: now)

		let sessionStart = sessionStartedAt ?? now
		let last = lastEventAt

		let moveCount = recentMoveTimes.count
		let clickCount = recentClickTimes.count

		let idleDuration: TimeInterval
		if let last {
			idleDuration = max(0, now.timeIntervalSince(last))
		} else {
			idleDuration = now.timeIntervalSince(sessionStart)
		}

		let isActive = (last != nil) && (idleDuration <= recentWindowSeconds)

		let moveIntensity = burstIntensityLocked(now: now, times: recentMoveTimes)
		let clickIntensity = burstIntensityLocked(now: now, times: recentClickTimes)
		let state = computeStateLocked(now: now, idleDuration: idleDuration, moveCount: moveCount, clickCount: clickCount)

		let sessionDuration = now.timeIntervalSince(sessionStart)
		let focus = estimatedFocusIntensity(state: state, moveIntensity: moveIntensity, clickIntensity: clickIntensity, moveCount: moveCount, clickCount: clickCount)

		let (appName, bundleId) = frontmostAppMetadata()
		lock.unlock()

		maybeLogState(state: state, moveEvents: moveCount, clickEvents: clickCount, moveIntensity: moveIntensity, clickIntensity: clickIntensity)

		return PointerActivityContext(
			id: UUID(),
			updatedAt: now,
			appName: appName,
			bundleIdentifier: bundleId,
			isPointerActive: isActive,
			pointerState: state,
			recentMoveEventCount: moveCount,
			recentClickEventCount: clickCount,
			movementBurstIntensity: moveIntensity,
			clickBurstIntensity: clickIntensity,
			sessionDuration: sessionDuration,
			idleDuration: idleDuration,
			estimatedFocusIntensity: focus
		)
	}

	// MARK: - Private

	private func recordEvent(_ event: NSEvent) {
		let kind: PointerEventKind
		switch event.type {
		case .mouseMoved:
			kind = .move
		case .leftMouseDown, .rightMouseDown, .otherMouseDown:
			kind = .click
		case .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
			kind = .scrollOrDrag
		default:
			return
		}
		recordEventTimestamp(Date(), kind: kind)
	}

	private func recordEventTimestamp(_ now: Date, kind: PointerEventKind) {
		lock.lock()
		if sessionStartedAt == nil { sessionStartedAt = now }
		lastEventAt = now

		switch kind {
		case .move:
			recentMoveTimes.append(now)
			if recentMoveTimes.count > maxRecentEventsStored {
				recentMoveTimes.removeFirst(recentMoveTimes.count - maxRecentEventsStored)
			}
		case .click:
			recentClickTimes.append(now)
			if recentClickTimes.count > maxRecentEventsStored {
				recentClickTimes.removeFirst(recentClickTimes.count - maxRecentEventsStored)
			}
		case .scrollOrDrag:
			recentInteractTimes.append(now)
			if recentInteractTimes.count > maxRecentEventsStored {
				recentInteractTimes.removeFirst(recentInteractTimes.count - maxRecentEventsStored)
			}
		}
		lock.unlock()
	}

	private func pruneLocked(now: Date) {
		let cutoff = now.addingTimeInterval(-idleAfterSeconds)
		recentMoveTimes.removeAll { $0 < cutoff }
		recentClickTimes.removeAll { $0 < cutoff }
		recentInteractTimes.removeAll { $0 < cutoff }
	}

	private func burstIntensityLocked(now: Date, times: [Date]) -> PointerBurstIntensity {
		let cutoff = now.addingTimeInterval(-burstWindowSeconds)
		let count = times.filter { $0 >= cutoff }.count
		switch count {
		case 0:
			return .none
		case 1...4:
			return .low
		case 5...10:
			return .medium
		default:
			return .high
		}
	}

	private func computeStateLocked(now: Date, idleDuration: TimeInterval, moveCount: Int, clickCount: Int) -> PointerState {
		if lastEventAt == nil { return .idle }
		if idleDuration > idleAfterSeconds { return .idle }
		if idleDuration > stopAfterSeconds { return .stopped }

		let moveIntensity = burstIntensityLocked(now: now, times: recentMoveTimes)
		let clickIntensity = burstIntensityLocked(now: now, times: recentClickTimes)
		let interactCount = recentInteractTimes.count

		let bursty = (moveIntensity == .high || moveIntensity == .medium) || (clickIntensity == .high || clickIntensity == .medium)
		if bursty { return .burst }

		if clickCount > 0 && (moveCount > 0 || interactCount > 0) { return .interacting }
		if clickCount > 0 { return .clicking }
		if moveCount > 0 || interactCount > 0 { return .moving }
		return .moving // fallback for rare cases
	}

	private func estimatedFocusIntensity(
		state: PointerState,
		moveIntensity: PointerBurstIntensity,
		clickIntensity: PointerBurstIntensity,
		moveCount: Int,
		clickCount: Int
	) -> Double {
		var score: Double
		switch state {
		case .idle:
			score = 0.0
		case .stopped:
			score = 0.12
		case .moving:
			score = 0.45
		case .clicking:
			score = 0.55
		case .interacting:
			score = 0.70
		case .burst:
			score = 0.85
		}

		switch moveIntensity {
		case .none:
			break
		case .low:
			score += 0.03
		case .medium:
			score += 0.06
		case .high:
			score += 0.10
		}
		switch clickIntensity {
		case .none:
			break
		case .low:
			score += 0.03
		case .medium:
			score += 0.06
		case .high:
			score += 0.10
		}
		if moveCount >= 20 { score += 0.04 }
		if clickCount >= 6 { score += 0.04 }

		return max(0.0, min(1.0, score))
	}

	private func frontmostAppMetadata() -> (String?, String?) {
		guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
		return (app.localizedName, app.bundleIdentifier)
	}

	private func maybeLogState(
		state: PointerState,
		moveEvents: Int,
		clickEvents: Int,
		moveIntensity: PointerBurstIntensity,
		clickIntensity: PointerBurstIntensity
	) {
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
		print("[PointerActivity] state=\(state.rawValue) moveEvents=\(moveEvents) clickEvents=\(clickEvents) moveIntensity=\(moveIntensity.rawValue) clickIntensity=\(clickIntensity.rawValue)")
	}
}

extension PointerActivitySource {
	/// DEBUG-only synthetic injection for non-interactive self-test.
	/// Records timestamps/counts only; never stores coordinates.
	func recordSyntheticMoveEventForTesting() {
		recordEventTimestamp(Date(), kind: .move)
	}

	func recordSyntheticClickEventForTesting() {
		recordEventTimestamp(Date(), kind: .click)
	}

	func recordSyntheticScrollEventForTesting() {
		recordEventTimestamp(Date(), kind: .scrollOrDrag)
	}
}

