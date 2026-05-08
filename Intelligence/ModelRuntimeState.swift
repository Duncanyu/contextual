import Foundation

/// Local Ollama / configured model readiness for UI (metadata-only elsewhere).
enum ModelRuntimeState: Equatable {
	case notInstalled
	/// Initial probe or explicit refresh in progress.
	case checking
	/// Spawn / warm-up of `ollama serve` in progress.
	case starting
	/// Server not reachable (connection refused, timeout) — transient, not a permanent error.
	case unavailable
	/// HTTP `/api/tags` reachable but configured model name not present.
	case modelMissing(model: String)
	case installing
	case ready
	case error(String)
}
