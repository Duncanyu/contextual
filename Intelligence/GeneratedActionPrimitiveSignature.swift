import Foundation

/// Privacy-safe plan signature (codes only; never raw text or outputs).
struct GeneratedActionPrimitiveSignature: Equatable, Sendable, Codable, Hashable {
	let signatureCode: String
	let primitiveCodes: String
	let workflowType: WorkflowType
	let intentType: IntentType
	let requiredContextCodes: String
	let safetyVersion: Int

	static let currentSafetyVersion = 1

	static func from(action: GeneratedExecutionAction) -> GeneratedActionPrimitiveSignature {
		let primitives = action.executionPlan.primitives.map(\.rawValue).joined(separator: ",")
		let contexts = action.requiredContextTypes.map(\.rawValue).joined(separator: ",")
		let code = [
			workflowTypeCode(action.workflowType),
			intentTypeCode(action.intentType),
			primitives,
			contexts,
			"v\(currentSafetyVersion)",
		].joined(separator: "|")

		return GeneratedActionPrimitiveSignature(
			signatureCode: code,
			primitiveCodes: primitives,
			workflowType: action.workflowType,
			intentType: action.intentType,
			requiredContextCodes: contexts,
			safetyVersion: currentSafetyVersion
		)
	}

	private static func workflowTypeCode(_ type: WorkflowType) -> String { type.rawValue }
	private static func intentTypeCode(_ type: IntentType) -> String { type.rawValue }
}
