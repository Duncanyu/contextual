import Foundation

/// Privacy envelope for generated execution context (no escalation in T17.3).
enum GeneratedExecutionPrivacyLevel: String, Hashable, Sendable, Codable, CaseIterable {
	case metadataOnly = "metadata_only"
	case boundedExcerpts = "bounded_excerpts"
}

/// Bounded, ephemeral context for primitive execution (not persisted).
struct GeneratedExecutionContext: Equatable, Sendable, Codable {
	static let maxExcerptLength = 1_200
	static let maxSummaryLength = 400

	let sourceType: String
	let appName: String
	let windowTitle: String
	let workflowType: WorkflowType
	let intentType: IntentType
	let selectedTextExcerpt: String?
	let clipboardTextExcerpt: String?
	let ocrTextExcerpt: String?
	let contextSummary: String?
	/// Bounded visual description excerpt (explicit visual context only).
	let visualSummaryExcerpt: String?
	let visualTags: [String]
	let visualContextCapturedAt: Date?
	let visualContextExpiresAt: Date?
	let availableContextTypes: [ContextRequirementType]
	let privacyLevel: GeneratedExecutionPrivacyLevel
	let createdAt: Date
	let expirationDate: Date

	init(
		sourceType: String,
		appName: String,
		windowTitle: String,
		workflowType: WorkflowType,
		intentType: IntentType,
		selectedTextExcerpt: String? = nil,
		clipboardTextExcerpt: String? = nil,
		ocrTextExcerpt: String? = nil,
		contextSummary: String? = nil,
		visualSummaryExcerpt: String? = nil,
		visualTags: [String] = [],
		visualContextCapturedAt: Date? = nil,
		visualContextExpiresAt: Date? = nil,
		availableContextTypes: [ContextRequirementType],
		privacyLevel: GeneratedExecutionPrivacyLevel = .boundedExcerpts,
		createdAt: Date = Date(),
		expirationDate: Date
	) {
		self.sourceType = sourceType
		self.appName = appName
		self.windowTitle = windowTitle
		self.workflowType = workflowType
		self.intentType = intentType
		self.selectedTextExcerpt = Self.cap(selectedTextExcerpt, max: Self.maxExcerptLength)
		self.clipboardTextExcerpt = Self.cap(clipboardTextExcerpt, max: Self.maxExcerptLength)
		self.ocrTextExcerpt = Self.cap(ocrTextExcerpt, max: Self.maxExcerptLength)
		self.contextSummary = Self.cap(contextSummary, max: Self.maxSummaryLength)
		self.visualSummaryExcerpt = Self.cap(visualSummaryExcerpt, max: Self.maxSummaryLength)
		self.visualTags = Array(visualTags.prefix(8).map { Self.capTag($0) })
		self.visualContextCapturedAt = visualContextCapturedAt
		self.visualContextExpiresAt = visualContextExpiresAt
		self.availableContextTypes = availableContextTypes
		self.privacyLevel = privacyLevel
		self.createdAt = createdAt
		self.expirationDate = expirationDate
	}

	var isExpired: Bool {
		Date() >= expirationDate
	}

	var hasActiveVisualContext: Bool {
		guard visualContextCapturedAt != nil else { return false }
		if let expiresAt = visualContextExpiresAt, Date() >= expiresAt { return false }
		return visualSummaryExcerpt != nil || !visualTags.isEmpty
	}

	/// Best-effort primary text for deterministic primitives (priority: selection → clipboard → OCR → visual → summary).
	var primarySourceText: String {
		let candidates = [selectedTextExcerpt, clipboardTextExcerpt, ocrTextExcerpt, visualSummaryExcerpt, contextSummary]
		for raw in candidates {
			let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty { return trimmed }
		}
		return ""
	}

	var hasUsableText: Bool {
		!primarySourceText.isEmpty
	}

	/// Whether required context codes are satisfied by available types and excerpts.
	func satisfies(required: [ContextRequirementType]) -> Bool {
		let requiredSet = Set(required.filter { $0 != .none })
		if requiredSet.isEmpty { return true }

		for req in requiredSet {
			switch req {
			case .textSnippet, .selectedText:
				guard availableContextTypes.contains(req) || availableContextTypes.contains(.textSnippet),
				      !(selectedTextExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				else { return false }
			case .fusedVisual, .screenCapture:
				guard availableContextTypes.contains(req) else { return false }
			case .multiSource:
				let count = [selectedTextExcerpt, clipboardTextExcerpt, ocrTextExcerpt]
					.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
					.filter { !$0.isEmpty }
					.count
				guard count >= 2 else { return false }
			case .workflowContext, .errorContext, .notesContext:
				guard availableContextTypes.contains(req), hasUsableText else { return false }
			case .none:
				break
			}
		}
		return true
	}

	private static func cap(_ value: String?, max: Int) -> String? {
		guard let value else { return nil }
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		if trimmed.count <= max { return trimmed }
		return String(trimmed.prefix(max))
	}

	private static func capTag(_ value: String) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count <= 48 else { return String(trimmed.prefix(48)) }
		return trimmed
	}

	/// Merges bounded visual context from an explicit scheduler result (no automatic collection).
	func merging(visual result: BoundedVisualContextResult) -> GeneratedExecutionContext {
		var types = availableContextTypes
		if result.status == .completed || result.status == .partial {
			if !types.contains(.screenCapture) { types.append(.screenCapture) }
			if result.ocrExcerpt != nil, !types.contains(.fusedVisual) { types.append(.fusedVisual) }
		}
		return GeneratedExecutionContext(
			sourceType: sourceType,
			appName: appName,
			windowTitle: windowTitle,
			workflowType: workflowType,
			intentType: intentType,
			selectedTextExcerpt: selectedTextExcerpt,
			clipboardTextExcerpt: clipboardTextExcerpt,
			ocrTextExcerpt: result.ocrExcerpt ?? ocrTextExcerpt,
			contextSummary: contextSummary,
			visualSummaryExcerpt: result.visualSummary ?? visualSummaryExcerpt,
			visualTags: result.visualTags.isEmpty ? visualTags : result.visualTags,
			visualContextCapturedAt: result.capturedAt ?? visualContextCapturedAt,
			visualContextExpiresAt: result.expiresAt ?? visualContextExpiresAt,
			availableContextTypes: types,
			privacyLevel: privacyLevel,
			createdAt: createdAt,
			expirationDate: expirationDate
		)
	}
}
