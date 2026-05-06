import Foundation

/// Keyed cooldown to avoid emitting the same class of signal repeatedly.
final class CooldownManager {
	private var lastFiredAt: [String: Date] = [:]

	/// Returns `true` if at least `interval` seconds have passed since the last successful acquire for `key`.
	func acquireIfEligible(key: String, interval: TimeInterval, now: Date = Date()) -> Bool {
		if let last = lastFiredAt[key], now.timeIntervalSince(last) < interval {
			return false
		}
		lastFiredAt[key] = now
		return true
	}

	func markFired(key: String, now: Date = Date()) {
		lastFiredAt[key] = now
	}

	func isCoolingDown(key: String, interval: TimeInterval, now: Date = Date()) -> Bool {
		if let last = lastFiredAt[key], now.timeIntervalSince(last) < interval {
			return true
		}
		return false
	}
}
