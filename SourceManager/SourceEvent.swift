import Foundation

enum SourceEvent: Equatable {
	case sourceChanged(SourceChange)
}

enum SourceChange: Equatable {
	case activeAppChanged(bundleIdentifier: String, name: String?)
	case windowTitleChanged(bundleIdentifier: String, appName: String?, title: String?)
}

