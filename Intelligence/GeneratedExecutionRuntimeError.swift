import Foundation

/// Strongly typed failures for the generated execution runtime (metadata-safe; no payloads).
enum GeneratedExecutionRuntimeError: String, Error, Hashable, Sendable, Codable, CaseIterable {
	case alreadyRunning = "already_running"
	case invalidPlan = "invalid_plan"
	case budgetExceeded = "budget_exceeded"
	case missingRequiredContext = "missing_required_context"
	case cancelled
	case timedOut = "timed_out"
	case executionUnavailable = "execution_unavailable"
}

extension GeneratedExecutionRuntimeError: LocalizedError {
	var errorDescription: String? {
		switch self {
		case .alreadyRunning:
			"Another generated execution is already active."
		case .invalidPlan:
			"Execution plan failed validation."
		case .budgetExceeded:
			"Execution budget does not satisfy plan requirements."
		case .missingRequiredContext:
			"Required context is not available for execution."
		case .cancelled:
			"Execution was cancelled."
		case .timedOut:
			"Execution timed out."
		case .executionUnavailable:
			"Generated execution is not available."
		}
	}
}
