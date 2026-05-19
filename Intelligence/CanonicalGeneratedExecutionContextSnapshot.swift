import Foundation

/// Bounded visual availability for generated execution (metadata + capped excerpts only).
struct GeneratedExecutionVisualContextAvailability: Equatable, Sendable {
	let hasVisualDescriptor: Bool
	let hasWindowSnapshot: Bool
	let visualSummaryExcerpt: String?
	let visualTags: [String]
	let visualCapturedAt: Date?
	let visualExpiresAt: Date?

	init(
		hasVisualDescriptor: Bool = false,
		hasWindowSnapshot: Bool = false,
		visualSummaryExcerpt: String? = nil,
		visualTags: [String] = [],
		visualCapturedAt: Date? = nil,
		visualExpiresAt: Date? = nil
	) {
		self.hasVisualDescriptor = hasVisualDescriptor
		self.hasWindowSnapshot = hasWindowSnapshot
		self.visualSummaryExcerpt = CanonicalGeneratedExecutionContextSnapshot.capExcerpt(visualSummaryExcerpt)
		self.visualTags = Array(visualTags.prefix(8).map { CanonicalGeneratedExecutionContextSnapshot.capTag($0) })
		self.visualCapturedAt = visualCapturedAt
		self.visualExpiresAt = visualExpiresAt
	}

	var hasUsableVisual: Bool {
		hasVisualDescriptor || hasWindowSnapshot || visualSummaryExcerpt != nil || !visualTags.isEmpty
	}
}

/// Metadata-only capture hints for freshness and arbitration (no raw payloads).
struct CanonicalExecutionSourceMetadata: Equatable, Sendable, Codable {
	let selectedTextCapturedAt: Date?
	let clipboardCapturedAt: Date?
	let ocrCapturedAt: Date?
	let contextUpdatedAt: Date?
	let lastSourceTrigger: String?
	let fusedConfidence: Double?
	let fusedConflictScore: Double?
	let fusedSuppressedSources: [String]
	let fusedArbitrationReasons: [String]
	let fusedPrimarySource: String?
	let sessionContinuityScore: Double
	let sessionDominantWorkflow: String?

	init(
		selectedTextCapturedAt: Date? = nil,
		clipboardCapturedAt: Date? = nil,
		ocrCapturedAt: Date? = nil,
		contextUpdatedAt: Date? = nil,
		lastSourceTrigger: String? = nil,
		fusedConfidence: Double? = nil,
		fusedConflictScore: Double? = nil,
		fusedSuppressedSources: [String] = [],
		fusedArbitrationReasons: [String] = [],
		fusedPrimarySource: String? = nil,
		sessionContinuityScore: Double = 0,
		sessionDominantWorkflow: String? = nil
	) {
		self.selectedTextCapturedAt = selectedTextCapturedAt
		self.clipboardCapturedAt = clipboardCapturedAt
		self.ocrCapturedAt = ocrCapturedAt
		self.contextUpdatedAt = contextUpdatedAt
		self.lastSourceTrigger = lastSourceTrigger
		self.fusedConfidence = fusedConfidence.map { min(1, max(0, $0)) }
		self.fusedConflictScore = fusedConflictScore.map { min(1, max(0, $0)) }
		self.fusedSuppressedSources = Array(fusedSuppressedSources.prefix(8))
		self.fusedArbitrationReasons = Array(fusedArbitrationReasons.prefix(8))
		self.fusedPrimarySource = fusedPrimarySource
		self.sessionContinuityScore = min(1, max(0, sessionContinuityScore))
		self.sessionDominantWorkflow = sessionDominantWorkflow
	}
}

/// Immutable canonical snapshot of fused/live runtime context for generated execution (T18.1).
struct CanonicalGeneratedExecutionContextSnapshot: Equatable, Sendable {
	static let maxExcerptLength = GeneratedExecutionContext.maxExcerptLength
	static let maxSummaryLength = GeneratedExecutionContext.maxSummaryLength

	let activeApp: String
	let windowTitle: String
	let bundleIdentifier: String?
	let inferredWorkflow: InferredWorkflow
	let inferredIntent: SynthesizedIntentType?
	let selectedText: String?
	let clipboardText: String?
	let recentOCRExcerpt: String?
	let contextSummary: String?
	let workflowConfidence: Double
	let availableContextTypes: [ContextRequirementType]
	let visualContextAvailability: GeneratedExecutionVisualContextAvailability
	let permissionAvailability: [PermissionRequirement: Bool]
	let generatedAt: Date
	let freshnessScore: Double
	let sourceMetadata: CanonicalExecutionSourceMetadata
	let fusedPacketId: UUID?
	let packetIsStale: Bool

	init(
		activeApp: String,
		windowTitle: String = "",
		bundleIdentifier: String? = nil,
		inferredWorkflow: InferredWorkflow = .unknown,
		inferredIntent: SynthesizedIntentType? = nil,
		selectedText: String? = nil,
		clipboardText: String? = nil,
		recentOCRExcerpt: String? = nil,
		contextSummary: String? = nil,
		workflowConfidence: Double = 0,
		availableContextTypes: [ContextRequirementType] = [],
		visualContextAvailability: GeneratedExecutionVisualContextAvailability = .init(),
		permissionAvailability: [PermissionRequirement: Bool] = [:],
		generatedAt: Date = Date(),
		freshnessScore: Double = 0.5,
		sourceMetadata: CanonicalExecutionSourceMetadata = .init(),
		fusedPacketId: UUID? = nil,
		packetIsStale: Bool = false
	) {
		self.activeApp = activeApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown" : activeApp
		self.windowTitle = windowTitle
		self.bundleIdentifier = bundleIdentifier
		self.inferredWorkflow = inferredWorkflow
		self.inferredIntent = inferredIntent
		self.selectedText = Self.capExcerpt(selectedText)
		self.clipboardText = Self.capExcerpt(clipboardText)
		self.recentOCRExcerpt = Self.capExcerpt(recentOCRExcerpt)
		self.contextSummary = Self.capSummary(contextSummary)
		self.workflowConfidence = min(1, max(0, workflowConfidence))
		self.availableContextTypes = availableContextTypes
		self.visualContextAvailability = visualContextAvailability
		self.permissionAvailability = permissionAvailability
		self.generatedAt = generatedAt
		self.freshnessScore = min(1, max(0, freshnessScore))
		self.sourceMetadata = sourceMetadata
		self.fusedPacketId = fusedPacketId
		self.packetIsStale = packetIsStale
	}

	static func capExcerpt(_ value: String?) -> String? {
		guard let value else { return nil }
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		if trimmed.count <= maxExcerptLength { return trimmed }
		return String(trimmed.prefix(maxExcerptLength))
	}

	static func capSummary(_ value: String?) -> String? {
		guard let value else { return nil }
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		if trimmed.count <= maxSummaryLength { return trimmed }
		return String(trimmed.prefix(maxSummaryLength))
	}

	static func capTag(_ value: String) -> String {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count <= 48 else { return String(trimmed.prefix(48)) }
		return trimmed
	}
}

// MARK: - Shallow export adapter (no subscriptions, no persistence)

enum CanonicalGeneratedExecutionContextSnapshotExporter {

	/// Builds a canonical snapshot from existing pipeline artifacts (call site supplies ephemeral text excerpts).
	static func export(
		model: ContextModel,
		fused: FusedContextPacket? = nil,
		selectedText: String? = nil,
		clipboardText: String? = nil,
		workflow: WorkflowInferenceResult? = nil,
		intent: IntentSynthesisResult? = nil,
		session: ContextualSessionState? = nil,
		visual: BoundedVisualContextResult? = nil,
		permissionAvailability: [PermissionRequirement: Bool] = [:],
		referenceTime: Date = Date()
	) -> CanonicalGeneratedExecutionContextSnapshot {
		let appName = model.activeAppName ?? fused?.appName ?? "Unknown"
		let windowTitle = model.activeWindowTitle ?? ""
		let wf = workflow?.workflow ?? .unknown
		let wfConf = workflow?.confidence ?? 0
		let intentType = intent?.topIntentType

		let ocrExcerpt = model.screenOCRText.map { CanonicalGeneratedExecutionContextSnapshot.capExcerpt($0) } ?? nil

		let visualAvailability = makeVisualAvailability(fused: fused, visual: visual, model: model)

		let metadata = makeMetadata(
			model: model,
			fused: fused,
			session: session,
			referenceTime: referenceTime
		)

		let available = inferAvailableTypes(
			model: model,
			fused: fused,
			selectedText: selectedText,
			clipboardText: clipboardText,
			ocrExcerpt: ocrExcerpt,
			visual: visualAvailability,
			workflow: wf
		)

		let summary = metadataOnlySummary(
			appName: appName,
			workflow: wf,
			fused: fused,
			available: available
		)

		let baseFresh = fused.map { min(1, max(0, $0.freshnessScore)) } ?? 0.45
		let provisional = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: appName,
			windowTitle: windowTitle,
			bundleIdentifier: model.activeAppBundleIdentifier ?? fused?.bundleIdentifier,
			inferredWorkflow: wf,
			inferredIntent: intentType,
			selectedText: selectedText,
			clipboardText: clipboardText,
			recentOCRExcerpt: ocrExcerpt ?? nil,
			contextSummary: summary,
			workflowConfidence: wfConf,
			availableContextTypes: available,
			visualContextAvailability: visualAvailability,
			permissionAvailability: permissionAvailability,
			generatedAt: referenceTime,
			freshnessScore: baseFresh,
			sourceMetadata: metadata,
			fusedPacketId: fused?.id,
			packetIsStale: fused?.isStale ?? false
		)

		let scored = GeneratedExecutionContextFreshnessScorer.score(
			snapshot: provisional,
			referenceTime: referenceTime
		)
		return CanonicalGeneratedExecutionContextSnapshot(
			activeApp: provisional.activeApp,
			windowTitle: provisional.windowTitle,
			bundleIdentifier: provisional.bundleIdentifier,
			inferredWorkflow: provisional.inferredWorkflow,
			inferredIntent: provisional.inferredIntent,
			selectedText: provisional.selectedText,
			clipboardText: provisional.clipboardText,
			recentOCRExcerpt: provisional.recentOCRExcerpt,
			contextSummary: provisional.contextSummary,
			workflowConfidence: provisional.workflowConfidence,
			availableContextTypes: provisional.availableContextTypes,
			visualContextAvailability: provisional.visualContextAvailability,
			permissionAvailability: provisional.permissionAvailability,
			generatedAt: provisional.generatedAt,
			freshnessScore: scored,
			sourceMetadata: provisional.sourceMetadata,
			fusedPacketId: provisional.fusedPacketId,
			packetIsStale: provisional.packetIsStale
		)
	}

	/// Convenience: fused packet from canonical state + model + optional excerpts (manual/debug).
	static func exportFromCanonicalState(
		model: ContextModel,
		selectedText: String? = nil,
		clipboardText: String? = nil,
		workflow: WorkflowInferenceResult? = nil,
		intent: IntentSynthesisResult? = nil,
		permissionAvailability: [PermissionRequirement: Bool] = [:],
		referenceTime: Date = Date()
	) -> CanonicalGeneratedExecutionContextSnapshot {
		let fused = CanonicalContextState.shared.current()
		let session = ContextualSessionTracker.shared.currentState()
		return export(
			model: model,
			fused: fused,
			selectedText: selectedText,
			clipboardText: clipboardText,
			workflow: workflow,
			intent: intent,
			session: session,
			permissionAvailability: permissionAvailability,
			referenceTime: referenceTime
		)
	}

	private static func makeVisualAvailability(
		fused: FusedContextPacket?,
		visual: BoundedVisualContextResult?,
		model: ContextModel
	) -> GeneratedExecutionVisualContextAvailability {
		if let visual, visual.status == .completed || visual.status == .partial {
			return GeneratedExecutionVisualContextAvailability(
				hasVisualDescriptor: true,
				hasWindowSnapshot: model.screenCaptureAvailable,
				visualSummaryExcerpt: visual.visualSummary,
				visualTags: visual.visualTags,
				visualCapturedAt: visual.capturedAt,
				visualExpiresAt: visual.expiresAt
			)
		}
		return GeneratedExecutionVisualContextAvailability(
			hasVisualDescriptor: fused?.hasVisualDescriptor ?? false,
			hasWindowSnapshot: fused?.hasWindowSnapshot ?? model.screenCaptureAvailable,
			visualSummaryExcerpt: nil,
			visualTags: fused?.uiStructureHints.prefix(4).map { $0 } ?? [],
			visualCapturedAt: model.screenCaptureCapturedAt,
			visualExpiresAt: nil
		)
	}

	private static func makeMetadata(
		model: ContextModel,
		fused: FusedContextPacket?,
		session: ContextualSessionState?,
		referenceTime: Date
	) -> CanonicalExecutionSourceMetadata {
		let trigger = model.lastSourceTrigger?.rawValue
		let selectedAt: Date? = model.selectedTextAvailable ? model.updatedAt : nil
		let clipboardAt: Date? = model.clipboardTextAvailable ? model.updatedAt : nil
		let ocrAt = model.screenOCRCapturedAt

		if trigger == LastSourceTrigger.selectedTextChanged.rawValue {
			// `updatedAt` reflects the dominant trigger; keep both hints when lengths imply availability.
		}

		return CanonicalExecutionSourceMetadata(
			selectedTextCapturedAt: selectedAt,
			clipboardCapturedAt: clipboardAt,
			ocrCapturedAt: ocrAt,
			contextUpdatedAt: model.updatedAt,
			lastSourceTrigger: trigger,
			fusedConfidence: fused?.confidence,
			fusedConflictScore: fused?.conflictScore,
			fusedSuppressedSources: fused?.suppressedSources.map(\.rawValue) ?? [],
			fusedArbitrationReasons: fused?.arbitrationReasons ?? [],
			fusedPrimarySource: fused?.primarySource.rawValue,
			sessionContinuityScore: session?.continuityScore ?? 0,
			sessionDominantWorkflow: session?.dominantWorkflow.rawValue
		)
	}

	private static func inferAvailableTypes(
		model: ContextModel,
		fused: FusedContextPacket?,
		selectedText: String?,
		clipboardText: String?,
		ocrExcerpt: String?,
		visual: GeneratedExecutionVisualContextAvailability,
		workflow: InferredWorkflow
	) -> [ContextRequirementType] {
		var types: [ContextRequirementType] = []
		func add(_ t: ContextRequirementType) {
			if !types.contains(t) { types.append(t) }
		}

		if !(selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			|| model.selectedTextAvailable {
			add(.selectedText)
			add(.textSnippet)
		}
		if !(clipboardText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			|| model.clipboardTextAvailable {
			add(.textSnippet)
		}
		if ocrExcerpt != nil || model.screenOCRAvailable || fused?.hasOCRText == true {
			add(.textSnippet)
			add(.fusedVisual)
		}
		if visual.hasUsableVisual || fused?.hasVisualDescriptor == true {
			add(.fusedVisual)
			add(.screenCapture)
		}
		if workflow != .unknown {
			add(.workflowContext)
		}

		let textChannels = [
			!(selectedText ?? "").isEmpty,
			!(clipboardText ?? "").isEmpty,
			ocrExcerpt != nil
		].filter { $0 }.count
		if textChannels >= 2 { add(.multiSource) }

		return types
	}

	private static func metadataOnlySummary(
		appName: String,
		workflow: InferredWorkflow,
		fused: FusedContextPacket?,
		available: [ContextRequirementType]
	) -> String? {
		var parts: [String] = ["app=\(appName)", "workflow=\(workflow.rawValue)"]
		if let fused {
			parts.append("primary=\(fused.primarySource.rawValue)")
			parts.append(String(format: "fresh=%.2f", fused.freshnessScore))
		}
		if !available.isEmpty {
			parts.append("types=\(available.map(\.rawValue).joined(separator: ","))")
		}
		return CanonicalGeneratedExecutionContextSnapshot.capSummary(parts.joined(separator: " | "))
	}
}
