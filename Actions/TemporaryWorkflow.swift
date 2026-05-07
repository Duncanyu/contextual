import Foundation

/// Placeholder for future multi-intent workflows (T11.8). Inert for now.
struct TemporaryWorkflow: Sendable, Equatable {
	let id: String
	let title: String
	let intents: [ActionIntent]
	/// Must remain `false` until explicit workflow execution exists.
	let isExecutable: Bool
}

