import Foundation

/// Bounded context gathering for generated execution (no SourceManager wiring in T17.3).
protocol GeneratedExecutionContextProvider: Sendable {
	func gatherContext(for action: GeneratedExecutionAction) async throws -> GeneratedExecutionContext
}

/// Supplies a prebuilt context packet (tests and future DI wiring).
struct StaticGeneratedExecutionContextProvider: GeneratedExecutionContextProvider, Sendable {
	private let packet: GeneratedExecutionContext?

	init(packet: GeneratedExecutionContext?) {
		self.packet = packet
	}

	func gatherContext(for action: GeneratedExecutionAction) async throws -> GeneratedExecutionContext {
		guard let packet else {
			throw GeneratedExecutionRuntimeError.missingRequiredContext
		}
		if packet.isExpired {
			throw GeneratedExecutionRuntimeError.executionUnavailable
		}
		if !packet.satisfies(required: action.requiredContextTypes) {
			throw GeneratedExecutionRuntimeError.missingRequiredContext
		}
		return packet
	}
}
