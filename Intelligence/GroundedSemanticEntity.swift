import Foundation

enum SemanticEntityType: String, Sendable, Equatable, Codable, CaseIterable {
	case productTitle = "product_title"
	case price
	case discount
	case rating
	case reviewCount = "review_count"
	case feature
	case specification
	case heading
	case body
	case action
	case unknown
}

/// A lightweight semantic entity extracted deterministically from grounded screen nodes.
struct GroundedSemanticEntity: Sendable, Equatable, Codable, Identifiable {
	let id: String
	let type: SemanticEntityType
	let text: String
	let normalizedValue: String?
	let confidence: Double
	let sourceNodeId: String
	let role: ScreenStateRole
	let tags: [String]

	init(
		id: String,
		type: SemanticEntityType,
		text: String,
		normalizedValue: String?,
		confidence: Double,
		sourceNodeId: String,
		role: ScreenStateRole,
		tags: [String]
	) {
		self.id = id
		self.type = type
		self.text = text
		self.normalizedValue = normalizedValue
		self.confidence = min(1, max(0, confidence))
		self.sourceNodeId = sourceNodeId
		self.role = role
		self.tags = tags
	}
}

