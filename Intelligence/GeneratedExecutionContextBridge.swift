import Foundation

/// Primary context channel chosen for generated execution (metadata code only).
enum GeneratedExecutionPrimarySource: String, Hashable, Sendable {
	case selectedText = "selected_text"
	case workflowApp = "workflow_app"
	case visual = "visual"
	case ocr = "ocr"
	case clipboard = "clipboard"
	case metadataFallback = "metadata_fallback"
}

/// Converts canonical live snapshots into bounded `GeneratedExecutionContext` (T18.1).
struct GeneratedExecutionContextBridge: Sendable {

	static let contextTTLSeconds: TimeInterval = 120

	func buildContext(
		from snapshot: CanonicalGeneratedExecutionContextSnapshot,
		action: GeneratedExecutionAction? = nil,
		referenceTime: Date = Date()
	) -> GeneratedExecutionContext {
		let suppression = GeneratedExecutionClipboardFreshnessPolicy.evaluate(
			snapshot: snapshot,
			referenceTime: referenceTime
		)
		let freshness = GeneratedExecutionContextFreshnessScorer.score(
			snapshot: snapshot,
			referenceTime: referenceTime
		)
		let workflowTypeFromSnapshot = WorkflowExecutionMapper.workflowType(from: snapshot.inferredWorkflow)
		let actionWorkflowType = action?.workflowType ?? .unknown
		let effectiveWorkflowType = workflowTypeFromSnapshot != .unknown ? workflowTypeFromSnapshot : actionWorkflowType

		let primary = resolvePrimarySource(
			snapshot: snapshot,
			suppression: suppression,
			effectiveWorkflowType: effectiveWorkflowType,
			referenceTime: referenceTime
		)

		let selectedExcerpt = snapshot.selectedText
		let clipboardExcerpt = suppression.includeClipboard ? snapshot.clipboardText : nil
		let ocrExcerpt = snapshot.recentOCRExcerpt

		let visual = snapshot.visualContextAvailability
		let intentType: IntentType = {
			if let intent = snapshot.inferredIntent {
				return WorkflowExecutionMapper.intentType(from: intent)
			}
			if let action {
				return action.intentType
			}
			return .unknown
		}()

		let available = mergeAvailableTypes(
			snapshot: snapshot,
			effectiveWorkflowType: effectiveWorkflowType,
			selectedExcerpt: selectedExcerpt,
			clipboardExcerpt: clipboardExcerpt,
			ocrExcerpt: ocrExcerpt,
			visual: visual
		)

		let expiration = snapshot.generatedAt.addingTimeInterval(Self.contextTTLSeconds)

		let context = GeneratedExecutionContext(
			sourceType: primary.rawValue,
			appName: snapshot.activeApp,
			windowTitle: snapshot.windowTitle,
			workflowType: effectiveWorkflowType,
			intentType: intentType,
			selectedTextExcerpt: selectedExcerpt,
			clipboardTextExcerpt: clipboardExcerpt,
			ocrTextExcerpt: ocrExcerpt,
			contextSummary: snapshot.contextSummary,
			visualSummaryExcerpt: visual.visualSummaryExcerpt,
			visualTags: visual.visualTags,
			visualContextCapturedAt: visual.visualCapturedAt,
			visualContextExpiresAt: visual.visualExpiresAt,
			availableContextTypes: available,
			createdAt: snapshot.generatedAt,
			expirationDate: expiration
		)

		logBridgeBuilt(
			primary: primary,
			freshness: freshness,
			suppression: suppression,
			continuity: snapshot.sourceMetadata.sessionContinuityScore,
			actionId: action?.id
		)

		return context
	}

	// MARK: - Primary source

	private func resolvePrimarySource(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		suppression: GeneratedExecutionClipboardSuppressionDecision,
		effectiveWorkflowType: WorkflowType,
		referenceTime: Date
	) -> GeneratedExecutionPrimarySource {
		if !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return .selectedText
		}

		let hasWorkflowInference = (snapshot.inferredWorkflow != .unknown && snapshot.workflowConfidence >= 0.35)
			|| effectiveWorkflowType != .unknown
		if hasWorkflowInference {
			if snapshot.visualContextAvailability.hasUsableVisual {
				return .visual
			}
			if !(snapshot.recentOCRExcerpt ?? "").isEmpty {
				return .ocr
			}
			return .workflowApp
		}

		if snapshot.visualContextAvailability.hasUsableVisual {
			return .visual
		}

		if !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let ocrAt = snapshot.sourceMetadata.ocrCapturedAt ?? snapshot.generatedAt
			if !ContextFreshnessPolicy.isStale(source: .screenOCR, capturedAt: ocrAt, now: referenceTime) {
				return .ocr
			}
		}

		if suppression.includeClipboard,
		   !(snapshot.clipboardText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return .clipboard
		}

		return .metadataFallback
	}

	private func mergeAvailableTypes(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		effectiveWorkflowType: WorkflowType,
		selectedExcerpt: String?,
		clipboardExcerpt: String?,
		ocrExcerpt: String?,
		visual: GeneratedExecutionVisualContextAvailability
	) -> [ContextRequirementType] {
		var types = snapshot.availableContextTypes
		func add(_ t: ContextRequirementType) {
			if !types.contains(t) { types.append(t) }
		}

		if !(selectedExcerpt ?? "").isEmpty { add(.selectedText); add(.textSnippet) }
		if !(clipboardExcerpt ?? "").isEmpty { add(.textSnippet) }
		if !(ocrExcerpt ?? "").isEmpty { add(.fusedVisual); add(.textSnippet) }
		if visual.hasUsableVisual { add(.screenCapture); add(.fusedVisual) }
		if effectiveWorkflowType != .unknown { add(.workflowContext) }
		// Add .errorContext for debugging when there is selected text or OCR — error context is
		// typically present whenever the user has selected an error message or stack trace.
		if effectiveWorkflowType == .debugging {
			let hasText = !(selectedExcerpt ?? "").isEmpty || !(ocrExcerpt ?? "").isEmpty
			if hasText { add(.errorContext) }
		}

		let channels = [
			!(selectedExcerpt ?? "").isEmpty,
			!(clipboardExcerpt ?? "").isEmpty,
			!(ocrExcerpt ?? "").isEmpty
		].filter { $0 }.count
		if channels >= 2 { add(.multiSource) }

		return types
	}

	// MARK: - Logging (metadata only)

	private func logBridgeBuilt(
		primary: GeneratedExecutionPrimarySource,
		freshness: Double,
		suppression: GeneratedExecutionClipboardSuppressionDecision,
		continuity: Double,
		actionId: UUID?
	) {
		var parts = [
			"primary=\(primary.rawValue)",
			String(format: "freshness=%.2f", freshness)
		]
		if let actionId {
			parts.append("actionId=\(actionId.uuidString.prefix(8))")
		}
		if !suppression.includeClipboard, let reason = suppression.reasonCode {
			parts.append("clipboard_suppressed=\(reason)")
		}
		if continuity > 0.05 {
			parts.append(String(format: "continuity=%.2f", continuity))
		}
		print("[GeneratedExecutionContextBridge] built \(parts.joined(separator: " "))")
	}
}

// MARK: - Clipboard suppression

struct GeneratedExecutionClipboardSuppressionDecision: Equatable, Sendable {
	let includeClipboard: Bool
	let reasonCode: String?
}

enum GeneratedExecutionClipboardFreshnessPolicy {

	static func evaluate(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date = Date()
	) -> GeneratedExecutionClipboardSuppressionDecision {
		let hasClipboard = !(snapshot.clipboardText ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.isEmpty
		guard hasClipboard else {
			return GeneratedExecutionClipboardSuppressionDecision(includeClipboard: false, reasonCode: nil)
		}

		let hasSelection = !(snapshot.selectedText ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.isEmpty
		if hasSelection {
			logSuppressed(reason: "selection_present")
			return GeneratedExecutionClipboardSuppressionDecision(includeClipboard: false, reasonCode: "selection_present")
		}

		let clipboardAt = snapshot.sourceMetadata.clipboardCapturedAt
			?? snapshot.sourceMetadata.contextUpdatedAt
			?? snapshot.generatedAt
		if ContextFreshnessPolicy.isStale(source: .clipboardText, capturedAt: clipboardAt, now: referenceTime) {
			logSuppressed(reason: "clipboard_stale")
			return GeneratedExecutionClipboardSuppressionDecision(includeClipboard: false, reasonCode: "clipboard_stale")
		}

		if snapshot.fusedPacketId != nil, snapshot.packetIsStale {
			logSuppressed(reason: "packet_stale")
			return GeneratedExecutionClipboardSuppressionDecision(includeClipboard: false, reasonCode: "packet_stale")
		}

		let fusedPrimary = snapshot.sourceMetadata.fusedPrimarySource
		if fusedPrimary == FusedPrimarySource.selectedText.rawValue
			|| fusedPrimary == FusedPrimarySource.axText.rawValue {
			logSuppressed(reason: "fused_primary_not_clipboard")
			return GeneratedExecutionClipboardSuppressionDecision(
				includeClipboard: false,
				reasonCode: "fused_primary_not_clipboard"
			)
		}

		if snapshot.sourceMetadata.fusedSuppressedSources.contains(FusedContextSource.clipboardText.rawValue) {
			logSuppressed(reason: "fused_suppressed_clipboard")
			return GeneratedExecutionClipboardSuppressionDecision(
				includeClipboard: false,
				reasonCode: "fused_suppressed_clipboard"
			)
		}

		let continuity = snapshot.sourceMetadata.sessionContinuityScore
		let dominant = snapshot.sourceMetadata.sessionDominantWorkflow
		if continuity >= 0.55,
		   let dominant,
		   dominant != snapshot.inferredWorkflow.rawValue,
		   dominant != InferredWorkflow.unknown.rawValue {
			logSuppressed(reason: "workflow_continuity_mismatch")
			return GeneratedExecutionClipboardSuppressionDecision(
				includeClipboard: false,
				reasonCode: "workflow_continuity_mismatch"
			)
		}

		if snapshot.sourceMetadata.lastSourceTrigger == LastSourceTrigger.activeAppChanged.rawValue,
		   snapshot.sourceMetadata.fusedPrimarySource != FusedPrimarySource.clipboardText.rawValue {
			logSuppressed(reason: "app_changed_clipboard_unrelated")
			return GeneratedExecutionClipboardSuppressionDecision(
				includeClipboard: false,
				reasonCode: "app_changed_clipboard_unrelated"
			)
		}

		return GeneratedExecutionClipboardSuppressionDecision(includeClipboard: true, reasonCode: nil)
	}

	private static func logSuppressed(reason: String) {
		print("[GeneratedExecutionContextBridge] stale_clipboard_suppressed reason=\(reason)")
	}
}

// MARK: - Freshness scoring

enum GeneratedExecutionContextFreshnessScorer {

	static func score(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date = Date()
	) -> Double {
		var score = snapshot.freshnessScore

		if let at = snapshot.sourceMetadata.selectedTextCapturedAt,
		   !(snapshot.selectedText ?? "").isEmpty {
			let sel = ContextFreshnessPolicy.freshnessScore(
				for: .selectedText,
				capturedAt: at,
				now: referenceTime
			)
			score = max(score, sel * 0.85 + 0.1)
		}

		if snapshot.sourceMetadata.sessionContinuityScore >= 0.5 {
			score += 0.06 * snapshot.sourceMetadata.sessionContinuityScore
		}

		if snapshot.workflowConfidence >= 0.4 {
			score += 0.04 * snapshot.workflowConfidence
		}

		if snapshot.packetIsStale {
			score -= 0.18
		}

		if let at = snapshot.sourceMetadata.clipboardCapturedAt,
		   !(snapshot.clipboardText ?? "").isEmpty {
			let clip = ContextFreshnessPolicy.freshnessScore(
				for: .clipboardText,
				capturedAt: at,
				now: referenceTime
			)
			if clip < ContextFreshnessPolicy.staleThreshold {
				score -= 0.12
			}
		}

		if let at = snapshot.sourceMetadata.ocrCapturedAt,
		   !(snapshot.recentOCRExcerpt ?? "").isEmpty {
			let ocr = ContextFreshnessPolicy.freshnessScore(
				for: .screenOCR,
				capturedAt: at,
				now: referenceTime
			)
			score = max(score, ocr * 0.7)
		}

		let age = referenceTime.timeIntervalSince(snapshot.generatedAt)
		if age > 90 {
			score -= min(0.25, (age - 90) / 120)
		}

		return min(1, max(0, score))
	}
}

// MARK: - Self tests (not wired to app launch)

enum GeneratedExecutionContextBridgeSelfTest {

	static func run() -> Bool {
		var failures: [String] = []
		func check(_ name: String, _ ok: Bool) {
			if !ok { failures.append(name) }
		}

		let bridge = GeneratedExecutionContextBridge()
		let now = Date()

		let staleClipboard = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Xcode",
			inferredWorkflow: .debugging,
			selectedText: "current selection wins",
			clipboardText: "old clipboard payload",
			generatedAt: now,
			freshnessScore: 0.5,
			sourceMetadata: CanonicalExecutionSourceMetadata(
				selectedTextCapturedAt: now,
				clipboardCapturedAt: now.addingTimeInterval(-120),
				fusedPrimarySource: FusedPrimarySource.clipboardText.rawValue
			)
		)
		let withSelection = bridge.buildContext(from: staleClipboard)
		check(
			"selection_outranks_clipboard",
			withSelection.primarySourceText == "current selection wins"
				&& (withSelection.clipboardTextExcerpt ?? "").isEmpty
		)

		let staleOnly = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Notes",
			clipboardText: "stale clip",
			generatedAt: now,
			sourceMetadata: CanonicalExecutionSourceMetadata(
				clipboardCapturedAt: now.addingTimeInterval(-200)
			),
			packetIsStale: true
		)
		let suppressed = bridge.buildContext(from: staleOnly)
		check("stale_clipboard_suppressed", (suppressed.clipboardTextExcerpt ?? "").isEmpty)

		let continuitySnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Safari",
			inferredWorkflow: .browsing,
			clipboardText: "clip",
			generatedAt: now,
			sourceMetadata: CanonicalExecutionSourceMetadata(
				clipboardCapturedAt: now,
				fusedPrimarySource: FusedPrimarySource.selectedText.rawValue,
				sessionContinuityScore: 0.8,
				sessionDominantWorkflow: InferredWorkflow.debugging.rawValue
			)
		)
		let continuityCtx = bridge.buildContext(from: continuitySnap)
		check(
			"continuity_influences_source",
			(continuityCtx.clipboardTextExcerpt ?? "").isEmpty
				&& continuityCtx.sourceType != GeneratedExecutionPrimarySource.clipboard.rawValue
		)

		let visualSnap = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "Finder",
			inferredWorkflow: .browsing,
			availableContextTypes: [.screenCapture, .fusedVisual],
			visualContextAvailability: GeneratedExecutionVisualContextAvailability(
				hasVisualDescriptor: true,
				visualSummaryExcerpt: "bounded visual summary",
				visualTags: ["list", "sidebar"],
				visualCapturedAt: now,
				visualExpiresAt: now.addingTimeInterval(30)
			),
			generatedAt: now
		)
		let visualCtx = bridge.buildContext(from: visualSnap)
		check(
			"visual_merges_safely",
			visualCtx.hasActiveVisualContext
				&& visualCtx.availableContextTypes.contains(.screenCapture)
		)

		let low = GeneratedExecutionContextFreshnessScorer.score(
			snapshot: CanonicalGeneratedExecutionContextSnapshot(
				activeApp: "A",
				generatedAt: now.addingTimeInterval(-300),
				freshnessScore: -0.5,
				packetIsStale: true
			),
			referenceTime: now
		)
		check("freshness_clamped", low >= 0 && low <= 1)

		let snapA = CanonicalGeneratedExecutionContextSnapshot(
			activeApp: "App",
			selectedText: "same",
			generatedAt: now,
			freshnessScore: 0.6
		)
		let ctx1 = bridge.buildContext(from: snapA)
		let ctx2 = bridge.buildContext(from: snapA)
		check("bridge_deterministic", ctx1 == ctx2)

		let sem = DispatchSemaphore(value: 0)
		Task.detached {
			let defaultRuntime = GeneratedExecutionRuntime()
			let probe = await defaultRuntime.phase18BridgeProbe()
			check("runtime_stable_without_bridge", !probe)
			sem.signal()
		}
		sem.wait()

		check("no_recursive_provider", BridgedGeneratedExecutionContextProvider.runSelfTest())

		let ok = failures.isEmpty
		print("[GeneratedExecutionContextBridge] selftest ok=\(ok) failures=\(failures.count) detail=\(failures.joined(separator: ";"))")
		return ok
	}
}
