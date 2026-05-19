import Foundation

// MARK: - Decision codes

enum SparseVisualPeekAllowReason: String, Hashable, Sendable, Codable {
	case weakContextConfidence = "weak_context_confidence"
	case insufficientWorkflowInference = "insufficient_workflow_inference"
	case missingPrimaryText = "missing_primary_text"
	case staleClipboardSuppressed = "stale_clipboard_suppressed"
	case visualContextLikelyUseful = "visual_context_likely_useful"
	case manualOrDebugExplicitRequest = "manual_or_debug_explicit_request"
	case actionRequiresVisionOrOCR = "action_requires_vision_or_ocr"
}

enum SparseVisualPeekDenyReason: String, Hashable, Sendable, Codable {
	case contextAlreadyStrong = "context_already_strong"
	case selectedTextSufficient = "selected_text_sufficient"
	case clipboardFreshEnough = "clipboard_fresh_enough"
	case recentVisualContextStillFresh = "recent_visual_context_still_fresh"
	case permissionUnavailable = "permission_unavailable"
	case budgetLikelyDenied = "budget_likely_denied"
	case workflowDoesNotBenefit = "workflow_does_not_benefit"
	case cooldownWindowActive = "cooldown_window_active"
	case schedulerUnavailable = "scheduler_unavailable"
	case noStrongTrigger = "no_strong_trigger"
}

/// Structured one-shot visual peek decision (metadata only — no raw context).
struct SparseVisualPeekDecision: Equatable, Sendable {
	let shouldPeek: Bool
	let allowReason: SparseVisualPeekAllowReason?
	let denyReason: SparseVisualPeekDenyReason?
	/// 0...1 — how urgently visual context is needed.
	let priority: Double
	let confidenceNeed: Double
	let requiresOCR: Bool
	let requiresVisualDescription: Bool
	let maxWindowSeconds: TimeInterval
	let maxOCRCharacters: Int
	let maxDescriptionCharacters: Int
	let recommendedRequest: BoundedVisualContextRequest?
	let metadata: [String: String]

	static func deny(
		_ reason: SparseVisualPeekDenyReason,
		confidenceNeed: Double = 0,
		metadata: [String: String] = [:]
	) -> SparseVisualPeekDecision {
		SparseVisualPeekDecision(
			shouldPeek: false,
			allowReason: nil,
			denyReason: reason,
			priority: 0,
			confidenceNeed: min(1, max(0, confidenceNeed)),
			requiresOCR: false,
			requiresVisualDescription: false,
			maxWindowSeconds: BoundedVisualContextBounds.defaultMaxWindowSeconds,
			maxOCRCharacters: BoundedVisualContextBounds.defaultMaxOCRCharacters,
			maxDescriptionCharacters: BoundedVisualContextBounds.defaultMaxDescriptionCharacters,
			recommendedRequest: nil,
			metadata: metadata
		)
	}

	static func allow(
		reason: SparseVisualPeekAllowReason,
		priority: Double,
		confidenceNeed: Double,
		requiresOCR: Bool,
		requiresVisualDescription: Bool,
		request: BoundedVisualContextRequest,
		metadata: [String: String] = [:]
	) -> SparseVisualPeekDecision {
		SparseVisualPeekDecision(
			shouldPeek: true,
			allowReason: reason,
			denyReason: nil,
			priority: min(1, max(0, priority)),
			confidenceNeed: min(1, max(0, confidenceNeed)),
			requiresOCR: requiresOCR,
			requiresVisualDescription: requiresVisualDescription,
			maxWindowSeconds: request.maxWindowSeconds,
			maxOCRCharacters: request.maxOCRCharacters,
			maxDescriptionCharacters: request.maxDescriptionCharacters,
			recommendedRequest: request,
			metadata: metadata
		)
	}
}

// MARK: - Sparse gate (in-memory, no timers/polling)

/// Cooldown / freshness gate for sparse visual peeks (process-local, not persisted).
actor SparseVisualPeekGate {
	static let cooldownSeconds: TimeInterval = 45
	static let snapshotVisualFreshSeconds: TimeInterval = 35

	private var lastPeekCompletedAt: Date?

	func evaluate(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date = Date()
	) -> SparseVisualPeekGateEvaluation {
		if snapshotVisualStillFresh(snapshot: snapshot, referenceTime: referenceTime) {
			return SparseVisualPeekGateEvaluation(shouldDeny: true, denyReason: .recentVisualContextStillFresh)
		}
		if let last = lastPeekCompletedAt,
		   referenceTime.timeIntervalSince(last) < Self.cooldownSeconds {
			return SparseVisualPeekGateEvaluation(shouldDeny: true, denyReason: .cooldownWindowActive)
		}
		return SparseVisualPeekGateEvaluation(shouldDeny: false, denyReason: nil)
	}

	func recordPeekCompleted(at: Date = Date()) {
		lastPeekCompletedAt = at
	}

	func resetForTests() {
		lastPeekCompletedAt = nil
	}

	private func snapshotVisualStillFresh(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> Bool {
		let visual = snapshot.visualContextAvailability
		if let expires = visual.visualExpiresAt, referenceTime < expires {
			return visual.hasUsableVisual
		}
		if let captured = visual.visualCapturedAt,
		   referenceTime.timeIntervalSince(captured) < Self.snapshotVisualFreshSeconds {
			return visual.hasUsableVisual
		}
		return false
	}
}

struct SparseVisualPeekGateEvaluation: Equatable, Sendable {
	let shouldDeny: Bool
	let denyReason: SparseVisualPeekDenyReason?
}

// MARK: - Policy

/// Deterministic sparse visual peek policy (T18.2).
enum SparseVisualPeekPolicy {

	static let weakFreshnessThreshold = 0.42
	static let weakWorkflowConfidenceThreshold = 0.38
	static let strongFreshnessThreshold = 0.72
	static let strongWorkflowConfidenceThreshold = 0.55
	static let selectedTextSufficientMinLength = 24

	static func shouldRequestVisualPeek(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		action: GeneratedExecutionAction? = nil,
		explicitManualRequest: Bool = false,
		gateEvaluation: SparseVisualPeekGateEvaluation = SparseVisualPeekGateEvaluation(shouldDeny: false, denyReason: nil),
		referenceTime: Date = Date()
	) -> SparseVisualPeekDecision {
		if gateEvaluation.shouldDeny, let reason = gateEvaluation.denyReason {
			logDenied(reason: reason, metadata: ["gate": "1"])
			return .deny(reason, metadata: ["gate": "1"])
		}

		if !screenPermissionLikelyAvailable(snapshot: snapshot) {
			logDenied(reason: .permissionUnavailable)
			return .deny(.permissionUnavailable, metadata: ["perm": "screen_recording"])
		}

		let plan = action?.executionPlan
		let budget = plan?.executionBudget ?? .conservative
		if let budgetDeny = evaluateBudgetLikelyDenied(plan: plan, budget: budget) {
			logDenied(reason: budgetDeny)
			return .deny(budgetDeny, metadata: ["budget": "1"])
		}

		if explicitManualRequest {
			return buildAllow(
				reason: .manualOrDebugExplicitRequest,
				snapshot: snapshot,
				action: action,
				budget: budget,
				priority: 0.95,
				confidenceNeed: 0.9,
				requiresOCR: plan?.requiresOCR ?? true,
				requiresVisualDescription: plan?.requiresVision ?? true,
				referenceTime: referenceTime
			)
		}

		if plan?.requiresVision == true || plan?.requiresOCR == true {
			return buildAllow(
				reason: .actionRequiresVisionOrOCR,
				snapshot: snapshot,
				action: action,
				budget: budget,
				priority: 0.88,
				confidenceNeed: 0.85,
				requiresOCR: plan?.requiresOCR ?? false,
				requiresVisualDescription: plan?.requiresVision ?? false,
				referenceTime: referenceTime
			)
		}

		let suppression = GeneratedExecutionClipboardFreshnessPolicy.evaluate(
			snapshot: snapshot,
			referenceTime: referenceTime
		)
		let hasSelection = hasSufficientSelectedText(snapshot: snapshot)
		if hasSelection {
			logDenied(reason: .selectedTextSufficient)
			return .deny(.selectedTextSufficient, metadata: ["selection": "1"])
		}

		if suppression.includeClipboard, clipboardIsFresh(snapshot: snapshot, referenceTime: referenceTime) {
			logDenied(reason: .clipboardFreshEnough)
			return .deny(.clipboardFreshEnough, metadata: ["clipboard": "fresh"])
		}

		if contextAlreadyStrong(snapshot: snapshot) {
			logDenied(reason: .contextAlreadyStrong)
			return .deny(.contextAlreadyStrong, metadata: ["freshness": String(format: "%.2f", snapshot.freshnessScore)])
		}

		if snapshot.visualContextAvailability.hasUsableVisual,
		   gateEvaluation.denyReason == .recentVisualContextStillFresh {
			logDenied(reason: .recentVisualContextStillFresh)
			return .deny(.recentVisualContextStillFresh)
		}

		var triggers: [SparseVisualPeekAllowReason] = []

		if snapshot.freshnessScore < weakFreshnessThreshold || snapshot.packetIsStale {
			triggers.append(.weakContextConfidence)
		}
		if snapshot.workflowConfidence < weakWorkflowConfidenceThreshold
			|| snapshot.inferredWorkflow == .unknown {
			triggers.append(.insufficientWorkflowInference)
		}
		if !hasPrimaryText(snapshot: snapshot, suppression: suppression) {
			triggers.append(.missingPrimaryText)
		}
		if !suppression.includeClipboard,
		   !(snapshot.clipboardText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			triggers.append(.staleClipboardSuppressed)
		}
		if isVisuallyDependent(snapshot.inferredWorkflow),
		   !hasPrimaryText(snapshot: snapshot, suppression: suppression) {
			triggers.append(.visualContextLikelyUseful)
		}

		guard let primary = triggers.first else {
			if !isVisuallyDependent(snapshot.inferredWorkflow) {
				logDenied(reason: .workflowDoesNotBenefit)
				return .deny(.workflowDoesNotBenefit)
			}
			logDenied(reason: .noStrongTrigger)
			return .deny(.noStrongTrigger)
		}

		let priority = min(1, 0.45 + Double(triggers.count) * 0.12)
		let confidenceNeed = min(1, 1 - snapshot.freshnessScore)

		return buildAllow(
			reason: primary,
			snapshot: snapshot,
			action: action,
			budget: budget,
			priority: priority,
			confidenceNeed: confidenceNeed,
			requiresOCR: true,
			requiresVisualDescription: true,
			referenceTime: referenceTime,
			metadata: ["triggers": triggers.map(\.rawValue).joined(separator: ",")]
		)
	}

	// MARK: - Helpers

	private static func buildAllow(
		reason: SparseVisualPeekAllowReason,
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		action: GeneratedExecutionAction?,
		budget: ExecutionBudget,
		priority: Double,
		confidenceNeed: Double,
		requiresOCR: Bool,
		requiresVisualDescription: Bool,
		referenceTime: Date,
		metadata: [String: String] = [:]
	) -> SparseVisualPeekDecision {
		let wf = WorkflowExecutionMapper.workflowType(from: snapshot.inferredWorkflow)
		let intent: IntentType = {
			if let it = snapshot.inferredIntent {
				return WorkflowExecutionMapper.intentType(from: it)
			}
			return action?.intentType ?? .unknown
		}()
		let request = BoundedVisualContextRequest(
			reason: "sparse_visual_peek:\(reason.rawValue)",
			requestedByActionId: action?.id,
			workflowType: wf,
			intentType: intent,
			requiresOCR: requiresOCR,
			requiresVisualDescription: requiresVisualDescription,
			maxCaptureCount: BoundedVisualContextBounds.defaultMaxCaptureCount,
			maxWindowSeconds: BoundedVisualContextBounds.defaultMaxWindowSeconds,
			maxOCRCharacters: BoundedVisualContextBounds.defaultMaxOCRCharacters,
			maxDescriptionCharacters: BoundedVisualContextBounds.defaultMaxDescriptionCharacters,
			budget: budget,
			permissionAvailability: snapshot.permissionAvailability,
			createdAt: referenceTime,
			expiresAt: referenceTime.addingTimeInterval(BoundedVisualContextBounds.defaultMaxWindowSeconds)
		)
		logAllowed(reason: reason, priority: priority, metadata: metadata)
		return .allow(
			reason: reason,
			priority: priority,
			confidenceNeed: confidenceNeed,
			requiresOCR: requiresOCR,
			requiresVisualDescription: requiresVisualDescription,
			request: request,
			metadata: metadata
		)
	}

	private static func contextAlreadyStrong(snapshot: CanonicalGeneratedExecutionContextSnapshot) -> Bool {
		snapshot.freshnessScore >= strongFreshnessThreshold
			&& snapshot.workflowConfidence >= strongWorkflowConfidenceThreshold
			&& !snapshot.packetIsStale
	}

	private static func hasSufficientSelectedText(snapshot: CanonicalGeneratedExecutionContextSnapshot) -> Bool {
		let text = (snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard text.count >= selectedTextSufficientMinLength else { return false }
		if let at = snapshot.sourceMetadata.selectedTextCapturedAt {
			return !ContextFreshnessPolicy.isStale(source: .selectedText, capturedAt: at, now: Date())
		}
		return true
	}

	private static func hasPrimaryText(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		suppression: GeneratedExecutionClipboardSuppressionDecision
	) -> Bool {
		if !(snapshot.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
		if suppression.includeClipboard,
		   !(snapshot.clipboardText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		if !(snapshot.recentOCRExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		return false
	}

	private static func clipboardIsFresh(
		snapshot: CanonicalGeneratedExecutionContextSnapshot,
		referenceTime: Date
	) -> Bool {
		let at = snapshot.sourceMetadata.clipboardCapturedAt
			?? snapshot.sourceMetadata.contextUpdatedAt
			?? snapshot.generatedAt
		return !ContextFreshnessPolicy.isStale(source: .clipboardText, capturedAt: at, now: referenceTime)
	}

	private static func screenPermissionLikelyAvailable(
		snapshot: CanonicalGeneratedExecutionContextSnapshot
	) -> Bool {
		if let granted = snapshot.permissionAvailability[.screenRecording] {
			return granted
		}
		// Unknown permission state: allow policy evaluation; budget gate may still deny.
		return true
	}

	private static func evaluateBudgetLikelyDenied(
		plan: ExecutionPlan?,
		budget: ExecutionBudget
	) -> SparseVisualPeekDenyReason? {
		guard let plan else { return nil }
		if plan.requiresOCR && !budget.allowsOCR { return .budgetLikelyDenied }
		if plan.requiresVision && !budget.allowsVision { return .budgetLikelyDenied }
		if !budget.allowsVision && !budget.allowsOCR { return .budgetLikelyDenied }
		return nil
	}

	private static func isVisuallyDependent(_ workflow: InferredWorkflow) -> Bool {
		switch workflow {
		case .debugging, .browsing, .research, .reviewing:
			return true
		case .writing, .editing, .unknown:
			return false
		}
	}

	// MARK: - Logging

	private static func logAllowed(
		reason: SparseVisualPeekAllowReason,
		priority: Double,
		metadata: [String: String]
	) {
		var parts = ["reason=\(reason.rawValue)", String(format: "priority=%.2f", priority)]
		for (k, v) in metadata.prefix(6) {
			parts.append("\(k)=\(v)")
		}
		print("[SparseVisualPeek] sparse_visual_peek_allowed \(parts.joined(separator: " "))")
	}

	private static func logDenied(reason: SparseVisualPeekDenyReason, metadata: [String: String] = [:]) {
		var parts = ["reason=\(reason.rawValue)"]
		for (k, v) in metadata.prefix(6) {
			parts.append("\(k)=\(v)")
		}
		print("[SparseVisualPeek] sparse_visual_peek_denied \(parts.joined(separator: " "))")
	}
}
