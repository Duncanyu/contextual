import Foundation

/// Output from one safe primitive invocation (bounded; in-memory only).
struct ExecutionPrimitiveOutput: Equatable, Sendable, Codable {
	let primitive: ExecutionPrimitive
	let title: String
	let content: String
	let sections: [ExecutionResultSection]
	let warnings: [String]
	let confidence: Double
	let metadata: [String: String]

	init(
		primitive: ExecutionPrimitive,
		title: String,
		content: String,
		sections: [ExecutionResultSection] = [],
		warnings: [String] = [],
		confidence: Double,
		metadata: [String: String] = [:]
	) {
		self.primitive = primitive
		self.title = title
		self.content = content
		self.sections = sections
		self.warnings = warnings
		self.confidence = min(1.0, max(0.0, confidence))
		self.metadata = metadata
	}
}

enum ExecutionPrimitiveRunnerError: String, Error, Hashable, Sendable {
	case unsupportedPrimitive = "unsupported_primitive"
	case insufficientContext = "insufficient_context"
}
