import Foundation

/// Severity for budget outcomes (metadata-only).
enum BudgetDecisionSeverity: String, Hashable, Sendable, Codable, CaseIterable {
	case info
	case warn
	case deny
}

/// Closed set of budget decision reasons (no raw context).
enum BudgetDecisionReason: String, Hashable, Sendable, Codable, CaseIterable {
	case allowed
	case cpuBudgetExceeded = "cpu_budget_exceeded"
	case executionAlreadyActive = "execution_already_active"
	case generationFrequencyExceeded = "generation_frequency_exceeded"
	case activeSamplingDenied = "active_sampling_denied"
	case expensiveContextDenied = "expensive_context_denied"
	case concurrencyLimitReached = "concurrency_limit_reached"
	case llmNotAllowed = "llm_not_allowed"
	case visionNotAllowed = "vision_not_allowed"
	case ocrNotAllowed = "ocr_not_allowed"
	case backgroundWorkNotAllowed = "background_work_not_allowed"
	case thermalSensitivityDenied = "thermal_sensitivity_denied"
	case budgetInvalid = "budget_invalid"
}

/// Structured allow/deny from the generated execution budget layer.
struct BudgetDecision: Equatable, Sendable, Codable {
	let allowed: Bool
	let reason: BudgetDecisionReason
	let severity: BudgetDecisionSeverity
	let budgetPriority: BudgetPriority
	let recommendedDelay: TimeInterval
	let metadata: [String: String]

	static func allow(
		priority: BudgetPriority = .normal,
		metadata: [String: String] = [:]
	) -> BudgetDecision {
		BudgetDecision(
			allowed: true,
			reason: .allowed,
			severity: .info,
			budgetPriority: priority,
			recommendedDelay: 0,
			metadata: metadata
		)
	}

	static func deny(
		reason: BudgetDecisionReason,
		priority: BudgetPriority = .normal,
		severity: BudgetDecisionSeverity = .deny,
		recommendedDelay: TimeInterval = 0,
		metadata: [String: String] = [:]
	) -> BudgetDecision {
		BudgetDecision(
			allowed: false,
			reason: reason,
			severity: severity,
			budgetPriority: priority,
			recommendedDelay: max(0, recommendedDelay),
			metadata: metadata
		)
	}
}

extension BudgetDecision {
	var runtimeError: GeneratedExecutionRuntimeError {
		switch reason {
		case .allowed:
			.executionUnavailable
		case .executionAlreadyActive:
			.alreadyRunning
		case .generationFrequencyExceeded:
			.executionUnavailable
		default:
			.budgetExceeded
		}
	}
}
