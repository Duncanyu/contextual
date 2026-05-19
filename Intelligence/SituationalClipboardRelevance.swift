import Foundation

/// Clipboard relevance for situational primary-source selection (T18.3.3B).
enum SituationalClipboardRelevance: String, Hashable, Sendable, Codable {
	case high
	case medium
	case low
	case unknown
}

struct SituationalClipboardRelevanceAssessment: Equatable, Sendable {
	let relevance: SituationalClipboardRelevance
	let suppressed: Bool
	let reasonCode: String
	let canBePrimary: Bool
	let appWindowChangedSinceClipboard: Bool
	let ageBucket: String
}

enum SituationalClipboardRelevanceEvaluator {

	static func assess(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		appCategory: SituationalAppCategory,
		referenceTime: Date = Date()
	) -> SituationalClipboardRelevanceAssessment {
		let text = snapshot.clipboardText ?? ""
		let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
		guard count > 0 else {
			return SituationalClipboardRelevanceAssessment(
				relevance: .unknown,
				suppressed: true,
				reasonCode: "no_clipboard",
				canBePrimary: false,
				appWindowChangedSinceClipboard: false,
				ageBucket: "none"
			)
		}

		let clipboardAt = snapshot.sourceMetadata.clipboardCapturedAt
			?? snapshot.sourceMetadata.contextUpdatedAt
			?? snapshot.generatedAt
		let contextAt = snapshot.sourceMetadata.contextUpdatedAt ?? snapshot.generatedAt
		let ageBucket = clipboardAgeBucket(capturedAt: clipboardAt, referenceTime: referenceTime)
		let appWindowChanged = appWindowChangedSinceClipboard(
			snapshot: snapshot,
			clipboardAt: clipboardAt,
			contextAt: contextAt
		)

		let basePolicy = GeneratedExecutionClipboardFreshnessPolicy.evaluate(
			snapshot: snapshot,
			referenceTime: referenceTime
		)
		if !basePolicy.includeClipboard {
			return SituationalClipboardRelevanceAssessment(
				relevance: .low,
				suppressed: true,
				reasonCode: basePolicy.reasonCode ?? "policy_suppressed",
				canBePrimary: false,
				appWindowChangedSinceClipboard: appWindowChanged,
				ageBucket: ageBucket
			)
		}

		let hasSelection = !(snapshot.selectedText ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.isEmpty
		let hasTitle = !snapshot.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		let noFused = snapshot.fusedPacketId == nil
		let lengthBucket = SituationalSignalMetrics.lengthBucket(for: count)

		if lengthBucket == .huge {
			return suppressed(
				relevance: .low,
				reason: "huge_clipboard_unrelated",
				appWindowChanged: appWindowChanged,
				ageBucket: ageBucket
			)
		}

		if appWindowChanged {
			return suppressed(
				relevance: .low,
				reason: "app_window_changed_since_clipboard",
				appWindowChanged: true,
				ageBucket: ageBucket
			)
		}

		if noFused, hasTitle, !hasSelection {
			if appCategory == .browser {
				return suppressed(
					relevance: .low,
					reason: "browser_metadata_only",
					appWindowChanged: appWindowChanged,
					ageBucket: ageBucket
				)
			}
			if appCategory == .ide {
				return suppressed(
					relevance: .low,
					reason: "ide_metadata_only",
					appWindowChanged: appWindowChanged,
					ageBucket: ageBucket
				)
			}
			return suppressed(
				relevance: .low,
				reason: "metadata_only_no_fused",
				appWindowChanged: appWindowChanged,
				ageBucket: ageBucket
			)
		}

		if snapshot.sourceMetadata.lastSourceTrigger == LastSourceTrigger.windowTitleChanged.rawValue
			|| snapshot.sourceMetadata.lastSourceTrigger == LastSourceTrigger.activeAppChanged.rawValue
		{
			return suppressed(
				relevance: .low,
				reason: "context_trigger_not_clipboard",
				appWindowChanged: appWindowChanged,
				ageBucket: ageBucket
			)
		}

		let freshness = SituationalSignalMetrics.freshnessLevel(
			capturedAt: clipboardAt,
			source: .clipboardText,
			referenceTime: referenceTime
		)
		if freshness == .stale {
			return suppressed(
				relevance: .low,
				reason: "clipboard_stale",
				appWindowChanged: appWindowChanged,
				ageBucket: ageBucket
			)
		}

		let clipboardTrigger = snapshot.sourceMetadata.lastSourceTrigger == LastSourceTrigger.clipboardTextChanged.rawValue
		if clipboardTrigger, freshness == .fresh, lengthBucket != .huge, count >= 40 {
			return SituationalClipboardRelevanceAssessment(
				relevance: .high,
				suppressed: false,
				reasonCode: "fresh_clipboard_same_context",
				canBePrimary: true,
				appWindowChangedSinceClipboard: false,
				ageBucket: ageBucket
			)
		}

		if freshness == .fresh, !noFused, count >= 40, lengthBucket != .huge {
			return SituationalClipboardRelevanceAssessment(
				relevance: .medium,
				suppressed: false,
				reasonCode: "clipboard_secondary_fused",
				canBePrimary: false,
				appWindowChangedSinceClipboard: appWindowChanged,
				ageBucket: ageBucket
			)
		}

		return suppressed(
			relevance: .low,
			reason: "clipboard_relevance_unproven",
			appWindowChanged: appWindowChanged,
			ageBucket: ageBucket
		)
	}

	private static func suppressed(
		relevance: SituationalClipboardRelevance,
		reason: String,
		appWindowChanged: Bool,
		ageBucket: String
	) -> SituationalClipboardRelevanceAssessment {
		SituationalClipboardRelevanceAssessment(
			relevance: relevance,
			suppressed: true,
			reasonCode: reason,
			canBePrimary: false,
			appWindowChangedSinceClipboard: appWindowChanged,
			ageBucket: ageBucket
		)
	}

	private static func clipboardAgeBucket(capturedAt: Date, referenceTime: Date) -> String {
		let age = referenceTime.timeIntervalSince(capturedAt)
		switch age {
		case ..<15: return "fresh"
		case ..<60: return "recent"
		case ..<180: return "aging"
		default: return "old"
		}
	}

	private static func appWindowChangedSinceClipboard(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		clipboardAt: Date,
		contextAt: Date
	) -> Bool {
		let trigger = snapshot.sourceMetadata.lastSourceTrigger
		if trigger == LastSourceTrigger.activeAppChanged.rawValue
			|| trigger == LastSourceTrigger.windowTitleChanged.rawValue
		{
			return contextAt.timeIntervalSince(clipboardAt) > 1.5
		}
		return contextAt.timeIntervalSince(clipboardAt) > 45
	}
}
