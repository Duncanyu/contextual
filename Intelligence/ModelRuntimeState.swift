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

	/// Short label for debug UI.
	var debugLabel: String {
		switch self {
		case .notInstalled: return "not_installed"
		case .checking: return "checking"
		case .starting: return "starting"
		case .unavailable: return "unavailable"
		case .modelMissing(let m): return "missing(\(m))"
		case .installing: return "installing"
		case .ready: return "ready"
		case .error(let msg): return "error(\(msg.prefix(30)))"
		}
	}
}
