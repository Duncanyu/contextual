import Foundation

/// Infrastructure-only decision layer for future rich/expensive context collection.
/// - No new collection is triggered here.
/// - No permissions are requested here.
/// - Logs are metadata-only.
final class ContextBudgetManager {
	static let shared = ContextBudgetManager()

	private let lock = NSLock()

	/// Rolling timestamps for expensive collection events (in-memory only).
	private var expensiveCollectionTimestamps: [Date] = []

	/// Per-capability counts (in-memory only).
	private var collectionCounts: [ContextCapabilityID: Int] = [:]

	private init() {}

	func evaluate(_ request: ContextBudgetRequest) -> ContextBudgetDecision {
		let capMeta = ContextCapabilityRegistry.shared.capability(for: request.requestedCapability)

		if let capMeta, !capMeta.isAvailable {
			return logAndReturn(
				allowed: false,
				deferred: false,
				requestedCapability: request.requestedCapability,
				score: 0.0,
				reason: "capability_unavailable",
				retryAfter: nil
			)
		}

		if let capMeta, capMeta.permissionState == .denied || capMeta.permissionState == .unavailable {
			return logAndReturn(
				allowed: false,
				deferred: false,
				requestedCapability: request.requestedCapability,
				score: 0.0,
				reason: "permission_not_granted",
				retryAfter: nil
			)
		}

		let cost: ContextCollectionCost = capMeta?.collectionCost ?? .medium
		let privacy: ContextPrivacySensitivity = capMeta?.privacySensitivity ?? .moderate
		let isExpensive = (cost == .expensive)
		let isMediumOrExpensive = (cost == .medium || cost == .expensive)
		let isManualTrigger = Self.isManualTriggerSource(request.triggerSource)

		let hasMeaningfulSelectedText = request.hasSelectedText && request.selectedTextLength >= 30
		let hasMeaningfulClipboardText = request.hasClipboardText && request.clipboardTextLength >= 30
		let hasAnyStrongCheapSignal = hasMeaningfulSelectedText || hasMeaningfulClipboardText

		// MARK: Hard deny rules (conservative defaults)

		if request.isActionExecuting, isMediumOrExpensive {
			return logAndReturn(
				allowed: false,
				deferred: false,
				requestedCapability: request.requestedCapability,
				score: 0.0,
				reason: "action_executing",
				retryAfter: nil
			)
		}

		if privacy == .high, !isManualTrigger {
			let hasStrongReason = (request.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
			if !hasStrongReason {
				return logAndReturn(
					allowed: false,
					deferred: false,
					requestedCapability: request.requestedCapability,
					score: 0.0,
					reason: "privacy_high_requires_manual_or_reason",
					retryAfter: nil
				)
			}
		}

		if isExpensive, !isManualTrigger, request.recentExpensiveCollectionCount >= 3 {
			return logAndReturn(
				allowed: false,
				deferred: true,
				requestedCapability: request.requestedCapability,
				score: 0.0,
				reason: "recent_expensive_too_high",
				retryAfter: 20
			)
		}

		if isExpensive, !isManualTrigger {
			if hasAnyStrongCheapSignal {
				return logAndReturn(
					allowed: false,
					deferred: false,
					requestedCapability: request.requestedCapability,
					score: 0.0,
					reason: "enough_text_context",
					retryAfter: nil
				)
			}
			if request.hasRecentOCR {
				return logAndReturn(
					allowed: false,
					deferred: false,
					requestedCapability: request.requestedCapability,
					score: 0.0,
					reason: "recent_ocr_exists",
					retryAfter: nil
				)
			}
			if request.hasRecentWindowSnapshot {
				return logAndReturn(
					allowed: false,
					deferred: false,
					requestedCapability: request.requestedCapability,
					score: 0.0,
					reason: "recent_window_snapshot_exists",
					retryAfter: nil
				)
			}
		}

		// MARK: Scoring (not a rigid cooldown)

		var score: Double = 0.55
		var reasonParts: [String] = []

		reasonParts.append(isManualTrigger ? "manual" : "automatic")

		// Cost sensitivity: expensive requires stronger justification.
		switch cost {
		case .cheap:
			score += 0.10
			reasonParts.append("cost=cheap")
		case .medium:
			score += 0.00
			reasonParts.append("cost=medium")
		case .expensive:
			score -= isManualTrigger ? 0.02 : 0.12
			reasonParts.append("cost=expensive")
		}

		// Activity intensity: avoid expensive collection while user is active.
		switch request.userActivityLevel {
		case .idle:
			score += isExpensive ? 0.10 : 0.03
			reasonParts.append("activity=idle")
		case .light:
			score += isExpensive ? 0.05 : 0.01
			reasonParts.append("activity=light")
		case .active:
			score -= isExpensive ? 0.12 : 0.04
			reasonParts.append("activity=active")
		case .intense:
			score -= isExpensive ? 0.20 : 0.06
			reasonParts.append("activity=intense")
		}

		// Weak context: favor richer context when text channels are missing.
		if !request.hasSelectedText || request.selectedTextLength == 0 {
			score += 0.05
			reasonParts.append("no_selection")
		}
		if !request.hasClipboardText || request.clipboardTextLength == 0 {
			score += 0.04
			reasonParts.append("no_clipboard")
		}

		// Recent expensive usage (internal rolling window) reduces score.
		if isExpensive {
			let internalRecent = internalRecentExpensiveCount(now: Date(), windowSeconds: 120)
			if internalRecent > 0 {
				score -= min(0.20, Double(internalRecent) * 0.06)
				reasonParts.append("recent_expensive_internal=\(internalRecent)")
			}
		}

		// Intelligence confidence: lower confidence can justify richer context.
		if let c = request.currentIntelligenceConfidence {
			let clamped = max(0.0, min(1.0, c))
			if clamped < 0.45 {
				score += isExpensive ? 0.12 : 0.04
				reasonParts.append("confidence_low")
			} else if clamped > 0.80 {
				score -= isExpensive ? 0.06 : 0.02
				reasonParts.append("confidence_high")
			} else {
				reasonParts.append("confidence_mid")
			}
		} else {
			score += isExpensive ? 0.04 : 0.01
			reasonParts.append("confidence_unknown")
		}

		// Manual requests are generally preferred.
		if isManualTrigger {
			score += isExpensive ? 0.18 : 0.06
		}

		score = max(0.0, min(1.0, score))

		let allowed = score >= (isExpensive && !isManualTrigger ? 0.62 : 0.50)
		let shouldDefer = (!allowed && isExpensive && score >= 0.40) || (request.userActivityLevel == .intense && isExpensive)
		let retryAfter: TimeInterval? = shouldDefer ? 8 : nil

		let reason = reasonParts.joined(separator: "|")
		return logAndReturn(
			allowed: allowed,
			deferred: shouldDefer,
			requestedCapability: request.requestedCapability,
			score: score,
			reason: reason,
			retryAfter: retryAfter
		)
	}

	func recordCollection(_ capability: ContextCapabilityID) {
		lock.lock()
		defer { lock.unlock() }

		collectionCounts[capability, default: 0] += 1

		if let meta = ContextCapabilityRegistry.shared.capability(for: capability),
		   meta.collectionCost == .expensive
		{
			expensiveCollectionTimestamps.append(Date())
			pruneExpensiveLocked(now: Date(), windowSeconds: 10 * 60)
		}

		print("[ContextBudget] recorded capability=\(capability.rawValue)")
	}

	func reset() {
		lock.lock()
		expensiveCollectionTimestamps = []
		collectionCounts = [:]
		lock.unlock()
	}

	// MARK: - Private

	private func internalRecentExpensiveCount(now: Date, windowSeconds: TimeInterval) -> Int {
		lock.lock()
		defer { lock.unlock() }
		pruneExpensiveLocked(now: now, windowSeconds: windowSeconds)
		return expensiveCollectionTimestamps.count
	}

	private func pruneExpensiveLocked(now: Date, windowSeconds: TimeInterval) {
		let cutoff = now.addingTimeInterval(-windowSeconds)
		if expensiveCollectionTimestamps.isEmpty { return }
		expensiveCollectionTimestamps.removeAll { $0 < cutoff }
	}

	private static func isManualTriggerSource(_ triggerSource: String) -> Bool {
		let s = triggerSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if s.isEmpty { return false }
		if s.contains("manual") { return true }
		if s.contains("hotkey") { return true }
		if s.contains("shortcut") { return true }
		if s.contains("user") && s.contains("invoke") { return true }
		return false
	}

	private func logAndReturn(
		allowed: Bool,
		deferred: Bool,
		requestedCapability: ContextCapabilityID,
		score: Double,
		reason: String,
		retryAfter: TimeInterval?
	) -> ContextBudgetDecision {
		let s = String(format: "%.2f", score)
		if deferred {
			print("[ContextBudget] deferred capability=\(requestedCapability.rawValue) reason=\(reason) score=\(s)")
		} else {
			print("[ContextBudget] \(allowed ? "allowed" : "denied") capability=\(requestedCapability.rawValue) reason=\(reason) score=\(s)")
		}
		return ContextBudgetDecision(
			allowed: allowed,
			reason: reason,
			score: score,
			requestedCapability: requestedCapability,
			shouldDefer: deferred,
			suggestedRetryAfter: retryAfter
		)
	}
}

