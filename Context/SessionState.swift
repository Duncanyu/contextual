import Foundation

struct SessionState: Equatable {
	private static let maxItems = 5

	private(set) var recentAppLabels: [String] = []
	private(set) var recentTriggerLabels: [String] = []

	mutating func recordActiveApp(name: String?, bundleIdentifier: String) {
		let label: String
		if let name, !name.isEmpty {
			label = name
		} else {
			label = bundleIdentifier
		}
		recentAppLabels = Self.appendingRolling(recentAppLabels, value: label, maxItems: Self.maxItems)
	}

	mutating func recordTrigger(_ trigger: LastSourceTrigger) {
		recentTriggerLabels = Self.appendingRolling(recentTriggerLabels, value: trigger.rawValue, maxItems: Self.maxItems)
	}

	private static func appendingRolling(_ array: [String], value: String, maxItems: Int) -> [String] {
		var copy = array
		copy.append(value)
		while copy.count > maxItems {
			copy.removeFirst()
		}
		return copy
	}
}
