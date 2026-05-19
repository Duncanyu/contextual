import Foundation

// MARK: - Bounds

enum BoundedVisualContextBounds {
	static let defaultMaxCaptureCount = 1
	static let defaultMaxWindowSeconds: TimeInterval = 8
	static let defaultMaxOCRCharacters = GeneratedExecutionContext.maxExcerptLength
	static let defaultMaxDescriptionCharacters = GeneratedExecutionContext.maxSummaryLength
	static let maxTags = 8
	static let maxWarnings = 6
	static let maxMetadataKeys = 12
}

// MARK: - Sources

enum VisualContextSourceKind: String, Hashable, Sendable, Codable, CaseIterable {
	case screenCapture = "screen_capture"
	case ocr
	case layoutMetadata = "layout_metadata"
}

// MARK: - Status

enum VisualContextStatus: String, Hashable, Sendable, Codable, CaseIterable {
	case unavailable
	case permissionDenied = "permission_denied"
	case budgetDenied = "budget_denied"
	case expired
	case concurrentRequestRejected = "concurrent_request_rejected"
	case timedOut = "timed_out"
	case cancelled
	case captureFailed = "capture_failed"
	case ocrFailed = "ocr_failed"
	case completed
	case partial
}

// MARK: - Errors

enum VisualContextError: String, Error, Hashable, Sendable {
	case unavailable
	case permissionDenied
	case budgetDenied
	case expired
	case concurrentRequestRejected
	case timedOut
	case cancelled
	case captureFailed
	case ocrFailed
	case invalidRequest
}

extension VisualContextError {
	var status: VisualContextStatus {
		switch self {
		case .unavailable: .unavailable
		case .permissionDenied: .permissionDenied
		case .budgetDenied: .budgetDenied
		case .expired: .expired
		case .concurrentRequestRejected: .concurrentRequestRejected
		case .timedOut: .timedOut
		case .cancelled: .cancelled
		case .captureFailed: .captureFailed
		case .ocrFailed: .ocrFailed
		case .invalidRequest: .unavailable
		}
	}
}

// MARK: - Request

/// Explicit, bounded visual context collection request (one execution window).
struct BoundedVisualContextRequest: Equatable, Sendable, Codable, Identifiable {
	let id: UUID
	let reason: String
	let requestedByActionId: UUID?
	let workflowType: WorkflowType
	let intentType: IntentType
	let allowedSources: [VisualContextSourceKind]
	let requiresOCR: Bool
	let requiresVisualDescription: Bool
	let maxCaptureCount: Int
	let maxWindowSeconds: TimeInterval
	let maxOCRCharacters: Int
	let maxDescriptionCharacters: Int
	let budget: ExecutionBudget
	let permissionAvailability: [String: Bool]
	let createdAt: Date
	let expiresAt: Date

	init(
		id: UUID = UUID(),
		reason: String,
		requestedByActionId: UUID? = nil,
		workflowType: WorkflowType,
		intentType: IntentType,
		allowedSources: [VisualContextSourceKind] = [.screenCapture, .ocr],
		requiresOCR: Bool = false,
		requiresVisualDescription: Bool = false,
		maxCaptureCount: Int = BoundedVisualContextBounds.defaultMaxCaptureCount,
		maxWindowSeconds: TimeInterval = BoundedVisualContextBounds.defaultMaxWindowSeconds,
		maxOCRCharacters: Int = BoundedVisualContextBounds.defaultMaxOCRCharacters,
		maxDescriptionCharacters: Int = BoundedVisualContextBounds.defaultMaxDescriptionCharacters,
		budget: ExecutionBudget = .conservative,
		permissionAvailability: [PermissionRequirement: Bool] = [:],
		createdAt: Date = Date(),
		expiresAt: Date? = nil
	) {
		self.id = id
		self.reason = Self.cap(reason, max: 120)
		self.requestedByActionId = requestedByActionId
		self.workflowType = workflowType
		self.intentType = intentType
		self.allowedSources = Array(allowedSources.prefix(4))
		self.requiresOCR = requiresOCR
		self.requiresVisualDescription = requiresVisualDescription
		self.maxCaptureCount = min(1, max(1, maxCaptureCount))
		self.maxWindowSeconds = min(30, max(1, maxWindowSeconds))
		self.maxOCRCharacters = min(
			BoundedVisualContextBounds.defaultMaxOCRCharacters,
			max(64, maxOCRCharacters)
		)
		self.maxDescriptionCharacters = min(
			BoundedVisualContextBounds.defaultMaxDescriptionCharacters,
			max(64, maxDescriptionCharacters)
		)
		self.budget = budget
		self.permissionAvailability = Dictionary(
			uniqueKeysWithValues: permissionAvailability.map { ($0.key.rawValue, $0.value) }
		)
		self.createdAt = createdAt
		let defaultExpiry = createdAt.addingTimeInterval(self.maxWindowSeconds)
		self.expiresAt = expiresAt ?? defaultExpiry
	}

	var isExpired: Bool {
		Date() >= expiresAt
	}

	func permissionGranted(_ requirement: PermissionRequirement) -> Bool {
		permissionAvailability[requirement.rawValue] ?? false
	}

	private static func cap(_ text: String, max: Int) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count > max else { return trimmed.isEmpty ? "visual_context" : trimmed }
		return String(trimmed.prefix(max))
	}
}

// MARK: - Result

/// Bounded visual context packet (no raw screenshot persistence).
struct BoundedVisualContextResult: Equatable, Sendable, Codable, Identifiable {
	let id: UUID
	let requestId: UUID
	let status: VisualContextStatus
	let capturedAt: Date?
	let sourceSummary: String
	let ocrExcerpt: String?
	let visualSummary: String?
	let visualTags: [String]
	let warnings: [String]
	let metadata: [String: String]
	let expiresAt: Date?

	init(
		id: UUID = UUID(),
		requestId: UUID,
		status: VisualContextStatus,
		capturedAt: Date? = nil,
		sourceSummary: String = "",
		ocrExcerpt: String? = nil,
		visualSummary: String? = nil,
		visualTags: [String] = [],
		warnings: [String] = [],
		metadata: [String: String] = [:],
		expiresAt: Date? = nil
	) {
		self.id = id
		self.requestId = requestId
		self.status = status
		self.capturedAt = capturedAt
		self.sourceSummary = Self.cap(sourceSummary, max: 160)
		self.ocrExcerpt = Self.capOptional(ocrExcerpt, max: BoundedVisualContextBounds.defaultMaxOCRCharacters)
		self.visualSummary = Self.capOptional(visualSummary, max: BoundedVisualContextBounds.defaultMaxDescriptionCharacters)
		self.visualTags = Array(visualTags.prefix(BoundedVisualContextBounds.maxTags).map { Self.cap($0, max: 48) })
		self.warnings = Array(warnings.prefix(BoundedVisualContextBounds.maxWarnings).map { Self.cap($0, max: 80) })
		self.metadata = Self.sanitizeMetadata(metadata)
		self.expiresAt = expiresAt
	}

	static func unavailable(requestId: UUID, detail: String = "provider_unavailable") -> BoundedVisualContextResult {
		BoundedVisualContextResult(
			requestId: requestId,
			status: .unavailable,
			sourceSummary: detail,
			warnings: [detail]
		)
	}

	static func fromError(_ error: VisualContextError, requestId: UUID, detail: String? = nil) -> BoundedVisualContextResult {
		BoundedVisualContextResult(
			requestId: requestId,
			status: error.status,
			sourceSummary: detail ?? error.rawValue,
			warnings: [error.rawValue]
		)
	}

	private static func cap(_ text: String, max: Int) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count > max else { return trimmed }
		return String(trimmed.prefix(max))
	}

	private static func capOptional(_ text: String?, max: Int) -> String? {
		guard let text else { return nil }
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		guard trimmed.count <= max else { return String(trimmed.prefix(max)) }
		return trimmed
	}

	private static func sanitizeMetadata(_ metadata: [String: String]) -> [String: String] {
		let allowed = [
			"captureWidth", "captureHeight", "captureCount", "ocrLineCount",
			"ocrCharBucket", "provider", "permission", "budgetGate",
		]
		var out: [String: String] = [:]
		for key in allowed {
			guard let value = metadata[key] else { continue }
			out[key] = cap(value, max: 64)
			if out.count >= BoundedVisualContextBounds.maxMetadataKeys { break }
		}
		return out
	}
}
