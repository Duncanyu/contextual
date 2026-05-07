import Foundation

/// Tier-1 micro model input (T12.3.5). No persistence; callers must not log `compressedText`.
struct MicroDecisionRequest: Sendable, Equatable {
	let contextType: ContextType
	let features: ContextFeatures
	let availableActions: [String]
	let sourceType: String
	let appName: String?
	let windowTitle: String?
	let textLength: Int
	let lineCount: Int
	let compressedText: String
}

/// Tier-1 micro model output (classification only; no generative fields).
struct MicroDecisionResponse: Sendable, Equatable {
	let shouldSuggest: Bool
	let bestActionId: String?
	let confidence: Double
}
