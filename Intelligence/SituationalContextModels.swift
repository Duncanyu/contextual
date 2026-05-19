import Foundation

// MARK: - Shared signal primitives

enum SituationalSourceAvailability: String, Hashable, Sendable, Codable, CaseIterable {
	case available
	case unavailable
	case stale
	case suppressed
}

enum SituationalLengthBucket: String, Hashable, Sendable, Codable, CaseIterable {
	case none
	case tiny
	case small
	case medium
	case large
	case huge
}

enum SituationalFreshnessLevel: String, Hashable, Sendable, Codable, CaseIterable {
	case unknown
	case stale
	case aging
	case fresh
}

enum SituationalConfidenceLevel: String, Hashable, Sendable, Codable, CaseIterable {
	case low
	case medium
	case high
}

enum SituationalPrivacyLevel: String, Hashable, Sendable, Codable, CaseIterable {
	case metadataOnly
	case cappedExcerpt
	case sensitive
}

// MARK: - Source signals

struct SelectedTextSituationalSignal: Equatable, Sendable, Codable {
	let availability: SituationalSourceAvailability
	let lengthBucket: SituationalLengthBucket
	let freshness: SituationalFreshnessLevel
	let confidence: SituationalConfidenceLevel
	let reasonCodes: [String]
	let privacyLevel: SituationalPrivacyLevel
}

struct ClipboardSituationalSignal: Equatable, Sendable, Codable {
	let availability: SituationalSourceAvailability
	let lengthBucket: SituationalLengthBucket
	let freshness: SituationalFreshnessLevel
	let confidence: SituationalConfidenceLevel
	let reasonCodes: [String]
	let privacyLevel: SituationalPrivacyLevel
}

struct VisualSituationalSignal: Equatable, Sendable, Codable {
	let availability: SituationalSourceAvailability
	let freshness: SituationalFreshnessLevel
	let confidence: SituationalConfidenceLevel
	let reasonCodes: [String]
	let privacyLevel: SituationalPrivacyLevel
	let hasDescriptor: Bool
	let hasWindowSnapshot: Bool
}

struct OCRSituationalSignal: Equatable, Sendable, Codable {
	let availability: SituationalSourceAvailability
	let lengthBucket: SituationalLengthBucket
	let freshness: SituationalFreshnessLevel
	let confidence: SituationalConfidenceLevel
	let reasonCodes: [String]
	let privacyLevel: SituationalPrivacyLevel
}

struct ActivitySituationalSignal: Equatable, Sendable, Codable {
	let availability: SituationalSourceAvailability
	let freshness: SituationalFreshnessLevel
	let confidence: SituationalConfidenceLevel
	let reasonCodes: [String]
	let sessionContinuityScore: Double
	let dominantWorkflowHint: String?
}

struct InteractionSituationalSignal: Equatable, Sendable, Codable {
	let availability: SituationalSourceAvailability
	let freshness: SituationalFreshnessLevel
	let confidence: SituationalConfidenceLevel
	let reasonCodes: [String]
	let lastTriggerHint: String?
}

// MARK: - Situation classification

enum SituationalAppCategory: String, Hashable, Sendable, Codable, CaseIterable {
	case browser
	case ide
	case terminal
	case notes
	case communication
	case media
	case unknown
}

enum SituationalPrimarySource: String, Hashable, Sendable, Codable, CaseIterable {
	case selectedText = "selected_text"
	case clipboard = "clipboard"
	case ocr = "ocr"
	case visual = "visual"
	case workflowApp = "workflow_app"
	case metadataOnly = "metadata_only"
	case none
}

enum SituationalPerceptionRecommendation: String, Hashable, Sendable, Codable, CaseIterable {
	case none
	case useful
	case recommended
	case requiredBeforeSpecificProposal
}

enum SituationalPerceptionReason: String, Hashable, Sendable, Codable, CaseIterable {
	case noTextContext
	case browserAXUnavailable
	case videoOrSlidesLikely
	case imageOrDiagramLikely
	case workflowUnknown
	case staleClipboardOnly
	case weakFusedContext
}

// MARK: - Snapshot

struct SituationalContextSnapshot: Equatable, Sendable, Codable, Identifiable {
	let id: UUID
	let activeAppName: String
	let activeBundleId: String?
	let windowTitle: String
	let appCategory: SituationalAppCategory
	let inferredWorkflow: InferredWorkflow
	let inferredIntent: SynthesizedIntentType?
	let workflowConfidence: Double
	let contextFreshness: Double
	let continuityConfidence: Double
	let primaryAvailableSource: SituationalPrimarySource
	let availableSources: [SituationalPrimarySource]
	let staleSources: [SituationalPrimarySource]
	let suppressedSources: [SituationalPrimarySource]
	let selectedTextSignal: SelectedTextSituationalSignal
	let clipboardSignal: ClipboardSituationalSignal
	let visualSignal: VisualSituationalSignal
	let ocrSignal: OCRSituationalSignal
	let activitySignal: ActivitySituationalSignal
	let interactionSignal: InteractionSituationalSignal
	let missingContextReasons: [String]
	let perceptionRecommendation: SituationalPerceptionRecommendation
	let perceptionReasons: [SituationalPerceptionReason]
	let situationalSummary: String
	let assistantGuidance: [String]
	let createdAt: Date
	let expiresAt: Date
	let metadata: [String: String]

	static let ttlSeconds: TimeInterval = 120
	static let maxSummaryLength = 360
	static let maxGuidanceItems = 8
}

// MARK: - Diagnostics

enum SituationalContextDiagnostics {

	static func log(_ situational: SituationalContextSnapshot) {
		let clipboardSuppressed = situational.clipboardSignal.availability == .suppressed
			|| situational.clipboardSignal.availability == .stale
		let fused = situational.metadata["fused_packet"] == "yes"
		print(
			"""
			[SituationalContext] app=\(situational.activeAppName) workflow=\(situational.inferredWorkflow.rawValue) \
			primary=\(situational.primaryAvailableSource.rawValue) freshness=\(String(format: "%.2f", situational.contextFreshness)) \
			missing=\(situational.missingContextReasons.count) perception=\(situational.perceptionRecommendation.rawValue) \
			clipboard_suppressed=\(clipboardSuppressed ? "yes" : "no") fused_packet=\(fused ? "yes" : "no")
			"""
		)
	}
}

// MARK: - Length / freshness helpers

enum SituationalSignalMetrics {

	static func lengthBucket(for charCount: Int) -> SituationalLengthBucket {
		switch charCount {
		case 0: return .none
		case 1 ..< 40: return .tiny
		case 40 ..< 120: return .small
		case 120 ..< 400: return .medium
		case 400 ..< 1200: return .large
		default: return .huge
		}
	}

	static func freshnessLevel(
		capturedAt: Date?,
		source: FusedContextSource,
		referenceTime: Date
	) -> SituationalFreshnessLevel {
		guard let capturedAt else { return .unknown }
		if ContextFreshnessPolicy.isStale(source: source, capturedAt: capturedAt, now: referenceTime) {
			return .stale
		}
		let score = ContextFreshnessPolicy.freshnessScore(for: source, capturedAt: capturedAt, now: referenceTime)
		if score >= 0.72 { return .fresh }
		if score >= 0.42 { return .aging }
		return .stale
	}

	static func confidenceLevel(from score: Double) -> SituationalConfidenceLevel {
		if score >= 0.72 { return .high }
		if score >= 0.45 { return .medium }
		return .low
	}
}
