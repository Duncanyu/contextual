import Foundation

public struct ClickedControlRecord: Sendable, Equatable {
	public let label: String?
	public let x: Double?
	public let y: Double?
	public let timestamp: Date
	
	public init(label: String?, x: Double?, y: Double?, timestamp: Date = Date()) {
		self.label = label
		self.x = x
		self.y = y
		self.timestamp = timestamp
	}
}

public struct ScrollRecord: Sendable, Equatable {
	public let direction: String
	public let timestamp: Date
	
	public init(direction: String, timestamp: Date = Date()) {
		self.direction = direction
		self.timestamp = timestamp
	}
}

public struct ObservationRecord: Sendable, Equatable {
	public let windowTitle: String
	public let textHash: String?
	public let timestamp: Date
	
	public init(windowTitle: String, textHash: String?, timestamp: Date = Date()) {
		self.windowTitle = windowTitle
		self.textHash = textHash
		self.timestamp = timestamp
	}
}

public struct ExplorationMemory: Sendable, Equatable {
	public private(set) var clickedControls: [ClickedControlRecord] = []
	public private(set) var observedWindows: [ObservationRecord] = []
	public private(set) var scrollHistory: [ScrollRecord] = []

	public init() {}
	
	public mutating func recordClick(label: String?, x: Double?, y: Double?) {
		clickedControls.append(ClickedControlRecord(label: label, x: x, y: y, timestamp: Date()))
	}
	
	public mutating func recordObserve(windowTitle: String, textHash: String?) {
		observedWindows.append(ObservationRecord(windowTitle: windowTitle, textHash: textHash, timestamp: Date()))
	}
	
	public mutating func recordScroll(direction: String) {
		scrollHistory.append(ScrollRecord(direction: direction, timestamp: Date()))
	}
	
	public func isStuckInObserveLoop() -> Bool {
		guard observedWindows.count >= 3 else { return false }
		
		let last3 = observedWindows.suffix(3)
		let first = last3.first!
		let allSame = last3.allSatisfy { $0.windowTitle == first.windowTitle && $0.textHash == first.textHash }
		
		if allSame && clickedControls.isEmpty {
			return true
		}
		
		return false
	}
	
	public func hasClicked(_ label: String) -> Bool {
		return clickedControls.contains { record in
			if let recLabel = record.label {
				return recLabel.lowercased() == label.lowercased()
			}
			return false
		}
	}
	
	public func hasScrolled() -> Bool {
		return !scrollHistory.isEmpty
	}
	
	public func clickCount() -> Int {
		return clickedControls.count
	}
}
