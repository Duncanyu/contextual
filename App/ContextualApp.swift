import SwiftUI

@main
struct ContextualApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

	var body: some Scene {
		Settings {
			EmptyView()
		}
		.commands {
			CommandMenu("Assistant") {
				Button("Invoke Assistant") {
					NotificationCenter.default.post(name: .contextualManualTrigger, object: nil)
				}
				.keyboardShortcut("a", modifiers: [.command, .shift])
			}
		}
	}
}

 
