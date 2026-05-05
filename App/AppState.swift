import Foundation

@MainActor
final class AppState: ObservableObject {
	@Published var isPaused: Bool = false
}

