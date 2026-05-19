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

	static let production = GeneratedExecutionRuntimeConfiguration(stepDelayNanoseconds: 0)
}
