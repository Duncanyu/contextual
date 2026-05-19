import Foundation

/// Metadata-only visibility into runtime lifecycle (no context payloads).
struct GeneratedExecutionRuntimeSnapshot: Equatable, Sendable, Codable {
	var currentState: ExecutionState
	var activeActionId: UUID?
	var startedAt: Date?
	var lastUpdatedAt: Date
	var lastResult: ExecutionResult?
	var failureReason: GeneratedExecutionRuntimeError?
	var warningCodes: [String]

	static let initial = GeneratedExecutionRuntimeSnapshot(
		currentState: .idle,
		activeActionId: nil,
		startedAt: nil,
		lastUpdatedAt: Date(),
		lastResult: nil,
		failureReason: nil,
		warningCodes: []
	)
}

/// Outcome of `GeneratedExecutionRuntime.start(action:)`.
enum GeneratedExecutionStartOutcome: Equatable, Sendable {
	case completed(ExecutionResult)
	case rejected(GeneratedExecutionRuntimeError)
}

/// Optional tuning for tests; production defaults keep zero delay (no timers).
struct GeneratedExecutionRuntimeConfiguration: Sendable, Equatable {
	/// Nanoseconds to await between lifecycle transitions (`0` = yield only).
	var stepDelayNanoseconds: UInt64
	/// Self-test only: caps wall-clock execution below plan budget while keeping plan validation unchanged.
	var maxExecutionTimeOverride: TimeInterval?
	/// When true, shapes execution plans from workflow profile before primitives run.
	var workflowPlanningEnabled: Bool

	static let production = GeneratedExecutionRuntimeConfiguration(
		stepDelayNanoseconds: 0,
		maxExecutionTimeOverride: nil,
		workflowPlanningEnabled: true
	)
}
