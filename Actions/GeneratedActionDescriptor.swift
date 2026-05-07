import Foundation

/// Placeholder descriptor for future generated actions (T11.8). No registration or execution yet.
struct GeneratedActionDescriptor: Sendable, Equatable {
	let id: String
	let title: String
	let intentKind: ActionIntentKind
	let requiredInputDescription: String
	let safetyLevel: String
}

