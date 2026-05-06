import Foundation

enum ModelRuntimeState: Equatable {
	case notInstalled
	case notRunning
	case installing
	case ready
	case error(String)
}
